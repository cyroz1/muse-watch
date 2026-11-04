# Muse authentication and chat transport

Observed from the Web Inspector HAR captured on November 3, 2026, the JavaScript bundles included in that HAR, a cookie-free fetch of the current public web bundle on November 3, 2026, and the live-protocol notes in this repository. Muse's protocol is undocumented and can change; treat this as a versioned research record, not a supported public API contract.

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
  ├─ or use a current browser WSS auth_token (live Network URL observed)
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

On November 3, 2026, a live check in the signed-in `muse.ai` browser session again returned HTTP 200 with `outcome: "validated"`; all token and account values were kept out of output. A follow-up probe reused the returned account `access_token` as a Bearer token with browser cookies omitted. `POST /api/auth/check` returned HTTP 401. A similar cookie-free Bearer probe to `POST /api/hatch/token` also returned HTTP 401. This is live evidence that the web `access_token` alone is not a Watch session handoff or a gateway-admission credential.

The simulator's one-time cookie import was later validated against `/api/auth/check`: after adding the browser-observed same-origin `Origin`, `Referer`, `DNT`, and `Sec-Fetch-*` headers, the Watch request returned HTTP 200 with `outcome: "validated"`. The session validated again after app relaunch, confirming that the simulator Keychain entry persisted. This validates the imported web session only; it is not a supported Watch sign-in flow.

The subsequent Watch admission request and a same-origin browser request both returned HTTP 401 with a JSON response containing `code` and `error` keys. Both used the inferred body with `vmAddress` set to the generic gateway origin `https://hatch.metaaivm.com` and omitted `vmName`. The current public bundle confirms that `/api/hatch/token` receives the selected gateway URL as `vmAddress`, with an optional `vmName`; its WebSocket target builder can derive `vm_id` from the gateway URL or VM identity and rejects a shared gateway target without an ID. The earlier 401 probes therefore did not reproduce a fully identified target and do not prove that the imported cookie cannot mint admission for the browser's actual selected VM. No admission token was received and no Watch WebSocket or chat request was made.

The Watch app has a debug-only `--import-muse-cookie` screen for a local simulator experiment. It stores a user-supplied `Cookie` header in the simulator Keychain (`WhenUnlockedThisDeviceOnly`) and sends it only to HTTPS requests on `muse.ai`; the UI can check the saved session through `/api/auth/check`. A headless simulator can instead use `--import-muse-cookie-file`, which reads and deletes a one-time file from the app's cache directory before validating the session. The imported browser session was live-validated on Watch and survived app relaunch. This remains a research workaround, not a supported Muse sign-in or Watch handoff. The current debug simulator path additionally implements source-derived admission, VM wake, a standard-VM first-use key pin, and encrypted text chat; none of those later steps has been live-verified from Watch. The app does not check a saved cookie automatically at launch.

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

`vmAddress` is the selected gateway target, not necessarily the generic shared-gateway origin. The current WebSocket builder accepts a `vm_id` query item on that target or derives the ID from the selected VM identity; it refuses to connect to the shared gateway without a valid ID. The current Swift and Node admission helpers add or preserve a credential-free `vm_id` query item when the caller supplies the selected VM ID, include it in the cache key and request body, and reject other query parameters so an auth token cannot be mistaken for target metadata. `vmName` and `force_refresh` are optional; the refresh flag is sent only when requested. A successful response is expected to include `token` and may include `notary_token`. The web client caches admission material by gateway URL and VM name, and refreshes when a parseable `timeout:` restriction on the notary token is within 60 seconds of expiry. The source uses a 10-second token-request timeout and invalidates in-flight results when the gateway target changes. The HAR contains no `/api/hatch/token` entry, so this request shape and behavior come from shipped client code, not a successful call in this capture.

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

A separate live DevTools capture on November 3, 2026, showed a successful HTTP 101 upgrade to the same `/v1/noise` host/path. In that connection the complete visible URL had only `vm_id` and `auth_token` query keys; it omitted `notary_token`, `app_id`, and `request_id`, unlike the earlier HAR. The token-mint and notary-resolution endpoints did not appear in that capture, so the admission token's acquisition or reuse path was not observed. Treat these connection parameters as version-dependent; this single call is not enough to change the client behavior.

