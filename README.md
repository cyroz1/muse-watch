# Muse Watch research

Early research for an Apple Watch client for Muse. A Node.js prototype completed a live Noise handshake, sent a test message, fetched its reply, and replayed subscription events. It is not an Apple Watch app yet.

See [protocol notes](muse-protocol-notes.md) for the observed connection, data structures, tests, and limitations. The files in this repository contain no captured browser traffic or account credentials.

The prototype does not implement Muse sign-in, admission-token renewal, or confidential-VM attestation. A test reused a captured browser admission credential and checked the format of the standard VM response; that check is not independent cryptographic verification of the peer. Do not use this prototype for confidential VMs or treat it as production-ready.

## Local checks

Run `node tests/noise.test.mjs` to exercise a synthetic handshake and bidirectional encryption with Node.js. `muse_codec.py` also requires the Python `protobuf` package; its extracted descriptor set is included.
