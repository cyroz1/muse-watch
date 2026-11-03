// Cross-implementation checks for MuseKit. Runs with Command Line Tools only,
// so it does not depend on XCTest. Exit code is non-zero on failure.
import Foundation
import MuseKit

var failures = 0
var passes = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL - \(label)")
    }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs == rhs {
        passes += 1
    } else {
        failures += 1
        print("FAIL - \(label)\n  expected: \(rhs)\n  actual:   \(lhs)")
    }
}

func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

// MARK: - Fixtures

struct Vectors {
    let raw: [String: Any]

    init() throws {
        guard let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures") else {
            throw CheckError.fixtureMissing
        }
        raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func string(_ name: String) -> String {
        raw[name] as! String
    }

    func key(_ name: String) -> String {
        (raw["keys"] as! [String: Any])[name] as! String
    }

    var request: [String: Any] { raw["request"] as! [String: Any] }
    var response: [String: Any] { raw["response"] as! [String: Any] }
}

enum CheckError: Error {
    case fixtureMissing
    case malformed(String)
}

func hex(_ string: String) -> Data {
    var data = Data(capacity: string.count / 2)
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        guard let byte = UInt8(string[index..<next], radix: 16) else { return data }
        data.append(byte)
        index = next
    }
    return data
}

/// Small protobuf writing helpers used to build negative/positive frames
/// without exposing MuseKit internals.
func varint(_ value: UInt64) -> Data {
    var value = value
    var out = Data()
    repeat {
        var byte = UInt8(value & 0x7f)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        out.append(byte)
    } while value != 0
    return out
}

func pbBytes(_ number: Int, _ data: Data) -> Data {
    var out = varint(UInt64(number) << 3 | 2)
    out.append(varint(UInt64(data.count)))
    out.append(data)
    return out
}

func pbNumber(_ number: Int, _ value: UInt64) -> Data {
    var out = varint(UInt64(number) << 3)
    out.append(varint(value))
    return out
}