The debug Watch setup now has a second, caller-supplied admission path: it accepts either a raw `auth_token` or the full current `/v1/noise` URL, verifies the Muse host, path, VM ID, and allowed query keys, then stores it in device-local Keychain scoped to the validated viewer and VM. It preserves the live browser URL's query shape, including the minimal `vm_id` + `auth_token` form, and skips `/api/hatch/token` for that connection. This adds no token acquisition or refresh behavior; token lifetime is unknown, so an expired value must be replaced. The direct path is synthetic/source-informed until a Watch handshake and chat exchange succeed.

After the handshake, all observed WebSocket frames are encrypted. The HAR does not contain the ephemeral private key needed to decrypt them. It therefore cannot reveal the exact chat request or response JSON from those frames. The chat contracts below come from the bundled client request registry/builders and the repository's separate live-protocol observations.

The current DevTools capture likewise exposed the WebSocket upgrade, not plaintext inner gateway requests or JSON Lines chat responses. `/chat/stream` and its bodies remain source-derived from the browser bundle; they were not visible as ordinary HTTP requests in the current Network panel.

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

The repository contains the Noise, protobuf framing, and WebSocket gateway core in `Sources/MuseKit`; `MuseGateway.connect` deliberately requires a caller-supplied verifier. `WatchApp/MuseChatUI/MuseGatewayChatTransport.swift` connects the source-derived session/admission helpers to the observed VM wake step, text chat requests, and completion/history parsing. The debug simulator screen can configure this transport after validating a manually supplied existing web-session Cookie header and selecting a gateway target and VM ID. It can use either `/api/hatch/token` or a current user-supplied browser `auth_token`/WSS URL. Normal app launches and CI screenshots still use `DemoTransport`.

To complete a live Watch client, keep these responsibilities separate:

1. **Sign-in/session provider:** use Muse's supported sign-in path and obtain an authenticated session. The HAR only proves that an existing browser session can be checked; it does not provide the login or cookie handoff needed by a standalone Watch app. The simulator's manually supplied Cookie is a research-only existing-session workaround.
2. **Admission provider:** call `/api/hatch/token` using that session; the source-derived implementation validates the response, caches and refreshes it, and passes the selected VM target. A `delegation.` notary token still requires the web client's missing endorser.
3. **Peer verifier:** the simulator path detects the observed confidential owner challenge and rejects it before Noise message 3. For standard VMs it offers user-approved first-use key pinning and rejects later key/type changes. The first key is not independently authenticated, so this is not equivalent to a verified server identity. Confidential attestation and recovery-proof verification remain incomplete.
4. **Gateway client:** connect to the WSS endpoint, wake the selected VM, encode the inner headers and JSON bodies, and use the existing frame/transport code.
5. **Chat store:** the Watch adapter sends `POST /chat/stream`, waits for the completion event, and falls back to `GET /chat/history` if the stream ends without assistant text. History-backed thread loading, background subscriptions, and replay reconciliation remain incomplete.

Until Muse documents or exposes a supported Watch sign-in/session exchange, the simulator's cookie import cannot be treated as a general Watch login. The session Cookie and gateway `auth_token` remain separate credentials. Both stay in device-local Keychain and are excluded from source and documentation. No live Watch gateway handshake or send/receive has yet been verified.

