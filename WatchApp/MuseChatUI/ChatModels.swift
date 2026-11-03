import Combine
import Foundation

public enum ChatRole: String, Sendable, Codable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), role: ChatRole, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

public struct ChatThread: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var preview: String
    public var date: Date
    public var unread: Bool

    public init(id: UUID = UUID(), title: String, preview: String, date: Date, unread: Bool = false) {
        self.id = id
        self.title = title
        self.preview = preview
        self.date = date
        self.unread = unread
    }

    public var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// The chat UI talks to this seam so the baseline app can run with canned
/// replies while the verified gateway client is wired up.
public protocol ChatTransport: Sendable {
    func reply(to thread: ChatThread, text: String) async throws -> String
}

public struct DemoTransport: ChatTransport {
    public init() {}

    public func reply(to thread: ChatThread, text: String) async throws -> String {
        try await Task.sleep(nanoseconds: 900_000_000)
        return "This is the demo transport. MuseKit's verified gateway client is wired up separately, so no network request was made."
    }
}

@MainActor
public final class ChatStore: ObservableObject {
    @Published public private(set) var threads: [ChatThread]
    @Published public private(set) var messagesByThread: [UUID: [ChatMessage]]
    @Published public private(set) var replyingThreadIDs: Set<UUID> = []

    private let transport: any ChatTransport

    public init(
        transport: any ChatTransport,
        threads: [ChatThread] = ChatThread.samples,
        messages: [UUID: [ChatMessage]] = ChatThread.sampleMessages
    ) {
        self.transport = transport
        self.threads = threads
        self.messagesByThread = messages
    }

    public func thread(for id: UUID) -> ChatThread? {
        threads.first { $0.id == id }
    }

    public func messages(in threadID: UUID) -> [ChatMessage] {
        messagesByThread[threadID] ?? []
    }

    public func isReplying(in threadID: UUID) -> Bool {
        replyingThreadIDs.contains(threadID)
    }

    @discardableResult
    public func startNewThread() -> ChatThread {
        let thread = ChatThread(title: "Muse", preview: "New conversation", date: Date())
        threads.insert(thread, at: 0)
        messagesByThread[thread.id] = []
        return thread
    }

    public func send(_ text: String, in threadID: UUID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let thread = thread(for: threadID) else { return }

        let outgoing = ChatMessage(role: .user, text: trimmed, date: Date())
        messagesByThread[threadID, default: []].append(outgoing)
        replyingThreadIDs.insert(threadID)
        touch(threadID, preview: trimmed, unread: false)

        defer { replyingThreadIDs.remove(threadID) }
        do {
            let reply = try await transport.reply(to: thread, text: trimmed)
            let incoming = ChatMessage(role: .assistant, text: reply, date: Date())
            messagesByThread[threadID, default: []].append(incoming)
            touch(threadID, preview: reply, unread: false)
        } catch {
            let failure = ChatMessage(role: .assistant, text: "Couldn't reach Muse. \(error.localizedDescription)", date: Date())
            messagesByThread[threadID, default: []].append(failure)
            touch(threadID, preview: failure.text, unread: false)
        }
    }

    public func markRead(_ threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].unread = false
    }

    private func touch(_ threadID: UUID, preview: String, unread: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].preview = preview
        threads[index].date = Date()
        threads[index].unread = unread
    }
}

extension ChatThread {
    public static var samples: [ChatThread] {
        let now = Date()
        return [
            ChatThread(title: "Muse", preview: "I can help with that. What are you working on?", date: now.addingTimeInterval(-120)),
            ChatThread(title: "Muse Design", preview: "The new complication looks great.", date: now.addingTimeInterval(-86_400), unread: true)
        ]
    }

    public static var sampleMessages: [UUID: [ChatMessage]] {
        let threads = samples
        let now = Date()
        return [
            threads[0].id: [
                ChatMessage(role: .user, text: "Hey Muse, can you help me sketch a watch app?", date: now.addingTimeInterval(-600)),
                ChatMessage(role: .assistant, text: "Absolutely. Start with the smallest useful screen, then layer in the protocol.", date: now.addingTimeInterval(-540)),
                ChatMessage(role: .user, text: "What should the chat screen look like?", date: now.addingTimeInterval(-180)),
                ChatMessage(role: .assistant, text: "I can help with that. What are you working on?", date: now.addingTimeInterval(-120))
            ],
            threads[1].id: [
                ChatMessage(role: .assistant, text: "The new complication looks great.", date: now.addingTimeInterval(-86_400))
            ]
        ]
    }
}
