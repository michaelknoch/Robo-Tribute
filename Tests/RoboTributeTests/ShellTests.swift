import XCTest
@testable import RoboTribute

/// Runs against a disposable local mongod; set ROBO3T_TEST_PORT (defaults to 27999) and seed it first.
final class ShellTests: XCTestCase {
    private static let port = Int(ProcessInfo.processInfo.environment["ROBO3T_TEST_PORT"] ?? "27999") ?? 27999
    private static let connection = Result {
        var settings = ConnectionSettings()
        settings.serverHost = "127.0.0.1"
        settings.serverPort = port
        let connection = try MongoConnection(settings: settings, secrets: ConnectionSecrets(), timeoutSeconds: 10)
        return connection
    }

    override func setUpWithError() throws {
        if case .failure(let error) = Self.connection { throw XCTSkip("No test mongod on port \(Self.port): \(error)") }
    }

    private func shell(_ db: String = "robo_test") throws -> MongoShell {
        MongoShell(connection: try Self.connection.get(), databaseName: db)
    }

    private func run(_ script: String, _ shell: MongoShell) async -> ShellExecResult {
        let result = await shell.execute(script, timeoutSeconds: 15, batchSize: 50)
        if let error = result.error { XCTFail("script failed: \(error)\n\(script)") }
        return result
    }

    func testCrudWithLegacyAndModernSyntax() async throws {
        let s = try shell()
        _ = await run("db.items.drop()", s)
        var r = await run("db.items.insert({_id: 1, a: 1, d: 2.5})", s)
        XCTAssertEqual(r.results.last?.text.hasPrefix("Inserted 1 record(s) in"), true)
        r = await run("db.items.insertMany([{_id: 2, a: 2}, {_id: 3, a: 3}])", s)
        r = await run("db.items.update({_id: 1}, {$set: {a: 10}})", s)
        XCTAssertEqual(r.results.last?.text.hasPrefix("Updated 1 existing record(s) in"), true)
        r = await run("db.items.update({_id: 9}, {$set: {a: 9}}, {upsert: true})", s)
        XCTAssertEqual(r.results.last?.text.hasPrefix("Updated 1 new record(s) in"), true)
        r = await run("db.items.updateMany({a: {$gt: 1}}, {$inc: {a: 1}})", s)
        r = await run("db.items.remove({_id: 9})", s)
        XCTAssertEqual(r.results.last?.text.hasPrefix("Removed 1 record(s) in"), true)
        r = await run("db.items.deleteOne({_id: 3})", s)
        r = await run("db.items.count()", s)
        XCTAssertEqual(r.results.last?.text, "2")
        r = await run("db.items.findOne({_id: 1})", s)
        guard case .document(let doc)? = r.results.last?.documents.first else { return XCTFail("no doc") }
        guard case .int32(11)? = doc["a"], case .double(2.5)? = doc["d"] else { return XCTFail("types lost: \(doc.elements)") }
    }

    func testFindReturnsQueryInfoAndPages() async throws {
        let s = try shell("sample")
        let r = await run("db.getCollection('records').find({}).sort({n: 1})", s)
        let result = try XCTUnwrap(r.results.first)
        let query = try XCTUnwrap(result.query)
        XCTAssertEqual(query.collection, "records")
        XCTAssertEqual(result.documents.count, 50)
        let page2 = try await s.loadQuery(query, skip: 50, limit: 50)
        XCTAssertEqual(page2.first?["n"]?.intValue, 50)
    }

    func testMultipleStatementsAndPrint() async throws {
        let s = try shell("sample")
        let r = await run("""
        var x = 5;
        print('hello ' + x)
        db.records.find({n: {$lt: 3}})
        db.records.aggregate([{$group: {_id: null, c: {$sum: 1}}}])
        """, s)
        XCTAssertEqual(r.results.count, 3)
        XCTAssertEqual(r.results[0].text, "hello 5")
        XCTAssertEqual(r.results[1].documents.count, 3)
        XCTAssertNotNil(r.results[2].aggregate)
        XCTAssertEqual(r.results[2].documents.count, 1)
    }

    func testUseShowAndTypes() async throws {
        let s = try shell()
        var r = await run("use sample\nshow collections", s)
        XCTAssertEqual(r.databaseName, "sample")
        XCTAssertTrue(r.results.last?.text.contains("records") ?? false)
        r = await run("db.people.find({created: {$gte: ISODate('2016-01-01')}, _id: 'doc-0001'}).toArray()", s)
        guard case .array(let docs)? = r.results.first?.documents.first, case .document(let doc)? = docs.first else {
            return XCTFail("no array")
        }
        guard case .int64(1_234_567_890_123)? = doc["count"], case .decimal128? = doc["dec"], case .binary(4, _)? = doc["uuid"] else {
            return XCTFail("types lost")
        }
    }

    func testErrorsAreReported() async throws {
        let s = try shell()
        var result = await s.execute("db.items.find({$badOp: 1}).toArray()", timeoutSeconds: 15, batchSize: 50)
        XCTAssertNotNil(result.error)
        result = await s.execute("db.items.find({", timeoutSeconds: 15, batchSize: 50)
        XCTAssertTrue(result.error?.hasPrefix("SyntaxError") ?? false)
    }

    func testTimeoutEndsRunawayScript() async throws {
        let result = try await shell().execute("while (true) {}", timeoutSeconds: 1, batchSize: 50)
        XCTAssertTrue(result.timedOut)
    }

    func testStopInterruptsRunningScript() async throws {
        let s = try shell()
        async let result = s.execute("while (true) {}", timeoutSeconds: 30, batchSize: 50)
        try await Task.sleep(for: .milliseconds(300))
        s.stop()
        let stopped = await result
        XCTAssertEqual(stopped.error, "Script execution was stopped")
    }

    func testTimeoutEndsSleepingScript() async throws {
        let result = try await shell().execute("sleep(60000)", timeoutSeconds: 1, batchSize: 50)
        XCTAssertTrue(result.timedOut)
    }

    func testStopReachesQueuedRun() async throws {
        let s = try shell()
        async let running = s.execute("sleep(60000)", timeoutSeconds: 30, batchSize: 50)
        try await Task.sleep(for: .milliseconds(200))
        async let queued = s.execute("while (true) {}", timeoutSeconds: 30, batchSize: 50)
        try await Task.sleep(for: .milliseconds(200))
        s.stop()
        let (first, second) = await (running, queued)
        XCTAssertEqual(first.error, "Script execution was stopped")
        XCTAssertTrue(second.results.isEmpty)
    }

    func testCursorIterationAndForEach() async throws {
        let s = try shell("sample")
        let r = await run("var total = 0; db.records.find().forEach(function (d) { total += d.n; }); total", s)
        XCTAssertEqual(r.results.last?.text, "7140")
    }
}
