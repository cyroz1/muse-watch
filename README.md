# Muse Watch research

Research toward an Apple Watch client for Muse. Two clients now exist:

- **Node.js prototype** — completed a live Noise handshake, fetched history, sent a test message, received the assistant reply, and replayed subscription events.
- **`MuseKit` Swift package** — a watchOS-compatible port of the protocol core (Noise XX with CryptoKit, protobuf framing, WebSocket gateway, subscriptions), plus source-derived session/admission helpers and the provisioned owner-proof calculation. The protocol core is checked byte-for-byte against Node-generated vectors.
- **`WatchApp/`** — a watchOS app shell whose chat UI follows the native Apple Watch Messages app. Its debug simulator flow now wires an existing Muse web session to admission, VM wake, a peer-verification gate, and encrypted text chat. The normal app path still uses `DemoTransport`.

See [protocol notes](muse-protocol-notes.md) for the observed connection, data structures, tests, and limitations. The files in this repository contain no captured browser traffic or account credentials.

See [authentication and chat transport](muse-auth-chat-protocol.md) for the browser-session check, Hatch admission-token flow, WebSocket query parameters, and chat request/response shapes. It distinguishes what the supplied HAR proves from behavior found only in its bundled client code.

This is still research software. Muse has no established Watch sign-in/session handoff in the evidence collected here. The debug simulator can validate an existing web-session Cookie header and accept a caller-supplied current gateway token or WebSocket URL, stored in device-local Keychain and scoped to the account and VM. Standard-VM first use requires a user decision and pins the Noise static-key fingerprint, but that first key is not independently authenticated. Confidential VMs fail closed because attestation and recovery-proof verification are incomplete. Delegation notary tokens still need an endorser. No live Watch send/receive has been verified; credential values are not stored in source or documentation.

## Local checks

Node:

```sh
node tests/noise.test.mjs       # synthetic Noise handshake and encryption
node tests/admission.test.mjs   # admission cache, refresh, delegation
node tools/genvectors.mjs       # regenerate Swift test vectors (self-checking)
```

Swift (works with Command Line Tools; no Xcode required):

```sh
swift run MuseKitChecks         # protocol and synthetic chat checks
```

The checks replay deterministic vectors from the Node prototype: handshake messages, transport ciphertexts, a framed `GET /chat/history` request, and a response stream. `muse_codec.py` also requires the Python `protobuf` package; its extracted descriptor set is included.

The watch UI itself needs Xcode; see [WatchApp/README.md](WatchApp/README.md) for build instructions and current limitations. CI builds the watch app and uploads a simulator screenshot as a workflow artifact.
