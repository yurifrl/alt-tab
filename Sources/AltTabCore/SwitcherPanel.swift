import AppKit
import Carbon.HIToolbox

// MARK: - Panel UI (Phase 2 — Switcher panel v1)

/// Case-insensitive match helpers shared by the session filter (row inclusion)
/// and the row renderer (per-character highlight ranges).
enum SearchText {
    /// UTF-16 positions of each query character in a fuzzy subsequence match
    /// over `text`, or nil when the query is not a subsequence of it.
    /// `fuzzy` = "Allow mismatch" search pref: off → only a contiguous
    /// case-insensitive substring counts (one highlighted run).
    static func positions(in text: String, query: String,
                          fuzzy: Bool = PrefsStore.searchAllowMismatch) -> [Range<Int>]? {
        let t = Array(text.lowercased().utf16)
        let q = Array(query.lowercased().utf16)
        guard !q.isEmpty, !t.isEmpty else { return nil }
        if !fuzzy {
            guard q.count <= t.count else { return nil }
            for start in 0...(t.count - q.count) where Array(t[start..<(start + q.count)]) == q {
                return (start..<(start + q.count)).map { $0..<($0 + 1) }
            }
            return nil
        }
        var out: [Range<Int>] = []
        var ti = 0
        // Partial greedy match: query chars not found are skipped, so rows
        // are ranked by how much of the query they cover, never dropped.
        for qc in q {
            guard ti < t.count, let hit = t[ti...].firstIndex(of: qc) else { continue }
            out.append(hit..<(hit + 1))
            ti = hit + 1
        }
        return out.isEmpty ? nil : out
    }

    /// Ranking score: matched-char coverage, plus bonuses for a contiguous
    /// substring (prefix of the app name best).
    static func score(app: String, title: String, query: String) -> Int {
        let q = query.lowercased()
        let fuzzy = PrefsStore.searchAllowMismatch
        func one(_ text: String, prefixBonus: Int, subBonus: Int) -> Int {
            let t = text.lowercased()
            var sc = (positions(in: text, query: query, fuzzy: fuzzy)?.count ?? 0) * 10
            if t.hasPrefix(q) { sc += prefixBonus } else if t.contains(q) { sc += subBonus }
            return sc
        }
        return max(one(app, prefixBonus: 100, subBonus: 60), one(title, prefixBonus: 50, subBonus: 30))
    }

}

/// One row, Contexts Command-Tab cell style: hint gutter | right-aligned app
/// name | icon | window title. Matched query characters render in orange.
final class PanelRowView: NSView {
    private let hint = NSTextField(labelWithString: "")
    private let appName = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    /// Clips the title so an overlong selected title can scroll (marquee).
    private let titleClip = NSView()
    /// Title text + match ranges for recoloring on highlight toggle.
    private var titleText = ""
    private var titleMatches: [Range<Int>]?
    private var appMatches: [Range<Int>]?
    private var hintLetter = ""
    private var appNameText = ""
    private var isSelected = false
    /// Click target ownership: session checks `isHoverSelectable` on hit-test.
    private(set) var globalIndex: Int = -1
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    /// Scroll-wheel step (+1 down / −1 up), relative to the current selection.
    var onScroll: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        addTrackingArea(NSTrackingArea(
            rect: .infinite, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        titleClip.wantsLayer = true
        titleClip.layer?.masksToBounds = true
        titleClip.addSubview(title)
        for view in [hint, appName, iconView, titleClip] { addSubview(view) }
        hint.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hint.alignment = .left
        appName.font = .systemFont(ofSize: 13, weight: .medium)
        appName.alignment = .right
        appName.cell?.truncatesLastVisibleLine = true
        title.font = .systemFont(ofSize: 13)
        title.cell?.truncatesLastVisibleLine = true
        for f in [title, appName] { f.maximumNumberOfLines = 1; f.lineBreakMode = .byTruncatingTail }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// Columns (Contexts Command-Tab): hint gutter 10–26, app name right edge
    /// at 196, icon 204–224, title from 230 to the row's right edge − 8.
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        func centered(_ f: NSTextField, x: CGFloat, width: CGFloat) {
            let th = min(h, f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: h)).height ?? 17)
            f.frame = NSRect(x: x, y: (h - th) / 2, width: width, height: th)
        }
        hint.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        centered(appName, x: 28, width: 170)
        iconView.frame = NSRect(x: 206, y: (h - 20) / 2, width: 20, height: 20)
        titleClip.frame = NSRect(x: 234, y: 0, width: max(0, w - 242), height: h)
        layoutTitle()
    }

    /// Selected + too long → single-line clipped field that scrolls back and
    /// forth; otherwise a plain tail-truncated label.
    private func layoutTitle() {
        let h = bounds.height, cw = titleClip.bounds.width
        title.layer?.removeAllAnimations()
        let full = ceil(title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: h)).width ?? 0) + 2
        let th = min(h, title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: h)).height ?? 17)
        if isSelected, full > cw {
            title.lineBreakMode = .byClipping
            title.frame = NSRect(x: 0, y: (h - th) / 2, width: full, height: th)
            title.wantsLayer = true
            let dist = full - cw
            let travel = Double(dist) / 45          // ~45 pt/s
            let hold = 1.0                          // pause at each end
            let total = hold + travel + hold + travel
            let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
            a.values = [0, 0, -dist, -dist, 0]
            a.keyTimes = [0, hold / total, (hold + travel) / total, (2 * hold + travel) / total, 1].map { NSNumber(value: $0) }
            a.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
            a.duration = total
            a.repeatCount = .infinity
            title.layer?.add(a, forKey: "marquee")
        } else {
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 0, y: (h - th) / 2, width: cw, height: th)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !PrefsStore.ignoreMouse, PrefsStore.hoverSelects, globalIndex >= 0 else { return }
        onHover?(globalIndex)
    }

    override func mouseDown(with event: NSEvent) {
        guard !PrefsStore.ignoreMouse, globalIndex >= 0 else { return }
        onClick?(globalIndex)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !PrefsStore.ignoreMouse, PrefsStore.scrollSelects, abs(event.deltaY) > 0.4 else { return }
        onScroll?(event.deltaY < 0 ? -1 : 1)
    }

    func configure(_ wm: WindowModel, globalIndex idx: Int = -1, query: String = "", hint: Character? = nil) {
        globalIndex = idx
        hintLetter = hint.map { String($0) } ?? ""
        appMatches = query.isEmpty ? nil : SearchText.positions(in: wm.appLocalName, query: query)
        appNameText = wm.appLocalName
        iconView.image = NSRunningApplication(processIdentifier: wm.pid)?.icon
        appName.stringValue = wm.appLocalName
        var text = wm.displayTitle
        if wm.minimized { text += "  (minimized)" }
        if wm.ignored { text += "  (ignored)" }
        titleText = text
        titleMatches = query.isEmpty ? nil : SearchText.positions(in: text, query: query)
        alphaValue = wm.ignored ? 0.45 : (wm.minimized ? 0.55 : 1.0)
        applyIndicator()
        setHighlighted(false)
    }

    /// Row indicator per pref: number gutter, search-hint gutter, or neither.
    func applyIndicator() {
        switch PrefsStore.rowIndicator {
        case .numbers:
            hint.stringValue = globalIndex >= 0 && globalIndex < 9 ? String(globalIndex + 1) : ""
            hint.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        case .searchHints:
            hint.stringValue = hintLetter
            hint.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        case .neither:
            hint.stringValue = ""
        }
    }

    func setHighlighted(_ on: Bool) {
        isSelected = on
        layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        hint.textColor = on ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor
        title.attributedStringValue = styled(titleText, matches: titleMatches, selected: on)
        layoutTitle()
        let styledName = NSMutableAttributedString(attributedString: styled(appNameText, matches: appMatches, selected: on))
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        para.lineBreakMode = .byTruncatingTail
        styledName.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: styledName.length))
        appName.attributedStringValue = styledName
    }

    /// Base color (white on the accent row) with matched characters in red.
    private func styled(_ text: String, matches: [Range<Int>]?, selected: Bool) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .medium), range: NSRange(location: 0, length: (text as NSString).length))
        attr.addAttribute(.foregroundColor, value: selected ? NSColor.white : NSColor.labelColor,
                          range: NSRange(location: 0, length: (text as NSString).length))
        for r in matches ?? [] {
            attr.addAttribute(.foregroundColor, value: NSColor.systemRed,
                              range: NSRange(location: r.lowerBound, length: r.upperBound - r.lowerBound))
        }
        return attr
    }
}

