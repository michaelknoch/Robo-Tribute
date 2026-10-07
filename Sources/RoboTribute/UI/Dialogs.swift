import AppKit

/// Base for Robo's small modal dialogs: content above, buttons bottom-right.
class ModalDialog: NSObject, NSWindowDelegate {
    let window: NSWindow
    private(set) var accepted = false

    init(title: String, size: NSSize, resizable: Bool = false) {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
    }

    func runModal() -> Bool {
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return accepted
    }

    @objc func accept() {
        guard validate() else { return }
        accepted = true
        NSApp.stopModal()
    }

    @objc func reject() {
        accepted = false
        NSApp.stopModal()
    }

    func validate() -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        reject()
        return false
    }

    /// Server, database and collection indicators shown at the top of Robo's dialogs.
    static func indicatorRow(server: String, database: String?, collection: String?) -> NSStackView {
        var views: [NSView] = [IndicatorView(icon: Theme.server, text: server)]
        if let database { views.append(IndicatorView(icon: Theme.database, text: database)) }
        if let collection { views.append(IndicatorView(icon: Theme.collection, text: collection)) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 0
        row.setHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }

    func buttonRow(okTitle: String, okImage: NSImage? = nil, leading: [NSView] = []) -> NSStackView {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(reject))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: okTitle, target: self, action: #selector(accept))
        ok.keyEquivalent = "\r"
        if let okImage {
            ok.image = okImage
            ok.imagePosition = .imageLeading
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: leading + [spacer, cancel, ok])
        row.orientation = .horizontal
        return row
    }
}

/// CreateDatabaseDialog.cpp, also used for rename/duplicate collection.
final class InputDialog: ModalDialog {
    private let field = NSTextField()

