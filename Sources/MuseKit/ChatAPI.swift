import Foundation

/// Source-derived request shape for a text-only `/chat/stream` call.
/// This is an experimental gateway payload, not a stable public API.
public struct MuseChatTextRequest: Encodable, Sendable, Equatable {
    public let message: String
    public let nodeID: String
    public let capabilities: [String]
    public let timezone: String
    public let sessionID: String?

    public init(
        message: String,
        nodeID: String,
        timezone: String = TimeZone.current.identifier,
        sessionID: String? = nil,
        capabilities: [String] = ["delta_stream"]
    ) {
        self.message = message
        self.nodeID = nodeID
        self.capabilities = capabilities
        self.timezone = timezone
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case message
        case nodeID = "node_id"
        case capabilities
        case timezone
        case sessionID = "session_id"
    }
}

/// Narrow helpers for the observed text chat response shapes. Unrecognized
/// JSON fields remain available to callers through `JSONValue`.
public enum MuseChatProtocol {
    /// Builds the encrypted gateway history path. Query values are escaped by
    /// URLComponents, including session IDs containing reserved characters.
    public static func historyPath(sessionID: String, limit: Int = 20) -> String? {
        guard limit > 0, !sessionID.isEmpty else { return nil }
        var components = URLComponents()
        components.path = "/chat/history"
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "session_id", value: sessionID)
        ]
        guard let query = components.percentEncodedQuery else { return nil }
        return "\(components.path)?\(query)"
    }

    /// Reads a session ID from an acknowledgement or event envelope without
    /// assuming that the version-dependent payload has only known fields.
    public static func sessionID(in record: JSONValue) -> String? {
        let containers = [record["payload"], record["result"], record].compactMap { $0 }
        for container in containers {
            if let value = container["session_id"]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Returns text from the observed final assistant event, when present.
    public static func completionText(in record: JSONValue) -> String? {
        guard isCompletionEvent(record) else { return nil }
        let payload = record["payload"] ?? record["result"] ?? record
        for key in ["transcript", "content", "text", "message"] {
            if let value = text(in: payload[key]) { return value }
        }
        return nil
    }

    public static func isCompletionEvent(_ record: JSONValue) -> Bool {
        let eventName = record["event"]?.stringValue ?? record["event_name"]?.stringValue
        return eventName == "delta.message_done" || eventName == "message.assistant"
    }

    /// Extracts the latest assistant text from the observed history envelope.
    /// The event and content schemas remain dynamic; only the role and common
    /// text-bearing keys are projected here.
    public static func latestAssistantText(in response: JSONValue) -> String? {
        let result = response["result"] ?? response
        guard let events = result["chat_events"]?.arrayValue else { return nil }
        for event in events.reversed() where event["role"]?.stringValue == "assistant" {
            if event["display_text_ready"]?.boolValue == true,
               let value = text(in: event["display_text"]) {
                return value
            }
            for value in [event["payload"], event["content"], event["transcript"], event["text"], event["message"]] {
                if let value = text(in: value) { return value }
            }
        }
        return nil
    }

    private static func text(in value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        case .array(let values):
            let parts = values.compactMap { text(in: $0) }
            return parts.isEmpty ? nil : parts.joined()
        case .object(let object):
            for key in ["text", "content", "transcript", "parts", "items", "segments", "message", "delta"] {
                if let result = text(in: object[key]) { return result }
            }
            return nil
        case .null, .bool, .number:
            return nil
        }
    }
}
