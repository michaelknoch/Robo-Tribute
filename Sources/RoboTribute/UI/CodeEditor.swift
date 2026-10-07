import AppKit

/// The dark JavaScript editor used for queries, documents and text output (RoboScintilla + JSLexer).
final class CodeEditor: NSView, NSTextStorageDelegate, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: CodeTextView
    var onTextChange: (() -> Void)?
    private var lineNumbers: LineNumberRuler?
    private var highlightTask: Task<Void, Never>?

    var string: String {
        get { textView.string }
        set { adopt(JSHighlighter.storage(for: newValue)) }
    }

    /// Swapping the storage is cheap; restyling the current one costs main-thread time per attribute run.
    func adopt(_ storage: NSTextStorage) {
        highlightTask?.cancel()
        storage.delegate = self
        textView.layoutManager?.replaceTextStorage(storage)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        lineNumbers?.textReplaced()
    }

    func setStringHighlightingInBackground(_ text: String) {
        adopt(NSTextStorage(string: text, attributes: [.font: Theme.codeFont, .foregroundColor: Theme.Editor.text]))
        highlightTask = Task {
            let highlighted = await Self.highlight(text)
            guard !Task.isCancelled, textView.string == text else { return }
            adopt(highlighted)
        }
    }

    @concurrent
    private static func highlight(_ text: String) async -> sending NSTextStorage {
        JSHighlighter.storage(for: text)
    }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    var cornerRadius: CGFloat = 4 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    init(wrap: Bool = false, editable: Bool = true) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = wrap
        layout.addTextContainer(container)
        textView = CodeTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        layer?.backgroundColor = Theme.Editor.background.cgColor
        layer?.masksToBounds = true

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Theme.codeFont
        textView.textColor = Theme.Editor.text
        textView.backgroundColor = Theme.Editor.background
        textView.drawsBackground = true
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [.backgroundColor: Theme.Editor.selection, .foregroundColor: NSColor.white]
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.typingAttributes = [.font: Theme.codeFont, .foregroundColor: Theme.Editor.text]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.editor = self
        storage.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrap
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.Editor.background
        scrollView.borderType = .noBorder
        scrollView.scrollerKnobStyle = .light
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setLineNumbersVisible(AppSettings.shared.lineNumbers)
    }

    required init?(coder: NSCoder) { fatalError() }

    var lineHeight: CGFloat {
        textView.layoutManager?.defaultLineHeight(for: Theme.codeFont) ?? 15
    }

    var lineCount: Int {
        var count = 1
        for c in textView.string.utf16 where c == 10 { count += 1 }
        return count
    }

    func setLineNumbersVisible(_ visible: Bool) {
        if visible {
            let ruler = lineNumbers ?? LineNumberRuler(textView: textView)
            lineNumbers = ruler
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        } else {
            scrollView.rulersVisible = false
        }
    }

    func toggleLineNumbers() {
        setLineNumbersVisible(!scrollView.rulersVisible)
    }

    // MARK: Highlighting

    /// Re-colors after typing: the whole text when small, otherwise just the edited lines.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let text = textStorage.string as NSString
        let range = text.length <= 100_000 ? NSRange(location: 0, length: text.length) : text.lineRange(for: editedRange)
        textStorage.addAttribute(.foregroundColor, value: Theme.Editor.text, range: range)
        for span in JSHighlighter.spans(in: text.substring(with: range) as NSString) {
            textStorage.addAttribute(.foregroundColor, value: span.color, range: NSRange(location: span.range.location + range.location, length: span.range.length))
        }
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?()
    }
}

final class CodeTextView: NSTextView {
    weak var editor: CodeEditor?

    @objc func toggleLineNumbers(_ sender: Any?) {
        editor?.toggleLineNumbers()
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

}

nonisolated enum JSHighlighter {
    struct Span {
        let range: NSRange
        let color: NSColor
    }

    static let keywords: Set<String> = Set("""
        abstract boolean break byte case catch char class const continue debugger default delete do double else enum \
        export extends final finally float for function goto if implements import in instanceof int interface long \
        native new package private protected public return short static super switch synchronized this throw throws \
        transient try typeof var void volatile while with ISODate ObjectId Mongo Date NumberInt Number NumberLong \
        Timestamp _id null false true UUID LUUID PYUUID CSUUID JUUID NUUID let
        """.split(separator: " ").map(String.init))

    static func storage(for text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: [.font: Theme.Editor.makeFont(), .foregroundColor: Theme.Editor.text])
        storage.beginEditing()
        for span in spans(in: text as NSString) {
            storage.addAttribute(.foregroundColor, value: span.color, range: span.range)
        }
        storage.endEditing()
        return storage
    }

