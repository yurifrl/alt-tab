import AppKit

/// The "More details" table under a rule's Match editor: every open window's
/// matchable values (title / id / app / pid, bundle + state on the sub-line),
/// clickable to drop that value into the focused condition. Windows the rule
/// matches are tinted green with a ✓; the value cells a condition already uses
/// are tinted accent. Titles wider than their column slide back and forth
/// (pausing under the pointer) and carry the full text as a tooltip.
final class WindowMatchTableView: NSView {
    /// A value was clicked: fill the editor's focused condition with it.
    var onPick: ((PrefsStore.Matcher.Attribute, String) -> Void)?

    /// The fixed content height the Windows pane reserves for the table.
    static let height: CGFloat = 266
    private static let headerHeight: CGFloat = 45

    private let header = HeaderView()
    private let scroll = NSScrollView()
    private let rowsHost = RowsHostView()
    private var rows: [UInt32: WindowRowView] = [:]
    /// The windows on screen, in tracker order (parallel to the laid-out rows).
    private var windows: [WindowModel] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = rowsHost
        addSubview(scroll)
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        scroll.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width,
                              height: max(0, bounds.height - Self.headerHeight))
        layoutRows()
    }

    /// Rows scroll: the host is as tall as the content wants, so the scroll
    /// view clips at the fixed 266pt box.
    private func layoutRows() {
        let size = scroll.contentSize
        rowsHost.frame = NSRect(x: 0, y: 0, width: size.width,
                                height: max(size.height, CGFloat(windows.count) * Metrics.rowHeight))
        var y: CGFloat = 0
        for w in windows {
            rows[w.windowId]?.frame = NSRect(x: 0, y: y, width: size.width, height: Metrics.rowHeight)
            y += Metrics.rowHeight
        }
        rowsHost.emptyText = windows.isEmpty ? "No open windows" : nil
        rowsHost.needsDisplay = true
    }

    /// Rebind the table to a rule and the tracker's current windows. Rows are
    /// reused by window id: only their contents change between refreshes.
    func update(rule: PrefsStore.WindowRule, windows all: [WindowModel]) {
        let listed = all.filter { $0.windowId != 0 && !$0.title.isEmpty }
        let conditions = rule.matchers.filter { !$0.text.isEmpty }
        var alive = Set<UInt32>()
        for w in listed {
            alive.insert(w.windowId)
            let row: WindowRowView
            if let existing = rows[w.windowId] {
                row = existing
            } else {
                row = WindowRowView()
                row.onPick = { [weak self] attribute, value in
                    self?.onPick?(attribute, value)
                }
                rowsHost.addSubview(row)
                rows[w.windowId] = row
            }
            row.apply(window: w, matches: PrefsStore.ruleMatches(rule, window: w), conditions: conditions)
        }
        for id in rows.keys where !alive.contains(id) {
            rows[id]?.removeFromSuperview()
            rows[id] = nil
        }
        windows = listed
        needsLayout = true
    }
}

// MARK: - Column math

/// One place for the column geometry so the header labels sit exactly over the
/// cells they name.
private enum Metrics {
    static let rowHeight: CGFloat = 38
    static let pad: CGFloat = 10
    static let idWidth: CGFloat = 76
    static let appWidth: CGFloat = 110
    static let pidWidth: CGFloat = 62
    static let checkWidth: CGFloat = 20

    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    static let appFont = NSFont.systemFont(ofSize: 11.5)
    static let subFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let headFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    struct Cells {
        let title: NSRect
        let id: NSRect
        let app: NSRect
        let pid: NSRect
        let check: NSRect
        let sub: NSRect
    }

