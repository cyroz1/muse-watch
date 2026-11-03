# Muse chat protocol: working notes

These findings come from the captured Muse web client. They describe an undocumented, version-dependent protocol. On November 3, 2026, the experimental client completed a live handshake, fetched history, sent one test message in a separate session, and fetched the assistant reply. No account credentials are included.

## Connection at a glance

```text
Authenticated Muse session
  └─ POST /api/hatch/token → admission token (+ possible notary token)
       └─ WSS /v1/noise → Noise XX handshake and applicable trust checks
            └─ encrypted protobuf frames → gateway request / response streams
                 ├─ POST /chat/stream → submit message and receive acknowledgement
                 ├─ POST /chat/subscribe → ongoing chat events
                 └─ GET /chat/history → retrieve messages and assistant replies
```

The gateway paths shown inside the connection are carried by the encrypted WebSocket, not ordinary public HTTP calls. The live test exercised token reuse, handshake, message submission and history retrieval; subscription reconnection and token renewal remain unverified.

## Authentication and connection

The browser session requests an admission credential from `POST https://muse.ai/api/hatch/token`, using a JSON body with `vmAddress` and optionally `vmName` and `force_refresh`. The response includes `token`, and may include `notary_token`. The client connects to `wss://hatch.metaaivm.com/v1/noise` using query parameters including `vm_id`, `auth_token`, `app_id`, and `request_id`. These URLs are sensitive because they include an authentication token.

The Noise handshake is `Noise_XX_25519_AESGCM_SHA256`. The client creates an ephemeral X25519 key, sends handshake message 1, receives and decrypts message 2, performs the applicable VM trust and attestation checks, then sends message 3 and splits the transport keys. The observed standard-VM branch checks local downgrade expectations; it does not necessarily perform confidential-VM attestation. For a confidential VM the server may supply an owner recovery-verification challenge; the browser constructs a client proof using recovery credentials. A client must preserve these trust checks, not simply accept an arbitrary server key.

## Encrypted gateway frames

The attached `muse-noise-descriptors.pb` is a protobuf `FileDescriptorSet` directly extracted from the client, containing `noise_transport.proto` and `noise_envelope.proto`. It provides field numbers and types for these layers:

1. `ApplicationRequest`: HTTP verb, path, repeated headers, body bytes and `end_body`.
2. `ServiceFrame`: numeric stream ID and a request, response, body chunk or reset.
3. `ServiceRequest`: service selector and serialized `ServiceFrame`.
4. `NoiseTransportFrame`: chunk ID, chunk index, total chunks and serialized service request fragment.
5. Each serialized chunk is encrypted with the established Noise transport cipher and sent as a binary WebSocket message. The client limits chunks to 65,489 payload bytes and 256 chunks per message.

The response reverses this process: decrypt the WebSocket message, reassemble `NoiseTransportFrame` chunks, decode `ServiceResponse` and `ServiceFrame`, then dispatch response, body chunks and reset by stream ID. Stream IDs begin at 1 and increment for requests in the observed implementation. The browser uses empty associated data for transport encryption.

### Protobuf field map

| Message | Fields (number: name) |
|---|---|
| `NoiseTransportFrame` | 1: `chunk_id`, 2: `chunk_index`, 3: `total_chunks`, 4: `payload` |
| `ServiceRequest` | 1: `service`, 2: `payload` |
| `ServiceResponse` | 1: `payload` |
| `ServiceFrame` | 1: `stream_id`; one of 2: `request`, 3: `response`, 4: `body_chunk`, 5: `reset` |
| `ApplicationRequest` | 1: `verb`, 2: `path`, 3: `headers`, 4: `body`, 5: `end_body` |
| `ApplicationResponse` | 1: `status`, 2: `headers`, 3: `body`, 4: `end_body` |
| `BodyChunk` | 1: `data`, 2: `end_body` |

The descriptor file includes exact protobuf types and enum definitions. Responses use `ServiceResponse` rather than `ServiceRequest` at the outer service layer.

## Chat operations

The route table maps `chat.history` to `GET /chat/history`, `chat.stream` to `POST /chat/stream`, `chat.stream_events` to `POST /chat/stream-events`, and `chat.subscribe` to `POST /chat/subscribe`. The latter three are marked as Noise-only subscriptions. These are gateway routes inside encrypted frames, not proven direct HTTPS endpoints.

The normal text composer calls `chat.stream` with a JSON body shaped like:

