import AppKit

/// "MongoDB Connections" (ConnectionsDialog.cpp).
final class ConnectionsWindow: ModalDialog, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let tableView = ConnectionsTableView()
    private var connections: [ConnectionSettings] { AppSettings.shared.connections }
    private static let dragType = NSPasteboard.PasteboardType("robo-tribute.connection.row")
    private(set) var selected: ConnectionSettings?

    init() {
        super.init(title: "MongoDB Connections", size: NSSize(width: 864, height: 526), resizable: true)
        window.minSize = NSSize(width: 660, height: 380)
        window.setFrameAutosaveName("ConnectionsDialog")

        let intro = NSTextView()
        intro.isEditable = false
        intro.drawsBackground = false
        intro.isSelectable = true
        intro.delegate = self
        intro.textContainerInset = .zero
        intro.textContainer?.lineFragmentPadding = 0
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 13)
        for (word, link) in [("Create", "create"), (",", nil), ("edit", "edit"), (",", nil), ("remove", "remove"), (",", nil), ("clone", "clone"),
                             (" or reorder connections via drag'n'drop.", nil)] as [(String, String?)] {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link {
                attrs[.link] = link
                attrs[.foregroundColor] = Theme.link
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            text.append(NSAttributedString(string: word, attributes: attrs))
        }
        intro.textStorage?.setAttributedString(text)
        intro.linkTextAttributes = [.foregroundColor: Theme.link, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        intro.heightAnchor.constraint(equalToConstant: 18).isActive = true

        for (id, title, width) in [("name", "Name", 250.0), ("address", "Address", 250.0), ("attributes", "Attributes", 60.0), ("auth", "Auth. Database / User", 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.rowHeight = 18
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(accept)
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.focusRingType = .none
        tableView.menu = contextMenu()
        tableView.onEdit = { [weak self] in self?.edit() }
        tableView.onDelete = { [weak self] in self?.remove() }
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        var leading: [NSView] = []
        if AppSettings.shared.importedConnectionsCount > 0 {
            let count = AppSettings.shared.importedConnectionsCount
            let icon = NSImageView(image: Theme.info)
            let label = NSTextField(labelWithString: "Connection settings have been imported (\(count) \(count > 1 ? "records" : "record")), passwords need to be re-entered")
            label.textColor = NSColor(srgbRed: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255, alpha: 1)
            leading = [icon, label]
            AppSettings.shared.importedConnectionsCount = 0
        }
        let buttons = buttonRow(okTitle: "Connect", okImage: Theme.server, leading: leading)

        let stack = NSStackView(views: [intro, scroll, buttons])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 20)
        for view in [intro, scroll, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        tableView.reloadData()
        if !connections.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: connections.count - 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(connections.count - 1)
        }
        window.initialFirstResponder = tableView
    }

    override func validate() -> Bool {
        let row = tableView.selectedRow
        guard row >= 0, row < connections.count else { return false }
        selected = connections[row]
        return true
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Add...") { [weak self] in self?.add() })
        menu.addItem(ClosureMenuItem(title: "Edit...") { [weak self] in self?.edit() })
        menu.addItem(ClosureMenuItem(title: "Clone...") { [weak self] in self?.clone() })
        menu.addItem(ClosureMenuItem(title: "Remove...") { [weak self] in self?.remove() })
        return menu
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        switch link as? String {
        case "create": add()
        case "edit": edit()
        case "remove": remove()
        case "clone": clone()
        default: return false
        }
        return true
    }

    // MARK: Actions

    private func add() {
        addNew(ConnectionSettings(), secrets: ConnectionSecrets())
    }

    private func addNew(_ settings: ConnectionSettings, secrets: ConnectionSecrets) {
        guard let (settings, secrets) = ConnectionSettingsWindow(settings: settings, secrets: secrets).run() else { return }
        AppSettings.shared.connections.append(settings)
        Keychain.store(secrets, for: settings.id)
        AppSettings.shared.save()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: connections.count - 1), byExtendingSelection: false)
    }

    private func edit() {
        let row = tableView.selectedRow
        guard row >= 0, row < connections.count else { return }
        let original = connections[row]
        let dialog = ConnectionSettingsWindow(settings: original, secrets: Keychain.secrets(for: original.id))
        guard let (settings, secrets) = dialog.run() else { return }
        AppSettings.shared.connections[row] = settings
        Keychain.store(secrets, for: settings.id)
        AppSettings.shared.save()
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(0..<4))
    }

    private func clone() {
        let row = tableView.selectedRow
        guard row >= 0, row < connections.count else { return }
        var copy = connections[row]
        let secrets = Keychain.secrets(for: copy.id)
        copy.id = UUID().uuidString
        copy.connectionName = "Copy of " + copy.connectionName
        copy.imported = false
        addNew(copy, secrets: secrets)
    }

    private func remove() {
        let row = tableView.selectedRow
        guard row >= 0, row < connections.count else { return }
        let connection = connections[row]
        guard Alerts.confirm("Connections", "Are you sure you want to delete \"\(connection.readableName)\" connection?", destructive: true) else { return }
        AppSettings.shared.connections.remove(at: row)
        Keychain.delete(connection.id)
        AppSettings.shared.save()
        tableView.reloadData()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RoboRowView.make(tableView) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let connection = connections[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let withIcon = id == "name" || id == "auth"
        let cell = BsonCell.make(tableView, id: "conn-\(id)", withIcon: withIcon)
        cell.textField?.font = .systemFont(ofSize: 13)
        switch id {
        case "name":
            cell.imageView?.image = connection.imported ? Theme.serverImported : (connection.isReplicaSet ? Theme.replicaSet : Theme.server)
            cell.textField?.stringValue = connection.connectionName
        case "address":
            if connection.isReplicaSet {
                let members = connection.replicaSetMembers
                var text = "\(members.count) \(members.count == 1 ? "node" : "nodes")"
                if let first = members.first { text += " (\(first))" }
                cell.textField?.stringValue = text
            } else {
                cell.textField?.stringValue = connection.fullAddress
            }
        case "attributes":
            var attributes: [String] = []
            if connection.isReplicaSet { attributes.append("Replica Set") }
            if connection.connectionType == .srv { attributes.append("SRV") }
            if connection.ssl.sslEnabled { attributes.append("TLS") }
            if !connection.isReplicaSet && connection.ssh.enabled { attributes.append("SSH") }
            cell.textField?.stringValue = attributes.joined(separator: ", ")
        default:
            if connection.hasEnabledCredential {
                cell.imageView?.image = Theme.key
                cell.textField?.stringValue = "\(connection.credential.databaseName) / \(connection.credential.userName)"
            } else {
                cell.imageView?.image = nil
                cell.textField?.stringValue = ""
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let string = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType), let from = Int(string) else { return false }
        var list = AppSettings.shared.connections
        let moved = list.remove(at: from)
        let to = from < row ? row - 1 : row
        list.insert(moved, at: to)
        AppSettings.shared.connections = list
        AppSettings.shared.save()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: to), byExtendingSelection: false)
        return true
    }
}

final class ConnectionsTableView: NSTableView {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "e" { onEdit?(); return }
        if event.keyCode == 117 || (event.keyCode == 51 && event.modifierFlags.contains(.command)) { onDelete?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { sendAction(doubleAction, to: target); return }
        super.keyDown(with: event)
    }
}
