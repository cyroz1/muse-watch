# Muse authentication and chat transport

Observed from the Web Inspector HAR captured on November 3, 2026, the JavaScript bundles included in that HAR, and the live-protocol notes in this repository. Muse's protocol is undocumented and can change; treat this as a versioned research record, not a supported public API contract.

The HAR is sensitive. Its two WebSocket URLs contain admission credentials, and its `/api/auth/check` response contains an access token and account/session identifiers. None of those values are reproduced here. Keep the original HAR out of source control and logs; consider invalidating the captured session credentials if the file has been shared beyond its intended private workspace.

This document separates three evidence levels:

- **HAR observed** means the request or response appears in the supplied capture.
- **Bundle observed** means the behavior is present in the web-client JavaScript shipped in that capture, whether or not that request ran during the capture.
- **Live-protocol notes** means behavior already exercised by the Node prototype described in [muse-protocol-notes.md](muse-protocol-notes.md). It is not a guarantee of a stable Muse contract.

## End-to-end flow

```text
Existing Muse browser session
  ├─ POST /api/auth/check                 validate the Muse web session
  ├─ POST /api/hatch/token                mint/reuse gateway admission (bundle observed;
  │                                         no call appears in this HAR)
  └─ WSS hatch.metaaivm.com/v1/noise      Noise XX handshake and peer verification
       └─ encrypted protobuf gateway      chat.history, chat.stream, chat.subscribe

Connection setup also calls POST /api/hatch/vm/wake for VM lifecycle management.
```

The `/chat/...` routes are gateway requests carried inside the encrypted Noise WebSocket. They are not direct `https://muse.ai/chat/...` requests.

## Keep the two authentication layers separate

The browser session and the gateway admission credential serve different purposes. Do not substitute one for the other.

| Layer | Request or value | What it does | Evidence |
|---|---|---|---|
| Muse account session | `POST https://muse.ai/api/auth/check` | Checks the browser's existing authenticated session. The web client sends browser credentials and expects a validated identity/access-token result. | HAR and bundle |
| Hatch admission | `POST https://muse.ai/api/hatch/token` | Requests a gateway `token` for a `vmAddress`, optionally scoped by `vmName`. The returned token becomes `auth_token` in the Noise WebSocket URL. | Bundle; the request itself is absent from this HAR |
| Noise notary | optional `notary_token` | Supplies the gateway/notary credential used by the handshake path. The web client resolves the token before connecting. | HAR URL keys and bundle; values redacted |
| Noise transport | `wss://hatch.metaaivm.com/v1/noise` | Authenticates the gateway connection and carries encrypted application requests. | HAR and bundle |

### Browser session validation

The HAR contains one successful `POST /api/auth/check` with status 200 and a JSON response containing `ok` (boolean), `access_token` (string), `session_binding_id` (string), `viewer_id` (string), and `outcome` (string).

The captured response values are deliberately omitted. The bundle calls this endpoint with `credentials: "include"`, `cache: "no-store"`, no request body, and a 15-second timeout. It treats `outcome: "validated"` as a valid session, requires a nonempty `access_token` and `viewer_id`, and accepts `session_binding_id` as either a string or `null`. The client keys its recent validation result by viewer and session binding and normally reuses it for up to 60 seconds. A 401/403 or a checkpoint-required response can trigger session teardown or a browser redirect.

`access_token` is the result of the Muse web-session check. It is not the `token` returned by `/api/hatch/token`, and it is not the `auth_token` query parameter used for the gateway. The HAR shows the session check but does not show a sign-in, password, passkey, OAuth, MFA, or session-renewal flow. Therefore it does not establish how a standalone Watch app should sign a user in or obtain the browser session cookie.

### Other account/session routes visible in the bundle

These routes are source-only in this capture; none appears in the HAR request list. They describe account housekeeping or recovery, not a complete sign-in flow.

