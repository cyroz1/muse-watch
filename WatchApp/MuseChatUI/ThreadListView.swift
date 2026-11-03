import SwiftUI

/// Conversation list styled after the watchOS Messages app: monogram avatars,
/// bold sender names, one-line grey previews and a compose button.
public struct ThreadListView: View {
    @ObservedObject private var store: ChatStore
    @State private var path: [UUID] = []

    public init(store: ChatStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.threads) { thread in
                    NavigationLink(value: thread.id) {
                        ThreadRow(thread: thread)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let thread = store.startNewThread()
                        path.append(thread.id)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New message")
                }
            }
            .navigationDestination(for: UUID.self) { threadID in
                ChatView(store: store, threadID: threadID)
            }
        }
    }
}

struct ThreadRow: View {
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.42), Color(white: 0.30)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Text(thread.initials)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(thread.date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(thread.preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if thread.unread {
                        Circle()
                            .fill(MuseTheme.sentBubble)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
