import Foundation

/// A request passed to an application-owned authenticated HTTP transport.
/// The transport is responsible for applying its supported session mechanism
/// and honoring the timeout and no-store requirements. MuseKit does not obtain
/// cookies, sign users in, or persist credentials.
public struct MuseAuthenticatedHTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval
    public let noStore: Bool

    public init(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval,
        noStore: Bool = true
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.noStore = noStore
    }

    public var description: String {
        "MuseAuthenticatedHTTPRequest(\(method) \(url.host ?? "<unknown>")\(url.path), headers: <redacted>, body: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct MuseAuthenticatedHTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var description: String { "MuseAuthenticatedHTTPResponse(statusCode: \(statusCode), body: <redacted>)" }
    public var debugDescription: String { description }
}

/// Supply a transport backed by an already authenticated, supported Muse
/// session. Do not implement this by copying browser cookies or HAR values.
public typealias MuseAuthenticatedFetch = @Sendable (
    MuseAuthenticatedHTTPRequest
) async throws -> MuseAuthenticatedHTTPResponse

public enum MuseAuthenticationError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidGatewayAddress
    case invalidSessionResponse
    case sessionNotValidated
    case sessionHTTPStatus(Int)
    case admissionHTTPStatus(Int)
    case wakeHTTPStatus(Int)
    case admissionResponseMissingToken
    case invalidWakeResponse
    case notaryHTTPStatus(Int)
    case notaryResponseMissingToken
    case invalidVMName
    case invalidVMID
    case delegationEndorserRequired
    case invalidNotaryEndorsement
    case requestInvalidated
    case attestationNotVerified
    case invalidInputLength(name: String, expected: Int, actual: Int)
    case missingNotaryToken
    case vmProofMismatch

    public var description: String {
        switch self {
        case .invalidGatewayAddress: return "Invalid Muse gateway address"
        case .invalidSessionResponse: return "Invalid Muse session-check response"
        case .sessionNotValidated: return "Muse session was not validated"
        case .sessionHTTPStatus(let status): return "Muse session check returned HTTP \(status)"
        case .admissionHTTPStatus(let status): return "Muse admission request returned HTTP \(status)"
        case .wakeHTTPStatus(let status): return "Muse VM wake request returned HTTP \(status)"
        case .admissionResponseMissingToken: return "Muse admission response is missing a token"
        case .invalidWakeResponse: return "Muse VM wake response is invalid"
        case .notaryHTTPStatus(let status): return "Muse notary request returned HTTP \(status)"
        case .notaryResponseMissingToken: return "Muse notary response is missing a token"
        case .invalidVMName: return "A VM name is required for notary resolution"
        case .invalidVMID: return "The VM ID is invalid"
        case .delegationEndorserRequired: return "A notary delegation endorser is required"
        case .invalidNotaryEndorsement: return "Muse returned an invalid notary endorsement"
        case .requestInvalidated: return "Muse authentication request was invalidated"
        case .attestationNotVerified: return "Verified VM attestation is required"
        case .invalidInputLength(let name, let expected, let actual):
            return "\(name) must be \(expected) bytes (received \(actual))"
        case .missingNotaryToken: return "A notary token is required"
        case .vmProofMismatch: return "VM proof did not match"
        }
    }

    public var errorDescription: String? { description }
}

