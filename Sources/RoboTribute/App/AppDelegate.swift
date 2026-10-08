import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppSettings.shared.importFromRoboIfNeeded()
        NSApp.mainMenu = buildMenu()
        mainWindow = MainWindowController()
        mainWindow.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.manageConnections(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.closeAllSessions()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu (MainWindow.cpp)

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Robo Tribute")
        app.addItem(withTitle: "About Robo Tribute", action: #selector(showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Robo Tribute", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Robo Tribute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        file.addItem(withTitle: "Connect...", action: #selector(MainWindowController.manageConnections(_:)), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: "New Shell", action: #selector(MainWindowController.newShell(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open...", action: #selector(MainWindowController.openScript(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Save", action: #selector(MainWindowController.saveScript(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As...", action: #selector(MainWindowController.saveScriptAs(_:)), keyEquivalent: "S")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Shell", action: #selector(MainWindowController.closeShell(_:)), keyEquivalent: "w")

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        find.addItem(findItem("Find...", .showFindInterface, "f"))
        find.addItem(findItem("Find Next", .nextMatch, "g"))
        find.addItem(findItem("Find Previous", .previousMatch, "G"))

        let view = submenu(main, "View")
        view.addItem(withTitle: "Explorer", action: #selector(MainWindowController.toggleExplorer(_:)), keyEquivalent: "e")
        view.addItem(withTitle: "Logs", action: #selector(MainWindowController.toggleLogs(_:)), keyEquivalent: "l")
        // Robo 3T binds these only to toolbar buttons; hidden items keep its menus while routing the keys through the responder chain.
        hiddenItem(view, "Execute", #selector(MainWindowController.executeScript(_:)), NSF5FunctionKey, [])
        hiddenItem(view, "Execute", #selector(MainWindowController.executeScript(_:)), 0x0D, .command)
        hiddenItem(view, "Execute", #selector(MainWindowController.executeScript(_:)), 0x03, .command)
        hiddenItem(view, "Stop", #selector(MainWindowController.stopScript(_:)), NSF6FunctionKey, [])
        hiddenItem(view, "Rotate", #selector(MainWindowController.rotate(_:)), NSF10FunctionKey, [])
        hiddenItem(view, "Toggle Line Numbers", #selector(CodeTextView.toggleLineNumbers(_:)), NSF11FunctionKey, [])

        let options = submenu(main, "Options")
        let modes = NSMenu(title: "Default View Mode")
        options.addItem(withTitle: "Default View Mode", action: nil, keyEquivalent: "").submenu = modes
        for (title, mode, key) in [("Tree Mode", ViewMode.tree, NSF2FunctionKey), ("Table Mode", .table, NSF3FunctionKey), ("Text Mode", .text, NSF4FunctionKey)] {
            let item = modes.addItem(withTitle: title, action: #selector(MainWindowController.setViewModeFromMenu(_:)),
                                     keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = []
            item.tag = mode.rawValue
        }
        options.addItem(.separator())
        let dates = NSMenu(title: "Display Dates In...")
        options.addItem(withTitle: "Display Dates In...", action: nil, keyEquivalent: "").submenu = dates
        dates.addItem(withTitle: "UTC", action: #selector(setTimeZone(_:)), keyEquivalent: "").tag = TimeZoneMode.utc.rawValue
        dates.addItem(withTitle: "Local Timezone", action: #selector(setTimeZone(_:)), keyEquivalent: "").tag = TimeZoneMode.local.rawValue
        let uuid = NSMenu(title: "Legacy UUID Encoding")
        options.addItem(withTitle: "Legacy UUID Encoding", action: nil, keyEquivalent: "").submenu = uuid
        for (title, encoding) in [("Do not decode (show as is)", UUIDEncoding.standard), ("Use Java Encoding", .javaLegacy),
                                  ("Use .NET Encoding", .csharpLegacy), ("Use Python Encoding", .pythonLegacy)] {
            uuid.addItem(withTitle: title, action: #selector(setUUIDEncoding(_:)), keyEquivalent: "").tag = encoding.rawValue
        }
        options.addItem(.separator())
        options.addItem(withTitle: "Auto Expand First Document", action: #selector(toggleAutoExpand(_:)), keyEquivalent: "")
        options.addItem(withTitle: "Show Line Numbers By Default", action: #selector(toggleLineNumbers(_:)), keyEquivalent: "")
        options.addItem(withTitle: "Automatically execute code in new tab", action: #selector(toggleAutoExec(_:)), keyEquivalent: "")
        options.addItem(.separator())
        options.addItem(withTitle: "Change Shell Timeout...", action: #selector(changeShellTimeout(_:)), keyEquivalent: "")

        let window = submenu(main, "Window")
        let fullScreen = window.addItem(withTitle: "Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Select Next Tab", action: #selector(MainWindowController.nextTab(_:)), keyEquivalent: "}")
        window.addItem(withTitle: "Select Previous Tab", action: #selector(MainWindowController.previousTab(_:)), keyEquivalent: "{")
        window.addItem(.separator())
        window.addItem(withTitle: "Re-execute Query in Current Tab", action: #selector(MainWindowController.reexecute(_:)), keyEquivalent: "r")
        window.addItem(withTitle: "Duplicate Query in New Tab", action: #selector(MainWindowController.duplicateTab(_:)), keyEquivalent: "T")
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        help.addItem(withTitle: "About Robo Tribute...", action: #selector(showAbout(_:)), keyEquivalent: "")
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    private func hiddenItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: Int, _ modifiers: NSEvent.ModifierFlags) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: String(Character(UnicodeScalar(key)!)))
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    private func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
        item.tag = action.rawValue
        return item
    }

    // MARK: Option actions

    @objc private func setTimeZone(_ sender: NSMenuItem) {
        AppSettings.shared.timeZone = TimeZoneMode(rawValue: sender.tag) ?? .utc
        AppSettings.shared.save()
    }

    @objc private func setUUIDEncoding(_ sender: NSMenuItem) {
        AppSettings.shared.uuidEncoding = UUIDEncoding(rawValue: sender.tag) ?? .standard
        AppSettings.shared.save()
    }

    @objc private func toggleAutoExpand(_ sender: NSMenuItem) {
        AppSettings.shared.autoExpand.toggle()
        AppSettings.shared.save()
    }

    @objc private func toggleLineNumbers(_ sender: NSMenuItem) {
        AppSettings.shared.lineNumbers.toggle()
        AppSettings.shared.save()
    }

    @objc private func toggleAutoExec(_ sender: NSMenuItem) {
        AppSettings.shared.autoExec.toggle()
        AppSettings.shared.save()
    }

    @objc private func changeShellTimeout(_ sender: NSMenuItem) {
        ShellTimeoutDialog.run()
    }

    @objc private func showAbout(_ sender: Any?) {
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        let credits = NSMutableAttributedString()
        func add(_ text: String, font: NSFont = body, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link { attributes[.link] = URL(string: link) }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("Shell-centric MongoDB management tool.\n\n")
        add("Thank you, Robo 3T\n", font: bold)
        add("This app is a native macOS re-implementation of ")
        add("Robo 3T 1.4", link: "https://github.com/Studio3T/robomongo")
        add(" (formerly Robomongo). Its design, dialogs, icons and document formatting are the work of the Robomongo "
            + "and Robo 3T authors. Thanks to @schetnikovich, @simsekgokhan, @stennie and all ")
        add("contributors", link: "https://github.com/Studio3T/robomongo/graphs/contributors")
        add(", and to 3T Software Labs for keeping Robo 3T open source under the GPLv3.\n\n")
        add("Robo 3T is a trademark of 3T Software Labs Ltd.; this project is not affiliated with them.\n\n")
        add("Dependencies: MongoDB C Driver 2.5.5, OpenSSL 4.0.3, Esprima 4.0.1.\n\n")
        add("Licensed under the GNU GPL v3. The program is provided AS IS with NO WARRANTY OF ANY KIND, INCLUDING THE "
            + "WARRANTY OF DESIGN, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.")
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Robo Tribute"])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let settings = AppSettings.shared
        switch menuItem.action {
        case #selector(setTimeZone(_:)): menuItem.state = settings.timeZone.rawValue == menuItem.tag ? .on : .off
        case #selector(setUUIDEncoding(_:)): menuItem.state = settings.uuidEncoding.rawValue == menuItem.tag ? .on : .off
        case #selector(toggleAutoExpand(_:)): menuItem.state = settings.autoExpand ? .on : .off
        case #selector(toggleLineNumbers(_:)): menuItem.state = settings.lineNumbers ? .on : .off
        case #selector(toggleAutoExec(_:)): menuItem.state = settings.autoExec ? .on : .off
        default: break
        }
        return true
    }
}