    init(title: String, server: String, database: String?, collection: String?, label: String, value: String, okTitle: String) {
        super.init(title: title, size: NSSize(width: 360, height: 150))
        let indicatorRow = Self.indicatorRow(server: server, database: database, collection: collection)
        field.stringValue = value
        let labelView = NSTextField(labelWithString: label)
        let stack = NSStackView(views: [indicatorRow, horizontalLine(), labelView, field, buttonRow(okTitle: okTitle)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in stack.arrangedSubviews where view !== indicatorRow && view !== labelView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
        window.initialFirstResponder = field
    }

    func run() -> String? {
        runModal() ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }
}

/// DocumentTextEditor.cpp: view, edit or insert a document as shell JSON.
final class DocumentEditorWindow: ModalDialog {
    struct Info {
        var server: String
        var db: String
        var collection: String
    }

    private static var open: [DocumentEditorWindow] = []
    private let editor = CodeEditor(wrap: true, editable: true)
    private let readOnly: Bool
    private var original: String
    private(set) var documents: [BSONDocument] = []

    init(title: String, info: Info?, json: String, readOnly: Bool, cursor: Int? = nil) {
        self.readOnly = readOnly
        original = json
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        super.init(title: title, size: NSSize(width: max(800, screen.width * 0.65), height: max(400, screen.height * 0.8)), resizable: true)
        window.minSize = NSSize(width: 800, height: 400)
        window.setFrameAutosaveName("DocumentTextEditor")
        window.styleMask.insert(.miniaturizable)

        var rows: [NSView] = []
        if let info {
            rows.append(Self.indicatorRow(server: info.server, database: info.db, collection: info.collection))
        }
        editor.setStringHighlightingInBackground(json)
        editor.isEditable = !readOnly
        rows.append(editor)

        let validate = NSButton(title: "Validate", target: self, action: #selector(validateClicked))
        validate.image = Theme.info
        validate.imagePosition = .imageLeading
        let buttons = buttonRow(okTitle: "Save", leading: readOnly ? [] : [validate])
        if readOnly {
            buttons.arrangedSubviews.last?.isHidden = true
            (buttons.arrangedSubviews[buttons.arrangedSubviews.count - 2] as? NSButton)?.title = "Close"
        }
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 14, right: 20)
        editor.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        editor.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        window.initialFirstResponder = editor.textView
        if let cursor { editor.textView.setSelectedRange(NSRange(location: cursor, length: 0)) }
    }

    /// Returns the parsed documents when saved, nil when cancelled.
    func runModal() -> [BSONDocument]? {
        super.runModal() ? documents : nil
    }

    func show() {
        Self.open.append(self)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard NSApp.modalWindow === window else { return true }
        reject()
        return false
    }

    override func reject() {
        if !readOnly && editor.string != original {
            let alert = NSAlert()
            alert.messageText = "Robo Tribute"
            alert.informativeText = "The document has been modified.\nDo you want to save your changes?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return accept()
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        if NSApp.modalWindow === window {
            super.reject()
        } else {
            window.close()
        }
    }

    override func validate() -> Bool {
        parse(silent: true)
    }

    @objc private func validateClicked() {
        _ = parse(silent: false)
    }

    private func parse(silent: Bool) -> Bool {
        let text = editor.string
        do {
            documents = try ShellJSONParser.parseDocuments(text)
        } catch let error as ShellJSONParser.ParseError {
            let (line, column) = ShellJSONParser.lineAndColumn(in: text, offset: error.offset)
            let prefix = String(decoding: Array(text.utf8.prefix(error.offset)), as: UTF8.self)
            editor.textView.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
            editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
            Alerts.error("Parsing error", "Unable to parse JSON:\n\(error.message), at (\(line + 1), \(column + 1)).")
            window.makeFirstResponder(editor.textView)
            return false
        } catch {
            Alerts.error("Parsing error", error.localizedDescription)
            return false
        }
        if !silent {
            Alerts.info("Validation", "JSON is valid!")
            window.makeFirstResponder(editor.textView)
        }
        return true
    }
}

enum ShellTimeoutDialog {
    static func run() {
        let current = AppSettings.shared.shellTimeoutSec
        guard let text = Alerts.ask("Robo Tribute", "Enter new value for Robo Tribute shell timeout in seconds:\n\nCurrent Value: \(current)",
                                    initial: String(current), formatter: DigitsFormatter()),
              let value = Int(text), value > 0 else { return }
        let old = AppSettings.shared.shellTimeoutSec
        AppSettings.shared.shellTimeoutSec = value
        AppSettings.shared.save()
        Log.info("Shell timeout value changed from \(old) to \(value) \(value > 1 ? "seconds." : "second.")")
    }
}

/// ConnectionDiagnosticDialog.cpp: step-by-step connection test.
final class DiagnosticWindow: ModalDialog {
    private final class Step {
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
    }

    private let settings: ConnectionSettings
    private let secrets: ConnectionSecrets
    private let ssh: Step?
    private let connection = Step()
    private let auth: Step?
    private let databases = Step()
    private let errorLink = NSButton(title: "Show error details", target: nil, action: nil)
    private var lastError = ""

    init(settings: ConnectionSettings, secrets: ConnectionSecrets) {
        self.settings = settings
        self.secrets = secrets
        ssh = settings.usesSSHTunnel ? Step() : nil
        auth = settings.hasEnabledCredential ? Step() : nil
        super.init(title: "Diagnostic", size: NSSize(width: 520, height: 180))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        for step in [ssh, connection, auth, databases].compactMap({ $0 }) {
            step.icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            step.icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let row = NSStackView(views: [step.icon, step.label])
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        errorLink.isBordered = false
        errorLink.contentTintColor = .secondaryLabelColor
        errorLink.target = self
        errorLink.action = #selector(showError)
        errorLink.isHidden = true
        let bottom = buttonRow(okTitle: "Close", leading: [errorLink])
        bottom.arrangedSubviews[bottom.arrangedSubviews.count - 2].isHidden = true
        stack.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        window.contentView = stack
    }

    @objc private func showError() {
        Alerts.info("Error details", lastError)
    }

    /// `text` marks bold parts with **, like the <b> tags in Robo's labels.
    private func set(_ step: Step?, _ state: Bool?, _ text: String) {
        guard let step else { return }
        step.icon.image = Theme.icon(state.map { $0 ? "yes_mark_24x24.png" : "no_mark_24x24.png" } ?? "question_mark_24x24.png", size: 20)
        let attributed = NSMutableAttributedString()
        for (i, part) in text.components(separatedBy: "**").enumerated() {
            attributed.append(NSAttributedString(string: part, attributes: [.font: i % 2 == 1 ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)]))
        }
        step.label.attributedStringValue = attributed
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        errorLink.isHidden = false
    }

    func run() {
        let address = settings.fullAddress
        let sshServer = "**\(settings.ssh.host):\(settings.ssh.port)**"
        let tunnelNote = settings.usesSSHTunnel ? " via SSH tunnel" : (settings.ssl.sslEnabled ? " via TLS tunnel" : "")
        let authTarget = "**\(settings.credential.databaseName)** database as **\(settings.credential.userName)**"
        set(ssh, nil, "Connecting to SSH server at \(sshServer)...")
        set(connection, nil, "Connecting to **\(address)**\(tunnelNote)...")
        set(auth, nil, "Authorizing on \(authTarget)...")
        set(databases, nil, "Loading list of databases...")

        var unauthenticated = settings
        unauthenticated.credential.enabled = false
        let timeout = AppSettings.shared.mongoTimeoutSec
        Task {
            let reachable = await Result.capture { try await MongoConnection.open(settings: unauthenticated, secrets: secrets, timeoutSeconds: timeout) }
            var authorized: Result<MongoConnection, Error>?
            var listed: Result<[String], Error>?
            if case .success(let probe) = reachable {
                probe.close()
                authorized = await Result.capture { try await MongoConnection.open(settings: settings, secrets: secrets, timeoutSeconds: timeout) }
                if case .success(let connection)? = authorized {
                    listed = await Result.capture { try await connection.run { try $0.listDatabases() } }
                    connection.close()
                }
            }
            switch reachable {
            case .failure(let error as SSHTunnelError):
                set(ssh, false, "Unable to connect to SSH server at \(sshServer)")
                set(connection, false, "No chance to try connection to **\(address)**\(tunnelNote)")
                fail(error)
            case .failure(let error):
                set(ssh, true, "Connected to SSH server at \(sshServer)")
                set(connection, false, "Failed to connect to **\(address)**\(tunnelNote)")
                fail(error)
            case .success:
                set(ssh, true, "Connected to SSH server at \(sshServer)")
                set(connection, true, "Connected to **\(address)**\(tunnelNote)")
            }
            switch authorized {
            case nil: set(auth, false, "No chance to authorize")
            case .failure(let error)?:
                set(auth, false, "Authorization failed on \(authTarget)")
                fail(error)
            default: set(auth, true, "Authorized on \(authTarget)")
            }
            switch listed {
            case nil: set(databases, false, "No chance to load list of databases")
            case .failure(let error)?:
                set(databases, false, "Failed to load list of databases")
                fail(error)
            default: set(databases, true, "Access to databases is available")
            }
        }
        _ = runModal()
    }
}