/// Borderless, non-activating overlay listing windows. Never becomes key:
/// all input arrives through the global CGEventTap, Contexts-style.
final class SwitcherPanelController {
    /// One overlay per display: sub-rows + its own panel window.
    private final class ScreenPanel {
        let panel: NSPanel
        let effect: NSVisualEffectView
        let stack: NSStackView
        var rowViews: [PanelRowView] = []
        var rows: [WindowModel] = []
        var hints: [Character?] = []
        /// Global row index → section header shown above that row.
        var headers: [Int: String] = [:]
        /// Non-empty while the search section (query box + "All Results") shows.
        var searchQuery = ""
        /// Blinking caret timer, alive only while the search section shows.
        private var caretTimer: Timer?
        let visibleFrame: NSRect

        init(screenFrame: NSRect) {
            visibleFrame = screenFrame
            let width = PrefsStore.panelWidth
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: PrefsStore.panelWidth, height: 120))

            stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.edgeInsets = NSEdgeInsets(top: SwitcherPanelController.inset, left: SwitcherPanelController.inset,
                                            bottom: SwitcherPanelController.inset, right: SwitcherPanelController.inset)
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            panel.contentView = effect
            // Center on the owning screen (visibleFrame excludes dock/menu bar).
            let vf = screenFrame
            var f = panel.frame
            f.origin.x = vf.midX - f.width / 2
            f.origin.y = vf.midY - f.height / 2
            panel.setFrame(f, display: false)
            applyTheme()
        }

        /// Styles appearance + material from the persisted theme (Phase 5).
        func applyTheme() {
            let (appearance, material) = PrefsStore.appearance(for: PrefsStore.theme)
            panel.appearance = NSAppearance(named: appearance)
            effect.material = material
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            rowViews.forEach { $0.applyIndicator() }
        }

        func rebuild(globalBase: Int) {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            caretTimer?.invalidate()
            caretTimer = nil
            // Search box sits on top (Raycast/Contexts layout), rows below.
            let searchHeight = searchQuery.isEmpty ? 0 : buildSearchSection()
            var headerCount = 0
            rowViews = rows.enumerated().map { off, wm in
                if let title = headers[globalBase + off] { addSectionHeader(title); headerCount += 1 }
                let row = PanelRowView()
                row.configure(wm, globalIndex: globalBase + off, query: searchQuery,
                              hint: off < hints.count ? hints[off] : nil)
                row.onHover = { [weak self] idx in self?.hoverCallback?(idx) }
                row.onClick = { [weak self] idx in self?.clickCallback?(idx) }
                row.onScroll = { [weak self] step in self?.scrollCallback?(step) }
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                NSLayoutConstraint.activate([
                    row.heightAnchor.constraint(equalToConstant: SwitcherPanelController.rowHeight),
                    row.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -2 * SwitcherPanelController.inset),
                ])
                return row
            }
            let height = 2 * SwitcherPanelController.inset + CGFloat(rows.count) * SwitcherPanelController.rowHeight
                + searchHeight + CGFloat(headerCount) * 21
            var f = panel.frame
            let width = PrefsStore.panelWidth
            f.size = NSSize(width: width, height: height)
            f.origin.x = visibleFrame.midX - width / 2
            f.origin.y = visibleFrame.midY - height / 2
            panel.setFrame(f, display: false)
        }

        /// Hairline divider + centered section title ("Recommended", …): 25pt.
        private func addSectionHeader(_ text: String) {
            let divider = NSView()
            divider.wantsLayer = true
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            divider.translatesAutoresizingMaskIntoConstraints = false
            for v in [divider, label] { stack.addArrangedSubview(v) }
            NSAppearance.current = panel.appearance
            defer { NSAppearance.current = nil }
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            NSLayoutConstraint.activate([
                divider.heightAnchor.constraint(equalToConstant: 1),
                divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                divider.widthAnchor.constraint(equalTo: effect.widthAnchor),
                label.heightAnchor.constraint(equalToConstant: 20),
                label.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -2 * SwitcherPanelController.inset),
            ])
        }

        /// Search section (Contexts Command-Tab): rounded query box with a
        /// blinking caret, full-width hairline divider, centered "All Results".
        /// Returns its total height.
        private func buildSearchSection() -> CGFloat {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 8
            box.layer?.borderWidth = 0
            let query = NSTextField(labelWithString: searchQuery)
            query.font = .systemFont(ofSize: 14)
            query.textColor = searchQuery.isEmpty ? .tertiaryLabelColor : .labelColor
            query.lineBreakMode = .byTruncatingHead
            query.translatesAutoresizingMaskIntoConstraints = false
            let caret = NSView()
            caret.wantsLayer = true
            caret.layer?.backgroundColor = NSColor.labelColor.cgColor
            caret.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(query)
            box.addSubview(caret)
            // Add to the stack before constraining: the box anchors reference
            // the effect view, valid only once the box shares that ancestor.
            stack.addArrangedSubview(box)
            NSLayoutConstraint.activate([
                box.heightAnchor.constraint(equalToConstant: 30),
                box.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -2 * SwitcherPanelController.inset),
                query.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
                query.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
                query.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                caret.widthAnchor.constraint(equalToConstant: 1.5),
                caret.heightAnchor.constraint(equalToConstant: 16),
                caret.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                searchQuery.isEmpty
                    ? caret.trailingAnchor.constraint(equalTo: query.leadingAnchor, constant: -2)
                    : caret.leadingAnchor.constraint(equalTo: query.trailingAnchor, constant: 2),
            ])
            stack.setCustomSpacing(4, after: box)
            NSLayoutConstraint.activate([])
            // Resolve the chrome colors against the panel's appearance, not
            // the app's (a dark panel built while the app is light-mode).
            NSAppearance.current = panel.appearance
            defer { NSAppearance.current = nil }
            box.layer?.borderColor = NSColor.separatorColor.cgColor
            box.layer?.backgroundColor = NSColor.clear.cgColor
            caretTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak caret] _ in
                caret?.isHidden.toggle()
            }
            return 30 + 4
        }

        var hoverCallback: ((Int) -> Void)?
        var clickCallback: ((Int) -> Void)?
        var scrollCallback: ((Int) -> Void)?

        func setHighlight(localIndex: Int?, globalForLog: Int) {
            for (i, row) in rowViews.enumerated() {
                row.setHighlighted(i == localIndex)
            }
        }

        func orderFront() { panel.orderFrontRegardless() }
        func orderOut() {
            caretTimer?.invalidate()
            caretTimer = nil
            panel.orderOut(nil)
        }
    }

    private var screenPanels: [ScreenPanel] = []
    /// Flattened addressing: global selection index → (panel, local row).
    private var index: [(panel: Int, row: Int)] = []
    private(set) var rows: [WindowModel] = []
    private(set) var selection = 0
    /// Quick-go letter per global row index (unique across the list).
    private var hintByIndex: [Character?] = []

    /// Global index of the row whose quick-go letter is `ch`.
    func indexForHint(_ ch: Character) -> Int? {
        hintByIndex.firstIndex { $0 == ch }
    }

    /// Unique letter per row: first free letter of the app name, then any
    /// free letter of the title, then any free letter at all.
    static func assignHints(_ models: [WindowModel]) -> [Character?] {
        models.map { $0.appLocalName.lowercased().first { $0.isLetter } }
    }

    var onCommit: ((WindowModel) -> Void)?

    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 4
    static let inset: CGFloat = 8
    /// Hard cap independent of the user pref (prefs min is 3, UI max 16).
    private static let hardRowCap = 16

    var isVisible: Bool { screenPanels.contains(where: { $0.panel.isVisible }) }
    var selectedModel: WindowModel? {
        guard index.indices.contains(selection) else { return nil }
        return screenPanels[index[selection].panel].rows[index[selection].row]
    }

    init() {}

    /// Splits rows across displays by frame intersection (minimized/offscreen →
    /// primary screen), one overlay per NSScreen, each centered on its screen.
    /// Re-skins open panels after a theme change (prefs live-apply).
    func applyTheme() {
        screenPanels.forEach {
            $0.applyTheme()
            $0.rowViews.forEach { $0.applyIndicator() }
        }
    }

    /// Hover moves selection (pref-gated; also the scroll-wheel path).
    private func hoverSelect(_ globalIdx: Int) {
        guard PrefsStore.hoverSelects, index.indices.contains(globalIdx) else { return }
        setSelection(globalIdx)
    }

    /// Click commits immediately (Contexts: click a row → activate it).
    private func clickCommit(_ globalIdx: Int) {
        guard index.indices.contains(globalIdx) else { return }
        setSelection(globalIdx)
        if let wm = selectedModel { onCommit?(wm) }
    }

    func show(_ models: [WindowModel], query: String = "", headers: [Int: String] = [:]) {
        // Kill previous overlays BEFORE replacing the array — otherwise every
        // open() leaks an NSPanel on screen that nothing can ever dismiss.
        screenPanels.forEach { $0.orderOut() }
        rows = Array(models.prefix(min(Self.hardRowCap, PrefsStore.maxRows)))
        selection = 0
        index = []

        // Panel display scope: all displays / primary only / active display
        // (the screen currently holding the mouse, Contexts behavior).
        let allScreens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        let screens: [NSScreen]
        switch PrefsStore.panelDisplay {
        case .all: screens = allScreens
        case .primary: screens = [allScreens.first { $0.frame.origin == .zero } ?? allScreens[0]]
        case .active:
            let mouse = NSEvent.mouseLocation
            screens = [allScreens.first { $0.frame.contains(mouse) } ?? allScreens[0]]
        }
        // Hints follow the display-split order (rows are flattened by panel).
        var assigned: [[WindowModel]] = Array(repeating: [], count: screens.count)
        for wm in rows {
            let sIdx = screens.firstIndex(where: { $0.frame.intersects(wm.frame) }) ?? 0
            assigned[sIdx].append(wm)
        }
        let hints = Self.assignHints(assigned.flatMap { $0 })
        hintByIndex = hints
        screenPanels = zip(screens, assigned).map { ScreenPanel(screenFrame: $0.0.visibleFrame) }
        for (pi, sp) in screenPanels.enumerated() {
            sp.hoverCallback = { [weak self] idx in self?.hoverSelect(idx) }
            sp.clickCallback = { [weak self] idx in self?.clickCommit(idx) }
            sp.scrollCallback = { [weak self] step in self?.moveSelection(step) }
            sp.rows = assigned[pi]
            sp.headers = headers
            let base = assigned.prefix(pi).reduce(0) { $0 + $1.count }
            sp.hints = Array(hints[base..<(base + assigned[pi].count)])
            sp.searchQuery = query
            sp.rebuild(globalBase: assigned.prefix(pi).reduce(0) { $0 + $1.count })
            for ri in 0..<assigned[pi].count {
                index.append((panel: pi, row: ri))
            }
            sp.orderFront()
        }
        applyHighlight()
    }

    struct Geometry: CustomStringConvertible {
        let screen: CGRect, panel: CGRect, rowCount: Int
        var description: String { "screen=\(screen) panel=\(panel) rows=\(rowCount)" }
    }

    /// Verification surface: per-display panel geometry vs its screen.
    var geometryReport: [Geometry] {
        screenPanels.map { Geometry(screen: $0.visibleFrame, panel: $0.panel.frame, rowCount: $0.rows.count) }
    }

    func hide() {
        screenPanels.forEach { $0.orderOut() }
    }

    /// `skipIgnored`: Tab-style cycling stays inside the rotation; arrows,
    /// digits, hover and click can still reach ignored rows.
    func moveSelection(_ delta: Int, skipIgnored: Bool = false) {
        guard !index.isEmpty else { return }
        let n = index.count
        let step = delta < 0 ? -1 : 1
        var next = (selection + delta + n) % n
        if skipIgnored {
            var tries = 0
            while model(at: next)?.ignored == true, tries < n {
                next = (next + step + n) % n
                tries += 1
            }
            if model(at: next)?.ignored == true { return } // nothing in rotation
        }
        setSelection(next)
    }

    func model(at globalIdx: Int) -> WindowModel? {
        guard index.indices.contains(globalIdx) else { return nil }
        return screenPanels[index[globalIdx].panel].rows[index[globalIdx].row]
    }

    func setSelection(_ globalIdx: Int) {
        guard index.indices.contains(globalIdx) else { return }
        selection = globalIdx
        applyHighlight()
        if let wm = selectedModel {
            print("panel: selection=\(selection) [\(wm.appLocalName)] \"\(wm.title)\"")
        }
    }

    private func applyHighlight() {
        for (pi, sp) in screenPanels.enumerated() {
            let local = index.indices.contains(selection) && index[selection].panel == pi ? index[selection].row : nil
            sp.setHighlight(localIndex: local, globalForLog: selection)
        }
    }
}