/// A successful `/api/auth/check` result. The access token is intentionally
/// omitted from textual descriptions to reduce accidental credential logging.
public struct MuseValidatedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let viewerID: String
    public let sessionBindingID: String?

    fileprivate init(accessToken: String, viewerID: String, sessionBindingID: String?) {
        self.accessToken = accessToken
        self.viewerID = viewerID
        self.sessionBindingID = sessionBindingID
    }

    public var description: String {
        "MuseValidatedSession(viewerID: \(viewerID), accessToken: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Validates an existing Muse session. This is not a sign-in provider: the
/// caller must supply a fetch closure backed by Muse's supported session flow.
public actor MuseSessionValidator {
    private struct CacheEntry {
        let session: MuseValidatedSession
        let expiresAt: Date
    }

    private struct PendingRequest {
        let id: UUID
        let generation: UInt64
        let clearGeneration: UInt64
        let task: Task<MuseValidatedSession, Error>
    }

    private let fetch: MuseAuthenticatedFetch
    private let now: @Sendable () -> Date
    private var cache: CacheEntry?
    private var pending: PendingRequest?
    private var generation: UInt64 = 0
    private var clearGeneration: UInt64 = 0

    public init(
        fetch: @escaping MuseAuthenticatedFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.now = now
    }

    /// The browser client reuses a validated result for up to 60 seconds.
    /// Call `clear()` whenever the signed-in account or session changes.
    public func validate(forceRefresh: Bool = false) async throws -> MuseValidatedSession {
        if forceRefresh {
            generation &+= 1
            cache = nil
            pending = nil
        }

        let requestGeneration = generation
        let requestClearGeneration = clearGeneration
        if !forceRefresh, let cache, now() < cache.expiresAt {
            return cache.session
        }

        let request: PendingRequest
        if !forceRefresh,
           let current = pending,
           current.generation == requestGeneration,
           current.clearGeneration == requestClearGeneration {
            request = current
        } else {
            let requestID = UUID()
            let fetch = self.fetch
            let task = Task.detached {
                try await fetchMuseSession(using: fetch)
            }
            let created = PendingRequest(
                id: requestID,
                generation: requestGeneration,
                clearGeneration: requestClearGeneration,
                task: task
            )
            pending = created
            request = created
        }

        do {
            let session = try await request.task.value
            guard generation == requestGeneration,
                  clearGeneration == requestClearGeneration else {
                throw MuseAuthenticationError.requestInvalidated
            }
            cache = CacheEntry(session: session, expiresAt: now().addingTimeInterval(60))
            if pending?.id == request.id { pending = nil }
            return session
        } catch {
            if let authError = error as? MuseAuthenticationError,
               case .sessionHTTPStatus(let status) = authError,
               (status == 401 || status == 403),
               generation == requestGeneration,
               clearGeneration == requestClearGeneration {
                clear()
            }
            if pending?.id == request.id { pending = nil }
            throw error
        }
    }

    /// Clears the in-memory validation result and rejects any older async result.
    public func clear() {
        generation &+= 1
        clearGeneration &+= 1
        cache = nil
        pending = nil
    }
}

/// A delegation token that must be endorsed by the caller before it is used.
public struct MuseNotaryDelegation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let delegation: String
    public let gatewayURL: URL
    public let vmName: String?
    public let path: String

    public var description: String { "MuseNotaryDelegation(gateway: \(gatewayURL.host ?? "<unknown>"), delegation: <redacted>)" }
    public var debugDescription: String { description }
}

/// A gateway address paired with the selected VM identity. The browser
/// protocol can carry the VM ID in the target URL; keeping it here ensures the
/// admission request and WebSocket target refer to the same VM.
public struct MuseGatewayTarget: Sendable, Equatable, CustomStringConvertible {
    public let gatewayAddress: URL
    public let vmID: String?

    public init(gatewayAddress: URL, vmID: String? = nil) throws {
        guard var components = URLComponents(url: gatewayAddress, resolvingAgainstBaseURL: false),
              ["https", "wss"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        let queryVMIDs = components.queryItems ?? []
        guard queryVMIDs.isEmpty ||
                (queryVMIDs.count == 1 && queryVMIDs[0].name == "vm_id"),
              queryVMIDs.allSatisfy({ item in
                  guard let value = item.value,
                        !value.isEmpty,
                        value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                        value.utf16.count <= 255 else { return false }
                  return true
              }) else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        let urlVMID = queryVMIDs.first?.value
        if let vmID {
            let normalizedVMID = vmID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedVMID.isEmpty, normalizedVMID == vmID, normalizedVMID.utf16.count <= 255 else {
                throw MuseAuthenticationError.invalidVMID
            }
            guard urlVMID == nil || urlVMID == normalizedVMID else {
                throw MuseAuthenticationError.invalidGatewayAddress
            }
            if urlVMID == nil {
                components.queryItems = [URLQueryItem(name: "vm_id", value: normalizedVMID)]
            }
        }

        components.scheme = components.scheme?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        guard let normalizedAddress = components.url else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }
        self.gatewayAddress = normalizedAddress
        self.vmID = vmID ?? urlVMID
    }

