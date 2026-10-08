import AppKit

/// One row of the result tree (BsonTreeItem.cpp); children are built lazily on first expand.
final class BsonNode {
    let key: String
    let fieldName: String
    let value: BSONValue
    weak var parent: BsonNode?
    let isArrayChild: Bool

    init(key: String, fieldName: String, value: BSONValue, parent: BsonNode?, isArrayChild: Bool) {
        self.key = key
        self.fieldName = fieldName
        self.value = value
        self.parent = parent
        self.isArrayChild = isArrayChild
    }

    static func roots(_ values: [BSONValue]) -> [BsonNode] {
        let formatter = BSONFormatter.current
        return values.enumerated().map { index, value in
            var idText = ""
            if case .document(let doc) = value, let id = doc["_id"] {
                idText = formatter.displayValue(id)
            }
            return BsonNode(key: "(\(index + 1)) \(idText)", fieldName: "", value: value, parent: nil, isArrayChild: false)
        }
    }

    private(set) lazy var children: [BsonNode] = {
        switch value {
        case .document(let doc):
            return doc.elements.map { BsonNode(key: $0.key, fieldName: $0.key, value: $0.value, parent: self, isArrayChild: false) }
        case .array(let items):
            return items.enumerated().map { BsonNode(key: "[\($0.offset)]", fieldName: String($0.offset), value: $0.element, parent: self, isArrayChild: true) }
        default:
            return []
        }
    }()

    var isContainer: Bool { value.isContainer }
    var isRoot: Bool { parent == nil }

    var root: BsonNode {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    var rootDocument: BSONDocument? { root.value.documentValue }

    var isSimple: Bool {
        switch value {
        case .int64, .double, .decimal128, .int32, .string, .bool, .date, .objectId: return true
        case .binary(let subtype, _): return subtype == 3 || subtype == 4
        default: return false
        }
    }

    private(set) lazy var displayValue: String = {
        switch value {
        case .string, .code, .codeWithScope:
            let simplified = fullValue.prefix(2000).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
            return simplified.count > 300 ? String(simplified.prefix(300)) : simplified
        default:
            return fullValue
        }
    }()

    private(set) lazy var fullValue: String = BSONFormatter.current.displayValue(value)
    private(set) lazy var toolTip = String(fullValue.prefix(500))

    var typeName: String { BSONFormatter.current.typeName(value) }

    var path: String {
        var names: [String] = []
        var node: BsonNode? = self
        while let current = node, !current.isRoot {
            if !current.isArrayChild { names.insert(current.fieldName, at: 0) }
            node = current.parent
        }
        return names.joined(separator: ".")
    }

    private lazy var childrenByName: [String: BsonNode] = Dictionary(children.map { ($0.fieldName, $0) }, uniquingKeysWith: { first, _ in first })

    func child(named name: String) -> BsonNode? {
        childrenByName[name]
    }
}

/// Document actions shared by the tree and table views (Notifier.cpp).
protocol DocumentActionsDelegate: AnyObject {
    var isEditable: Bool { get }
    func editDocument(_ node: BsonNode)
    func viewDocument(_ node: BsonNode)
    func insertDocument()
    func deleteDocuments(_ roots: [BsonNode])
}

enum DocumentMenu {
    static func build(nodes: [BsonNode], delegate: DocumentActionsDelegate?, expand: (@MainActor () -> Void)?, collapse: (@MainActor () -> Void)?) -> NSMenu {
        let menu = NSMenu()
        let editable = delegate?.isEditable ?? false
        let roots = uniqueRoots(nodes)

        if roots.count > 1 {
            if let expand, let collapse {
                menu.addItem(ClosureMenuItem(title: "Expand Recursively", keyEquivalent: "", action: expand))
                menu.addItem(ClosureMenuItem(title: "Collapse Recursively", keyEquivalent: "", action: collapse))
                menu.addItem(.separator())
            }
            if editable {
                menu.addItem(ClosureMenuItem(title: "Insert Document...") { delegate?.insertDocument() })
                menu.addItem(ClosureMenuItem(title: "Delete Documents...") { delegate?.deleteDocuments(roots) })
            }
            return menu
        }

        let node = nodes.first
        if let node, node.isContainer, let expand, let collapse {
            let e = ClosureMenuItem(title: "Expand Recursively", action: expand)
            e.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            e.keyEquivalentModifierMask = .option
            let c = ClosureMenuItem(title: "Collapse Recursively", action: collapse)
            c.keyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            c.keyEquivalentModifierMask = .option
            menu.addItem(e)
            menu.addItem(c)
            menu.addItem(.separator())
        }
        if let node, editable { menu.addItem(ClosureMenuItem(title: "Edit Document...") { delegate?.editDocument(node) }) }
        if let node { menu.addItem(ClosureMenuItem(title: "View Document...") { delegate?.viewDocument(node) }) }
        if editable { menu.addItem(ClosureMenuItem(title: "Insert Document...") { delegate?.insertDocument() }) }
        if let node {
            if node.isSimple || node.isContainer { menu.addItem(.separator()) }
            if node.isSimple {
                menu.addItem(ClosureMenuItem(title: "Copy Value") { copy(node.fullValue) })
            }
            if (node.isSimple || node.isContainer) && !node.isArrayChild && !node.isRoot {
                menu.addItem(ClosureMenuItem(title: "Copy Name") { copy(node.fieldName) })
            }
            if (node.isSimple || node.isContainer) && !node.isRoot {
                menu.addItem(ClosureMenuItem(title: "Copy Path") { copy(node.path) })
            }
            if case .objectId(let oid) = node.value {
                menu.addItem(ClosureMenuItem(title: "Copy Timestamp from ObjectId") {
                    let iso = BSONFormatter(uuidEncoding: .standard, timeZone: .utc).isoTime(Int64(oid.timestampSeconds) * 1000, separator: " ")
                    copy("ISODate(\"\(iso)\")")
                })
            }
            if node.isContainer {
                menu.addItem(ClosureMenuItem(title: "Copy JSON") { copy(BSONFormatter.current.json(node.value)) })
            }
            if editable {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Delete Document...") { delegate?.deleteDocuments([node.root]) })
            }
        }
        return menu
    }

