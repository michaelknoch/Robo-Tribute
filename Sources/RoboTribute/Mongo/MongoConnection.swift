import Foundation
import CMongoC
import os

nonisolated struct MongoError: Error, LocalizedError {
    var message: String
    var code: Int = 0
    var errorDescription: String? { message }

    init(_ message: String, code: Int = 0) {
        self.message = message
        self.code = code
    }

    /// Prefers the server's errmsg/code from `reply` over libmongoc's generic description.
    init(_ error: bson_error_t, reply: UnsafePointer<bson_t>? = nil) {
        if let reply, let doc = try? BSONDecoder.decode(reply), let errmsg = doc["errmsg"]?.stringValue {
            message = errmsg
            code = doc["code"]?.intValue ?? Int(error.code)
            return
        }
        var copy = error
        message = withUnsafeBytes(of: &copy.message) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        code = Int(error.code)
    }

    /// The error a cursor stopped with, if any.
    static func from(cursor: OpaquePointer) -> MongoError? {
        var error = bson_error_t()
        var reply: UnsafePointer<bson_t>?
        return mongoc_cursor_error_document(cursor, &error, &reply) ? MongoError(error, reply: reply) : nil
    }
}

nonisolated struct CollectionInfo: Sendable {
    var name: String
    var type: String
}

nonisolated struct IndexInfo: Sendable {
    var name: String
    var spec: BSONDocument
}

