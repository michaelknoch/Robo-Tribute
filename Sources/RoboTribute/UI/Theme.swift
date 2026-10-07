import AppKit

/// Colors, fonts and icons taken from Robo 3T (GuiRegistry.cpp, JSLexer.cpp, MainWindow.cpp).
enum Theme {
    static let explorerBackground = NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xEF / 255, alpha: 1)
    static let queryBackground = NSColor(srgbRed: 0xE7 / 255, green: 0xE5 / 255, blue: 0xE4 / 255, alpha: 1)
    static let selection = NSColor(srgbRed: 16 / 255, green: 108 / 255, blue: 214 / 255, alpha: 1)
    static let inactiveSelection = NSColor(srgbRed: 0xDC / 255, green: 0xDC / 255, blue: 0xDC / 255, alpha: 1)
    static let alternateRow = NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
    static let typeText = NSColor(srgbRed: 160 / 255, green: 160 / 255, blue: 164 / 255, alpha: 1)
    static let border = NSColor(srgbRed: 0xC7 / 255, green: 0xC5 / 255, blue: 0xC4 / 255, alpha: 1)
    static let gridLine = NSColor(srgbRed: 0xED / 255, green: 0xEB / 255, blue: 0xEA / 255, alpha: 1)
    static let missingCell = NSColor(srgbRed: 0xF5 / 255, green: 0xF3 / 255, blue: 0xF2 / 255, alpha: 1)
    static let link = NSColor(srgbRed: 0x10 / 255, green: 0x6C / 255, blue: 0xD6 / 255, alpha: 1)
    static let indicatorText = NSColor(srgbRed: 0x55 / 255, green: 0x55 / 255, blue: 0x55 / 255, alpha: 1)

    nonisolated enum Editor {
        /// NSFont isn't Sendable, and editor text is built off the main thread.
        static func makeFont() -> NSFont {
            NSFont(name: "Monaco", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        static let background = NSColor(srgbRed: 73 / 255, green: 76 / 255, blue: 78 / 255, alpha: 1)
        static let margin = NSColor(srgbRed: 53 / 255, green: 56 / 255, blue: 58 / 255, alpha: 1)
        static let marginText = NSColor(srgbRed: 173 / 255, green: 176 / 255, blue: 178 / 255, alpha: 1)
        static let text = NSColor.white
        static let comment = NSColor(srgbRed: 0x99 / 255, green: 0x99 / 255, blue: 0x99 / 255, alpha: 1)
        static let number = NSColor(srgbRed: 0xFF / 255, green: 0xA0 / 255, blue: 0x9E / 255, alpha: 1)
        static let keyword = NSColor(srgbRed: 0xBE / 255, green: 0xE5 / 255, blue: 0xFF / 255, alpha: 1)
        static let string = NSColor(srgbRed: 0xC6 / 255, green: 0xF0 / 255, blue: 0x79 / 255, alpha: 1)
        static let operatorColor = NSColor(srgbRed: 0xFF / 255, green: 0xD1 / 255, blue: 0x4D / 255, alpha: 1)
        static let selection = NSColor(srgbRed: 0x2F / 255, green: 0x65 / 255, blue: 0xCA / 255, alpha: 1)
    }

    static let codeFont = Editor.makeFont()
    static let treeFont = NSFont.systemFont(ofSize: 13)

    private static var cache: [String: NSImage] = [:]

    static func icon(_ name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        let image: NSImage
        if let url = AppResources.bundle.url(forResource: name, withExtension: nil, subdirectory: "Resources/icons"),
           let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            image = NSImage(size: NSSize(width: 16, height: 16))
        }
        cache[name] = image
        return image
    }

    static func icon(_ name: String, size: CGFloat) -> NSImage {
        let key = "\(name)@\(size)"
        if let cached = cache[key] { return cached }
        let source = icon(name)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        cache[key] = image
        return image
    }

    static var server: NSImage { icon("server_16x16.png") }
    static var serverImported: NSImage { icon("server_imported_16x16.png") }
    static var replicaSet: NSImage { icon("replica_set_16x16.png") }
    static var database: NSImage { icon("database_16x16.png") }
    static var collection: NSImage { icon("collection_16x16.png") }
    static var indexIcon: NSImage { icon("index_16x16.png") }
    static var user: NSImage { icon("user_16x16.png") }
    static var function: NSImage { icon("function_16x16.png") }
    static var key: NSImage { icon("key_16x16.png") }
    static var time: NSImage { icon("time_16x16.png") }
    static var info: NSImage { icon("qt_info_32.png", size: 16) }

    static var folder: NSImage {
        if let cached = cache["__folder"] { return cached }
        let image = NSWorkspace.shared.icon(for: .folder)
        image.size = NSSize(width: 16, height: 16)
        cache["__folder"] = image
        return image
    }

    static func bsonIcon(_ value: BSONValue) -> NSImage {
        switch value {
        case .double: return icon("bson_double_16x16.png")
        case .decimal128: return icon("bson_decimal128_16x16.png")
        case .string: return icon("bson_string_16x16.png")
        case .document: return icon("bson_object_16x16.png")
        case .array: return icon("bson_array_16x16.png")
        case .binary: return icon("bson_binary_16x16.png")
        case .bool: return icon("bson_bool_16x16.png")
        case .date, .timestamp: return icon("bson_datetime_16x16.png")
        case .null: return icon("bson_null_16x16.png")
        case .int32, .int64: return icon("bson_integer_16x16.png")
        default: return icon("bson_unsupported_16x16.png")
        }
    }
}

/// Selection drawn in Robo's blue (#106CD6) regardless of the system accent color.
final class RoboRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.selection : Theme.inactiveSelection).setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}