The official Meta developer documentation currently describes browser sign-in for Muse Code and `MODEL_API_KEY` bearer authentication for the Meta Model API. Those are separate surfaces (`dev.meta.ai` / `api.meta.ai`) and do not specify a session handoff for the `muse.ai` Hatch chat gateway, so they are not substituted here ([Muse Code authentication](https://dev.meta.ai/docs/muse-code/auth), [Meta Model API overview](https://dev.meta.ai/docs/overview)).

### Swift helper port status

`Sources/MuseKit/Authentication.swift` ports the source-observed `/api/auth/check` response validation and 60-second in-memory reuse, the Node prototype's `/api/hatch/token` cache/refresh and delegation-endorsement seam, and the source-observed `/api/hatch/noise-notary-token` request shape. It also builds the credential-bearing `wss://hatch.metaaivm.com/v1/noise` URL and redacts token-bearing objects' textual descriptions. `Sources/MuseKit/ConfidentialProof.swift` ports the provisioned owner-proof HMAC and protobuf payload calculation from `muse_confidential_proof.mjs`; callers still must independently verify attestation, identity, and inputs before using it. `Sources/MuseKit/ChatAPI.swift` defines the observed text request and dynamic response projections. The Watch app's `MuseGatewayChatTransport` connects validation, admission, the required verifier, and the encrypted text chat route; callers provide authentication and trust behavior.

This is a source-derived Swift port with a previously live-validated Watch session check, but no successful live Watch gateway authentication. `MuseAuthenticatedFetch` is caller-supplied and must use an approved session mechanism, honor request timeouts and no-store requirements, and avoid logging request/response bodies. The debug-only simulator import stores a user-supplied Cookie header in Keychain and restricts its use to HTTPS `muse.ai` requests; it is not a supported login or session handoff. The imported session returned `validated` from `/api/auth/check` and remained valid after app relaunch. The later `/api/hatch/token` request using selected VM context returned HTTP 401. The new direct path accepts a user-supplied current browser WebSocket URL or raw `auth_token`, validates the target, and stores the credential in device-local Keychain scoped to account and VM. It has not been live-verified from Watch. The simulator performs VM wake before Noise message 1, gates message 3 on standard key pinning, and sends encrypted chat requests. No Watch Noise handshake or chat exchange has been achieved. Delegated notary tokens still fail closed without an endorser; confidential VMs fail closed without attestation and owner-proof verification. No cookie values or HAR files are stored in the repository.

## Evidence and open questions

| Item | Finding | Status |
|---|---|---|
| `/api/auth/check` | POST, no body, browser credentials included, status 200 in the HAR and a same-origin live session check; live result was `outcome: validated`, with the documented fields/types and all values redacted | HAR and live request |
| Muse account `access_token` as Bearer | Cookie-free Bearer probes to `/api/auth/check` and `/api/hatch/token` returned HTTP 401; token value omitted and not saved | Live negative probe |
| Watch simulator Cookie import | One-time browser Cookie header import was accepted; `/api/auth/check` returned `validated`, including after app relaunch. This validates the web session only. | Historical live Watch session validation; unsupported handoff |
| Account housekeeping | `/api/auth/save-account`, `/api/auth/session/reset`, `/api/auth/checkpoint/terminate`, `/api/logout` referenced by bundles | Source only |
| `/api/hatch/vm/wake` | POST body contains VM ID, retry count, optional attempt ID; status 200 | Observed |
| `/api/hatch/token` | Current public bundle sends the selected gateway URL as `vmAddress` and optionally `vmName`; its WebSocket target builder accepts a `vm_id` query item or derives the ID from VM identity. Generic-origin Watch/browser probes returned HTTP 401 without the selected VM context. | Current bundle source plus inconclusive live negative probes; no token minted |
| `/api/hatch/noise-notary-token` | Request/response shape and 8-second timeout in bundled source; no request in this HAR | Source only |
| Current `muse.ai` browser tab (2026-11-03) | Live Network panel showed a 101 upgrade to `/v1/noise` with `vm_id` and `auth_token` query keys; values redacted. No `/api/hatch/token` or `/api/hatch/noise-notary-token` request appeared in the captured window. | Live network observation; token acquisition remains unknown |
| Watch direct admission input | Parser accepts a raw token or WSS URL and rejects host, path, VM, duplicate-query, or unexpected-query mismatches; simulator stores the validated URL in Keychain. | Synthetic validation only; no live Watch use |
| Noise WebSocket | Two HTTP 101 upgrades; 230 and 10 binary frames; standard-size handshake with empty message-3 payload | Observed; peer trust is not independently established by the HAR |
| Chat gateway methods | Route registry, composer body builder, subscription cursors and capabilities in bundled source | Source observed; routes are inside ciphertext |
| Live text send/history/replay | Accepted in the Node experiment described in the protocol notes | Live-protocol notes |
| Sign-in, MFA, cookie acquisition, expiry and renewal | Not captured; no standalone Watch sign-in contract established. The live account access token did not work as a cookie-free Bearer credential for the session-check or admission routes. | Unknown; live negative probe |
| Swift live interoperability and attestation | Byte-vector parity exists; no live Watch handshake. Standard VM uses user-approved first-use pinning without independent first-key identity validation; confidential attestation is incomplete. | Unknown/incomplete |
| Native Messages visual reference | The user supplied a conversation screenshot and a short video showing a Shiba avatar. The Watch UI now uses a frame-derived circular avatar, blue outgoing bubbles, delivery text, dark incoming bubbles, and a compact iMessage composer with a dictation button. | Visual implementation checked in the Watch simulator; not pixel-identical |

See [muse-protocol-notes.md](muse-protocol-notes.md) for the lower-level protobuf fields, chunking rules, test-vector scope, and existing experimental limitations.