    public var description: String {
        "MuseGatewayTarget(gateway: \(gatewayAddress.host ?? "<unknown>"), vmID: \(vmID == nil ? "<missing>" : "<redacted>"))"
    }
}

/// A caller-supplied gateway credential copied from a current Muse web
/// connection. It accepts either the opaque `auth_token` value or the full
/// browser WebSocket URL, and validates that the credential targets the
/// selected Muse VM before use. Its URL contains secrets and is always
/// redacted from textual descriptions.
public struct MusePreauthorizedGateway: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let vmID: String

    public init(_ tokenOrWebSocketURL: String, expectedVMID: String) throws {
        guard !expectedVMID.isEmpty,
              expectedVMID == expectedVMID.trimmingCharacters(in: .whitespacesAndNewlines),
              expectedVMID.utf16.count <= 255 else {
            throw MuseAuthenticationError.invalidVMID
        }

        let input = tokenOrWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 16_384,
              !input.contains("\r"), !input.contains("\n") else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        let candidate: URL
        if input.localizedCaseInsensitiveContains("://") {
            guard let parsed = URL(string: input) else {
                throw MuseAuthenticationError.invalidGatewayAddress
            }
            candidate = parsed
        } else {
            guard !input.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw MuseAuthenticationError.invalidGatewayAddress
            }
            var components = URLComponents()
            components.scheme = "wss"
            components.host = "hatch.metaaivm.com"
            components.path = "/v1/noise"
            components.queryItems = [
                URLQueryItem(name: "vm_id", value: expectedVMID),
                URLQueryItem(name: "auth_token", value: input)
            ]
            guard let url = components.url else { throw MuseAuthenticationError.invalidGatewayAddress }
            candidate = url
        }

        guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wss",
              components.host?.lowercased() == "hatch.metaaivm.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "/v1/noise" else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        let queryItems = components.queryItems ?? []
        let allowedNames: Set<String> = [
            "vm_id", "auth_token", "notary_token", "app_id", "request_id", "atod_token"
        ]
        let names = queryItems.map(\.name)
        guard names.allSatisfy(allowedNames.contains),
              Set(names).count == names.count,
              queryItems.allSatisfy({
                  guard let value = $0.value else { return false }
                  return !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
              }),
              queryItems.first(where: { $0.name == "vm_id" })?.value == expectedVMID,
              let token = queryItems.first(where: { $0.name == "auth_token" })?.value,
              !token.isEmpty,
              queryItems.first(where: { $0.name == "app_id" })?.value.map({ $0 == "hatch-web" }) ?? true else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        components.scheme = "wss"
        components.host = "hatch.metaaivm.com"
        guard let validatedURL = components.url else { throw MuseAuthenticationError.invalidGatewayAddress }
        url = validatedURL
        vmID = expectedVMID
    }

    public var description: String {
        "MusePreauthorizedGateway(vmID: <redacted>, URL: wss://hatch.metaaivm.com/v1/noise?<redacted>)"
    }

    public var debugDescription: String { description }
}