| Route | Observed client behavior | Port relevance |
|---|---|---|
| `POST /api/auth/save-account` | No body; same-origin credentials and `no-store`. The component registers the signed-in account for this device once. | Not an admission-token or sign-in request. |
| `POST /api/auth/session/reset` | JSON body with `sessionBindingId`; credentials included. Used when the web client resets a session. | Session teardown only. |
| `POST /api/auth/checkpoint/terminate` | URL-encoded `destination`, `return_to`, and optional `sessionBindingId`/`checkpoint_url`; credentials included. | Checkpoint navigation/cleanup only. |
| `/api/logout` | Browser fallback, optionally with `sessionBindingId` in the query. | Session teardown only. |
| `/api/hatch/oauth/callback` | Referenced by a callback helper that reads OAuth callback parameters for an external-provider credential flow. | The capture does not establish this as Muse account sign-in. |

### Gateway admission and notary credentials

The bundled web client implements a POST to `/api/hatch/token` with a JSON body shaped as:

```json
{
  "vmAddress": "<gateway URL>",
  "vmName": "<optional VM name>",
  "force_refresh": true
}
```

`vmName` and `force_refresh` are optional; the refresh flag is sent only when requested. A successful response is expected to include `token` and may include `notary_token`. The web client caches admission material by gateway URL and VM name, and refreshes when a parseable `timeout:` restriction on the notary token is within 60 seconds of expiry. The source uses a 10-second token-request timeout and invalidates in-flight results when the gateway target changes. The HAR contains no `/api/hatch/token` entry, so this request shape and behavior come from the shipped client code, not a successful call in this capture.

The bundle also contains a credential-resolution request to `POST /api/hatch/noise-notary-token` with `{"vmName":"<VM name>"}`. It expects a nonempty `notaryToken` response and times out after 8 seconds. This request is not present in the HAR. The notary may be resolved or endorsed for the selected gateway before it is sent; the local Node `AdmissionProvider` leaves that endorsement to its caller.

The HAR contains the resulting credential names in the WebSocket query, but not a captured token-mint request. Do not assume the access token from `/api/auth/check` can mint gateway admission by itself. Reproducing the browser flow requires a supported authenticated-session mechanism for the token endpoint.

### VM wake and ancillary browser calls

The HAR records `POST /api/hatch/vm/wake` during connection setup. In this capture the WebSocket upgrade had started, then the wake request began just before the first Noise handshake frame was sent. Its JSON body has `vm_id` (string), `retry_count` (number), and `connect_attempt_id` (string). The bundle includes `connect_attempt_id` when the caller has a connection-attempt context. The response has a `status` string. The bundle uses a 10-second timeout. This is a VM lifecycle call, separate from account-session validation and the encrypted gateway protocol.

The same page also posts to `/api/hatch/stateful-sharing` without a body and receives an `enabled` boolean. This is a rollout/feature check, not a credential request. `GET /api/client-ip` returns an IP string; the chat sender may attach that as optional `client_ip` context.

## Noise WebSocket connection

The observed endpoint is:

```text
wss://hatch.metaaivm.com/v1/noise
  ?vm_id=<VM ID>
  &auth_token=<Hatch admission token>
  [&notary_token=<resolved notary token>]
  &app_id=hatch-web
  &request_id=<fresh connection request ID>
```

The browser may add `atod_token` when its `use_od=1` option is explicitly enabled. The VM identifier is derived from the selected VM or VM name and is limited to 255 characters by the client. Every credential-bearing query value is sensitive: never log the full URL, include it in crash reports, or persist it in diagnostics. The WebSocket `request_id` identifies the connection; each inner gateway request has its own `x-request-id`.

The HAR records two successful WebSocket upgrades (HTTP 101). Both are binary-only connections: one contains 230 frames and the other 10. The Web Inspector stores frame data as base64 strings. In both connections the decoded handshake sizes are 66 bytes for Noise message 1, 166 bytes for message 2, and 64 bytes for message 3. The 64-byte message 3 matches the encrypted client static key with an empty Noise payload. This capture is consistent with the standard handshake branch; it does not show a confidential-VM owner proof in message 3.

