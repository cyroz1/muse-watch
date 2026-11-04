import CryptoKit
import Foundation

/// The handshake payload type observed by the Muse web client. Confidential
/// owner challenges need SNP attestation and recovery-key proof, which this
/// package does not implement. They are rejected before Noise message 3.
public enum MuseObservedVMType: String, Codable, Sendable {
    case standard
    case confidential
}

public enum MusePeerTrustError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidIdentity
    case invalidServerKey
    case malformedOwnerChallenge
    case confidentialVMUnsupported
    case firstUseApprovalRequired
    case peerKeyChanged
    case peerTypeChanged
    case pinStoreUnavailable

    public var description: String {
        switch self {
        case .invalidIdentity: return "Muse owner or VM identity is invalid"
        case .invalidServerKey: return "Muse returned an invalid server key"
        case .malformedOwnerChallenge: return "Muse returned a malformed VM owner challenge"
        case .confidentialVMUnsupported: return "Confidential Muse VMs need attestation and recovery-key verification"
        case .firstUseApprovalRequired: return "Trust this VM's first server key before connecting"
        case .peerKeyChanged: return "Muse's server key changed for this VM"
        case .peerTypeChanged: return "Muse's VM security type changed"
        case .pinStoreUnavailable: return "Muse VM trust could not be saved securely"
        }
    }

    public var errorDescription: String? { description }
}

/// A local trust record binds one Muse account and VM to a standard-VM
/// server key. It contains only a SHA-256 fingerprint, never a secret key.
public struct MusePeerPin: Equatable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let ownerID: String
    public let vmID: String
    public let observedType: MuseObservedVMType
    public let serverKeyFingerprint: Data

    public init(ownerID: String, vmID: String, observedType: MuseObservedVMType, serverKeyFingerprint: Data) {
        self.ownerID = ownerID
        self.vmID = vmID
        self.observedType = observedType
        self.serverKeyFingerprint = serverKeyFingerprint
    }

    public var description: String { "MusePeerPin(owner: <redacted>, vm: <redacted>, key: <redacted>)" }
    public var debugDescription: String { description }
}

/// Implement with secure local storage. `saveFirstUse` must never replace an
/// existing record; a concurrent first connection is resolved by re-reading
/// the stored pin and comparing it with the candidate.
public protocol MusePeerPinStore: Sendable {
    func load(ownerID: String, vmID: String) async throws -> MusePeerPin?
    func saveFirstUse(_ pin: MusePeerPin) async throws
}

/// Standard-VM verifier with account/VM-scoped key pinning. A caller may
/// permit first-use pinning only after an explicit trust decision. Later
/// connections must match the pinned server key and observed VM type.
public struct MuseStandardPeerVerifier: Sendable {
    public let ownerID: String
    public let vmID: String
    public let allowFirstUse: Bool
    private let pinStore: any MusePeerPinStore

    public init(
        ownerID: String,
        vmID: String,
        allowFirstUse: Bool,
        pinStore: any MusePeerPinStore
    ) {
        self.ownerID = ownerID
        self.vmID = vmID
        self.allowFirstUse = allowFirstUse
        self.pinStore = pinStore
    }

    /// Verifies the observed VM class, rejects confidential or malformed
    /// owner challenges, and checks/pins the server static key before the
    /// caller can send Noise message 3.
    public func verify(_ hello: MuseGateway.Hello) async throws -> Data {
        guard Self.validIdentity(ownerID), Self.validIdentity(vmID) else {
            throw MusePeerTrustError.invalidIdentity
        }
        guard hello.serverStaticPublicKey.count == 32 else {
            throw MusePeerTrustError.invalidServerKey
        }

        let observedType = try Self.classify(hello.payload)
        guard observedType == .standard else {
            throw MusePeerTrustError.confidentialVMUnsupported
        }

        let fingerprint = Data(SHA256.hash(data: hello.serverStaticPublicKey))
        let candidate = MusePeerPin(
            ownerID: ownerID,
            vmID: vmID,
            observedType: observedType,
            serverKeyFingerprint: fingerprint
        )

        let loadedPin: MusePeerPin?
        do {
            loadedPin = try await pinStore.load(ownerID: ownerID, vmID: vmID)
        } catch {
            throw MusePeerTrustError.pinStoreUnavailable
        }
        if let existing = loadedPin {
            try Self.requireMatch(existing, candidate)
            return Data()
        }

        guard allowFirstUse else { throw MusePeerTrustError.firstUseApprovalRequired }
        do {
            try await pinStore.saveFirstUse(candidate)
        } catch {
            // Another connection can win the initial pin race. Accept only if
            // its durable record is byte-for-byte the same trust decision.
            guard let raced = try? await pinStore.load(ownerID: ownerID, vmID: vmID) else {
                throw MusePeerTrustError.pinStoreUnavailable
            }
            try Self.requireMatch(raced, candidate)
        }
        guard let saved = try? await pinStore.load(ownerID: ownerID, vmID: vmID) else {
            throw MusePeerTrustError.pinStoreUnavailable
        }
        try Self.requireMatch(saved, candidate)
        return Data()
    }

