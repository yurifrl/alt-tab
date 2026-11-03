import AppKit
import Carbon.HIToolbox

/// Preferences window (Phase 5 + Contexts parity panes): one tab per Contexts
/// settings pane. Every control writes PrefsStore directly and applies live —
/// theme re-skins open surfaces, sidebars toggle, hotkeys rebind instantly.
final class PrefsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PrefsWindowController()

    // Command-Tab pane — Contexts-style shortcut list (the four fixed combos).
    private struct ShortcutRow {
        let check: NSButton        // enables the trigger
        let upLabel: NSTextField   // current move-up binding
        let upButton: NSButton     // records move-up
    }
    private var shortcutRows: [ShortcutRow] = []
    private var recordingUp: Int?

    // Panel pane
    private let themePopup = NSPopUpButton(frame: .zero)
    private let rowsField = NSTextField(frame: .zero)
    private let rowsStepper = NSStepper(frame: .zero)
    private let widthField = NSTextField(frame: .zero)
    private let displayPopup = NSPopUpButton(frame: .zero)
    private let delayCheck = NSButton(checkboxWithTitle: "Show Panel after a slight delay (tap and release quickly to switch to the last window)", target: nil, action: nil)
    private let hoverCheck = NSButton(checkboxWithTitle: "Hovering a row selects it", target: nil, action: nil)
    private let scrollCheck = NSButton(checkboxWithTitle: "Scroll wheel moves the selection", target: nil, action: nil)
    private let indicatorPopup = NSPopUpButton(frame: .zero)
    private let minimizedPopup = NSPopUpButton(frame: .zero)
    private let hiddenPopup = NSPopUpButton(frame: .zero)
    private let windowlessPopup = NSPopUpButton(frame: .zero)
    private let typingCheck = NSButton(checkboxWithTitle: "Typing starts Fast Search while the panel is open", target: nil, action: nil)

    // Search pane
    private let fastSearchPopup = NSPopUpButton(frame: .zero)
    private let shortcutsPopup = NSPopUpButton(frame: .zero)
    private let mismatchCheck = NSButton(checkboxWithTitle: "Allow mismatch (fuzzy subsequence matching)", target: nil, action: nil)

    // Number pane
    private let digitsCheck = NSButton(checkboxWithTitle: "Typing a number instantly activates that window", target: nil, action: nil)
    private let leftCmdCheck = NSButton(checkboxWithTitle: "Left ⌘", target: nil, action: nil)
    private let rightCmdCheck = NSButton(checkboxWithTitle: "Right ⌘", target: nil, action: nil)
    private let leftOptCheck = NSButton(checkboxWithTitle: "Left ⌥", target: nil, action: nil)
    private let rightOptCheck = NSButton(checkboxWithTitle: "Right ⌥", target: nil, action: nil)
    private let numberSidebarCheck = NSButton(checkboxWithTitle: "Show the Number Switcher's numbers on the Sidebar", target: nil, action: nil)

    // Rules pane
    private let appsOfPopup = NSPopUpButton(frame: .zero)
    private let excludesField = NSTextField(frame: .zero)
    private let groupingPopup = NSPopUpButton(frame: .zero)
    private let spacePopup = NSPopUpButton(frame: .zero)
    private let groupCountStepper = NSStepper(frame: .zero)
    private let groupCountField = NSTextField(frame: .zero)

    // Sidebar pane
    private let sidebarsCheck = NSButton(checkboxWithTitle: "Show sidebars (always-on per-screen lists)", target: nil, action: nil)
    private let sidebarsWindowlessCheck = NSButton(checkboxWithTitle: "Include running apps without windows", target: nil, action: nil)
    private let sidebarsNumbersCheck = NSButton(checkboxWithTitle: "Show numbers next to sidebar rows", target: nil, action: nil)

    private var built = false

    override init(window: NSWindow?) {
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    private var prefsWindow: NSWindow {
        if let w = window { return w }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "alt-tab Preferences"
        w.delegate = self
        w.isReleasedWhenClosed = false
        window = w
        return w
    }

    override func showWindow(_ sender: Any?) {
        buildIfNeeded()
        syncFromStore()
        super.showWindow(sender)
        prefsWindow.center()
        prefsWindow.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    // MARK: - Layout

    private func buildIfNeeded() {
        guard !built else { return }
        built = true

        // Command-Tab pane -------------------------------------------------
        themePopup.addItems(withTitles: ["Auto", "Vibrant Light", "Vibrant Dark"])
        themePopup.target = self; themePopup.action = #selector(themeChanged(_:))

        // Contexts' fixed four combos; each toggles its trigger and records
        // its own move-up binding.
        let shortcutNames = ["⌘Tab", "⌘`", "⌥Tab", "⌥`"]
        for (i, name) in shortcutNames.enumerated() {
            let check = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            check.target = self; check.action = #selector(shortcutToggled(_:)); check.tag = i
            let upLabel = NSTextField(labelWithString: "—")
            let upButton = NSButton(title: "Record", target: self, action: #selector(recordShortcutUp(_:)))
            upButton.bezelStyle = .rounded; upButton.tag = i
            shortcutRows.append(ShortcutRow(check: check, upLabel: upLabel, upButton: upButton))
        }

        delayCheck.target = self; delayCheck.action = #selector(delayToggled(_:))
        typingCheck.target = self; typingCheck.action = #selector(typingToggled(_:))

        var cmdTabRows: [[NSView]] = [[label("Switch windows:")]]
        for r in shortcutRows {
            let upRow = NSStackView(views: [r.upLabel, r.upButton]); upRow.spacing = 8
            cmdTabRows.append([NSGridCell.emptyContentView, r.check, upRow])
        }
        cmdTabRows.append([NSGridCell.emptyContentView, delayCheck])
        cmdTabRows.append([NSGridCell.emptyContentView, typingCheck])
        let cmdTabGrid = NSGridView(views: cmdTabRows)

        // Panel pane ---------------------------------------------------------
        rowsStepper.minValue = 3; rowsStepper.maxValue = 16; rowsStepper.increment = 1
        rowsField.target = self; rowsField.action = #selector(rowsEdited(_:))
        rowsStepper.target = self; rowsStepper.action = #selector(rowsStepped(_:))
        widthField.target = self; widthField.action = #selector(widthEdited(_:))
        displayPopup.addItems(withTitles: ["On all displays", "Primary display only", "Display with mouse"])
        displayPopup.target = self; displayPopup.action = #selector(displayChanged(_:))
        hoverCheck.target = self; hoverCheck.action = #selector(hoverToggled(_:))
        scrollCheck.target = self; scrollCheck.action = #selector(scrollToggled(_:))
        indicatorPopup.addItems(withTitles: ["Search hints", "Numbers 1–9", "Neither"])
        indicatorPopup.target = self; indicatorPopup.action = #selector(indicatorChanged(_:))
        for p in [minimizedPopup, hiddenPopup, windowlessPopup] {
            p.addItems(withTitles: ["Show", "Show at bottom", "Do not show"])
            p.target = self; p.action = #selector(policyChanged(_:))
        }
        let rowsGroup = NSStackView(views: [rowsField, rowsStepper]); rowsGroup.spacing = 6
        let panelGrid = NSGridView(views: [
            [label("Theme:"), themePopup],
            [label("Max rows:"), rowsGroup],
            [label("Panel width:"), widthField],
            [label("Show on:"), displayPopup],
            [label("Show next to rows:"), indicatorPopup],
            [label("Minimized windows:"), minimizedPopup],
            [label("Hidden apps:"), hiddenPopup],
            [label("Apps without windows:"), windowlessPopup],
            [NSGridCell.emptyContentView, hoverCheck],
            [NSGridCell.emptyContentView, scrollCheck],
        ])

        // Search pane --------------------------------------------------------
        fastSearchPopup.addItems(withTitles: ["Off (no fast search)", "Hold ⌘ + type", "Hold ⌃ + type", "Hold ⌥ + type"])
        fastSearchPopup.target = self; fastSearchPopup.action = #selector(fastSearchChanged(_:))
        shortcutsPopup.addItems(withTitles: ["Off", "Remember last query", "Last 3 queries", "Last 5 queries"])
        shortcutsPopup.target = self; shortcutsPopup.action = #selector(shortcutsChanged(_:))
        mismatchCheck.target = self; mismatchCheck.action = #selector(mismatchToggled(_:))
        let searchGrid = NSGridView(views: [
            [label("Fast Search:"), fastSearchPopup],
            [label("Search Shortcuts:"), shortcutsPopup],
            [NSGridCell.emptyContentView, mismatchCheck],
        ])

        // Number pane ----------------------------------------------------------
        digitsCheck.target = self; digitsCheck.action = #selector(digitsToggled(_:))
        for c in [leftCmdCheck, rightCmdCheck, leftOptCheck, rightOptCheck] {
            c.target = self; c.action = #selector(numberSideToggled(_:))
        }
        numberSidebarCheck.target = self; numberSidebarCheck.action = #selector(numberSidebarToggled(_:))
        let sidesRow = NSStackView(views: [leftCmdCheck, rightCmdCheck, leftOptCheck, rightOptCheck])
        sidesRow.orientation = .horizontal; sidesRow.spacing = 12
        let numberGrid = NSGridView(views: [
            [NSGridCell.emptyContentView, digitsCheck],
            [label("Switch numbers with:"), sidesRow],
            [NSGridCell.emptyContentView, numberSidebarCheck],
        ])

        // Rules pane -----------------------------------------------------------
        appsOfPopup.addItems(withTitles: ["Windows of all apps", "Windows of the active app only"])
        appsOfPopup.target = self; appsOfPopup.action = #selector(appsOfChanged(_:))
        excludesField.target = self; excludesField.action = #selector(excludesEdited(_:))
        groupingPopup.addItems(withTitles: ["By Space", "In One Group", "Manually"])
        groupingPopup.target = self; groupingPopup.action = #selector(groupingChanged(_:))
        spacePopup.addItems(withTitles: ["All Spaces", "Visible Spaces (+ fullscreen)", "Visible Spaces"])
        spacePopup.target = self; spacePopup.action = #selector(spaceChanged(_:))
        groupCountStepper.minValue = 1; groupCountStepper.maxValue = 9; groupCountStepper.increment = 1
        groupCountField.isEditable = false
        groupCountStepper.target = self; groupCountStepper.action = #selector(groupCountChanged(_:))
        let gcGroup = NSStackView(views: [groupCountField, groupCountStepper]); gcGroup.spacing = 6
        let rulesGrid = NSGridView(views: [
            [label("Show windows of:"), appsOfPopup],
            [label("Show windows from:"), spacePopup],
            [label("Apps to not show\n(bundle / bundle|title-pattern):"), excludesField],
            [label("Group windows:"), groupingPopup],
            [label("Number of groups:"), gcGroup],
        ])

        // Sidebar pane -----------------------------------------------------------
        sidebarsCheck.target = self; sidebarsCheck.action = #selector(sidebarsToggled(_:))
        sidebarsWindowlessCheck.target = self; sidebarsWindowlessCheck.action = #selector(sidebarsWindowlessToggled(_:))
        sidebarsNumbersCheck.target = self; sidebarsNumbersCheck.action = #selector(sidebarsNumbersToggled(_:))
        let sidebarGrid = NSGridView(views: [
            [NSGridCell.emptyContentView, sidebarsCheck],
            [NSGridCell.emptyContentView, sidebarsWindowlessCheck],
            [NSGridCell.emptyContentView, sidebarsNumbersCheck],
        ])

        for grid in [cmdTabGrid, panelGrid, searchGrid, numberGrid, rulesGrid, sidebarGrid] {
            grid.rowSpacing = 10
            grid.columnSpacing = 12
            grid.column(at: 0).xPlacement = .trailing
        }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 360))
        tabs.addTabViewItem(tab("Command-Tab", cmdTabGrid))
        tabs.addTabViewItem(tab("Panel", panelGrid))
        tabs.addTabViewItem(tab("Search", searchGrid))
        tabs.addTabViewItem(tab("Number Switcher", numberGrid))
        tabs.addTabViewItem(tab("Rules", rulesGrid))
        tabs.addTabViewItem(tab("Sidebar", sidebarGrid))
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let c = prefsWindow.contentView!
        c.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            rowsField.widthAnchor.constraint(equalToConstant: 44),
            widthField.widthAnchor.constraint(equalToConstant: 64),
            groupCountField.widthAnchor.constraint(equalToConstant: 32),
            excludesField.widthAnchor.constraint(equalToConstant: 280),
        ])
    }

    private func tab(_ name: String, _ grid: NSGridView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: name)
        item.label = name
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 330))
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
        ])
        item.view = box
        return item
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func syncFromStore() {
        themePopup.selectItem(at: PrefsStore.Theme.allCases.firstIndex(of: PrefsStore.theme) ?? 0)
        rowsField.integerValue = PrefsStore.maxRows
        rowsStepper.integerValue = PrefsStore.maxRows
        widthField.integerValue = Int(PrefsStore.panelWidth)
        displayPopup.selectItem(at: PrefsStore.PanelDisplay.allCases.firstIndex(of: PrefsStore.panelDisplay) ?? 0)
        hoverCheck.state = PrefsStore.hoverSelects ? .on : .off
        scrollCheck.state = PrefsStore.scrollSelects ? .on : .off
        indicatorPopup.selectItem(at: PrefsStore.RowIndicator.allCases.firstIndex(of: PrefsStore.rowIndicator) ?? 0)
        minimizedPopup.selectItem(at: PrefsStore.WindowPolicy.allCases.firstIndex(of: PrefsStore.minimizedPolicy) ?? 0)
        hiddenPopup.selectItem(at: PrefsStore.WindowPolicy.allCases.firstIndex(of: PrefsStore.hiddenPolicy) ?? 0)
        windowlessPopup.selectItem(at: PrefsStore.WindowPolicy.allCases.firstIndex(of: PrefsStore.windowlessPolicy) ?? 0)
        delayCheck.state = PrefsStore.panelShowDelay ? .on : .off
        typingCheck.state = PrefsStore.typingStartsFastSearch ? .on : .off

        mismatchCheck.state = PrefsStore.searchAllowMismatch ? .on : .off
        shortcutsPopup.selectItem(at: [0, 1, 3, 5].firstIndex(of: PrefsStore.searchShortcutsDepth) ?? 0)
        fastSearchPopup.selectItem(at: Self.fastSearchIndex(for: PrefsStore.fastSearchMods))

        digitsCheck.state = PrefsStore.numberInstantActivate ? .on : .off
        let sides = PrefsStore.numberSideMask
        leftCmdCheck.state = sides & 1 != 0 ? .on : .off
        rightCmdCheck.state = sides & 2 != 0 ? .on : .off
        leftOptCheck.state = sides & 4 != 0 ? .on : .off
        rightOptCheck.state = sides & 8 != 0 ? .on : .off
        numberSidebarCheck.state = PrefsStore.numberShowOnSidebar ? .on : .off

        appsOfPopup.selectItem(at: PrefsStore.appsOfAll ? 0 : 1)
        excludesField.stringValue = PrefsStore.workspaceExcludes.joined(separator: ", ")
        groupingPopup.selectItem(at: PrefsStore.Grouping.allCases.firstIndex(of: PrefsStore.grouping) ?? 0)
        spacePopup.selectItem(at: PrefsStore.SpaceScope.allCases.firstIndex(of: PrefsStore.spaceScope) ?? 0)
        groupCountField.integerValue = PrefsStore.groupCount
        groupCountStepper.integerValue = PrefsStore.groupCount

        sidebarsCheck.state = PrefsStore.sidebarsEnabled ? .on : .off
        sidebarsWindowlessCheck.state = PrefsStore.sidebarsWindowless ? .on : .off
        sidebarsNumbersCheck.state = PrefsStore.sidebarsNumbers ? .on : .off

        let list = PrefsStore.shortcuts
        for r in shortcutRows {
            let sc = list[r.check.tag]
            r.check.state = sc.on ? .on : .off
            r.upLabel.stringValue = sc.upMods == 0 ? "—" : describeBinding(sc.upMods, sc.upKey)
        }
    }

    private static func fastSearchIndex(for mods: UInt32) -> Int {
        switch mods {
        case 0: return 0
        case UInt32(cmdKey): return 1
        case UInt32(controlKey): return 2
        case UInt32(optionKey): return 3
        default: return 0
        }
    }

    private static func fastSearchMods(for index: Int) -> UInt32 {
        switch index {
        case 1: return UInt32(cmdKey)
        case 2: return UInt32(controlKey)
        case 3: return UInt32(optionKey)
        default: return 0
        }
    }

    private func describeBinding(_ m: UInt32, _ key: UInt32) -> String {
        var parts: [String] = []
        if m & UInt32(controlKey) != 0 { parts.append("⌃") }
        if m & UInt32(optionKey) != 0 { parts.append("⌥") }
        if m & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if m & UInt32(shiftKey) != 0 { parts.append("⇧") }
        return parts.joined() + " " + keyName(key)
    }

    /// Virtual keycode → readable name for the common keys; numeric fallback.
    private func keyName(_ code: UInt32) -> String {
        let letters: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        ]
        if let name = letters[code] { return name }
        switch code {
        case UInt32(kVK_Tab): return "Tab"
        case UInt32(kVK_ANSI_Grave): return "`"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Escape): return "Esc"
        case UInt32(kVK_Return): return "Return"
        default: return "key \(code)"
        }
    }

    // MARK: - Actions (each writes the store, then applies live)

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        PrefsStore.theme = PrefsStore.Theme.allCases[sender.indexOfSelectedItem]
        // Panels are rebuilt per open, but an open panel re-skins in place;
        // sidebars rebuild with the new material.
        SwitcherSession.shared.applyThemeLive()
        SidebarController.shared.applyTheme()
    }

    @objc private func rowsEdited(_ sender: NSTextField) { applyRows(sender.integerValue) }
    @objc private func rowsStepped(_ sender: NSStepper) { applyRows(sender.integerValue) }
    private func applyRows(_ raw: Int) {
        let clamped = min(16, max(3, raw))
        rowsField.integerValue = clamped
        rowsStepper.integerValue = clamped
        PrefsStore.maxRows = clamped
    }

    @objc private func widthEdited(_ sender: NSTextField) {
        let clamped = min(1200, max(300, sender.integerValue))
        widthField.integerValue = clamped
        PrefsStore.panelWidth = Double(clamped)
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        PrefsStore.panelDisplay = PrefsStore.PanelDisplay.allCases[sender.indexOfSelectedItem]
    }

    @objc private func hoverToggled(_ sender: NSButton) { PrefsStore.hoverSelects = sender.state == .on }
    @objc private func scrollToggled(_ sender: NSButton) { PrefsStore.scrollSelects = sender.state == .on }
    @objc private func indicatorChanged(_ sender: NSPopUpButton) {
        PrefsStore.rowIndicator = PrefsStore.RowIndicator.allCases[sender.indexOfSelectedItem]
        SwitcherSession.shared.applyThemeLive()
    }

    @objc private func policyChanged(_ sender: NSPopUpButton) {
        let policy = PrefsStore.WindowPolicy.allCases[sender.indexOfSelectedItem]
        switch sender {
        case minimizedPopup: PrefsStore.minimizedPolicy = policy
        case hiddenPopup: PrefsStore.hiddenPolicy = policy
        case windowlessPopup: PrefsStore.windowlessPolicy = policy
        default: break
        }
        WindowTracker.shared.refresh(reason: "policy")
    }

    @objc private func delayToggled(_ sender: NSButton) { PrefsStore.panelShowDelay = sender.state == .on }
    @objc private func typingToggled(_ sender: NSButton) { PrefsStore.typingStartsFastSearch = sender.state == .on }

    @objc private func mismatchToggled(_ sender: NSButton) { PrefsStore.searchAllowMismatch = sender.state == .on }
    @objc private func shortcutsChanged(_ sender: NSPopUpButton) {
        PrefsStore.searchShortcutsDepth = [0, 1, 3, 5][sender.indexOfSelectedItem]
    }
    @objc private func fastSearchChanged(_ sender: NSPopUpButton) {
        PrefsStore.fastSearchMods = Self.fastSearchMods(for: sender.indexOfSelectedItem)
    }

    @objc private func digitsToggled(_ sender: NSButton) { PrefsStore.numberInstantActivate = sender.state == .on }
    @objc private func numberSideToggled(_ sender: NSButton) {
        let sides = PrefsStore.numberSideMask
        var next = sides
        if sender === leftCmdCheck { next = PrefsStore.toggledSide(next, 1, sender.state == .on) }
        if sender === rightCmdCheck { next = PrefsStore.toggledSide(next, 2, sender.state == .on) }
        if sender === leftOptCheck { next = PrefsStore.toggledSide(next, 4, sender.state == .on) }
        if sender === rightOptCheck { next = PrefsStore.toggledSide(next, 8, sender.state == .on) }
        PrefsStore.numberSideMask = next
    }
    @objc private func numberSidebarToggled(_ sender: NSButton) { PrefsStore.numberShowOnSidebar = sender.state == .on }

    @objc private func appsOfChanged(_ sender: NSPopUpButton) { PrefsStore.appsOfAll = sender.indexOfSelectedItem == 0 }
    @objc private func groupingChanged(_ sender: NSPopUpButton) {
        PrefsStore.grouping = PrefsStore.Grouping.allCases[sender.indexOfSelectedItem]
        SidebarController.shared.refreshForPrefs()
    }
    @objc private func spaceChanged(_ sender: NSPopUpButton) {
        PrefsStore.spaceScope = PrefsStore.SpaceScope.allCases[sender.indexOfSelectedItem]
        WindowTracker.shared.refresh(reason: "spaceScope")
    }
    @objc private func groupCountChanged(_ sender: NSStepper) {
        groupCountField.integerValue = sender.integerValue
        PrefsStore.groupCount = sender.integerValue
        SidebarController.shared.refreshForPrefs()
    }
    @objc private func excludesEdited(_ sender: NSTextField) {
        let ids = sender.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        PrefsStore.workspaceExcludes = ids
        WindowTracker.shared.refresh(reason: "excludes")
    }

    @objc private func sidebarsToggled(_ sender: NSButton) {
        PrefsStore.sidebarsEnabled = sender.state == .on
        if PrefsStore.sidebarsEnabled {
            SidebarController.shared.enable()
        } else {
            SidebarController.shared.disable()
        }
    }
    @objc private func sidebarsWindowlessToggled(_ sender: NSButton) {
        PrefsStore.sidebarsWindowless = sender.state == .on
        SidebarController.shared.refreshForPrefs()
    }
    @objc private func sidebarsNumbersToggled(_ sender: NSButton) {
        PrefsStore.sidebarsNumbers = sender.state == .on
        SidebarController.shared.refreshForPrefs()
    }

    // MARK: - Shortcut list actions

    @objc private func shortcutToggled(_ sender: NSButton) {
        var list = PrefsStore.shortcuts
        list[sender.tag].on = sender.state == .on
        PrefsStore.shortcuts = list
        SwitcherSession.shared.installShortcuts()
    }

    @objc private func recordShortcutUp(_ sender: NSButton) {
        if recordingUp == sender.tag { stopRecording(); return }
        recordingUp = sender.tag
        shortcutRows[sender.tag].upLabel.stringValue = "press keys…"
        startRecording()
    }

    private func startRecording() {
        prefsWindow.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingUp != nil else { return event }
            self.handleRecordedKey(event)
            return nil   // consumed
        }
    }

    /// Records a move-up binding: modifier(s) + key (Tab or backtick). Esc cancels.
    private func handleRecordedKey(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        var mask: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.control) { mask |= UInt32(controlKey) }
        if f.contains(.option) { mask |= UInt32(optionKey) }
        if f.contains(.command) { mask |= UInt32(cmdKey) }
        if f.contains(.shift) { mask |= UInt32(shiftKey) }
        // Require a real accelerator modifier; bare letters would hijack typing.
        guard mask != 0 else { return }
        if let index = recordingUp {
            var list = PrefsStore.shortcuts
            list[index].upMods = mask
            list[index].upKey = UInt32(event.keyCode)
            PrefsStore.shortcuts = list
            SwitcherSession.shared.installShortcuts()
        }
        stopRecording()
        syncFromStore()
    }

    private var keyMonitor: Any?
    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingUp = nil
        if built { syncFromStore() }
    }
}
