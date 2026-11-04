import SwiftUI

/// A single conversation, laid out like watchOS Messages: centered timestamps,
/// blue outgoing bubbles, grey incoming bubbles and a compact composer.
public struct ChatView: View {
    @ObservedObject private var store: ChatStore
    private let threadID: UUID

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    public init(store: ChatStore, threadID: UUID) {
        self.store = store
        self.threadID = threadID
    }

    private var messages: [ChatMessage] {
        store.messages(in: threadID)
    }

    private var title: String {
        store.thread(for: threadID)?.title ?? "Messages"
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 0) {
                    if messages.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("No messages yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if showsTimestamp(at: index) {
                            timestampLabel(message.date)
                        }
                        MessageBubbleRow(message: message)
                            .padding(.bottom, MuseTheme.Metric.bubbleSpacing)
                            .id(message.id)
                    }

                    if store.isReplying(in: threadID) {
                        TypingIndicator()
                            .padding(.top, 4)
                    }

                    Color.clear
                        .frame(height: Self.composerReserveHeight)
                        .id(Self.bottomID)
                }
                .padding(.horizontal, MuseTheme.Metric.horizontalMargin)
                .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .bottom)
            .onAppear {
                store.markRead(threadID)
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: store.isReplying(in: threadID)) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
        .overlay(alignment: .bottom) {
            composer
                .offset(y: 16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image("MuseAvatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                .accessibilityLabel("\(title) contact")
            }
        }
    }

    private static let bottomID = "chat-bottom"
    private static let composerReserveHeight: CGFloat = 58

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
    }

    private func showsTimestamp(at index: Int) -> Bool {
        guard index > 0 else { return false }
        return messages[index].date.timeIntervalSince(messages[index - 1].date) > 5 * 60
    }

    private func timestampLabel(_ date: Date) -> some View {
        Text(date, format: .dateTime.hour().minute())
            .font(.caption2)
            .foregroundStyle(MuseTheme.timestamp)
            .padding(.top, MuseTheme.Metric.groupSpacing)
            .padding(.bottom, 3)
            .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button {
                composerFocused = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .buttonBorderShape(.circle)
            .frame(width: 32, height: 32)
            .accessibilityLabel("Dictate message")

            TextField("message", text: $draft)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { if canSend { send(draft) } }
                .controlSize(.mini)
                .frame(width: 140, height: 32)
            .accessibilityLabel("Message")

            if canSend {
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .buttonBorderShape(.circle)
                .tint(MuseTheme.sentBubble)
                .accessibilityLabel("Send")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        Task {
            await store.send(trimmed, in: threadID)
        }
    }
}

struct MessageBubbleRow: View {
    let message: ChatMessage

    private var isFromCurrentUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isFromCurrentUser {
                Spacer(minLength: MuseTheme.Metric.minimumEdgeSpace)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(isFromCurrentUser ? .white : .primary)
                    .padding(.horizontal, MuseTheme.Metric.bubblePaddingHorizontal)
                    .padding(.vertical, MuseTheme.Metric.bubblePaddingVertical)
                    .background(
                        MessageBubbleShape(isFromCurrentUser: isFromCurrentUser)
                            .fill(isFromCurrentUser ? MuseTheme.sentBubble : MuseTheme.receivedBubble)
                    )
                    .accessibilityLabel("\(isFromCurrentUser ? "You" : "Muse"): \(message.text)")

                if isFromCurrentUser && message.isDelivered {
                    Text("Delivered")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
            }

            if !isFromCurrentUser {
                Spacer(minLength: MuseTheme.Metric.minimumEdgeSpace)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