    /// Mirrors the current web-client owner challenge envelope: field 1 is
    /// attestation, field 2 is state (1 unprovisioned, 2 provisioned), field
    /// 3 is a 32-byte VM nonce, field 4 is the optional 32-byte VM proof, and
    /// field 5 is optional chip binding. Opaque standard-VM payloads remain
    /// standard; recognizable but malformed owner challenges fail closed.
    public static func classify(_ payload: Data) throws -> MuseObservedVMType {
        guard !payload.isEmpty else { return .standard }

        var offset = 0
        var challengeHint = false
        var attestation: Data?
        var state: UInt64?
        var vmNonce: Data?
        var vmProof: Data?
        var chipBinding: Data?

        do {
            while offset < payload.count {
                let tag = try readVarint(payload, offset: &offset)
                let field = Int(tag >> 3)
                let wire = Int(tag & 7)
                guard field > 0 else { throw ProtoDecodeError.malformed }

                switch (field, wire) {
                case (1, 2):
                    guard attestation == nil else { throw ProtoDecodeError.malformed }
                    attestation = try readBytes(payload, offset: &offset)
                case (2, 0):
                    guard state == nil else { throw ProtoDecodeError.malformed }
                    let value = try readVarint(payload, offset: &offset)
                    state = value
                    challengeHint = challengeHint || value == 1 || value == 2
                case (3, 2):
                    guard vmNonce == nil else { throw ProtoDecodeError.malformed }
                    challengeHint = true
                    vmNonce = try readBytes(payload, offset: &offset)
                    challengeHint = challengeHint || vmNonce?.count == 32
                case (4, 2):
                    guard vmProof == nil else { throw ProtoDecodeError.malformed }
                    challengeHint = true
                    vmProof = try readBytes(payload, offset: &offset)
                    challengeHint = challengeHint || vmProof?.count == 32
                case (5, 2):
                    guard chipBinding == nil else { throw ProtoDecodeError.malformed }
                    challengeHint = true
                    chipBinding = try readBytes(payload, offset: &offset)
                default:
                    try skipValue(payload, offset: &offset, wire: wire)
                }
            }
        } catch {
            if challengeHint { throw MusePeerTrustError.malformedOwnerChallenge }
            return .standard
        }

        guard challengeHint else { return .standard }
        guard let attestation, !attestation.isEmpty,
              let state, state == 1 || state == 2,
              let vmNonce, vmNonce.count == 32 else {
            throw MusePeerTrustError.malformedOwnerChallenge
        }
        if state == 1, vmProof != nil {
            throw MusePeerTrustError.malformedOwnerChallenge
        }
        if state == 2, vmProof?.count != 32 {
            throw MusePeerTrustError.malformedOwnerChallenge
        }
        _ = chipBinding
        return .confidential
    }

    private static func requireMatch(_ existing: MusePeerPin, _ candidate: MusePeerPin) throws {
        guard existing.ownerID == candidate.ownerID, existing.vmID == candidate.vmID else {
            throw MusePeerTrustError.invalidIdentity
        }
        guard existing.observedType == candidate.observedType else {
            throw MusePeerTrustError.peerTypeChanged
        }
        guard constantTimeEqual(existing.serverKeyFingerprint, candidate.serverKeyFingerprint) else {
            throw MusePeerTrustError.peerKeyChanged
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf16.count <= 255 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    private enum ProtoDecodeError: Error { case malformed }

    private static func readVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift < 64 {
            let byte = data[offset]
            offset += 1
            if shift == 63, byte > 1 { throw ProtoDecodeError.malformed }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoDecodeError.malformed
    }

    private static func readBytes(_ data: Data, offset: inout Int) throws -> Data {
        let length = try readVarint(data, offset: &offset)
        guard length <= UInt64(data.count - offset) else { throw ProtoDecodeError.malformed }
        let end = offset + Int(length)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    private static func skipValue(_ data: Data, offset: inout Int, wire: Int) throws {
        switch wire {
        case 0: _ = try readVarint(data, offset: &offset)
        case 1:
            guard offset <= data.count - 8 else { throw ProtoDecodeError.malformed }
            offset += 8
        case 2:
            _ = try readBytes(data, offset: &offset)
        case 5:
            guard offset <= data.count - 4 else { throw ProtoDecodeError.malformed }
            offset += 4
        default:
            throw ProtoDecodeError.malformed
        }
    }
}
