import AppKit
import UniformTypeIdentifiers

/// A query tab: connection status line, script editor and results (QueryWidget.cpp + ScriptWidget.cpp).
final class QueryTabController: NSViewController, OutputItemHost, NSWindowDelegate {
    let session: ServerSession
    let shell: MongoShell
    let editor = CodeEditor(wrap: false, editable: true)
    let output = OutputView()
    var onTitleChange: (() -> Void)?
    var onRunningChange: (() -> Void)?

    private let connectionIndicator: IndicatorView
    private let serverIndicator: IndicatorView
    private let databaseIndicator: IndicatorView
    private let outputLabel = NSTextField(labelWithString: "")
    private let outputContainer = NSView()
    private let scriptArea = ColorView(color: .white)
    private var editorHeight: NSLayoutConstraint!
    private var outputConstraints: [NSLayoutConstraint] = []
    private var undockedWindow: NSWindow?
    private var lastExecuted = ""
    private var textChanged = false
    private(set) var filePath: URL?
    private(set) var databaseName: String
    private(set) var isRunning = false {
        didSet { onRunningChange?() }
    }

    init(session: ServerSession, database: String, script: String) {
        self.session = session
        databaseName = database.isEmpty ? "test" : database
        shell = MongoShell(connection: session.connection, databaseName: databaseName)
        let gray = Theme.indicatorText
        connectionIndicator = IndicatorView(icon: Theme.icon("connect_24x24.png", size: 16), text: session.settings.readableName, color: gray)
        serverIndicator = IndicatorView(icon: Theme.server, text: session.connection.address, color: gray)
        databaseIndicator = IndicatorView(icon: Theme.database, text: databaseName, color: gray)
        super.init(nibName: nil, bundle: nil)
        editor.string = script
        lastExecuted = script
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ColorView(color: Theme.queryBackground)

        let statusBar = NSStackView(views: [connectionIndicator, serverIndicator, databaseIndicator])
        statusBar.orientation = .horizontal
        statusBar.spacing = 0
        statusBar.edgeInsets = NSEdgeInsets(top: 3, left: 2, bottom: 3, right: 2)

        scriptArea.addSubview(statusBar)
        scriptArea.addSubview(editor)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        editorHeight = editor.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: scriptArea.leadingAnchor, constant: 5),
            statusBar.trailingAnchor.constraint(lessThanOrEqualTo: scriptArea.trailingAnchor, constant: -5),
            statusBar.topAnchor.constraint(equalTo: scriptArea.topAnchor, constant: 1),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
            editor.leadingAnchor.constraint(equalTo: scriptArea.leadingAnchor, constant: 5),
            editor.trailingAnchor.constraint(equalTo: scriptArea.trailingAnchor, constant: -5),
            editor.topAnchor.constraint(equalTo: statusBar.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: scriptArea.bottomAnchor, constant: -5),
            editorHeight,
        ])

        outputLabel.stringValue = "  Script executed successfully, but there are no results to show."
        outputLabel.isHidden = true
        outputLabel.textColor = .secondaryLabelColor

        let line = horizontalLine()
        for view in [scriptArea, line, outputContainer, outputLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scriptArea.topAnchor.constraint(equalTo: root.topAnchor),
            scriptArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scriptArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: scriptArea.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outputContainer.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 2),
            outputContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outputContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outputContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            outputLabel.topAnchor.constraint(equalTo: outputContainer.topAnchor, constant: 5),
            outputLabel.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor),
        ])

        outputContainer.addSubview(output)
        output.pin(to: outputContainer)

        editor.onTextChange = { [weak self] in
            guard let self else { return }
            self.updateEditorHeight()
            if !self.textChanged {
                self.textChanged = true
                self.onTitleChange?()
            }
        }
        view = root
        updateEditorHeight()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusEditor()
    }

    func focusEditor() {
        view.window?.makeFirstResponder(editor.textView)
    }

    func placeCursor(fromEnd offset: Int) {
        let length = (editor.string as NSString).length
        let location = max(0, length - offset)
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    private func updateEditorHeight() {
        guard undockedWindow == nil else { return }
        let lines = min(max(editor.lineCount, 1), 18)
        editorHeight.constant = CGFloat(lines) * editor.lineHeight + editor.textView.textContainerInset.height * 2 + 6
    }

    // MARK: Title

    var tabTitle: String {
        var title: String
        if let filePath {
            title = filePath.lastPathComponent
        } else if lastExecuted.isEmpty {
            title = "New Shell"
        } else {
            title = String(lastExecuted.prefix(41)).replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        }
        return textChanged ? "* " + title : title
    }

    var toolTip: String {
        let query = String(lastExecuted.prefix(700))
        if let filePath { return filePath.path + "\n\n" + query }
        return query
    }

    // MARK: Execution

    func execute() {
        guard !isRunning else { return }
        let selection = editor.textView.selectedRange()
        var script = selection.length > 0 ? (editor.string as NSString).substring(with: selection) : editor.string
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { script = editor.string }
        lastExecuted = editor.string
        onTitleChange?()
        isRunning = true
        showProgress()
        let timeout = AppSettings.shared.shellTimeoutSec
        let batchSize = AppSettings.shared.batchSize
        Task { [weak self, shell] in
            let result = await shell.execute(script, timeoutSeconds: timeout, batchSize: batchSize)
            self?.display(result, script: script)
        }
    }

    func stop() {
        shell.stop()
    }

    private func display(_ result: ShellExecResult, script: String) {
        isRunning = false
        hideProgress()
        databaseName = result.databaseName
        databaseIndicator.text = databaseName
        if result.results.isEmpty && result.error == nil && !result.timedOut {
            outputLabel.isHidden = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            output.clear()
        } else {
            outputLabel.isHidden = true
            output.present(result.results, host: self)
        }
        if let error = result.error {
            Log.error(error)
            let prefix = error.lowercased().hasPrefix("error") ? "" : "Error:\n"
            Alerts.error("Error", "Failed to execute script.\n\n" + prefix + error)
        }
        if result.timedOut {
            let seconds = AppSettings.shared.shellTimeoutSec
            let message = "Failed to execute all of the script. The script has reached shell timeout (\(seconds) second\(seconds == 1 ? "" : "s")) limit."
            Log.error(message)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Error"
            alert.informativeText = message + "\n\nPlease increase the value of shell timeout using button below or from the main window menu \"Options->Change Shell Timeout\"."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Change Shell Timeout")
            Alerts.present(alert) { if $0 == .alertSecondButtonReturn { ShellTimeoutDialog.run() } }
        }
        focusEditor()
    }

    func setViewMode(_ mode: ViewMode) { output.setMode(mode) }
    func toggleOrientation() { output.toggleOrientation() }

    // MARK: OutputItemHost

    var isOutputDocked: Bool { undockedWindow == nil }
    func showProgress() { output.showProgress() }
    func hideProgress() { output.hideProgress() }

    func toggleDock() {
        if let window = undockedWindow {
            window.close()
        } else {
            output.removeFromSuperview()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = tabTitle
            window.isReleasedWhenClosed = false
            let container = NSView()
            container.addSubview(output)
            output.pin(to: container)
            window.contentView = container
            window.center()
            window.delegate = self
            undockedWindow = window
            outputContainer.isHidden = true
            editorHeight.isActive = false
            window.makeKeyAndOrderFront(nil)
        }
        output.updateDockButtons(docked: isOutputDocked)
    }

    func closeUndockedWindow() {
        undockedWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === undockedWindow else { return }
        window.delegate = nil
        window.contentView = nil
        undockedWindow = nil
        outputContainer.isHidden = false
        outputContainer.addSubview(output)
        output.pin(to: outputContainer)
        editorHeight.isActive = true
        updateEditorHeight()
        output.updateDockButtons(docked: true)
    }

    // MARK: Files

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .javaScript, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        editor.string = text
        filePath = url
        textChanged = false
        updateEditorHeight()
        onTitleChange?()
    }

    func save() {
        guard let filePath else { return saveAs() }
        write(to: filePath)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .javaScript]
        panel.nameFieldStringValue = filePath?.lastPathComponent ?? "query.js"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try editor.string.write(to: url, atomically: true, encoding: .utf8)
            filePath = url
            textChanged = false
            onTitleChange?()
        } catch {
            Alerts.error("Error", "Unable to save file: \(error.localizedDescription)")
        }
    }

    var scriptText: String { editor.string }
    var selectedText: String {
        let range = editor.textView.selectedRange()
        return range.length > 0 ? (editor.string as NSString).substring(with: range) : ""
    }
}