The browser uses `Noise_XX_25519_AESGCM_SHA256`. Message 1 includes a fresh 32-byte client nonce in its handshake payload. Message 2 carries the server ephemeral key, encrypted static key, and encrypted handshake payload. Before sending message 3, a client must verify the server/VM identity and perform any required trust or attestation checks. Confidential-VM flows may require attestation verification and an owner recovery-key proof in the message-3 payload. The captured empty payload is not evidence that those checks can be skipped for another VM or account.

After the handshake, all observed WebSocket frames are encrypted. The HAR does not contain the ephemeral private key needed to decrypt them. It therefore cannot reveal the exact chat request or response JSON from those frames. The chat contracts below come from the bundled client request registry/builders and the repository's separate live-protocol observations.

## Encrypted gateway request envelope

The existing framing implementation and descriptor-derived field map are documented in [muse-protocol-notes.md](muse-protocol-notes.md). At a high level, each request is JSON encoded in an `ApplicationRequest`, wrapped in a `ServiceFrame`/`ServiceRequest`, split into `NoiseTransportFrame` chunks, encrypted, and sent as a binary WebSocket message.

The browser attaches these inner request headers:

| Header | Value |
|---|---|
| `x-request-id` | Fresh UUID per gateway request |
| `x-app-id` | `hatch-web` |
| `Accept-Language` | Browser locale (the research client currently uses `en-US`) |
| `Content-Type` | `application/json` when the request has a JSON body |

The route registry marks chat operations as Noise-only. `chat.stream`, `chat.stream_events`, and `chat.subscribe` use subscription-style response streams; `chat.subscribe` has a 30-second request timeout in the captured bundle.

## Chat operations

### Load history

```http
GET /chat/history?limit=20[&session_id=<session>][&before_seq=<n>|&after_seq=<n>]
```

`limit` is used for paging; `session_id` scopes a thread when present. The live prototype has used `limit=20`. The JSON result is wrapped in an `ok`/`result` envelope; `result` includes `chat_events` and `has_more`. The browser's canonical message-event shape includes `seq`, `occurred_at_ms`, `event_name`, `message_id`, `reply_to_message_id`, `role`, and `content`. The event name and role agree (`message.user`/`user` or `message.assistant`/`assistant`).

### Send a text message

The normal composer sends `POST /chat/stream` with a JSON body. A minimal text-only shape is:

```json
{
  "message": "<text>",
  "node_id": "<stable client device ID>",
  "capabilities": [
    "hotel_results",
    "chat_cancel",
    "delta_stream",
    "custom_reactions",
    "custom_reactions_facebook_thumbs_up_v1"
  ],
  "timezone": "<IANA timezone>"
}
```

For an existing thread, include `session_id`. The browser gets its `node_id` from its local device context; a Watch implementation should use its own stable, app-generated installation identifier, not a hardware serial number. The browser may attach `client_ip`, reply/context parameters, modality, metadata, or other fields when those features are used. For attachments or item-based commands, the composer sends an `items` array instead of the simple `message` field; the exact item variants depend on the attachment type.

Capabilities are version-dependent. The list above is the observed baseline; `chat.subscribe` adds `voice_reply_captions` and `voice_user_live_transcript` in the browser. A minimal Watch client should advertise only capabilities it implements and should tolerate server events outside its current UI.

`chat.stream` is registered as a subscription-style request. The live prototype received an acknowledgement containing `message_id`, `reply_to_message_id`, and `session_id`, followed by JSON Lines records for chat events. A record can be an acknowledgement such as `{type:"res", id, status, payload}` or an event such as `{type:"event", event, payload, seq, ts_ms}`. The experiment observed `message.user` and `delta.message_done`; incremental token-by-token streaming is not yet confirmed as a stable behavior.

### Subscribe to updates

The browser posts to `/chat/subscribe` with a body shaped as:

