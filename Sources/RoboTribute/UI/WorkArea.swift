import AppKit

/// Robo 3T's macOS tab strip (WorkAreaTabWidget.cpp): grey tabs, white selected tab, close button on the left.
final class TabBarView: NSView {
    struct Tab {
        var title: String
        var toolTip: String
    }

    var tabs: [Tab] = [] {
        didSet { rebuild() }
    }
    var selectedIndex = -1 {
        didSet { needsDisplay = true }
    }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onDoubleClickEmpty: (() -> Void)?
    var menuForTab: ((Int) -> NSMenu?)?

    private var closeButtons: [NSButton] = []
    private var frames: [NSRect] = []
    private var dragIndex: Int?
    private let font = NSFont.systemFont(ofSize: 11)
    static let height: CGFloat = 25

    override var isFlipped: Bool { true }

    private var background: NSColor {
        NSColor(srgbRed: 0xCF / 255, green: 0xCF / 255, blue: 0xCF / 255, alpha: 1)
    }

    private func rebuild() {
        if closeButtons.count != tabs.count {
            rebuildButtons()
        }
        layoutTabs()
        needsDisplay = true
    }

    private func rebuildButtons() {
        closeButtons.forEach { $0.removeFromSuperview() }
        closeButtons = tabs.indices.map { index in
            let button = NSButton(image: Theme.icon("close_2_Mac_16x16.png", size: 10), target: self, action: #selector(closeClicked(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = "Close Shell"
            addSubview(button)
            return button
        }
    }

    private func layoutTabs() {
        frames = []
        var x: CGFloat = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for (index, tab) in tabs.enumerated() {
            let textWidth = min((tab.title as NSString).size(withAttributes: attrs).width, 260)
            let width = ceil(textWidth) + 10 + 10 + 18
            let rect = NSRect(x: x, y: 0, width: width, height: Self.height)
            frames.append(rect)
            closeButtons[index].frame = NSRect(x: rect.minX + 7, y: (Self.height - 12) / 2, width: 12, height: 12)
            x += width
        }
        removeAllToolTips()
        for (index, rect) in frames.enumerated() where !tabs[index].toolTip.isEmpty {
            addToolTip(rect, owner: tabs[index].toolTip as NSString, userData: nil)
        }
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let separator = NSColor(srgbRed: 0xAA / 255, green: 0xAA / 255, blue: 0xAA / 255, alpha: 1)
        for (index, rect) in frames.enumerated() {
            let selected = index == selectedIndex
            (selected ? NSColor.white : background).setFill()
            rect.fill()
            separator.setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
            let color = selected ? NSColor(srgbRed: 0x28 / 255, green: 0x28 / 255, blue: 0x28 / 255, alpha: 1)
                : NSColor(srgbRed: 0x50 / 255, green: 0x50 / 255, blue: 0x50 / 255, alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let textRect = NSRect(x: rect.minX + 24, y: (rect.height - 14) / 2, width: rect.width - 30, height: 15)
            (tabs[index].title as NSString).draw(in: textRect, withAttributes: attrs)
        }
        separator.setFill()
        let lineStart = frames.last?.maxX ?? 0
        NSRect(x: lineStart, y: bounds.maxY - 1, width: bounds.width - lineStart, height: 1).fill()
    }

    private func index(at point: NSPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else {
            if event.clickCount == 2 { onDoubleClickEmpty?() }
            return
        }
        dragIndex = index
        onSelect?(index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragIndex, let to = index(at: convert(event.locationInWindow, from: nil)), from != to else { return }
        onMove?(from, to)
        dragIndex = to
    }

    override func mouseUp(with event: NSEvent) {
        dragIndex = nil
    }

    override func otherMouseUp(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) { onClose?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuForTab?(index)
    }

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?(sender.tag)
    }
}

protocol WorkAreaDelegate: AnyObject {
    func workAreaDidChangeSelection()
    func workAreaOpenShell(from tab: QueryTabController, script: String, execute: Bool)
}

final class WorkAreaController: NSViewController {
    private let tabBar = TabBarView()
    private let container = ColorView(color: NSColor(srgbRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255, alpha: 1))
    private(set) var tabs: [QueryTabController] = []
    private(set) var selectedIndex = -1
    weak var delegate: WorkAreaDelegate?

    var current: QueryTabController? {
        selectedIndex >= 0 && selectedIndex < tabs.count ? tabs[selectedIndex] : nil
    }

    override func loadView() {
        let root = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Theme.border.cgColor
        root.addSubview(tabBar)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
        ])
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.close($0) }
        tabBar.onMove = { [weak self] in self?.move(from: $0, to: $1) }
        tabBar.onDoubleClickEmpty = { [weak self] in
            guard let self, let current = self.current else { return }
            self.delegate?.workAreaOpenShell(from: current, script: "", execute: false)
        }
        tabBar.menuForTab = { [weak self] in self?.menu(for: $0) }
        tabBar.isHidden = true
        view = root
    }

    func add(_ tab: QueryTabController) {
        tab.onTitleChange = { [weak self] in self?.refreshTitles() }
        tabs.append(tab)
        refreshTitles()
        select(tabs.count - 1)
    }

    func select(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        current?.view.removeFromSuperview()
        selectedIndex = index
        let tab = tabs[index]
        container.addSubview(tab.view)
        tab.view.pin(to: container)
        tabBar.selectedIndex = index
        tab.focusEditor()
        delegate?.workAreaDidChangeSelection()
    }

    func close(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs.remove(at: index)
        tab.stop()
        tab.closeUndockedWindow()
        tab.view.removeFromSuperview()
        if selectedIndex >= tabs.count || index < selectedIndex || (index == selectedIndex) {
            selectedIndex = -1
            refreshTitles()
            if !tabs.isEmpty { select(min(index, tabs.count - 1)) }
        } else {
            refreshTitles()
        }
        delegate?.workAreaDidChangeSelection()
    }

    func closeTabs(of session: ServerSession) {
        for index in tabs.indices.reversed() where tabs[index].session === session { close(index) }
    }

    func closeOthers(_ index: Int) {
        let keep = tabs[index]
        for i in tabs.indices.reversed() where tabs[i] !== keep { close(i) }
    }

    func closeToTheRight(_ index: Int) {
        while tabs.count > index + 1 { close(tabs.count - 1) }
    }

    func next() {
        guard !tabs.isEmpty else { return }
        select((selectedIndex + 1) % tabs.count)
    }

    func previous() {
        guard !tabs.isEmpty else { return }
        select((selectedIndex - 1 + tabs.count) % tabs.count)
    }

    private func move(from: Int, to: Int) {
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        selectedIndex = to
        refreshTitles()
        tabBar.selectedIndex = to
    }

    func refreshTitles() {
        tabBar.tabs = tabs.map { TabBarView.Tab(title: $0.tabTitle, toolTip: $0.toolTip) }
        tabBar.selectedIndex = selectedIndex
        tabBar.isHidden = tabs.isEmpty
    }

    private func menu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let tab = tabs[index]
        let newShell = ClosureMenuItem(title: "New Shell", keyEquivalent: "t") { [weak self] in
            self?.delegate?.workAreaOpenShell(from: tab, script: "", execute: false)
        }
        menu.addItem(newShell)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Re-execute Query", keyEquivalent: "r") { tab.execute() })
        let duplicate = ClosureMenuItem(title: "Duplicate Query In New Tab", keyEquivalent: "T") { [weak self] in
            self?.delegate?.workAreaOpenShell(from: tab, script: tab.scriptText, execute: true)
        }
        menu.addItem(duplicate)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Close Shell", keyEquivalent: "w") { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.close(i)
        })
        menu.addItem(ClosureMenuItem(title: "Close Other Shells") { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeOthers(i)
        })
        menu.addItem(ClosureMenuItem(title: "Close Shells to the Right") { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeToTheRight(i)
        })
        return menu
    }
}
