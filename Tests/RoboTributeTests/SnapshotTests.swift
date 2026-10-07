import XCTest
import AppKit
@testable import RoboTribute

/// Renders the main windows offscreen into PNGs for visual review.
/// Enabled with ROBO3T_SNAPSHOT_DIR and a seeded test mongod on ROBO3T_TEST_PORT (default 27999).
@MainActor
final class SnapshotTests: XCTestCase {
    private var outputDir: URL!

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["ROBO3T_SNAPSHOT_DIR"] else { throw XCTSkip("ROBO3T_SNAPSHOT_DIR not set") }
        outputDir = URL(fileURLWithPath: dir)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames MainSplit")
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames RightSplit")
    }

    private func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func snapshot(_ window: NSWindow, _ name: String) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let view = window.contentView, let image = NSImage(data: view.dataWithPDF(inside: view.bounds)) else { return }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: outputDir.appendingPathComponent(name + ".png"))
    }

    private var testSettings: ConnectionSettings {
        var settings = ConnectionSettings()
        settings.connectionName = "local test"
        settings.serverHost = "localhost"
        settings.serverPort = Int(ProcessInfo.processInfo.environment["ROBO3T_TEST_PORT"] ?? "27999") ?? 27999
        return settings
    }

    func testMainWindowFlow() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1500, height: 860))
        controller.showWindow(nil)
        snapshot(window, "01-empty")

        controller.connect(testSettings)
        wait { controller.explorer.servers.first?.isLoaded == true }
        let server = try XCTUnwrap(controller.explorer.servers.first)
        let sample = try XCTUnwrap(server.children.compactMap { $0 as? DatabaseNode }.first { $0.name == "sample" })
        controller.explorer.outlineView.expandItem(sample)
        controller.explorer.outlineView.expandItem(sample.collections)
        wait { sample.collections.isLoaded }
        snapshot(window, "02-explorer")

        controller.explorerOpenShell(session: server.session, database: "sample",
                                     script: "db.getCollection('people').find({})", execute: true, cursorFromEnd: 2)
        wait { controller.workArea.current?.isRunning == false && controller.workArea.current?.output.items.isEmpty == false }
        snapshot(window, "03-tree")
        if ProcessInfo.processInfo.environment["ROBO3T_DUMP"] != nil, let view = controller.workArea.current?.view {
            func dump(_ v: NSView, _ depth: Int) {
                guard depth < 12 else { return }
                print("DUMP " + String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
                v.subviews.forEach { dump($0, depth + 1) }
            }
            dump(view, 0)
        }

        controller.explorerOpenShell(session: server.session, database: "sample",
                                     script: "db.getCollection('records').find({}, {points: 1})", execute: true, cursorFromEnd: 2)
        wait { controller.workArea.current?.isRunning == false && controller.workArea.current?.output.items.isEmpty == false }
        if let tree = controller.workArea.current?.output.items.first {
            tree.showTree()
        }
        snapshot(window, "04-records")

        controller.setViewMode(.table)
        snapshot(window, "05-table")
        controller.setViewMode(.text)
        wait(2) { false }
        snapshot(window, "06-text")
        controller.setViewMode(.tree)

        controller.explorerOpenShell(session: server.session, database: "sample",
                                     script: "print('hi')\ndb.records.count()\ndb.records.find({n: 1})", execute: true, cursorFromEnd: 0)
        wait { controller.workArea.current?.isRunning == false && controller.workArea.current?.output.items.isEmpty == false }
        controller.toggleLogs(nil)
        snapshot(window, "07-multi")
        window.close()
    }

    func testDialogs() throws {
        let connections = ConnectionsWindow()
        connections.window.setContentSize(NSSize(width: 864, height: 526))
        connections.window.orderFront(nil)
        snapshot(connections.window, "10-connections")
        connections.window.orderOut(nil)

        var settings = testSettings
        settings.ssl.sslEnabled = true
        settings.ssl.caFile = "/tmp/root-ca.pem"
        settings.credential.enabled = true
        settings.credential.userName = "admin-user"
        let dialog = ConnectionSettingsWindow(settings: settings, secrets: ConnectionSecrets())
        dialog.window.orderFront(nil)
        let tabs = try XCTUnwrap(dialog.window.contentView?.subviews.compactMap { $0 as? NSTabView }.first)
        for (index, name) in ["connection", "auth", "ssh", "tls", "advanced"].enumerated() {
            tabs.selectTabViewItem(at: index)
            snapshot(dialog.window, "11-settings-\(name)")
        }
        dialog.window.orderOut(nil)

        let formatter = BSONFormatter(uuidEncoding: .standard, timeZone: .utc)
        let doc = try ShellJSONParser.parseDocuments("""
        {"_id": "doc-0001", "name": "Ada Lovelace", "public": true,
         "chapters": ["tag-a", "tag-b"], "level": 3, "i18n": {"zh": {"name": "你好世界"}}}
        """)[0]
        let editor = DocumentEditorWindow(title: "Edit Document",
                                          info: .init(server: "localhost:27017", db: "sample", collection: "people"),
                                          json: formatter.jsonString(doc), readOnly: false)
        editor.window.setContentSize(NSSize(width: 1100, height: 600))
        editor.window.orderFront(nil)
        snapshot(editor.window, "12-edit-document")
        editor.window.orderOut(nil)
    }
}
