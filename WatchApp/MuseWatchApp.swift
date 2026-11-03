import SwiftUI

@main
struct MuseWatchApp: App {
    @StateObject private var store = ChatStore(transport: DemoTransport())

    private var opensChat: Bool {
        ProcessInfo.processInfo.arguments.contains("--open-chat")
    }

    var body: some Scene {
        WindowGroup {
            ThreadListView(store: store, openFirstThread: opensChat)
        }
    }
}
