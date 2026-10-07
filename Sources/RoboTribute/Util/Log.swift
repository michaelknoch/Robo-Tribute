import Foundation
import os

nonisolated enum LogLevel {
    case info, log, warning, error
}

nonisolated enum Log {
    struct Entry {
        let sequence: Int
        let date: Date
        let level: LogLevel
        let message: String
    }

    static let didLog = Notification.Name("RoboTribute.didLog")
    private static let store = OSAllocatedUnfairLock(initialState: (entries: [Entry](), next: 1))
    static var entries: [Entry] { store.withLock { $0.entries } }

    static func info(_ message: String) { add(message, .info) }
    static func log(_ message: String) { add(message, .log) }
    static func warning(_ message: String) { add(message, .warning) }
    static func error(_ message: String) { add(message, .error) }

    private static func add(_ message: String, _ level: LogLevel) {
        let entry = store.withLock { store in
            let entry = Entry(sequence: store.next, date: Date(), level: level, message: message)
            store.next += 1
            store.entries.append(entry)
            if store.entries.count > 5000 { store.entries.removeFirst(store.entries.count - 5000) }
            return entry
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didLog, object: nil, userInfo: ["entry": entry])
        }
    }
}