/// Admission credentials are held only in memory. Their textual descriptions
/// redact both token values.
public struct MuseAdmissionCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let notaryToken: String?
    public let gatewayURL: URL
    public let vmName: String?

    fileprivate init(token: String, notaryToken: String?, gatewayURL: URL, vmName: String?) {
        self.token = token
        self.notaryToken = notaryToken
        self.gatewayURL = gatewayURL
        self.vmName = vmName
    }

    public var description: String {
        "MuseAdmissionCredentials(gatewayURL: \(gatewayURL.host ?? "<unknown>"), tokens: <redacted>)"
    }

    public var debugDescription: String { description }

    /// Creates the credential-bearing URL accepted by `MuseGateway.connect`.
    /// Do not log or persist the returned URL; its query includes live tokens.
    public func webSocketURL(
        vmID: String,
        appID: String = "hatch-web",
        requestID: String = UUID().uuidString.lowercased(),
        notaryToken overrideNotaryToken: String? = nil
    ) throws -> URL {
        guard !vmID.isEmpty, vmID.utf16.count <= 255 else {
            throw MuseAuthenticationError.invalidVMID
        }
        let normalizedVMID = vmID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVMID.isEmpty, normalizedVMID == vmID else {
            throw MuseAuthenticationError.invalidVMID
        }
        guard var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false),
              ["https", "wss"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.lowercased() == "hatch.metaaivm.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              !appID.isEmpty,
              !requestID.isEmpty,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        let targetVMIDs = components.queryItems ?? []
        guard targetVMIDs.isEmpty ||
                (targetVMIDs.count == 1 && targetVMIDs[0].name == "vm_id" && targetVMIDs[0].value == normalizedVMID) else {
            throw MuseAuthenticationError.invalidGatewayAddress
        }

        let selectedNotaryToken = overrideNotaryToken ?? notaryToken
        components.scheme = "wss"
        components.path = "/v1/noise"
        components.queryItems = [
            URLQueryItem(name: "vm_id", value: vmID),
            URLQueryItem(name: "auth_token", value: token)
        ]
        if let selectedNotaryToken,
           !selectedNotaryToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems?.append(URLQueryItem(name: "notary_token", value: selectedNotaryToken))
        }
        components.queryItems?.append(URLQueryItem(name: "app_id", value: appID))
        components.queryItems?.append(URLQueryItem(name: "request_id", value: requestID))

        guard let url = components.url else { throw MuseAuthenticationError.invalidGatewayAddress }
        return url
    }
}

