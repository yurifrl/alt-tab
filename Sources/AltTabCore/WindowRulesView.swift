import AppKit

/// App name / icon for a rule's bundle id (legacy loose entries that are not
/// bundle ids fall back to the raw text).
enum AppInfo {
    static func name(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId.isEmpty ? "Any app" : bundleId
    }
    static func icon(_ bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Menu payload: an app and optionally one of its windows (id 0 = whole app).
final class PinTarget: NSObject {
    let bundleId: String
    let windowId: UInt32
    let title: String
    init(bundleId: String, windowId: UInt32, title: String) {
        self.bundleId = bundleId; self.windowId = windowId; self.title = title
    }
}

/// First dot opens the system color selector (its color, converted to
/// "#RRGGBB"), second is the screen eyedropper (click any pixel), then
/// "none" + palette dots; click to pick. The first dot keeps the picker's
/// last color, so tapping a palette dot and coming back restores it.
final class ColorChoiceRow: NSView {
    var onChange: ((String) -> Void)?
    /// "" = none; a hex outside the palette fills the first (selector) dot.
    var value = "" {
        didSet {
            if let hex = selectorHex { lastCustom = hex }
            needsDisplay = true
        }
    }
    /// Last color the picker committed (selector or eyedropper); the picker
    /// dot shows it and re-applies it after a palette or "none" tap.
    private var lastCustom: String?
    /// Live eyedropper, retained from `show` until it completes.
    private var sampler: NSColorSampler?

    override var intrinsicContentSize: NSSize { NSSize(width: 11 * 28, height: 28) }

    /// 0 = selector color, 1 = screen eyedropper, 2 = none, 3... = palette.
    private func rect(_ i: Int) -> NSRect { NSRect(x: 3 + CGFloat(i) * 28, y: 5, width: 18, height: 18) }

    /// The rule's color when it came from the selector (nil for none/palette).
    private var selectorHex: String? {
        value.isEmpty || ColorTag.palette.contains(value) ? nil : value
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0...(ColorTag.palette.count + 2) {
            let r = rect(i)
            switch i {
            case 0:
                if let hex = selectorHex ?? lastCustom, let c = ColorTag.color(hex) {
                    c.setFill(); NSBezierPath(ovalIn: r).fill()
                } else {
                    drawWheel(r)
                }
            case 1:
                drawEyedropper(r)
            case 2:
                NSColor.secondaryLabelColor.setStroke()
                let o = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                o.lineWidth = 1.2; o.setLineDash([3, 3], count: 2, phase: 0); o.stroke()
            default:
                ColorTag.color(ColorTag.palette[i - 3])?.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            let chosen = i == 0 ? selectorHex != nil
                : (i == 2 ? value.isEmpty : (i > 2 && value == ColorTag.palette[i - 3]))
            if chosen {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2; ring.stroke()
            }
        }
    }

    /// Hue wheel in the empty selector dot ("pick any color").
    private func drawWheel(_ r: NSRect) {
        let c = NSPoint(x: r.midX, y: r.midY)
        let wedges = 12
        let step = 360 / CGFloat(wedges)
        for k in 0..<wedges {
            let w = NSBezierPath()
            w.move(to: c)
            w.appendArc(withCenter: c, radius: r.width / 2 - 0.5,
                        startAngle: -90 + CGFloat(k) * step, endAngle: -90 + CGFloat(k + 1) * step)
            w.close()
            NSColor(hue: CGFloat(k) / CGFloat(wedges), saturation: 0.78, brightness: 0.96, alpha: 1).setFill()
            w.fill()
        }
    }

    /// A swatch picks on the first click, even when the prefs window is not
    /// key yet (and while the selector panel is open).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0...(ColorTag.palette.count + 2) where rect(i).insetBy(dx: -4, dy: -4).contains(p) {
            switch i {
            case 0:
                // Hand back the picker's last color before the panel opens.
                if let hex = lastCustom, hex != value { value = hex; onChange?(hex) }
                openSelector(); return
            case 1: sampleFromScreen(); return
            case 2: value = ""; onChange?(""); return
            default: value = ColorTag.palette[i - 3]; onChange?(value); return
            }
        }
    }

    /// Opens the system color selector; every color it lands on is stored as a
    /// hex tag (live, so dragging previews in the switcher row below).
    private func openSelector() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        if let c = ColorTag.color(selectorHex ?? value) { panel.color = c }
        panel.setTarget(self)
        panel.setAction(#selector(selectorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func selectorChanged(_ sender: NSColorPanel) {
        guard let hex = ColorTag.hex(sender.color) else { return }
        value = hex
        onChange?(hex)
    }

    /// Screen eyedropper: the system loupe follows the cursor; clicking any
    /// pixel tags with that color (Esc cancels).
    private func sampleFromScreen() {
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] color in
            guard let self else { return }
            self.sampler = nil
            guard let color, let hex = ColorTag.hex(color) else { return }
            self.value = hex
            self.onChange?(hex)
        }
    }

    /// Eyedropper glyph in the sampler dot ("pick a color off the screen").
    private func drawEyedropper(_ r: NSRect) {
        let cfg = NSImage.SymbolConfiguration(paletteColors: [NSColor.secondaryLabelColor])
            .applying(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        guard let img = NSImage(systemSymbolName: "eyedropper",
                                accessibilityDescription: "Pick a color off the screen")?
            .withSymbolConfiguration(cfg) else {
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return
        }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2,
                            width: s.width, height: s.height))
    }
}

