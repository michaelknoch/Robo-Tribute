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
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    private static let initOnce: Void = mongoc_init()

    static func open(settings: ConnectionSettings, secrets: ConnectionSecrets, timeoutSeconds: Int) async throws -> MongoConnection {
        try await Blocking.run { try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: timeoutSeconds) }
    }

    init(settings: ConnectionSettings, secrets: ConnectionSecrets, timeoutSeconds: Int) throws {
        _ = Self.initOnce
        if let reason = settings.transportSecurityError { throw MongoError("\(settings.readableName): \(reason)") }
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
        do {
            let pool = try Self.makePool(settings: settings, secrets: secrets, host: host, port: port, timeoutSeconds: timeoutSeconds)
            do {
                let buildInfo = try PooledClient(pool: pool, owner: nil).runCommand(db: "admin", command: ["buildInfo": .int32(1)])
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
        self.settings = settings
        address = settings.fullAddress
        Log.info("Connected to \(settings.fullAddress), MongoDB \(serverVersion)")
    }

    deinit {
        // Destroying the pool ends its server sessions over the network.
        let teardown = Teardown(pool: pool, tunnel: tunnel)
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
            let members = settings.replicaSetMembers.isEmpty ? ["\(host):\(port)"] : settings.replicaSetMembers
            var s = "mongodb://\(members.joined(separator: ","))/"
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
            applyTLS(pool, ssl: settings.ssl, pemPassphrase: secrets.pemPassphrase)
        }
        return pool
    }

    private static func applyTLS(_ pool: OpaquePointer, ssl: SSLSettings, pemPassphrase: String) {
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
                        mongoc_client_pool_set_ssl_opts(pool, &opts)
                    }
                }
            }
        }
    }

    // MARK: Client access

    func checkout() throws -> PooledClient {
        guard !isClosed.withLock({ $0 }) else { throw MongoError("Not connected") }
        return try PooledClient(pool: pool, owner: self)
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
        try withClient { client in
            guard let database = mongoc_client_get_database(client.client, db) else { throw MongoError("Invalid database") }
            defer { mongoc_database_destroy(database) }
            let opts: BSONDocument = ["nameOnly": .bool(true), "authorizedCollections": .bool(true)]
            let docs = try opts.withBSON { o -> [BSONDocument] in
                guard let cursor = mongoc_database_find_collections_with_opts(database, o) else { throw MongoError("Unable to list collections") }
                defer { mongoc_cursor_destroy(cursor) }
                return try PooledClient.drain(cursor, max: .max)
            }
            return docs.compactMap { doc in
                doc["name"]?.stringValue.map { CollectionInfo(name: $0, type: doc["type"]?.stringValue ?? "collection") }
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
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
        _ = try runCommand(db: db, command: [
            "update": .string(collection),
            "updates": .array([.document(["q": .document(["_id": id]), "u": .document(document), "upsert": .bool(true)])]),
        ])
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

/// A client checked out of the pool; it goes back to the pool when released.
nonisolated final class PooledClient {
    let pool: OpaquePointer
    let client: OpaquePointer
    private let owner: MongoConnection?

    init(pool: OpaquePointer, owner: MongoConnection?) throws {
        guard let client = mongoc_client_pool_pop(pool) else { throw MongoError("Unable to obtain a client from the pool") }
        self.pool = pool
        self.client = client
        self.owner = owner
    }

    deinit {
        mongoc_client_pool_push(pool, client)
    }

    func runCommand(db: String, command: BSONDocument) throws -> BSONDocument {
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

    func withCollection<T>(db: String, _ name: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let collection = mongoc_client_get_collection(client, db, name) else { throw MongoError("Invalid collection") }
        defer { mongoc_collection_destroy(collection) }
        return try body(collection)
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
        return try withCollection(db: db, collection) { coll in
            try options.filter.withBSON { filter in
                try opts.withBSON { o in
                    guard let cursor = mongoc_collection_find_with_opts(coll, filter, o, nil) else { throw MongoError("Unable to create cursor") }
                    defer { mongoc_cursor_destroy(cursor) }
                    return try Self.drain(cursor, max: options.limit > 0 ? options.limit : .max)
                }
            }
        }
    }

    func aggregate(db: String, collection: String, pipeline: [BSONValue], options: BSONDocument) throws -> [BSONDocument] {
        try withCollection(db: db, collection) { coll in
            try (["pipeline": .array(pipeline)] as BSONDocument).withBSON { p in
                try options.withBSON { o in
                    guard let cursor = mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, p, o, nil) else { throw MongoError("Unable to create cursor") }
                    defer { mongoc_cursor_destroy(cursor) }
                    return try Self.drain(cursor, max: .max)
                }
            }
        }
    }

    func listIndexes(db: String, collection: String) throws -> [IndexInfo] {
        try withCollection(db: db, collection) { coll in
            guard let cursor = mongoc_collection_find_indexes_with_opts(coll, nil) else { throw MongoError("Unable to list indexes") }
            defer { mongoc_cursor_destroy(cursor) }
            return try Self.drain(cursor, max: .max).map { IndexInfo(name: $0["name"]?.stringValue ?? "", spec: $0) }
        }
    }

    static func drain(_ cursor: OpaquePointer, max: Int) throws -> [BSONDocument] {
        var docs: [BSONDocument] = []
        var current: UnsafePointer<bson_t>?
        while docs.count < max, mongoc_cursor_next(cursor, &current) {
            if let current { docs.append(try BSONDecoder.decode(current)) }
        }
        if let error = MongoError.from(cursor: cursor) { throw error }
        return docs
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
