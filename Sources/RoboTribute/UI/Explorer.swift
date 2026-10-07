import AppKit

/// A live connection shown in the explorer: settings plus the pooled driver connection.
final class ServerSession {
    let settings: ConnectionSettings
    let connection: MongoConnection

    init(settings: ConnectionSettings, connection: MongoConnection) {
        self.settings = settings
        self.connection = connection
    }

    func write(_ description: String, _ work: @escaping @Sendable (MongoConnection) throws -> Void) async {
        do {
            try await connection.run(work)
            Log.info(description)
        } catch {
            Log.error("\(description) failed: \(error.localizedDescription)")
            Alerts.error("Database Error", error.localizedDescription)
        }
    }

    func insertDocuments(db: String, collection: String, onInserted: @escaping () -> Void = {}) {
        let info = DocumentEditorWindow.Info(server: connection.address, db: db, collection: collection)
        let editor = DocumentEditorWindow(title: "Insert Document", info: info, json: "{\n    \n}", readOnly: false, cursor: 6)
        guard let docs = editor.runModal(), !docs.isEmpty else { return }
        Task {
            await write("Inserted \(docs.count) document(s) into \(db).\(collection)") { try $0.insert(db: db, collection: collection, documents: docs) }
            onInserted()
        }
    }
}

class ExplorerNode {
    weak var parent: ExplorerNode?
    let session: ServerSession
    var title: String
    var icon: NSImage
    var children: [ExplorerNode] = []
    var isLoaded = true
    var isLoading = false
    var isExpandable: Bool { !children.isEmpty || !isLoaded }

    init(session: ServerSession, title: String, icon: NSImage) {
        self.session = session
        self.title = title
        self.icon = icon
    }

    func add(_ child: ExplorerNode) {
        child.parent = self
        children.append(child)
    }

    /// Loads children in the background, showing "Title ..." meanwhile and "Title (count)" afterwards.
    func load(completion: @escaping () -> Void) {
        let base = baseTitle
        isLoading = true
        title = Self.countTitle(base, nil)
        completion()
        Task {
            let result = await Result { try await fetch() }
            isLoading = false
            children = []
            switch result {
            case .success(let nodes):
                isLoaded = true
                nodes.forEach(add)
                title = Self.countTitle(base, nodes.reduce(0) { $0 + (($1 as? FolderNode)?.children.count ?? 1) })
            case .failure(let error):
                title = base
                Log.error("Cannot load \(base): \(error.localizedDescription)")
                loadFailed(error)
            }
            completion()
        }
    }

    var baseTitle: String { title }
    func fetch() async throws -> [ExplorerNode] { [] }
    func loadFailed(_ error: Error) {}

    var databaseNode: DatabaseNode? {
        var node: ExplorerNode? = self
        while let current = node {
            if let db = current as? DatabaseNode { return db }
            node = current.parent
        }
        return nil
    }

    static func countTitle(_ base: String, _ count: Int?) -> String {
        guard let count else { return base + " ..." }
        return "\(base) (\(count))"
    }
}

final class ServerNode: ExplorerNode {
    init(session: ServerSession) {
        super.init(session: session, title: session.settings.readableName,
                   icon: session.settings.isReplicaSet ? Theme.replicaSet : Theme.server)
        isLoaded = false
    }

    override var baseTitle: String { session.settings.readableName }

    override func fetch() async throws -> [ExplorerNode] {
        let names = try await session.connection.run { try $0.listDatabases() }
        let system = FolderNode(session: session, title: "System")
        var nodes: [ExplorerNode] = []
        for name in names {
            let db = DatabaseNode(session: session, name: name)
            if name == "admin" || name == "local" { system.add(db) } else { nodes.append(db) }
        }
        return system.children.isEmpty ? nodes : [system] + nodes
    }

    override func loadFailed(_ error: Error) {
        Alerts.info("Error", "Cannot load list of databases.\n\nError:\n\(error.localizedDescription)")
    }
}

