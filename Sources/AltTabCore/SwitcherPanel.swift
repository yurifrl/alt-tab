import AppKit
import Carbon.HIToolbox

// MARK: - Panel UI (Phase 2 — Switcher panel v1)

/// Case-insensitive match helpers shared by the session filter (row inclusion)
/// and the row renderer (per-character highlight ranges).
enum SearchText {
    /// UTF-16 positions of each query character in a fuzzy subsequence match
    /// over `text`, or nil when the query is not a subsequence of it.
    static func positions(in text: String, query: String) -> [Range<Int>]? {
        let t = Array(text.lowercased().utf16)
        let q = Array(query.lowercased().utf16)
        guard !q.isEmpty, !t.isEmpty else { return nil }
        var out: [Range<Int>] = []
        var ti = 0
        for qc in q {
            guard let hit = t[ti...].firstIndex(of: qc) else { return nil }
            out.append(hit..<(hit + 1))
            ti = hit + 1
        }
        return out
    }

    static func isMatch(_ text: String, query: String) -> Bool {
        positions(in: text, query: query) != nil
    }
}

/// One row, Contexts Command-Tab cell style: hint gutter | right-aligned app
/// name | icon | window title. Matched query characters render in orange.
final class PanelRowView: NSView {
    private let hint = NSTextField(labelWithString: "")
    private let appName = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    /// Title text + match ranges for recoloring on highlight toggle.
    private var titleText = ""
    private var titleMatches: [Range<Int>]?
    /// Click target ownership: session checks `isHoverSelectable` on hit-test.
    private(set) var globalIndex: Int = -1
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        addTrackingArea(NSTrackingArea(
            rect: .infinite, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
        for view in [hint, appName, iconView, title] { addSubview(view) }
        hint.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hint.alignment = .center
        appName.font = .systemFont(ofSize: 13)
        appName.alignment = .right
        appName.cell?.truncatesLastVisibleLine = true
        title.font = .systemFont(ofSize: 13)
        title.cell?.truncatesLastVisibleLine = true
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// Columns (Contexts Command-Tab): hint gutter 10–26, app name right edge
    /// at 196, icon 204–224, title from 230 to the row's right edge − 8.
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        hint.frame = NSRect(x: 10, y: 0, width: 16, height: h)
        appName.frame = NSRect(x: 30, y: 0, width: 166, height: h)
        iconView.frame = NSRect(x: 204, y: (h - 20) / 2, width: 20, height: 20)
        title.frame = NSRect(x: 230, y: 0, width: w - 238, height: h)
    }

    override func mouseEntered(with event: NSEvent) {
        guard PrefsStore.hoverSelects, globalIndex >= 0 else { return }
        onHover?(globalIndex)
    }

    override func mouseDown(with event: NSEvent) {
        guard globalIndex >= 0 else { return }
        onClick?(globalIndex)
    }

    override func scrollWheel(with event: NSEvent) {
        guard PrefsStore.scrollSelects, abs(event.deltaY) > 0.4 else { return }
        onHover?(globalIndex + (event.deltaY < 0 ? -1 : 1))
    }

    func configure(_ wm: WindowModel, globalIndex idx: Int = -1, query: String = "") {
        globalIndex = idx
        iconView.image = NSRunningApplication(processIdentifier: wm.pid)?.icon
        appName.stringValue = wm.appLocalName
        var text = wm.title
        if wm.minimized { text += "  (minimized)" }
        titleText = text
        titleMatches = query.isEmpty ? nil : SearchText.positions(in: text, query: query)
        alphaValue = wm.minimized ? 0.55 : 1.0
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
            hint.stringValue = appName.stringValue.first.map { String($0).lowercased() } ?? ""
            hint.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        case .neither:
            hint.stringValue = ""
        }
    }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        hint.textColor = on ? NSColor.white.withAlphaComponent(0.75) : NSColor.tertiaryLabelColor
        appName.textColor = on ? .white : .labelColor
        let attr = NSMutableAttributedString(string: titleText)
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor,
                          range: NSRange(location: 0, length: (titleText as NSString).length))
        for r in titleMatches ?? [] {
            attr.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                              range: NSRange(location: r.lowerBound, length: r.upperBound - r.lowerBound))
        }
        title.attributedStringValue = attr
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
            rowViews = rows.enumerated().map { off, wm in
                let row = PanelRowView()
                row.configure(wm, globalIndex: globalBase + off, query: searchQuery)
                row.onHover = { [weak self] idx in self?.hoverCallback?(idx) }
                row.onClick = { [weak self] idx in self?.clickCallback?(idx) }
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                NSLayoutConstraint.activate([
                    row.heightAnchor.constraint(equalToConstant: SwitcherPanelController.rowHeight),
                    row.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -2 * SwitcherPanelController.inset),
                ])
                return row
            }
            let searchHeight = searchQuery.isEmpty ? 0 : buildSearchSection()
            let height = 2 * SwitcherPanelController.inset + CGFloat(rows.count) * SwitcherPanelController.rowHeight
                + CGFloat(max(0, rows.count - 1)) * SwitcherPanelController.rowSpacing + searchHeight
            var f = panel.frame
            let width = PrefsStore.panelWidth
            f.size = NSSize(width: width, height: height)
            f.origin.x = visibleFrame.midX - width / 2
            f.origin.y = visibleFrame.midY - height / 2
            panel.setFrame(f, display: false)
        }

        /// Search section (Contexts Command-Tab): rounded query box with a
        /// blinking caret, full-width hairline divider, centered "All Results".
        /// Returns its total height.
        private func buildSearchSection() -> CGFloat {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 6
            box.layer?.borderWidth = 1
            let query = NSTextField(labelWithString: searchQuery)
            query.font = .systemFont(ofSize: 14)
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
                box.heightAnchor.constraint(equalToConstant: 34),
                box.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -2 * SwitcherPanelController.inset),
                query.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
                query.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                caret.widthAnchor.constraint(equalToConstant: 1.5),
                caret.heightAnchor.constraint(equalToConstant: 16),
                caret.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                caret.leadingAnchor.constraint(equalTo: query.trailingAnchor, constant: 2),
            ])
            let divider = NSView()
            divider.wantsLayer = true
            let header = NSTextField(labelWithString: "All Results")
            header.font = .systemFont(ofSize: 12)
            header.alignment = .center
            header.translatesAutoresizingMaskIntoConstraints = false
            // Add to the stack BEFORE activating cross-view constraints — an
            // anchor pair only resolves once both views share an ancestor.
            for v in [divider, header] { stack.addArrangedSubview(v) }
            stack.setCustomSpacing(6, after: box)
            stack.setCustomSpacing(0, after: divider)
            stack.setCustomSpacing(6, after: header)
            NSLayoutConstraint.activate([
                divider.heightAnchor.constraint(equalToConstant: 1),
                divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                divider.widthAnchor.constraint(equalTo: effect.widthAnchor),
                header.heightAnchor.constraint(equalToConstant: 24),
                header.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -2 * SwitcherPanelController.inset),
            ])
            // Resolve the chrome colors against the panel's appearance, not
            // the app's (a dark panel built while the app is light-mode).
            NSAppearance.current = panel.appearance
            defer { NSAppearance.current = nil }
            box.layer?.borderColor = NSColor.separatorColor.cgColor
            box.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            caretTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak caret] _ in
                caret?.isHidden.toggle()
            }
            return 34 + 6 + 1 + 24 + 6
        }

        var hoverCallback: ((Int) -> Void)?
        var clickCallback: ((Int) -> Void)?

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

    var onCommit: ((WindowModel) -> Void)?

    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 4
    static let inset: CGFloat = 10
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

    func show(_ models: [WindowModel], query: String = "") {
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
        var assigned: [[WindowModel]] = Array(repeating: [], count: screens.count)
        for wm in rows {
            let sIdx = screens.firstIndex(where: { $0.frame.intersects(wm.frame) }) ?? 0
            assigned[sIdx].append(wm)
        }
        screenPanels = zip(screens, assigned).map { ScreenPanel(screenFrame: $0.0.visibleFrame) }
        for (pi, sp) in screenPanels.enumerated() {
            sp.hoverCallback = { [weak self] idx in self?.hoverSelect(idx) }
            sp.clickCallback = { [weak self] idx in self?.clickCommit(idx) }
            sp.rows = assigned[pi]
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

    func moveSelection(_ delta: Int) {
        guard !index.isEmpty else { return }
        setSelection((selection + delta + index.count) % index.count)
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
    /// Fast Search in progress: the side-mask that started it (non-nil while
    /// the overlay-less query runs — letters append, Space commits, Esc exits).
    private var pendingSearchMods: UInt32?
    /// Remembered queries (Search Shortcuts), newest first, capped by depth.
    private var searchMemory: [String] = []
    /// Hold-to-switch: side-mask bits of the trigger's modifiers while the
    /// trigger is being held; nil when no hold is in progress.
    private var holdSideBits: UInt32?
    /// The shortcut that opened the panel: its combo cycles forward while
    /// held, and its siblings' move-up combos cycle back (Contexts pairing).
    private var activeTrigger: PrefsStore.TriggerShortcut?
    /// Pending delayed-open task ("show panel after a slight delay").
    private var openTask: DispatchWorkItem?
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
        HotkeyCenter.shared.flagsChangedHandler = { [weak self] sideMask in
            guard let self else { return }
            self.routeHoldRelease(sideMask)
        }
        HotkeyCenter.shared.rawKeyHandler = { [weak self] event, sideMask in
            guard let self else { return false }
            return self.routeGlobalKey(event, sideMask: sideMask)
        }
    }

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
        searchQuery = PrefsStore.searchShortcutsDepth > 0 ? (searchMemory.first ?? "") : ""
        let showed = renderFromTracker(selectFirst: true)
        if selectNext { panel.moveSelection(1) }
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
            panel.moveSelection(1)
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
        if !searchQuery.isEmpty {
            rows = rows.filter { searchMatches($0) }
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Focused app's windows first, AX order preserved within each app.
        let front = rows.filter { $0.pid == frontPid }
        let rest = rows.filter { $0.pid != frontPid }
        return front + rest
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
        panel.show(rows, query: searchQuery)
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
            guard let target = rows.dropFirst().first ?? rows.first else { return }
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
        lastCommittedPid = target.pid
        lastCommittedModel = target
        DispatchQueue.main.async { [weak self] in
            self?.panel.onCommit?(target)
        }
    }

    /// Substring or fuzzy subsequence (case-insensitive) over title and app
    /// name, gated by the "allow mismatch" search pref. Shared with the row
    /// renderer so highlight positions come from the identical scan.
    private func searchMatches(_ wm: WindowModel) -> Bool {
        let targets = [wm.title, wm.appLocalName]
        if PrefsStore.searchAllowMismatch {
            // Fuzzy: every query char appears in order (subsequence match).
            return targets.contains { SearchText.isMatch($0, query: searchQuery) }
        }
        return targets.contains {
            $0.localizedCaseInsensitiveContains(searchQuery)
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
        let target = panel.selectedModel
        isOpen = false
        panel.hide()
        // Search Shortcuts: remember the query (newest first, depth-capped).
        if PrefsStore.searchShortcutsDepth > 0, !searchQuery.isEmpty {
            searchMemory.removeAll { $0 == searchQuery }
            searchMemory.insert(searchQuery, at: 0)
            while searchMemory.count > PrefsStore.searchShortcutsDepth { searchMemory.removeLast() }
        }
        pendingSearchMods = nil
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
        // Fast Search (Panel pane): letters keep filtering, Space commits,
        // Esc exits the overlay-less mode.
        if let mods = pendingSearchMods {
            if event.flags.intersection(HotkeyCenter.modifierBitsPublic).isEmpty {
                switch Self.character(of: event)?.lowercased() {
                case " ":  close(commit: true); return true
                case "\u{1b}":  pendingSearchMods = nil; searchQuery = ""; print("fast-search: exited"); return true
                case .some(let ch) where ch.count == 1 && ch.first!.isLetter:
                    searchQuery.append(ch); applyQuery(); return true
                default: return false
                }
            }
            pendingSearchMods = mods   // keep-alive while modifiers held
        }
        // In-panel action keys: modifier+letter acts on the selected row.
        if let acted = Self.actionKey(of: event, mods: PrefsStore.actionQuitMods, letter: "q") {
            if acted { actOnSelected(.quitApp) }
            return acted
        }
        if let acted = Self.actionKey(of: event, mods: PrefsStore.actionCloseWinMods, letter: "k") {
            if acted { actOnSelected(.closeWindow) }
            return acted
        }
        if let acted = Self.actionKey(of: event, mods: PrefsStore.actionMinimizeMods, letter: "m") {
            if acted { actOnSelected(.minimize) }
            return acted
        }
        if let acted = Self.actionKey(of: event, mods: PrefsStore.actionHideMods, letter: "h") {
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
        for sc in PrefsStore.shortcuts where sc.on && sc.upMods != 0 {
            if kc == sc.upKey, eventMods & sc.upMods == sc.upMods {
                panel.moveSelection(-1)
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
            panel.moveSelection(back ? -1 : 1)
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
                // Number switcher parity: flagless digit commits instantly; a
                // digit pressed with any configured Number-switch modifier
                // side also commits (Contexts "switch numbers with").
                let sides = HotkeyCenter.shared.sideMask
                if (event.flags.isEmpty || (sides != 0 && sides & PrefsStore.numberSideMask != 0))
                    && PrefsStore.numberInstantActivate {
                    panel.setSelection(idx)
                    close(commit: true)
                } else {
                    panel.setSelection(idx)
                }
            } else if PrefsStore.typingStartsFastSearch,
                      let ch = Self.character(of: event)?.lowercased(),
                      ch.count == 1, ch.first!.isLetter || ch == " ",
                      Self.searchEligibleFlags(event.flags) {
                searchQuery.append(ch)
                applyQuery()
            } else {
                return false
            }
        }
        return true
    }

    /// Matches one in-panel action: modifiers exactly equal the configured
    /// mask and the key is its letter. Returns nil when not this action's
    /// modifiers at all (keep routing), true/false when it is (consume/ignore).
    private static func actionKey(of event: CGEvent, mods: UInt32, letter: Character) -> Bool? {
        let carbon = HotkeyCenter.carbonFlags(fromCG: event.flags.intersection(HotkeyCenter.modifierBitsPublic))
        guard carbon != 0 else { return nil }
        guard carbon == mods else { return nil }
        guard let ch = character(of: event)?.lowercased(), ch.count == 1, ch.first == letter else { return false }
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

    /// Global (panel-closed) route: number switcher digits under a held
    /// side-mask, and Fast Search start letters under the configured mods.
    private func routeGlobalKey(_ event: CGEvent, sideMask: UInt32) -> Bool {
        let kc = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        // Number switcher: held modifiers match the configured side-mask and
        // the key is a digit row key.
        let numberMask = PrefsStore.numberModifierMask
        if numberMask != 0, sideMask & numberMask == numberMask,
           let idx = Self.digitKeycodes[kc] {
            WindowTracker.shared.refresh(reason: "number")
            let rows = WindowTracker.shared.windows.filter { !$0.title.isEmpty }
            guard rows.indices.contains(idx) else { return false }
            if PrefsStore.numberInstantActivate {
                panel.onCommit?(rows[idx])
            } else {
                open()
                panel.setSelection(idx)
            }
            print("number: digit \(idx + 1) → [\(rows[idx].appLocalName)]")
            return true
        }
        // Fast Search start: the configured side-mask + a letter opens the
        // overlay-less query without showing the panel.
        let fsMods = PrefsStore.fastSearchMods
        if fsMods != 0, sideMask & fsMods == fsMods,
           let ch = Self.character(of: event)?.lowercased(),
           ch.count == 1, ch.first!.isLetter, !isOpen {
            WindowTracker.shared.refresh(reason: "fast-search")
            searchQuery = ch
            pendingSearchMods = sideMask
            if PrefsStore.searchShortcutsDepth > 0, let remembered = searchMemory.first {
                // Prefill remembered query with the typed char as prefix hint.
                _ = remembered
            }
            renderFromTracker(selectFirst: true)
            print("fast-search: started \"\(searchQuery)\"")
            return true
        }
        return false
    }

    private func applyQuery() {
        let pinned = panel.selectedModel
        renderFromTracker(selectFirst: false)
        if let pinned,
           let idx = panel.rows.firstIndex(where: { $0.pid == pinned.pid && $0.title == pinned.title }) {
            panel.setSelection(idx)
        }
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
