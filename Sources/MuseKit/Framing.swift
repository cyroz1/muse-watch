import Foundation

public enum FramingError: Error, Equatable, CustomStringConvertible {
    case malformedProtobuf(String)
    case invalidChunk(String)
    case requestTooLarge
    case unknownServiceFrame

    public var description: String {
        switch self {
        case .malformedProtobuf(let reason): return "Malformed protobuf: \(reason)"
        case .invalidChunk(let reason): return "Invalid chunk: \(reason)"
        case .requestTooLarge: return "Request too large"
        case .unknownServiceFrame: return "Unknown service frame"
        }
    }
}

public struct GatewayHeader: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

public enum GatewayFrameKind: Equatable, Sendable {
    case response(status: Int, headers: [GatewayHeader], body: Data, end: Bool)
    case body(data: Data, end: Bool)
    case reset(code: Int, reason: String)
}

public struct GatewayFrame: Equatable, Sendable {
    public let streamID: Int
    public let kind: GatewayFrameKind
}

/// Encodes `ApplicationRequest` / `ServiceFrame` / `ServiceRequest` /
/// `NoiseTransportFrame` frames exactly as observed in the web client.
public enum Framing {
    public static let maxChunk = 65_489
    public static let maxChunks = 256
    public static let maxAssembly = 0x100_0000

    public static func encodeRequest(
        streamID: Int,
        verb: String,
        path: String,
        body: Data = Data(),
        headers: [GatewayHeader] = [],
        chunkID: UInt64
    ) throws -> [Data] {
        var request = Data()
        request.append(Proto.bytes(1, Data(verb.utf8)))
        request.append(Proto.bytes(2, Data(path.utf8)))
        for header in headers {
            var encoded = Data()
            encoded.append(Proto.bytes(1, Data(header.key.utf8)))
            encoded.append(Proto.bytes(2, Data(header.value.utf8)))
            request.append(Proto.bytes(3, encoded))
        }
        request.append(Proto.bytes(4, body))
        request.append(Proto.number(5, 1)) // end_body

        var frame = Data()
        frame.append(Proto.number(1, UInt64(streamID)))
        frame.append(Proto.bytes(2, request))

        // ServiceRequest: field 1 is the service enum (default 0 = daemon, omitted),
        // field 2 carries the serialized ServiceFrame.
        var service = Data()
        service.append(Proto.bytes(2, frame))

        let count = max(1, (service.count + maxChunk - 1) / maxChunk)
        guard count <= maxChunks else { throw FramingError.requestTooLarge }

        return (0..<count).map { index in
            var chunk = Data()
            chunk.append(Proto.number(1, chunkID))
            chunk.append(Proto.number(2, UInt64(index)))
            chunk.append(Proto.number(3, UInt64(count)))
            let start = index * maxChunk
            let end = min(start + maxChunk, service.count)
            chunk.append(Proto.bytes(4, service.subdata(in: start..<end)))
            return chunk
        }
    }

    public static func randomChunkID() -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(UInt8.random(in: 0...255))
        }
        return value
    }
}

/// Reassembles `NoiseTransportFrame` chunks and decodes the inner
/// `ServiceResponse` / `ServiceFrame` into gateway frames.
public final class ResponseAssembler {
    private struct Pending {
        let total: Int
        var parts: [Int: Data]
    }

    private var pending: [UInt64: Pending] = [:]
    public var maxIncompleteMessages = 16

    public init() {}

    public func feed(_ data: Data) throws -> GatewayFrame? {
        let chunk = try Proto.parse(data)
        let chunkID = chunk.number(1)
        let index = Int(chunk.number(2))
        let total = Int(chunk.number(3, default: 1))
        let payload = chunk.bytes(4)

        guard total >= 1, total <= Framing.maxChunks, index < total, payload.count <= Framing.maxChunk else {
            throw FramingError.invalidChunk("bad index, total or payload size")
        }

        if pending[chunkID] == nil {
            guard pending.count < maxIncompleteMessages else {
                throw FramingError.invalidChunk("too many incomplete messages")
            }
            pending[chunkID] = Pending(total: total, parts: [:])
        }

        guard var entry = pending[chunkID], entry.total == total, entry.parts[index] == nil else {
            pending[chunkID] = nil
            throw FramingError.invalidChunk("duplicate or inconsistent chunk")
        }

        entry.parts[index] = payload
        if entry.parts.values.reduce(0, { $0 + $1.count }) > Framing.maxAssembly {
            pending[chunkID] = nil
            throw FramingError.invalidChunk("assembly too large")
        }
        guard entry.parts.count == total else {
            pending[chunkID] = entry
            return nil
        }
        pending[chunkID] = nil

        var serviceBytes = Data()
        for part in 0..<total {
            guard let part = entry.parts[part] else {
                throw FramingError.invalidChunk("missing part")
            }
            serviceBytes.append(part)
        }

        let service = try Proto.parse(serviceBytes)
        let frameBytes = service.bytes(1)
        guard !frameBytes.isEmpty else { throw FramingError.unknownServiceFrame }
        let frame = try Proto.parse(frameBytes)
        let streamID = Int(frame.number(1))

        if let response = frame.first(3), case .bytes(let body) = response {
            let fields = try Proto.parse(body)
            var headers: [GatewayHeader] = []
            for field in fields where field.number == 2 {
                if case .bytes(let headerBytes) = field.value {
                    let header = try Proto.parse(headerBytes)
                    headers.append(GatewayHeader(
                        String(decoding: header.bytes(1), as: UTF8.self),
                        String(decoding: header.bytes(2), as: UTF8.self)
                    ))
                }
            }
            return GatewayFrame(streamID: streamID, kind: .response(
                status: Int(fields.number(1)),
                headers: headers,
                body: fields.bytes(3),
                end: fields.number(4) != 0
            ))
        }
        if let bodyChunk = frame.first(4), case .bytes(let body) = bodyChunk {
            let fields = try Proto.parse(body)
            return GatewayFrame(streamID: streamID, kind: .body(
                data: fields.bytes(1),
                end: fields.number(2) != 0
            ))
        }
        if let reset = frame.first(5), case .bytes(let body) = reset {
            let fields = try Proto.parse(body)
            return GatewayFrame(streamID: streamID, kind: .reset(
                code: Int(fields.number(1)),
                reason: String(decoding: fields.bytes(2), as: UTF8.self)
            ))
        }
        throw FramingError.unknownServiceFrame
    }
}