```json
{
  "after_stream_seq": 0,
  "after_chat_event_seq": 0,
  "capabilities": [
    "hotel_results",
    "chat_cancel",
    "delta_stream",
    "custom_reactions",
    "custom_reactions_facebook_thumbs_up_v1",
    "voice_reply_captions",
    "voice_user_live_transcript"
  ],
  "session_id": "<include for a thread subscription>"
}
```

The two cursor fields are nonnegative sequence numbers. The main chat subscription omits `session_id`; a thread subscription includes it. On first subscription the browser uses zero cursors. The response stream is newline-delimited JSON: the first record acknowledges the subscription, and later `event` records contain event name, payload, stream sequence, and timestamp. The acknowledgement can contain `subscribed`, `session_id`, `agent_id`, `conn_id`, capabilities, and channel metadata.

The live replay showed a repeated `message.user` event after reconnect even when its chat sequence was below the supplied cursor. Cursors are not an exactly-once guarantee. Reconcile repeated messages by stable `message_id`, and maintain both stream and chat-event cursors rather than treating every replay as a new bubble.

`chat.stream_events` is also registered as a Noise-only POST subscription route, but its request and event semantics have not been separately documented or live-verified. It is not required for the text-only Watch flow described here.

## Apple Watch port implications

The repository already contains the Noise, protobuf framing, and WebSocket gateway core in `Sources/MuseKit`; its `MuseGateway.connect` deliberately requires a caller-supplied verifier. `WatchApp/` still uses `DemoTransport`, so it has no live authentication or chat wiring.

To complete a live Watch client, keep these responsibilities separate:

1. **Sign-in/session provider:** use Muse's supported sign-in path and obtain an authenticated session. The HAR only proves that an existing browser session can be checked; it does not provide the login or cookie handoff needed by a standalone Watch app.
2. **Admission provider:** call `/api/hatch/token` using that authenticated session; validate the response, refresh near notary expiry, and keep credentials out of logs and long-lived app state.
3. **Peer verifier:** validate the expected VM/server identity and any required standard-VM or confidential-VM trust evidence before Noise message 3. Do not accept an arbitrary server key.
4. **Gateway client:** connect to the WSS endpoint, encode the inner headers and JSON bodies, and use the existing frame/transport code.
5. **Chat store:** load history, send `chat.stream`, subscribe for events, reconcile by message ID, and resume with cursors after reconnect.

Until Muse documents or exposes a supported Watch sign-in/session exchange, the account-session handoff is the main missing piece. The current Node/Swift protocol core is not a substitute for that flow or for attestation verification.

## Evidence and open questions

| Item | Finding | Status |
|---|---|---|
| `/api/auth/check` | POST, no body, browser credentials included, status 200 in HAR; response fields above | Observed |
| Account housekeeping | `/api/auth/save-account`, `/api/auth/session/reset`, `/api/auth/checkpoint/terminate`, `/api/logout` referenced by bundles | Source only |
| `/api/hatch/vm/wake` | POST body contains VM ID, retry count, optional attempt ID; status 200 | Observed |
| `/api/hatch/token` | Request/response shape and 10-second timeout in bundled source; no request in this HAR | Source only |
| `/api/hatch/noise-notary-token` | Request/response shape and 8-second timeout in bundled source; no request in this HAR | Source only |
| Noise WebSocket | Two HTTP 101 upgrades; 230 and 10 binary frames; standard-size handshake with empty message-3 payload | Observed; peer trust is not independently established by the HAR |
| Chat gateway methods | Route registry, composer body builder, subscription cursors and capabilities in bundled source | Source observed; routes are inside ciphertext |
| Live text send/history/replay | Accepted in the Node experiment described in the protocol notes | Live-protocol notes |
| Sign-in, MFA, cookie acquisition, expiry and renewal | Not captured; no standalone Watch sign-in contract established | Unknown |
| Swift live interoperability and attestation | Byte-vector parity exists; no live Swift handshake or full attestation verifier | Unknown/incomplete |

See [muse-protocol-notes.md](muse-protocol-notes.md) for the lower-level protobuf fields, chunking rules, test-vector scope, and existing experimental limitations.