/// Performs the browser-observed VM wake request immediately before the
/// Noise handshake begins. The selected VM ID is the only target identifier
/// sent; response text and credentials are never logged.
public actor MuseVMWakeProvider {
    private let fetch: MuseAuthenticatedFetch

    public init(fetch: @escaping MuseAuthenticatedFetch) {
        self.fetch = fetch
    }

    @discardableResult
    public func wake(
        vmID: String,
        retryCount: Int = 0,
        connectAttemptID: String = UUID().uuidString.lowercased()
    ) async throws -> String {
        guard !vmID.isEmpty,
              vmID == vmID.trimmingCharacters(in: .whitespacesAndNewlines),
              vmID.utf16.count <= 255,
              retryCount >= 0,
              !connectAttemptID.isEmpty else {
            throw MuseAuthenticationError.invalidVMID
        }
        let endpoint = URL(string: "https://muse.ai/api/hatch/vm/wake")!
        let body = try JSONSerialization.data(withJSONObject: [
            "vm_id": vmID,
            "retry_count": retryCount,
            "connect_attempt_id": connectAttemptID
        ])
        let response = try await fetch(MuseAuthenticatedHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeout: 10,
            noStore: true
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw MuseAuthenticationError.wakeHTTPStatus(response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let status = object["status"] as? String,
              !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuseAuthenticationError.invalidWakeResponse
        }
        return status.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Port of the source-observed browser session and Hatch admission helpers.
/// This actor never signs in, stores credentials on disk, or verifies a peer.
public actor MuseAdmissionProvider {
    public typealias DelegationEndorser = @Sendable (MuseNotaryDelegation) async throws -> String

    private struct CacheKey: Hashable {
        let gatewayAddress: String
        let vmName: String?
    }

    private struct CacheEntry {
        let credentials: MuseAdmissionCredentials
    }

    private struct PendingRequest {
        let id: UUID
        let generation: UInt64
        let clearGeneration: UInt64
        let task: Task<MuseAdmissionCredentials, Error>
    }

    private let fetch: MuseAuthenticatedFetch
    private let endorseDelegation: DelegationEndorser?
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]
    private var pending: [CacheKey: PendingRequest] = [:]
    private var generations: [CacheKey: UInt64] = [:]
    private var clearGeneration: UInt64 = 0

    public init(
        fetch: @escaping MuseAuthenticatedFetch,
        endorseDelegation: DelegationEndorser? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.endorseDelegation = endorseDelegation
        self.now = now
    }

    public func get(
        gatewayAddress: URL,
        vmID: String? = nil,
        vmName: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> MuseAdmissionCredentials {
        let target = try MuseGatewayTarget(gatewayAddress: gatewayAddress, vmID: vmID)
        let address = target.gatewayAddress
        let normalizedVMName = vmName.flatMap { $0.isEmpty ? nil : $0 }
        let key = CacheKey(gatewayAddress: address.absoluteString, vmName: normalizedVMName)

        if forceRefresh {
            cache[key] = nil
            generations[key, default: 0] &+= 1
        }

        let requestGeneration = generations[key] ?? 0
        let requestClearGeneration = clearGeneration
        if !forceRefresh,
           let cached = cache[key],
           let expiry = Self.notaryExpirationDate(in: cached.credentials.notaryToken),
           now().addingTimeInterval(60) >= expiry {
            cache[key] = nil
        } else if !forceRefresh, let cached = cache[key] {
            return cached.credentials
        }

        let request: PendingRequest
        if !forceRefresh,
           let current = pending[key],
           current.generation == requestGeneration,
           current.clearGeneration == requestClearGeneration {
            request = current
        } else {
            let requestID = UUID()
            let fetch = self.fetch
            let endorser = self.endorseDelegation
            let task = Task.detached {
                try await fetchMuseAdmission(
                    gatewayAddress: address,
                    vmName: normalizedVMName,
                    forceRefresh: forceRefresh,
                    fetch: fetch,
                    endorser: endorser
                )
            }
            let created = PendingRequest(
                id: requestID,
                generation: requestGeneration,
                clearGeneration: requestClearGeneration,
                task: task
            )
            pending[key] = created
            request = created
        }

        do {
            let credentials = try await request.task.value
            guard generations[key] == requestGeneration,
                  clearGeneration == requestClearGeneration else {
                throw MuseAuthenticationError.requestInvalidated
            }
            cache[key] = CacheEntry(credentials: credentials)
            if pending[key]?.id == request.id { pending[key] = nil }
            return credentials
        } catch {
            if pending[key]?.id == request.id { pending[key] = nil }
            throw error
        }
    }

    /// Resolves a notary token through the source-observed endpoint. The
    /// response shape is source-derived and has not been live-verified here.
    public func resolveNotaryToken(vmName: String) async throws -> String {
        guard !vmName.isEmpty else { throw MuseAuthenticationError.invalidVMName }
        let endpoint = URL(string: "https://muse.ai/api/hatch/noise-notary-token")!
        let body = try JSONSerialization.data(withJSONObject: ["vmName": vmName])
        let response = try await fetch(MuseAuthenticatedHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeout: 8,
            noStore: true
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw MuseAuthenticationError.notaryHTTPStatus(response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let token = object["notaryToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuseAuthenticationError.notaryResponseMissingToken
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops cached credentials and invalidates all in-flight admission work.
    /// Call this when the signed-in owner or authenticated session changes.
    public func clear() {
        clearGeneration &+= 1
        cache.removeAll()
        pending.removeAll()
        generations.removeAll()
    }

    /// Parses the source-observed `timeout:` restriction, returning nil for an
    /// absent, malformed, or unrecognized notary token.
    public static func notaryExpirationDate(in token: String?) -> Date? {
        guard let token,
              let payload = token.split(separator: ".", omittingEmptySubsequences: false).dropFirst(2).first,
              let data = decodeBase64URL(String(payload)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let restrictions = object["restrictions"] as? [String] else {
            return nil
        }

        for restriction in restrictions where restriction.hasPrefix("timeout:") {
            let rawSeconds = restriction.dropFirst("timeout:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let seconds = Double(rawSeconds), seconds.isFinite, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

}

private func fetchMuseSession(using fetch: MuseAuthenticatedFetch) async throws -> MuseValidatedSession {
    let endpoint = URL(string: "https://muse.ai/api/auth/check")!
    let response = try await fetch(MuseAuthenticatedHTTPRequest(
        url: endpoint,
        method: "POST",
        timeout: 15,
        noStore: true
    ))
    guard response.statusCode == 200 else {
        throw MuseAuthenticationError.sessionHTTPStatus(response.statusCode)
    }
    guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          object["outcome"] as? String == "validated",
          let accessToken = object["access_token"] as? String,
          !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let viewerID = object["viewer_id"] as? String,
          !viewerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let bindingValue = object["session_binding_id"] else {
        if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           object["outcome"] as? String != "validated" {
            throw MuseAuthenticationError.sessionNotValidated
        }
        throw MuseAuthenticationError.invalidSessionResponse
    }

    let bindingID: String?
    if bindingValue is NSNull {
        bindingID = nil
    } else if let value = bindingValue as? String {
        bindingID = value
    } else {
        throw MuseAuthenticationError.invalidSessionResponse
    }
    return MuseValidatedSession(
        accessToken: accessToken,
        viewerID: viewerID,
        sessionBindingID: bindingID
    )
}

private func fetchMuseAdmission(
    gatewayAddress: URL,
    vmName: String?,
    forceRefresh: Bool,
    fetch: MuseAuthenticatedFetch,
    endorser: MuseAdmissionProvider.DelegationEndorser?
) async throws -> MuseAdmissionCredentials {
    let endpoint = URL(string: "https://muse.ai/api/hatch/token")!
    var bodyObject: [String: Any] = ["vmAddress": gatewayAddress.absoluteString]
    if let vmName { bodyObject["vmName"] = vmName }
    if forceRefresh { bodyObject["force_refresh"] = true }
    let body = try JSONSerialization.data(withJSONObject: bodyObject)
    let response = try await fetch(MuseAuthenticatedHTTPRequest(
        url: endpoint,
        method: "POST",
        headers: ["Content-Type": "application/json"],
        body: body,
        timeout: 10,
        noStore: true
    ))
    guard (200..<300).contains(response.statusCode) else {
        throw MuseAuthenticationError.admissionHTTPStatus(response.statusCode)
    }
    guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let token = object["token"] as? String,
          !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MuseAuthenticationError.admissionResponseMissingToken
    }

    var notaryToken = (object["notary_token"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let delegation = notaryToken, delegation.hasPrefix("delegation.") {
        guard let endorser else { throw MuseAuthenticationError.delegationEndorserRequired }
        let endorsed = try await endorser(MuseNotaryDelegation(
            delegation: delegation,
            gatewayURL: gatewayAddress,
            vmName: vmName,
            path: "/v1/noise"
        ))
        guard !endorsed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuseAuthenticationError.invalidNotaryEndorsement
        }
        notaryToken = endorsed
    }

    return MuseAdmissionCredentials(
        token: token,
        notaryToken: notaryToken,
        gatewayURL: gatewayAddress,
        vmName: vmName
    )
}

private func decodeBase64URL(_ value: String) -> Data? {
    var normalized = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: normalized)
}
