import Foundation

/// Parses the relaxed "shell JSON" accepted by Robo 3T's document editor
/// (robomongo/shell/bson/json.cpp): unquoted keys, single quotes, ObjectId(), ISODate(), NumberLong() etc.
nonisolated struct ShellJSONParser {
    struct ParseError: Error, LocalizedError {
        var message: String
        var offset: Int
        var errorDescription: String? { message }
    }

    private let chars: [UInt8]
    private var pos = 0

    init(_ text: String) {
        chars = Array(text.utf8)
    }

    static func parseDocuments(_ text: String) throws -> [BSONDocument] {
        var parser = ShellJSONParser(text)
        var docs: [BSONDocument] = []
        parser.skipWhitespace()
        while parser.pos < parser.chars.count {
            let value = try parser.parseValue()
            guard case .document(let doc) = value else {
                throw ParseError(message: "Expecting '{'", offset: parser.pos)
            }
            docs.append(doc)
            parser.skipWhitespace()
            if parser.peek() == UInt8(ascii: ",") || parser.peek() == UInt8(ascii: ";") {
                parser.pos += 1
                parser.skipWhitespace()
            }
        }
        return docs
    }

    /// Converts a UTF-8 byte offset into a zero-based (line, column) pair.
    static func lineAndColumn(in text: String, offset: Int) -> (Int, Int) {
        var line = 0
        var column = 0
        for (index, byte) in text.utf8.enumerated() {
            if index >= offset { break }
            if byte == UInt8(ascii: "\n") {
                line += 1
                column = 0
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return (line, column)
    }

    // MARK: Lexing

    private func peek(_ ahead: Int = 0) -> UInt8? {
        pos + ahead < chars.count ? chars[pos + ahead] : nil
    }

    private func error(_ message: String) -> ParseError {
        ParseError(message: message, offset: pos)
    }

    private mutating func skipWhitespace() {
        while let c = peek() {
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C {
                pos += 1
            } else if c == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "/") {
                while let d = peek(), d != 0x0A { _ = d; pos += 1 }
            } else if c == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "*") {
                pos += 2
                while pos < chars.count, !(chars[pos] == UInt8(ascii: "*") && peek(1) == UInt8(ascii: "/")) { pos += 1 }
                pos = min(pos + 2, chars.count)
            } else {
                break
            }
        }
    }

    private mutating func readToken(_ token: String) -> Bool {
        skipWhitespace()
        let bytes = token.utf8
        guard pos + bytes.count <= chars.count, chars[pos..<(pos + bytes.count)].elementsEqual(bytes) else { return false }
        if let last = bytes.last, Self.isIdentChar(last), let next = peek(bytes.count), Self.isIdentChar(next) {
            return false
        }
        pos += bytes.count
        return true
    }

    private mutating func expect(_ token: String) throws {
        if !readToken(token) { throw error("Expecting '\(token)'") }
    }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
    }

    private static func isIdentChar(_ c: UInt8) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    // MARK: Values

    private mutating func parseValue() throws -> BSONValue {
        skipWhitespace()
        guard let c = peek() else { throw error("Unexpected end of input") }
        switch c {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""), UInt8(ascii: "'"): return .string(try parseQuotedString())
        case UInt8(ascii: "/"): return try parseRegex()
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."): return try parseNumber()
        default: break
        }
        if readToken("new") { return try parseValue() }
        if readToken("ISODate") { return try parseDateCall(isoOnly: true) }
        if readToken("Date") { return try parseDateCall(isoOnly: false) }
        if readToken("UUID") { return try parseUUID(subtype: 4, encoding: .standard) }
        if readToken("LUUID") { return try parseUUID(subtype: 3, encoding: .standard) }
        if readToken("JUUID") { return try parseUUID(subtype: 3, encoding: .javaLegacy) }
        if readToken("NUUID") || readToken("CSUUID") { return try parseUUID(subtype: 3, encoding: .csharpLegacy) }
        if readToken("PYUUID") { return try parseUUID(subtype: 3, encoding: .pythonLegacy) }
        if readToken("Timestamp") {
            try expect("(")
            let t = try parseInteger()
            try expect(",")
            let i = try parseInteger()
            try expect(")")
            return .timestamp(t: UInt32(truncatingIfNeeded: t), i: UInt32(truncatingIfNeeded: i))
        }
        if readToken("ObjectId") {
            try expect("(")
            if readToken(")") { return .objectId(ObjectId.generate()) }
            let hex = try parseQuotedString()
            guard let oid = ObjectId(hex: hex) else { throw error("Invalid ObjectId") }
            try expect(")")
            return .objectId(oid)
        }
        if readToken("NumberLong") {
            try expect("(")
            let v = try parseQuotedOrBareInteger()
            try expect(")")
            return .int64(v)
        }
        if readToken("NumberInt") {
            try expect("(")
            let v = try parseQuotedOrBareInteger()
            try expect(")")
            guard let i32 = Int32(exactly: v) else { throw error("NumberInt out of range") }
            return .int32(i32)
        }
        if readToken("NumberDecimal") {
            try expect("(")
            let s: String
            if peek() == UInt8(ascii: "\"") || peek() == UInt8(ascii: "'") {
                s = try parseQuotedString()
            } else {
                s = try numberLiteral()
            }
            try expect(")")
            guard let d = Decimal128(string: s) else { throw error("Invalid NumberDecimal") }
            return .decimal128(d)
        }
        if readToken("DBRef") || readToken("Dbref") {
            try expect("(")
            let ref = try parseQuotedString()
            try expect(",")
            let idValue = try parseValue()
            try expect(")")
            if case .objectId(let oid) = idValue { return .dbPointer(ref: ref, id: oid) }
            if case .string(let s) = idValue, let oid = ObjectId(hex: s) { return .dbPointer(ref: ref, id: oid) }
            return .document(BSONDocument([("$ref", .string(ref)), ("$id", idValue)]))
        }
        if readToken("BinData") {
            try expect("(")
            let subtype = try parseInteger()
            try expect(",")
            let b64 = try parseQuotedString()
            try expect(")")
            guard let data = Data(base64Encoded: b64) else { throw error("Invalid base64 in BinData") }
            return .binary(subtype: UInt8(truncatingIfNeeded: subtype), data: data)
        }
        if readToken("HexData") {
            try expect("(")
            let subtype = try parseInteger()
            try expect(",")
            let hex = try parseQuotedString()
            try expect(")")
            guard let data = Data(hexString: hex) else { throw error("Invalid hex in HexData") }
            return .binary(subtype: UInt8(truncatingIfNeeded: subtype), data: data)
        }
        if readToken("MinKey") { _ = readToken("("); _ = readToken(")"); return .minKey }
        if readToken("MaxKey") { _ = readToken("("); _ = readToken(")"); return .maxKey }
        if readToken("true") { return .bool(true) }
        if readToken("false") { return .bool(false) }
        if readToken("null") { return .null }
        if readToken("undefined") { return .undefined }
        if readToken("NaN") { return .double(.nan) }
        if readToken("Infinity") { return .double(.infinity) }
        if readToken("-Infinity") { return .double(-.infinity) }
        return try parseNumber()
    }

    private mutating func parseObject() throws -> BSONValue {
        try expect("{")
        var doc = BSONDocument()
        if readToken("}") { return .document(doc) }
        while true {
            let key = try parseFieldName()
            try expect(":")
            doc.append(key, try parseValue())
            if readToken(",") {
                if readToken("}") { break }
                continue
            }
            try expect("}")
            break
        }
        return Self.convertSpecial(doc) ?? .document(doc)
    }

    private mutating func parseArray() throws -> BSONValue {
        try expect("[")
        var items: [BSONValue] = []
        if readToken("]") { return .array(items) }
        while true {
            items.append(try parseValue())
            if readToken(",") {
                if readToken("]") { break }
                continue
            }
            try expect("]")
            break
        }
        return .array(items)
    }

    private mutating func parseFieldName() throws -> String {
        skipWhitespace()
        guard let c = peek() else { throw error("Field name expected") }
        if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { return try parseQuotedString() }
        guard Self.isIdentStart(c) else { throw error("First character in field must be [A-Za-z$_]") }
        let start = pos
        while let d = peek(), Self.isIdentChar(d) { pos += 1 }
        return String(decoding: chars[start..<pos], as: UTF8.self)
    }

    private mutating func parseQuotedString() throws -> String {
        skipWhitespace()
        guard let quote = peek(), quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
            throw error("Expecting quoted string")
        }
        pos += 1
        var bytes: [UInt8] = []
        while true {
            guard let c = peek() else { throw error("Unterminated string") }
            pos += 1
            if c == quote { break }
            if c == UInt8(ascii: "\\") {
                guard let e = peek() else { throw error("Unterminated string") }
                pos += 1
                switch e {
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "v"): bytes.append(0x0B)
                case UInt8(ascii: "0"): bytes.append(0x00)
                case UInt8(ascii: "u"):
                    var scalarValue = try readHex4()
                    if (0xD800...0xDBFF).contains(scalarValue), peek() == UInt8(ascii: "\\"), peek(1) == UInt8(ascii: "u") {
                        pos += 2
                        let low = try readHex4()
                        scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                case UInt8(ascii: "x"):
                    guard pos + 2 <= chars.count, let v = UInt8(String(decoding: chars[pos..<(pos + 2)], as: UTF8.self), radix: 16) else {
                        throw error("Invalid \\x escape")
                    }
                    pos += 2
                    bytes.append(contentsOf: Array(String(Character(Unicode.Scalar(v))).utf8))
                default: bytes.append(e)
                }
            } else {
                bytes.append(c)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func readHex4() throws -> UInt32 {
        guard pos + 4 <= chars.count, let v = UInt32(String(decoding: chars[pos..<(pos + 4)], as: UTF8.self), radix: 16) else {
            throw error("Invalid \\u escape")
        }
        pos += 4
        return v
    }

    private mutating func parseRegex() throws -> BSONValue {
        pos += 1
        var pattern: [UInt8] = []
        while true {
            guard let c = peek() else { throw error("Unterminated regular expression") }
            pos += 1
            if c == UInt8(ascii: "/") { break }
            if c == UInt8(ascii: "\\"), let n = peek() {
                pos += 1
                if n != UInt8(ascii: "/") { pattern.append(c) }
                pattern.append(n)
                continue
            }
            pattern.append(c)
        }
        let start = pos
        while let c = peek(), (c >= 97 && c <= 122) { pos += 1 }
        let options = String(decoding: chars[start..<pos], as: UTF8.self)
        return .regex(pattern: String(decoding: pattern, as: UTF8.self), options: options)
    }

    private mutating func numberLiteral() throws -> String {
        skipWhitespace()
        let start = pos
        if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") { pos += 1 }
        while let c = peek(), (c >= 48 && c <= 57) || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
                || ((c == UInt8(ascii: "-") || c == UInt8(ascii: "+")) && (chars[pos - 1] == UInt8(ascii: "e") || chars[pos - 1] == UInt8(ascii: "E"))) {
            pos += 1
        }
        if start == pos { throw error("Bad characters in value") }
        return String(decoding: chars[start..<pos], as: UTF8.self)
    }

    private mutating func parseNumber() throws -> BSONValue {
        let start = pos
        let literal = try numberLiteral()
        let isFloating = literal.contains(where: { $0 == "." || $0 == "e" || $0 == "E" })
        if !isFloating, let v = Int64(literal) {
            if let i32 = Int32(exactly: v) { return .int32(i32) }
            return .int64(v)
        }
        guard let d = Double(literal) else {
            pos = start
            throw error("Bad characters in value")
        }
        return .double(d)
    }

    private mutating func parseInteger() throws -> Int64 {
        let literal = try numberLiteral()
        guard let v = Int64(literal) else { throw error("Expecting integer") }
        return v
    }

    private mutating func parseQuotedOrBareInteger() throws -> Int64 {
        skipWhitespace()
        if peek() == UInt8(ascii: "\"") || peek() == UInt8(ascii: "'") {
            let s = try parseQuotedString()
            guard let v = Int64(s.trimmingCharacters(in: .whitespaces)) else { throw error("Expecting number") }
            return v
        }
        let literal = try numberLiteral()
        if let v = Int64(literal) { return v }
        if let d = Double(literal), d == d.rounded(), abs(d) < 9.2e18 { return Int64(d) }
        throw error("Expecting number")
    }

    private mutating func parseDateCall(isoOnly: Bool) throws -> BSONValue {
        try expect("(")
        if readToken(")") { return .date(Int64(Date().timeIntervalSince1970 * 1000)) }
        skipWhitespace()
        let value: Int64
        if peek() == UInt8(ascii: "\"") || peek() == UInt8(ascii: "'") {
            let s = try parseQuotedString()
            guard let ms = Self.parseISODate(s) else { throw error("Invalid date string: \(s)") }
            value = ms
        } else {
            let literal = try numberLiteral()
            guard let d = Double(literal) else { throw error("Expecting date") }
            value = Int64(d)
        }
        try expect(")")
        return .date(value)
    }

    private mutating func parseUUID(subtype: UInt8, encoding: UUIDEncoding) throws -> BSONValue {
        try expect("(")
        let s = try parseQuotedString()
        try expect(")")
        guard let bytes = Data(hexString: s.replacingOccurrences(of: "-", with: "")).map(Array.init), bytes.count == 16 else {
            throw error("Invalid UUID")
        }
        return .binary(subtype: subtype, data: Data(encoding.reorder(bytes)))
    }

    /// Accepts "2016-07-21T14:07:09.000Z", "2016-07-21 14:07:09+02:00", "2016-07-21" and similar ISO-8601 forms.
    static func parseISODate(_ input: String) -> Int64? {
        let s = Array(input.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= s.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = s[i + k]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += n
            return v
        }
        func skip(_ c: Character) -> Bool {
            if i < s.count, s[i] == UInt8(ascii: c.unicodeScalars.first!) { i += 1; return true }
            return false
        }
        guard let year = digits(4), skip("-"), let month = digits(2), skip("-"), let day = digits(2) else { return nil }
        var hour = 0, minute = 0, second = 0, millis = 0
        var offsetSeconds = 0
        if i < s.count, s[i] == UInt8(ascii: "T") || s[i] == UInt8(ascii: " ") {
            i += 1
            guard let h = digits(2), skip(":"), let m = digits(2) else { return nil }
            hour = h
            minute = m
            if skip(":") {
                guard let sec = digits(2) else { return nil }
                second = sec
                if skip(".") {
                    var fraction = 0
                    var count = 0
                    while i < s.count, s[i] >= 48, s[i] <= 57 {
                        if count < 3 { fraction = fraction * 10 + Int(s[i] - 48) }
                        count += 1
                        i += 1
                    }
                    while count < 3 { fraction *= 10; count += 1 }
                    millis = fraction
                }
            }
            if skip("Z") {
            } else if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") {
                let sign = s[i] == UInt8(ascii: "-") ? -1 : 1
                i += 1
                guard let oh = digits(2) else { return nil }
                _ = skip(":")
                let om = digits(2) ?? 0
                offsetSeconds = sign * (oh * 3600 + om * 60)
            }
        }
        guard i == s.count else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970) * 1000 + Int64(millis) - Int64(offsetSeconds) * 1000
    }

    /// Maps Extended JSON wrapper objects ({"$oid": ...}, {"$date": ...}, ...) to their BSON types.
    static func convertSpecial(_ doc: BSONDocument) -> BSONValue? {
        guard let first = doc.elements.first, first.key.hasPrefix("$") else { return nil }
        switch (first.key, doc.count) {
        case ("$oid", 1):
            if let s = first.value.stringValue, let oid = ObjectId(hex: s) { return .objectId(oid) }
        case ("$date", 1):
            switch first.value {
            case .string(let s): return parseISODate(s).map { .date($0) }
            case .int32, .int64, .double: return first.value.intValue.map { .date(Int64($0)) }
            case .document(let inner): return inner["$numberLong"]?.stringValue.flatMap(Int64.init).map { .date($0) }
            default: return nil
            }
        case ("$numberLong", 1):
            if let s = first.value.stringValue, let v = Int64(s) { return .int64(v) }
        case ("$numberInt", 1):
            if let s = first.value.stringValue, let v = Int32(s) { return .int32(v) }
        case ("$numberDouble", 1):
            if let s = first.value.stringValue {
                switch s {
                case "NaN": return .double(.nan)
                case "Infinity": return .double(.infinity)
                case "-Infinity": return .double(-.infinity)
                default: return Double(s).map { .double($0) }
                }
            }
        case ("$numberDecimal", 1):
            if let s = first.value.stringValue, let d = Decimal128(string: s) { return .decimal128(d) }
        case ("$undefined", 1): return .undefined
        case ("$minKey", 1): return .minKey
        case ("$maxKey", 1): return .maxKey
        case ("$timestamp", 1):
            if let inner = first.value.documentValue, let t = inner["t"]?.intValue, let i = inner["i"]?.intValue {
                return .timestamp(t: UInt32(truncatingIfNeeded: t), i: UInt32(truncatingIfNeeded: i))
            }
        case ("$binary", 1):
            if let inner = first.value.documentValue, let b64 = inner["base64"]?.stringValue,
               let sub = inner["subType"]?.stringValue, let data = Data(base64Encoded: b64), let st = UInt8(sub, radix: 16) {
                return .binary(subtype: st, data: data)
            }
        case ("$binary", 2):
            if let b64 = first.value.stringValue, let data = Data(base64Encoded: b64) {
                let typeValue = doc["$type"]
                let st: UInt8? = typeValue?.stringValue.flatMap { UInt8($0, radix: 16) } ?? typeValue?.intValue.map { UInt8(truncatingIfNeeded: $0) }
                if let st { return .binary(subtype: st, data: data) }
            }
        case ("$uuid", 1):
            if let s = first.value.stringValue, let data = Data(hexString: s.replacingOccurrences(of: "-", with: "")), data.count == 16 {
                return .binary(subtype: 4, data: data)
            }
        case ("$regex", _):
            if let pattern = first.value.stringValue {
                return .regex(pattern: pattern, options: doc["$options"]?.stringValue ?? "")
            }
        case ("$regularExpression", 1):
            if let inner = first.value.documentValue, let pattern = inner["pattern"]?.stringValue {
                return .regex(pattern: pattern, options: inner["options"]?.stringValue ?? "")
            }
        default: break
        }
        return nil
    }
}
