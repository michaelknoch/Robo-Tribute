import Foundation

nonisolated enum UUIDEncoding: Int, Codable, CaseIterable {
    case standard = 0, javaLegacy = 1, csharpLegacy = 2, pythonLegacy = 3

    /// Byte order of legacy (subtype 3) UUIDs written by the Java and .NET drivers; the mapping is its own inverse.
    func reorder(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count == 16 else { return bytes }
        switch self {
        case .javaLegacy: return bytes[0..<8].reversed() + bytes[8..<16].reversed()
        case .csharpLegacy: return bytes[0..<4].reversed() + bytes[4..<6].reversed() + bytes[6..<8].reversed() + Array(bytes[8..<16])
        case .standard, .pythonLegacy: return bytes
        }
    }
}

nonisolated enum TimeZoneMode: Int, Codable {
    case utc = 0, local = 1
}

/// Reproduces Robo 3T's BsonUtils formatting (robomongo/core/utils/BsonUtils.cpp).
nonisolated struct BSONFormatter: Sendable {
    var uuidEncoding: UUIDEncoding
    var timeZone: TimeZoneMode

    @MainActor static var current: BSONFormatter {
        BSONFormatter(uuidEncoding: AppSettings.shared.uuidEncoding, timeZone: AppSettings.shared.timeZone)
    }

    private static let minDate: Int64 = -9_218_988_800_000
    private static let maxDate: Int64 = 9_218_988_800_000

    // MARK: Shell (TenGen) JSON

    func jsonString(_ doc: BSONDocument, pretty: Int = 1) -> String {
        var out = ""
        writeObject(doc.elements, pretty: pretty, isArray: false, into: &out)
        return out
    }

    /// Top-level arrays use the object layout, nested arrays the "[ " layout, exactly as in BsonUtils.cpp.
    func jsonString(array: [BSONValue], pretty: Int = 1) -> String {
        var out = ""
        writeObject(array.enumerated().map { BSONElement(key: String($0.offset), value: $0.element) }, pretty: pretty, isArray: true, into: &out)
        return out
    }

    func json(_ value: BSONValue) -> String {
        switch value {
        case .document(let doc): return jsonString(doc)
        case .array(let items): return jsonString(array: items)
        default:
            var out = ""
            writeValue(value, pretty: 1, into: &out)
            return out
        }
    }

    private static let indents = (0..<64).map { String(repeating: "    ", count: $0) }

    private func indent(_ n: Int) -> String {
        n < Self.indents.count ? Self.indents[max(n, 0)] : String(repeating: "    ", count: n)
    }

    private func writeObject(_ elements: [BSONElement], pretty: Int, isArray: Bool, into out: inout String) {
        if elements.isEmpty {
            out += isArray ? "[]" : "{}"
            return
        }
        out += isArray ? "[" : "{"
        for (index, element) in elements.enumerated() {
            if pretty > 0 {
                out += "\n"
                out += indent(pretty)
            } else {
                out += " "
            }
            if !isArray {
                out += "\""
                out += Self.escape(element.key)
                out += "\" : "
            }
            writeValue(element.value, pretty: pretty > 0 ? pretty + 1 : 0, into: &out)
            if index == elements.count - 1 {
                out += "\n"
                out += indent(pretty - 1)
                out += isArray ? "]" : "}"
            } else {
                out += ","
            }
        }
    }

    private func writeValue(_ value: BSONValue, pretty: Int, into out: inout String) {
        switch value {
        case .undefined: out += "undefined"
        case .string(let v), .symbol(let v):
            out += "\""
            out += Self.escape(v)
            out += "\""
        case .int64(let v): out += "NumberLong(\(v))"
        case .int32(let v): out += String(v)
        case .double(let v): out += Self.formatDouble(v)
        case .decimal128(let d): out += "NumberDecimal(\"\(d.stringValue)\")"
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .document(let doc): writeObject(doc.elements, pretty: pretty, isArray: false, into: &out)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[ "
            for (index, item) in items.enumerated() {
                if pretty > 0 {
                    out += "\n"
                    out += indent(pretty)
                }
                writeValue(item, pretty: pretty > 0 ? pretty + 1 : 0, into: &out)
                if index == items.count - 1 {
                    out += "\n"
                    out += indent(pretty - 1)
                    out += "]"
                } else {
                    out += ", "
                }
            }
        case .dbPointer(let ref, let id): out += "DBRef(\"\(ref)\", \"\(id.hex)\")"
        case .objectId(let oid): out += "ObjectId(\"\(oid.hex)\")"
        case .binary(let subtype, let data):
            if subtype == 3 || subtype == 4 {
                out += formatUUID(subtype: subtype, data: data)
            } else {
                out += "{ \"$binary\" : \"\(data.base64EncodedString())\", \"$type\" : \"\([subtype].hexString)\" }"
            }
        case .date(let ms):
            let supported = Self.minDate < ms && ms < Self.maxDate
            out += supported ? "ISODate(" : "Date("
            out += pretty > 0 && supported ? "\"" + isoTime(ms, separator: "T") + "\"" : String(ms)
            out += ")"
        case .regex(let pattern, let options):
            // ShellJSONParser reads a /literal/ verbatim except for \/, so only patterns without / or a trailing \ survive that form.
            if pattern.contains("/") || pattern.hasSuffix("\\") || pattern.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                out += "{ \"$regex\" : \"" + Self.escape(pattern) + "\", \"$options\" : \"" + Self.escape(options) + "\" }"
            } else {
                out += "/" + pattern + "/" + options
            }
        case .codeWithScope(let code, let scope):
            if scope.isEmpty {
                out += code
            } else {
                out += "{ \"$code\" : \(code) ,  \"$scope\" : "
                writeObject(scope.elements, pretty: 0, isArray: false, into: &out)
                out += " }"
            }
        case .code(let code): out += code
        case .timestamp(let t, let i): out += "Timestamp(\(t), \(i))"
        case .minKey: out += "{ \"$minKey\" : 1 }"
        case .maxKey: out += "{ \"$maxKey\" : 1 }"
        }
    }

    // MARK: Tree / table cell value

    func displayValue(_ value: BSONValue) -> String {
        switch value {
        case .double(let v): return Self.formatDouble(v)
        case .string(let v), .symbol(let v), .code(let v): return v
        case .codeWithScope(let code, _): return code
        case .document(let doc): return Self.objectSummary(doc.count)
        case .array(let items): return Self.arraySummary(items.count)
        case .binary(let subtype, let data):
            return (subtype == 3 || subtype == 4) ? formatUUID(subtype: subtype, data: data) : "<binary>"
        case .undefined: return "undefined"
        case .objectId(let oid): return "ObjectId(\"\(oid.hex)\")"
        case .bool(let b): return b ? "true" : "false"
        case .date(let ms):
            let supported = Self.minDate < ms && ms < Self.maxDate
            return supported ? isoTime(ms, separator: " ") : "\(ms)"
        case .null: return "null"
        case .regex(let pattern, let options): return "/\(pattern)/" + options
        case .dbPointer: return ""
        case .int32(let v): return "\(v)"
        case .int64(let v): return "\(v)"
        case .timestamp(let t, _): return isoTime(Int64(t) * 1000, separator: "T")
        case .decimal128(let d): return d.stringValue
        case .minKey: return "{ \"$minKey\" : 1 }"
        case .maxKey: return "{ \"$maxKey\" : 1 }"
        }
    }

    static func objectSummary(_ count: Int) -> String { "{ \(count) \(count == 1 ? "field" : "fields") }" }
    static func arraySummary(_ count: Int) -> String { "[ \(count) \(count == 1 ? "element" : "elements") ]" }

    func typeName(_ value: BSONValue) -> String {
        switch value {
        case .double: return "Double"
        case .decimal128: return "Decimal128"
        case .string: return "String"
        case .document: return "Object"
        case .array: return "Array"
        case .binary(let subtype, _):
            if subtype == 4 { return "UUID" }
            if subtype == 3 {
                switch uuidEncoding {
                case .standard: return "Legacy UUID"
                case .javaLegacy: return "Java UUID (Legacy)"
                case .csharpLegacy: return ".NET UUID (Legacy)"
                case .pythonLegacy: return "Python UUID (Legacy)"
                }
            }
            return "Binary"
        case .undefined: return "Undefined"
        case .objectId: return "ObjectId"
        case .bool: return "Boolean"
        case .date: return "Date"
        case .null: return "Null"
        case .regex: return "Regular Expression"
        case .dbPointer: return "DBRef"
        case .code: return "Code"
        case .symbol: return "Symbol"
        case .codeWithScope: return "CodeWScope"
        case .int32: return "Int32"
        case .timestamp: return "Timestamp"
        case .int64: return "Int64"
        case .minKey, .maxKey: return "Type is not supported"
        }
    }

    // MARK: Helpers

    static func formatDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        // Swift's description is the shortest text that parses back to the same bits; %.15g is not.
        return d.description
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    func isoTime(_ ms: Int64, separator: Character) -> String {
        var offsetSeconds = 0
        if timeZone == .local {
            offsetSeconds = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }
        let local = ms + Int64(offsetSeconds) * 1000
        let msPerDay: Int64 = 86_400_000
        let days = local >= 0 ? local / msPerDay : (local - msPerDay + 1) / msPerDay
        let msOfDay = Int(local - days * msPerDay)

        // Civil date from days since 1970-01-01 (Howard Hinnant's days_from_civil inverse).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = Int(doy - (153 * mp + 2) / 5 + 1)
        let month = Int(mp < 10 ? mp + 3 : mp - 9)
        let year = Int(yoe + era * 400 + (month <= 2 ? 1 : 0))

        func pad(_ value: Int, _ width: Int) -> String {
            let s = String(value)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        var out = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + String(separator)
        out += pad(msOfDay / 3_600_000, 2) + ":" + pad(msOfDay / 60_000 % 60, 2) + ":" + pad(msOfDay / 1000 % 60, 2) + "." + pad(msOfDay % 1000, 3)
        if timeZone == .utc { return out + "Z" }
        let absOffset = abs(offsetSeconds)
        return out + (offsetSeconds >= 0 ? "+" : "-") + pad(absOffset / 3600, 2) + ":" + pad(absOffset % 3600 / 60, 2)
    }

    func formatUUID(subtype: UInt8, data: Data) -> String {
        guard data.count == 16 else { return "<binary>" }
        if subtype == 4 { return "UUID(\"\(Self.uuidString(Array(data)))\")" }
        let prefix: String
        switch uuidEncoding {
        case .javaLegacy: prefix = "JUUID"
        case .csharpLegacy: prefix = "NUUID"
        case .pythonLegacy: prefix = "PYUUID"
        case .standard: prefix = "LUUID"
        }
        return "\(prefix)(\"\(Self.uuidString(uuidEncoding.reorder(Array(data))))\")"
    }

    static func uuidString(_ bytes: [UInt8]) -> String {
        let hex = bytes.hexString
        let i = hex.utf8
        func part(_ a: Int, _ b: Int) -> Substring { hex[i.index(i.startIndex, offsetBy: a)..<i.index(i.startIndex, offsetBy: b)] }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }
}