// MARK: - Session (control layer)

/// Owns the switcher state machine: hotkey → panel open/cycle, arrow/enter/esc/
/// digit routing through the global tap interceptor, commit → activation.
final class SwitcherSession {
    static let shared = SwitcherSession()

    private let panel = SwitcherPanelController()
    private(set) var isOpen = false
    private var searchQuery = ""
    /// Remembered queries (Search Shortcuts), newest first, capped by depth.
    private var searchMemory: [String] = []
    /// query → window last committed for it (pid + title).
    private var lastSelected: [String: (pid: pid_t, title: String)] = [:]
    private var topIsRemembered = false

    /// Section headers for the current query (global row index → title).
    private func sectionHeaders(rowCount: Int) -> [Int: String] {
        guard !searchQuery.isEmpty, rowCount > 0 else { return [:] }
        if topIsRemembered {
            var h: [Int: String] = [0: "Last Selected for '\(searchQuery)…'"]
            if rowCount > 1 { h[1] = "Other Results" }
            return h
        }
        if searchQuery.count == 1 {
            var h: [Int: String] = [0: "Recommended"]
            if rowCount > 1 { h[1] = "Other Results" }
            return h
        }
        return [0: "All Results"]
    }
    /// Hold-to-switch: side-mask bits of the trigger's modifiers while the
    /// trigger is being held; nil when no hold is in progress.
    private var holdSideBits: UInt32?
    /// The shortcut that opened the panel: its combo cycles forward while
    /// held, and its siblings' move-up combos cycle back (Contexts pairing).
    private var activeTrigger: PrefsStore.TriggerShortcut?
    /// Pending delayed-open task ("show panel after a slight delay").
    private var openTask: DispatchWorkItem?
    /// Hold-Q: pending timer while Q is down; fires closeWindow on the
    /// selected row. `qHoldFired` swallows the rest of that press.
    private var qHold: DispatchWorkItem?
    private var qHoldFired = false
    private static let qHoldDelay: TimeInterval = 0.4
    /// Hold-i ignores (or un-ignores) the selected window; a tap types "i".
    private var iHold: DispatchWorkItem?
    private var iHoldFired = false
    /// Hold-h shows/hides ignored windows for this session.
    private var hHold: DispatchWorkItem?
    private var hHoldFired = false
    /// Last committed window — the quick double-press re-targets it.
    private var lastCommittedModel: WindowModel?
    /// Verification surface for per-display panel placement (Phase 4).
    var panelGeometry: [SwitcherPanelController.Geometry] { panel.geometryReport }
    private(set) var lastCommittedPid: pid_t?