/// Parses only the length-delimited and varint fields the checks need.
func pbFields(_ data: Data) throws -> [(number: Int, varint: UInt64?, bytes: Data?)] {
    let bytes = [UInt8](data)
    var index = 0
    var fields: [(Int, UInt64?, Data?)] = []

    func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var count = 0
        while true {
            guard index < bytes.count, count < 10 else { throw CheckError.malformed("varint") }
            let byte = bytes[index]
            index += 1
            count += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    while index < bytes.count {
        let key = try readVarint()
        let number = Int(key >> 3)
        switch key & 7 {
        case 0:
            fields.append((number, try readVarint(), nil))
        case 2:
            let size = Int(try readVarint())
            guard size <= bytes.count - index else { throw CheckError.malformed("truncated") }
            fields.append((number, nil, Data(bytes[index..<(index + size)])))
            index += size
        default:
            throw CheckError.malformed("wire type")
        }
    }
    return fields
}

func noiseChunk(id: UInt64, index: UInt64, total: UInt64, payload: Data) -> Data {
    var chunk = Data()
    chunk.append(pbNumber(1, id))
    chunk.append(pbNumber(2, index))
    chunk.append(pbNumber(3, total))
    chunk.append(pbBytes(4, payload))
    return chunk
}

func fixedInitiator(_ vectors: Vectors) throws -> NoiseXXInitiator {
    var calls = 0
    let ephemeral = try NoiseKeyPair(privateKeyRaw: hex(vectors.key("clientEphemeralPrivate")))
    let localStatic = try NoiseKeyPair(privateKeyRaw: hex(vectors.key("clientStaticPrivate")))
    return NoiseXXInitiator {
        defer { calls += 1 }
        return calls == 0 ? ephemeral : localStatic
    }
}

// MARK: - Checks

let vectors = try Vectors()

run("Noise handshake messages match the Node prototype") {
    let initiator = try fixedInitiator(vectors)
    let message1 = try initiator.message1(payload: hex(vectors.string("hello")))
    checkEqual(message1, hex(vectors.string("message1")), "message 1 bytes")
    checkEqual(initiator.message1Hash!, hex(vectors.string("message1Hash")), "message 1 hash")

    let hello = try initiator.message2(hex(vectors.string("message2")))
    checkEqual(hello.serverStaticPublicKey, hex(vectors.key("serverStaticPublic")), "server static key")

    let result = try initiator.message3()
    checkEqual(result.message, hex(vectors.string("message3")), "message 3 bytes")
}

run("Gateway request encoding matches the Node prototype") {
    let initiator = try fixedInitiator(vectors)
    _ = try initiator.message1(payload: hex(vectors.string("hello")))
    _ = try initiator.message2(hex(vectors.string("message2")))
    let transport = try initiator.message3().transport

    let request = vectors.request
    let streamID = request["streamId"] as! Int
    let chunkID = UInt64(request["chunkId"] as! String)!
    let headers = (request["headers"] as! [[String]]).map { GatewayHeader($0[0], $0[1]) }

    let chunks = try Framing.encodeRequest(
        streamID: streamID,
        verb: request["verb"] as! String,
        path: request["path"] as! String,
        body: Data((request["requestBody"] as! String).utf8),
        headers: headers,
        chunkID: chunkID
    )
    checkEqual(chunks, (request["plaintextChunks"] as! [String]).map(hex), "encoded request chunks")

    let wire = try chunks.map { try transport.encrypt($0) }
    checkEqual(wire, (request["wireFrames"] as! [String]).map(hex), "encrypted request frames")
}

run("Gateway response decoding matches the Node prototype") {
    let initiator = try fixedInitiator(vectors)
    _ = try initiator.message1(payload: hex(vectors.string("hello")))
    _ = try initiator.message2(hex(vectors.string("message2")))
    let transport = try initiator.message3().transport

    let assembler = ResponseAssembler()
    let wire = (vectors.response["wireFrames"] as! [String]).map(hex)
    let frames = try wire.map { try assembler.feed(try transport.decrypt($0)) }
    let streamID = vectors.response["streamId"] as! Int

    guard case .response(let status, _, _, let end)? = frames[0]?.kind else {
        throw CheckError.malformed("expected response frame")
    }
    checkEqual(frames[0]?.streamID, streamID, "response stream id")
    checkEqual(status, 200, "response status")
    check(!end, "response is not final")

    guard case .body(let first, let firstEnd)? = frames[1]?.kind else {
        throw CheckError.malformed("expected first body chunk")
    }
    checkEqual(first, Data(#"{"ok":"#.utf8), "first body chunk")
    check(!firstEnd, "first chunk is not final")

    guard case .body(let second, let secondEnd)? = frames[2]?.kind else {
        throw CheckError.malformed("expected final body chunk")
    }
    checkEqual(second, Data(#"true, "chat_events": []}"#.utf8), "final body chunk")
    check(secondEnd, "final chunk ends the stream")
}

run("Request chunking splits at the observed limit") {
    let body = Data(repeating: 0x41, count: 200_000)
    let chunks = try Framing.encodeRequest(
        streamID: 4,
        verb: "POST",
        path: "/chat/stream",
        body: body,
        headers: [GatewayHeader("x-app-id", "hatch-web")],
        chunkID: 42
    )
    checkEqual(chunks.count, 4, "chunk count")
    for (index, chunk) in chunks.enumerated() {
        let fields = try pbFields(chunk)
        checkEqual(fields.first { $0.number == 1 }?.varint, 42, "chunk id")
        checkEqual(fields.first { $0.number == 2 }?.varint, UInt64(index), "chunk index")
        checkEqual(fields.first { $0.number == 3 }?.varint, 4, "chunk total")
        check((fields.first { $0.number == 4 }?.bytes?.count ?? .max) <= Framing.maxChunk, "chunk payload size")
    }
}

run("Duplicate chunks are rejected") {
    let chunk = noiseChunk(id: 7, index: 0, total: 2, payload: Data([1]))
    let assembler = ResponseAssembler()
    check(try assembler.feed(chunk) == nil, "first chunk is buffered")
    do {
        _ = try assembler.feed(chunk)
        check(false, "duplicate should throw")
    } catch {
        check(true, "duplicate throws")
    }
}

run("Reset frames decode") {
    var reset = Data()
    reset.append(pbNumber(1, 2))
    reset.append(pbBytes(2, Data("boom".utf8)))
    var frame = Data()
    frame.append(pbNumber(1, 3))
    frame.append(pbBytes(5, reset))
    let service = pbBytes(1, frame)
    let chunk = noiseChunk(id: 9, index: 0, total: 1, payload: service)

    let decoded = try ResponseAssembler().feed(chunk)
    checkEqual(decoded?.streamID, 3, "reset stream id")
    checkEqual(decoded?.kind, .reset(code: 2, reason: "boom"), "reset payload")
}

run("Inconsistent chunk totals are rejected") {
    let assembler = ResponseAssembler()
    check(try assembler.feed(noiseChunk(id: 11, index: 0, total: 2, payload: Data([1]))) == nil, "first chunk buffered")
    do {
        _ = try assembler.feed(noiseChunk(id: 11, index: 1, total: 3, payload: Data([2])))
        check(false, "inconsistent total should throw")
    } catch {
        check(true, "inconsistent total throws")
    }
}

run("Malformed protobuf is rejected") {
    let assembler = ResponseAssembler()
    do {
        _ = try assembler.feed(Data([0x0a, 0x05, 0x01]))
        check(false, "truncated protobuf should throw")
    } catch {
        check(true, "truncated protobuf throws")
    }
}

print(failures == 0 ? "\nAll \(passes) checks passed." : "\n\(failures) check(s) failed, \(passes) passed.")
exit(failures == 0 ? 0 : 1)