/// Checked-out clients keep the connection alive: libmongoc requires all of them back before the pool is destroyed.
nonisolated final class MongoConnection: @unchecked Sendable {
    let settings: ConnectionSettings
    let address: String
    let serverVersion: String
    private let pool: OpaquePointer
    private let tunnel: SSHTunnel?
    private let members: MemberWatch?
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    private static let initOnce: Void = mongoc_init()

    static func open(settings: ConnectionSettings, secrets: ConnectionSecrets, timeoutSeconds: Int) async throws -> MongoConnection {
        try await Blocking.run { try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: timeoutSeconds) }
    }

    init(settings: ConnectionSettings, secrets: ConnectionSecrets, timeoutSeconds: Int) throws {
        _ = Self.initOnce
        if let reason = settings.transportSecurityError { throw MongoError("\(settings.readableName): \(reason)") }
        if settings.requiresLocalMembers { try Self.ensureMembersAreLocal(settings: settings, secrets: secrets, timeoutSeconds: timeoutSeconds) }
        var host = settings.serverHost
        var port = settings.serverPort
        var tunnel: SSHTunnel?
        if settings.usesSSHTunnel {
            let started = SSHTunnel(settings: settings.ssh, secrets: secrets, remoteHost: host, remotePort: port, timeoutSeconds: timeoutSeconds)
            try started.start()
            tunnel = started
            host = "127.0.0.1"
            port = started.localPort
        }
        let members = settings.requiresLocalMembers ? MemberWatch() : nil
        do {
            let pool = try Self.makePool(settings: settings, secrets: secrets, host: host, port: port, timeoutSeconds: timeoutSeconds)
            members?.install(on: pool)
            do {
                let buildInfo = try PooledClient(pool: pool, owner: nil, settings: settings, members: members).runCommand(db: "admin", command: ["buildInfo": .int32(1)])
                serverVersion = buildInfo["version"]?.stringValue ?? ""
            } catch {
                mongoc_client_pool_destroy(pool)
                throw error
            }
            self.pool = pool
        } catch {
            tunnel?.stop()
            throw error
        }
        self.tunnel = tunnel
        self.members = members
        self.settings = settings
        address = settings.fullAddress
        Log.info("Connected to \(settings.fullAddress), MongoDB \(serverVersion)")
    }

    deinit {
        // Destroying the pool ends its server sessions over the network.
        let teardown = Teardown(pool: pool, tunnel: tunnel, members: members)
        Blocking.detach { teardown.run() }
    }

    /// The pool itself goes away with its last client.
    func close() {
        isClosed.withLock { $0 = true }
        tunnel?.stop()
    }

    private struct Teardown: @unchecked Sendable {
        let pool: OpaquePointer
        let tunnel: SSHTunnel?
        /// The pool's monitor calls into it until the pool is destroyed.
        let members: MemberWatch?

        func run() {
            mongoc_client_pool_destroy(pool)
            tunnel?.stop()
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable (MongoConnection) throws -> T) async throws -> T {
        try await Blocking.run { try work(self) }
    }

    private static func makePool(settings: ConnectionSettings, secrets: ConnectionSecrets, host: String, port: Int, timeoutSeconds: Int) throws -> OpaquePointer {
        var error = bson_error_t()
        let uriString: String
        switch settings.connectionType {
        case .direct:
            let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            uriString = "mongodb://\(formattedHost):\(port)/?directConnection=true"
        case .replicaSet:
            var s = "mongodb://\(settings.seedMembers.joined(separator: ","))/"
            if !settings.replicaSetName.isEmpty {
                s += "?replicaSet=\(settings.replicaSetName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settings.replicaSetName)"
            }
            uriString = s
        case .srv:
            uriString = "mongodb+srv://\(host)/"
        }
        guard let uri = mongoc_uri_new_with_error(uriString, &error) else { throw MongoError(error) }
        defer { mongoc_uri_destroy(uri) }

        let timeoutMs = Int32(max(timeoutSeconds, 1) * 1000)
        mongoc_uri_set_option_as_int32(uri, MONGOC_URI_SERVERSELECTIONTIMEOUTMS, timeoutMs)
        mongoc_uri_set_option_as_int32(uri, MONGOC_URI_CONNECTTIMEOUTMS, timeoutMs)
        mongoc_uri_set_appname(uri, "Robo Tribute")

        if settings.hasEnabledCredential {
            mongoc_uri_set_username(uri, settings.credential.userName)
            mongoc_uri_set_password(uri, secrets.password)
            let authDb = settings.credential.databaseName.isEmpty ? "admin" : settings.credential.databaseName
            mongoc_uri_set_auth_source(uri, authDb)
            // SCRAM-SHA-256 is left to negotiation, which picks it whenever the user has SHA-256 credentials
            // and falls back to SHA-1 for users created before MongoDB 4.0.
            if settings.credential.mechanism == "SCRAM-SHA-1" {
                mongoc_uri_set_auth_mechanism(uri, "SCRAM-SHA-1")
            }
        }

        if settings.usesTLS {
            mongoc_uri_set_option_as_bool(uri, MONGOC_URI_TLS, true)
            if settings.ssl.sslEnabled && !settings.verifiesCertificates {
                Log.warning("\(settings.readableName): TLS certificate validation is disabled; the server's identity is not verified.")
            }
        }

        guard let pool = mongoc_client_pool_new_with_error(uri, &error) else { throw MongoError(error) }
        mongoc_client_pool_set_error_api(pool, Int32(MONGOC_ERROR_API_VERSION_2))
        if settings.ssl.sslEnabled {
            withTLSOptions(ssl: settings.ssl, pemPassphrase: secrets.pemPassphrase) { mongoc_client_pool_set_ssl_opts(pool, &$0) }
        }
        return pool
    }

    /// Asks a seed directly which members its replica set has, before any pool can discover and connect to them.
    private static func ensureMembersAreLocal(settings: ConnectionSettings, secrets: ConnectionSecrets, timeoutSeconds: Int) throws {
        for seed in settings.seedMembers {
            guard let (host, port) = ConnectionSettings.splitHostPort(seed) else { continue }
            var probe = settings
            probe.connectionType = .direct
            probe.credential.enabled = false
            guard let hello = try? isMaster(probe, secrets: secrets, host: host, port: port, timeoutSeconds: timeoutSeconds) else { continue }
            let members = ["hosts", "passives", "arbiters"].flatMap { key -> [String] in
                guard case .array(let hosts)? = hello[key] else { return [] }
                return hosts.compactMap(\.stringValue)
            }
            let remote = members.filter { !ConnectionSettings.isLoopback(ConnectionSettings.host(ofMember: $0)) }
            if !remote.isEmpty {
                throw MongoError("\(settings.readableName): the replica set has members on other machines (\(remote.joined(separator: ", "))). Connecting to them needs verified TLS.")
            }
            return
        }
    }

    private static func isMaster(_ settings: ConnectionSettings, secrets: ConnectionSecrets, host: String, port: Int, timeoutSeconds: Int) throws -> BSONDocument {
        let pool = try makePool(settings: settings, secrets: secrets, host: host, port: port, timeoutSeconds: timeoutSeconds)
        defer { mongoc_client_pool_destroy(pool) }
        return try PooledClient(pool: pool, owner: nil, settings: settings, members: nil).runCommand(db: "admin", command: ["isMaster": .int32(1)])
    }

    private static func withTLSOptions(ssl: SSLSettings, pemPassphrase: String, _ apply: (inout mongoc_ssl_opt_t) -> Void) {
        let caFile = ssl.allowInvalidCertificates ? "" : (ssl.caFile as NSString).expandingTildeInPath
        let pemFile = ssl.usePemFile ? (ssl.pemKeyFile as NSString).expandingTildeInPath : ""
        let crlFile = ssl.useAdvancedOptions ? (ssl.crlFile as NSString).expandingTildeInPath : ""
        let passphrase = ssl.usePemFile ? pemPassphrase : ""

        var opts = mongoc_ssl_opt_get_default().pointee
        opts.weak_cert_validation = ssl.allowInvalidCertificates
        opts.allow_invalid_hostname = ssl.useAdvancedOptions && ssl.allowInvalidHostnames

        caFile.withCStringOrNil { ca in
            pemFile.withCStringOrNil { pem in
                crlFile.withCStringOrNil { crl in
                    passphrase.withCStringOrNil { pwd in
                        opts.ca_file = ca
                        opts.pem_file = pem
                        opts.crl_file = crl
                        opts.pem_pwd = pwd
                        apply(&opts)
                    }
                }
            }
        }
    }

    // MARK: Client access

    func checkout() throws -> PooledClient {
        guard !isClosed.withLock({ $0 }) else { throw MongoError("Not connected") }
        return try PooledClient(pool: pool, owner: self, settings: settings, members: members)
    }

    func withClient<T>(_ body: (PooledClient) throws -> T) throws -> T {
        try body(checkout())
    }

    func runCommand(db: String, command: BSONDocument) throws -> BSONDocument {
        try withClient { try $0.runCommand(db: db, command: command) }
    }

    func find(db: String, collection: String, options: FindOptions) throws -> [BSONDocument] {
        try withClient { try $0.find(db: db, collection: collection, options: options) }
    }

    func aggregate(db: String, collection: String, pipeline: [BSONValue], options: BSONDocument) throws -> [BSONDocument] {
        try withClient { try $0.aggregate(db: db, collection: collection, pipeline: pipeline, options: options) }
    }

    func listIndexes(db: String, collection: String) throws -> [IndexInfo] {
        try withClient { try $0.listIndexes(db: db, collection: collection) }
    }

    // MARK: Explorer

    func listDatabases() throws -> [String] {
        if settings.hasEnabledCredential && settings.credential.useManuallyVisibleDbs {
            return settings.credential.manuallyVisibleDbs
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        do {
            let reply = try runCommand(db: "admin", command: [
                "listDatabases": .int32(1), "nameOnly": .bool(true), "authorizedDatabases": .bool(true),
            ])
            guard case .array(let dbs)? = reply["databases"] else { return [] }
            return dbs.compactMap { $0.documentValue?["name"]?.stringValue }.sorted()
        } catch {
            if settings.hasEnabledCredential {
                let fallback = settings.defaultDatabase.isEmpty ? settings.credential.databaseName : settings.defaultDatabase
                if !fallback.isEmpty { return [fallback] }
            }
            throw error
        }
    }

    func listCollections(db: String) throws -> [CollectionInfo] {
        try withClient { try $0.listCollections(db: db) }.compactMap { doc in
            doc["name"]?.stringValue.map { CollectionInfo(name: $0, type: doc["type"]?.stringValue ?? "collection") }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Documents

    struct FindOptions {
        var filter = BSONDocument()
        var projection: BSONDocument?
        var sort: BSONDocument?
        var hint: BSONValue?
        var skip = 0
        var limit = 0
        var maxTimeMS = 0
        var collation: BSONDocument?
    }

    func insert(db: String, collection: String, documents: [BSONDocument]) throws {
        _ = try runCommand(db: db, command: [
            "insert": .string(collection), "documents": .array(documents.map { .document($0) }), "ordered": .bool(true),
        ])
    }

    func replace(db: String, collection: String, id: BSONValue, with document: BSONDocument) throws {
        let reply = try runCommand(db: db, command: [
            "update": .string(collection),
            "updates": .array([.document(["q": .document(["_id": id]), "u": .document(document), "upsert": .bool(false)])]),
        ])
        if reply["n"]?.intValue == 0 { throw MongoError("The document no longer exists, it was not saved.") }
    }

    func delete(db: String, collection: String, filter: BSONDocument, limit: Int) throws {
        _ = try runCommand(db: db, command: [
            "delete": .string(collection),
            "deletes": .array([.document(["q": .document(filter), "limit": .int32(Int32(limit))])]),
        ])
    }

    func dropDatabase(_ db: String) throws {
        _ = try runCommand(db: db, command: ["dropDatabase": .int32(1)])
    }

    func createCollection(db: String, name: String) throws {
        _ = try runCommand(db: db, command: ["create": .string(name)])
    }

    func dropCollection(db: String, name: String) throws {
        _ = try runCommand(db: db, command: ["drop": .string(name)])
    }

    func renameCollection(db: String, from: String, to: String) throws {
        _ = try runCommand(db: "admin", command: ["renameCollection": .string("\(db).\(from)"), "to": .string("\(db).\(to)")])
    }

    func duplicateCollection(db: String, from: String, to: String) throws {
        _ = try aggregate(db: db, collection: from, pipeline: [.document(["$out": .string(to)])], options: BSONDocument())
    }

    func dropIndex(db: String, collection: String, name: String) throws {
        _ = try runCommand(db: db, command: ["dropIndexes": .string(collection), "index": .string(name)])
    }
}

/// Learns about replica set members from the driver's topology monitor as soon as it discovers them.
nonisolated final class MemberWatch: @unchecked Sendable {
    private let remote = OSAllocatedUnfairLock<String?>(initialState: nil)

    var remoteMember: String? { remote.withLock { $0 } }

    /// Must run before the first client leaves the pool; the pool keeps an unretained pointer to this watch.
    func install(on pool: OpaquePointer) {
        let callbacks = mongoc_apm_callbacks_new()
        mongoc_apm_set_server_opening_cb(callbacks) { event in
            guard let event, let context = mongoc_apm_server_opening_get_context(event),
                  let host = mongoc_apm_server_opening_get_host(event) else { return }
            let name = withUnsafeBytes(of: host.pointee.host) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard !ConnectionSettings.isLoopback(name) else { return }
            Unmanaged<MemberWatch>.fromOpaque(context).takeUnretainedValue().remote.withLock { $0 = $0 ?? name }
        }
        mongoc_client_pool_set_apm_callbacks(pool, callbacks, Unmanaged.passUnretained(self).toOpaque())
        mongoc_apm_callbacks_destroy(callbacks)
    }
}

/// A driver cursor with the collection or database handle it reads from, destroyed in that order.
nonisolated final class MongoCursor {
    let pointer: OpaquePointer
    private let releaseOwner: () -> Void

    init(_ pointer: OpaquePointer, releaseOwner: @escaping () -> Void) {
        self.pointer = pointer
        self.releaseOwner = releaseOwner
    }

    deinit {
        mongoc_cursor_destroy(pointer)
        releaseOwner()
    }

    func drain(max: Int = .max) throws -> [BSONDocument] {
        var docs: [BSONDocument] = []
        var current: UnsafePointer<bson_t>?
        while docs.count < max, mongoc_cursor_next(pointer, &current) {
            if let current { docs.append(try BSONDecoder.decode(current)) }
        }
        if let error = MongoError.from(cursor: pointer) { throw error }
        return docs
    }
}

/// A client checked out of the pool; it goes back to the pool when released.
/// It keeps the driver client to itself so every command passes `authorize`, which enforces read-only connections.
nonisolated final class PooledClient {
    private let pool: OpaquePointer
    private let client: OpaquePointer
    private let owner: MongoConnection?
    private let settings: ConnectionSettings
    private let members: MemberWatch?

    init(pool: OpaquePointer, owner: MongoConnection?, settings: ConnectionSettings, members: MemberWatch?) throws {
        guard let client = mongoc_client_pool_pop(pool) else { throw MongoError("Unable to obtain a client from the pool") }
        self.pool = pool
        self.client = client
        self.owner = owner
        self.settings = settings
        self.members = members
    }

    deinit {
        mongoc_client_pool_push(pool, client)
    }

    /// An allowlist, so commands this list doesn't know are refused rather than let through.
    private static let readOnlyCommands: Set<String> = [
        "find", "getmore", "killcursors", "count", "distinct", "aggregate", "explain",
        "listcollections", "listdatabases", "listindexes", "dbstats", "collstats", "datasize",
        "buildinfo", "hello", "ismaster", "ping", "serverstatus", "hostinfo", "getcmdlineopts", "getlog", "getparameter",
        "connectionstatus", "currentop", "listcommands", "whatsmyuri", "usersinfo", "rolesinfo", "replsetgetstatus", "replsetgetconfig", "top",
    ]

    private func authorize(_ command: BSONDocument) throws {
        if let remote = members?.remoteMember {
            throw MongoError("The replica set now includes \(remote), which is not on this machine. Connecting to it needs verified TLS.")
        }
        if settings.isReadOnly, !Self.isReadOnly(command) {
            throw MongoError("This connection is read-only, \"\(command.elements.first?.key ?? "")\" was blocked.")
        }
    }

    static func isReadOnly(_ command: BSONDocument) -> Bool {
        guard let name = command.elements.first?.key.lowercased(), readOnlyCommands.contains(name) else { return false }
        return name != "aggregate" || command["pipeline"].map(containsOutputStage) != true
    }

    private static func containsOutputStage(_ value: BSONValue) -> Bool {
        switch value {
        case .document(let doc): return doc.elements.contains { $0.key == "$out" || $0.key == "$merge" || containsOutputStage($0.value) }
        case .array(let items): return items.contains(where: containsOutputStage)
        default: return false
        }
    }

    func runCommand(db: String, command: BSONDocument) throws -> BSONDocument {
        try authorize(command)
        var reply = bson_t()
        var error = bson_error_t()
        let ok = command.withBSON { mongoc_client_command_simple(client, db, $0, nil, &reply, &error) }
        defer { bson_destroy(&reply) }
        if !ok { throw MongoError(error, reply: &reply) }
        let doc = try BSONDecoder.decode(&reply)
        try Self.checkWriteErrors(doc)
        return doc
    }

    private static func checkWriteErrors(_ reply: BSONDocument) throws {
        if case .array(let errors)? = reply["writeErrors"], let first = errors.first?.documentValue {
            throw MongoError(first["errmsg"]?.stringValue ?? "Write error", code: first["code"]?.intValue ?? 0)
        }
        if let wce = reply["writeConcernError"]?.documentValue {
            throw MongoError(wce["errmsg"]?.stringValue ?? "Write concern error", code: wce["code"]?.intValue ?? 0)
        }
    }

    func find(db: String, collection: String, options: MongoConnection.FindOptions) throws -> [BSONDocument] {
        var opts = BSONDocument()
        if let projection = options.projection, !projection.isEmpty { opts.append("projection", .document(projection)) }
        if let sort = options.sort, !sort.isEmpty { opts.append("sort", .document(sort)) }
        if let hint = options.hint { opts.append("hint", hint) }
        if options.skip > 0 { opts.append("skip", .int64(Int64(options.skip))) }
        if options.limit > 0 {
            opts.append("limit", .int64(Int64(options.limit)))
            opts.append("batchSize", .int64(Int64(options.limit)))
        }
        if options.maxTimeMS > 0 { opts.append("maxTimeMS", .int64(Int64(options.maxTimeMS))) }
        if let collation = options.collation { opts.append("collation", .document(collation)) }
        return try findCursor(db: db, collection: collection, filter: options.filter, options: opts).drain(max: options.limit > 0 ? options.limit : .max)
    }

    func findCursor(db: String, collection: String, filter: BSONDocument, options: BSONDocument) throws -> MongoCursor {
        try authorize(["find": .string(collection)])
        return try collectionCursor(db: db, collection) { coll in
            filter.withBSON { f in options.withBSON { o in mongoc_collection_find_with_opts(coll, f, o, nil) } }
        }
    }

    func aggregate(db: String, collection: String, pipeline: [BSONValue], options: BSONDocument) throws -> [BSONDocument] {
        try aggregateCursor(db: db, collection: collection, spec: ["pipeline": .array(pipeline)], options: options).drain()
    }

    /// `spec` is `{pipeline: [...]}`; without a collection it runs on the database, like `$currentOp`.
    func aggregateCursor(db: String, collection: String?, spec: BSONDocument, options: BSONDocument) throws -> MongoCursor {
        try authorize(["aggregate": collection.map { .string($0) } ?? .int32(1), "pipeline": spec["pipeline"] ?? .array([])])
        let open = { (run: (UnsafePointer<bson_t>, UnsafePointer<bson_t>) -> OpaquePointer?) in
            spec.withBSON { p in options.withBSON { o in run(p, o) } }
        }
        if let collection {
            return try collectionCursor(db: db, collection) { coll in open { mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, $0, $1, nil) } }
        }
        guard let database = mongoc_client_get_database(client, db) else { throw MongoError("Invalid database") }
        guard let cursor = open({ mongoc_database_aggregate(database, $0, $1, nil) }) else {
            mongoc_database_destroy(database)
            throw MongoError("Unable to create cursor")
        }
        return MongoCursor(cursor) { mongoc_database_destroy(database) }
    }

    func listIndexes(db: String, collection: String) throws -> [IndexInfo] {
        try authorize(["listIndexes": .string(collection)])
        return try collectionCursor(db: db, collection) { mongoc_collection_find_indexes_with_opts($0, nil) }
            .drain().map { IndexInfo(name: $0["name"]?.stringValue ?? "", spec: $0) }
    }

    func listCollections(db: String) throws -> [BSONDocument] {
        try authorize(["listCollections": .int32(1)])
        guard let database = mongoc_client_get_database(client, db) else { throw MongoError("Invalid database") }
        let opts: BSONDocument = ["nameOnly": .bool(true), "authorizedCollections": .bool(true)]
        guard let cursor = opts.withBSON({ mongoc_database_find_collections_with_opts(database, $0) }) else {
            mongoc_database_destroy(database)
            throw MongoError("Unable to list collections")
        }
        return try MongoCursor(cursor) { mongoc_database_destroy(database) }.drain()
    }

    private func collectionCursor(db: String, _ name: String, _ open: (OpaquePointer) -> OpaquePointer?) throws -> MongoCursor {
        guard let collection = mongoc_client_get_collection(client, db, name) else { throw MongoError("Invalid collection") }
        guard let cursor = open(collection) else {
            mongoc_collection_destroy(collection)
            throw MongoError("Unable to create cursor")
        }
        return MongoCursor(cursor) { mongoc_collection_destroy(collection) }
    }
}

nonisolated extension BSONDocument: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, BSONValue)...) {
        self.init(elements)
    }
}

nonisolated extension String {
    func withCStringOrNil<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if isEmpty { return try body(nil) }
        return try withCString { try body($0) }
    }
}