    static func uniqueRoots(_ nodes: [BsonNode]) -> [BsonNode] {
        var seen = Set<ObjectIdentifier>()
        var roots: [BsonNode] = []
        for node in nodes {
            let root = node.root
            if seen.insert(ObjectIdentifier(root)).inserted { roots.append(root) }
        }
        return roots
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Tree

final class BsonOutlineView: NSOutlineView {
    var menuProvider: (() -> NSMenu?)?
    var onDelete: (() -> Void)?
    var onExpandRecursive: (() -> Void)?
    var onCollapseRecursive: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?()
    }

    override func keyDown(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 117: onDelete?(); return
        case 51 where event.modifierFlags.contains(.command): onDelete?(); return
        case 124 where option: onExpandRecursive?(); return
        case 123 where option: onCollapseRecursive?(); return
        default: break
        }
        super.keyDown(with: event)
    }
}

final class BsonTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outlineView = BsonOutlineView()
    private(set) var roots: [BsonNode]
    weak var actions: DocumentActionsDelegate?

    init(values: [BSONValue], actions: DocumentActionsDelegate?) {
        roots = BsonNode.roots(values)
        self.actions = actions
        super.init()
        for (id, title) in [("key", "Key"), ("value", "Value"), ("type", "Type")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = 250
            column.minWidth = 40
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            outlineView.addTableColumn(column)
            if id == "key" { outlineView.outlineTableColumn = column }
        }
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.style = .plain
        outlineView.rowHeight = 20
        outlineView.intercellSpacing = NSSize(width: 3, height: 0)
        outlineView.indentationPerLevel = 16
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsMultipleSelection = true
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menuProvider = { [weak self] in self?.contextMenu() }
        outlineView.onDelete = { [weak self] in self?.deleteSelected() }
        outlineView.onExpandRecursive = { [weak self] in self?.expandSelected(true) }
        outlineView.onCollapseRecursive = { [weak self] in self?.expandSelected(false) }
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        outlineView.reloadData()
        outlineView.sizeLastColumnToFit()
        if AppSettings.shared.autoExpand, let first = roots.first {
            outlineView.expandItem(first)
        }
    }

    var selectedNodes: [BsonNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? BsonNode }
    }

    private func contextMenu() -> NSMenu? {
        DocumentMenu.build(nodes: selectedNodes, delegate: actions,
                           expand: { [weak self] in self?.expandSelected(true) },
                           collapse: { [weak self] in self?.expandSelected(false) })
    }

    private func deleteSelected() {
        guard actions?.isEditable == true else { return }
        actions?.deleteDocuments(DocumentMenu.uniqueRoots(selectedNodes))
    }

    private func expandSelected(_ expand: Bool) {
        // Bottom-up, so expanding a node doesn't shift the rows of the ones still to come.
        for node in selectedNodes.sorted(by: { outlineView.row(forItem: $0) > outlineView.row(forItem: $1) }) {
            if expand { outlineView.expandItem(node, expandChildren: true) } else { outlineView.collapseItem(node, collapseChildren: true) }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? BsonNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? BsonNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BsonNode)?.isContainer ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        RoboRowView.make(outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BsonNode, let column = tableColumn?.identifier.rawValue else { return nil }
        switch column {
        case "key":
            let cell = BsonCell.make(outlineView, id: "keyCell", withIcon: true)
            cell.imageView?.image = Theme.bsonIcon(node.value)
            cell.textField?.stringValue = node.key
            cell.textField?.textColor = .labelColor
            return cell
        case "value":
            let cell = BsonCell.make(outlineView, id: "valueCell", withIcon: false)
            cell.textField?.stringValue = node.displayValue
            cell.textField?.textColor = .labelColor
            cell.textField?.toolTip = node.isContainer ? nil : node.toolTip
            return cell
        default:
            let cell = BsonCell.make(outlineView, id: "typeCell", withIcon: false)
            cell.textField?.stringValue = node.typeName
            cell.textField?.textColor = Theme.typeText
            return cell
        }
    }
}

