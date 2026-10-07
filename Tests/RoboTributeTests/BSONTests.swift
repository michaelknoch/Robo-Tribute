import XCTest
@testable import RoboTribute

final class BSONTests: XCTestCase {
    func testRoundTrip() throws {
        let doc = BSONDocument([
            ("_id", .objectId(ObjectId(hex: "5f1d7a8b9c0d1e2f3a4b5c6d")!)),
            ("i", .int32(3)), ("l", .int64(1_234_567_890_123)), ("d", .double(9.5)),
            ("s", .string("héllo")), ("a", .array([.int32(1), .string("x")])),
            ("o", .document(BSONDocument([("x", .bool(true))]))), ("n", .null),
            ("t", .date(1_469_110_029_000)), ("r", .regex(pattern: "abc", options: "i")),
            ("ts", .timestamp(t: 5, i: 7)), ("b", .binary(subtype: 4, data: Data(repeating: 1, count: 16))),
        ])
        let decoded = try doc.withBSON { try BSONDecoder.decode($0) }
        XCTAssertEqual(BSONFormatter(uuidEncoding: .standard, timeZone: .utc).jsonString(decoded),
                       BSONFormatter(uuidEncoding: .standard, timeZone: .utc).jsonString(doc))
        XCTAssertEqual(decoded.elements.map(\.key), doc.elements.map(\.key))
    }

    func testRoboJSONFormatting() {
        let f = BSONFormatter(uuidEncoding: .standard, timeZone: .utc)
        let doc = BSONDocument([
            ("_id", .string("doc-0001")), ("public", .bool(true)),
            ("chapters", .array([.string("a"), .string("b")])), ("level", .int32(3)), ("price", .double(3)),
            ("count", .int64(5)), ("when", .date(1_469_110_029_000)), ("empty", .array([])),
        ])
        XCTAssertEqual(f.jsonString(doc), """
        {
            "_id" : "doc-0001",
            "public" : true,
            "chapters" : [ \n        "a", \n        "b"
            ],
            "level" : 3,
            "price" : 3.0,
            "count" : NumberLong(5),
            "when" : ISODate("2016-07-21T14:07:09.000Z"),
            "empty" : []
        }
        """)
        XCTAssertEqual(f.displayValue(.date(1_469_110_029_000)), "2016-07-21 14:07:09.000Z")
        XCTAssertEqual(f.displayValue(.objectId(ObjectId(hex: "5f1d7a8b9c0d1e2f3a4b5c6d")!)), "ObjectId(\"5f1d7a8b9c0d1e2f3a4b5c6d\")")
        XCTAssertEqual(BSONFormatter.formatDouble(0.1), "0.1")
        XCTAssertEqual(BSONFormatter.formatDouble(1e21), "1e+21")
        XCTAssertEqual(f.typeName(.int32(1)), "Int32")
        XCTAssertEqual(BSONFormatter.objectSummary(1), "{ 1 field }")
        XCTAssertEqual(BSONFormatter.arraySummary(70), "[ 70 elements ]")
    }

    func testShellJSONParserPreservesTypes() throws {
        let docs = try ShellJSONParser.parseDocuments("""
        {
            _id : ObjectId("5f1d7a8b9c0d1e2f3a4b5c6d"),
            'single' : 'q',
            "i" : 3, "d" : 3.0, "big" : 9007199254740993, "l" : NumberLong("12"), "ni": NumberInt(7),
            "dec" : NumberDecimal("1.50"), "date" : ISODate("2016-07-21T14:07:09.123Z"),
            "u" : UUID("01234567-89ab-cdef-0123-456789abcdef"), "re" : /a\\/b/i, "ts" : Timestamp(5, 7),
            "n" : null, "arr" : [1, "x", {a: true}], // comment
            "ext" : { "$oid" : "5f1d7a8b9c0d1e2f3a4b5c6d" }
        }
        """)
        XCTAssertEqual(docs.count, 1)
        let d = docs[0]
        guard case .int32(3)? = d["i"], case .double(3.0)? = d["d"], case .int64(9_007_199_254_740_993)? = d["big"],
              case .int64(12)? = d["l"], case .int32(7)? = d["ni"], case .decimal128(let dec)? = d["dec"],
              case .date(1_469_110_029_123)? = d["date"], case .binary(4, _)? = d["u"], case .regex("a/b", "i")? = d["re"],
              case .timestamp(5, 7)? = d["ts"], case .null? = d["n"], case .objectId? = d["ext"], case .string("q")? = d["single"] else {
            return XCTFail("unexpected types: \(BSONFormatter(uuidEncoding: .standard, timeZone: .utc).jsonString(d))")
        }
        XCTAssertEqual(dec.stringValue, "1.50")
    }

    func testRoundTripThroughEditorFormat() throws {
        let f = BSONFormatter(uuidEncoding: .standard, timeZone: .utc)
        let original = BSONDocument([
            ("i", .int32(3)), ("d", .double(3)), ("l", .int64(4)), ("s", .string("tab\t\"q\"")),
            ("t", .date(-1000)), ("b", .binary(subtype: 0, data: Data([1, 2, 3]))), ("m", .minKey),
        ])
        let parsed = try ShellJSONParser.parseDocuments(f.jsonString(original))
        XCTAssertEqual(f.jsonString(parsed[0]), f.jsonString(original))
    }

    func testParseErrorOffset() {
        XCTAssertThrowsError(try ShellJSONParser.parseDocuments("{\n  a: 1,\n  b: ]\n}")) { error in
            let e = error as! ShellJSONParser.ParseError
            let (line, _) = ShellJSONParser.lineAndColumn(in: "{\n  a: 1,\n  b: ]\n}", offset: e.offset)
            XCTAssertEqual(line, 2)
        }
    }
}
