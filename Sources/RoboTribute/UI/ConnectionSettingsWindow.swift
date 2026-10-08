import AppKit
import CMongoC

/// "Connection Settings" with the Connection, Authentication, SSH, TLS and Advanced tabs (ConnectionDialog.cpp and tabs).
final class ConnectionSettingsWindow: ModalDialog, NSTableViewDataSource, NSTableViewDelegate {
    private var settings: ConnectionSettings
    private var secrets: ConnectionSecrets

    // Connection
    private let typePopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let addressInfo = wrapping("Specify host and port of MongoDB server. Host can be either IPv4, IPv6 or domain name.")
    private let membersTable = NSTableView()
    private var members: [String] = []
    private let setNameField = NSTextField()
    private let uriField = NSTextField()
    private var connectionGrid: NSGridView!
    private var portContainer: NSStackView!

    // Authentication
    private let useAuth = NSButton(checkboxWithTitle: "Perform authentication", target: nil, action: nil)
    private let authDbField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = SecretField()
    private let mechanismPopup = NSPopUpButton()
    private let useManualDbs = NSButton(checkboxWithTitle: "Manually specify visible databases", target: nil, action: nil)
    private let manualDbsField = NSTextField()
    private var authGrid: NSGridView!

    // SSH
    private let useSSH = NSButton(checkboxWithTitle: "Use SSH tunnel", target: nil, action: nil)
    private let sshHostField = NSTextField()
    private let sshPortField = NSTextField()
    private let sshUserField = NSTextField()
    private let sshMethodPopup = NSPopUpButton()
    private let sshPasswordField = SecretField()
    private let sshKeyField = NSTextField()
    private let sshPassphraseField = SecretField()
    private let sshAsk = NSButton(checkboxWithTitle: "Ask for password each time", target: nil, action: nil)
    private var sshGrid: NSGridView!

    // TLS
    private let useTLS = NSButton(checkboxWithTitle: "Use TLS protocol", target: nil, action: nil)
    private let tlsMethodPopup = NSPopUpButton()
    private let caField = NSTextField()
    private let usePem = NSButton(checkboxWithTitle: "Use PEM Cert./Key: ", target: nil, action: nil)
    private let pemField = NSTextField()
    private let pemPassField = SecretField()
    private let pemAsk = NSButton(checkboxWithTitle: "Ask for passphrase each time", target: nil, action: nil)
    private let tlsAdvanced = NSButton(checkboxWithTitle: "Advanced Options", target: nil, action: nil)
    private let crlField = NSTextField()
    private let invalidHostnamesPopup = NSPopUpButton()
    private var tlsGrid: NSGridView!

    // Advanced
    private let defaultDbField = NSTextField()
    private let readOnlyCheck = NSButton(checkboxWithTitle: "Read-only connection", target: nil, action: nil)

