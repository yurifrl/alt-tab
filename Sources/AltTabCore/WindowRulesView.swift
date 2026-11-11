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

/// "none" + palette dots; click to pick.
final class ColorChoiceRow: NSView {
    var onChange: ((String) -> Void)?
    /// "" = none; a hex outside the palette highlights nothing.
    var value = "" { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 9 * 30, height: 28) }

    private func rect(_ i: Int) -> NSRect { NSRect(x: 4 + CGFloat(i) * 30, y: 4, width: 20, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0...ColorTag.palette.count {
            let r = rect(i)
            if i == 0 {
                NSColor.secondaryLabelColor.setStroke()
                let o = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                o.lineWidth = 1.2; o.setLineDash([3, 3], count: 2, phase: 0); o.stroke()
            } else {
                ColorTag.color(ColorTag.palette[i - 1])?.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            let chosen = i == 0 ? value.isEmpty : value == ColorTag.palette[i - 1]
            if chosen {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3.5, dy: -3.5))
                ring.lineWidth = 2; ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0...ColorTag.palette.count where rect(i).insetBy(dx: -4, dy: -4).contains(p) {
            value = i == 0 ? "" : ColorTag.palette[i - 1]
            onChange?(value)
            return
        }
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

    private let detailBox = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Customize a window to rename it, color it or hide it. Pick one from your open windows with “Add from open windows”, or hold E on a row in the switcher.")
    private let headerIcon = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerBundle = NSTextField(labelWithString: "")
    private let appliesSeg = NSSegmentedControl(labels: ["This window", "Title matches", "All windows"], trackingMode: .selectOne, target: nil, action: nil)
    private let matchPopup = NSPopUpButton(frame: .zero)
    private let patternField = NSTextField()
    private let matchCount = NSTextField(labelWithString: "")
    private let pinStatus = NSTextField(wrappingLabelWithString: "")
    private let relinkButton = NSButton(title: "Pick from open windows ▾", target: nil, action: nil)
    private var patternRowView: NSStackView?
    private var pinRowView: NSStackView?
    private let aliasField = NSTextField()
    private let letterLabel = NSTextField(labelWithString: "")
    private let colors = ColorChoiceRow()
    private let hideSwitch = NSSwitch()
    private let previewHolder = NSView()
    private let preview = PanelRowView()
    private let removeRule = NSButton(title: "Remove customization", target: nil, action: nil)

    private static let matchKinds = ["Contains", "Exact", "Starts with", "Ends with"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        observer = NotificationCenter.default.addObserver(
            forName: PrefsStore.windowRulesChanged, object: nil, queue: .main) { [weak self] _ in
            // Our own writes already match `rules`: reloading would reset
            // transient form state (e.g. "Title matches" with an empty pattern).
            guard let self, PrefsStore.windowRules != self.rules else { return }
            self.reload()
        }
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }
    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    // MARK: Build

    private func smallLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        // Left: list + buttons.
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        col.width = 180
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

        // Right: detail form.
        headerName.font = .systemFont(ofSize: 15, weight: .semibold)
        headerBundle.font = .systemFont(ofSize: 11); headerBundle.textColor = .secondaryLabelColor
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        appliesSeg.target = self; appliesSeg.action = #selector(appliesChanged(_:))
        appliesSeg.controlSize = .small
        appliesSeg.segmentStyle = .rounded
        for i in 0..<3 { appliesSeg.setWidth(98, forSegment: i) }
        matchPopup.addItems(withTitles: Self.matchKinds)
        matchPopup.controlSize = .small
        matchPopup.target = self; matchPopup.action = #selector(patternEdited(_:))
        for f in [patternField, aliasField] {
            f.delegate = self
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
        }
        patternField.placeholderString = "Window title"
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
        let patternRow = row([matchPopup, patternField])
        let pinRow = NSStackView(views: [pinStatus, relinkButton])
        pinRow.orientation = .vertical; pinRow.alignment = .leading; pinRow.spacing = 6
        patternRowView = patternRow; pinRowView = pinRow
        let aliasRow = row([aliasField, letterLabel])
        let hideRow = row([hideSwitch, NSTextField(labelWithString: "Hide from the switcher")], spacing: 8)
        let form = NSStackView(views: [
            header,
            smallLabel("APPLIES TO"), appliesSeg, pinRow, patternRow, matchCount,
            smallLabel("ALIAS"), aliasRow,
            smallLabel("COLOR"), colors,
            smallLabel("VISIBILITY"), hideRow,
            removeRule,
        ])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 6
        form.setCustomSpacing(14, after: header)
        form.setCustomSpacing(14, after: matchCount)
        form.setCustomSpacing(14, after: aliasRow)
        form.setCustomSpacing(14, after: colors)
        form.setCustomSpacing(18, after: hideRow)
        form.translatesAutoresizingMaskIntoConstraints = false
        detailBox.addSubview(form)

        // Bottom: live preview.
        let previewTitle = smallLabel("PREVIEW — HOW IT LOOKS IN THE SWITCHER")
        previewHolder.wantsLayer = true
        previewHolder.layer?.cornerRadius = 8
        previewHolder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.addSubview(preview)

        for v in [scroll, addButton, removeButton, detailBox, emptyLabel, previewTitle, previewHolder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [headerIcon, patternField, aliasField, matchPopup, colors, appliesSeg] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.widthAnchor.constraint(equalToConstant: 188),
            scroll.bottomAnchor.constraint(equalTo: previewTitle.topAnchor, constant: -50),
            addButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            removeButton.widthAnchor.constraint(equalToConstant: 26),

            detailBox.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detailBox.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            detailBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detailBox.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            form.topAnchor.constraint(equalTo: detailBox.topAnchor),
            form.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor),
            form.trailingAnchor.constraint(lessThanOrEqualTo: detailBox.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: detailBox.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: detailBox.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: detailBox.widthAnchor, constant: -24),

            headerIcon.widthAnchor.constraint(equalToConstant: 34),
            headerIcon.heightAnchor.constraint(equalToConstant: 34),
            matchPopup.widthAnchor.constraint(equalToConstant: 104),
            patternField.widthAnchor.constraint(equalToConstant: 190),
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

    // MARK: Pattern <-> controls

    private static func decode(_ p: String) -> (kind: Int, text: String) {
        if p.hasPrefix("=") { return (1, String(p.dropFirst())) }
        if p.hasPrefix("^") { return (2, String(p.dropFirst())) }
        if p.hasSuffix("$") { return (3, String(p.dropLast())) }
        return (0, p)
    }
    private static func encode(kind: Int, text: String) -> String {
        guard !text.isEmpty else { return "" }
        switch kind {
        case 1: return "=" + text
        case 2: return "^" + text
        case 3: return text + "$"
        default: return text
        }
    }
    private func composedPattern() -> String {
        appliesSeg.selectedSegment != 1 ? "" :
            Self.encode(kind: matchPopup.indexOfSelectedItem, text: patternField.stringValue)
    }

    // MARK: Detail

    private func loadDetail() {
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
        headerIcon.image = AppInfo.icon(r.bundleId)
        headerName.stringValue = AppInfo.name(r.bundleId)
        headerBundle.stringValue = r.bundleId
        let d = Self.decode(r.pattern)
        appliesSeg.selectedSegment = r.windowId != 0 ? 0 : (r.pattern.isEmpty ? 2 : 1)
        matchPopup.selectItem(at: d.kind)
        patternField.stringValue = d.text
        applyScopeVisibility()
        aliasField.stringValue = r.alias
        colors.value = r.color
        hideSwitch.state = r.hide ? .on : .off
        updateDynamic()
    }

    /// Pinned scope shows the window link row; title scope shows the pattern row.
    private func applyScopeVisibility() {
        let seg = appliesSeg.selectedSegment
        pinRowView?.isHidden = seg != 0
        patternRowView?.isHidden = seg != 1
        matchCount.isHidden = seg == 0
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
        }
        matchCount.stringValue = n == 0 ? "No open windows match right now"
            : "✓ Matches \(n) open window\(n == 1 ? "" : "s") now"
        let name = r.alias.isEmpty ? AppInfo.name(r.bundleId) : r.alias
        let letter = name.lowercased().first { $0.isLetter }
        letterLabel.stringValue = letter.map { "quick-go: \($0)" } ?? ""

        let live = WindowTracker.shared.windows.first { PrefsStore.ruleMatches(r, window: $0) }
        let fallback = r.windowId != 0 ? r.windowTitle : Self.decode(r.pattern).text
        let title = live?.title ?? (fallback.isEmpty ? "Window title" : fallback)
        let pid = live?.pid ?? NSRunningApplication.runningApplications(withBundleIdentifier: r.bundleId).first?.processIdentifier ?? 0
        var wm = WindowModel(pid: pid, bundleId: r.bundleId, appLocalName: AppInfo.name(r.bundleId),
                             title: title, frame: .zero, minimized: false, ax: nil)
        wm.alias = r.alias.isEmpty ? nil : r.alias
        wm.colorHex = r.color.isEmpty ? nil : r.color
        preview.configure(wm, globalIndex: 0, hint: letter)
        preview.setHighlighted(true)
        preview.alphaValue = r.hide ? 0.45 : 1
    }

    // MARK: Actions

    @objc private func appliesChanged(_ sender: NSSegmentedControl) {
        guard let i = selected else { return }
        switch sender.selectedSegment {
        case 0:
            // Needs a window to pin to: ask now; cancelling snaps back.
            if rules[i].windowId == 0 {
                showWindowPicker(from: sender, forSelectedRule: true)
                if selected.map({ rules[$0].windowId == 0 }) ?? true { loadDetail() }
            }
        case 1:
            mutate { $0.windowId = 0; $0.windowTitle = ""; $0.pattern = composedPattern() }
            applyScopeVisibility()
            window?.makeFirstResponder(patternField)
        default:
            mutate { $0.windowId = 0; $0.windowTitle = ""; $0.pattern = "" }
            applyScopeVisibility()
        }
        if let s = selected { _ = s; updateDynamic() }
    }

    @objc private func relinkPressed(_ sender: NSButton) {
        showWindowPicker(from: sender, forSelectedRule: true)
    }

    /// Open windows of the rule's app first, every other app under "Other apps".
    /// Picking pins the selected rule to that window (new id, same settings).
    private func showWindowPicker(from view: NSView, forSelectedRule: Bool) {
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
        mutate { $0.bundleId = t.bundleId; $0.windowId = t.windowId; $0.windowTitle = t.title; $0.pattern = "" }
        loadDetail()
    }
    @objc private func patternEdited(_ sender: Any?) { mutate { $0.pattern = composedPattern() } }
    @objc private func hideToggled(_ sender: NSSwitch) { mutate { $0.hide = sender.state == .on } }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === patternField { mutate { $0.pattern = composedPattern() } }
        else if f === aliasField { mutate { $0.alias = f.stringValue.trimmingCharacters(in: .whitespaces) } }
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
            $0.bundleId == t.bundleId && (pinned ? $0.windowId == t.windowId : ($0.windowId == 0 && $0.pattern.isEmpty))
        }) {
            table.selectRowIndexes([existing], byExtendingSelection: false)
            table.scrollRowToVisible(existing)
        } else {
            rules.append(PrefsStore.WindowRule(bundleId: t.bundleId, pattern: "", hide: false,
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
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 46))
        let bar = NSView(frame: NSRect(x: 0, y: 8, width: 3, height: 30))
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = ColorTag.color(r.color)?.cgColor
        bar.isHidden = r.color.isEmpty
        let icon = NSImageView(frame: NSRect(x: 8, y: 10, width: 26, height: 26))
        icon.image = AppInfo.icon(r.bundleId)
        let title = NSTextField(labelWithString: r.alias.isEmpty ? AppInfo.name(r.bundleId) : r.alias)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let d = Self.decode(r.pattern)
        let scope: String
        if r.windowId != 0 {
            let open = WindowTracker.shared.windows.contains { PrefsStore.ruleMatches(r, window: $0) }
            scope = "This window" + (open ? "" : " (not open)") + (r.windowTitle.isEmpty ? "" : " · “\(r.windowTitle)”")
        } else {
            scope = r.pattern.isEmpty ? "All windows" : ["", "= ", "starts ", "ends "][d.kind] + "“\(d.text)”"
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
