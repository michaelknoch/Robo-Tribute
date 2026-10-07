import Foundation
import os
import JavaScriptCore
import CryptoKit
import CMongoC
import CJSCPrivate

nonisolated struct QueryInfo: Sendable {
    var db: String
    var collection: String
    var spec: BSONDocument
    var skip: Int
    var limit: Int

    var hasProjection: Bool {
        if let p = spec["projection"]?.documentValue { return !p.isEmpty }
        return false
    }

    func findOptions(skip: Int, limit: Int, defaultMaxTimeMS: Int) -> MongoConnection.FindOptions {
        var o = MongoConnection.FindOptions()
        o.filter = spec["filter"]?.documentValue ?? BSONDocument()
        o.projection = spec["projection"]?.documentValue
        o.sort = spec["sort"]?.documentValue
        o.hint = spec["hint"]
        o.maxTimeMS = spec["maxTimeMS"]?.intValue ?? defaultMaxTimeMS
        o.collation = spec["collation"]?.documentValue
        o.skip = skip
        o.limit = limit
        return o
    }
}

nonisolated struct AggregateInfo: Sendable {
    var db: String
    var collection: String
    var pipeline: [BSONValue]
    var options: BSONDocument
}

nonisolated struct ShellResult: Sendable {
    var statement: String
    var documents: [BSONValue] = []
    var text = ""
    var query: QueryInfo?
    var aggregate: AggregateInfo?
    var elapsed: TimeInterval = 0

    var statementShort: String {
        let flat = statement.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "..." : flat
    }
}

nonisolated struct ShellExecResult: Sendable {
    var results: [ShellResult] = []
    var databaseName = ""
    var error: String?
    var timedOut = false
}