final class FolderNode: ExplorerNode {
    init(session: ServerSession, title: String) {
        super.init(session: session, title: title, icon: Theme.folder)
    }
}

final class DatabaseNode: ExplorerNode {
    let name: String
    let collections: CategoryNode
    let functions: CategoryNode
    let users: CategoryNode

    init(session: ServerSession, name: String) {
        self.name = name
        collections = CategoryNode(session: session, kind: .collections)
        functions = CategoryNode(session: session, kind: .functions)
        users = CategoryNode(session: session, kind: .users)
        super.init(session: session, title: name, icon: Theme.database)
        add(collections)
        add(functions)
        add(users)
    }
}

final class CategoryNode: ExplorerNode {
    enum Kind: String {
        case collections = "Collections", functions = "Functions", users = "Users"
    }

    let kind: Kind

    init(session: ServerSession, kind: Kind) {
        self.kind = kind
        super.init(session: session, title: kind.rawValue, icon: Theme.folder)
        isLoaded = false
    }

    override var baseTitle: String { kind.rawValue }

    override func fetch() async throws -> [ExplorerNode] {
        guard let db = databaseNode?.name else { return [] }
        switch kind {
        case .collections:
            let infos = try await session.connection.run { try $0.listCollections(db: db) }
            let system = FolderNode(session: session, title: "System")
            var nodes: [ExplorerNode] = []
            for info in infos {
                let node = CollectionNode(session: session, name: info.name, isView: info.type == "view")
                if info.name.hasPrefix("system.") { system.add(node) } else { nodes.append(node) }
            }
            return system.children.isEmpty ? nodes : [system] + nodes
        case .functions:
            let ids = try await session.connection.run { connection in
                var options = MongoConnection.FindOptions()
                options.projection = ["_id": .int32(1)]
                return try connection.find(db: db, collection: "system.js", options: options).map { $0["_id"] ?? .null }
            }
            return ids.map { ExplorerNode(session: session, title: $0.stringValue ?? BSONFormatter.current.displayValue($0), icon: Theme.function) }
        case .users:
            let names = try await session.connection.run { connection in
                let reply = try connection.runCommand(db: db, command: ["usersInfo": .int32(1)])
                guard case .array(let users)? = reply["users"] else { return [String]() }
                return users.compactMap { $0.documentValue?["user"]?.stringValue }.sorted()
            }
            return names.map { ExplorerNode(session: session, title: $0, icon: Theme.user) }
        }
    }
}

final class CollectionNode: ExplorerNode {
    let name: String
    let indexes: IndexesNode

    init(session: ServerSession, name: String, isView: Bool) {
        self.name = name
        indexes = IndexesNode(session: session)
        super.init(session: session, title: name, icon: Theme.collection)
        if !isView { add(indexes) }
    }
}

final class IndexesNode: ExplorerNode {
    init(session: ServerSession) {
        super.init(session: session, title: "Indexes", icon: Theme.folder)
        isLoaded = false
    }

    override var baseTitle: String { "Indexes" }

    override func fetch() async throws -> [ExplorerNode] {
        guard let db = databaseNode?.name, let collection = (parent as? CollectionNode)?.name else { return [] }
        return try await session.connection.run { try $0.listIndexes(db: db, collection: collection) }.map { IndexNode(session: session, info: $0) }
    }

    override func loadFailed(_ error: Error) {
        Alerts.info("Error", "Cannot load list of indexes.\n\nError:\n\(error.localizedDescription)")
    }
}

final class IndexNode: ExplorerNode {
    let info: IndexInfo

    init(session: ServerSession, info: IndexInfo) {
        self.info = info
        super.init(session: session, title: info.name, icon: Theme.indexIcon)
    }
}

protocol ExplorerDelegate: AnyObject {
    func explorerOpenShell(session: ServerSession, database: String?, script: String, execute: Bool, cursorFromEnd: Int)
    func explorerDisconnect(_ session: ServerSession)
    func explorerInsertDocument(session: ServerSession, database: String, collection: String)
    func explorerNeedsWidth(_ width: CGFloat)
}

