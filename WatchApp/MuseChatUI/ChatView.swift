import SwiftUI

/// A single conversation, laid out like watchOS Messages: centered timestamps,
/// green outgoing bubbles, grey incoming bubbles, quick replies and a composer.
public struct ChatView: View {
    @ObservedObject private var store: ChatStore
    private let threadID: UUID

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private let quickReplies = ["On my way!", "Okay", "Sounds good"]

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
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.horizontal, MuseTheme.Metric.horizontalMargin)
                .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                store.markRead(threadID)
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: store.isReplying(in: threadID)) { _ in
                scrollToBottom(proxy, animated: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(title)
    }

    private static let bottomID = "chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
    }

    private func showsTimestamp(at index: Int) -> Bool {
        guard index > 0 else { return true }
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
        VStack(spacing: 6) {
            if draft.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickReplies, id: \.self) { reply in
                            Button {
                                send(reply)
                            } label: {
                                Text(reply)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(MuseTheme.composerBackground)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }

            HStack(spacing: 6) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { send(draft) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(MuseTheme.composerBackground)
                    )

                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(
                                canSend ? MuseTheme.sentBubble : Color(white: 0.28)
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.thinMaterial)
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

            if !isFromCurrentUser {
                Spacer(minLength: MuseTheme.Metric.minimumEdgeSpace)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
