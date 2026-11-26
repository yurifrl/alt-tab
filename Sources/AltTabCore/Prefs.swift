import AppKit
import Carbon.HIToolbox

/// Settings facade. Every value lives in `config.yaml` (see `ConfigStore`);
/// this type keeps the names, types and semantics the rest of the app was
/// written against, so consumers read live and never see the file.
enum PrefsStore {
    typealias Theme = Config.Theme
    typealias PanelDisplay = Config.PanelDisplay
    typealias SpaceScope = Config.SpaceScope
    typealias WindowPolicy = Config.WindowPolicy
    typealias RowIndicator = Config.RowIndicator
    typealias Grouping = Config.Grouping
    typealias UpdateChannel = Config.UpdateChannel
    typealias Matcher = Config.Matcher
    typealias WindowRule = Config.WindowRule
    typealias TriggerShortcut = Config.Shortcut

    // MARK: Appearance / layout

    static var theme: Theme {
        get { ConfigStore.values.appearance.theme }
        set { ConfigStore.mutate { $0.appearance.theme = newValue } }
    }

    /// Sparkle update channel. `stable` (default) sees numbered releases only;
    /// `nightly` also sees rolling builds tracked by the nightly workflow.
    /// Read by Updater on every manual check, so a change applies immediately.
    static var updateChannel: UpdateChannel {
        get { ConfigStore.values.updates.channel }
        set { ConfigStore.mutate { $0.updates.channel = newValue } }
    }

    static var maxRows: Int {
        get { ConfigStore.values.panel.maxRows }
        set { ConfigStore.mutate { $0.panel.maxRows = min(max(newValue, 1), 20) } }
    }

    /// Panel width in points, Narrow→Wide slider (default ≈ 560).
    static var panelWidth: Double {
        get { ConfigStore.values.panel.width }
        set { ConfigStore.mutate { $0.panel.width = newValue > 0 ? newValue : 1 } }
    }

    static var panelDisplay: PanelDisplay {
        get { ConfigStore.values.panel.display }
        set { ConfigStore.mutate { $0.panel.display = newValue } }
    }

    /// "Show Panel after a slight delay" (avoids flicker on quick
    /// switch to last window). Off stores 0 (immediate).
    static var panelShowDelay: Bool {
        get { ConfigStore.values.panel.showDelay > 0 }
        set { ConfigStore.mutate { $0.panel.showDelay = newValue ? 0.35 : 0 } }
    }

    /// List only windows on the display holding the mouse (minimized ones stay).
    static var activeDisplayOnly: Bool {
        get { ConfigStore.values.panel.activeDisplayOnly }
        set { ConfigStore.mutate { $0.panel.activeDisplayOnly = newValue } }
    }

    static var hoverSelects: Bool {
        get { ConfigStore.values.panel.hoverSelects }
        set { ConfigStore.mutate { $0.panel.hoverSelects = newValue } }
    }

    static var scrollSelects: Bool {
        get { ConfigStore.values.panel.scrollSelects }
        set { ConfigStore.mutate { $0.panel.scrollSelects = newValue } }
    }

    /// Master switch: the panel ignores hover, click and scroll entirely.
    static var ignoreMouse: Bool {
        get { ConfigStore.values.panel.ignoreMouse }
        set { ConfigStore.mutate { $0.panel.ignoreMouse = newValue } }
    }

    static var rowIndicator: RowIndicator {
        get { ConfigStore.values.panel.rowIndicator }
        set { ConfigStore.mutate { $0.panel.rowIndicator = newValue } }
    }

    // MARK: Hotkeys (Carbon masks)

    /// Default set: ⌘Tab (move up ⌘`), ⌘` (move up ⌘Tab), ⌥Tab
    /// (move up ⌥`), ⌥` (move up ⌥Tab) — the Command pair enabled.
    static let defaultShortcuts: [TriggerShortcut] = Config.defaultShortcuts

    /// Persisted shortcut list, row 0 first.
    static var shortcuts: [TriggerShortcut] {
        get { ConfigStore.values.shortcuts }
        set { ConfigStore.mutate { $0.shortcuts = newValue } }
    }

    // MARK: Search

    /// Search Shortcuts depth (0 off,1,3,5 remembered-query chars).
    static var searchShortcutsDepth: Int {
        get { ConfigStore.values.search.shortcutsDepth }
        set { ConfigStore.mutate { $0.search.shortcutsDepth = min(max(newValue, 0), 20) } }
    }