```json
{
  "message": "Hello",
  "node_id": "<device ID>",
  "capabilities": ["hotel_results", "chat_cancel", "delta_stream", "custom_reactions", "custom_reactions_facebook_thumbs_up_v1"],
  "timezone": "America/New_York"
}
```

Depending on context the client also supplies `session_id`, `client_ip`, reply parameters, modality, and other optional fields. The timezone above is an example; the browser uses its local timezone. Requests carry a fresh `x-request-id` UUID. For messages with attachments the client uses an `items` array instead of the simple `message` field. A separate command path also uses text items.

To subscribe on the main chat the client sends `chat.subscribe` with `after_stream_seq` and `after_chat_event_seq` cursor numbers (zero on first subscription), and the capabilities above plus `voice_reply_captions` and `voice_user_live_transcript`. Thread subscriptions add `session_id`. A successful subscription response is expected to contain fields including `agent_id`, `conn_id`, and optionally `session_id` and `capabilities`. The implementation accumulates response body bytes as UTF-8 and parses newline-delimited JSON records, preserving incomplete lines across body chunks; the first record can be an acknowledgement or an event envelope. Subsequent parsed records are dispatched to the gateway message handler. `chat.history` is used with `limit`, and optionally `before_seq` or `after_seq`; its response contains `chat_events` and `has_more`.

The implementation adds `Content-Type: application/json` for JSON requests, an `x-request-id` if absent, `x-app-id: hatch-web`, and `Accept-Language`; precise subscription record semantics still require verification. It UTF-8 encodes non-GET JSON bodies.

## watchOS port (baseline)

`MuseKit` is a Swift package containing a watchOS-compatible port of the verified client core: Noise XX with CryptoKit, the protobuf frame codec, chunking/reassembly, and a gateway actor over `URLSessionWebSocketTask`. `tools/genvectors.mjs` produces deterministic vectors from the Node prototype (fixed invented keys only); `swift run MuseKitChecks` replays them and checks handshake bytes, transport ciphertexts, request framing and response decoding. This proves byte-level parity with the prototype that passed the live test, not live interoperability from Swift: no Swift handshake has been run against Muse yet.

`WatchApp/` contains a baseline SwiftUI app whose look follows the native Apple Watch Messages app (thread list with monogram avatars, green outgoing and grey incoming bubbles, centered timestamps, quick replies, typing indicator, dictation-ready composer). It uses a demo transport. The UI has not been compiled here because only Command Line Tools are installed; building requires Xcode and a watchOS simulator or device.

## Remaining work

- Implement and test token acquisition and refresh using a normal authenticated session and secure local storage. The live test reused a captured admission token; its lifetime and refresh behavior remain unknown.
- Complete server/VM identity and attestation validation. The live experiment recognized the same standard-format response observed in the browser; it did not independently authenticate a pinned Noise peer or implement confidential VM attestation.
- Live request framing, the text-send payload, node ID and a new session ID were accepted. Verify expiration and reconnect behavior across multiple sessions.
- A live subscription replay returned an acknowledgement, the user message and assistant completion. Verify incremental live deltas and reconnect behavior.
- Run the Swift client against Muse using a freshly captured admission URL (not the reused token from the Node test) and confirm CryptoKit framing matches the live gateway.
- Wire `MuseGateway` into the watch app behind a `ChatTransport`, replacing the demo transport, and build/run the UI in Xcode.
- The companion `muse_codec.py` implements protobuf framing only; it has no encryption, authentication or networking. Its local synthetic round-trip checks are not a live interoperability test.

## Experimental Noise implementation

`muse_noise.mjs` implements the Noise XX initiator using Node's cryptographic primitives. A local synthetic responder completed a three-message handshake, exchanged encrypted messages in both directions, and verified that corrupted ciphertext is rejected. This is a local test, not proof of interoperability with Muse. The implementation requires a caller-supplied peer-verification callback before message 3; it does **not** implement Muse's VM identity, attestation, recovery verification, login, or WebSocket connection, and must not be used to skip those protections.

The browser checks for a confidential-to-standard downgrade using its locally stored VM identity. For confidential VMs it can verify AMD SEV-SNP attestation, including the server static key, freshness nonce, chip authorization and expected host data when applicable. These checks depend on account and VM state and remain unimplemented in the experimental code.

`muse_gateway.mjs` connects the experimental Noise implementation to protobuf framing and WebSocket request/response handling. It requires an already-authorized gateway URL and a caller-supplied verifier that implements the appropriate server/VM checks and any recovery proof. It defaults the app ID to `hatch-web` and generates a nonce-based handshake hello; credentials and verification are not obtained automatically. Its JavaScript request encoder and response decoder were checked against the independently decoded protobuf descriptors using Python; the gateway was exercised against Muse for a standard-format handshake, history, and one test message. The subscription interface returns when a stream ends and reports newline-delimited JSON records via a callback. This is a research prototype, not a finished chat application.

