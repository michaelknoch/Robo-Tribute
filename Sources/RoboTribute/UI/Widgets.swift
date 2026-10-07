import AppKit

/// Icon followed by a label, as in Robo 3T's Indicator (IndicatorLabel.cpp).
final class IndicatorView: NSStackView {
    let imageView = NSImageView()
    let label = NSTextField(labelWithString: "")

    init(icon: NSImage, text: String = "", color: NSColor = .labelColor) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 7
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        label.font = .systemFont(ofSize: 13)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = text
        addArrangedSubview(imageView)
        addArrangedSubview(label)
        edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 14)
        setHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}

/// Flat 24x24 icon button (Qt's QPushButton::setFlat).
final class FlatButton: NSButton {
    convenience init(image: NSImage, size: CGFloat = 24, height: CGFloat? = nil, toolTip: String? = nil, target: AnyObject?, action: Selector?) {
        self.init(frame: NSRect(x: 0, y: 0, width: size, height: height ?? size))
        self.image = image
        self.target = target
        self.action = action
        self.toolTip = toolTip
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: height ?? size).isActive = true
    }
}

final class ColorView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

func verticalSeparator() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    box.widthAnchor.constraint(equalToConstant: 5).isActive = true
    box.heightAnchor.constraint(equalToConstant: 20).isActive = true
    return box
}

func horizontalLine() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    return box
}

extension NSView {
    func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

enum Alerts {
    static func error(_ title: String, _ message: String) {
        show(.critical, title, message)
    }

    static func info(_ title: String, _ message: String) {
        show(.informational, title, message)
    }

    /// A modal started inside a main-queue job holds back every main-actor task until it closes.
    static func runOutsideMainQueueJob(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform { MainActor.assumeIsolated(body) }
    }

    private static func show(_ style: NSAlert.Style, _ title: String, _ message: String) {
        runOutsideMainQueueJob {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    static func confirm(_ title: String, _ message: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        if destructive { alert.buttons[0].hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func ask(_ title: String, _ message: String, initial: String = "", secure: Bool = false, formatter: Formatter? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.formatter = formatter
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func askSecret(_ title: String, _ message: String) -> String? {
        ask(title, message, secure: true)
    }

    /// Prompts for the SSH and TLS secrets a connection is configured to ask for on every connect.
    static func askEachTimeSecrets(for settings: ConnectionSettings, _ secrets: ConnectionSecrets) -> ConnectionSecrets? {
        var secrets = secrets
        if settings.usesSSHTunnel && settings.ssh.askPassword {
            let isKey = settings.ssh.usesPublicKey
            guard let value = askSecret("SSH", "Enter SSH \(isKey ? "passphrase" : "password") for \(settings.ssh.userName)@\(settings.ssh.host)") else { return nil }
            if isKey { secrets.sshPassphrase = value } else { secrets.sshPassword = value }
        }
        if settings.ssl.sslEnabled && settings.ssl.usePemFile && settings.ssl.askPassphrase {
            guard let value = askSecret("TLS", "Enter passphrase for \(settings.ssl.pemKeyFile)") else { return nil }
            secrets.pemPassphrase = value
        }
        return secrets
    }
}