    private init() {
        WindowTracker.shared.start()
        WindowTracker.shared.addChangeHandler("session") { [weak self] in self?.refreshRowsIfOpen() }
        panel.onCommit = { [weak self] wm in
            print("panel: commit → [\(wm.appLocalName)] \"\(wm.title)\"")
            activateAndVerify(wm)
            // Click-commit arrives with the panel still open → dismiss it.
            // close(commit:) calls this after setting isOpen = false, so no
            // re-entry happens on that path.
            if let self, self.isOpen { self.close(commit: false) }
        }
        HotkeyCenter.shared.interceptor = { [weak self] event in
            guard let self, self.isOpen else { return false }
            return self.routeKey(event)
        }
        HotkeyCenter.shared.keyUpHandler = { [weak self] event in
            guard let self else { return false }
            return self.routeKeyUp(event)
        }
        HotkeyCenter.shared.flagsChangedHandler = { [weak self] sideMask in
            guard let self else { return }
            self.routeHoldRelease(sideMask)
        }
    }

    /// Physical key → letter (ANSI). Independent of held modifiers: with ⌥
    /// down the typed character is "å", not "a", which broke hint lookup.
    private static let letterKeycodes: [UInt32: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
        17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]

    /// Digit row → selection index (kVK_ANSI_1..9; note non-contiguous keycodes).
    private static let digitKeycodes: [UInt32: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
    ]

