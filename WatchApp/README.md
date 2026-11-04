# Muse Watch app

A baseline watchOS app whose chat UI follows the native Apple Watch Messages
conversation: contact avatar, blue outgoing bubbles with delivery text, grey
incoming bubbles, centered timestamps, and a compact composer with a dictation
button. The Muse avatar is a still extracted from the user-provided video. The protocol engine lives in the `MuseKit`
Swift package at the repository root.

The browser authentication and chat request contracts are documented in the repository's [authentication and chat transport notes](../muse-auth-chat-protocol.md). They remain research observations rather than a supported Muse API.

## What works

- `MuseKit` protocol core (library, runnable checks):
  - `NoiseXXInitiator` / `NoiseTransport` — `Noise_XX_25519_AESGCM_SHA256` using CryptoKit.
  - Protobuf framing for `ApplicationRequest`, `ServiceFrame`, `ServiceRequest`,
    `NoiseTransportFrame`, and response reassembly.
  - `MuseGateway` actor over `URLSessionWebSocketTask` with request and
    newline-delimited subscription APIs.
  - Verified byte-for-byte against vectors generated from the Node prototype
    that completed a live Muse handshake (`swift run MuseKitChecks`).
- App shell with Messages-style thread list and conversation screen.
- `MuseGatewayChatTransport` for text turns over the encrypted gateway. It
  validates the supplied session, obtains admission, wakes the selected VM,
  waits for peer verification before Noise message 3, sends `/chat/stream`,
  tracks session IDs per local thread, and falls back to `/chat/history` when
  the stream ends without assistant text.
- A standard-VM first-use pin scoped to the account and VM. A user decision
  allows the first Noise static key to be stored in Keychain; later key changes
  are rejected. This is trust on first use, not independent first-key identity
  verification.
- `DemoTransport` for normal app launches and the `--open-chat` screenshot path.
- A debug-only `--import-muse-cookie` screen can store a pasted Muse browser
  Cookie header in the simulator Keychain and validate it with
  `/api/auth/check`. A headless simulator can use
  `--import-muse-cookie-file` to read and delete a one-time cache file. Both
  paths send the header only to HTTPS requests on `muse.ai`. The transferred
  browser session returned `validated` on Watch and remained valid after app
  relaunch. The screen accepts the selected gateway URL, VM ID (or a `vm_id`
  query item), and optional VM name for source-derived admission requests.
  This remains a simulator research workaround, not a supported Muse sign-in
  or Watch handoff. The app does not auto-check the saved cookie at launch.
- The setup screen accepts either a raw gateway `auth_token` or a current Muse
  WebSocket URL. It validates the host and selected VM, then stores the
  credential URL in device-local Keychain scoped to the validated account and
  VM. A headless simulator can use `--import-muse-gateway-credential-file` to
  read and delete `Library/Caches/muse-gateway-credential.txt`. When supplied,
  the transport uses the browser-observed WebSocket query shape directly and
  skips the `/api/hatch/token` request. Token expiry and refresh are unknown;
  the user must import a current value again if it expires.
- On November 3, 2026, a user-authorized turn completed on the Apple Watch
  Series 12 (46mm) watchOS 27.2 simulator. The Watch validated the imported
  web session, woke the selected standard VM, passed the user's first-use key
  pin, sent a message, fetched history, and displayed Muse's assistant reply.
  The `/chat/stream` response ended after its acknowledgement in this run, so
  the transport used its history fallback. Live history events carried text in
  `display_text` when ready and in nested `payload.content`; the parser now
  supports both. This is one version-specific simulator exchange under
  trust-on-first-use, not independent server identity verification or a
  physical Watch test. The test Cookie and gateway credential were cleared
  from simulator Keychain after the run; the approved peer pin remains.

## What is not wired yet

- The normal app launch uses `DemoTransport`. In a debug simulator build, the
  app opens the existing-session setup screen by default; after session
  validation and VM selection it opens `MuseGatewayChatTransport`.