/// The Windows preferences tab: every per-window customization (hide, alias,
/// color) lives in `PrefsStore.windowRules`; this is its editor. Master list on
/// the left, the selected rule's form on the right, a live panel-row preview
/// below. Edits write through immediately; hold-E in the panel edits the same
/// rules and the list reloads on `PrefsStore.windowRulesChanged`.
final class WindowRulesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var rules: [PrefsStore.WindowRule] = []
    private var observer: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton(title: "Add from open windows ▾", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let plusButton = NSButton(title: "+", target: nil, action: nil)

    private let detailBox = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Customize a window to rename it, color it or hide it. Pick one from your open windows with “Add from open windows”, add a generic rule with “+”, or hold E on a row in the switcher.")
    private let headerIcon = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerBundle = NSTextField(labelWithString: "")
    private let appliesSeg = NSSegmentedControl(labels: ["This window", "Match", "All windows"], trackingMode: .selectOne, target: nil, action: nil)
    private let matchersEditor = MatcherListEditor(frame: .zero)
    private let matchCount = NSTextField(labelWithString: "")
    private let moreDetails = NSButton(title: "▸ More details", target: nil, action: nil)
    private let matchTable = WindowMatchTableView(frame: .zero)
    /// Match scope's "More details" disclosure: the open-window table shown.
    private var detailsOpen = true
    private let pinStatus = NSTextField(wrappingLabelWithString: "")
    private let relinkButton = NSButton(title: "Pick from open windows ▾", target: nil, action: nil)
    private var pinRowView: NSStackView?
    /// Conditions stashed when the scope leaves "Match" (persistently
    /// clearing on every segment click would throw them away by accident).
    private var stashedMatchers: [PrefsStore.Matcher] = []
    private var stashedMatchAll = false
    private let aliasField = NSTextField()
    private let letterLabel = NSTextField(labelWithString: "")
    private let colors = ColorChoiceRow()
    private let hideSwitch = NSSwitch()
    private let previewHolder = NSView()
    private let preview = PanelRowView()
    private let removeRule = NSButton(title: "Remove customization", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        observer = NotificationCenter.default.addObserver(
            forName: PrefsStore.windowRulesChanged, object: nil, queue: .main) { [weak self] _ in
            // Our own writes already match `rules`: reloading would reset
            // transient form state (e.g. "Match" with an empty pattern).
            guard let self, PrefsStore.windowRules != self.rules else { return }
            self.reload()
        }
        // Every tracker sweep rebuilds the open-window model: keep the count
        // line, the More-details table and the preview in step with it.
        WindowTracker.shared.addChangeHandler("rules") { [weak self] in self?.updateDynamic() }
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }
    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        WindowTracker.shared.removeChangeHandler("rules")
    }

    // MARK: Build

    private func smallLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        // Left: list + buttons. The sidebar is as wide as the footer row
        // ("Add from open windows" + − +): its frame's right edge lands on the
        // + button's right edge (216 frame − 8 of bezel = 208 of list).
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        col.width = 208
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .sourceList
        table.dataSource = self; table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addButton.target = self; addButton.action = #selector(addPressed(_:))
        addButton.bezelStyle = .rounded; addButton.controlSize = .small
        removeButton.target = self; removeButton.action = #selector(removePressed(_:))
        removeButton.bezelStyle = .smallSquare; removeButton.controlSize = .small
        removeButton.toolTip = "Remove the selected customization"
        plusButton.target = self; plusButton.action = #selector(addGenericPressed(_:))
        plusButton.bezelStyle = .smallSquare; plusButton.controlSize = .small
        plusButton.toolTip = "Add a generic rule — any window, narrowed by a title pattern"

        // Right: detail form.
        headerName.font = .systemFont(ofSize: 15, weight: .semibold)
        headerBundle.font = .systemFont(ofSize: 11); headerBundle.textColor = .secondaryLabelColor
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        appliesSeg.target = self; appliesSeg.action = #selector(appliesChanged(_:))
        appliesSeg.controlSize = .small
        appliesSeg.segmentStyle = .rounded
        for i in 0..<3 { appliesSeg.setWidth(98, forSegment: i) }
        matchersEditor.onEdit = { [weak self] matchers, matchAll in
            self?.mutate { $0.matchers = matchers; $0.matchAll = matchAll }
        }
        moreDetails.target = self; moreDetails.action = #selector(detailsToggled(_:))
        moreDetails.isBordered = false
        moreDetails.setButtonType(.momentaryChange)
        updateDetailsButton()
        matchTable.onPick = { [weak self] attribute, value in
            self?.matchersEditor.fillFocused(attribute: attribute, value: value)
        }
        aliasField.delegate = self
        aliasField.controlSize = .small
        aliasField.bezelStyle = .roundedBezel
        aliasField.placeholderString = "App name shown in the switcher"
        matchCount.font = .systemFont(ofSize: 11); matchCount.textColor = .secondaryLabelColor
        pinStatus.font = .systemFont(ofSize: 11); pinStatus.maximumNumberOfLines = 3
        relinkButton.target = self; relinkButton.action = #selector(relinkPressed(_:))
        relinkButton.bezelStyle = .rounded; relinkButton.controlSize = .small
        letterLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium); letterLabel.textColor = .secondaryLabelColor
        colors.onChange = { [weak self] hex in self?.mutate { $0.color = hex } }
        hideSwitch.target = self; hideSwitch.action = #selector(hideToggled(_:))
        removeRule.target = self; removeRule.action = #selector(removePressed(_:))
        removeRule.bezelStyle = .rounded; removeRule.controlSize = .small
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
            let s = NSStackView(views: views); s.spacing = spacing; s.alignment = .centerY; return s
        }
        let header = row([headerIcon, { () -> NSStackView in
            let v = NSStackView(views: [headerName, headerBundle]); v.orientation = .vertical
            v.alignment = .leading; v.spacing = 1; return v }()], spacing: 10)
        let pinRow = NSStackView(views: [pinStatus, relinkButton])
        pinRow.orientation = .vertical; pinRow.alignment = .leading; pinRow.spacing = 6
        pinRowView = pinRow
        let countRow = row([matchCount, moreDetails], spacing: 8)
        let aliasRow = row([aliasField, letterLabel])
        let hideRow = row([hideSwitch, NSTextField(labelWithString: "Hide from the switcher")], spacing: 8)
        let form = NSStackView(views: [
            header,
            smallLabel("APPLIES TO"), appliesSeg, pinRow, matchersEditor, countRow, matchTable,
            smallLabel("ALIAS"), aliasRow,
            smallLabel("COLOR"), colors,
            smallLabel("VISIBILITY"), hideRow,
            removeRule,
        ])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 6
        form.setCustomSpacing(14, after: header)
        form.setCustomSpacing(14, after: countRow)
        form.setCustomSpacing(14, after: aliasRow)
        form.setCustomSpacing(14, after: colors)
        form.setCustomSpacing(18, after: hideRow)
        // The form can outgrow the pane (matcher rows + the 266pt table), so it
        // lives in a scroll view: everything stays reachable at any size.
        form.translatesAutoresizingMaskIntoConstraints = false
        let formHolder = FlippedView()
        formHolder.translatesAutoresizingMaskIntoConstraints = false
        formHolder.addSubview(form)
        let formScroll = NSScrollView()
        formScroll.drawsBackground = false
        formScroll.hasVerticalScroller = true
        formScroll.autohidesScrollers = true
        formScroll.documentView = formHolder
        detailBox.addSubview(formScroll)

        // Bottom: live preview.
        let previewTitle = smallLabel("PREVIEW — HOW IT LOOKS IN THE SWITCHER")
        previewHolder.wantsLayer = true
        previewHolder.layer?.cornerRadius = 8
        previewHolder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.addSubview(preview)

        for v in [scroll, addButton, removeButton, plusButton, detailBox, formScroll, emptyLabel, previewTitle, previewHolder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [headerIcon, matchersEditor, aliasField, colors, appliesSeg, matchTable] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.widthAnchor.constraint(equalToConstant: 216),
            scroll.bottomAnchor.constraint(equalTo: previewTitle.topAnchor, constant: -50),
            addButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            removeButton.widthAnchor.constraint(equalToConstant: 26),
            plusButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            plusButton.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 6),
            plusButton.widthAnchor.constraint(equalToConstant: 26),

            detailBox.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detailBox.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            detailBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detailBox.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            formScroll.topAnchor.constraint(equalTo: detailBox.topAnchor),
            formScroll.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor),
            formScroll.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor),
            formScroll.bottomAnchor.constraint(equalTo: detailBox.bottomAnchor),
            formHolder.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            formHolder.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            formHolder.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            form.topAnchor.constraint(equalTo: formHolder.topAnchor),
            form.leadingAnchor.constraint(equalTo: formHolder.leadingAnchor),
            form.trailingAnchor.constraint(lessThanOrEqualTo: formHolder.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: formHolder.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: detailBox.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: detailBox.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: detailBox.widthAnchor, constant: -24),

            headerIcon.widthAnchor.constraint(equalToConstant: 34),
            headerIcon.heightAnchor.constraint(equalToConstant: 34),
            matchersEditor.widthAnchor.constraint(equalTo: detailBox.widthAnchor),
            matchersEditor.heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
            matchTable.widthAnchor.constraint(equalTo: detailBox.widthAnchor),
            matchTable.heightAnchor.constraint(equalToConstant: WindowMatchTableView.height),
            aliasField.widthAnchor.constraint(equalToConstant: 226),
            pinStatus.widthAnchor.constraint(equalToConstant: 290),

            previewTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            previewTitle.bottomAnchor.constraint(equalTo: previewHolder.topAnchor, constant: -6),
            previewHolder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            previewHolder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            previewHolder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            previewHolder.heightAnchor.constraint(equalToConstant: SwitcherPanelController.rowHeight + 12),
            preview.leadingAnchor.constraint(equalTo: previewHolder.leadingAnchor, constant: 6),
            preview.trailingAnchor.constraint(equalTo: previewHolder.trailingAnchor, constant: -6),
            preview.centerYAnchor.constraint(equalTo: previewHolder.centerYAnchor),
            preview.heightAnchor.constraint(equalToConstant: SwitcherPanelController.rowHeight),
        ])
        formView = form
        reload()
    }
    private var formView: NSStackView?

    // MARK: Data

    /// Re-reads the store (also on external edits, e.g. hold-E in the panel).
    func reload() {
        let latest = PrefsStore.windowRules
        let previous = table.selectedRow
        rules = latest
        table.reloadData()
        if !rules.isEmpty {
            table.selectRowIndexes([max(0, min(previous < 0 ? 0 : previous, rules.count - 1))], byExtendingSelection: false)
        }
        loadDetail()
    }

    private var selected: Int? {
        let i = table.selectedRow
        return i >= 0 && i < rules.count ? i : nil
    }

    /// Single write path: apply to the selected rule, persist, repaint, and
    /// (debounced) tell the tracker so the switcher re-renders.
    private func mutate(_ change: (inout PrefsStore.WindowRule) -> Void) {
        guard let i = selected else { return }
        change(&rules[i])
        PrefsStore.windowRules = rules
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
        updateDynamic()
        refreshWork?.cancel()
        let w = DispatchWorkItem { WindowTracker.shared.refresh(reason: "rules") }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: Matchers

    /// One-line scope for the list: "any" / "all" of a few quoted conditions.
    private static func matcherSummary(_ r: PrefsStore.WindowRule) -> String {
        guard !r.matchers.isEmpty else { return "All windows" }
        let quoted = r.matchers.map {
            $0.attribute == .title ? "“\($0.text)”" : "\($0.attribute.short) “\($0.text)”"
        }
        let shown = quoted.prefix(2).joined(separator: ", ")
        let more = quoted.count > 2 ? ", …" : ""
        return (r.matchers.count > 1 ? (r.matchAll ? "all of: " : "any of: ") : "")
            + (r.matchers.count == 1 ? quoted[0] : shown + more)
    }

    // MARK: Detail

    private func loadDetail() {
        // A new selection invalidates any stashed conditions: they may only be
        // restored into the rule that was on screen when they were stashed.
        stashedMatchers = []
        stashedMatchAll = false
        guard let i = selected else {
            formView?.isHidden = true
            emptyLabel.isHidden = false
            previewHolder.isHidden = true
            removeButton.isEnabled = false
            return
        }
        formView?.isHidden = false
        emptyLabel.isHidden = true
        previewHolder.isHidden = false
        removeButton.isEnabled = true
        let r = rules[i]
        let generic = r.bundleId.isEmpty
        headerIcon.image = generic ? nil : AppInfo.icon(r.bundleId)
        headerName.stringValue = generic ? "Generic rule" : AppInfo.name(r.bundleId)
        headerBundle.stringValue = generic ? "Every app — narrowed by its title pattern" : r.bundleId
        appliesSeg.setEnabled(!generic, forSegment: 0)
        appliesSeg.selectedSegment = r.windowId != 0 ? 0 : (r.matchers.isEmpty ? 2 : 1)
        matchersEditor.load(matchers: r.matchers, matchAll: r.matchAll)
        matchTable.update(rule: r, windows: WindowTracker.shared.windows)
        applyScopeVisibility()
        aliasField.stringValue = r.alias
        colors.value = r.color
        hideSwitch.state = r.hide ? .on : .off
        updateDynamic()
    }

    /// Pinned scope shows the window link row; Match scope shows the editor,
    /// its More-details table and the count line.
    private func applyScopeVisibility() {
        let seg = appliesSeg.selectedSegment
        pinRowView?.isHidden = seg != 0
        matchersEditor.isHidden = seg != 1
        matchCount.isHidden = seg == 0
        moreDetails.isHidden = seg != 1
        matchTable.isHidden = seg != 1 || !detailsOpen
    }

    private func isOpen(_ r: PrefsStore.WindowRule) -> WindowModel? {
        WindowTracker.shared.windows.first { PrefsStore.ruleMatches(r, window: $0) }
    }

    /// Match count, quick-go letter and the preview row.
    private func updateDynamic() {
        guard let i = selected else { return }
        let r = rules[i]
        let n = WindowTracker.shared.windows.filter { PrefsStore.ruleMatches(r, window: $0) }.count
        if r.windowId != 0 {
            if let w = isOpen(r) {
                pinStatus.stringValue = "● Open now — “\(w.title)”"
                pinStatus.textColor = .systemGreen
            } else {
                pinStatus.stringValue = "○ Not open (closed, or its id changed) — re-link below.\nLast seen: “\(r.windowTitle)”"
                pinStatus.textColor = .systemOrange
            }
        } else {
            pinStatus.stringValue = r.bundleId.isEmpty
                ? "○ Not linked — every window matches until you pick one below."
                : "○ Not linked — every \(AppInfo.name(r.bundleId)) window matches until you pick one below."
            pinStatus.textColor = .systemOrange
        }
        matchCount.stringValue = n == 0 ? "No open windows match right now"
            : "✓ Matches \(n) open window\(n == 1 ? "" : "s") now"
        let name = r.alias.isEmpty ? AppInfo.name(r.bundleId) : r.alias
        let letter = name.quickGoLetter
        letterLabel.stringValue = letter.map { "quick-go: \($0)" } ?? ""

        let live = WindowTracker.shared.windows.first { PrefsStore.ruleMatches(r, window: $0) }
        let fallback = r.windowId != 0 ? r.windowTitle : r.matchers.first?.text ?? ""
        let title = live?.title ?? (fallback.isEmpty ? "Window title" : fallback)
        let pid = live?.pid ?? NSRunningApplication.runningApplications(withBundleIdentifier: r.bundleId).first?.processIdentifier ?? 0
        var wm = WindowModel(pid: pid, bundleId: r.bundleId, appLocalName: AppInfo.name(r.bundleId),
                             title: title, frame: .zero, minimized: false, ax: nil)
        wm.alias = r.alias.isEmpty ? nil : r.alias
        wm.colorHex = r.color.isEmpty ? nil : r.color
        preview.configure(wm, globalIndex: 0, hint: letter)
        preview.setHighlighted(true)
        preview.alphaValue = r.hide ? 0.45 : 1
        matchTable.update(rule: r, windows: WindowTracker.shared.windows)
    }

    /// "More details": the open-window table collapses to just the count line.
    @objc private func detailsToggled(_ sender: NSButton) {
        detailsOpen.toggle()
        applyScopeVisibility()
        updateDetailsButton()
    }

    /// The disclosure's title flips with its state.
    private func updateDetailsButton() {
        moreDetails.attributedTitle = NSAttributedString(
            string: detailsOpen ? "▾ Hide details" : "▸ More details",
            attributes: [.foregroundColor: NSColor.controlAccentColor,
                         .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
    }

    // MARK: Actions

    @objc private func appliesChanged(_ sender: NSSegmentedControl) {
        guard selected != nil else { return }
        switch sender.selectedSegment {
        case 0:
            // Just open the tab: a window link is explicit — the "Pick from
            // open windows" button below, not a forced picker popup. No title
            // match survives into this scope.
            stashMatchers()
            mutate { $0.matchers = []; $0.windowId = 0; $0.windowTitle = "" }
            applyScopeVisibility()
        case 1:
            mutate {
                $0.windowId = 0; $0.windowTitle = ""
                if $0.matchers.isEmpty { $0.matchers = stashedMatchers; $0.matchAll = stashedMatchAll }
            }
            if let i = selected { matchersEditor.load(matchers: rules[i].matchers, matchAll: rules[i].matchAll) }
            applyScopeVisibility()
            matchersEditor.focusFirstField()
        default:
            stashMatchers()
            mutate { $0.matchers = []; $0.windowId = 0; $0.windowTitle = "" }
            applyScopeVisibility()
        }
        if let s = selected { _ = s; updateDynamic() }
    }

    /// Remembers the selected rule's conditions before a scope that ignores
    /// them clears the field.
    private func stashMatchers() {
        guard let i = selected, !rules[i].matchers.isEmpty else { return }
        stashedMatchers = rules[i].matchers
        stashedMatchAll = rules[i].matchAll
    }

    @objc private func relinkPressed(_ sender: NSButton) {
        showWindowPicker(from: sender)
    }

    /// Open windows of the rule's app first, every other app under "Other apps".
    /// Picking pins the selected rule to that window (new id, same settings).
    private func showWindowPicker(from view: NSView) {
        guard let i = selected else { return }
        let menu = NSMenu()
        let same = WindowTracker.shared.windows.filter { $0.bundleId == rules[i].bundleId && !$0.title.isEmpty }
        let others = WindowTracker.shared.windows.filter { $0.bundleId != rules[i].bundleId && !$0.title.isEmpty && !$0.bundleId.isEmpty }
        let head = NSMenuItem(title: "Open \(AppInfo.name(rules[i].bundleId)) windows", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if same.isEmpty {
            let none = NSMenuItem(title: "None open", action: nil, keyEquivalent: ""); none.isEnabled = false
            menu.addItem(none)
        }
        for w in same { menu.addItem(pinItem(w, showApp: false)) }
        if !others.isEmpty {
            menu.addItem(.separator())
            let other = NSMenuItem(title: "Other apps", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for w in others { sub.addItem(pinItem(w, showApp: true)) }
            other.submenu = sub
            menu.addItem(other)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func pinItem(_ w: WindowModel, showApp: Bool) -> NSMenuItem {
        let t = w.title.count > 52 ? String(w.title.prefix(52)) + "…" : w.title
        let item = NSMenuItem(title: showApp ? "\(w.appLocalName) — \(t)" : t, action: #selector(pinPicked(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSRunningApplication(processIdentifier: w.pid)?.icon.map { Self.small($0) }
        item.representedObject = PinTarget(bundleId: w.bundleId, windowId: w.windowId, title: w.title)
        return item
    }

    @objc private func pinPicked(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? PinTarget, t.windowId != 0 else { return }
        stashMatchers()
        mutate { $0.bundleId = t.bundleId; $0.windowId = t.windowId; $0.windowTitle = t.title; $0.matchers = [] }
        loadDetail()
    }
    @objc private func hideToggled(_ sender: NSSwitch) { mutate { $0.hide = sender.state == .on } }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === aliasField { mutate { $0.alias = f.stringValue.trimmingCharacters(in: .whitespaces) } }
    }

    @objc private func removePressed(_ sender: Any?) {
        guard let i = selected else { return }
        rules.remove(at: i)
        PrefsStore.windowRules = rules
        table.reloadData()
        if !rules.isEmpty { table.selectRowIndexes([min(i, rules.count - 1)], byExtendingSelection: false) }
        loadDetail()
        WindowTracker.shared.refresh(reason: "rules")
    }

    /// "+": a generic rule — not tied to an app or a window; the title pattern
    /// (empty = every window) decides what it applies to.
    @objc private func addGenericPressed(_ sender: Any?) {
        if let existing = rules.firstIndex(where: { $0.bundleId.isEmpty && $0.windowId == 0 && $0.matchers.isEmpty }) {
            table.selectRowIndexes([existing], byExtendingSelection: false)
            table.scrollRowToVisible(existing)
        } else {
            rules.append(PrefsStore.WindowRule(bundleId: "", hide: false, alias: "", color: ""))
            PrefsStore.windowRules = rules
            table.reloadData()
            table.selectRowIndexes([rules.count - 1], byExtendingSelection: false)
            table.scrollRowToVisible(rules.count - 1)
        }
        loadDetail()
        // Nothing matches "all windows" on purpose yet: start on the matchers.
        appliesSeg.selectedSegment = 1
        applyScopeVisibility()
        matchersEditor.focusFirstField()
    }

    @objc private func addPressed(_ sender: NSButton) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Open windows", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for w in WindowTracker.shared.windows where !w.title.isEmpty && !w.bundleId.isEmpty {
            let t = w.title.count > 48 ? String(w.title.prefix(48)) + "…" : w.title
            let item = NSMenuItem(title: "\(w.appLocalName) — \(t)", action: #selector(addWindowPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSRunningApplication(processIdentifier: w.pid)?.icon.map { Self.small($0) }
            item.representedObject = PinTarget(bundleId: w.bundleId, windowId: w.windowId, title: w.title)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let whole = NSMenuItem(title: "Whole app", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for a in apps {
            let item = NSMenuItem(title: a.localizedName ?? a.bundleIdentifier!, action: #selector(addWindowPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = a.icon.map { Self.small($0) }
            item.representedObject = PinTarget(bundleId: a.bundleIdentifier!, windowId: 0, title: "")
            sub.addItem(item)
        }
        whole.submenu = sub
        menu.addItem(whole)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private static func small(_ img: NSImage) -> NSImage {
        let c = img.copy() as! NSImage
        c.size = NSSize(width: 16, height: 16)
        return c
    }

    @objc private func addWindowPicked(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? PinTarget else { return }
        let pinned = t.windowId != 0
        if let existing = rules.firstIndex(where: {
            $0.bundleId == t.bundleId && (pinned ? $0.windowId == t.windowId : ($0.windowId == 0 && $0.matchers.isEmpty))
        }) {
            table.selectRowIndexes([existing], byExtendingSelection: false)
            table.scrollRowToVisible(existing)
        } else {
            rules.append(PrefsStore.WindowRule(bundleId: t.bundleId, hide: false,
                                               alias: "", color: "", windowId: t.windowId, windowTitle: t.title))
            PrefsStore.windowRules = rules
            table.reloadData()
            table.selectRowIndexes([rules.count - 1], byExtendingSelection: false)
            table.scrollRowToVisible(rules.count - 1)
        }
        loadDetail()
        window?.makeFirstResponder(aliasField)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableViewSelectionDidChange(_ notification: Notification) { loadDetail() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rules[row]
        let generic = r.bundleId.isEmpty
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 46))
        let bar = NSView(frame: NSRect(x: 0, y: 8, width: 3, height: 30))
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = ColorTag.color(r.color)?.cgColor
        bar.isHidden = r.color.isEmpty
        let icon = NSImageView(frame: NSRect(x: 8, y: 10, width: 26, height: 26))
        if generic {
            icon.image = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Every app")
            icon.contentTintColor = .secondaryLabelColor
        } else {
            icon.image = AppInfo.icon(r.bundleId)
        }
        let ruleName = generic ? "Generic rule" : AppInfo.name(r.bundleId)
        let title = NSTextField(labelWithString: r.alias.isEmpty ? ruleName : r.alias)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let scope: String
        if r.windowId != 0 {
            let open = WindowTracker.shared.windows.contains { PrefsStore.ruleMatches(r, window: $0) }
            scope = "This window" + (open ? "" : " (not open)") + (r.windowTitle.isEmpty ? "" : " · “\(r.windowTitle)”")
        } else {
            scope = Self.matcherSummary(r)
        }
        let sub = NSTextField(labelWithString: (r.alias.isEmpty ? scope : "\(AppInfo.name(r.bundleId)) · \(scope)"))
        sub.font = .systemFont(ofSize: 10.5); sub.textColor = .secondaryLabelColor
        for l in [title, sub] { l.lineBreakMode = .byTruncatingTail }
        let eyeWidth: CGFloat = r.hide ? 20 : 0
        title.frame = NSRect(x: 40, y: 24, width: 180 - 40 - 8 - eyeWidth - 14, height: 16)
        sub.frame = NSRect(x: 40, y: 8, width: 180 - 40 - 8 - eyeWidth - 14, height: 14)
        title.autoresizingMask = [.width]; sub.autoresizingMask = [.width]
        cell.addSubview(bar); cell.addSubview(icon); cell.addSubview(title); cell.addSubview(sub)
        if r.hide {
            let eye = NSImageView(frame: NSRect(x: 180 - 14 - 18, y: 14, width: 18, height: 18))
            eye.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hidden")
            eye.contentTintColor = .secondaryLabelColor
            eye.autoresizingMask = [.minXMargin]
            cell.addSubview(eye)
        }
        cell.textField = title
        return cell
    }
}

/// Top-anchored host for the scrolling detail form (an NSScrollView's document
/// starts at the bottom unless its view is flipped).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
