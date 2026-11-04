import Foundation

public enum MuseJSONLinesDecodingError: Error, Equatable, Sendable {
    case invalidRecord
}

/// Incremental decoder for gateway JSON Lines streams. Records can span body
/// chunks, and the final record may end with the response body rather than a
/// newline.
public struct MuseJSONLinesDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    /// Appends a body chunk and returns every complete JSON record in order.
    public mutating func append(_ chunk: Data) throws -> [JSONValue] {
        buffer.append(chunk)
        var records: [JSONValue] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeFirst(newline + 1)
            if let record = try Self.decodeRecord(line) {
                records.append(record)
            }
        }
        return records
    }

    /// Decodes a final unterminated record when the body ends.
    public mutating func finish() throws -> [JSONValue] {
        guard !buffer.isEmpty else { return [] }
        let finalLine = buffer
        buffer.removeAll(keepingCapacity: false)
        guard let record = try Self.decodeRecord(finalLine) else { return [] }
        return [record]
    }

    private static func decodeRecord(_ line: Data) throws -> JSONValue? {
        let normalized = line.last == 0x0D ? Data(line.dropLast()) : line
        guard !normalized.isEmpty else { return nil }
        do {
            return try JSONValue.decode(normalized)
        } catch {
            throw MuseJSONLinesDecodingError.invalidRecord
        }
    }
}