    /// Installs every enabled trigger shortcut as a hold-to-switch binding.
    @discardableResult
    func installShortcuts() -> Bool {
        let bindings = PrefsStore.shortcuts.filter(\.on).map { sc in
            HotkeyCenter.Binding(id: "trigger", keyCode: sc.key,
                mods: HotkeyCenter.cgFlags(fromCarbon: sc.mods)) { [weak self] event in
                self?.triggerPressed(event)
            }
        }
        // An empty set must tear down the stale tap: register() no-ops on
        // empty bindings, which would otherwise leave old triggers live.
        HotkeyCenter.shared.unregister()
        return HotkeyCenter.shared.register(bindings)
    }

    /// Demo mode: one synthetic trigger (⌃⌥⌘W), not from prefs.
    @discardableResult
    func installDemoShortcut(key: UInt32, mods: UInt32) -> Bool {
        HotkeyCenter.shared.register([HotkeyCenter.Binding(id: "main", keyCode: key,
            mods: HotkeyCenter.cgFlags(fromCarbon: mods)) { [weak self] event in
            self?.triggerPressed(event)
        }])
    }

    /// Re-skins an open panel after a theme change (prefs live-apply).
    func applyThemeLive() {
        guard isOpen else { return }
        panel.applyTheme()
    }

    /// `selectNext`: preselect the next (previously used) window — the
    /// hold-to-switch model. Bare openings (menu, no modifiers held) keep the
    /// current window selected at row 0.
    func open(selectNext: Bool = false) {
        openTask?.cancel()
        openTask = nil
        // The tap callback must stay fast — WindowServer disables taps whose
        // callbacks run slow, silently dropping later hotkeys (the same hazard
        // commitAsync guards). Show the tracker's current model now; refresh
        // and re-render on the next main-loop turn.
        searchQuery = ""
        let showed = renderFromTracker(selectFirst: true)
        // Current window ignored → it sits below the rotation, so row 0 is
        // already the previously used window; don't step past it.
        if selectNext, !WindowTracker.shared.focusedIsIgnored { panel.moveSelection(1, skipIgnored: true) }
        print("panel: opened rows=\(panel.rows.count) query=\"\(searchQuery)\" selectNext=\(selectNext)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            WindowTracker.shared.refresh(reason: "open")
            if showed || self.isOpen { self.refreshRowsIfOpen() }
            else { self.renderFromTracker(selectFirst: true) } // rows were empty at press time
        }
    }

