import AppKit

protocol OutputItemHost: AnyObject {
    var session: ServerSession { get }
    var shell: MongoShell { get }
    func toggleDock()
    var isOutputDocked: Bool { get }
    func showProgress()
    func hideProgress()
}

final class PagingView: NSStackView {
    let skipField = NSTextField()
    let batchField = NSTextField()
    var onRefresh: ((Int, Int) -> Void)?
    var onLeft: ((Int, Int) -> Void)?
    var onRight: ((Int, Int) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 1
        for (field, tip) in [(skipField, "Skip"), (batchField, "Batch Size (number of documents shown at once)")] {
            field.alignment = .center
            field.toolTip = tip
            field.font = .systemFont(ofSize: 13)
            field.formatter = DigitsFormatter()
            field.target = self
            field.action = #selector(refresh)
            field.widthAnchor.constraint(equalToConstant: 66).isActive = true
        }
        addArrangedSubview(FlatButton(image: Theme.icon("left_16x16.png"), target: self, action: #selector(left)))
        addArrangedSubview(skipField)
        addArrangedSubview(batchField)
        addArrangedSubview(FlatButton(image: Theme.icon("right_16x16.png"), target: self, action: #selector(right)))
    }

    required init?(coder: NSCoder) { fatalError() }

    var skip: Int {
        get { Int(skipField.stringValue) ?? 0 }
        set { skipField.stringValue = "\(newValue)" }
    }

    var batchSize: Int {
        get { Int(batchField.stringValue) ?? AppSettings.shared.batchSize }
        set { batchField.stringValue = "\(newValue > 0 ? newValue : AppSettings.shared.batchSize)" }
    }

    @objc private func refresh() { onRefresh?(skip, batchSize) }
    @objc private func left() { onLeft?(skip, batchSize) }
    @objc private func right() { onRight?(skip, batchSize) }
}

nonisolated final class DigitsFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj.map { "\($0)" } }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partialString.allSatisfy(\.isNumber)
    }
}

final class OutputHeaderView: NSView {
    let collectionIndicator = IndicatorView(icon: Theme.collection)
    let timeIndicator = IndicatorView(icon: Theme.time)
    let paging = PagingView()
    let treeButton: FlatButton
    let tableButton: FlatButton
    let textButton: FlatButton
    let maximizeButton: FlatButton
    let dockButton: FlatButton
    var onDoubleClick: (() -> Void)?

