import CryptoKit
import Foundation

public enum NoiseError: Error, Equatable, CustomStringConvertible {
    case wrongPhase
    case shortHandshake(String)
    case peerVerificationRequired
    case cipherUnavailable
    case allZeroSharedSecret

    public var description: String {
        switch self {
        case .wrongPhase: return "Noise handshake called in the wrong phase"
        case .shortHandshake(let detail): return "Short Noise handshake message: \(detail)"
        case .peerVerificationRequired: return "Peer verification is required before message 3"
        case .cipherUnavailable: return "Noise cipher unavailable"
        case .allZeroSharedSecret: return "All-zero shared secret"
        }
    }
}

public struct NoiseKeyPair {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKeyRaw: Data

    public init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = key
        self.publicKeyRaw = key.publicKey.rawRepresentation
    }

    /// Fixed-key initializer for deterministic tests only.
    public init(privateKeyRaw: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        self.privateKey = key
        self.publicKeyRaw = key.publicKey.rawRepresentation
    }
}

public struct NoiseHello {
    public let payload: Data
    public let serverStaticPublicKey: Data
    public let handshakeHash: Data
}

public final class NoiseTransport {
    let sendCipher: NoiseCipherState
    let receiveCipher: NoiseCipherState

    init(sendCipher: NoiseCipherState, receiveCipher: NoiseCipherState) {
        self.sendCipher = sendCipher
        self.receiveCipher = receiveCipher
    }

    public func encrypt(_ data: Data) throws -> Data {
        try sendCipher.encrypt(associatedData: Data(), data)
    }

    public func decrypt(_ data: Data) throws -> Data {
        try receiveCipher.decrypt(associatedData: Data(), data)
    }
}

final class NoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var failed = false

    init(key: Data? = nil) {
        if let key { self.key = SymmetricKey(data: key) }
    }

    private func nextNonce() throws -> AES.GCM.Nonce {
        guard !failed, nonce < UInt64.max else { throw NoiseError.cipherUnavailable }
        var iv = Data(repeating: 0, count: 12)
        withUnsafeBytes(of: nonce.bigEndian) { raw in
            iv.replaceSubrange(4..<12, with: raw)
        }
        nonce += 1
        return try AES.GCM.Nonce(data: iv)
    }

    func encrypt(associatedData: Data, _ plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nextNonce(), authenticating: associatedData)
            return sealed.ciphertext + sealed.tag
        } catch {
            failed = true
            throw error
        }
    }

    func decrypt(associatedData: Data, _ ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        do {
            guard ciphertext.count >= 16 else { throw NoiseError.shortHandshake("ciphertext") }
            let box = try AES.GCM.SealedBox(
                nonce: nextNonce(),
                ciphertext: ciphertext.dropLast(16),
                tag: ciphertext.suffix(16)
            )
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            failed = true
            throw error
        }
    }
}

private func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

private func hmac(_ key: Data, _ data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

private func hkdf(_ chainingKey: Data, _ input: Data) -> (chainingKey: Data, key: Data) {
    let temp = hmac(chainingKey, input)
    let first = hmac(temp, Data([1]))
    let second = hmac(temp, first + Data([2]))
    return (first, second)
}

private func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKeyRaw: Data) throws -> Data {
    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyRaw)
    let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    let data = secret.withUnsafeBytes { Data($0) }
    guard data.contains(where: { $0 != 0 }) else { throw NoiseError.allZeroSharedSecret }
    return data
}

/// Noise XX initiator for `Noise_XX_25519_AESGCM_SHA256`. Callers must verify
/// the peer between `message2` and `message3`; this type never skips that step.
public final class NoiseXXInitiator {
    private let keyFactory: () -> NoiseKeyPair
    private var symmetric: SymmetricState
    private var phase = 0
    private var ephemeral: NoiseKeyPair?
    private var remoteEphemeral: Data?
    public private(set) var message1Hash: Data?

    public init(keyFactory: (() -> NoiseKeyPair)? = nil) {
        self.keyFactory = keyFactory ?? { NoiseKeyPair() }
        self.symmetric = SymmetricState()
    }

    public func message1(payload: Data = Data()) throws -> Data {
        guard phase == 0 else { throw NoiseError.wrongPhase }
        let key = keyFactory()
        ephemeral = key
        symmetric.mixHash(key.publicKeyRaw)
        let result = key.publicKeyRaw + (try symmetric.encryptAndHash(payload))
        message1Hash = symmetric.handshakeHash
        phase = 1
        return result
    }

    public func message2(_ message: Data) throws -> NoiseHello {
        guard phase == 1, let ephemeral else { throw NoiseError.wrongPhase }
        guard message.count >= 96 else { throw NoiseError.shortHandshake("message 2 is \(message.count) bytes") }
        do {
            let remoteEphemeral = message.subdata(in: 0..<32)
            self.remoteEphemeral = remoteEphemeral
            symmetric.mixHash(remoteEphemeral)
            symmetric.mixKey(try dh(ephemeral.privateKey, remoteEphemeral))
            let remoteStatic = try symmetric.decryptAndHash(message.subdata(in: 32..<80))
            symmetric.mixKey(try dh(ephemeral.privateKey, remoteStatic))
            let payload = try symmetric.decryptAndHash(message.subdata(in: 80..<message.count))
            phase = 2
            return NoiseHello(
                payload: payload,
                serverStaticPublicKey: remoteStatic,
                handshakeHash: symmetric.handshakeHash
            )
        } catch {
            phase = -1
            throw error
        }
    }

    /// Encrypts the third handshake message and returns the transport cipher
    /// pair. The caller must have verified the `NoiseHello` first.
    public func message3(payload: Data = Data()) throws -> (message: Data, transport: NoiseTransport) {
        guard phase == 2, let remoteEphemeral else { throw NoiseError.wrongPhase }
        do {
            let localStatic = keyFactory()
            let first = try symmetric.encryptAndHash(localStatic.publicKeyRaw)
            symmetric.mixKey(try dh(localStatic.privateKey, remoteEphemeral))
            let last = try symmetric.encryptAndHash(payload)
            let (firstKey, secondKey) = symmetric.split()
            phase = 3
            return (
                first + last,
                NoiseTransport(
                    sendCipher: NoiseCipherState(key: firstKey),
                    receiveCipher: NoiseCipherState(key: secondKey)
                )
            )
        } catch {
            phase = -1
            throw error
        }
    }
}

private final class SymmetricState {
    private(set) var handshakeHash = Data()
    private var chainingKey = Data()
    private var cipher = NoiseCipherState()

    init() {
        var name = Data("Noise_XX_25519_AESGCM_SHA256".utf8)
        name.append(Data(repeating: 0, count: 32 - name.count))
        handshakeHash = name
        chainingKey = name
        mixHash(Data())
    }

    func mixHash(_ data: Data) {
        handshakeHash = sha256(handshakeHash + data)
    }

    func mixKey(_ input: Data) {
        let derived = hkdf(chainingKey, input)
        chainingKey = derived.chainingKey
        cipher = NoiseCipherState(key: derived.key)
    }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(associatedData: handshakeHash, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(associatedData: handshakeHash, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (Data, Data) {
        let derived = hkdf(chainingKey, Data())
        return (derived.chainingKey, derived.key)
    }
}