    /// Contexts "show panel after a slight delay": schedules instead of showing
    /// immediately; releasing the trigger before the delay elapses commits the
    /// last-used window directly (quick tap = quick switch).
    func openDelayed(selectNext: Bool = false) {
        openTask?.cancel()
        guard PrefsStore.panelShowDelay else { open(selectNext: selectNext); return }
        let task = DispatchWorkItem { [weak self] in self?.open(selectNext: selectNext) }
        openTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    /// Cancels a pending delayed open; returns true when one was cancelled.
    @discardableResult
    func cancelPendingOpen() -> Bool {
        guard let task = openTask, !task.isCancelled else { return false }
        task.cancel()
        openTask = nil
        print("panel: delayed open cancelled")
        return true
    }

    /// Hold-to-switch trigger keyDown (exact combo, e.g. ⌥Tab).
    ///
    /// The binding match itself proves the combo is down — the keyDown's own
    /// flags carry it — so the hold session arms here, never from
    /// flagsChanged ordering, which key-report races can invert.
    /// - A real second press inside the delay window commits the previous
    ///   window without ever showing the panel (quick tap).
    /// - While the panel is open (still held): advance.
    /// - Otherwise: open after the delay, previous window preselected.
    private func triggerPressed(_ event: CGEvent) {
        let kc = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let carbon = HotkeyCenter.carbonFlags(fromCG: event.flags.intersection(HotkeyCenter.modifierBitsPublic))
        if TapLog.on { TapLog.log("triggerPressed kc=\(kc) carbon=0x\(String(carbon, radix: 16)) isOpen=\(isOpen)") }
        activeTrigger = PrefsStore.shortcuts.first { $0.on && $0.key == kc && $0.mods == carbon }
            ?? PrefsStore.shortcuts.first(where: { $0.on })
        holdSideBits = HotkeyCenter.sideBits(fromCarbon: activeTrigger?.mods ?? 0)
        if isOpen {
            panel.moveSelection(1, skipIgnored: true)
            return
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            // Held Tab without releasing: the first press already scheduled
            // the open. Never slide the delay window — a held Tab would
            // otherwise never open the panel.
            if openTask == nil { openDelayed(selectNext: true) }
            return
        }
        if cancelPendingOpen() {
            openInstantCommit()   // real quick double-press
            return
        }
        openDelayed(selectNext: true)
    }

    /// Hold-to-switch release: when the trigger's last modifier goes up while
    /// the panel is open, commit the selected window. A release before the
    /// delayed open fired is a quick tap → commit the previous window.
    private func routeHoldRelease(_ sideMask: UInt32) {
        if TapLog.on {
            TapLog.log("routeHoldRelease sideMask=0x\(String(sideMask, radix: 16)) holdSideBits=\(holdSideBits.map { String($0, radix: 16) } ?? "nil")")
        }
        guard let bits = holdSideBits, sideMask & bits == 0 else { return }
        holdSideBits = nil
        if isOpen {
            print("panel: released trigger — committing selection")
            close(commit: true)
        } else if openTask != nil {
            openInstantCommit()
        }
    }

    // Verification hooks (Phase 6 demos): query/rows surface without synthetic CGEvents.
    var panelRows: [WindowModel] { panel.rows }
    func openForTest() { open() }
    func typeForTest(_ s: String) {
        searchQuery += s
        applyQuery()
    }

    /// Current tracker model after all Rules/Search filters, focused app first.
    private func trackerRows() -> [WindowModel] {
        var rows = WindowTracker.shared.windows.filter { !$0.title.isEmpty }
        // Apps scope (Rules pane): all running apps vs active app only.
        if !PrefsStore.appsOfAll {
            let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
            rows = rows.filter { $0.pid == active }
        }
        // Search: substring, or fuzzy subsequence when "allow mismatch" is on.
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Focused app's windows first, AX order preserved within each app.
        let front = rows.filter { $0.pid == frontPid }
        let rest = rows.filter { $0.pid != frontPid }
        if PrefsStore.orderByRecency {
            // Per-window MRU; never-focused windows keep tracker order after
            // the known ones (stable: offset breaks ties).
            let recency = WindowTracker.shared.windowRecency
            var rankOf: [String: Int] = [:]
            for (i, k) in recency.enumerated() { rankOf[k] = i }
            rows = rows.enumerated()
                .sorted { (rankOf[$0.element.key] ?? Int.max, $0.offset) < (rankOf[$1.element.key] ?? Int.max, $1.offset) }
                .map(\.element)
        } else {
            rows = front + rest
        }
        // Ignored windows sink below the rotation (stable partition).
        rows = rows.filter { !$0.ignored } + rows.filter(\.ignored)
        topIsRemembered = false
        guard !searchQuery.isEmpty else { return rows }
        // Search ranks, never filters (Contexts): best match first, stable.
        let q = searchQuery
        var ranked = rows.enumerated().map { (i: $0.offset, wm: $0.element,
            sc: SearchText.score(app: $0.element.appLocalName, title: $0.element.displayTitle, query: q)) }
        ranked.sort { $0.sc != $1.sc ? $0.sc > $1.sc : $0.i < $1.i }
        rows = ranked.map(\.wm)
        // "Last Selected for 'q…'": the window committed last time for this query.
        if PrefsStore.searchShortcutsDepth > 0, searchMemory.contains(q),
           let mem = lastSelected[q],
           let idx = rows.firstIndex(where: { $0.pid == mem.pid && $0.title == mem.title }) {
            rows.insert(rows.remove(at: idx), at: 0)
            topIsRemembered = true
        }
        return rows
    }

    /// Renders rows straight from the tracker's current model (no re-enumeration —
    /// the tracker already refreshed; re-refreshing here recurses infinitely).
    @discardableResult
    private func renderFromTracker(selectFirst: Bool) -> Bool {
        let rows = trackerRows()
        // Search left zero matches: keep the panel open showing only the
        // search section (Contexts behavior) instead of tearing it down.
        if rows.isEmpty, !searchQuery.isEmpty {
            isOpen = true
            panel.show([], query: searchQuery)
            return false
        }
        guard !rows.isEmpty else {
            print("panel: no windows to show")
            return false
        }
        isOpen = true
        var headers = sectionHeaders(rowCount: rows.count)
        // "Ignored" section: below the rotation, after the last normal row.
        if let firstIgnored = rows.firstIndex(where: \.ignored), headers[firstIgnored] == nil {
            headers[firstIgnored] = "Ignored"
        }
        panel.show(rows, query: searchQuery, headers: headers)
        if selectFirst { panel.setSelection(0) }
        return true
    }

    /// Quick double-press while the delayed open is still pending: switch
    /// straight to the previous window without ever showing the panel
    /// (Contexts "slight delay" behavior).
    func openInstantCommit() {
        openTask?.cancel()
        openTask = nil
        holdSideBits = nil
        searchQuery = ""
        // Deferred off the tap callback. No refresh here: the tracker model is
        // observer-maintained and the commit targets row 1 of the CURRENT model
        // — the synchronous sweep this used to run blocked main for seconds on
        // busy apps (observed ~2 s activating busy Chrome), starving the event
        // tap so later hotkey events were silently dropped.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let rows = self.trackerRows()
            // Rotation only: skip ignored rows; if the current window is itself
            // ignored, row 0 is already the previously used window.
            let rotation = rows.filter { !$0.ignored }
            let skipCurrent = !WindowTracker.shared.focusedIsIgnored
            guard let target = (skipCurrent ? rotation.dropFirst().first : rotation.first) ?? rotation.first else { return }
            WindowTracker.shared.commitFocus(target)
            self.lastCommittedPid = target.pid
            self.lastCommittedModel = target
            self.panel.onCommit?(target)
            print("panel: instant commit → [\(target.appLocalName)] \"\(target.title)\"")
        }
    }

    /// Commits off the tap callback: activate() polls for up to seconds and
    /// WindowServer disables taps whose callbacks run slow — which would kill
    /// every later hotkey delivery. The panel is already hidden when this
    /// runs; only the activation is deferred.
    private func commitAsync(_ target: WindowModel) {
        WindowTracker.shared.commitFocus(target)
        lastCommittedPid = target.pid
        lastCommittedModel = target
        DispatchQueue.main.async { [weak self] in
            self?.panel.onCommit?(target)
        }
    }

    /// Tracker change while panel is open: rebuild rows, keep selection pinned
    /// to the same pid+title when that window still exists.
    private func refreshRowsIfOpen() {
        guard isOpen else { return }
        let pinned = panel.selectedModel
        renderFromTracker(selectFirst: false)
        if let pinned,
           let idx = panel.rows.firstIndex(where: { $0.pid == pinned.pid && $0.title == pinned.title }) {
            panel.setSelection(idx)
        }
        print("panel: refreshed rows=\(panel.rows.count) selection=\(panel.selection)")
    }

