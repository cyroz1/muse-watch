import MuseChatUI
import SwiftUI

@main
struct MuseWatchApp: App {
    @StateObject private var store = ChatStore(transport: DemoTransport())

    var body: some Scene {
        WindowGroup {
            ThreadListView(store: store)
        }
    }
}
