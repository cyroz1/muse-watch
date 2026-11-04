# Project instructions for agents

These instructions apply to the entire repository. Read the relevant code and the protocol notes before changing behavior. This project studies an undocumented, version-dependent service; distinguish observations from assumptions and preserve the experimental status of the client.

## Project purpose and current state

This repository is research toward an Apple Watch client for Muse. It has three related pieces:

1. **Node.js protocol prototype** — implements experimental Noise XX, protobuf gateway framing, an admission-token helper, and a confidential-VM proof calculation. The gateway prototype has been used in a live standard-VM experiment, but does not independently establish peer trust or complete sign-in/attestation.
2. **`MuseKit` Swift package** — a watchOS-compatible port of Noise, protobuf framing, chunking/reassembly, and WebSocket gateway handling. It is checked against deterministic vectors from the Node prototype. Vector parity is not proof of live Swift interoperability.
3. **`WatchApp/`** — a SwiftUI watchOS shell with a Messages-style thread and chat screen. Normal launches use `DemoTransport`; debug simulator builds also contain an experimental Muse session and gateway path that is not live-verified end to end.

Do not describe this repository as a production client. It does not implement Muse sign-in, a supported Watch session handoff, independent server/VM trust verification, or full confidential-VM attestation.

## Read before protocol work

- [README.md](README.md) — project status and existing local commands.
- [muse-protocol-notes.md](muse-protocol-notes.md) — protocol framing, observed chat behavior, experiments, and known gaps.
- [muse-auth-chat-protocol.md](muse-auth-chat-protocol.md) — browser authentication, admission credentials, chat request shapes, evidence sources, and Watch implications.
- [WatchApp/README.md](WatchApp/README.md) — Watch build setup, UI status, and CI behavior.

Treat these notes as research records, not a stable Muse API specification. When code behavior changes, update the relevant notes and label whether the result is synthetic, source-derived, captured, or live-verified.

## Repository map

| Path | Responsibility |
|---|---|
| `Sources/MuseKit/Noise.swift` | Noise XX initiator and AES-GCM transport cipher using CryptoKit. Requires caller verification before sending message 3. |
| `Sources/MuseKit/Proto.swift` | Minimal protobuf wire codec for the fields used by this protocol; not a general protobuf library. |
| `Sources/MuseKit/Framing.swift` | Application/service frame encoding, chunking, response reassembly, and gateway frame decoding. |
| `Sources/MuseKit/Gateway.swift` | `URLSessionWebSocketTask` actor, request streams, subscription records, and error handling. Connection setup takes a caller-supplied peer verifier. |
| `Sources/MuseKit/JSONValue.swift` | Dynamic JSON representation for version-dependent gateway responses. |
| `muse_noise.mjs` | Node Noise XX implementation using Node's built-in crypto; no login or token acquisition. |
| `muse_gateway.mjs` | Node WebSocket/protobuf gateway prototype; caller must provide a pre-authorized URL and peer verifier. |
| `muse_admission.mjs` | Experimental token cache/refresh helper; caller supplies the authenticated fetch function and notary delegation endorser. |
| `muse_confidential_proof.mjs` | Provisioned owner recovery-key proof calculation. Caller must verify attestation and inputs first. |
| `muse_codec.py` | Python protobuf framing helper using the descriptor set; no encryption, auth, or networking. |
| `muse-noise-descriptors.pb` | Extracted protobuf `FileDescriptorSet` used to inspect the wire schema. Do not hand-edit it. |
| `tools/genvectors.mjs` | Generates deterministic Swift fixtures from the Node prototype using invented test keys. |
| `Checks/` | Swift command-line checks and checked-in deterministic fixtures. |
| `tests/` | Synthetic Node checks for Noise and the admission helper; they do not contact Muse. |
| `WatchApp/MuseChatUI/` | SwiftUI screens, theme, chat models, and the `ChatTransport` seam. |
| `WatchApp/MuseWatchApp.swift` | App entry point; uses `DemoTransport` normally and exposes the debug simulator setup path. |
| `WatchApp/project.yml` | XcodeGen project description. The generated Xcode project is committed separately. |
| `.github/workflows/watch.yml` | CI protocol checks and unsigned watch simulator build/screenshot job. |

There is no Node package manifest. Current Node modules use built-in APIs. `muse_codec.py` requires the Python `protobuf` package.

## Security and data handling

- Never commit a HAR, browser profile, session cookie, access token, admission token, notary token, OAuth callback URL, or private recovery key. `*.har` and `.env` are ignored, but verify `git status` before staging and never force-add captures.
- HAR files and full `wss://.../v1/noise` URLs can contain live credentials. Do not print their query values, paste them into logs, fixtures, issues, or documentation, or include them in crash reports. Use placeholders and describe only the schema.
- Captured credentials may be reused only for a user-authorized personal live test on that user's own account. Keep them in the simulator Keychain or process memory, never print or persist them in source, fixtures, logs, or docs, and clear them when the test is done. Never send a chat prompt or create a Muse session unless the user explicitly asks for a live interaction in the current task.
- Do not weaken or bypass the peer verifier to make a handshake succeed. Verify server static key, VM identity, downgrade expectations, and any required attestation before Noise message 3. A format check is not identity verification.
- Keep tests and fixtures deterministic and synthetic. Fixed keys are permitted only for fixtures; production paths must use fresh cryptographic randomness.
- Keep access tokens and recovery material out of persistent logs. Clear in-memory credentials when the session/owner changes and reject asynchronous results from an invalidated credential generation.
- Do not infer that undocumented endpoints or schemas are stable or supported. Record evidence level and uncertainty explicitly.