    func close(commit: Bool) {
        if TapLog.on { TapLog.log("close(commit=\(commit)) isOpen=\(isOpen) selection=\(panel.selection)") }
        openTask?.cancel()
        openTask = nil
        qHold?.cancel()
        qHold = nil
        iHold?.cancel()
        iHold = nil
        iHoldFired = false
        hHold?.cancel()
        hHold = nil
        hHoldFired = false
        let target = panel.selectedModel
        isOpen = false
        panel.hide()
        // Search Shortcuts: remember the query (newest first, depth-capped).
        if PrefsStore.searchShortcutsDepth > 0, !searchQuery.isEmpty {
            searchMemory.removeAll { $0 == searchQuery }
            searchMemory.insert(searchQuery, at: 0)
            while searchMemory.count > PrefsStore.searchShortcutsDepth { searchMemory.removeLast() }
        }
        if commit, !searchQuery.isEmpty, let t = target { lastSelected[searchQuery] = (t.pid, t.title) }
        // Forget picks for queries that fell out of the remembered set.
        lastSelected = lastSelected.filter { searchMemory.contains($0.key) }
        holdSideBits = nil
        activeTrigger = nil
        searchQuery = ""
        print("panel: closed(\(commit ? "commit" : "cancel"))")
        if commit, let target {
            commitAsync(target)
        }
    }

