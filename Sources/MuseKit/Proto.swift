import Foundation

/// Minimal protobuf wire codec for the Muse gateway's length-delimited and
/// varint fields. Mirrors the field map in `muse-protocol-notes.md`; this is
/// not a general protobuf implementation.
enum Proto {
    enum Value: Equatable {
        case varint(UInt64)
        case bytes(Data)
    }

    struct Field: Equatable {
        let number: Int
        let value: Value
    }

    static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func tag(_ field: Int, wireType: UInt64) -> Data {
        varint(UInt64(field) << 3 | wireType)
    }

    /// Length-delimited field (wire type 2).
    static func bytes(_ field: Int, _ data: Data) -> Data {
        var out = tag(field, wireType: 2)
        out.append(varint(UInt64(data.count)))
        out.append(data)
        return out
    }

    /// Varint field (wire type 0).
    static func number(_ field: Int, _ value: UInt64) -> Data {
        var out = tag(field, wireType: 0)
        out.append(varint(value))
        return out
    }

    static func parse(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []

        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            var count = 0
            while true {
                guard index < bytes.count, count < 10 else {
                    throw FramingError.malformedProtobuf("invalid varint")
                }
                let byte = bytes[index]
                index += 1
                count += 1
                if shift == 63 && byte > 1 {
                    throw FramingError.malformedProtobuf("varint overflow")
                }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        while index < bytes.count {
            let key = try readVarint()
            let number = Int(key >> 3)
            let wireType = key & 7
            guard number > 0 else { throw FramingError.malformedProtobuf("invalid field number") }
            switch wireType {
            case 0:
                fields.append(Field(number: number, value: .varint(try readVarint())))
            case 2:
                let size = try readVarint()
                guard size <= UInt64(bytes.count - index) else {
                    throw FramingError.malformedProtobuf("truncated field")
                }
                let start = index
                index += Int(size)
                fields.append(Field(number: number, value: .bytes(Data(bytes[start..<index]))))
            default:
                throw FramingError.malformedProtobuf("unsupported wire type \(wireType)")
            }
        }
        return fields
    }
}

extension Array where Element == Proto.Field {
    func first(_ number: Int) -> Proto.Value? {
        first { $0.number == number }?.value
    }

    func bytes(_ number: Int, default defaultValue: Data = Data()) -> Data {
        if case .bytes(let data)? = first(number) { return data }
        return defaultValue
    }

    func number(_ number: Int, default defaultValue: UInt64 = 0) -> UInt64 {
        if case .varint(let value)? = first(number) { return value }
        return defaultValue
    }
}
