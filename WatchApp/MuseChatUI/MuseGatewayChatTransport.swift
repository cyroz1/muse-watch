import Foundation
import MuseKit

/// Live transport dependencies. The caller must supply a supported signed-in
/// session fetcher and a verifier that authenticates the expected Muse VM
/// before the Noise handshake sends message 3.
public struct MuseWatchAuthentication: Sendable {
    public let fetch: MuseAuthenticatedFetch
    public let gatewayAddress: URL
    public let vmID: String
    public let vmName: String?
    public let preauthorizedGateway: MusePreauthorizedGateway?
    public let endorseDelegation: MuseAdmissionProvider.DelegationEndorser?
    public let verifyPeer: MuseGateway.Verifier

    public init(
        fetch: @escaping MuseAuthenticatedFetch,
        gatewayAddress: URL,
        vmID: String,
        vmName: String? = nil,
        preauthorizedGateway: MusePreauthorizedGateway? = nil,
        endorseDelegation: MuseAdmissionProvider.DelegationEndorser? = nil,
        verifyPeer: @escaping MuseGateway.Verifier
    ) {
        self.fetch = fetch
        self.gatewayAddress = gatewayAddress
        self.vmID = vmID
        self.vmName = vmName
        self.preauthorizedGateway = preauthorizedGateway
        self.endorseDelegation = endorseDelegation
        self.verifyPeer = verifyPeer
    }
}

public enum MuseGatewayChatTransportError: LocalizedError {
    case authenticationFailed
    case connectionFailed
    case chatRequestFailed
    case requestInvalidated
    case sessionIDMissing
    case assistantReplyMissing

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Muse sign-in could not be validated."
        case .connectionFailed:
            return "Muse could not establish a verified connection."
        case .chatRequestFailed:
            return "Muse could not complete the chat request."
        case .requestInvalidated:
            return "Muse sign-in changed while the request was running. Try again."
        case .sessionIDMissing:
            return "Muse did not return a conversation ID."
        case .assistantReplyMissing:
            return "Muse finished the request without returning assistant text."
        }
    }
}

