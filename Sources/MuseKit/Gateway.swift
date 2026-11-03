import Foundation

public enum GatewayError: Error, CustomStringConvertible {
    case invalidURL
    case timeout
    case closed
    case socket(String)
    case status(Int)
    case reset(code: Int, reason: String)
    case protocolViolation(String)
    case subscriptionStatus(Int)
    case subscriptionEndedBeforeAck

    public var description: String {
        switch self {
        case .invalidURL: return "Unexpected gateway URL"
        case .timeout: return "Gateway operation timed out"
        case .closed: return "Gateway connection closed"
        case .socket(let message): return "Gateway socket error: \(message)"
        case .status(let status): return "Gateway returned status \(status)"
        case .reset(let code, let reason): return "Gateway reset \(code): \(reason)"
        case .protocolViolation(let detail): return "Gateway protocol error: \(detail)"
        case .subscriptionStatus(let status): return "Subscription returned status \(status)"
        case .subscriptionEndedBeforeAck: return "Subscription ended before acknowledgement"
        }
    }
}

public enum GatewaySubscriptionRecord: Equatable, Sendable {
    case acknowledged(JSONValue)
    case event(JSONValue)
}

/// Experimental gateway client. The caller must supply a verifier that
/// implements Muse's server/VM identity checks (including confidential-VM
/// attestation and any owner recovery proof) before message 3 is sent.
public actor MuseGateway {
    public struct Config: Sendable {
        public var url: URL
        public var appID: String
        public var helloPayload: Data?
        public var timeout: TimeInterval

        public init(url: URL, appID: String = "hatch-web", helloPayload: Data? = nil, timeout: TimeInterval = 10) {
            self.url = url
            self.appID = appID
            self.helloPayload = helloPayload
            self.timeout = timeout
        }
    }

    public struct Hello: Sendable {
        public let serverStaticPublicKey: Data
        public let handshakeHash: Data
        public let clientNonce: Data?
        public let payload: Data
    }

    /// Returns the payload for handshake message 3 (for example a confidential
    /// VM owner proof). Throw to reject the peer.
    public typealias Verifier = @Sendable (Hello) async throws -> Data

    private enum PendingResult {
        case request(CheckedContinuation<JSONValue?, Error>)
        case subscription(AsyncThrowingStream<GatewaySubscriptionRecord, Error>.Continuation)
    }

    private struct Pending {
        let result: PendingResult
        var status = 0
        var bytes: [UInt8] = []
        var acknowledged = false
    }

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let transport: NoiseTransport
    private let appID: String
    private let assembler = ResponseAssembler()
    private var nextStreamID = 1
    private var pending: [Int: Pending] = [:]
    private var closed = false
    private var readTask: Task<Void, Never>?

    private init(task: URLSessionWebSocketTask, session: URLSession, transport: NoiseTransport, appID: String) {
        self.task = task
        self.session = session
        self.transport = transport
        self.appID = appID
    }

    public static func connect(config: Config, verify: @escaping Verifier) async throws -> MuseGateway {
        guard config.url.scheme == "wss",
              config.url.host == "hatch.metaaivm.com",
              config.url.path == "/v1/noise" else {
            throw GatewayError.invalidURL
        }

        let nonce: Data?
        let helloPayload: Data
        if let payload = config.helloPayload {
            helloPayload = payload
            nonce = nil
        } else {
            let generated = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            nonce = generated
            helloPayload = Data([0x0a, 0x20]) + generated
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: config.url)
        task.resume()

        do {
            let noise = NoiseXXInitiator()
            let message1 = try noise.message1(payload: helloPayload)
            try await withTimeout(config.timeout) { try await task.send(.data(message1)) }

            let message2 = try await receiveData(task, timeout: config.timeout)
            let hello = try noise.message2(message2)
            let proof = try await verify(Hello(
                serverStaticPublicKey: hello.serverStaticPublicKey,
                handshakeHash: hello.handshakeHash,
                clientNonce: nonce,
                payload: hello.payload
            ))
            let message3 = try noise.message3(payload: proof)
            try await withTimeout(config.timeout) { try await task.send(.data(message3.message)) }

            let gateway = MuseGateway(task: task, session: session, transport: message3.transport, appID: config.appID)
            await gateway.startReadLoop()
            return gateway
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
    }

    // MARK: - Public operations

    public func request(
        _ verb: String,
        _ path: String,
        body: (any Encodable)? = nil,
        headers: [GatewayHeader] = []
    ) async throws -> JSONValue? {
        guard !closed else { throw GatewayError.closed }
        let streamID = nextStreamID
        nextStreamID += 1

        let requestID = UUID().uuidString.lowercased()
        var allHeaders = headers
        allHeaders.append(GatewayHeader("x-request-id", requestID))
        allHeaders.append(GatewayHeader("x-app-id", appID))
        allHeaders.append(GatewayHeader("Accept-Language", "en-US"))

        let bodyData: Data?
        if let body {
            bodyData = try JSONEncoder().encode(body)
            allHeaders.append(GatewayHeader("Content-Type", "application/json"))
        } else {
            bodyData = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[streamID] = Pending(result: .request(continuation))
            Task {
                do {
                    try await self.send(streamID: streamID, verb: verb, path: path, body: bodyData, headers: allHeaders)
                } catch {
                    self.failStream(streamID, error: error)
                }
            }
        }
    }

    public func subscribe(
        _ path: String,
        body: (any Encodable)? = nil,
        headers: [GatewayHeader] = []
    ) -> AsyncThrowingStream<GatewaySubscriptionRecord, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.beginSubscription(path: path, body: body, headers: headers, continuation: continuation)
            }
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        failAll(GatewayError.closed)
    }

    // MARK: - Internals

    private func startReadLoop() {
        readTask = Task { await self.readLoop() }
    }

    private func readLoop() async {
        do {
            while !closed {
                let message = try await task.receive()
                guard case .data(let data) = message else { continue }
                let plaintext = try transport.decrypt(data)
                if let frame = try assembler.feed(plaintext) {
                    try handle(frame)
                }
            }
        } catch {
            failAll(error)
        }
    }

    private func send(streamID: Int, verb: String, path: String, body: Data?, headers: [GatewayHeader]) async throws {
        let chunks = try Framing.encodeRequest(
            streamID: streamID,
            verb: verb,
            path: path,
            body: body ?? Data(),
            headers: headers,
            chunkID: Framing.randomChunkID()
        )
        for chunk in chunks {
            try await task.send(.data(transport.encrypt(chunk)))
        }
    }

    private func beginSubscription(
        path: String,
        body: (any Encodable)?,
        headers: [GatewayHeader],
        continuation: AsyncThrowingStream<GatewaySubscriptionRecord, Error>.Continuation
    ) async {
        guard !closed else {
            continuation.finish(throwing: GatewayError.closed)
            return
        }
        let streamID = nextStreamID
        nextStreamID += 1

        var allHeaders = headers
        allHeaders.append(GatewayHeader("x-request-id", UUID().uuidString.lowercased()))
        allHeaders.append(GatewayHeader("x-app-id", appID))
        allHeaders.append(GatewayHeader("Accept-Language", "en-US"))

        let bodyData: Data?
        do {
            if let body {
                bodyData = try JSONEncoder().encode(body)
                allHeaders.append(GatewayHeader("Content-Type", "application/json"))
            } else {
                bodyData = nil
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }

        pending[streamID] = Pending(result: .subscription(continuation))
        do {
            try await send(streamID: streamID, verb: "POST", path: path, body: bodyData, headers: allHeaders)
        } catch {
            failStream(streamID, error: error)
        }
    }

    private func handle(_ frame: GatewayFrame) throws {
        guard var entry = pending[frame.streamID] else { return }

        switch frame.kind {
        case .reset(let code, let reason):
            pending[frame.streamID] = nil
            finish(entry, outcome: .failure(GatewayError.reset(code: code, reason: reason)))

        case .response(let status, _, let body, let end):
            entry.status = status
            if !body.isEmpty { try consume(body, into: &entry) }
            if end {
                pending[frame.streamID] = nil
                finish(entry, outcome: .success(()))
            } else {
                pending[frame.streamID] = entry
            }

        case .body(let data, let end):
            if !data.isEmpty { try consume(data, into: &entry) }
            if end {
                pending[frame.streamID] = nil
                finish(entry, outcome: .success(()))
            } else {
                pending[frame.streamID] = entry
            }
        }
    }

    private func consume(_ data: Data, into entry: inout Pending) throws {
        switch entry.result {
        case .request:
            entry.bytes.append(contentsOf: data)

        case .subscription(let continuation):
            entry.bytes.append(contentsOf: data)
            while let newline = entry.bytes.firstIndex(of: 0x0A) {
                let line = Data(entry.bytes[..<newline])
                entry.bytes.removeFirst(newline + 1)
                try dispatch(line: trimCarriageReturn(line), entry: &entry, continuation: continuation)
            }
        }
    }

    private func dispatch(
        line: Data,
        entry: inout Pending,
        continuation: AsyncThrowingStream<GatewaySubscriptionRecord, Error>.Continuation
    ) throws {
        guard !line.isEmpty else { return }
        let record: JSONValue
        do {
            record = try JSONValue.decode(line)
        } catch {
            throw GatewayError.protocolViolation("invalid subscription record")
        }

        if !entry.acknowledged {
            entry.acknowledged = true
            if record["type"]?.stringValue == "res", let status = record["status"]?.intValue, status >= 400 {
                throw GatewayError.subscriptionStatus(status)
            }
            continuation.yield(.acknowledged(record))
            return
        }
        if record["type"]?.stringValue == "event" {
            continuation.yield(.event(record))
        }
    }

    private func trimCarriageReturn(_ data: Data) -> Data {
        if data.last == 0x0D { return data.dropLast() }
        return data
    }

    private func finish(_ entry: Pending, outcome: Result<Void, Error>) {
        switch entry.result {
        case .request(let continuation):
            switch outcome {
            case .failure(let error):
                continuation.resume(throwing: error)
            case .success:
                if entry.status != 0, !(200..<300).contains(entry.status) {
                    continuation.resume(throwing: GatewayError.status(entry.status))
                } else if entry.bytes.isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    do {
                        continuation.resume(returning: try JSONValue.decode(Data(entry.bytes)))
                    } catch {
                        continuation.resume(throwing: GatewayError.protocolViolation("invalid JSON response"))
                    }
                }
            }

        case .subscription(let continuation):
            switch outcome {
            case .failure(let error):
                continuation.finish(throwing: error)
            case .success:
                if !entry.acknowledged {
                    continuation.finish(throwing: GatewayError.subscriptionEndedBeforeAck)
                } else if entry.status != 0, !(200..<300).contains(entry.status) {
                    continuation.finish(throwing: GatewayError.status(entry.status))
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func failStream(_ streamID: Int, error: Error) {
        guard let entry = pending.removeValue(forKey: streamID) else { return }
        finish(entry, outcome: .failure(error))
    }

    private func failAll(_ error: Error) {
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            finish(entry, outcome: .failure(error))
        }
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw GatewayError.timeout
        }
        guard let result = try await group.next() else {
            throw GatewayError.timeout
        }
        group.cancelAll()
        return result
    }
}

private func receiveData(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> Data {
    let message = try await withTimeout(timeout) {
        try await task.receive()
    }
    switch message {
    case .data(let data): return data
    case .string(let text): return Data(text.utf8)
    @unknown default: throw GatewayError.protocolViolation("unknown WebSocket message type")
    }
}