final class ExplorerOutlineView: NSOutlineView {
    var menuProvider: ((ExplorerNode) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? ExplorerNode else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(node)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            sendAction(doubleAction, to: target)
            return
        }
        super.keyDown(with: event)
    }
}

final class ExplorerController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = ExplorerOutlineView()
    weak var delegate: ExplorerDelegate?
    private(set) var servers: [ServerNode] = []
    private let progress = NSProgressIndicator()

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.explorerBackground

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 15
        outlineView.rowHeight = 20
        outlineView.backgroundColor = Theme.explorerBackground
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.focusRingType = .none
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.menuProvider = { [weak self] in self?.menu(for: $0) }
        scroll.documentView = outlineView

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = scroll
    }

    func setConnecting(_ connecting: Bool) {
        connecting ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    func addServer(_ session: ServerSession) {
        let node = ServerNode(session: session)
        servers.append(node)
        outlineView.reloadData()
        outlineView.expandItem(node)
        fitWidth()
        let row = outlineView.row(forItem: node)
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        view.window?.makeFirstResponder(outlineView)
    }

    func removeServer(_ session: ServerSession) {
        servers.removeAll { $0.session === session }
        outlineView.reloadData()
    }

    func refresh(_ node: ExplorerNode) {
        node.isLoaded = false
        load(node)
    }

    private func load(_ node: ExplorerNode) {
        guard !node.isLoading else { return }
        node.load { [weak self, weak node] in
            guard let self, let node else { return }
            self.outlineView.reloadItem(node, reloadChildren: true)
            self.fitWidth()
        }
    }

    private func fitWidth() {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.treeFont]
        var widest: CGFloat = 0
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? ExplorerNode else { continue }
            let textStart = outlineView.frameOfCell(atColumn: 0, row: row).minX + 23
            widest = max(widest, textStart + (node.title as NSString).size(withAttributes: attributes).width)
        }
        delegate?.explorerNeedsWidth(ceil(widest) + 24)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ExplorerNode else { return servers.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ExplorerNode else { return servers[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ExplorerNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        RoboRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ExplorerNode else { return nil }
        let cell = BsonCell.make(outlineView, id: "cell", withIcon: true)
        cell.textField?.stringValue = node.title
        cell.imageView?.image = node.icon
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ExplorerNode, !node.isLoaded else { return }
        load(node)
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ExplorerNode else { return }
        if let collection = node as? CollectionNode, let db = collection.databaseNode?.name {
            delegate?.explorerOpenShell(session: node.session, database: db,
                                        script: Self.collectionQuery(collection.name, "find({})"), execute: true, cursorFromEnd: 2)
            return
        }
        if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
    }

    static func collectionQuery(_ name: String, _ postfix: String) -> String {
        "db.getCollection('\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))').\(postfix)"
    }

    private func menu(for node: ExplorerNode) -> NSMenu? {
        let menu = NSMenu()
        let item: (String, @escaping @MainActor () -> Void) -> Void = { title, action in
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        let session = node.session
        let shell: (String?, String, Bool, Int) -> Void = { [weak self] db, script, execute, cursor in
            self?.delegate?.explorerOpenShell(session: session, database: db, script: script, execute: execute, cursorFromEnd: cursor)
        }

        switch node {
        case let server as ServerNode:
            let open = ClosureMenuItem(title: "Open Shell") { shell(nil, "", false, 0) }
            open.image = Theme.icon("mongodb_icon_for_MAC.png")
            menu.addItem(open)
            item("Refresh") { [weak self] in self?.refresh(server) }
            menu.addItem(.separator())
            item("Create Database") { [weak self] in self?.createDatabase(server) }
            item("Server Status") { shell(nil, "db.serverStatus()", true, 0) }
            item("Host Info") { shell(nil, "db.hostInfo()", true, 0) }
            item("MongoDB Version") { shell(nil, "db.version()", true, 0) }
            menu.addItem(.separator())
            item("Show Log") { shell(nil, "show log", true, 0) }
            item("Disconnect") { [weak self] in self?.delegate?.explorerDisconnect(session) }

        case let db as DatabaseNode:
            let name = db.name
            let open = ClosureMenuItem(title: "Open Shell") { shell(name, "", false, 0) }
            open.image = Theme.icon("mongodb_icon_for_MAC.png")
            menu.addItem(open)
            item("Refresh") { [weak self] in self?.refresh(db.collections) }
            menu.addItem(.separator())
            item("Database Statistics") { shell(name, "db.stats()", true, 0) }
            menu.addItem(.separator())
            item("Current Operations") { shell(name, "db.currentOp()", true, 0) }
            item("Kill Operation...") { shell(name, "db.killOp()", false, 1) }
            menu.addItem(.separator())
            item("Drop Database...") { [weak self] in self?.dropDatabase(db) }

        case let category as CategoryNode:
            guard let db = category.databaseNode?.name else { return nil }
            switch category.kind {
            case .collections:
                item("Collections Statistics") { shell(db, "db.printCollectionStats()", true, 0) }
                item("Create Collection...") { [weak self] in self?.createCollection(category, db: db) }
            case .functions:
                item("View Functions") { shell(db, "db.system.js.find()", true, 0) }
            case .users:
                item("View Users") { shell(db, "db.getUsers()", true, 0) }
            }
            menu.addItem(.separator())
            item("Refresh") { [weak self] in self?.refresh(category) }

        case let collection as CollectionNode:
            guard let db = collection.databaseNode?.name else { return nil }
            let name = collection.name
            let q: (String) -> String = { Self.collectionQuery(name, $0) }
            item("View Documents") { shell(db, q("find({})"), true, 2) }
            menu.addItem(.separator())
            item("Insert Document...") { [weak self] in self?.delegate?.explorerInsertDocument(session: session, database: db, collection: name) }
            item("Update Documents...") {
                shell(db, q("updateMany(\n    // filter\n    {\n        \"key\" : \"value\"\n    },\n    \n    // update\n    {\n        \"$set\" : {\n        }\n    },\n    \n    // options\n    {\n        \"upsert\" : false  // insert a new document, if no existing document match the filter\n    }\n);"), false, 0)
            }
            item("Remove Documents...") { shell(db, q("deleteMany({ '' : '' });"), false, 10) }
            item("Remove All Documents...") { [weak self] in self?.removeAll(collection, db: db) }
            menu.addItem(.separator())
            item("Rename Collection...") { [weak self] in self?.renameCollection(collection, db: db, duplicate: false) }
            item("Duplicate Collection...") { [weak self] in self?.renameCollection(collection, db: db, duplicate: true) }
            item("Drop Collection...") { [weak self] in self?.dropCollection(collection, db: db) }
            menu.addItem(.separator())
            item("Statistics") { shell(db, q("stats()"), true, 0) }
            menu.addItem(.separator())
            item("Shard Version") { shell(db, q("getShardVersion()"), true, 0) }
            item("Shard Distribution") { shell(db, q("getShardDistribution()"), true, 0) }

        case let indexes as IndexesNode:
            item("Refresh") { [weak self] in self?.refresh(indexes) }

        case let index as IndexNode:
            guard let db = index.databaseNode?.name, let collection = (index.parent?.parent as? CollectionNode)?.name else { return nil }
            item("View Index") { shell(db, Self.collectionQuery(collection, "getIndexes()"), true, 0) }
            if index.info.name != "_id_" {
                item("Drop Index...") { [weak self] in self?.dropIndex(index, db: db, collection: collection) }
            }

        default:
            return nil
        }
        return menu
    }

    // MARK: Explorer operations

    private func createDatabase(_ server: ServerNode) {
        let dialog = InputDialog(title: "Create Database", server: server.session.settings.fullAddress, database: nil, collection: nil,
                                 label: "Database Name:", value: "", okTitle: "Create")
        guard let name = dialog.run(), !name.isEmpty else { return }
        // MongoDB creates a database lazily with its first collection, so it only exists in the explorer until then.
        server.add(DatabaseNode(session: server.session, name: name))
        server.title = ExplorerNode.countTitle(server.session.settings.readableName, server.children.filter { $0 is DatabaseNode }.count)
        outlineView.reloadItem(server, reloadChildren: true)
        Log.info("Database '\(name)' created.")
    }

    private func dropDatabase(_ db: DatabaseNode) {
        guard Alerts.confirm("Drop Database", "Drop \(db.name) database?", destructive: true) else { return }
        let name = db.name
        write(db.session, "Database '\(name)' dropped", refreshing: self.servers.first { $0.session === db.session }) { try $0.dropDatabase(name) }
    }

    private func createCollection(_ category: CategoryNode, db: String) {
        let dialog = InputDialog(title: "Create Collection", server: category.session.settings.fullAddress, database: db, collection: nil,
                                 label: "Collection Name:", value: "", okTitle: "Create")
        guard let name = dialog.run(), !name.isEmpty else { return }
        write(category.session, "Collection '\(name)' created", refreshing: category) { try $0.createCollection(db: db, name: name) }
    }

    private func dropCollection(_ collection: CollectionNode, db: String) {
        guard Alerts.confirm("Drop", "Drop collection \(collection.name)?", destructive: true) else { return }
        let name = collection.name
        write(collection.session, "Collection '\(name)' dropped", refreshing: collection.databaseNode?.collections) { try $0.dropCollection(db: db, name: name) }
    }

    private func removeAll(_ collection: CollectionNode, db: String) {
        guard Alerts.confirm("Remove All Documents", "Remove all documents from \(collection.name) collection?", destructive: true) else { return }
        let name = collection.name
        write(collection.session, "All documents removed from '\(name)'", refreshing: nil) { try $0.delete(db: db, collection: name, filter: BSONDocument(), limit: 0) }
    }

    private func renameCollection(_ collection: CollectionNode, db: String, duplicate: Bool) {
        let dialog = InputDialog(title: duplicate ? "Duplicate Collection" : "Rename Collection",
                                 server: collection.session.settings.fullAddress, database: db, collection: collection.name,
                                 label: "New Collection Name:", value: duplicate ? collection.name + "_copy" : collection.name,
                                 okTitle: duplicate ? "Duplicate" : "Rename")
        guard let newName = dialog.run(), !newName.isEmpty, newName != collection.name else { return }
        let from = collection.name
        let description = duplicate ? "Collection '\(from)' duplicated to '\(newName)'" : "Collection '\(from)' renamed to '\(newName)'"
        write(collection.session, description, refreshing: collection.databaseNode?.collections) {
            if duplicate { try $0.duplicateCollection(db: db, from: from, to: newName) } else { try $0.renameCollection(db: db, from: from, to: newName) }
        }
    }

    private func dropIndex(_ index: IndexNode, db: String, collection: String) {
        guard Alerts.confirm("Drop", "Drop index \(index.info.name)?", destructive: true) else { return }
        let name = index.info.name
        write(index.session, "Succeeded to drop index \"\(name)\"", refreshing: index.parent) { try $0.dropIndex(db: db, collection: collection, name: name) }
    }

    /// `refreshing` is evaluated after the write, so it sees the tree as it is then.
    private func write(_ session: ServerSession, _ description: String, refreshing node: @autoclosure @escaping () -> ExplorerNode?,
                       _ work: @escaping @Sendable (MongoConnection) throws -> Void) {
        Task {
            await session.write(description, work)
            if let node = node() { refresh(node) }
        }
    }
}

nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    @MainActor init(title: String, keyEquivalent: String = "", action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func fire() { handler() }
}
