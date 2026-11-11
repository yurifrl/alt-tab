import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Preferences window (Phase 5): one tab per
/// settings pane. Every control writes PrefsStore directly and applies live —
/// theme re-skins open surfaces, hotkeys rebind instantly.
final class PrefsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
    static let shared = PrefsWindowController()

    // Command-Tab pane — shortcut list: an "Or"/"Shortcut"
    // table on the left, the selected row's activate/move-up chips to its
    // right, +/− for custom triggers below.
    private enum RecordingKind { case moveUp, trigger }
    private let shortcutTable = NSTableView()
    private let shortcutScroll = NSScrollView()
    private let activateChip = NSButton(title: "—", target: nil, action: nil)
    private let activateClear = NSButton(title: "✕", target: nil, action: nil)
    private let moveUpChip = NSButton(title: "—", target: nil, action: nil)
    private let moveUpClear = NSButton(title: "✕", target: nil, action: nil)
    private let plusShortcut = NSButton(title: "+", target: nil, action: nil)
    private let minusShortcut = NSButton(title: "−", target: nil, action: nil)
    private let moveDownHint = NSTextField(wrappingLabelWithString: "To move down the list, press the first shortcut's key.")
    private var selectedShortcut = 0
    /// reloadData clamps selection to row 0 (empty selection is off), which
    /// fires tableViewSelectionDidChange before the explicit selectRowIndexes
    /// below — the flag keeps that transient from clobbering selectedShortcut.
    private var reloadingShortcutTable = false
    private var recordingKind: RecordingKind?
    private var recordingIndex: Int?

    // Panel pane
    private let themePopup = NSPopUpButton(frame: .zero)
    private let rowsField = NSTextField(frame: .zero)
    private let rowsStepper = NSStepper(frame: .zero)
    private let widthField = NSTextField(frame: .zero)
    private let displayPopup = NSPopUpButton(frame: .zero)
    private let delayCheck = NSButton(checkboxWithTitle: "Show Panel after a slight delay", target: nil, action: nil)
    private let activeOnlyCheck = NSButton(checkboxWithTitle: "List only windows on the display with the mouse", target: nil, action: nil)
    private let hoverCheck = NSButton(checkboxWithTitle: "Hovering a row selects it", target: nil, action: nil)
    private let ignoreMouseCheck = NSButton(checkboxWithTitle: "Ignore the mouse (no hover, click or scroll in the panel)", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Start AltTab at login", target: nil, action: nil)
    private let scrollCheck = NSButton(checkboxWithTitle: "Scroll wheel moves the selection", target: nil, action: nil)
    private let indicatorPopup = NSPopUpButton(frame: .zero)
    private let minimizedPopup = NSPopUpButton(frame: .zero)
    private let hiddenPopup = NSPopUpButton(frame: .zero)
    private let typingCheck = NSButton(checkboxWithTitle: "Typing searches while the panel is open", target: nil, action: nil)

    // Search pane
    private let shortcutsPopup = NSPopUpButton(frame: .zero)
    private let mismatchCheck = NSButton(checkboxWithTitle: "Allow mismatch (fuzzy subsequence matching)", target: nil, action: nil)


    // Rules pane
    private let appsOfPopup = NSPopUpButton(frame: .zero)
    private let orderPopup = NSPopUpButton(frame: .zero)
    private let showIgnoredCheck = NSButton(checkboxWithTitle: "Show ignored windows in a separate \"Ignored\" section", target: nil, action: nil)
    private let spacePopup = NSPopUpButton(frame: .zero)
    private let bySpaceRadio = NSButton(radioButtonWithTitle: "By Space", target: nil, action: nil)
    private let oneGroupRadio = NSButton(radioButtonWithTitle: "In One Group", target: nil, action: nil)
    private let manuallyRadio = NSButton(radioButtonWithTitle: "Manually", target: nil, action: nil)
    private let groupSlider = NSSlider(value: 5, minValue: 1, maxValue: 9, target: nil, action: nil)
    private let windowlessPopup = NSPopUpButton(frame: .zero)
    private let delayHelp = NSTextField(wrappingLabelWithString: "Tap and release quickly to switch to the last window.")
    private let groupHelp = NSTextField(wrappingLabelWithString: "This applies to Sidebar and Gesture Switcher. Command-Tab has its own separate options. When set to Manually, new apps & windows are distributed across groups; but you can re-order them or move them between groups by drag & drop and reserve spots for apps from the right-click menu.")
    private let countHelp = NSTextField(wrappingLabelWithString: "With \"In One Group\" or \"Manually\" there's an option to show the Numbers Badge. When \"Manually\" is selected groups can also be renamed.")
    private let windowlessHelp = NSTextField(wrappingLabelWithString: "Shows apps for which there are no AX windows, e.g. apps with hidden or background-only windows.")
    private let ignoredHelp = NSTextField(wrappingLabelWithString: "Tab reaches the section after the active windows, and focusing an ignored window never changes the order. In the panel, hold I to ignore (or un-ignore) the selected window, and hold V to show or hide the section for this session.")

    private let windowRulesView = WindowRulesView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
    private var tabView: NSTabView?
    private var built = false

    override init(window: NSWindow?) {
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    private var prefsWindow: NSWindow {
        if let w = window { return w }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
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

    /// Selects a tab by identifier ("Windows", "Rules", …) — used by the UI demo.
    func showTab(_ id: String) {
        buildIfNeeded()
        tabView?.selectTabViewItem(withIdentifier: id)
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

        // Shortcut list: "Or" checkbox column + trigger name; the
        // selected row's move-up recorder sits to its right.
        let orCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("or")); orCol.title = "Or"; orCol.width = 36
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); nameCol.title = "Shortcut"; nameCol.width = 160
        shortcutTable.addTableColumn(orCol); shortcutTable.addTableColumn(nameCol)
        shortcutTable.dataSource = self; shortcutTable.delegate = self
        shortcutTable.style = .plain
        shortcutTable.rowSizeStyle = .small
        shortcutTable.allowsEmptySelection = false
        shortcutScroll.documentView = shortcutTable
        shortcutScroll.hasVerticalScroller = true
        shortcutScroll.heightAnchor.constraint(equalToConstant: 128).isActive = true
        shortcutScroll.widthAnchor.constraint(equalToConstant: 240).isActive = true

        activateChip.bezelStyle = .rounded
        activateChip.target = self; activateChip.action = #selector(activateChipClicked(_:))
        activateClear.bezelStyle = .rounded; activateClear.controlSize = .small
        activateClear.target = self; activateClear.action = #selector(activateCleared(_:))
        moveUpChip.bezelStyle = .rounded
        moveUpChip.target = self; moveUpChip.action = #selector(moveUpChipClicked(_:))
        moveUpClear.bezelStyle = .rounded; moveUpClear.controlSize = .small
        moveUpClear.target = self; moveUpClear.action = #selector(moveUpCleared(_:))
        plusShortcut.bezelStyle = .smallSquare; plusShortcut.controlSize = .small
        plusShortcut.widthAnchor.constraint(equalToConstant: 26).isActive = true
        plusShortcut.toolTip = "Add a custom shortcut"
        plusShortcut.target = self; plusShortcut.action = #selector(plusShortcutClicked(_:))
        minusShortcut.bezelStyle = .smallSquare; minusShortcut.controlSize = .small
        minusShortcut.widthAnchor.constraint(equalToConstant: 26).isActive = true
        minusShortcut.toolTip = "Remove the selected custom shortcut"
        minusShortcut.target = self; minusShortcut.action = #selector(minusShortcutClicked(_:))
        moveDownHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        moveDownHint.textColor = .secondaryLabelColor
        moveDownHint.preferredMaxLayoutWidth = 180

        let actChipRow = NSStackView(views: [activateChip, activateClear]); actChipRow.spacing = 4
        let upChipRow = NSStackView(views: [moveUpChip, moveUpClear]); upChipRow.spacing = 4
        let plusRow = NSStackView(views: [plusShortcut, minusShortcut]); plusRow.spacing = 4
        let detailGrid = NSGridView(views: [
            [label("Activate switcher with:"), actChipRow],
            [label("Move up list with:"), upChipRow],
            [NSGridCell.emptyContentView, moveDownHint],
        ])
        detailGrid.rowSpacing = 8
        detailGrid.column(at: 0).xPlacement = .trailing
        let listRow = NSStackView(views: [shortcutScroll, detailGrid])
        listRow.orientation = .horizontal; listRow.spacing = 16; listRow.alignment = .top

        delayCheck.target = self; delayCheck.action = #selector(delayToggled(_:))
        typingCheck.target = self; typingCheck.action = #selector(typingToggled(_:))
        indicatorPopup.target = self; indicatorPopup.action = #selector(indicatorChanged(_:))
        shortcutsPopup.addItems(withTitles: ["Off", "Remember last query", "Last 3 queries", "Last 5 queries"])
        shortcutsPopup.target = self; shortcutsPopup.action = #selector(shortcutsChanged(_:))
        mismatchCheck.target = self; mismatchCheck.action = #selector(mismatchToggled(_:))

        let cmdTabGrid = NSGridView(views: [
            [label("Switch windows:")],
            [NSGridCell.emptyContentView, listRow],
            [NSGridCell.emptyContentView, plusRow],
            [NSGridCell.emptyContentView, delayCheck],
            [NSGridCell.emptyContentView, delayHelp],
            [NSGridCell.emptyContentView, typingCheck],
            [label("Search Shortcuts:"), shortcutsPopup],
            [NSGridCell.emptyContentView, mismatchCheck],
            [label("Show:"), indicatorPopup],
        ])

        // Panel pane ---------------------------------------------------------
        rowsStepper.minValue = 3; rowsStepper.maxValue = 16; rowsStepper.increment = 1
        rowsField.target = self; rowsField.action = #selector(rowsEdited(_:))
        rowsStepper.target = self; rowsStepper.action = #selector(rowsStepped(_:))
        widthField.target = self; widthField.action = #selector(widthEdited(_:))
        displayPopup.addItems(withTitles: ["On all displays", "Primary display only", "Display with mouse"])
        displayPopup.target = self; displayPopup.action = #selector(displayChanged(_:))
        activeOnlyCheck.target = self; activeOnlyCheck.action = #selector(activeOnlyToggled(_:))
        hoverCheck.target = self; hoverCheck.action = #selector(hoverToggled(_:))
        scrollCheck.target = self; scrollCheck.action = #selector(scrollToggled(_:))
        loginCheck.target = self; loginCheck.action = #selector(loginToggled(_:))
        ignoreMouseCheck.target = self; ignoreMouseCheck.action = #selector(ignoreMouseToggled(_:))
        indicatorPopup.addItems(withTitles: ["Search hints", "Numbers 1–9", "Neither"])
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
            [label("Minimized windows:"), minimizedPopup],
            [label("Hidden apps:"), hiddenPopup],
            [NSGridCell.emptyContentView, activeOnlyCheck],
            [NSGridCell.emptyContentView, hoverCheck],
            [NSGridCell.emptyContentView, scrollCheck],
            [NSGridCell.emptyContentView, ignoreMouseCheck],
            [NSGridCell.emptyContentView, loginCheck],
        ])

        // Rules pane -----------------------------------------------------------
        appsOfPopup.addItems(withTitles: ["Windows of all apps", "Windows of the active app only"])
        appsOfPopup.target = self; appsOfPopup.action = #selector(appsOfChanged(_:))
        orderPopup.addItems(withTitles: ["Most recently used", "Application launch order"])
        showIgnoredCheck.target = self; showIgnoredCheck.action = #selector(showIgnoredToggled(_:))
        orderPopup.target = self; orderPopup.action = #selector(orderChanged(_:))
        spacePopup.addItems(withTitles: ["All Spaces", "Visible Spaces (+ fullscreen)", "Visible Spaces"])
        spacePopup.target = self; spacePopup.action = #selector(spaceChanged(_:))
        for r in [bySpaceRadio, oneGroupRadio, manuallyRadio] {
            r.target = self; r.action = #selector(groupingRadioChanged(_:))
        }
        groupSlider.minValue = 1; groupSlider.maxValue = 9
        groupSlider.numberOfTickMarks = 9; groupSlider.allowsTickMarkValuesOnly = true
        groupSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        groupSlider.target = self; groupSlider.action = #selector(groupCountSliderChanged(_:))
        windowlessPopup.target = self; windowlessPopup.action = #selector(policyChanged(_:))
        let groupRadios = NSStackView(views: [bySpaceRadio, oneGroupRadio, manuallyRadio])
        groupRadios.orientation = .vertical; groupRadios.alignment = .leading; groupRadios.spacing = 4
        let tickLabels = NSStackView(views: [label("1"), label("5"), label("9")])
        tickLabels.distribution = .fillEqually
        // Width comes from the grid: tickLabels shares groupSlider's column.
        // Never activate cross-view constraints here — both views are detached
        // (their tab-box ancestor installs lazily), and activating raises
        // NSInternalInconsistencyException, which AppKit's menu dispatch
        // swallows, silently abandoning the rest of buildIfNeeded.
        for c in tickLabels.arrangedSubviews { (c as? NSTextField)?.alignment = .center }
        for h in [groupHelp, countHelp, windowlessHelp, delayHelp, ignoredHelp] {
            h.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            h.textColor = .secondaryLabelColor
            h.preferredMaxLayoutWidth = 340
        }
        let rulesGrid = NSGridView(views: [
            [label("Group windows:"), groupRadios],
            [NSGridCell.emptyContentView, groupHelp],
            [label("Number of Groups:"), groupSlider],
            [NSGridCell.emptyContentView, tickLabels],
            [NSGridCell.emptyContentView, countHelp],
            [label("Apps without windows:"), windowlessPopup],
            [NSGridCell.emptyContentView, windowlessHelp],
            [label("Show windows of:"), appsOfPopup],
            [label("Show windows from:"), spacePopup],
            [label("Order windows by:"), orderPopup],
            [NSGridCell.emptyContentView, showIgnoredCheck],
            [NSGridCell.emptyContentView, ignoredHelp],
        ])

        for grid in [cmdTabGrid, panelGrid, rulesGrid] {
            grid.rowSpacing = 10
            grid.columnSpacing = 12
            grid.column(at: 0).xPlacement = .trailing
        }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 360))
        tabView = tabs
        tabs.addTabViewItem(tab("Command-Tab", cmdTabGrid))
        tabs.addTabViewItem(tab("Panel", panelGrid))
        tabs.addTabViewItem(tab("Rules", rulesGrid, height: 620))
        let windowsItem = NSTabViewItem(identifier: "Windows")
        windowsItem.label = "Windows"
        windowsItem.view = windowRulesView
        tabs.addTabViewItem(windowsItem)
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
        ])
    }

    private func tab(_ name: String, _ grid: NSGridView, height: CGFloat = 330) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: name)
        item.label = name
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
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
        activeOnlyCheck.state = PrefsStore.activeDisplayOnly ? .on : .off
        hoverCheck.state = PrefsStore.hoverSelects ? .on : .off
        scrollCheck.state = PrefsStore.scrollSelects ? .on : .off
        ignoreMouseCheck.state = PrefsStore.ignoreMouse ? .on : .off
        indicatorPopup.selectItem(at: PrefsStore.RowIndicator.allCases.firstIndex(of: PrefsStore.rowIndicator) ?? 0)
        minimizedPopup.selectItem(at: PrefsStore.WindowPolicy.allCases.firstIndex(of: PrefsStore.minimizedPolicy) ?? 0)
        hiddenPopup.selectItem(at: PrefsStore.WindowPolicy.allCases.firstIndex(of: PrefsStore.hiddenPolicy) ?? 0)
        delayCheck.state = PrefsStore.panelShowDelay ? .on : .off
        refreshLoginCheck()
        typingCheck.state = PrefsStore.typingStartsFastSearch ? .on : .off

        mismatchCheck.state = PrefsStore.searchAllowMismatch ? .on : .off
        shortcutsPopup.selectItem(at: [0, 1, 3, 5].firstIndex(of: PrefsStore.searchShortcutsDepth) ?? 0)

        appsOfPopup.selectItem(at: PrefsStore.appsOfAll ? 0 : 1)
        orderPopup.selectItem(at: PrefsStore.orderByRecency ? 0 : 1)
        showIgnoredCheck.state = PrefsStore.showIgnored ? .on : .off
        windowRulesView.reload()
        bySpaceRadio.state = PrefsStore.grouping == .bySpace ? .on : .off
        oneGroupRadio.state = PrefsStore.grouping == .oneGroup ? .on : .off
        manuallyRadio.state = PrefsStore.grouping == .manually ? .on : .off
        spacePopup.selectItem(at: PrefsStore.SpaceScope.allCases.firstIndex(of: PrefsStore.spaceScope) ?? 0)
        groupSlider.integerValue = PrefsStore.groupCount
        windowlessPopup.selectItem(at: PrefsStore.WindowPolicy.allCases.firstIndex(of: PrefsStore.windowlessPolicy) ?? 0)

        refreshShortcutTable()
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
        // Panels are rebuilt per open, but an open panel re-skins in place.
        SwitcherSession.shared.applyThemeLive()
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

    /// Login item state lives in the system (SMAppService), not UserDefaults,
    /// so the checkbox always reflects what System Settings shows.
    private func refreshLoginCheck() {
        if #available(macOS 13.0, *) {
            loginCheck.isEnabled = true
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginCheck.isEnabled = false
            loginCheck.state = .off
            loginCheck.toolTip = "Requires macOS 13 or later"
        }
    }

    @objc private func loginToggled(_ sender: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
            NSLog("AltTab: login item change failed: \(error)")
        }
        refreshLoginCheck()
    }

    @objc private func activeOnlyToggled(_ sender: NSButton) { PrefsStore.activeDisplayOnly = sender.state == .on }
    @objc private func hoverToggled(_ sender: NSButton) { PrefsStore.hoverSelects = sender.state == .on }
    @objc private func scrollToggled(_ sender: NSButton) { PrefsStore.scrollSelects = sender.state == .on }
    @objc private func ignoreMouseToggled(_ sender: NSButton) { PrefsStore.ignoreMouse = sender.state == .on }
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

    @objc private func showIgnoredToggled(_ sender: NSButton) {
        PrefsStore.showIgnored = sender.state == .on
        PrefsStore.sessionShowIgnored = nil
        WindowTracker.shared.refresh(reason: "prefs:showIgnored")
    }
    @objc private func orderChanged(_ sender: NSPopUpButton) { PrefsStore.orderByRecency = sender.indexOfSelectedItem == 0 }
    @objc private func appsOfChanged(_ sender: NSPopUpButton) { PrefsStore.appsOfAll = sender.indexOfSelectedItem == 0 }
    @objc private func groupingRadioChanged(_ sender: NSButton) {
        PrefsStore.grouping = sender === bySpaceRadio ? .bySpace : sender === oneGroupRadio ? .oneGroup : .manually
    }
    @objc private func spaceChanged(_ sender: NSPopUpButton) {
        PrefsStore.spaceScope = PrefsStore.SpaceScope.allCases[sender.indexOfSelectedItem]
        WindowTracker.shared.refresh(reason: "spaceScope")
    }
    @objc private func groupCountSliderChanged(_ sender: NSSlider) {
        PrefsStore.groupCount = min(9, max(1, sender.integerValue))
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        PrefsStore.shortcuts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === shortcutTable {
            let cell = NSTableCellView()
            let sc = PrefsStore.shortcuts[row]
            if tableColumn?.identifier.rawValue == "or" {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(shortcutToggled(_:)))
                box.tag = row
                box.state = sc.on ? .on : .off
                cell.addSubview(box)
                box.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    box.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                let field = NSTextField(string: shortcutName(sc))
                field.isBordered = false; field.drawsBackground = false
                field.isSelectable = true
                cell.addSubview(field)
                field.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }
        return nil
    }

    // MARK: - Shortcut list actions

    /// Fixed-four display name; custom rows render their recorded combo.
    private func shortcutName(_ sc: PrefsStore.TriggerShortcut) -> String {
        let fixed = ["⌘Tab", "⌘`", "⌥Tab", "⌥`"]
        if sc.mods == 0 && sc.key == 0 { return "Add a shortcut…" }
        let name = describeBinding(sc.mods, sc.key)
        return fixed.contains(name) ? name : name
    }

    private func refreshShortcutTable() {
        guard built else { return }
        reloadingShortcutTable = true
        shortcutTable.reloadData()
        let rows = PrefsStore.shortcuts.count
        shortcutTable.selectRowIndexes(IndexSet(integer: min(selectedShortcut, max(0, rows - 1))),
                                       byExtendingSelection: false)
        reloadingShortcutTable = false
        syncShortcutDetail()
    }

    /// Selected row's chips: activate combo and move-up combo.
    private func syncShortcutDetail() {
        guard built, PrefsStore.shortcuts.indices.contains(selectedShortcut) else { return }
        let sc = PrefsStore.shortcuts[selectedShortcut]
        let isFixed = selectedShortcut < 4
        let empty = sc.mods == 0 && sc.key == 0
        activateChip.title = empty ? "record…" : describeBinding(sc.mods, sc.key)
        activateClear.isEnabled = !isFixed && !empty
        moveUpChip.title = sc.upMods == 0 ? "—" : describeBinding(sc.upMods, sc.upKey)
        moveUpClear.isEnabled = sc.upMods != 0
        minusShortcut.isEnabled = !isFixed
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === shortcutTable,
              !reloadingShortcutTable else { return }
        selectedShortcut = shortcutTable.selectedRow
        if selectedShortcut < 0 { selectedShortcut = 0; return }
        syncShortcutDetail()
    }

    @objc private func shortcutToggled(_ sender: NSButton) {
        stopRecording()   // a list mutation must never leave the tap suspended
        var list = PrefsStore.shortcuts
        list[sender.tag].on = sender.state == .on
        PrefsStore.shortcuts = list
        SwitcherSession.shared.installShortcuts()
    }

    @objc private func plusShortcutClicked(_ sender: NSButton) {
        stopRecording()   // keep at most one armed recorder, never across a reselect
        var list = PrefsStore.shortcuts
        list.append(PrefsStore.TriggerShortcut(on: false, mods: 0, key: 0, upMods: 0, upKey: 0))
        PrefsStore.shortcuts = list
        selectedShortcut = list.count - 1
        refreshShortcutTable()
    }

    @objc private func minusShortcutClicked(_ sender: NSButton) {
        stopRecording()   // removing the armed row must also un-suspend the tap
        guard selectedShortcut >= 4, PrefsStore.shortcuts.count > selectedShortcut else { return }
        var list = PrefsStore.shortcuts
        list.remove(at: selectedShortcut)
        PrefsStore.shortcuts = list
        // Only fixed rows may remain: clamp to the last valid index (their
        // chips must re-sync; an out-of-range index would skip syncShortcutDetail).
        selectedShortcut = min(4, list.count - 1)
        SwitcherSession.shared.installShortcuts()
        refreshShortcutTable()
    }

    @objc private func activateChipClicked(_ sender: NSButton) {
        guard selectedShortcut < PrefsStore.shortcuts.count else { return }
        if recordingKind == .trigger, recordingIndex == selectedShortcut { stopRecording(); return }
        recordingKind = .trigger
        recordingIndex = selectedShortcut
        activateChip.title = "press keys…"
        startRecording()
    }

    @objc private func activateCleared(_ sender: NSButton) {
        guard selectedShortcut >= 4 else { return }
        var list = PrefsStore.shortcuts
        list[selectedShortcut].mods = 0; list[selectedShortcut].key = 0
        list[selectedShortcut].on = false
        PrefsStore.shortcuts = list
        SwitcherSession.shared.installShortcuts()
        refreshShortcutTable()
    }

    @objc private func moveUpChipClicked(_ sender: NSButton) {
        guard selectedShortcut < PrefsStore.shortcuts.count else { return }
        if recordingKind == .moveUp, recordingIndex == selectedShortcut { stopRecording(); return }
        recordingKind = .moveUp
        recordingIndex = selectedShortcut
        moveUpChip.title = "press keys…"
        startRecording()
    }

    @objc private func moveUpCleared(_ sender: NSButton) {
        var list = PrefsStore.shortcuts
        guard list.indices.contains(selectedShortcut), list[selectedShortcut].upMods != 0 else { return }
        list[selectedShortcut].upMods = 0; list[selectedShortcut].upKey = 0
        PrefsStore.shortcuts = list
        refreshShortcutTable()
    }

    private func startRecording() {
        prefsWindow.makeKeyAndOrderFront(nil)
        // The tap passes events through untouched while recording (suspended):
        // the recorder's local monitor needs them, and a recorded combo that
        // matches a live trigger must not be consumed by the tap first.
        HotkeyCenter.shared.suspended = true
        HotkeyCenter.shared.setRecordingCapture(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingKind != nil else { return event }
            self.handleRecordedKey(event)
            return nil   // consumed
        }
    }

    /// Records an activate or move-up binding: modifier(s) + key. Esc cancels.
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
        guard mask != 0, let kind = recordingKind, let index = recordingIndex else { return }
        var list = PrefsStore.shortcuts
        guard list.indices.contains(index) else { stopRecording(); return }
        switch kind {
        case .moveUp:
            list[index].upMods = mask
            list[index].upKey = UInt32(event.keyCode)
        case .trigger:
            list[index].mods = mask
            list[index].key = UInt32(event.keyCode)
            list[index].on = true
        }
        PrefsStore.shortcuts = list
        SwitcherSession.shared.installShortcuts()
        stopRecording()
        syncFromStore()
    }

    private var keyMonitor: Any?
    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingKind = nil
        recordingIndex = nil
        HotkeyCenter.shared.suspended = false
        HotkeyCenter.shared.setRecordingCapture(false)
        if built { syncFromStore() }
    }
}