    static func cells(width: CGFloat) -> Cells {
        let titleWidth = max(40, width - pad - idWidth - appWidth - pidWidth - checkWidth - pad)
        let title = NSRect(x: pad, y: 4, width: titleWidth, height: 16)
        let id = NSRect(x: title.maxX + 2, y: 4, width: idWidth - 4, height: 16)
        let app = NSRect(x: id.maxX + 4, y: 4, width: appWidth - 6, height: 16)
        let pid = NSRect(x: app.maxX + 4, y: 4, width: pidWidth - 6, height: 16)
        let check = NSRect(x: pid.maxX + 2, y: 4, width: checkWidth - 4, height: 16)
        let sub = NSRect(x: pad, y: 21, width: max(60, pid.maxX - pad - 2), height: 14)
        return Cells(title: title, id: id, app: app, pid: pid, check: check, sub: sub)
    }
}

// MARK: - Caption + column header

private final class HeaderView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let caption: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let hint: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let name = "OPEN WINDOWS" as NSString
        name.draw(at: NSPoint(x: Metrics.pad, y: 6), withAttributes: caption)
        ("click a value to use it in the rule" as NSString)
            .draw(at: NSPoint(x: Metrics.pad + name.size(withAttributes: caption).width + 10, y: 6),
                  withAttributes: hint)

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 23, width: bounds.width, height: 1).fill()

        let cells = Metrics.cells(width: bounds.width)
        let head: [NSAttributedString.Key: Any] = [
            .font: Metrics.headFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ("TITLE" as NSString).draw(at: NSPoint(x: cells.title.minX, y: 29), withAttributes: head)
        ("ID" as NSString).draw(at: NSPoint(x: cells.id.minX, y: 29), withAttributes: head)
        ("APP" as NSString).draw(at: NSPoint(x: cells.app.minX, y: 29), withAttributes: head)
        ("PID" as NSString).draw(at: NSPoint(x: cells.pid.minX, y: 29), withAttributes: head)

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Scrolling host of the rows; paints the empty state itself.
private final class RowsHostView: NSView {
    var emptyText: String?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let text = emptyText else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (text as NSString).draw(at: NSPoint(x: Metrics.pad, y: 12), withAttributes: attrs)
    }
}

// MARK: - Row

private final class WindowRowView: NSView {
    var onPick: ((PrefsStore.Matcher.Attribute, String) -> Void)?
    private(set) var windowId: UInt32 = 0

    private var model: WindowModel?
    private var hit = false
    private var used: Set<PrefsStore.Matcher.Attribute> = []