    init(settings: ConnectionSettings, secrets: ConnectionSecrets) {
        self.settings = settings
        self.secrets = secrets
        super.init(title: "Connection Settings", size: NSSize(width: 660, height: 470), resizable: true)
        window.minSize = NSSize(width: 660, height: 440)
        window.setFrameAutosaveName("ConnectionDialog")

        let tabs = NSTabView()
        tabs.addTabViewItem(tab("Connection", buildConnectionTab()))
        tabs.addTabViewItem(tab("Authentication", buildAuthTab()))
        tabs.addTabViewItem(tab("SSH", buildSSHTab()))
        tabs.addTabViewItem(tab("TLS", buildTLSTab()))
        tabs.addTabViewItem(tab("Advanced", buildAdvancedTab()))

        let test = NSButton(title: "Test", target: self, action: #selector(test))
        test.image = Theme.info
        test.imagePosition = .imageLeading
        let buttons = buttonRow(okTitle: "Save", leading: [test])
        let stack = NSStackView(views: [tabs, buttons])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        tabs.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        window.initialFirstResponder = nameField
        load()
    }

    func run() -> (ConnectionSettings, ConnectionSecrets)? {
        runModal() ? (settings, secrets) : nil
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let container = NSView()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])
        item.view = container
        return item
    }

    private static func wrapping(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 440
        return label
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        return grid
    }

    private func fileRow(_ field: NSTextField, action: Selector) -> NSStackView {
        let button = NSButton(title: "...", target: self, action: action)
        button.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let row = NSStackView(views: [field, button])
        row.spacing = 6
        return row
    }

    // MARK: Tabs

    private func buildConnectionTab() -> NSView {
        typePopup.addItems(withTitles: ["Direct Connection", "Replica Set", "DNS Seedlist (SRV)"])
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        portField.formatter = DigitsFormatter()
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        portContainer = NSStackView(views: [hostField, NSTextField(labelWithString: ":"), portField])
        portContainer.spacing = 4

        membersTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("member")))
        membersTable.headerView = nil
        membersTable.dataSource = self
        membersTable.delegate = self
        membersTable.rowHeight = 18
        let membersScroll = NSScrollView()
        membersScroll.documentView = membersTable
        membersScroll.borderType = .bezelBorder
        membersScroll.hasVerticalScroller = true
        membersScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let plusMinus = NSSegmentedControl(images: [NSImage(named: NSImage.removeTemplateName)!, NSImage(named: NSImage.addTemplateName)!],
                                           trackingMode: .momentary, target: self, action: #selector(membersPlusMinus(_:)))
        let membersBox = NSStackView(views: [membersScroll, plusMinus])
        membersBox.orientation = .vertical
        membersBox.alignment = .trailing
        membersScroll.widthAnchor.constraint(equalTo: membersBox.widthAnchor).isActive = true

        let fromURI = NSButton(title: "From URI", target: self, action: #selector(fromURI))
        uriField.placeholderString = "Import connection details from MongoDB URI connection string"

        connectionGrid = grid([
            [NSTextField(labelWithString: "Type:"), typePopup],
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSGridCell.emptyContentView, Self.wrapping("Choose any connection name that will help you to identify this connection.")],
            [NSTextField(labelWithString: "Address:"), portContainer],
            [NSGridCell.emptyContentView, addressInfo],
            [NSTextField(labelWithString: "Members:"), membersBox],
            [NSTextField(labelWithString: "Set Name:"), setNameField],
            [horizontalLine()],
            [fromURI, uriField],
        ])
        connectionGrid.row(at: 7).mergeCells(in: NSRange(location: 0, length: 2))
        connectionGrid.row(at: 7).topPadding = 16
        connectionGrid.row(at: 7).bottomPadding = 8
        connectionGrid.column(at: 1).width = 460
        return connectionGrid
    }

    private func buildAuthTab() -> NSView {
        useAuth.target = self
        useAuth.action = #selector(updateAuthState)
        useManualDbs.target = self
        useManualDbs.action = #selector(updateAuthState)
        mechanismPopup.addItems(withTitles: ["SCRAM-SHA-1", "SCRAM-SHA-256"])
        manualDbsField.placeholderString = "Comma-separated e.g. products, users"
        authGrid = grid([
            [useAuth],
            [NSTextField(labelWithString: "Database"), authDbField],
            [NSGridCell.emptyContentView, Self.wrapping("The admin database is unique in MongoDB. Users with normal access to the admin database have read and write access to all databases.")],
            [NSTextField(labelWithString: "User Name"), userField],
            [NSTextField(labelWithString: "Password"), passwordField],
            [NSTextField(labelWithString: "Auth Mechanism"), mechanismPopup],
            [horizontalLine()],
            [useManualDbs],
            [NSTextField(labelWithString: "Databases"), manualDbsField],
            [NSGridCell.emptyContentView, Self.wrapping("Some MongoDB users might not have the permission to get the list of database names (listDatabases command). For this case, manually add the name of the database(s) that this user has access to.")],
        ])
        for row in [0, 6, 7] { authGrid.row(at: row).mergeCells(in: NSRange(location: 0, length: 2)) }
        authGrid.cell(atColumnIndex: 0, rowIndex: 0).xPlacement = .leading
        authGrid.cell(atColumnIndex: 0, rowIndex: 7).xPlacement = .leading
        authGrid.row(at: 3).topPadding = 12
        authGrid.row(at: 6).topPadding = 12
        authGrid.row(at: 6).bottomPadding = 4
        authGrid.column(at: 1).width = 440
        return authGrid
    }

    private func buildSSHTab() -> NSView {
        useSSH.target = self
        useSSH.action = #selector(updateSSHState)
        sshAsk.target = self
        sshAsk.action = #selector(updateSSHState)
        sshMethodPopup.addItems(withTitles: ["Password", "Private Key"])
        sshMethodPopup.target = self
        sshMethodPopup.action = #selector(updateSSHState)
        sshPortField.formatter = DigitsFormatter()
        sshPortField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        sshKeyField.placeholderString = "RSA, ECDSA and Ed25519 keys in OpenSSH format are supported."
        let address = NSStackView(views: [sshHostField, NSTextField(labelWithString: ":"), sshPortField])
        address.spacing = 4
        sshGrid = grid([
            [useSSH],
            [NSTextField(labelWithString: "SSH Address:"), address],
            [NSTextField(labelWithString: "SSH User Name:"), sshUserField],
            [NSTextField(labelWithString: "SSH Auth Method:"), sshMethodPopup],
            [NSTextField(labelWithString: "User Password:"), sshPasswordField],
            [NSTextField(labelWithString: "Private key:"), fileRow(sshKeyField, action: #selector(browseSSHKey))],
            [NSTextField(labelWithString: "Passphrase:"), sshPassphraseField],
            [NSGridCell.emptyContentView, sshAsk],
        ])
        sshGrid.row(at: 0).mergeCells(in: NSRange(location: 0, length: 2))
        sshGrid.cell(atColumnIndex: 0, rowIndex: 0).xPlacement = .leading
        sshGrid.column(at: 1).width = 440
        return sshGrid
    }

    private func buildTLSTab() -> NSView {
        useTLS.target = self
        useTLS.action = #selector(updateTLSState)
        tlsMethodPopup.addItems(withTitles: ["Self-signed Certificate", "Use CA Certificate"])
        tlsMethodPopup.item(at: 0)?.toolTip = "mongo --tlsAllowInvalidCertificates : Allow connections to servers with invalid certificates"
        tlsMethodPopup.item(at: 1)?.toolTip = "mongo --tlsCAFile : Certificate Authority file for TLS"
        tlsMethodPopup.target = self
        tlsMethodPopup.action = #selector(updateTLSState)
        usePem.target = self
        usePem.action = #selector(updateTLSState)
        pemAsk.target = self
        pemAsk.action = #selector(updateTLSState)
        tlsAdvanced.target = self
        tlsAdvanced.action = #selector(updateTLSState)
        invalidHostnamesPopup.addItems(withTitles: ["Not Allowed", "Allowed"])
        tlsGrid = grid([
            [useTLS],
            [NSTextField(labelWithString: "Authentication Method: "), tlsMethodPopup],
            [NSGridCell.emptyContentView, Self.wrapping("In general, avoid using self-signed certificates unless the network is trusted. If self-signed certificate is used, the communications channel will be encrypted however there will be no validation of server identity.")],
            [NSTextField(labelWithString: "CA Certificate:"), fileRow(caField, action: #selector(browseCA))],
            [usePem, Self.wrapping("Enable this option to connect to a MongoDB that requires CA-signed client certificates/key file.")],
            [NSTextField(labelWithString: "PEM Certificate/Key: "), fileRow(pemField, action: #selector(browsePEM))],
            [NSTextField(labelWithString: "Passphrase: "), pemPassField],
            [NSGridCell.emptyContentView, pemAsk],
            [tlsAdvanced],
            [NSTextField(labelWithString: "CRL (Revocation List): "), fileRow(crlField, action: #selector(browseCRL))],
            [NSTextField(labelWithString: "Invalid Hostnames: "), invalidHostnamesPopup],
        ])
        tlsGrid.row(at: 0).mergeCells(in: NSRange(location: 0, length: 2))
        tlsGrid.cell(atColumnIndex: 0, rowIndex: 0).xPlacement = .leading
        tlsGrid.cell(atColumnIndex: 0, rowIndex: 8).xPlacement = .trailing
        tlsGrid.row(at: 4).topPadding = 10
        tlsGrid.row(at: 8).topPadding = 10
        tlsGrid.column(at: 1).width = 400
        caField.toolTip = "mongo --tlsCAFile : Certificate Authority file for TLS"
        pemField.toolTip = "mongo --tlsCertificateKeyFile : PEM certificate/key file for TLS"
        crlField.toolTip = "mongo --tlsCRLFile : Certificate Revocation List file for TLS"
        return tlsGrid
    }

    private func buildAdvancedTab() -> NSView {
        let description = Self.wrapping("Database, that will be default (db shell variable will point to this database). By default, default database will be the one you authenticate on, or test otherwise. Leave this field empty, if you want default behavior.")
        let g = grid([
            [NSTextField(labelWithString: "Default Database:"), defaultDbField],
            [NSGridCell.emptyContentView, description],
            [NSGridCell.emptyContentView, readOnlyCheck],
            [NSGridCell.emptyContentView, Self.wrapping("Blocks every command that could change data, from the shell, the explorer and the document editor.")],
        ])
        g.row(at: 2).topPadding = 12
        g.column(at: 1).width = 440
        return g
    }

    // MARK: Load / store

    private func load() {
        typePopup.selectItem(at: settings.connectionType.rawValue)
        nameField.stringValue = settings.connectionName
        hostField.stringValue = settings.serverHost
        portField.stringValue = "\(settings.serverPort)"
        members = settings.replicaSetMembers.isEmpty ? ["localhost:27017"] : settings.replicaSetMembers
        membersTable.reloadData()
        setNameField.stringValue = settings.replicaSetName

        let credential = settings.credential
        useAuth.state = credential.enabled ? .on : .off
        authDbField.stringValue = credential.databaseName
        userField.stringValue = credential.userName
        passwordField.stringValue = secrets.password
        mechanismPopup.selectItem(withTitle: credential.mechanism)
        if mechanismPopup.indexOfSelectedItem < 0 { mechanismPopup.selectItem(withTitle: "SCRAM-SHA-256") }
        useManualDbs.state = credential.useManuallyVisibleDbs ? .on : .off
        manualDbsField.stringValue = credential.manuallyVisibleDbs

        let ssh = settings.ssh
        useSSH.state = ssh.enabled ? .on : .off
        sshHostField.stringValue = ssh.host
        sshPortField.stringValue = "\(ssh.port)"
        sshUserField.stringValue = ssh.userName
        sshMethodPopup.selectItem(at: ssh.usesPublicKey ? 1 : 0)
        sshPasswordField.stringValue = secrets.sshPassword
        sshKeyField.stringValue = ssh.privateKeyFile
        sshPassphraseField.stringValue = secrets.sshPassphrase
        sshAsk.state = ssh.askPassword ? .on : .off

        let ssl = settings.ssl
        useTLS.state = ssl.sslEnabled ? .on : .off
        tlsMethodPopup.selectItem(at: ssl.allowInvalidCertificates ? 0 : 1)
        caField.stringValue = ssl.caFile
        usePem.state = ssl.usePemFile ? .on : .off
        pemField.stringValue = ssl.pemKeyFile
        pemPassField.stringValue = secrets.pemPassphrase
        pemAsk.state = ssl.askPassphrase ? .on : .off
        tlsAdvanced.state = ssl.useAdvancedOptions ? .on : .off
        crlField.stringValue = ssl.crlFile
        invalidHostnamesPopup.selectItem(at: ssl.allowInvalidHostnames ? 1 : 0)

        defaultDbField.stringValue = settings.defaultDatabase
        readOnlyCheck.state = settings.isReadOnly ? .on : .off
        typeChanged()
        updateAuthState()
        updateSSHState()
        updateTLSState()
    }

    private func store() {
        settings.connectionType = ConnectionType(rawValue: typePopup.indexOfSelectedItem) ?? .direct
        settings.connectionName = nameField.stringValue
        settings.serverHost = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.serverPort = Int(portField.stringValue) ?? 27017
        settings.replicaSetMembers = settings.isReplicaSet ? members.filter { !$0.isEmpty } : []
        settings.replicaSetName = settings.isReplicaSet ? setNameField.stringValue : ""
        if settings.isReplicaSet, let first = members.first.flatMap(ConnectionSettings.splitHostPort) {
            settings.serverHost = first.host
            settings.serverPort = first.port
        }

        settings.credential.enabled = useAuth.state == .on
        settings.credential.databaseName = authDbField.stringValue
        settings.credential.userName = userField.stringValue
        settings.credential.mechanism = mechanismPopup.titleOfSelectedItem ?? "SCRAM-SHA-256"
        settings.credential.useManuallyVisibleDbs = useManualDbs.state == .on && !manualDbsField.stringValue.isEmpty
        settings.credential.manuallyVisibleDbs = manualDbsField.stringValue.replacingOccurrences(of: " ", with: "")
        secrets.password = passwordField.stringValue

        settings.ssh.enabled = useSSH.state == .on && settings.connectionType == .direct
        settings.ssh.host = sshHostField.stringValue
        settings.ssh.port = Int(sshPortField.stringValue) ?? 22
        settings.ssh.userName = sshUserField.stringValue
        settings.ssh.method = sshMethodPopup.indexOfSelectedItem == 1 ? "publickey" : "password"
        settings.ssh.privateKeyFile = sshKeyField.stringValue
        settings.ssh.askPassword = sshAsk.state == .on
        secrets.sshPassword = settings.ssh.askPassword ? "" : sshPasswordField.stringValue
        secrets.sshPassphrase = settings.ssh.askPassword ? "" : sshPassphraseField.stringValue

        settings.ssl.sslEnabled = useTLS.state == .on
        settings.ssl.allowInvalidCertificates = tlsMethodPopup.indexOfSelectedItem == 0
        settings.ssl.caFile = caField.stringValue
        settings.ssl.usePemFile = usePem.state == .on
        settings.ssl.pemKeyFile = pemField.stringValue
        settings.ssl.askPassphrase = pemAsk.state == .on
        settings.ssl.useAdvancedOptions = tlsAdvanced.state == .on
        settings.ssl.crlFile = crlField.stringValue
        settings.ssl.allowInvalidHostnames = invalidHostnamesPopup.indexOfSelectedItem == 1
        secrets.pemPassphrase = settings.ssl.askPassphrase ? "" : pemPassField.stringValue

        settings.defaultDatabase = defaultDbField.stringValue
        settings.readOnly = readOnlyCheck.state == .on
    }

    override func validate() -> Bool {
        window.makeFirstResponder(nil)
        store()
        if settings.isReplicaSet {
            if members.filter({ !$0.isEmpty }).isEmpty {
                Alerts.error("Error", "Replica set members cannot be empty. Please enter at least one member.")
                return false
            }
            if members.contains(where: { !$0.contains(":") }) {
                Alerts.error("Error", "Replica set member items must all contain ':' between hostname and port.")
                return false
            }
            if Set(members).count != members.count {
                Alerts.error("Error", "Please remove duplicate member, two replica set members cannot have the same hostname and port.")
                return false
            }
        }
        if let reason = settings.transportSecurityError {
            Alerts.error("Error", reason)
            return false
        }
        let fm = FileManager.default
        let exists: (String) -> Bool = { fm.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
        if settings.ssh.enabled && settings.ssh.usesPublicKey && !settings.ssh.privateKeyFile.isEmpty && !exists(settings.ssh.privateKeyFile) {
            Alerts.info("Settings are incomplete", "Private key file \"\(settings.ssh.privateKeyFile)\" doesn't exist")
            return false
        }
        if settings.ssl.sslEnabled {
            if !settings.ssl.allowInvalidCertificates && !settings.ssl.caFile.isEmpty && !exists(settings.ssl.caFile) {
                Alerts.error("Error", "Error: CA-signed certificate file does not exist")
                return false
            }
            if settings.ssl.usePemFile && !exists(settings.ssl.pemKeyFile) {
                Alerts.error("Error", "Error: PEM Certificate/Key file does not exist")
                return false
            }
            if settings.ssl.useAdvancedOptions && !settings.ssl.crlFile.isEmpty && !exists(settings.ssl.crlFile) {
                Alerts.error("Error", "Error: CRL (Revocation List) file does not exist")
                return false
            }
        }
        return true
    }

    // MARK: State

    @objc private func typeChanged() {
        let type = ConnectionType(rawValue: typePopup.indexOfSelectedItem) ?? .direct
        let replica = type == .replicaSet
        connectionGrid.row(at: 3).isHidden = replica
        connectionGrid.row(at: 4).isHidden = replica
        connectionGrid.row(at: 5).isHidden = !replica
        connectionGrid.row(at: 6).isHidden = !replica
        portContainer.arrangedSubviews[1].isHidden = type == .srv
        portField.isHidden = type == .srv
        addressInfo.stringValue = type == .srv
            ? "Specify the DNS seedlist host name, e.g. cluster0.abcde.mongodb.net. TLS is enabled by default for SRV connections."
            : "Specify host and port of MongoDB server. Host can be either IPv4, IPv6 or domain name."
        useSSH.isEnabled = type == .direct
        useSSH.toolTip = type == .direct ? nil : "SSH is currently only supported for direct connections"
        updateSSHState()
    }

    @objc private func updateAuthState() {
        let on = useAuth.state == .on
        for view in [authDbField, userField, mechanismPopup, useManualDbs, manualDbsField] as [NSControl] {
            view.isEnabled = on
        }
        passwordField.isEnabled = on
        let manual = useManualDbs.state == .on
        authGrid.row(at: 8).isHidden = !manual
        authGrid.row(at: 9).isHidden = !manual
    }

    @objc private func updateSSHState() {
        let on = useSSH.state == .on && useSSH.isEnabled
        let key = sshMethodPopup.indexOfSelectedItem == 1
        let ask = sshAsk.state == .on
        sshGrid.row(at: 4).isHidden = key
        sshGrid.row(at: 5).isHidden = !key
        sshGrid.row(at: 6).isHidden = !key
        sshAsk.title = key ? "Ask for passphrase each time" : "Ask for password each time"
        for control in [sshHostField, sshPortField, sshUserField, sshMethodPopup, sshKeyField, sshAsk] as [NSControl] { control.isEnabled = on }
        sshPasswordField.isEnabled = on && !ask
        sshPassphraseField.isEnabled = on && !ask
    }

    @objc private func updateTLSState() {
        let on = useTLS.state == .on
        let ca = tlsMethodPopup.indexOfSelectedItem == 1
        let pem = usePem.state == .on
        let advanced = tlsAdvanced.state == .on
        tlsGrid.row(at: 2).isHidden = ca
        tlsGrid.row(at: 3).isHidden = !ca
        tlsGrid.cell(atColumnIndex: 1, rowIndex: 4).contentView?.isHidden = pem
        for row in 5...7 { tlsGrid.row(at: row).isHidden = !pem }
        for row in 9...10 { tlsGrid.row(at: row).isHidden = !advanced }
        for control in [tlsMethodPopup, caField, usePem, pemField, pemAsk, tlsAdvanced, crlField, invalidHostnamesPopup] as [NSControl] {
            control.isEnabled = on
        }
        pemPassField.isEnabled = on && pemAsk.state != .on
        if pemAsk.state == .on { pemPassField.stringValue = "" }
    }

    // MARK: Actions

    @objc private func test() {
        guard validate(), let secrets = Alerts.askEachTimeSecrets(for: settings, secrets) else { return }
        DiagnosticWindow(settings: settings, secrets: secrets).run()
    }

    @objc private func membersPlusMinus(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 {
            if let last = members.last.flatMap(ConnectionSettings.splitHostPort) {
                members.append("\(last.host):\(last.port + 1)")
            } else {
                members.append("localhost:\(27017 + members.count)")
            }
        } else if !members.isEmpty {
            let row = membersTable.selectedRow
            members.remove(at: row >= 0 ? row : members.count - 1)
        }
        membersTable.reloadData()
    }

    private func browse(_ field: NSTextField, directory: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        let current = (field.stringValue as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: current.isEmpty ? (directory ?? NSHomeDirectory()) : (current as NSString).deletingLastPathComponent)
        if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
    }

    @objc private func browseSSHKey() { browse(sshKeyField, directory: NSHomeDirectory() + "/.ssh") }
    @objc private func browseCA() { browse(caField) }
    @objc private func browsePEM() { browse(pemField) }
    @objc private func browseCRL() { browse(crlField) }

    @objc private func fromURI() {
        let uriString = uriField.stringValue.replacingOccurrences(of: " ", with: "")
        var error = bson_error_t()
        guard let uri = mongoc_uri_new_with_error(uriString, &error) else {
            Alerts.error("Error", "MongoDB URI:\n" + MongoError(error).message)
            return
        }
        defer { mongoc_uri_destroy(uri) }
        let string: (UnsafePointer<CChar>?) -> String = { $0.map { String(cString: $0) } ?? "" }

        var hosts: [String] = []
        var host = mongoc_uri_get_hosts(uri)
        while let current = host {
            var name = withUnsafeBytes(of: current.pointee.host) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if name.hasSuffix(".") { name.removeLast() }
            hosts.append("\(name):\(current.pointee.port)")
            host = UnsafePointer(current.pointee.next)
        }
        let srv = string(mongoc_uri_get_srv_hostname(uri))
        let replicaSet = string(mongoc_uri_get_replica_set(uri))
        if !srv.isEmpty {
            typePopup.selectItem(at: ConnectionType.srv.rawValue)
            hostField.stringValue = srv
        } else if !replicaSet.isEmpty || hosts.count > 1 {
            typePopup.selectItem(at: ConnectionType.replicaSet.rawValue)
            members = hosts
            setNameField.stringValue = replicaSet
            membersTable.reloadData()
        } else if let first = hosts.first.flatMap(ConnectionSettings.splitHostPort) {
            typePopup.selectItem(at: ConnectionType.direct.rawValue)
            hostField.stringValue = first.host
            portField.stringValue = String(first.port)
        }

        let user = string(mongoc_uri_get_username(uri))
        useAuth.state = user.isEmpty ? .off : .on
        userField.stringValue = user
        passwordField.stringValue = string(mongoc_uri_get_password(uri))
        let authSource = string(mongoc_uri_get_auth_source(uri))
        authDbField.stringValue = authSource.isEmpty ? (user.isEmpty ? "" : "admin") : authSource
        let mechanism = string(mongoc_uri_get_auth_mechanism(uri))
        if !mechanism.isEmpty { mechanismPopup.selectItem(withTitle: mechanism) }

        let tls = mongoc_uri_get_tls(uri)
        useTLS.state = tls ? .on : .off
        if tls {
            let insecure = mongoc_uri_get_option_as_bool(uri, MONGOC_URI_TLSALLOWINVALIDCERTIFICATES, false)
                || mongoc_uri_get_option_as_bool(uri, MONGOC_URI_TLSINSECURE, false)
            tlsMethodPopup.selectItem(at: insecure ? 0 : 1)
            caField.stringValue = string(mongoc_uri_get_option_as_utf8(uri, MONGOC_URI_TLSCAFILE, nil))
            let pem = string(mongoc_uri_get_option_as_utf8(uri, MONGOC_URI_TLSCERTIFICATEKEYFILE, nil))
            usePem.state = pem.isEmpty ? .off : .on
            pemField.stringValue = pem
            pemPassField.stringValue = string(mongoc_uri_get_option_as_utf8(uri, MONGOC_URI_TLSCERTIFICATEKEYFILEPASSWORD, nil))
            let invalidHosts = mongoc_uri_get_option_as_bool(uri, MONGOC_URI_TLSALLOWINVALIDHOSTNAMES, false)
            tlsAdvanced.state = invalidHosts ? .on : .off
            invalidHostnamesPopup.selectItem(at: invalidHosts ? 1 : 0)
        }
        defaultDbField.stringValue = string(mongoc_uri_get_database(uri))
        typeChanged()
        updateAuthState()
        updateTLSState()
    }

    // MARK: Members table

    func numberOfRows(in tableView: NSTableView) -> Int { members.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(string: members[row])
        field.isBordered = false
        field.drawsBackground = false
        field.tag = row
        field.target = self
        field.action = #selector(memberEdited(_:))
        return field
    }

    @objc private func memberEdited(_ sender: NSTextField) {
        guard sender.tag < members.count else { return }
        var value = sender.stringValue.replacingOccurrences(of: " ", with: "")
        if value.isEmpty {
            members.remove(at: sender.tag)
        } else {
            if !value.contains(":") { value += ":27017" }
            members[sender.tag] = value
        }
        membersTable.reloadData()
    }
}

/// Password field with Robo's show/hide eye button.
final class SecretField: NSStackView {
    private let secure = NSSecureTextField()
    private let plain = NSTextField()
    private let toggle: NSButton

    init() {
        toggle = NSButton(image: Theme.icon("hide_64x64.png", size: 16), target: nil, action: nil)
        super.init(frame: .zero)
        spacing = 6
        toggle.target = self
        toggle.action = #selector(toggleVisibility)
        toggle.widthAnchor.constraint(equalToConstant: 50).isActive = true
        plain.isHidden = true
        addArrangedSubview(secure)
        addArrangedSubview(plain)
        addArrangedSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { secure.isHidden ? plain.stringValue : secure.stringValue }
        set { secure.stringValue = newValue; plain.stringValue = newValue }
    }

    var isEnabled: Bool {
        get { secure.isEnabled }
        set { secure.isEnabled = newValue; plain.isEnabled = newValue; toggle.isEnabled = newValue }
    }

    @objc private func toggleVisibility() {
        let showing = !plain.isHidden
        if showing { secure.stringValue = plain.stringValue } else { plain.stringValue = secure.stringValue }
        plain.isHidden = showing
        secure.isHidden = !showing
        toggle.image = Theme.icon(showing ? "hide_64x64.png" : "show_64x64.png", size: 16)
    }
}