    private func routeKey(_ event: CGEvent) -> Bool {
        let kc = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        // Hold-Q: swallow Q's autorepeat; any other key while Q is still
        // pending means it was a fast tap (rollover) → type the "q" first.
        if kc == UInt32(kVK_ANSI_Q), qHold != nil || qHoldFired {
            return true
        }
        if qHold != nil { flushPendingQ() }
        if kc == UInt32(kVK_ANSI_I), iHold != nil || iHoldFired { return true }
        if iHold != nil { flushPendingI() }
        if kc == UInt32(kVK_ANSI_H), hHold != nil || hHoldFired { return true }
        if hHold != nil { flushPendingH() }
        // In-panel action keys: modifier+letter acts on the selected row — only
        // before a query starts, so typing words never hides/quits an app.
        if searchQuery.isEmpty, let acted = Self.actionKey(of: event, mods: PrefsStore.actionQuitMods, letter: "q") {
            if acted { actOnSelected(.quitApp) }
            return acted
        }
        if searchQuery.isEmpty, let acted = Self.actionKey(of: event, mods: PrefsStore.actionCloseWinMods, letter: "k") {
            if acted { actOnSelected(.closeWindow) }
            return acted
        }
        if searchQuery.isEmpty, let acted = Self.actionKey(of: event, mods: PrefsStore.actionMinimizeMods, letter: "m") {
            if acted { actOnSelected(.minimize) }
            return acted
        }
        if searchQuery.isEmpty, let acted = Self.actionKey(of: event, mods: PrefsStore.actionHideMods, letter: "h") {
            if acted { actOnSelected(.hide) }
            return acted
        }
        // Contexts move-up pairing: while the panel is open, any enabled
        // shortcut's move-up combo cycles back (e.g. ⌘` while holding ⌘Tab,
        // or a recorded ⌃Tab arriving as ⌘⌃Tab under a ⌘Tab hold). The
        // event's flags carry every physically held modifier, so match the
        // recorded combo as a subset of the held set; a bare Tab (no
        // modifiers) can never match a nonempty recorded combo, so plain
        // hold-to-switch advancing is untouched.
        // Consumed here so it can never reach its own trigger binding.
        let eventMods = HotkeyCenter.carbonFlags(fromCG: event.flags.intersection(HotkeyCenter.modifierBitsPublic))
        // Only the opening trigger's own move-up pairs while it is held —
        // otherwise a sibling's move-up equal to this trigger's activate combo
        // (⌘` up = ⌘Tab) would make the forward key move back.
        let upCandidates = activeTrigger.map { [$0] } ?? PrefsStore.shortcuts.filter(\.on)
        for sc in upCandidates where sc.upMods != 0 {
            if kc == sc.upKey, eventMods & sc.upMods == sc.upMods {
                panel.moveSelection(-1, skipIgnored: true)
                return true
            }
        }
        switch kc {
        case UInt32(kVK_Tab):
            // Hold-to-switch cycling: bare Tab advances, Shift+Tab goes back.
            // Arm the hold session when modifiers are down but no trigger
            // press armed it (menu-opened panel, or a key-report race) — the
            // release must always have a commit path.
            if holdSideBits == nil {
                let carbon = HotkeyCenter.carbonFlags(fromCG: event.flags.intersection(HotkeyCenter.modifierBitsPublic))
                if carbon != 0 { holdSideBits = HotkeyCenter.sideBits(fromCarbon: carbon) }
            }
            let back = event.flags.intersection(HotkeyCenter.modifierBitsPublic).contains(.maskShift)
            panel.moveSelection(back ? -1 : 1, skipIgnored: true)
        case UInt32(kVK_UpArrow):
            panel.moveSelection(-1)
        case UInt32(kVK_DownArrow):
            panel.moveSelection(1)
        case UInt32(kVK_Return):
            close(commit: true)
        case UInt32(kVK_Escape), UInt32(kVK_LeftArrow):
            close(commit: false)
        case UInt32(kVK_Delete):
            guard searchQuery.isEmpty == false else { return false }
            searchQuery.removeLast()
            applyQuery()
        default:
            if let idx = Self.digitKeycodes[kc] {
                // Digit N selects row N (the "Numbers 1–9" gutter).
                guard idx < panel.rows.count else { return true }
                panel.setSelection(idx)
            } else if kc == UInt32(kVK_ANSI_H), searchQuery.isEmpty,
                      PrefsStore.typingStartsFastSearch,
                      Self.searchEligibleFlags(event.flags) {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isOpen, self.hHold != nil else { return }
                    self.hHold = nil
                    self.hHoldFired = true
                    PrefsStore.sessionShowIgnored = !PrefsStore.showIgnoredNow
                    print("panel: show ignored (session) = \(PrefsStore.showIgnoredNow)")
                    WindowTracker.shared.refresh(reason: "session-show-ignored")
                }
                hHold = work
                hHoldFired = false
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.qHoldDelay, execute: work)
            } else if kc == UInt32(kVK_ANSI_I), searchQuery.isEmpty,
                      PrefsStore.typingStartsFastSearch,
                      Self.searchEligibleFlags(event.flags) {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isOpen, self.iHold != nil else { return }
                    self.iHold = nil
                    self.iHoldFired = true
                    self.toggleIgnoreSelected()
                }
                iHold = work
                iHoldFired = false
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.qHoldDelay, execute: work)
            } else if kc == UInt32(kVK_ANSI_Q), searchQuery.isEmpty,
                      PrefsStore.typingStartsFastSearch,
                      Self.searchEligibleFlags(event.flags) {
                // Hold Q closes the selected window; a tap still types "q"
                // (on keyUp, or when the next key arrives).
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isOpen, self.qHold != nil else { return }
                    self.qHold = nil
                    self.qHoldFired = true
                    self.actOnSelected(.closeWindow)
                }
                qHold = work
                qHoldFired = false
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.qHoldDelay, execute: work)
            } else if let ch = Self.letterKeycodes[kc].map({ String($0) }) ?? (kc == 49 && !searchQuery.isEmpty ? " " : nil),
                      PrefsStore.typingStartsFastSearch,
                      Self.searchEligibleFlags(event.flags) {
                // Every letter types into the search; commit is Enter / release.
                searchQuery.append(ch)
                applyQuery()
            } else {
                return false
            }
        }
        return true
    }

    /// Q released: before the hold delay it was a tap → type "q"; after it
    /// fired, swallow the release.
    private func routeKeyUp(_ event: CGEvent) -> Bool {
        let kc = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        if kc == UInt32(kVK_ANSI_H) {
            if hHold != nil { flushPendingH(); return true }
            if hHoldFired { hHoldFired = false; return true }
            return false
        }
        if kc == UInt32(kVK_ANSI_I) {
            if iHold != nil { flushPendingI(); return true }
            if iHoldFired { iHoldFired = false; return true }
            return false
        }
        guard kc == UInt32(kVK_ANSI_Q) else { return false }
        if qHold != nil {
            flushPendingQ()
            return true
        }
        if qHoldFired {
            qHoldFired = false
            return true
        }
        return false
    }

    private func flushPendingH() {
        hHold?.cancel()
        hHold = nil
        guard isOpen else { return }
        searchQuery.append("h")
        applyQuery()
    }

    private func flushPendingI() {
        iHold?.cancel()
        iHold = nil
        guard isOpen else { return }
        searchQuery.append("i")
        applyQuery()
    }

    /// Adds the selected window to Rules → Apps to not show (exact title under
    /// its app), or removes that rule when it is already ignored.
    private func toggleIgnoreSelected() {
        guard let target = panel.selectedModel,
              PrefsStore.toggleIgnore(bundleId: target.bundleId, title: target.title) else { return }
        print("panel: ignore toggled → [\(target.appLocalName)] \"\(target.title)\"")
        WindowTracker.shared.refresh(reason: "ignore")
    }

    /// Resolve a pending Q press as a tap: cancel the hold timer, type "q".
    private func flushPendingQ() {
        qHold?.cancel()
        qHold = nil
        guard isOpen else { return }
        searchQuery.append("q")
        applyQuery()
    }

    /// Matches one in-panel action: modifiers exactly equal the configured
    /// mask and the key is its letter. Returns nil when not this action's
    /// modifiers at all (keep routing), true/false when it is (consume/ignore).
    private static func actionKey(of event: CGEvent, mods: UInt32, letter: Character) -> Bool? {
        let carbon = HotkeyCenter.carbonFlags(fromCG: event.flags.intersection(HotkeyCenter.modifierBitsPublic))
        guard carbon != 0 else { return nil }
        guard carbon == mods else { return nil }
        // Not this action's letter → keep routing (quick-go / search), never
        // swallow: with ⌥ held every other letter used to die here.
        let kc = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        guard letterKeycodes[kc] == letter else { return nil }
        return true
    }

    /// A plain key starts in-panel search when the only modifiers held are
    /// the trigger's own (⌘/⌥ hold-to-switch keeps them down) plus Shift.
    /// Command or Option paired with Control route to action keys instead.
    private static func searchEligibleFlags(_ flags: CGEventFlags) -> Bool {
        let m = flags.intersection(HotkeyCenter.modifierBitsPublic)
        let cmdHold = m.subtracting(.maskCommand).subtracting(.maskShift).subtracting(.maskAlphaShift).isEmpty
        let optHold = m.subtracting(.maskAlternate).subtracting(.maskShift).subtracting(.maskAlphaShift).isEmpty
        return cmdHold || optHold
    }

    private enum RowAction { case quitApp, closeWindow, minimize, hide }

    private func actOnSelected(_ action: RowAction) {
        guard let target = panel.selectedModel else { return }
        switch action {
        case .quitApp:    quitApp(target)
        case .closeWindow: closeWindow(target)
        case .minimize:   minimizeWindow(target)
        case .hide:       hideApp(target)
        }
        print("panel: action \(action) → [\(target.appLocalName)] \"\(target.title)\"")
        // Re-render after the effect lands (row usually disappears).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isOpen else { return }
            WindowTracker.shared.refresh(reason: "action")
            self.refreshRowsIfOpen()
        }
    }

    private func applyQuery() {
        renderFromTracker(selectFirst: true)
        print("panel: query=\"\(searchQuery)\" rows=\(panel.rows.count)")
    }

    /// Typed character for a key event (CGEventKeyboardGetUnicodeString).
    private static func character(of event: CGEvent) -> String? {
        var len: Int = 0
        var chars = [UInt16](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return nil }
        return String(decoding: chars.prefix(Int(len)), as: UTF16.self)
    }
}