## Additional handshake details

The captured gateway URLs use app ID `hatch-web`, consistent with the web client's default. The ordinary browser client creates a fresh random 32-byte client nonce and sends it in message 1 as protobuf field 1 (`0a 20` followed by 32 bytes). The two captured connections each have a 66-byte first handshake message, consistent with a 32-byte ephemeral public key followed by that 34-byte payload. Their third handshake messages are 64 bytes, consistent with an empty message-3 payload; this alone does not establish the VM's trust state or prove that a future connection will do the same.

For a provisioned confidential VM, message 2's owner challenge carries an attestation, state, 32-byte VM nonce, 32-byte VM proof and optionally chip binding. After verifying attestation, the client authenticates the VM proof using an account recovery-verification key, derives a client proof, and sends that proof with a notary token in the encrypted third handshake message. `muse_confidential_proof.mjs` implements this provisioned proof calculation when the caller supplies the correct verified inputs. Its HMAC output was checked against an independent Python calculation, including rejection of an altered VM proof. It does not perform attestation, obtain or store the RV key, handle unprovisioned enrollment, or validate a live connection.

## Live back-and-forth result

A direct client connected to the gateway with the admission URL from the Chrome capture. It used a fresh request ID and nonce, completed the Noise XX exchange, and fetched three existing events. It then sent the harmless prompt `Connectivity test: please reply with the word ready.` in a newly generated session. The gateway accepted the request and returned a stream acknowledgement with `message_id`, `reply_to_message_id`, and `session_id`. A later `GET /chat/history?limit=20&session_id=...` returned two events with user and assistant roles; the assistant reply contained “ready”. History is wrapped as `{ "ok": true, "result": { "chat_events": [...], "has_more": false, ... } }`.

The experiment reused the browser capture admission URL and followed the observed standard-VM path. Its verifier only checked the observed message-2 format; this is not an independent static-key pin or confidential-attestation verifier. Do not use it for confidential VMs, and do not infer that the captured token will remain valid. The test created one separate Muse chat session.

## Verified subscription replay

Using the separate test session, `POST /chat/subscribe` with zero cursors returned newline-delimited records. The initial record was `{type: "res", id, status, payload}` with `payload.subscribed: true` and session, connection, capability and channel metadata. Subsequent records had `{type: "event", event, payload, seq, ts_ms}`. Observed event names included `model_lock.updated`, `agent.status`, `task.status`, `approvals.snapshot`, `message.user`, and `delta.message_done`. The completion payload included `message_id`, `reply_to_message_id`, `session_id`, `status`, and `transcript` among other fields. This confirms replay and completion-event delivery, not yet incremental streaming, reconnect recovery, or a stable public contract.

The JavaScript gateway prototype exposes `subscribe(path, body, onEvent)`, returning separate `ack` and `finished` promises. The helper successfully received the live acknowledgement and assistant completion event.

## Admission credential refresh

The web client holds admission credentials in an in-memory cache scoped by gateway URL and VM name. It looks for a `timeout:` restriction in the notary token and refreshes when that timestamp is less than 60 seconds away; a forced refresh sends `force_refresh: true` to `/api/hatch/token`. A notary value prefixed `delegation.` is endorsed for the gateway and `/v1/noise` before use. The captured endorsement contained timeout, hostname, and URI-prefix restrictions. Its contents and expiration are sensitive and are not included here.

`muse_admission.mjs` is an experimental implementation of this observed cache and endpoint request. It takes an authenticated fetch function and, for delegation tokens, a caller-supplied endorser; it does not sign users in, acquire browser cookies, or implement endorsement. Its behavior has synthetic tests only and is not a live authentication or renewal test.

## Reconnection observation

A live test subscribed to the separate test session with both cursors at zero, recorded the maximum observed stream sequence and the message/chat sequence, disconnected, and subscribed again with those cursors. The resumed subscription sent new state snapshots and replayed the earlier `message.user` event even though its chat sequence was below the supplied cursor. The earlier `delta.message_done` was not repeated in this run. Thus, cursors do not establish an exactly-once delivery guarantee; clients should reconcile repeated message events using stable message IDs and event semantics. Snapshot records can have sequence numbers higher than message events. This is one observed session, not a complete specification of replay or out-of-order delivery.
