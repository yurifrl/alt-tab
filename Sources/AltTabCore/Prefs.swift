import AppKit
import Carbon.HIToolbox

/// Preferences, namespaced `at.*`. Mirrors the Contexts option surface
/// (Command-Tab, Panel, Rules panes).
/// Everything persisted; consumers read live on each use.
enum PrefsStore {
    enum Theme: String, CaseIterable { case auto, vibrantLight, vibrantDark }

    /// Where switcher panels appear.
    enum PanelDisplay: String, CaseIterable { case all, primary, active }
    /// Window space filter (Contexts "Show windows from").
    enum SpaceScope: String, CaseIterable { case allSpaces, visibleAndFullscreen, visibleSpaces }
    /// Per-class window visibility policy (Contexts: Show / Show at bottom / Do not show).
    enum WindowPolicy: String, CaseIterable { case show, showAtBottom, doNotShow }
    /// What the panel shows next to each row (Contexts "Show:").
    enum RowIndicator: String, CaseIterable { case searchHints, numbers, neither }
    /// Space grouping (Contexts "Group windows").
    enum Grouping: String, CaseIterable { case bySpace, oneGroup, manually }

    private static let d = UserDefaults.standard

    private enum Key {
        static let theme = "at.appearance.theme"
        static let maxRows = "at.panel.maxRows"
        static let hotkeyMods = "at.hotkey.modifierFlags"
        static let hotkeyKey = "at.hotkey.virtualKey"
        static let moveUpMods = "at.hotkey.moveUpFlags"
        static let moveUpKey = "at.hotkey.moveUpKey"
        static let searchMods = "at.hotkey.searchFlags"
        static let shortcuts = "at.shortcuts.list"
        static let searchShortcuts = "at.search.shortcutsDepth" // 0=off,1,3,5
        static let searchMismatch = "at.search.allowMismatch"
        static let workspaceExcludes = "at.workspaces.appExcludes"   // [String] bundle ids
        static let workspaceTitleExcludes = "at.workspaces.titleExcludes" // [String] "bundle|pattern"
        static let showWindowlessApps = "at.rules.showWindowlessApps"    // Bool
        static let panelDisplay = "at.panel.showOn"
        static let panelWidth = "at.panel.width"
        static let panelDelay = "at.panel.showAfterDelay"
        static let hoverSelects = "at.panel.hoverSelects"
        static let scrollSelects = "at.panel.scrollSelects"
        static let ignoreMouse = "at.panel.ignoreMouse"
        static let spaceScope = "at.panel.spaceScope"
        static let minimizedPolicy = "at.panel.minimizedPolicy"
        static let orderByRecency = "at.panel.orderByRecency"
        static let showIgnored = "at.panel.showIgnored"
        static let hiddenPolicy = "at.panel.hiddenPolicy"
        static let windowlessPolicy = "at.panel.windowlessPolicy"
        static let appsOf = "at.panel.appsOf"        // all | active
        static let typingStartsFastSearch = "at.panel.typingStartsFastSearch"
        static let showRowIndicator = "at.panel.rowIndicator"
        static let actionCloseWinMods = "at.action.closeWindowFlags"
        static let actionQuitMods = "at.action.quitFlags"
        static let actionMinimizeMods = "at.action.minimizeFlags"
        static let actionHideMods = "at.action.hideFlags"
        static let grouping = "at.workspaces.grouping"
        static let groupCount = "at.workspaces.groupCount"
    }

    // MARK: Appearance / layout

    static var theme: Theme {
        get { Theme(rawValue: d.string(forKey: Key.theme) ?? "") ?? .vibrantDark }
        set { d.set(newValue.rawValue, forKey: Key.theme) }
    }

    static var maxRows: Int {
        get { d.object(forKey: Key.maxRows) as? Int ?? 8 }
        set { d.set(newValue, forKey: Key.maxRows) }
    }

    /// Panel width in points, Narrow→Wide slider (Contexts default ≈ 560).
    static var panelWidth: Double {
        get { d.object(forKey: Key.panelWidth) as? Double ?? 920 }
        set { d.set(newValue, forKey: Key.panelWidth) }
    }

