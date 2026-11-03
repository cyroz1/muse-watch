# Muse Watch app

A baseline watchOS app whose chat UI mirrors the native Apple Watch Messages app:
monogram avatars and one-line previews in the thread list, centered timestamps,
green outgoing bubbles, grey incoming bubbles, quick replies, a dictation-ready
composer, and a typing indicator. The protocol engine lives in the `MuseKit`
Swift package at the repository root.

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
- `DemoTransport` canned replies so the UI runs before gateway wiring.

## What is not wired yet

- The app uses `DemoTransport`, not `MuseGateway`. Connecting needs a verified
  admission path (browser session, token refresh, VM attestation) that the
  research package deliberately leaves to the caller.
- The UI has not been compiled or run here: this checkout only has Command Line
  Tools, and SwiftUI/watchOS builds require Xcode. Syntax was checked, not the
  full watchOS build.

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
- Quick replies sit above the composer while the draft is empty, echoing the
  watch Messages reply screen.
- Chat scrolling uses the normal `ScrollView`, so the Digital Crown scrolls the
  conversation without custom gesture code.

## Next milestone

Wire a `ChatTransport` backed by `MuseGateway`:

1. Acquire the admission URL and token from an authenticated Muse session
   (outside the watch app for now — do not ship browser cookies to the watch).
2. Implement the `MuseGateway.Verifier` with the VM/attestation checks.
3. `GET /chat/history` for the thread list, `POST /chat/stream` to send,
   `POST /chat/subscribe` for deltas, reconciling repeats by message ID.
4. Keep the Messages UI; replace `DemoTransport` in `MuseWatchApp.swift`.