/// One JavaScript shell per query tab, like Robo 3T's MongoShell/ScriptEngine pair.
/// Its own serial queue keeps JSContext and libmongoc cursors on one thread and their blocking calls off the cooperative pool.
actor MongoShell {
    private enum Termination {
        case none, stopped, timedOut
    }

    let connection: MongoConnection
    private let queue = DispatchSerialQueue(label: "robo-tribute.shell", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private var databaseName: String
    private var context: JSContext?
    private var pooled: PooledClient?
    private var cursors: [Int: (cursor: OpaquePointer, destroyOwner: () -> Void)] = [:]
    private var nextCursorId = 1
    private var printed: [String] = []
    private var statementStart = Date()
    private var timeoutSeconds = 15
    private var batchSize = 50
    /// Counted when a run is submitted, before it queues on the actor, so Stop also reaches a run still waiting.
    private let runs = OSAllocatedUnfairLock(initialState: (submitted: 0, stopped: 0))
    private var currentRun = 0
    private var termination = Termination.none

    init(connection: MongoConnection, databaseName: String) {
        self.connection = connection
        self.databaseName = databaseName.isEmpty ? "test" : databaseName
    }

    private var stopRequested: Bool { runs.withLock { $0.stopped } >= currentRun }

    nonisolated func stop() {
        runs.withLock { $0.stopped = $0.submitted }
    }

    /// The shell keeps one pooled client for its lifetime, so cursors and paging share a connection.
    private func client() throws -> PooledClient {
        if let pooled { return pooled }
        let client = try connection.checkout()
        pooled = client
        return client
    }

    // MARK: Execution

    nonisolated func execute(_ script: String, timeoutSeconds: Int, batchSize: Int) async -> ShellExecResult {
        let id = runs.withLock { runs in
            runs.submitted += 1
            return runs.submitted
        }
        return await run(script, id: id, timeoutSeconds: timeoutSeconds, batchSize: batchSize)
    }

    private func run(_ script: String, id: Int, timeoutSeconds: Int, batchSize: Int) -> ShellExecResult {
        currentRun = id
        termination = .none
        self.timeoutSeconds = max(timeoutSeconds, 1)
        self.batchSize = max(batchSize, 1)
        var result = ShellExecResult()
        defer { closeCursors() }
        do {
            let ctx = try ensureContext()
            Self.arm(JSContextGetGroup(ctx.jsGlobalContextRef), Unmanaged.passUnretained(self).toOpaque())
            let split = ctx.objectForKeyedSubscript("__roboSplit").call(withArguments: [Self.preprocess(script)])?.toString() ?? "{}"
            let parsed = (try? JSONSerialization.jsonObject(with: Data(split.utf8))) as? [String: Any] ?? [:]
            if let error = parsed["error"] as? String {
                result.error = "SyntaxError: " + error
                result.databaseName = databaseName
                return result
            }
            for statement in parsed["statements"] as? [String] ?? [] {
                if stopRequested { break }
                printed = []
                statementStart = Date()
                ctx.exception = nil
                let value = ctx.evaluateScript(statement, withSourceURL: URL(string: "shell"))
                var description: JSValue?
                if ctx.exception == nil {
                    description = ctx.objectForKeyedSubscript("__roboDescribe").call(withArguments: [value as Any])
                }
                if let exception = ctx.exception {
                    flushPrintedAsResult(statement, into: &result)
                    switch termination {
                    case .timedOut: result.timedOut = true
                    case .stopped: result.error = "Script execution was stopped"
                    case .none: result.error = Self.describe(exception: exception)
                    }
                    break
                }
                var shellResult = try buildResult(statement: statement, description: description?.toString() ?? "")
                shellResult.elapsed = Date().timeIntervalSince(statementStart)
                if !shellResult.text.isEmpty || !shellResult.documents.isEmpty || shellResult.query != nil || shellResult.aggregate != nil {
                    result.results.append(shellResult)
                }
            }
            if let name = ctx.objectForKeyedSubscript("__roboDbName").call(withArguments: [])?.toString() {
                databaseName = name
            }
        } catch {
            result.error = error.localizedDescription
        }
        result.databaseName = databaseName
        return result
    }

    private func flushPrintedAsResult(_ statement: String, into result: inout ShellExecResult) {
        guard !printed.isEmpty else { return }
        var r = ShellResult(statement: statement)
        r.text = printed.joined(separator: "\n")
        r.elapsed = Date().timeIntervalSince(statementStart)
        result.results.append(r)
        printed = []
    }

    private func buildResult(statement: String, description: String) throws -> ShellResult {
        var result = ShellResult(statement: statement)
        let output = printed.joined(separator: "\n")
        let described = try ExtendedJSON.parse(description)
        switch described["kind"]?.stringValue {
        case "query":
            let spec = described["spec"]?.documentValue ?? BSONDocument()
            let info = QueryInfo(db: described["db"]?.stringValue ?? databaseName,
                                 collection: described["collection"]?.stringValue ?? "",
                                 spec: spec,
                                 skip: spec["skip"]?.intValue ?? 0,
                                 limit: spec["limit"]?.intValue ?? 0)
            let firstLimit = info.limit != 0 ? min(abs(info.limit), batchSize) : batchSize
            result.documents = try loadQuery(info, skip: info.skip, limit: firstLimit).map { .document($0) }
            result.query = info
        case "aggregate":
            var pipeline: [BSONValue] = []
            if case .array(let p)? = described["pipeline"] { pipeline = p }
            let info = AggregateInfo(db: described["db"]?.stringValue ?? databaseName,
                                     collection: described["collection"]?.stringValue ?? "",
                                     pipeline: pipeline,
                                     options: described["options"]?.documentValue ?? BSONDocument())
            result.documents = try loadAggregate(info, skip: 0, batchSize: batchSize).map { .document($0) }
            result.aggregate = info
        case "documents":
            if case .array(let docs)? = described["docs"] { result.documents = docs }
        case "array":
            if let value = described["value"] { result.documents = [value] }
        case "text":
            result.text = described["text"]?.stringValue ?? ""
        default:
            break
        }
        if !output.isEmpty {
            result.text = result.text.isEmpty ? output : output + "\n" + result.text
        }
        return result
    }

    // MARK: Paging (executed natively so BSON types survive untouched)

    func loadQuery(_ info: QueryInfo, skip: Int, limit: Int) throws -> [BSONDocument] {
        if limit < 0 { return [] }
        return try client().find(db: info.db, collection: info.collection,
                                 options: info.findOptions(skip: skip, limit: limit, defaultMaxTimeMS: timeoutSeconds * 1000))
    }

    func loadAggregate(_ info: AggregateInfo, skip: Int, batchSize: Int) throws -> [BSONDocument] {
        let batch = Int64(max(batchSize, 1))
        let pipeline = info.pipeline + [.document(["$skip": .int64(Int64(skip))]), .document(["$limit": .int64(batch)])]
        var options = info.options
        options["batchSize"] = .int64(batch)
        return try client().aggregate(db: info.db, collection: info.collection, pipeline: pipeline, options: options)
    }

    // MARK: Context

    private static let helperPattern = try! NSRegularExpression(pattern: #"^[ \t]*(show|use|set)[ \t]+([\w.$-]+)[ \t]*;?[ \t]*$"#,
                                                                 options: [.caseInsensitive, .anchorsMatchLines])

    private static func preprocess(_ script: String) -> String {
        helperPattern.stringByReplacingMatches(in: script, range: NSRange(script.startIndex..., in: script),
                                               withTemplate: "shellHelper('$1', '$2');")
    }

    private static func describe(exception: JSValue) -> String {
        var message = exception.toString() ?? "Unknown error"
        if let code = exception.objectForKeyedSubscript("code"), code.isNumber {
            message += " (code \(code.toInt32()))"
        }
        return message
    }

    private func ensureContext() throws -> JSContext {
        if let context { return context }
        guard let ctx = JSContext() else { throw MongoError("Unable to create JavaScript context") }
        ctx.name = "Robo Tribute shell"
        installNative(in: ctx)
        for script in ["esprima", "shell"] {
            guard let url = AppResources.bundle.url(forResource: script, withExtension: "js", subdirectory: "Resources"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw MongoError("Missing \(script).js resource")
            }
            ctx.evaluateScript(source, withSourceURL: url)
            if let exception = ctx.exception {
                throw MongoError("Failed to load \(script).js: \(exception)")
            }
        }
        context = ctx
        return ctx
    }

    /// Polled every 250ms of JS execution; ending the script implements both Stop and the shell timeout.
    /// JavaScriptCore asks only once per arming, so the callback re-arms itself.
    private static let watchdog: JSShouldTerminateCallback = { ctx, info in
        guard let ctx, let info else { return false }
        // Called synchronously from evaluateScript, so we are on the actor's queue.
        if Unmanaged<MongoShell>.fromOpaque(info).takeUnretainedValue().assumeIsolated({ $0.shouldTerminate() }) { return true }
        arm(JSContextGetGroup(ctx), info)
        return false
    }

    private static func arm(_ group: JSContextGroupRef, _ info: UnsafeMutableRawPointer) {
        JSContextGroupSetExecutionTimeLimit(group, 0.25, watchdog, info)
    }

    private func shouldTerminate() -> Bool {
        if stopRequested {
            termination = .stopped
        } else if Date().timeIntervalSince(statementStart) > TimeInterval(timeoutSeconds) {
            termination = .timedOut
        }
        return termination != .none
    }

    /// The watchdog only counts time spent running JavaScript, so a sleeping script checks Stop and the timeout itself.
    private func pause(milliseconds: Double) throws {
        let deadline = Date().addingTimeInterval(milliseconds / 1000)
        while Date() < deadline {
            if shouldTerminate() { throw MongoError(termination == .stopped ? "Script execution was stopped" : "Script execution timed out") }
            usleep(10_000)
        }
    }

    private func throwJS(_ error: Error) {
        guard let ctx = JSContext.current() else { return }
        let value = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
        if let mongo = error as? MongoError, mongo.code != 0 {
            value?.setObject(mongo.code, forKeyedSubscript: "code" as NSString)
        }
        ctx.exception = value
    }

    /// JavaScriptCore calls native functions synchronously from evaluateScript, i.e. on the actor's queue.
    private static func call<T: Sendable>(_ shell: MongoShell?, _ fallback: T, _ body: @Sendable (isolated MongoShell) throws -> T) -> T {
        shell?.assumeIsolated { isolatedShell in isolatedShell.bridge(fallback) { try body(isolatedShell) } } ?? fallback
    }

    private func bridge<T>(_ fallback: T, _ body: () throws -> T) -> T {
        if stopRequested {
            throwJS(MongoError("Script execution was stopped"))
            return fallback
        }
        do {
            return try body()
        } catch {
            throwJS(error)
            return fallback
        }
    }

    private func installNative(in ctx: JSContext) {
        let native = JSValue(newObjectIn: ctx)!
        let setFn: (String, Any) -> Void = { name, block in native.setObject(block, forKeyedSubscript: name as NSString) }

        setFn("print", { [weak self] (text: String) in
            self?.assumeIsolated { $0.printed.append(text) }
        } as @convention(block) (String) -> Void)

        setFn("host", { [weak self] () -> String in
            self?.connection.address ?? ""
        } as @convention(block) () -> String)

        setFn("initialDb", { [weak self] () -> String in
            self?.assumeIsolated { $0.databaseName } ?? "test"
        } as @convention(block) () -> String)

        setFn("newObjectId", { () -> String in
            ObjectId.generate().hex
        } as @convention(block) () -> String)

        setFn("randomUUIDHex", { () -> String in
            withUnsafeBytes(of: UUID().uuid) { $0.hexString }
        } as @convention(block) () -> String)

        setFn("parseISODate", { (s: String) -> Any in
            ShellJSONParser.parseISODate(s).map { Double($0) } ?? NSNull()
        } as @convention(block) (String) -> Any)

        setFn("hexToBase64", { (hex: String) -> String in
            Data(hexString: hex)?.base64EncodedString() ?? ""
        } as @convention(block) (String) -> String)

        setFn("base64ToHex", { (b64: String) -> String in
            (Data(base64Encoded: b64) ?? Data()).hexString
        } as @convention(block) (String) -> String)

        setFn("legacyUUIDToBase64", { (hex: String, encoding: Int) -> String in
            guard let bytes = Data(hexString: hex).map(Array.init), bytes.count == 16 else { return "" }
            return Data((UUIDEncoding(rawValue: encoding) ?? .standard).reorder(bytes)).base64EncodedString()
        } as @convention(block) (String, Int) -> String)

        setFn("md5", { (s: String) -> String in
            Insecure.MD5.hash(data: Data(s.utf8)).hexString
        } as @convention(block) (String) -> String)

        setFn("sleep", { [weak self] (ms: Double) in
            MongoShell.call(self, ()) { try $0.pause(milliseconds: ms) }
        } as @convention(block) (Double) -> Void)

        setFn("readFile", { [weak self] (path: String) -> String in
            MongoShell.call(self, "") { _ in try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) }
        } as @convention(block) (String) -> String)

        setFn("command", { [weak self] (db: String, json: String) -> String in
            MongoShell.call(self, "{}") { ExtendedJSON.canonical(try $0.client().runCommand(db: db, command: ExtendedJSON.parse(json))) }
        } as @convention(block) (String, String) -> String)

        setFn("find", { [weak self] (db: String, coll: String, specJSON: String) -> Int in
            MongoShell.call(self, 0) { shell in
                var spec = try ExtendedJSON.parse(specJSON)
                let filter = spec["filter"]?.documentValue ?? BSONDocument()
                spec["filter"] = nil
                return try shell.openCollectionCursor(db: db, collection: coll) { collection in
                    filter.withBSON { f in spec.withBSON { o in mongoc_collection_find_with_opts(collection, f, o, nil) } }
                }
            }
        } as @convention(block) (String, String, String) -> Int)

        setFn("aggregate", { [weak self] (db: String, coll: String, pipelineJSON: String, optionsJSON: String) -> Int in
            MongoShell.call(self, 0) { shell in
                let pipeline = try ExtendedJSON.parse("{\"pipeline\": \(pipelineJSON)}")
                let options = try ExtendedJSON.parse(optionsJSON)
                return try shell.openCollectionCursor(db: db, collection: coll) { collection in
                    pipeline.withBSON { p in options.withBSON { o in mongoc_collection_aggregate(collection, MONGOC_QUERY_NONE, p, o, nil) } }
                }
            }
        } as @convention(block) (String, String, String, String) -> Int)

        setFn("aggregateDb", { [weak self] (db: String, pipelineJSON: String, optionsJSON: String) -> Int in
            MongoShell.call(self, 0) { shell in
                let pipeline = try ExtendedJSON.parse("{\"pipeline\": \(pipelineJSON)}")
                let options = try ExtendedJSON.parse(optionsJSON)
                guard let database = mongoc_client_get_database(try shell.client().client, db) else { throw MongoError("Invalid database") }
                let cursor = pipeline.withBSON { p in options.withBSON { o in mongoc_database_aggregate(database, p, o, nil) } }
                return shell.register(cursor, destroyOwner: { mongoc_database_destroy(database) })
            }
        } as @convention(block) (String, String, String) -> Int)

        setFn("listIndexes", { [weak self] (db: String, coll: String) -> [String] in
            MongoShell.call(self, []) { try $0.client().listIndexes(db: db, collection: coll).map { ExtendedJSON.canonical($0.spec) } }
        } as @convention(block) (String, String) -> [String])

        setFn("cursorNext", { [weak self] (id: Int, max: Int) -> [String] in
            MongoShell.call(self, []) { try $0.nextBatch(id, max: max) }
        } as @convention(block) (Int, Int) -> [String])

        setFn("cursorClose", { [weak self] (id: Int) in
            self?.assumeIsolated { $0.closeCursor(id) }
        } as @convention(block) (Int) -> Void)

        ctx.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    // MARK: Cursors held by JavaScript

    private func openCollectionCursor(db: String, collection name: String, _ open: (OpaquePointer) -> OpaquePointer?) throws -> Int {
        guard let collection = mongoc_client_get_collection(try client().client, db, name) else { throw MongoError("Invalid collection") }
        return register(open(collection), destroyOwner: { mongoc_collection_destroy(collection) })
    }

    private func register(_ cursor: OpaquePointer?, destroyOwner: @escaping () -> Void) -> Int {
        guard let cursor else {
            destroyOwner()
            return 0
        }
        let id = nextCursorId
        nextCursorId += 1
        cursors[id] = (cursor, destroyOwner)
        return id
    }

    /// Returns up to `max` documents as canonical Extended JSON; an exhausted cursor is closed right away.
    private func nextBatch(_ id: Int, max: Int) throws -> [String] {
        guard let cursor = cursors[id]?.cursor else { return [] }
        var batch: [String] = []
        var current: UnsafePointer<bson_t>?
        while batch.count < max, mongoc_cursor_next(cursor, &current) {
            if let current { batch.append(ExtendedJSON.canonical(current)) }
        }
        if batch.count < max {
            let error = MongoError.from(cursor: cursor)
            closeCursor(id)
            if let error { throw error }
        }
        return batch
    }

    private func closeCursor(_ id: Int) {
        guard let entry = cursors.removeValue(forKey: id) else { return }
        mongoc_cursor_destroy(entry.cursor)
        entry.destroyOwner()
    }

    private func closeCursors() {
        for id in Array(cursors.keys) { closeCursor(id) }
    }
}
