import XCTest
@testable import RoboTribute

final class ReadOnlyTests: XCTestCase {
    func testOnlyReadCommandsPass() {
        for command: BSONDocument in [
            ["find": .string("c")], ["count": .string("c")], ["listCollections": .int32(1)], ["serverStatus": .int32(1)],
            ["aggregate": .string("c"), "pipeline": .array([.document(["$match": .document([:])])])],
        ] {
            XCTAssertTrue(PooledClient.isReadOnly(command), "\(command.elements.first!.key)")
        }
        for command: BSONDocument in [
            ["insert": .string("c")], ["update": .string("c")], ["delete": .string("c")], ["findAndModify": .string("c")],
            ["drop": .string("c")], ["dropDatabase": .int32(1)], ["createIndexes": .string("c")], ["renameCollection": .string("a.b")],
            ["mapReduce": .string("c")], ["killOp": .int32(1)], ["somethingNew": .int32(1)],
            ["aggregate": .string("c"), "pipeline": .array([.document(["$out": .string("x")])])],
            ["aggregate": .string("c"), "pipeline": .array([.document(["$facet": .document(["a": .array([.document(["$merge": .string("x")])])])])])],
        ] {
            XCTAssertFalse(PooledClient.isReadOnly(command), "\(command.elements.first!.key)")
        }
    }
}

/// Runs against the disposable local mongod used by ShellTests.
final class ReadOnlyConnectionTests: XCTestCase {
    private static let port = Int(ProcessInfo.processInfo.environment["ROBO3T_TEST_PORT"] ?? "27999") ?? 27999

    private func connection(readOnly: Bool) throws -> MongoConnection {
        var settings = ConnectionSettings()
        settings.serverHost = "127.0.0.1"
        settings.serverPort = Self.port
        settings.readOnly = readOnly
        do {
            return try MongoConnection(settings: settings, secrets: ConnectionSecrets(), timeoutSeconds: 3)
        } catch {
            throw XCTSkip("No test mongod on port \(Self.port): \(error)")
        }
    }

    func testReadOnlyConnectionBlocksEveryWritePath() async throws {
        let writable = try connection(readOnly: false)
        try writable.dropCollection(db: "robo_test", name: "ro")
        try writable.insert(db: "robo_test", collection: "ro", documents: [["_id": .int32(1), "a": .double(1.5)]])

        let readOnly = try connection(readOnly: true)
        XCTAssertEqual(try readOnly.find(db: "robo_test", collection: "ro", options: .init()).count, 1)
        XCTAssertThrowsError(try readOnly.insert(db: "robo_test", collection: "ro", documents: [["_id": .int32(2)]]))
        XCTAssertThrowsError(try readOnly.replace(db: "robo_test", collection: "ro", id: .int32(1), with: ["_id": .int32(1)]))
        XCTAssertThrowsError(try readOnly.dropCollection(db: "robo_test", name: "ro"))
        XCTAssertThrowsError(try readOnly.duplicateCollection(db: "robo_test", from: "ro", to: "ro_copy"))

        let shell = MongoShell(connection: readOnly, databaseName: "robo_test")
        for script in ["db.ro.insertOne({_id: 3})", "db.ro.deleteMany({})", "db.ro.updateOne({_id: 1}, {$set: {a: 2}})",
                       "db.ro.aggregate([{$out: 'ro_copy'}])", "db.runCommand({drop: 'ro'})", "db.getSiblingDB('admin').runCommand({dropDatabase: 1})"] {
            let result = await shell.execute(script, timeoutSeconds: 5, batchSize: 50)
            XCTAssertTrue(result.error?.contains("read-only") ?? false, "\(script): \(result.error ?? "no error")")
        }
        let read = await shell.execute("db.ro.find().toArray()", timeoutSeconds: 5, batchSize: 50)
        XCTAssertNil(read.error)

        let docs = try writable.find(db: "robo_test", collection: "ro", options: .init())
        XCTAssertEqual(docs.count, 1)
        guard case .double(1.5)? = docs.first?["a"] else { return XCTFail("document changed: \(docs)") }
        XCTAssertEqual(try writable.listCollections(db: "robo_test").contains { $0.name == "ro_copy" }, false)
    }

    func testReplaceNeverRecreatesADeletedDocument() throws {
        let writable = try connection(readOnly: false)
        try writable.dropCollection(db: "robo_test", name: "gone")
        XCTAssertThrowsError(try writable.replace(db: "robo_test", collection: "gone", id: .int32(1), with: ["_id": .int32(1)]))
        XCTAssertEqual(try writable.find(db: "robo_test", collection: "gone", options: .init()).count, 0)
    }
}

/// Runs against a disposable single-member replica set on 127.0.0.1; set ROBO3T_RS_PORT to enable.
final class LocalReplicaSetTests: XCTestCase {
    func testLocalReplicaSetConnectsWithoutTLS() throws {
        guard let port = ProcessInfo.processInfo.environment["ROBO3T_RS_PORT"] else { throw XCTSkip("ROBO3T_RS_PORT not set") }
        var settings = ConnectionSettings()
        settings.connectionType = .replicaSet
        settings.replicaSetMembers = ["127.0.0.1:\(port)"]
        settings.replicaSetName = "rs0"
        let connection = try MongoConnection(settings: settings, secrets: ConnectionSecrets(), timeoutSeconds: 5)
        XCTAssertFalse(try connection.listDatabases().isEmpty)
    }
}