    init() {
        treeButton = FlatButton(image: Theme.icon("tree_16x16.png"), toolTip: "View results in tree mode", target: nil, action: #selector(OutputItemView.showTree))
        tableButton = FlatButton(image: Theme.icon("table_16x16.png"), toolTip: "View results in table mode", target: nil, action: #selector(OutputItemView.showTable))
        textButton = FlatButton(image: Theme.icon("text_16x16.png"), toolTip: "View results in text mode", target: nil, action: #selector(OutputItemView.showText))
        maximizeButton = FlatButton(image: Theme.icon("maximize.png"), size: 18, toolTip: "Maximize this output result (double-click on result's header)", target: nil, action: #selector(OutputItemView.toggleMaximize))
        dockButton = FlatButton(image: Theme.icon("undock.png"), size: 18, toolTip: "Undock into separate window", target: nil, action: #selector(OutputItemView.toggleDock))
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 5)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(collectionIndicator)
        stack.addArrangedSubview(timeIndicator)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(paging)
        stack.addArrangedSubview(verticalSeparator())
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(treeButton)
        stack.addArrangedSubview(tableButton)
        stack.addArrangedSubview(textButton)
        stack.addArrangedSubview(maximizeButton)
        stack.setCustomSpacing(3, after: maximizeButton)
        stack.addArrangedSubview(verticalSeparator())
        stack.addArrangedSubview(dockButton)
        addSubview(stack)
        stack.pin(to: self)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        collectionIndicator.isHidden = true
        paging.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    func highlight(_ mode: ViewMode) {
        treeButton.image = Theme.icon(mode == .tree ? "tree_highlighted_16x16.png" : "tree_16x16.png")
        tableButton.image = Theme.icon(mode == .table ? "table_highlighted_16x16.png" : "table_16x16.png")
        textButton.image = Theme.icon(mode == .text ? "text_highlighted_16x16.png" : "text_16x16.png")
    }
}

/// One statement's result: header with paging plus tree, table or text view (OutputItemContentWidget.cpp).
final class OutputItemView: NSView, DocumentActionsDelegate {
    private(set) var result: ShellResult
    private weak var host: OutputItemHost?
    let header: OutputHeaderView
    private let content = NSView()
    private(set) var mode: ViewMode
    private var tree: BsonTreeController?
    private var table: BsonTableController?
    private var text: CodeEditor?
    private var renderTask: Task<Void, Never>?

    deinit {
        renderTask?.cancel()
    }
    private let initialSkip: Int
    private let initialLimit: Int
    var onMaximize: ((OutputItemView) -> Void)?

    init(result: ShellResult, host: OutputItemHost, mode: ViewMode, multiple: Bool) {
        self.result = result
        self.host = host
        self.mode = mode
        initialSkip = result.query?.skip ?? 0
        initialLimit = abs(result.query?.limit ?? 0)
        header = OutputHeaderView()
        super.init(frame: .zero)
        for button in [header.treeButton, header.tableButton, header.textButton, header.maximizeButton, header.dockButton] {
            button.target = self
        }
        header.maximizeButton.isHidden = !multiple
        header.onDoubleClick = { [weak self] in self?.toggleMaximize() }
        updateDockButton(docked: host.isOutputDocked)

        let hasDocuments = !result.documents.isEmpty || result.query != nil || result.aggregate != nil
        header.treeButton.isHidden = !hasDocuments
        header.tableButton.isHidden = !hasDocuments
        if !hasDocuments { self.mode = .text }

        if let collection = result.query?.collection ?? result.aggregate?.collection {
            header.collectionIndicator.text = collection
            header.collectionIndicator.isHidden = false
            header.paging.isHidden = false
            header.paging.skip = initialSkip
            header.paging.batchSize = AppSettings.shared.batchSize
        }
        showElapsed()
        header.paging.onRefresh = { [weak self] skip, batch in self?.refresh(skip: skip, batchSize: batch) }
        header.paging.onLeft = { [weak self] skip, batch in self?.refresh(skip: max(skip - batch, 0), batchSize: batch) }
        header.paging.onRight = { [weak self] skip, batch in self?.refresh(skip: skip + batch, batchSize: batch) }

        for view in [header, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Content is built when the item first becomes visible, so hidden result tabs cost nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && content.subviews.isEmpty { apply(mode: mode) }
    }

    private func showElapsed() {
        header.timeIndicator.text = String(format: "%.3g sec.", result.elapsed)
    }

    // MARK: Modes

    @objc func showTree() { apply(mode: .tree) }
    @objc func showTable() { apply(mode: .table) }
    @objc func showText() { apply(mode: .text) }
    @objc func toggleMaximize() { onMaximize?(self) }
    @objc func toggleDock() { host?.toggleDock() }

    func setMaximized(_ maximized: Bool) {
        header.maximizeButton.image = Theme.icon(maximized ? "minimize.png" : "maximize.png")
        header.maximizeButton.toolTip = maximized ? "Restore back to original size (double-click on result header)"
            : "Maximize this output result (double-click on result header)"
    }

    func updateDockButton(docked: Bool) {
        header.dockButton.image = Theme.icon(docked ? "undock.png" : "dock.png")
        header.dockButton.toolTip = docked ? "Undock into separate window" : "Dock into main window"
    }

    func apply(mode requested: ViewMode) {
        let hasDocuments = !header.treeButton.isHidden
        let newMode: ViewMode = hasDocuments ? (requested == .custom ? .tree : requested) : .text
        mode = newMode
        header.highlight(requested == .custom ? .tree : requested)
        let view: NSView
        switch newMode {
        case .tree, .custom:
            if tree == nil { tree = BsonTreeController(values: result.documents, actions: self) }
            view = tree!.scrollView
        case .table:
            if table == nil { table = BsonTableController(values: result.documents, actions: self) }
            view = table!.scrollView
        case .text:
            if text == nil {
                let editor = CodeEditor(wrap: false, editable: false)
                editor.cornerRadius = 0
                text = editor
                fillText(editor)
            }
            view = text!
        }
        guard view.superview !== content else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(view)
        view.pin(to: content)
    }

    private func fillText(_ editor: CodeEditor) {
        editor.string = "Loading..."
        let documents = result.documents
        let plain = result.text
        let formatter = BSONFormatter.current
        renderTask?.cancel()
        renderTask = Task {
            guard let storage = await Self.render(documents, plain: plain, formatter: formatter), !Task.isCancelled else { return }
            editor.adopt(storage)
        }
    }

    @concurrent
    private static func render(_ documents: [BSONValue], plain: String, formatter: BSONFormatter) async -> sending NSTextStorage? {
        var parts: [String] = []
        for document in documents {
            if Task.isCancelled { return nil }
            parts.append(formatter.json(document))
        }
        return JSHighlighter.storage(for: documents.isEmpty ? plain : "\n" + parts.joined(separator: "\n\n\n"))
    }

    private func reloadContent() {
        renderTask?.cancel()
        tree = nil
        table = nil
        text = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        apply(mode: mode)
    }

    // MARK: Paging (OutputItemContentWidget::refresh)

    func refresh(skip requestedSkip: Int, batchSize: Int) {
        guard let host else { return }
        let batch = max(batchSize, 1)
        if let query = result.query {
            var skip = requestedSkip
            if skip < initialSkip { skip = initialSkip }
            let delta = skip - initialSkip
            var limit = batch
            if initialLimit != 0 {
                limit = initialLimit - delta
                if limit <= 0 { limit = -1 }
                if limit > batch { limit = batch }
            }
            load(host: host, skip: skip, batch: batch) { shell in try await shell.loadQuery(query, skip: skip, limit: limit) }
        } else if let aggregate = result.aggregate {
            let skip = max(requestedSkip, 0)
            load(host: host, skip: skip, batch: batch) { shell in try await shell.loadAggregate(aggregate, skip: skip, batchSize: batch) }
        }
    }

    private func load(host: OutputItemHost, skip: Int, batch: Int, _ work: @escaping (MongoShell) async throws -> [BSONDocument]) {
        let shell = host.shell
        let started = Date()
        host.showProgress()
        Task { [weak self] in
            defer { host.hideProgress() }
            do {
                let docs = try await work(shell)
                guard let self else { return }
                result.documents = docs.map { .document($0) }
                result.elapsed = Date().timeIntervalSince(started)
                showElapsed()
                header.paging.skip = skip
                header.paging.batchSize = batch
                reloadContent()
            } catch {
                Alerts.info("Error", "Failed to load documents.\n\nError:\n\(error.localizedDescription)")
            }
        }
    }

    func reloadCurrentPage() {
        refresh(skip: header.paging.skip, batchSize: header.paging.batchSize)
    }

    // MARK: DocumentActionsDelegate (Notifier.cpp)

    var isEditable: Bool {
        guard let query = result.query else { return false }
        return !query.hasProjection
    }

    private var namespace: (db: String, collection: String)? {
        if let q = result.query { return (q.db, q.collection) }
        if let a = result.aggregate { return (a.db, a.collection) }
        return nil
    }

    func viewDocument(_ node: BsonNode) {
        let info = namespace.map { DocumentEditorWindow.Info(server: host?.session.connection.address ?? "", db: $0.db, collection: $0.collection) }
        DocumentEditorWindow(title: "View Document", info: info, json: BSONFormatter.current.json(node.root.value), readOnly: true).show()
    }

    func editDocument(_ node: BsonNode) {
        guard let host, let ns = namespace, let doc = node.rootDocument else { return }
        let info = DocumentEditorWindow.Info(server: host.session.connection.address, db: ns.db, collection: ns.collection)
        let editor = DocumentEditorWindow(title: "Edit Document", info: info, json: BSONFormatter.current.jsonString(doc), readOnly: false)
        guard let docs = editor.runModal(), let edited = docs.first else { return }
        let id = edited["_id"] ?? doc["_id"] ?? .null
        write(host: host, "Document saved") { try $0.replace(db: ns.db, collection: ns.collection, id: id, with: edited) }
    }

    func insertDocument() {
        guard let host, let ns = namespace else { return }
        host.session.insertDocuments(db: ns.db, collection: ns.collection) { self.reloadCurrentPage() }
    }

    func deleteDocuments(_ roots: [BsonNode]) {
        guard let host, let ns = namespace, !roots.isEmpty else { return }
        let ids = roots.compactMap { $0.rootDocument?["_id"] }
        guard ids.count == roots.count else {
            Alerts.info("Cannot delete", "Selected document doesn't have _id field. \nMaybe this is a system document that should be managed in a special way?")
            return
        }
        let question = ids.count == 1 ? "Delete Document with id:\n\(BSONFormatter.current.json(ids[0]))?"
            : "Do you want to delete \(ids.count) selected documents?"
        guard Alerts.confirm("Delete", question, destructive: true) else { return }
        let filter: BSONDocument = ["_id": .document(["$in": .array(ids)])]
        write(host: host, "Removed \(ids.count) document(s)") { try $0.delete(db: ns.db, collection: ns.collection, filter: filter, limit: 0) }
    }

    private func write(host: OutputItemHost, _ description: String, _ work: @escaping @Sendable (MongoConnection) throws -> Void) {
        host.showProgress()
        Task {
            await host.session.write(description, work)
            host.hideProgress()
            reloadCurrentPage()
        }
    }
}

/// All results of one execution: stacked in a split view, or tabbed when there are more than two (OutputWidget.cpp).
final class OutputView: NSView {
    private let split = NSSplitView()
    private let tabBar = TabBarView()
    private let tabContainer = NSView()
    private(set) var items: [OutputItemView] = []
    private var maximized: OutputItemView?
    private var selectedTab = 0
    private let progress = ProgressPopup()

    init() {
        super.init(frame: .zero)
        split.isVertical = false
        split.dividerStyle = .thin
        for view in [split, tabBar, tabContainer, progress] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            tabContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        tabBar.onSelect = { [weak self] in self?.selectTab($0) }
        tabBar.onClose = { [weak self] in self?.closeTab($0) }
        setTabbed(false)
        progress.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isTabbed: Bool { !tabBar.isHidden }

    private func setTabbed(_ tabbed: Bool) {
        split.isHidden = tabbed
        tabBar.isHidden = !tabbed
        tabContainer.isHidden = !tabbed
    }

    func present(_ results: [ShellResult], host: OutputItemHost) {
        let previousModes = items.map(\.mode)
        clear()
        let tabbed = results.count > 2
        items = results.enumerated().map { index, result in
            let mode = index < previousModes.count ? previousModes[index] : AppSettings.shared.viewMode
            let item = OutputItemView(result: result, host: host, mode: mode, multiple: results.count > 1 && !tabbed)
            item.onMaximize = { [weak self] in self?.toggleMaximize($0) }
            item.translatesAutoresizingMaskIntoConstraints = false
            return item
        }
        setTabbed(tabbed)
        if tabbed {
            refreshTabs()
            selectTab(0)
        } else {
            items.forEach { split.addArrangedSubview($0) }
            split.adjustSubviews()
            equalize()
        }
    }

    func clear() {
        items.forEach { $0.removeFromSuperview() }
        items = []
        maximized = nil
        tabBar.tabs = []
    }

    private func refreshTabs() {
        tabBar.tabs = items.map { TabBarView.Tab(title: $0.result.statementShort, toolTip: $0.result.statement) }
    }

    private func selectTab(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        tabContainer.subviews.forEach { $0.removeFromSuperview() }
        selectedTab = index
        tabContainer.addSubview(items[index])
        items[index].pin(to: tabContainer)
        tabBar.selectedIndex = index
    }

    private func closeTab(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        items.remove(at: index).removeFromSuperview()
        refreshTabs()
        selectTab(min(index, items.count - 1))
    }

    func toggleOrientation() {
        split.isVertical.toggle()
        split.adjustSubviews()
        equalize()
    }

    func setMode(_ mode: ViewMode) {
        if isTabbed {
            if selectedTab < items.count { items[selectedTab].apply(mode: mode) }
        } else {
            items.forEach { $0.apply(mode: mode) }
        }
    }

    func updateDockButtons(docked: Bool) {
        items.forEach { $0.updateDockButton(docked: docked) }
    }

    private func equalize() {
        let count = split.arrangedSubviews.count
        guard count > 1 else { return }
        layoutSubtreeIfNeeded()
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        let step = total / CGFloat(count)
        for i in 0..<(count - 1) {
            split.setPosition(step * CGFloat(i + 1), ofDividerAt: i)
        }
    }

    private func toggleMaximize(_ item: OutputItemView) {
        guard items.count > 1, !isTabbed else { return }
        if maximized === item {
            items.forEach { $0.isHidden = false; $0.setMaximized(false) }
            maximized = nil
            split.adjustSubviews()
            equalize()
        } else {
            items.forEach { $0.isHidden = $0 !== item }
            item.setMaximized(true)
            maximized = item
            split.adjustSubviews()
        }
    }

    func showProgress() { progress.isHidden = false }
    func hideProgress() { progress.isHidden = true }
}

/// Robo's progress popup: an animated bar on a rounded grey panel (ProgressBarPopup.cpp).
final class ProgressPopup: NSView {
    private let image = NSImageView()

    // NSImageView keeps decoding and redrawing GIF frames while hidden or offscreen.
    private func updateAnimation() {
        image.animates = window != nil && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidHide() { updateAnimation() }
    override func viewDidUnhide() { updateAnimation() }
    override func viewDidMoveToWindow() { updateAnimation() }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 184, height: 36))
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0xE1 / 255, green: 0xE1 / 255, blue: 0xE1 / 255, alpha: 1).cgColor
        layer?.cornerRadius = 6
        image.image = Theme.icon("progress_bar.gif")
        image.imageScaling = .scaleNone
        addSubview(image)
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 184),
            heightAnchor.constraint(equalToConstant: 36),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 164),
            image.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