enum BsonCell {
    static func make(_ tableView: NSTableView, id: String, withIcon: Bool) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = BsonCellView(withIcon: withIcon)
        cell.identifier = identifier
        return cell
    }
}

/// Frame layout instead of constraints: every reused cell otherwise re-solves Auto Layout while scrolling.
private final class BsonCellView: NSTableCellView {
    private let textHeight: CGFloat

    init(withIcon: Bool) {
        let text = NSTextField(labelWithString: "")
        text.font = Theme.treeFont
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        textHeight = ceil(text.intrinsicContentSize.height)
        super.init(frame: .zero)
        addSubview(text)
        textField = text
        if withIcon {
            let image = NSImageView()
            addSubview(image)
            imageView = image
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        if let imageView {
            imageView.frame = NSRect(x: x, y: floor((bounds.height - 16) / 2), width: 16, height: 16)
            x = imageView.frame.maxX + 5
        }
        textField?.frame = NSRect(x: x, y: floor((bounds.height - textHeight) / 2), width: max(bounds.width - x - 2, 0), height: textHeight)
    }
}

// MARK: - Table

final class BsonTableView: NSTableView {
    var menuProvider: ((Int, Int) -> NSMenu?)?
    var onDelete: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return menuProvider?(row, column)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 117 || (event.keyCode == 51 && event.modifierFlags.contains(.command)) {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

final class BsonTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = BsonTableView()
    private let roots: [BsonNode]
    private var columns: [String] = []
    private static let maxColumns = 300
    weak var actions: DocumentActionsDelegate?

    init(values: [BSONValue], actions: DocumentActionsDelegate?) {
        roots = BsonNode.roots(values)
        self.actions = actions
        super.init()
        var seen = Set<String>()
        for case .document(let doc) in values {
            for element in doc.elements where seen.insert(element.key).inserted { columns.append(element.key) }
        }
        // NSTableView gets quadratically slower per added column; documents keyed by ids can have thousands.
        let hiddenColumns = max(columns.count - Self.maxColumns, 0)
        columns = Array(columns.prefix(Self.maxColumns))
        let numberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
        numberColumn.title = ""
        numberColumn.width = max(28, CGFloat(String(roots.count).count) * 9 + 12)
        numberColumn.resizingMask = []
        tableView.addTableColumn(numberColumn)
        for (index, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = name
            column.width = 160
            column.minWidth = 40
            tableView.addTableColumn(column)
        }
        if hiddenColumns > 0 {
            let more = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("more"))
            more.title = "+\(hiddenColumns) more"
            more.headerToolTip = "\(hiddenColumns) more fields are only shown in the tree and text views."
            more.width = 120
            tableView.addTableColumn(more)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.rowHeight = 20
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = Theme.gridLine
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menuProvider = { [weak self] row, column in self?.contextMenu(row: row, column: column) }
        tableView.onDelete = { [weak self] in self?.deleteSelected() }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    private func node(row: Int, column: Int) -> BsonNode? {
        guard row >= 0, row < roots.count else { return nil }
        guard column >= 1, column - 1 < columns.count else { return roots[row] }
        return roots[row].child(named: columns[column - 1]) ?? roots[row]
    }

    private func contextMenu(row: Int, column: Int) -> NSMenu? {
        let selected = tableView.selectedRowIndexes.map { roots[$0] }
        if selected.count > 1 {
            return DocumentMenu.build(nodes: selected, delegate: actions, expand: nil, collapse: nil)
        }
        return DocumentMenu.build(nodes: [node(row: row, column: column)].compactMap { $0 }, delegate: actions, expand: nil, collapse: nil)
    }

    private func deleteSelected() {
        guard actions?.isEditable == true else { return }
        actions?.deleteDocuments(tableView.selectedRowIndexes.map { roots[$0] })
    }

    func numberOfRows(in tableView: NSTableView) -> Int { roots.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RoboRowView.make(tableView) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if id == "#" {
            let cell = BsonCell.make(tableView, id: "numberCell", withIcon: false)
            cell.textField?.stringValue = "\(row + 1)"
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
        guard let index = Int(id.dropFirst()) else { return nil }
        let root = roots[row]
        guard let child = root.child(named: columns[index]) else {
            let identifier = NSUserInterfaceItemIdentifier("missingCell")
            if let empty = tableView.makeView(withIdentifier: identifier, owner: nil) { return empty }
            let empty = ColorView(color: Theme.missingCell)
            empty.identifier = identifier
            return empty
        }
        let cell = BsonCell.make(tableView, id: "tableCell", withIcon: true)
        cell.imageView?.image = Theme.bsonIcon(child.value)
        cell.textField?.stringValue = child.displayValue
        cell.textField?.toolTip = child.toolTip
        return cell
    }
}