    static var panelDisplay: PanelDisplay {
        get { PanelDisplay(rawValue: d.string(forKey: Key.panelDisplay) ?? "") ?? .active }
        set { d.set(newValue.rawValue, forKey: Key.panelDisplay) }
    }

    /// Contexts "Show Panel after a slight delay" (avoids flicker on quick
    /// switch to last window).
    static var panelShowDelay: Bool {
        get { d.object(forKey: Key.panelDelay) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.panelDelay) }
    }

    static var hoverSelects: Bool {
        get { d.bool(forKey: Key.hoverSelects) }
        set { d.set(newValue, forKey: Key.hoverSelects) }
    }

    static var scrollSelects: Bool {
        get { d.bool(forKey: Key.scrollSelects) }
        set { d.set(newValue, forKey: Key.scrollSelects) }
    }

    /// Master switch: the panel ignores hover, click and scroll entirely.
    static var ignoreMouse: Bool {
        get { d.bool(forKey: Key.ignoreMouse) }
        set { d.set(newValue, forKey: Key.ignoreMouse) }
    }

    static var rowIndicator: RowIndicator {
        get { RowIndicator(rawValue: d.string(forKey: Key.showRowIndicator) ?? "") ?? .searchHints }
        set { d.set(newValue.rawValue, forKey: Key.showRowIndicator) }
    }

    // MARK: Hotkeys (Carbon masks)

    /// One switcher trigger shortcut. `mods`/`key` open+cycle (hold-to-switch);
    /// `upMods`/`upKey` optionally move the selection back (0 = unset).
    struct TriggerShortcut: Codable, Equatable {
        var on: Bool
        var mods: UInt32
        var key: UInt32
        var upMods: UInt32
        var upKey: UInt32
    }

    /// Contexts' default set: ⌘Tab (move up ⌘`), ⌘` (move up ⌘Tab), ⌥Tab
    /// (move up ⌥`), ⌥` (move up ⌥Tab) — the Command pair enabled.
    static let defaultShortcuts: [TriggerShortcut] = [
        TriggerShortcut(on: true, mods: UInt32(cmdKey), key: UInt32(kVK_Tab),
                        upMods: UInt32(cmdKey), upKey: UInt32(kVK_ANSI_Grave)),
        TriggerShortcut(on: true, mods: UInt32(cmdKey), key: UInt32(kVK_ANSI_Grave),
                        upMods: UInt32(cmdKey), upKey: UInt32(kVK_Tab)),
        TriggerShortcut(on: false, mods: UInt32(optionKey), key: UInt32(kVK_Tab),
                        upMods: UInt32(optionKey), upKey: UInt32(kVK_ANSI_Grave)),
        TriggerShortcut(on: false, mods: UInt32(optionKey), key: UInt32(kVK_ANSI_Grave),
                        upMods: UInt32(optionKey), upKey: UInt32(kVK_Tab)),
    ]

    /// Persisted shortcut list (JSON). Absent → Contexts defaults.
    static var shortcuts: [TriggerShortcut] {
        get {
            guard let raw = d.string(forKey: Key.shortcuts), let data = raw.data(using: .utf8),
                  let list = try? JSONDecoder().decode([TriggerShortcut].self, from: data),
                  !list.isEmpty else { return defaultShortcuts }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(String(decoding: data, as: UTF8.self), forKey: Key.shortcuts)
        }
    }

    /// One-time migration: a persisted single-trigger setup (pre-list schema)
    /// enables the matching entry and adopts its recorded move-up. Legacy keys
    /// are removed afterwards, so re-runs are no-ops.
    static func migrateShortcuts() {
        var list = shortcuts
        var changed = false
        let legacyMods = d.object(forKey: Key.hotkeyMods) as? Int
        let legacyKey = d.object(forKey: Key.hotkeyKey) as? Int
        if let mods = legacyMods, let key = legacyKey, mods != 0 {
            if let i = list.firstIndex(where: { $0.mods == UInt32(mods) && $0.key == UInt32(key) }),
               !list[i].on {
                list[i].on = true
                changed = true
            }
            let upMods = d.object(forKey: Key.moveUpMods) as? Int
            let upKey = d.object(forKey: Key.moveUpKey) as? Int
            if let upMods, let upKey, upMods != 0, upKey != 0,
               let i = list.firstIndex(where: { $0.mods == UInt32(mods) && $0.key == UInt32(key) }),
               list[i].upMods == 0 {
                list[i].upMods = UInt32(upMods)
                list[i].upKey = UInt32(upKey)
                changed = true
            }
        }
        if legacyMods != nil || d.object(forKey: Key.moveUpMods) != nil {
            d.removeObject(forKey: Key.hotkeyMods)
            d.removeObject(forKey: Key.hotkeyKey)
            d.removeObject(forKey: Key.moveUpMods)
            d.removeObject(forKey: Key.moveUpKey)
        }
        if changed { shortcuts = list }
    }

    // MARK: Search

    /// Search Shortcuts depth (0 off,1,3,5 remembered-query chars).
    static var searchShortcutsDepth: Int {
        get { d.object(forKey: Key.searchShortcuts) as? Int ?? 0 }
        set { d.set(newValue, forKey: Key.searchShortcuts) }
    }

    static var searchAllowMismatch: Bool {
        get { d.bool(forKey: Key.searchMismatch) }
        set { d.set(newValue, forKey: Key.searchMismatch) }
    }

    /// Remembered query → top window (Search Shortcuts), persisted across opens.
    static var rememberedQuery: String {
        get { d.string(forKey: "at.search.lastQuery") ?? "" }
        set { d.set(newValue, forKey: "at.search.lastQuery") }
    }

    // MARK: Panel policies

    static var spaceScope: SpaceScope {
        get { SpaceScope(rawValue: d.string(forKey: Key.spaceScope) ?? "") ?? .allSpaces }
        set { d.set(newValue.rawValue, forKey: Key.spaceScope) }
    }

    static var appsOfAll: Bool {
        get { d.string(forKey: Key.appsOf) != "active" }
        set { d.set(newValue ? "all" : "active", forKey: Key.appsOf) }
    }

    /// Order apps by most recent activation (default) instead of launch order.
    static var orderByRecency: Bool {
        get { d.object(forKey: Key.orderByRecency) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.orderByRecency) }
    }

    /// Show ignored (excluded) windows at the bottom of the panel. Tab cycling
    /// skips them and focusing one never changes the recency order.
    static var showIgnored: Bool {
        get { d.bool(forKey: Key.showIgnored) }
        set { d.set(newValue, forKey: Key.showIgnored) }
    }

    /// Hold-v in the panel: flips visibility of ignored windows until the app
    /// quits, without touching the saved preference.
    static var sessionShowIgnored: Bool?
    static var showIgnoredNow: Bool { sessionShowIgnored ?? showIgnored }

    /// Hold-i: ignore the window by exact title under its app (toggles off if
    /// that exact rule already exists). Returns true when the rule set changed.
    @discardableResult
    static func toggleIgnore(bundleId: String, title: String) -> Bool {
        guard !bundleId.isEmpty, !title.isEmpty else { return false }
        let entry = "\(bundleId)|=\(title)"
        var list = titleExcludes
        if let i = list.firstIndex(of: entry) { list.remove(at: i) } else { list.append(entry) }
        titleExcludes = list
        return true
    }

    static var minimizedPolicy: WindowPolicy {
        get { WindowPolicy(rawValue: d.string(forKey: Key.minimizedPolicy) ?? "") ?? .doNotShow }
        set { d.set(newValue.rawValue, forKey: Key.minimizedPolicy) }
    }

    static var hiddenPolicy: WindowPolicy {
        get { WindowPolicy(rawValue: d.string(forKey: Key.hiddenPolicy) ?? "") ?? .doNotShow }
        set { d.set(newValue.rawValue, forKey: Key.hiddenPolicy) }
    }

    /// Apps without AX windows ("windowless apps"). Three-state like
    /// minimized/hidden; one-shot migration from the legacy bool and the
    /// older string popup ("Show"/"Show at bottom" preserved).
    static var windowlessPolicy: WindowPolicy {
        get {
            if let raw = d.string(forKey: Key.windowlessPolicy),
               let p = WindowPolicy(rawValue: raw) {
                d.removeObject(forKey: Key.showWindowlessApps) // legacy bool no longer read
                return p
            }
            if let v = d.object(forKey: Key.showWindowlessApps) as? Bool {
                let p: WindowPolicy = v ? .show : .doNotShow
                d.set(p.rawValue, forKey: Key.windowlessPolicy)
                d.removeObject(forKey: Key.showWindowlessApps)
                return p
            }
            return .doNotShow
        }
        set { d.set(newValue.rawValue, forKey: Key.windowlessPolicy) }
    }

    /// Panel-only: letters type into the search while the panel is visible.
    static var typingStartsFastSearch: Bool {
        get { d.object(forKey: Key.typingStartsFastSearch) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.typingStartsFastSearch) }
    }

    // MARK: Rules (workspaces)

    static var grouping: Grouping {
        get { Grouping(rawValue: d.string(forKey: Key.grouping) ?? "") ?? .bySpace }
        set { d.set(newValue.rawValue, forKey: Key.grouping) }
    }

    static var groupCount: Int {
        get { d.object(forKey: Key.groupCount) as? Int ?? 5 }
        set { d.set(newValue, forKey: Key.groupCount) }
    }

    /// Apps never shown in the switcher.
    static var workspaceExcludes: [String] {
        get { d.stringArray(forKey: Key.workspaceExcludes) ?? [] }
        set { d.set(newValue, forKey: Key.workspaceExcludes) }
    }

    /// Per-app title filters: entries are "bundleId|pattern" (pattern syntax:
    /// "abc" contains, "=abc" exact, "^abc"/"abc$" anchors per Contexts docs).
    static var titleExcludes: [String] {
        get { d.stringArray(forKey: Key.workspaceTitleExcludes) ?? [] }
        set { d.set(newValue, forKey: Key.workspaceTitleExcludes) }
    }

    /// True when the window must not appear per the exclude rules.
    /// Bundle-only rules: exact bundle id, or case-insensitive substring of the
    /// app's local name (preserves the legacy loose app-name matching).
    static func isExcluded(bundleId: String, appLocalName: String, title: String) -> Bool {
        for entry in workspaceExcludes {
            if entry == bundleId { return true }
            if appLocalName.localizedCaseInsensitiveContains(entry) { return true }
        }
        for entry in titleExcludes where entry.hasPrefix(bundleId + "|") {
            let pattern = String(entry.dropFirst(bundleId.count + 1))
            if titleMatches(title, pattern) { return true }
        }
        return false
    }

    /// Contexts pattern syntax subset: "abc" contains; "=abc" exact;
    /// "^abc" prefix; "abc$" suffix.
    static func titleMatches(_ title: String, _ pattern: String) -> Bool {
        if pattern.hasPrefix("=") { return title == String(pattern.dropFirst()) }
        if pattern.hasPrefix("^") { return title.hasPrefix(String(pattern.dropFirst())) }
        if pattern.hasSuffix("$") && !pattern.hasPrefix("^") { return title.hasSuffix(String(pattern.dropLast())) }
        return title.localizedCaseInsensitiveContains(pattern)
    }

    // MARK: In-panel action keys (Panel pane: Close/Quit/Minimize/Hide rows)
    // 0 means unset → Option (Contexts-style defaults).

    private static func actionMods(_ key: String) -> UInt32 {
        let v = UInt32(d.integer(forKey: key))
        return v == 0 ? UInt32(optionKey) : v
    }

    static var actionCloseWinMods: UInt32 { actionMods(Key.actionCloseWinMods) }
    static var actionQuitMods: UInt32 { actionMods(Key.actionQuitMods) }
    static var actionMinimizeMods: UInt32 { actionMods(Key.actionMinimizeMods) }
    static var actionHideMods: UInt32 { actionMods(Key.actionHideMods) }

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
