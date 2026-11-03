# Muse Watch research

Research toward an Apple Watch client for Muse. Two clients now exist:

- **Node.js prototype** — completed a live Noise handshake, fetched history, sent a test message, received the assistant reply, and replayed subscription events.
- **`MuseKit` Swift package** — a watchOS-compatible port of the verified protocol core (Noise XX with CryptoKit, protobuf framing, WebSocket gateway, subscriptions), checked byte-for-byte against vectors generated from the Node prototype.
- **`WatchApp/`** — a baseline watchOS app shell whose chat UI mirrors the native Apple Watch Messages app. It currently uses a demo transport; the gateway is not wired in yet.

See [protocol notes](muse-protocol-notes.md) for the observed connection, data structures, tests, and limitations. The files in this repository contain no captured browser traffic or account credentials.

The project does not implement Muse sign-in, admission-token renewal, or confidential-VM attestation. A test reused a captured browser admission credential and checked the format of the standard VM response; that check is not independent cryptographic verification of the peer. Do not use this prototype for confidential VMs or treat it as production-ready.

## Local checks

Node:

```sh
node tests/noise.test.mjs       # synthetic Noise handshake and encryption
node tests/admission.test.mjs   # admission cache, refresh, delegation
node tools/genvectors.mjs       # regenerate Swift test vectors (self-checking)
```

Swift (works with Command Line Tools; no Xcode required):

```sh
swift run MuseKitChecks         # 37 cross-implementation checks
```

The checks replay deterministic vectors from the Node prototype: handshake messages, transport ciphertexts, a framed `GET /chat/history` request, and a response stream. `muse_codec.py` also requires the Python `protobuf` package; its extracted descriptor set is included.

The watch UI itself needs Xcode; see [WatchApp/README.md](WatchApp/README.md) for build instructions and current limitations. CI builds the watch app and uploads a simulator screenshot as a workflow artifact.
