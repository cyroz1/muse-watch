import SwiftUI

/// Conversation list styled after the watchOS Messages app: monogram avatars,
/// bold sender names, one-line grey previews and a "New Message" row pinned
/// above the conversations.
public struct ThreadListView: View {
    @ObservedObject private var store: ChatStore
    @State private var path: [UUID]

    /// `openFirstThread` is used by the CI screenshot job to land directly on
    /// the conversation screen.
    public init(store: ChatStore, openFirstThread: Bool = false) {
        self.store = store
        _path = State(initialValue: openFirstThread
            ? (store.threads.first.map { [$0.id] } ?? [])
            : [])
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Button {
                    let thread = store.startNewThread()
                    path.append(thread.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.footnote.weight(.semibold))
                        Text("New Message")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color(white: 0.20))
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 4, trailing: 2))
                .listRowBackground(Color.clear)
                .accessibilityLabel("New message")

                ForEach(store.threads) { thread in
                    NavigationLink(value: thread.id) {
                        ThreadRow(thread: thread)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Messages")
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
                            .fill(Color(red: 0.04, green: 0.52, blue: 1.0))
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
