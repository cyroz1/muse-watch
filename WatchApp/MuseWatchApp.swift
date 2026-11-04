import SwiftUI

@main
struct MuseWatchApp: App {
    @StateObject private var store: ChatStore

    init() {
        self.init(transport: DemoTransport())
    }

    init(transport: any ChatTransport) {
        if transport is MuseGatewayChatTransport {
            _store = StateObject(wrappedValue: ChatStore(
                transport: transport,
                threads: [],
                messages: [:]
            ))
        } else {
            _store = StateObject(wrappedValue: ChatStore(transport: transport))
        }
    }

    init(authentication: MuseWatchAuthentication) {
        self.init(transport: MuseGatewayChatTransport(authentication: authentication))
    }

    private var opensChat: Bool {
        ProcessInfo.processInfo.arguments.contains("--open-chat")
    }

    private var opensCookieImport: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--import-muse-cookie")
            || ProcessInfo.processInfo.arguments.contains("--import-muse-cookie-file")
            || ProcessInfo.processInfo.arguments.contains("--import-muse-gateway-credential-file")
#else
        false
#endif
    }

    private var opensLiveChatSetup: Bool {
#if DEBUG && targetEnvironment(simulator)
        !opensChat
            || ProcessInfo.processInfo.arguments.contains("--muse-chat")
            || ProcessInfo.processInfo.arguments.contains("--muse-live-test")
#else
        false
#endif
    }

    var body: some Scene {
        WindowGroup {
            if opensCookieImport || opensLiveChatSetup {
                MuseCookieSignInView()
            } else {
                ThreadListView(store: store, openFirstThread: opensChat)
            }
        }
    }
}
