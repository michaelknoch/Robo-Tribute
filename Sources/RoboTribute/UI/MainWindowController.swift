import AppKit

/// Toolbar under the title bar, drawn like Robo 3T's Qt toolbars (MainWindow.cpp).
final class ToolbarStrip: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(starting: NSColor(srgbRed: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255, alpha: 1),
                                  ending: NSColor(srgbRed: 0xDC / 255, green: 0xDC / 255, blue: 0xDC / 255, alpha: 1))
        gradient?.draw(in: bounds, angle: 90)
        NSColor(srgbRed: 0xB5 / 255, green: 0xB5 / 255, blue: 0xB5 / 255, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    static func button(_ image: NSImage, toolTip: String, action: Selector) -> NSButton {
        FlatButton(image: image, size: 30, height: 28, toolTip: toolTip, target: nil, action: action)
    }
}

final class MainWindowController: NSWindowController, NSMenuItemValidation, ExplorerDelegate, WorkAreaDelegate {
    let explorer = ExplorerController()
    let workArea = WorkAreaController()
    private let logPanel = LogPanel()
    private let mainSplit = NSSplitView()
    private let rightSplit = NSSplitView()
    private let logsButton = NSButton(title: "Logs", target: nil, action: #selector(toggleLogs(_:)))
    private var sessions: [ServerSession] = []
    private var executeButton: NSButton!
    private var stopButton: NSButton!
    private var rotateButton: NSButton!
    private var openButton: NSButton!
    private var saveButton: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Robo Tribute - \(AppInfo.version)"
        window.minSize = NSSize(width: 700, height: 400)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
        window.setFrameAutosaveName("MainWindow")
        updateToolbar()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        let key = "ExplorerWidthInitialized"
        if !UserDefaults.standard.bool(forKey: key) {
            window?.contentView?.layoutSubtreeIfNeeded()
            mainSplit.setPosition(340, ofDividerAt: 0)
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private func buildContent() {
        guard let window else { return }
        let root = NSView()

        let toolbar = ToolbarStrip()
        let connect = ToolbarStrip.button(Theme.icon("connect_24x24.png", size: 20),
                                          toolTip: "Connect to local or remote MongoDB instance (⌘N)", action: #selector(manageConnections(_:)))
        openButton = ToolbarStrip.button(Theme.icon("qt_open_32.png", size: 20), toolTip: "Load script from the file to the currently opened shell (⌘O)", action: #selector(openScript(_:)))
        saveButton = ToolbarStrip.button(Theme.icon("qt_save_32.png", size: 20), toolTip: "Save script of the currently opened shell to the file (⌘S)", action: #selector(saveScript(_:)))
        executeButton = ToolbarStrip.button(Theme.icon("execute_24x24.png", size: 20),
                                            toolTip: "Execute query for current tab. If you have some selection in query text - only selection will be executed (F5 or ⌘↩)",
                                            action: #selector(executeScript(_:)))
        stopButton = ToolbarStrip.button(Theme.icon("stop_24x24.png", size: 20), toolTip: "Stop execution of currently running script. (F6)", action: #selector(stopScript(_:)))
        rotateButton = ToolbarStrip.button(Theme.icon("rotate_16x16.png", size: 20), toolTip: "Rotate (F10)", action: #selector(rotate(_:)))
        let buttons = NSStackView(views: [connect, openButton, saveButton, executeButton, stopButton, rotateButton])
        buttons.spacing = 3
        buttons.setCustomSpacing(10, after: connect)
        buttons.setCustomSpacing(10, after: saveButton)
        toolbar.addSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
            buttons.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        explorer.delegate = self
        workArea.delegate = self
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.autosaveName = "MainSplit"
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        rightSplit.autosaveName = "RightSplit"
        rightSplit.addArrangedSubview(workArea.view)
        rightSplit.addArrangedSubview(logPanel)
        for view in [workArea.view, logPanel, explorer.view, rightSplit] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        mainSplit.addArrangedSubview(explorer.view)
        mainSplit.addArrangedSubview(rightSplit)
        mainSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        rightSplit.setHoldingPriority(.init(240), forSubviewAt: 0)
        rightSplit.setHoldingPriority(.init(260), forSubviewAt: 1)
        explorer.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        logPanel.isHidden = true

        let status = ColorView(color: .windowBackgroundColor)
        logsButton.bezelStyle = .rounded
        logsButton.controlSize = .small
        logsButton.setButtonType(.pushOnPushOff)
        logsButton.target = self
        status.addSubview(logsButton)
        logsButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logsButton.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 2),
            logsButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])

        for view in [toolbar, mainSplit, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),
            mainSplit.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
        ])
        window.contentView = root
    }

    // MARK: Toolbar state

    private func updateToolbar() {
        let tab = workArea.current
        let running = tab?.isRunning ?? false
        executeButton.isEnabled = tab != nil && !running
        stopButton.isEnabled = running
        rotateButton.isEnabled = tab != nil
        openButton.isEnabled = tab != nil
        saveButton.isEnabled = tab != nil
    }

    func workAreaDidChangeSelection() {
        updateToolbar()
    }

    func workAreaOpenShell(from tab: QueryTabController, script: String, execute: Bool) {
        openShell(session: tab.session, database: tab.databaseName, script: script, execute: execute, cursorFromEnd: 0)
    }

    // MARK: Connections

    @objc func manageConnections(_ sender: Any?) {
        guard let window else { return }
        let dialog = ConnectionsWindow()
        dialog.beginSheet(for: window) { accepted in
            if accepted, let settings = dialog.selected { self.connect(settings) }
        }
    }

    func connect(_ settings: ConnectionSettings) {
        var secrets = Keychain.secrets(for: settings.id)
        if settings.hasEnabledCredential && secrets.password.isEmpty {
            guard let password = Alerts.askSecret("Authentication",
                                                  "Enter password for \(settings.credential.userName) on database \(settings.credential.databaseName) (\(settings.readableName)).\nIt will be stored in your Keychain.") else { return }
            secrets.password = password
            Keychain.store(secrets, for: settings.id)
        }
        guard let completed = Alerts.askEachTimeSecrets(for: settings, secrets) else { return }
        secrets = completed
        explorer.setConnecting(true)
        Log.info("Connecting to \(settings.fullAddress)...")
        let timeout = AppSettings.shared.mongoTimeoutSec
        Task {
            let result = await Result.capture { try await MongoConnection.open(settings: settings, secrets: secrets, timeoutSeconds: timeout) }
            explorer.setConnecting(false)
            switch result {
            case .success(let connection):
                let session = ServerSession(settings: settings, connection: connection)
                sessions.append(session)
                explorer.addServer(session)
            case .failure(let error):
                Log.error("Cannot connect to the MongoDB at \(settings.fullAddress): \(error.localizedDescription)")
                Alerts.error("Error", "Cannot connect to the MongoDB at \(settings.fullAddress).\n\nError:\n\(error.localizedDescription)")
            }
        }
    }

    // MARK: ExplorerDelegate

    func explorerOpenShell(session: ServerSession, database: String?, script: String, execute: Bool, cursorFromEnd: Int) {
        openShell(session: session, database: database, script: script, execute: execute, cursorFromEnd: cursorFromEnd)
    }

    /// Only grows, so a width the user chose is kept.
    func explorerNeedsWidth(_ width: CGFloat) {
        let target = min(width, max(mainSplit.bounds.width * 0.4, 340))
        guard target > explorer.view.frame.width else { return }
        mainSplit.setPosition(target, ofDividerAt: 0)
    }

    func explorerDisconnect(_ session: ServerSession) {
        workArea.closeTabs(of: session)
        explorer.removeServer(session)
        sessions.removeAll { $0 === session }
        session.connection.close()
        Log.info("Disconnected from \(session.settings.fullAddress)")
    }

    func explorerInsertDocument(session: ServerSession, database: String, collection: String) {
        session.insertDocuments(db: database, collection: collection)
    }

    private func openShell(session: ServerSession, database: String?, script: String, execute: Bool, cursorFromEnd: Int) {
        let settings = session.settings
        let db = database ?? (settings.defaultDatabase.isEmpty
            ? (settings.hasEnabledCredential ? settings.credential.databaseName : "test")
            : settings.defaultDatabase)
        let tab = QueryTabController(session: session, database: db, script: script)
        tab.onRunningChange = { [weak self] in self?.updateToolbar() }
        workArea.add(tab)
        tab.placeCursor(fromEnd: cursorFromEnd)
        if execute && !script.isEmpty { tab.execute() }
        updateToolbar()
    }

    // MARK: Actions

    @objc func executeScript(_ sender: Any?) { workArea.current?.execute() }
    @objc func stopScript(_ sender: Any?) { workArea.current?.stop() }
    @objc func rotate(_ sender: Any?) { workArea.current?.toggleOrientation() }
    @objc func openScript(_ sender: Any?) { workArea.current?.open() }
    @objc func saveScript(_ sender: Any?) { workArea.current?.save() }
    @objc func saveScriptAs(_ sender: Any?) { workArea.current?.saveAs() }
    @objc func nextTab(_ sender: Any?) { workArea.next() }
    @objc func previousTab(_ sender: Any?) { workArea.previous() }
    @objc func reexecute(_ sender: Any?) { workArea.current?.execute() }

    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = workArea.current else { return }
        workAreaOpenShell(from: tab, script: tab.scriptText, execute: true)
    }

    @objc func newShell(_ sender: Any?) {
        guard let tab = workArea.current else { return }
        workAreaOpenShell(from: tab, script: tab.selectedText, execute: AppSettings.shared.autoExec && !tab.selectedText.isEmpty)
    }

    @objc func closeShell(_ sender: Any?) {
        if workArea.selectedIndex >= 0 { workArea.close(workArea.selectedIndex) } else { window?.performClose(sender) }
    }

    @objc func toggleExplorer(_ sender: Any?) {
        explorer.view.isHidden.toggle()
        mainSplit.adjustSubviews()
    }

    @objc func toggleLogs(_ sender: Any?) {
        logPanel.isHidden.toggle()
        logsButton.state = logPanel.isHidden ? .off : .on
        rightSplit.adjustSubviews()
        if !logPanel.isHidden {
            rightSplit.layoutSubtreeIfNeeded()
            rightSplit.setPosition(max(rightSplit.bounds.height - 180, rightSplit.bounds.height / 2), ofDividerAt: 0)
        }
    }

    func setViewMode(_ mode: ViewMode) {
        AppSettings.shared.viewMode = mode
        AppSettings.shared.save()
        workArea.current?.setViewMode(mode)
    }

    @objc func setViewModeFromMenu(_ sender: NSMenuItem) {
        setViewMode(ViewMode(rawValue: sender.tag) ?? .tree)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleExplorer(_:)):
            menuItem.state = explorer.view.isHidden ? .off : .on
        case #selector(toggleLogs(_:)):
            menuItem.state = logPanel.isHidden ? .off : .on
        case #selector(setViewModeFromMenu(_:)):
            menuItem.state = AppSettings.shared.viewMode.rawValue == menuItem.tag ? .on : .off
        case #selector(executeScript(_:)), #selector(reexecute(_:)):
            return workArea.current.map { !$0.isRunning } ?? false
        case #selector(stopScript(_:)):
            return workArea.current?.isRunning ?? false
        case #selector(openScript(_:)), #selector(saveScript(_:)), #selector(saveScriptAs(_:)), #selector(rotate(_:)),
             #selector(duplicateTab(_:)), #selector(newShell(_:)), #selector(nextTab(_:)), #selector(previousTab(_:)):
            return workArea.current != nil
        default:
            break
        }
        return true
    }

    func closeAllSessions() {
        sessions.forEach { $0.connection.close() }
        sessions = []
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
