import CryptoKit
import Foundation

/// The provisioned confidential-VM owner proof calculation ported from the
/// Node prototype. It does not verify attestation or establish VM identity;
/// callers must complete those checks before calling this function.
public enum MuseConfidentialProof {
    public static func buildProvisionedProof(
        rvKey: Data,
        notaryToken: String,
        message1Hash: Data,
        message2Hash: Data,
        clientNonce: Data,
        vmNonce: Data,
        vmProof: Data,
        attestationVerified: Bool
    ) throws -> Data {
        guard attestationVerified else { throw MuseAuthenticationError.attestationNotVerified }
        try requireLength(rvKey, 32, name: "RV key")
        try requireLength(message1Hash, 32, name: "message 1 hash")
        try requireLength(message2Hash, 32, name: "message 2 hash")
        try requireLength(clientNonce, 32, name: "client nonce")
        try requireLength(vmNonce, 32, name: "VM nonce")
        try requireLength(vmProof, 32, name: "VM proof")

        let trimmedNotaryToken = notaryToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNotaryToken.isEmpty else { throw MuseAuthenticationError.missingNotaryToken }

        var vmKey = hmac(key: rvKey, message: Data("hatch.noise-auth.key.v1vm-proof-key".utf8))
        defer { wipe(&vmKey) }
        var vmProofInput = Data("hatch.noise-auth.vm-proof.v1".utf8)
        vmProofInput.append(message1Hash)
        vmProofInput.append(clientNonce)
        vmProofInput.append(vmNonce)
        var expectedVMProof = hmac(key: vmKey, message: vmProofInput)
        defer { wipe(&expectedVMProof) }
        wipe(&vmProofInput)
        guard constantTimeEqual(expectedVMProof, vmProof) else {
            throw MuseAuthenticationError.vmProofMismatch
        }

        var clientKey = hmac(key: rvKey, message: Data("hatch.noise-auth.key.v1client-proof-key".utf8))
        defer { wipe(&clientKey) }
        var clientProofInput = Data("hatch.noise-auth.client-proof.v1".utf8)
        clientProofInput.append(message2Hash)
        clientProofInput.append(vmNonce)
        clientProofInput.append(clientNonce)
        var clientProof = hmac(key: clientKey, message: clientProofInput)
        defer { wipe(&clientProof) }
        wipe(&clientProofInput)

        var payload = Proto.bytes(1, Data(trimmedNotaryToken.utf8))
        payload.append(Proto.bytes(3, clientProof))
        return payload
    }

    private static func requireLength(_ value: Data, _ expected: Int, name: String) throws {
        guard value.count == expected else {
            throw MuseAuthenticationError.invalidInputLength(name: name, expected: expected, actual: value.count)
        }
    }

    private static func hmac(key: Data, message: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    private static func wipe(_ data: inout Data) {
        if !data.isEmpty { data.resetBytes(in: 0..<data.count) }
    }
}