    static var searchAllowMismatch: Bool {
        get { ConfigStore.values.search.allowMismatch }
        set { ConfigStore.mutate { $0.search.allowMismatch = newValue } }
    }

    // MARK: Panel policies

    static var spaceScope: SpaceScope {
        get { ConfigStore.values.workspaces.spaceScope }
        set { ConfigStore.mutate { $0.workspaces.spaceScope = newValue } }
    }

    static var appsOfAll: Bool {
        get { ConfigStore.values.workspaces.appsOfAll }
        set { ConfigStore.mutate { $0.workspaces.appsOfAll = newValue } }
    }

    /// Order apps by most recent activation (default) instead of launch order.
    static var orderByRecency: Bool {
        get { ConfigStore.values.workspaces.orderByRecency }
        set { ConfigStore.mutate { $0.workspaces.orderByRecency = newValue } }
    }

    /// Show ignored (excluded) windows at the bottom of the panel. Tab cycling
    /// skips them and focusing one never changes the recency order.
    static var showIgnored: Bool {
        get { ConfigStore.values.workspaces.showIgnored }
        set { ConfigStore.mutate { $0.workspaces.showIgnored = newValue } }
    }

    /// Hold-v in the panel: flips visibility of ignored windows until the app
    /// quits, without touching the saved preference.
    static var sessionShowIgnored: Bool?
    static var showIgnoredNow: Bool { sessionShowIgnored ?? showIgnored }

    /// Hold-i: hide the window (pinned to its window id, so tab/title changes
    /// don't lose it); toggles off if that rule already hides it. A rule that
    /// also carries an alias/color is kept, only its Hide flag flips.
    @discardableResult
    static func toggleIgnore(_ w: WindowModel) -> Bool {
        guard !w.bundleId.isEmpty, !w.title.isEmpty else { return false }
        var list = windowRules
        if let i = ruleIndex(in: list, for: w) {
            if list[i].hide && list[i].alias.isEmpty && list[i].color.isEmpty { list.remove(at: i) } else { list[i].hide.toggle() }
        } else {
            var r = pinnedRule(for: w, hide: true)
            if w.windowId == 0 { r.matchers = [Matcher(kind: .exact, text: w.title)]; r.windowTitle = "" }
            list.append(r)
        }
        windowRules = list
        return true
    }

    static var minimizedPolicy: WindowPolicy {
        get { ConfigStore.values.workspaces.minimized }
        set { ConfigStore.mutate { $0.workspaces.minimized = newValue } }
    }

    static var hiddenPolicy: WindowPolicy {
        get { ConfigStore.values.workspaces.hidden }
        set { ConfigStore.mutate { $0.workspaces.hidden = newValue } }
    }

    /// Apps without AX windows ("windowless apps"). Three-state like
    /// minimized/hidden; the legacy bool was folded in at first import.
    static var windowlessPolicy: WindowPolicy {
        get { ConfigStore.values.workspaces.windowless }
        set { ConfigStore.mutate { $0.workspaces.windowless = newValue } }
    }

    /// Panel-only: letters type into the search while the panel is visible.
    static var typingStartsFastSearch: Bool {
        get { ConfigStore.values.panel.typingStartsFastSearch }
        set { ConfigStore.mutate { $0.panel.typingStartsFastSearch = newValue } }
    }

    // MARK: Rules (workspaces)

    static var grouping: Grouping {
        get { ConfigStore.values.workspaces.grouping }
        set { ConfigStore.mutate { $0.workspaces.grouping = newValue } }
    }

    static var groupCount: Int {
        get { ConfigStore.values.workspaces.groupCount }
        set { ConfigStore.mutate { $0.workspaces.groupCount = min(max(newValue, 1), 9) } }
    }

    /// Persisted rule list, in list order.
    static var windowRules: [WindowRule] {
        get { ConfigStore.values.rules }
        set {
            ConfigStore.mutate { $0.rules = newValue }
            NotificationCenter.default.post(name: windowRulesChanged, object: nil)
        }
    }

    /// Posted after every write to `windowRules` (Preferences list reloads).
    static let windowRulesChanged = Notification.Name("at.windowRulesChanged")