    static func spans(in text: NSString) -> [Span] {
        var spans: [Span] = []
        let length = text.length
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var i = 0
        func isIdentStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        // Whitespace shows no color, so bridging it saves an attribute run.
        func add(_ start: Int, _ end: Int, _ color: NSColor) {
            if let last = spans.last, last.color === color,
               buffer[last.range.upperBound..<start].allSatisfy({ $0 == 32 || $0 == 10 || $0 == 9 || $0 == 13 }) {
                spans[spans.count - 1] = Span(range: NSRange(location: last.range.location, length: end - last.range.location), color: color)
            } else {
                spans.append(Span(range: NSRange(location: start, length: end - start), color: color))
            }
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        let operators: Set<unichar> = Set("{}[]().,;:+-*/%=<>!&|?^~".utf16)
        while i < length {
            let c = buffer[i]
            if c == 47, i + 1 < length, buffer[i + 1] == 47 {
                let start = i
                while i < length, buffer[i] != 10 { i += 1 }
                add(start, i, Theme.Editor.comment)
            } else if c == 47, i + 1 < length, buffer[i + 1] == 42 {
                let start = i
                i += 2
                while i < length, !(buffer[i] == 42 && i + 1 < length && buffer[i + 1] == 47) { i += 1 }
                i = min(i + 2, length)
                add(start, i, Theme.Editor.comment)
            } else if c == 34 || c == 39 || c == 96 {
                let start = i
                i += 1
                while i < length, buffer[i] != c, buffer[i] != 10 || c == 96 {
                    if buffer[i] == 92 { i += 1 }
                    i += 1
                }
                let closed = i < length && buffer[i] == c
                i = min(i + 1, length)
                add(start, i, closed ? Theme.Editor.string : Theme.Editor.operatorColor)
            } else if isDigit(c) || (c == 46 && i + 1 < length && isDigit(buffer[i + 1])) {
                let start = i
                while i < length, isDigit(buffer[i]) || buffer[i] == 46 || buffer[i] == 101 || buffer[i] == 69 || buffer[i] == 120
                        || (buffer[i] >= 97 && buffer[i] <= 102) || (buffer[i] >= 65 && buffer[i] <= 70) { i += 1 }
                add(start, i, Theme.Editor.number)
            } else if isIdentStart(c) {
                let start = i
                while i < length, isIdentStart(buffer[i]) || isDigit(buffer[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(buffer[start..<i]), count: i - start)
                if keywords.contains(word) {
                    add(start, i, Theme.Editor.keyword)
                }
            } else if operators.contains(c) {
                add(i, i + 1, Theme.Editor.operatorColor)
                i += 1
            } else {
                i += 1
            }
        }
        return spans
    }
}

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int]?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(refresh(_:)), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh(_:)), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    func textReplaced() {
        lineStarts = nil
        needsDisplay = true
    }

    @objc private func refresh(_ notification: Notification) {
        if notification.name == NSText.didChangeNotification { lineStarts = nil }
        needsDisplay = true
    }

    private func lineNumber(at location: Int, in text: NSString) -> Int {
        if lineStarts == nil {
            var starts = [0]
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                if NSMaxRange(enclosing) < text.length { starts.append(NSMaxRange(enclosing)) }
            }
            lineStarts = starts
        }
        let starts = lineStarts!
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.Editor.margin.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var lineNumber = lineNumber(at: charRange.location, in: text)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.codeFont, .foregroundColor: Theme.Editor.marginText]
        let inset = textView.textContainerInset.height
        var index = charRange.location
        while index <= NSMaxRange(charRange) {
            let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(lineRange.location, max(text.length - 1, 0)))
            var lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if text.length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: layout.defaultLineHeight(for: Theme.codeFont)) }
            let y = lineRect.minY + inset - visible.minY
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attrs)
            lineNumber += 1
            if NSMaxRange(lineRange) <= index || NSMaxRange(lineRange) >= text.length { break }
            index = NSMaxRange(lineRange)
        }
    }
}