/// A text-only Watch chat transport over MuseKit's encrypted gateway. It
/// performs session validation and admission through the caller's supported
/// authentication provider, and refuses to connect without a peer verifier.
/// Each turn uses a fresh gateway connection; admission credentials and
/// session validation remain in the existing in-memory provider caches.
public actor MuseGatewayChatTransport: ChatTransport {
    private let configuration: MuseWatchAuthentication
    private let sessionValidator: MuseSessionValidator
    private let admissionProvider: MuseAdmissionProvider
    private let vmWakeProvider: MuseVMWakeProvider
    private let nodeID: String
    private var sessionIDsByThread: [UUID: String] = [:]
    private var activeGateways: [UUID: MuseGateway] = [:]
    private var authenticationGeneration: UInt64 = 0

    public init(
        authentication: MuseWatchAuthentication,
        nodeID: String? = nil
    ) {
        configuration = authentication
        sessionValidator = MuseSessionValidator(fetch: authentication.fetch)
        vmWakeProvider = MuseVMWakeProvider(fetch: authentication.fetch)
        admissionProvider = MuseAdmissionProvider(
            fetch: authentication.fetch,
            endorseDelegation: authentication.endorseDelegation
        )
        self.nodeID = nodeID ?? Self.installationNodeID()
    }

    public func reply(to thread: ChatThread, text: String) async throws -> String {
        let requestGeneration = authenticationGeneration
        let gateway: MuseGateway
        do {
            gateway = try await connect()
        } catch let error as MuseAuthenticationError {
            throw error
        } catch let error as MusePeerTrustError {
            throw error
        } catch {
            // URLSession/WebSocket errors can contain the credential-bearing
            // connection URL. Expose a safe summary to the UI instead.
            throw authenticationGeneration == requestGeneration
                ? MuseGatewayChatTransportError.authenticationFailed
                : MuseGatewayChatTransportError.requestInvalidated
        }
        let gatewayID = UUID()
        activeGateways[gatewayID] = gateway
        defer { activeGateways[gatewayID] = nil }
        do {
            try requireCurrentGeneration(requestGeneration)
            let result = try await send(
                text,
                to: thread,
                using: gateway,
                generation: requestGeneration
            )
            await gateway.close()
            try requireCurrentGeneration(requestGeneration)
            return result
        } catch let error as MuseGatewayChatTransportError {
            await gateway.close()
            throw error
        } catch {
            await gateway.close()
            // Do not surface lower-level WebSocket errors that may include
            // the credential-bearing URL.
            throw authenticationGeneration == requestGeneration
                ? MuseGatewayChatTransportError.chatRequestFailed
                : MuseGatewayChatTransportError.requestInvalidated
        }
    }

    /// Clears credentials and local conversation mappings after sign-out or
    /// when the authenticated owner changes.
    public func clearAuthentication() async {
        authenticationGeneration &+= 1
        sessionIDsByThread.removeAll()
        let gateways = Array(activeGateways.values)
        activeGateways.removeAll()
        for gateway in gateways {
            await gateway.close()
        }
        await sessionValidator.clear()
        await admissionProvider.clear()
    }

    private func connect() async throws -> MuseGateway {
        _ = try await sessionValidator.validate()
        let gatewayConfiguration: MuseGateway.Config
        if let preauthorized = configuration.preauthorizedGateway {
            guard preauthorized.vmID == configuration.vmID else {
                throw MuseAuthenticationError.invalidGatewayAddress
            }
            // The browser's live connection uses a credential-bearing URL
            // directly. Preserve its query shape instead of trying to mint a
            // second admission token through the failing HTTP endpoint.
            gatewayConfiguration = MuseGateway.Config(url: preauthorized.url, appID: "hatch-web")
        } else {
            let admission = try await admissionProvider.get(
                gatewayAddress: configuration.gatewayAddress,
                vmID: configuration.vmID,
                vmName: configuration.vmName
            )
            gatewayConfiguration = try MuseGateway.Config(
                admission: admission,
                vmID: configuration.vmID
            )
        }
        let wakeProvider = vmWakeProvider
        let vmID = configuration.vmID
        let verifier = configuration.verifyPeer
        do {
            return try await MuseGateway.connect(
                config: gatewayConfiguration,
                prepareConnection: { _ = try await wakeProvider.wake(vmID: vmID) },
                verify: verifier
            )
        } catch let error as MuseAuthenticationError {
            throw error
        } catch {
            throw MuseGatewayChatTransportError.connectionFailed
        }
    }

    private func send(
        _ text: String,
        to thread: ChatThread,
        using gateway: MuseGateway,
        generation: UInt64
    ) async throws -> String {
        var remoteSessionID = sessionIDsByThread[thread.id]
        let body = MuseChatTextRequest(
            message: text,
            nodeID: nodeID,
            sessionID: remoteSessionID
        )
        let records = await gateway.subscribe("/chat/stream", body: body)
        var assistantText: String?

        for try await record in records {
            try requireCurrentGeneration(generation)
            let value: JSONValue
            switch record {
            case .acknowledged(let acknowledgement):
                value = acknowledgement
            case .event(let event):
                value = event
            }

            if let sessionID = MuseChatProtocol.sessionID(in: value) {
                remoteSessionID = sessionID
                sessionIDsByThread[thread.id] = sessionID
            }

            if case .event(let event) = record,
               MuseChatProtocol.isCompletionEvent(event) {
                assistantText = MuseChatProtocol.completionText(in: event)
                break
            }
        }

        try requireCurrentGeneration(generation)
        if let assistantText { return assistantText }
        guard let remoteSessionID,
              let path = MuseChatProtocol.historyPath(sessionID: remoteSessionID) else {
            throw MuseGatewayChatTransportError.sessionIDMissing
        }
        let history = try await gateway.request("GET", path)
        try requireCurrentGeneration(generation)
        if let history,
           let assistantText = MuseChatProtocol.latestAssistantText(in: history) {
            return assistantText
        }
        throw MuseGatewayChatTransportError.assistantReplyMissing
    }

    private func requireCurrentGeneration(_ generation: UInt64) throws {
        guard authenticationGeneration == generation else {
            throw MuseGatewayChatTransportError.requestInvalidated
        }
    }

    private static func installationNodeID() -> String {
        let key = "ai.muse.research.watch.node-id"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
