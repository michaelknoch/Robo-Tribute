import Foundation
import CMongoC

nonisolated struct ObjectId: Hashable, Sendable {
    var bytes: [UInt8]

    init(bytes: [UInt8]) { self.bytes = bytes }

    init?(hex: String) {
        guard let data = Data(hexString: hex), data.count == 12 else { return nil }
        bytes = Array(data)
    }

    static func generate() -> ObjectId {
        var oid = bson_oid_t()
        bson_oid_init(&oid, nil)
        return ObjectId(bytes: withUnsafeBytes(of: oid.bytes) { Array($0) })
    }

    var hex: String { bytes.hexString }

    var timestampSeconds: UInt32 {
        UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}

nonisolated struct Decimal128: Hashable, Sendable {
    var low: UInt64
    var high: UInt64

    var stringValue: String {
        var dec = bson_decimal128_t(low: low, high: high)
        var buffer = [CChar](repeating: 0, count: Int(BSON_DECIMAL128_STRING))
        bson_decimal128_to_string(&dec, &buffer)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    init?(string: String) {
        var dec = bson_decimal128_t()
        guard bson_decimal128_from_string(string, &dec) else { return nil }
        low = dec.low
        high = dec.high
    }
}

nonisolated indirect enum BSONValue: Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(subtype: UInt8, data: Data)
    case undefined
    case objectId(ObjectId)
    case bool(Bool)
    case date(Int64)
    case null
    case regex(pattern: String, options: String)
    case dbPointer(ref: String, id: ObjectId)
    case code(String)
    case symbol(String)
    case codeWithScope(code: String, scope: BSONDocument)
    case int32(Int32)
    case timestamp(t: UInt32, i: UInt32)
    case int64(Int64)
    case decimal128(Decimal128)
    case minKey
    case maxKey

    var isContainer: Bool {
        switch self {
        case .document, .array: return true
        default: return false
        }
    }

    var documentValue: BSONDocument? {
        if case .document(let doc) = self { return doc }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int32(let v): return Int(v)
        case .int64(let v): return Int(v)
        case .double(let v) where v.isFinite: return Int(v)
        default: return nil
        }
    }

}

nonisolated struct BSONElement: Sendable {
    var key: String
    var value: BSONValue
}

nonisolated struct BSONDocument: Sendable {
    var elements: [BSONElement] = []

    init() {}

    init(_ elements: [(String, BSONValue)]) {
        self.elements = elements.map { BSONElement(key: $0.0, value: $0.1) }
    }

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }

    subscript(key: String) -> BSONValue? {
        get { elements.first { $0.key == key }?.value }
        set {
            if let index = elements.firstIndex(where: { $0.key == key }) {
                if let newValue { elements[index].value = newValue } else { elements.remove(at: index) }
            } else if let newValue {
                elements.append(BSONElement(key: key, value: newValue))
            }
        }
    }

    mutating func append(_ key: String, _ value: BSONValue) {
        elements.append(BSONElement(key: key, value: value))
    }
}

nonisolated private let hexDigits = Array("0123456789abcdef".utf8)

nonisolated extension Sequence where Element == UInt8 {
    var hexString: String {
        var out: [UInt8] = []
        out.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

nonisolated extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        self = out
    }
}