    /// Rule match. A pinned rule matches only its window id (and app). An
    /// empty app id makes the rule generic: it matches windows of any app,
    /// narrowed by its title conditions. A condition-less rule whose app id is
    /// not a bundle id (no ".") keeps the legacy loose matching on the app's name.
    private static func matches(_ r: WindowRule, _ w: WindowModel) -> Bool {
        if r.windowId != 0 { return w.windowId == r.windowId && r.bundleId == w.bundleId }
        let appMatches = r.bundleId.isEmpty || r.bundleId == w.bundleId
            || (r.matchers.isEmpty && !r.bundleId.contains(".") && !r.bundleId.isEmpty
                && w.appLocalName.localizedCaseInsensitiveContains(r.bundleId))
        guard appMatches else { return false }
        guard !r.matchers.isEmpty else { return true }
        return r.matchAll ? r.matchers.allSatisfy { $0.matches(w) }
                          : r.matchers.contains { $0.matches(w) }
    }

    /// Rule match for a tracked window.
    static func ruleMatches(_ r: WindowRule, window w: WindowModel) -> Bool { matches(r, w) }

    /// True when the window must not appear per the Hide rules.
    static func isExcluded(_ w: WindowModel) -> Bool {
        windowRules.contains { $0.hide && matches($0, w) }
    }

    /// Best rule among those matching and having a value: pinned > title
    /// conditions > app-wide > generic (every app).
    private static func best(_ w: WindowModel, _ has: (WindowRule) -> Bool) -> WindowRule? {
        let hits = windowRules.filter { has($0) && matches($0, w) }
        return hits.first { $0.windowId != 0 }
            ?? hits.first { !$0.matchers.isEmpty }
            ?? hits.first { !$0.bundleId.isEmpty }
            ?? hits.first
    }

    static func alias(for w: WindowModel) -> String? { best(w) { !$0.alias.isEmpty }?.alias }
    static func color(for w: WindowModel) -> String? { best(w) { !$0.color.isEmpty }?.color }

    private static func pinnedRule(for w: WindowModel, hide: Bool = false) -> WindowRule {
        WindowRule(bundleId: w.bundleId, hide: hide, alias: "", color: "",
                   windowId: w.windowId, windowTitle: w.title)
    }

    /// The rule that targets exactly this window: pinned to its id, or (no id
    /// available) the exact-title pattern.
    private static func ruleIndex(in list: [WindowRule], for w: WindowModel) -> Int? {
        if w.windowId != 0 {
            return list.firstIndex { $0.bundleId == w.bundleId && $0.windowId == w.windowId }
        }
        return list.firstIndex {
            $0.bundleId == w.bundleId && $0.windowId == 0
                && $0.matchers == [Matcher(kind: .exact, text: w.title)]
        }
    }

    /// Hold-E: set (or clear, with "") alias and color of the rule pinned to
    /// this window. A rule left with no alias, color or hide is dropped.
    static func setAppearance(for w: WindowModel, alias: String, color: String) {
        guard !w.bundleId.isEmpty, !w.title.isEmpty else { return }
        var list = windowRules
        if let i = ruleIndex(in: list, for: w) {
            list[i].alias = alias
            list[i].color = color
            if alias.isEmpty && color.isEmpty && !list[i].hide { list.remove(at: i) }
        } else if !alias.isEmpty || !color.isEmpty {
            var r = pinnedRule(for: w)
            if w.windowId == 0 { r.matchers = [Matcher(kind: .exact, text: w.title)]; r.windowTitle = "" }
            r.alias = alias; r.color = color
            list.append(r)
        }
        windowRules = list
    }

    // MARK: In-panel action keys (Panel pane: Close/Quit/Minimize/Hide rows)
    // Not settings any more (dropped keys): Option is the one modifier set.

    static var actionCloseWinMods: UInt32 { UInt32(optionKey) }
    static var actionQuitMods: UInt32 { UInt32(optionKey) }
    static var actionMinimizeMods: UInt32 { UInt32(optionKey) }
    static var actionHideMods: UInt32 { UInt32(optionKey) }

    /// NSAppearance name + NSVisualEffectView.Material for a theme.
    static func appearance(for theme: Theme) -> (name: NSAppearance.Name, material: NSVisualEffectView.Material) {
        switch theme {
        case .vibrantDark: return (.darkAqua, .hudWindow)
        case .vibrantLight: return (.aqua, .underWindowBackground)
        case .auto:
            let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? (.darkAqua, .hudWindow) : (.aqua, .underWindowBackground)
        }
    }
}
