import Foundation
import CMongoC

nonisolated enum BSONError: Error, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let s): return "Malformed BSON: \(s)"
        }
    }
}

nonisolated enum BSONDecoder {
    static func decode(_ bson: UnsafePointer<bson_t>) throws -> BSONDocument {
        guard let ptr = bson_get_data(bson) else { throw BSONError.malformed("null data") }
        let buffer = UnsafeBufferPointer(start: ptr, count: Int(bson.pointee.len))
        var reader = Reader(bytes: buffer)
        return try reader.readDocument()
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var pos = 0

        mutating func need(_ n: Int) throws {
            if pos + n > bytes.count { throw BSONError.malformed("unexpected end at \(pos)") }
        }

        mutating func u8() throws -> UInt8 {
            try need(1)
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func le<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            try need(size)
            var value: T = 0
            for i in 0..<size { value |= T(bytes[pos + i]) << (8 * i) }
            pos += size
            return value
        }

        mutating func cstring() throws -> String {
            let start = pos
            while true {
                try need(1)
                if bytes[pos] == 0 { break }
                pos += 1
            }
            let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<pos]), as: UTF8.self)
            pos += 1
            return s
        }

        mutating func string() throws -> String {
            let len = Int(try le(Int32.self))
            guard len >= 1 else { throw BSONError.malformed("bad string length") }
            try need(len)
            let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[pos..<(pos + len - 1)]), as: UTF8.self)
            pos += len
            return s
        }

        mutating func data(_ n: Int) throws -> Data {
            try need(n)
            defer { pos += n }
            return Data(bytes[pos..<(pos + n)])
        }

        mutating func objectId() throws -> ObjectId {
            try need(12)
            defer { pos += 12 }
            return ObjectId(bytes: Array(bytes[pos..<(pos + 12)]))
        }

        mutating func readDocument() throws -> BSONDocument {
            let start = pos
            let len = Int(try le(Int32.self))
            let end = start + len
            guard len >= 5, end <= bytes.count else { throw BSONError.malformed("bad document length") }
            var doc = BSONDocument()
            while pos < end - 1 {
                let type = try u8()
                let key = try cstring()
                doc.append(key, try readValue(type))
            }
            pos = end
            return doc
        }

        mutating func readValue(_ type: UInt8) throws -> BSONValue {
            switch type {
            case 0x01: return .double(Double(bitPattern: try le(UInt64.self)))
            case 0x02: return .string(try string())
            case 0x03: return .document(try readDocument())
            case 0x04: return .array(try readDocument().elements.map(\.value))
            case 0x05:
                let len = Int(try le(Int32.self))
                let subtype = try u8()
                var payload = try data(len)
                if subtype == 0x02, payload.count >= 4 { payload = payload.dropFirst(4) }
                return .binary(subtype: subtype, data: Data(payload))
            case 0x06: return .undefined
            case 0x07: return .objectId(try objectId())
            case 0x08: return .bool(try u8() != 0)
            case 0x09: return .date(try le(Int64.self))
            case 0x0A: return .null
            case 0x0B:
                let pattern = try cstring()
                return .regex(pattern: pattern, options: try cstring())
            case 0x0C:
                let ref = try string()
                return .dbPointer(ref: ref, id: try objectId())
            case 0x0D: return .code(try string())
            case 0x0E: return .symbol(try string())
            case 0x0F:
                _ = try le(Int32.self)
                let code = try string()
                return .codeWithScope(code: code, scope: try readDocument())
            case 0x10: return .int32(try le(Int32.self))
            case 0x11:
                let i = try le(UInt32.self)
                return .timestamp(t: try le(UInt32.self), i: i)
            case 0x12: return .int64(try le(Int64.self))
            case 0x13:
                let low = try le(UInt64.self)
                return .decimal128(Decimal128(low: low, high: try le(UInt64.self)))
            case 0xFF: return .minKey
            case 0x7F: return .maxKey
            default: throw BSONError.malformed("unknown type 0x\(String(type, radix: 16))")
            }
        }
    }
}