    // Marquee: titles wider than the column slide (paused under the pointer).
    private var timer: Timer?
    private var offset: CGFloat = 0
    private var direction: CGFloat = 1
    private var distance: CGFloat = 0
    private var pixelsPerSecond: CGFloat = 22
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: Metrics.titleFont,
        .foregroundColor: NSColor.labelColor,
    ]

    override var isFlipped: Bool { true }

    func apply(window w: WindowModel, matches: Bool, conditions: [PrefsStore.Matcher]) {
        model = w
        windowId = w.windowId
        hit = matches
        used = Set(conditions.filter { $0.text == $0.attribute.value(of: w) }.map(\.attribute))
        remeasure()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let w = model else { return }
        let cells = Metrics.cells(width: bounds.width)

        if hit {
            NSColor.systemGreen.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        // Sub-line: the bundle id (dotted underline; clicking it matches that
        // value) then any interesting state.
        let sub = NSMutableAttributedString(string: w.bundleId, attributes: [
            .font: Metrics.subFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.tertiaryLabelColor,
        ])
        var flags: [String] = []
        if w.fullscreen { flags.append("fullscreen") }
        if w.minimized { flags.append("minimized") }
        if w.appHidden { flags.append("app hidden") }
        if w.windowless { flags.append("windowless") }
        if w.ignored { flags.append("ignored") }
        if !flags.isEmpty {
            sub.append(NSAttributedString(string: " · " + flags.joined(separator: ", "), attributes: [
                .font: Metrics.subFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        drawClipped(sub, in: cells.sub)

        // Title, sliding when it overflows its column.
        let title = w.title as NSString
        let titleWidth = title.size(withAttributes: Self.titleAttrs).width
        if titleWidth > cells.title.width {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: cells.title.insetBy(dx: -1, dy: 0))
            clip.addClip()
            title.draw(at: NSPoint(x: cells.title.minX - offset, y: cells.title.minY),
                       withAttributes: Self.titleAttrs)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            title.draw(at: NSPoint(x: cells.title.minX, y: cells.title.minY),
                       withAttributes: Self.titleAttrs)
        }

        drawValue(String(w.windowId), attribute: .windowId, in: cells.id, mono: true)
        drawValue(w.appLocalName, attribute: .app, in: cells.app, mono: false)
        drawValue(String(w.pid), attribute: .pid, in: cells.pid, mono: true)

        if hit {
            let check: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.systemGreen,
            ]
            ("✓" as NSString).draw(at: NSPoint(x: cells.check.minX, y: cells.check.minY), withAttributes: check)
        }
    }

    /// Draw at most one line, ellipsized: rows never grow.
    private func drawClipped(_ text: NSAttributedString, in rect: NSRect) {
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingTail
        let full = NSMutableAttributedString(attributedString: text)
        full.addAttribute(.paragraphStyle, value: line, range: NSRange(location: 0, length: full.length))
        full.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A clickable value: accent-tinted when a condition already uses it.
    private func drawValue(_ value: String, attribute: PrefsStore.Matcher.Attribute,
                           in rect: NSRect, mono: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: mono ? Metrics.valueFont : Metrics.appFont,
            .foregroundColor: used.contains(attribute) ? NSColor.controlAccentColor
                                                       : NSColor.secondaryLabelColor,
        ]
        let text = value as NSString
        let size = text.size(withAttributes: attrs)
        if used.contains(attribute) {
            let pill = NSRect(x: rect.minX - 3, y: rect.minY - 1,
                              width: size.width + 6, height: rect.height)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
        text.draw(at: NSPoint(x: rect.minX, y: rect.minY + (rect.height - size.height) / 2),
                  withAttributes: attrs)
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        guard let w = model else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cells = Metrics.cells(width: bounds.width)
        let targets: [(NSRect, PrefsStore.Matcher.Attribute, String)] = [
            (cells.title, .title, w.title),
            (cells.id, .windowId, String(w.windowId)),
            (cells.app, .app, w.appLocalName),
            (cells.pid, .pid, String(w.pid)),
            (cells.sub, .bundle, w.bundleId),
        ]
        for (rect, attribute, value) in targets
        where !value.isEmpty && rect.insetBy(dx: -1, dy: -2).contains(p) {
            onPick?(attribute, value)
            return
        }
    }

    override func resetCursorRects() {
        let cells = Metrics.cells(width: bounds.width)
        for rect in [cells.title, cells.id, cells.app, cells.pid, cells.sub] {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    // MARK: Hover + marquee

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        remeasure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopMarquee() } else { remeasure() }
    }

    deinit { timer?.invalidate() }

    /// Width changed (or contents did): restart or retire the slide.
    private func remeasure() {
        guard let w = model, bounds.width > 0 else { return }
        let cells = Metrics.cells(width: bounds.width)
        let titleWidth = (w.title as NSString).size(withAttributes: Self.titleAttrs).width
        distance = max(0, titleWidth - cells.title.width)
        toolTip = distance > 1 ? w.title : nil
        if distance > 4 {
            // Same pace as the mock: ~3–9 s per sweep, proportional to travel.
            pixelsPerSecond = distance / min(9, max(3, distance / 12))
            if timer == nil { startMarquee() }
        } else {
            stopMarquee()
            offset = 0
        }
    }

    private func startMarquee() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopMarquee() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard distance > 0, !hovered, window != nil else { return }
        offset += direction * pixelsPerSecond / 30
        if offset >= distance {
            offset = distance
            direction = -1
        } else if offset <= 0 {
            offset = 0
            direction = 1
        }
        needsDisplay = true
    }
}