## Protocol implementation rules

- Preserve the Noise protocol name and handshake order: `Noise_XX_25519_AESGCM_SHA256`. Do not send message 3 before the caller's verification succeeds.
- Keep application chat routes inside encrypted protobuf frames. `/chat/history`, `/chat/stream`, and `/chat/subscribe` are gateway paths, not ordinary public Muse HTTP endpoints.
- Preserve protobuf field numbers, enum values, end-of-body markers, chunk limits, stream IDs, and response assembly behavior. Update both Node and Swift implementations together when changing shared wire behavior.
- Treat `Proto.swift` as a deliberately small codec. Add only the wire types needed by observed protocol messages; do not silently turn it into a lossy/general-purpose protobuf parser.
- `JSONValue` is dynamic because response/event payloads can change. Avoid freezing incomplete schemas or dropping unknown fields unless the caller explicitly needs a validated projection.
- Subscription responses are newline-delimited JSON and lines can cross body chunks. Preserve incomplete bytes between chunks. Reconnect cursors are not an exactly-once guarantee; reconcile messages by stable message ID.
- Keep connection-level `request_id` distinct from each inner gateway request's `x-request-id`.
- Do not change gateway/token refresh semantics based only on a synthetic test. Document whether behavior is from a HAR, bundled client source, synthetic fixture, or live call.
- Do not regenerate `Checks/Fixtures/vectors.json` merely to make a failing implementation match itself. Regenerate only when intentionally changing the reference Node protocol, then review the fixture diff and keep the keys invented.

## Swift and Watch app conventions

- The package uses Swift 5.9 and targets watchOS 10, macOS 13, and iOS 16. Keep `MuseKit` free of SwiftUI so the protocol core remains independently buildable.
- Maintain actor/concurrency and `Sendable` boundaries in gateway code. Keep crypto state and stream IDs scoped to a single connection; fail pending requests when the socket closes or decryption/framing fails.
- Keep UI transport behind `ChatTransport`. Do not put authentication, token parsing, Noise, or protobuf code directly in SwiftUI views.
- Preserve the current `DemoTransport` path unless the task explicitly wires live transport. When integrating, do not embed browser cookies or captured credentials in the app.
- Preserve the small-screen interaction model: Crown scrolling through a normal `ScrollView`, accessible send controls, and clear loading/error states. Avoid custom gestures that conflict with watchOS navigation or Crown behavior.
- `WatchApp/MuseWatch.xcodeproj` is committed. Editing Swift does not require project regeneration. If `WatchApp/project.yml` changes, regenerate with XcodeGen from `WatchApp/` and review both the YAML and generated project diff.
- Keep simulator launch argument `--open-chat` working; CI uses it to capture the chat screenshot.

## Node and Python conventions

- Keep Node files as ES modules (`.mjs`) and prefer Node built-ins over new dependencies. The synthetic checks use `node:assert/strict` and should not make network calls.
- Keep the experimental modules explicit about required caller-supplied authentication and verification. Do not make missing verifier callbacks default to trust.
- Keep the Python helper focused on descriptor-backed framing. It reads the adjacent `muse-noise-descriptors.pb`; it must not acquire credentials, open sockets, or implement its own encryption.
- Keep protocol constants such as maximum chunk size consistent across Python, Node, Swift, and the docs. When a shared constant changes, inspect every implementation and fixture.

## Commands and validation

Do not add or run tests/checks unless the user asks for testing or verification. When asked, choose the narrowest relevant existing check:

```sh
node tests/noise.test.mjs
node tests/admission.test.mjs
node tools/genvectors.mjs
swift run MuseKitChecks
```

`node tools/genvectors.mjs` rewrites `Checks/Fixtures/vectors.json`; run it only when intentionally regenerating reference vectors. The Swift check works with Command Line Tools and does not build the Watch UI.

The Watch app requires Xcode 16 or later and a watchOS 10+ simulator. The documented simulator build is:

```sh
xcodebuild -project WatchApp/MuseWatch.xcodeproj -scheme MuseWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' build
```

The CI workflow runs `swift run MuseKitChecks`, builds the Watch app unsigned on macOS, and attempts simulator screenshots. Screenshot capture is best-effort; do not treat a missing screenshot as a protocol failure.

Do not use a live Muse endpoint as a routine test. A live protocol check is distinct from synthetic Node tests, Swift fixture parity, and a simulator build; report those evidence levels separately.

## Change workflow

1. Check `git status` before editing; preserve unrelated user changes.
2. Read the relevant implementation and protocol notes before changing wire or auth behavior.
3. Make the smallest coherent change and keep parallel Node/Swift behavior aligned where they implement the same protocol.
4. Update docs when evidence, limitations, or behavior changes; never copy credential values from captures.
5. Review the final diff for accidental secrets, generated artifacts, and unrelated changes. Report which checks were or were not run and any remaining live-verification limits.
