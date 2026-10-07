import AppKit

/// Logs dock (LogWidget.cpp).
final class LogPanel: NSView {
    private var lastSequence = 0
    private let textView = NSTextView()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isRichText = true
        textView.font = .systemFont(ofSize: 12)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.menu = makeMenu()
        scroll.documentView = textView
        addSubview(scroll)
        scroll.pin(to: self)
        Log.entries.forEach(append)
        NotificationCenter.default.addObserver(self, selector: #selector(didLog(_:)), name: Log.didLog, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Clear All") { [weak self] in self?.textView.string = "" })
        return menu
    }

    @objc private func didLog(_ notification: Notification) {
        guard let entry = notification.userInfo?["entry"] as? Log.Entry else { return }
        append(entry)
    }

    private func append(_ entry: Log.Entry) {
        // Entries logged before this panel existed arrive both in the snapshot and as queued notifications.
        guard entry.sequence > lastSequence else { return }
        lastSequence = entry.sequence
        let color: NSColor
        switch entry.level {
        case .error: color = NSColor(srgbRed: 0xCD / 255, green: 0, blue: 0, alpha: 1)
        case .log: color = NSColor(srgbRed: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255, alpha: 1)
        case .warning: color = NSColor(srgbRed: 0xCD / 255, green: 0x98 / 255, blue: 0, alpha: 1)
        case .info: color = .labelColor
        }
        let font = NSFont.systemFont(ofSize: 12)
        var message = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > 500 { message = "(truncated) " + message.prefix(500) + "..." }
        let line = NSMutableAttributedString(string: formatter.string(from: entry.date) + "\t",
                                             attributes: [.foregroundColor: NSColor(srgbRed: 0xAA / 255, green: 0xAA / 255, blue: 0xAA / 255, alpha: 1), .font: font])
        line.append(NSAttributedString(string: message + "\n", attributes: [.foregroundColor: color, .font: font]))
        guard let storage = textView.textStorage else { return }
        storage.append(line)
        if storage.length > 1_000_000 {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length / 2))
        }
        textView.scrollToEndOfDocument(nil)
    }
}