nonisolated enum BSONEncoder {
    static func encode(_ doc: BSONDocument) -> Data {
        var out = Data()
        writeDocument(doc.elements, into: &out)
        return out
    }

    private static func le<T: FixedWidthInteger>(_ v: T, _ out: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func cstring(_ s: String, _ out: inout Data) {
        out.append(contentsOf: Array(s.utf8).filter { $0 != 0 })
        out.append(0)
    }

    private static func string(_ s: String, _ out: inout Data) {
        let bytes = Array(s.utf8)
        le(Int32(bytes.count + 1), &out)
        out.append(contentsOf: bytes)
        out.append(0)
    }

    private static func writeDocument(_ elements: [BSONElement], into out: inout Data) {
        let start = out.count
        le(Int32(0), &out)
        for element in elements {
            out.append(typeByte(element.value))
            cstring(element.key, &out)
            writeValue(element.value, &out)
        }
        out.append(0)
        let len = Int32(out.count - start)
        withUnsafeBytes(of: len.littleEndian) { out.replaceSubrange(start..<(start + 4), with: $0) }
    }

    static func typeByte(_ value: BSONValue) -> UInt8 {
        switch value {
        case .double: return 0x01
        case .string: return 0x02
        case .document: return 0x03
        case .array: return 0x04
        case .binary: return 0x05
        case .undefined: return 0x06
        case .objectId: return 0x07
        case .bool: return 0x08
        case .date: return 0x09
        case .null: return 0x0A
        case .regex: return 0x0B
        case .dbPointer: return 0x0C
        case .code: return 0x0D
        case .symbol: return 0x0E
        case .codeWithScope: return 0x0F
        case .int32: return 0x10
        case .timestamp: return 0x11
        case .int64: return 0x12
        case .decimal128: return 0x13
        case .minKey: return 0xFF
        case .maxKey: return 0x7F
        }
    }

    private static func writeValue(_ value: BSONValue, _ out: inout Data) {
        switch value {
        case .double(let d): le(d.bitPattern, &out)
        case .string(let s), .code(let s), .symbol(let s): string(s, &out)
        case .document(let doc): writeDocument(doc.elements, into: &out)
        case .array(let items):
            writeDocument(items.enumerated().map { BSONElement(key: String($0.offset), value: $0.element) }, into: &out)
        case .binary(let subtype, let data):
            if subtype == 0x02 {
                le(Int32(data.count + 4), &out)
                out.append(subtype)
                le(Int32(data.count), &out)
            } else {
                le(Int32(data.count), &out)
                out.append(subtype)
            }
            out.append(data)
        case .undefined, .null, .minKey, .maxKey: break
        case .objectId(let oid): out.append(contentsOf: oid.bytes)
        case .bool(let b): out.append(b ? 1 : 0)
        case .date(let ms): le(ms, &out)
        case .regex(let pattern, let options):
            cstring(pattern, &out)
            cstring(String(options.sorted()), &out)
        case .dbPointer(let ref, let id):
            string(ref, &out)
            out.append(contentsOf: id.bytes)
        case .codeWithScope(let code, let scope):
            var inner = Data()
            string(code, &inner)
            writeDocument(scope.elements, into: &inner)
            le(Int32(inner.count + 4), &out)
            out.append(inner)
        case .int32(let v): le(v, &out)
        case .timestamp(let t, let i):
            le(i, &out)
            le(t, &out)
        case .int64(let v): le(v, &out)
        case .decimal128(let d):
            le(d.low, &out)
            le(d.high, &out)
        }
    }
}

/// Bridges to libbson for MongoDB Extended JSON (used to talk to the JavaScript shell).
nonisolated enum ExtendedJSON {
    static func canonical(_ doc: BSONDocument) -> String {
        doc.withBSON(canonical)
    }

    static func canonical(_ bson: UnsafePointer<bson_t>) -> String {
        var length = 0
        guard let json = bson_as_canonical_extended_json(bson, &length) else { return "{}" }
        defer { bson_free(json) }
        return String(cString: json)
    }

    static func parse(_ json: String) throws -> BSONDocument {
        var error = bson_error_t()
        var text = json
        guard let bson = text.withUTF8({ bson_new_from_json($0.baseAddress, $0.count, &error) }) else {
            throw MongoError(error)
        }
        defer { bson_destroy(bson) }
        return try BSONDecoder.decode(bson)
    }
}

nonisolated extension BSONDocument {
    func withBSON<T>(_ body: (UnsafePointer<bson_t>) throws -> T) rethrows -> T {
        let data = BSONEncoder.encode(self)
        return try data.withUnsafeBytes { raw in
            var bson = bson_t()
            _ = bson_init_static(&bson, raw.bindMemory(to: UInt8.self).baseAddress!, data.count)
            return try body(&bson)
        }
    }
}