- A live `muse.ai` browser session validated successfully, but its returned
  account access token received HTTP 401 when used as a Bearer token without
  browser cookies on the session-check and admission routes. The simulator's
  imported Cookie did validate the Watch session. Earlier admission probes
  used the generic gateway origin without the selected VM context and returned
  HTTP 401; the current public bundle shows that admission receives the
  selected gateway target and optional VM name, while its WebSocket target
  requires a VM ID.
- The selected-VM `/api/hatch/token` request returned HTTP 401, so the live
  exchange used the current browser WebSocket credential directly. Admission
  responses that require notary delegation cannot proceed because the Watch
  does not have the web client's delegation endorser. Confidential VMs remain
  blocked pending verified attestation and recovery proof.
- The native Messages app on this watchOS simulator had no conversations. A
  draft addressed to a reserved fictional number did not create a persistent
  thread, so the chat screen was visually compared with Messages' available
  empty state and styled after its message conventions, not verified pixel for
  pixel against a native conversation.
- MuseKit protocol and chat request/response helpers have synthetic checks.
  The Watch target was built, installed, and launched in the Series 12
  simulator; one live standard-VM exchange completed as described above.

## Build the watch app

Requires Xcode 16 or later and watchOS 10+.

The Xcode project is committed, so there is no generator step:

```sh
open WatchApp/MuseWatch.xcodeproj
```

Pick the `MuseWatch` scheme and a watchOS simulator, then run. The command-line
equivalent is:

```sh
xcodebuild -project WatchApp/MuseWatch.xcodeproj -scheme MuseWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' build
```

If you change `project.yml`, regenerate with XcodeGen:

```sh
brew install xcodegen
cd WatchApp && xcodegen generate
```

### Creating the target by hand instead

1. File > New > Project > watchOS > App, name it `MuseWatch`, SwiftUI, no
   companion app.
2. File > Add Package Dependencies… > Add Local…, choose the repository root,
   and add the `MuseKit` product to the watch target.
3. Add this folder's `MuseWatchApp.swift` and the whole `MuseChatUI` folder to
   the target.
4. Set the minimum deployment to watchOS 10 and run on a simulator or device.

## Continuous integration

`.github/workflows/watch.yml` runs on every push and pull request:

1. `swift run MuseKitChecks` on macOS (protocol regression).
2. Downloads a watchOS simulator runtime if the runner does not have one.
3. Builds `WatchApp/MuseWatch.xcodeproj` unsigned for a watch simulator.
4. Boots the simulator, installs and launches the app, and captures two
   screenshots: `screenshot-list.png` (thread list) and `screenshot-chat.png`
   (conversation, opened with the `--open-chat` launch argument). Both ship as
   the `muse-watch-simulator` artifact.

The screenshot step is best-effort so a flaky simulator boot does not hide a
successful build. You do not need Xcode installed locally to read the artifact.

## Design notes

- Sent bubble green matches Messages (`#34C759`-ish, dark-mode `#30D158`-ish);
  incoming bubble is a neutral dark grey.
- Bubble tails are a small overlapping rounded shape at the bottom corner, the
  same visual device Messages uses at this size.
- Timestamps appear centered between groups when more than five minutes pass.
- The conversation uses a compact, single-line composer so the message history
  gets most of the screen, like native Messages.
- Chat scrolling uses the normal `ScrollView`, so the Digital Crown scrolls the
  conversation without custom gesture code.

## Remaining milestones

To move beyond the one-turn simulator research result:

1. Provide a supported Muse session handoff; the simulator Cookie import is
   only a research path for an already signed-in web session.
2. Implement the web client's notary delegation endorser and complete
   independent standard-VM identity checks. Add confidential-VM attestation
   and recovery-proof verification before enabling those VMs.
3. Add history-backed thread loading, background subscriptions, and cursor
   reconciliation for later turns and reconnects.
