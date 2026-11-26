import AppKit
import Carbon.HIToolbox

/// Preferences, namespaced `at.*`.
/// (Command-Tab, Panel, Rules panes).
/// Everything persisted; consumers read live on each use.
enum PrefsStore {
    enum Theme: String, CaseIterable { case auto, vibrantLight, vibrantDark }

    /// Where switcher panels appear.
    enum PanelDisplay: String, CaseIterable { case all, primary, active }
    /// Window space filter ("Show windows from").
    enum SpaceScope: String, CaseIterable { case allSpaces, visibleAndFullscreen, visibleSpaces }
    /// Per-class window visibility policy (Show / Show at bottom / Do not show).
    enum WindowPolicy: String, CaseIterable { case show, showAtBottom, doNotShow }
    /// What the panel shows next to each row ("Show:").
    enum RowIndicator: String, CaseIterable { case searchHints, numbers, neither }
    /// Space grouping ("Group windows").
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
        static let windowRules = "at.rules.windowRules"   // [[String: Any]] bundleId/matchers/matchAll/hide/alias
        static let showWindowlessApps = "at.rules.showWindowlessApps"    // Bool
        static let panelDisplay = "at.panel.showOn"
        static let activeDisplayOnly = "at.panel.activeDisplayOnly"
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
        static let updateChannel = "at.updates.channel"
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

    /// Sparkle update channel. `stable` (default) sees numbered releases only;
    /// `nightly` also sees rolling builds tracked by the nightly workflow.
    /// Read by Updater on every manual check, so a change applies immediately.
    enum UpdateChannel: String, CaseIterable { case stable, nightly }

    static var updateChannel: UpdateChannel {
        get { UpdateChannel(rawValue: d.string(forKey: Key.updateChannel) ?? "") ?? .stable }
        set { d.set(newValue.rawValue, forKey: Key.updateChannel) }
    }

    static var maxRows: Int {
        get { d.object(forKey: Key.maxRows) as? Int ?? 8 }
        set { d.set(newValue, forKey: Key.maxRows) }
    }

    /// Panel width in points, Narrow→Wide slider (default ≈ 560).
    static var panelWidth: Double {
        get { d.object(forKey: Key.panelWidth) as? Double ?? 920 }
        set { d.set(newValue, forKey: Key.panelWidth) }
    }

    static var panelDisplay: PanelDisplay {
        get { PanelDisplay(rawValue: d.string(forKey: Key.panelDisplay) ?? "") ?? .active }
        set { d.set(newValue.rawValue, forKey: Key.panelDisplay) }
    }

    /// "Show Panel after a slight delay" (avoids flicker on quick
    /// switch to last window).
    static var panelShowDelay: Bool {
        get { d.object(forKey: Key.panelDelay) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.panelDelay) }
    }

    /// List only windows on the display holding the mouse (minimized ones stay).
    static var activeDisplayOnly: Bool {
        get { d.bool(forKey: Key.activeDisplayOnly) }
        set { d.set(newValue, forKey: Key.activeDisplayOnly) }
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

    /// Default set: ⌘Tab (move up ⌘`), ⌘` (move up ⌘Tab), ⌥Tab
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

    /// Persisted shortcut list (JSON). Absent → defaults.
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

    /// One condition of a rule: what it looks at (`attribute`), how it compares
    /// (`kind`), and the typed value. Title/Contains stays the default: entries
    /// persisted before attributes existed read back as title conditions.
    struct Matcher: Equatable {
        /// What a condition looks at. The open-windows table drops clicked
        /// values into a row under this attribute.
        enum Attribute: String, CaseIterable {
            case title, windowId, app, bundle, pid

            var title: String {
                switch self {
                case .title: return "Title"
                case .windowId: return "Window ID"
                case .app: return "App name"
                case .bundle: return "Bundle ID"
                case .pid: return "PID"
                }
            }
            /// Short form for the rules-list summary ("id “74821”").
            var short: String {
                switch self {
                case .title: return "title"
                case .windowId: return "id"
                case .app: return "app"
                case .bundle: return "bundle"
                case .pid: return "pid"
                }
            }
            /// Numbers compare with "is"/"is not"; text with the string kinds.
            var numeric: Bool { self == .windowId || self == .pid }

            /// The field's placeholder while this attribute is selected.
            var placeholder: String {
                switch self {
                case .title: return "Window title"
                case .windowId: return "e.g. 74821"
                case .app: return "e.g. Slack"
                case .bundle: return "e.g. com.mitchellh.ghostty"
                case .pid: return "e.g. 1183"
                }
            }

            /// The window's value for this attribute ("" = nothing to compare).
            func value(of w: WindowModel) -> String {
                switch self {
                case .title: return w.title
                case .windowId: return w.windowId == 0 ? "" : String(w.windowId)
                case .app: return w.appLocalName
                case .bundle: return w.bundleId
                case .pid: return String(w.pid)
                }
            }
        }

        enum Kind: String, CaseIterable {
            case contains, exact, startsWith, endsWith, regex
            case isExactly = "is"
            case isNot = "isNot"

            var title: String {
                switch self {
                case .contains: return "Contains"
                case .exact: return "Exact"
                case .startsWith: return "Starts with"
                case .endsWith: return "Ends with"
                case .regex: return "Regex"
                case .isExactly: return "Is"
                case .isNot: return "Is not"
                }
            }
            var numeric: Bool { self == .isExactly || self == .isNot }

            /// The kinds an attribute's row offers.
            static func list(for attribute: Attribute) -> [Kind] {
                attribute.numeric ? [.isExactly, .isNot]
                                  : [.contains, .exact, .startsWith, .endsWith, .regex]
            }
        }

        var attribute: Attribute = .title
        var kind: Kind = .contains
        var text: String = ""

        /// Empty text matches nothing: a half-typed condition must never
        /// sweep in every window.
        func matches(_ w: WindowModel) -> Bool {
            guard !text.isEmpty else { return false }
            switch attribute {
            case .title, .app, .bundle:
                return Self.compare(kind, text, attribute.value(of: w))
            case .windowId, .pid:
                // A string kind left on a numeric attribute matches nothing;
                // the editor rewrites it the moment it sees it.
                guard kind.numeric, let n = Int64(text),
                      let v = Int64(attribute.value(of: w)) else { return false }
                return kind == .isNot ? v != n : v == n
            }
        }

        private static func compare(_ kind: Kind, _ text: String, _ value: String) -> Bool {
            switch kind {
            case .contains: return value.localizedCaseInsensitiveContains(text)
            case .exact: return value == text
            case .startsWith: return value.hasPrefix(text)
            case .endsWith: return value.hasSuffix(text)
            case .regex:
                guard let re = regex(text) else { return false }
                return re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            case .isExactly, .isNot: return false
            }
        }

        /// The editor's live check behind the field's red flag.
        static func isValidRegex(_ pattern: String) -> Bool { regex(pattern) != nil }

        // Compile-once caches, valid and invalid apart: typing, and every
        // tracker refresh, must not recompile the same string.
        private static var regexOK: [String: NSRegularExpression] = [:]
        private static var regexBad: Set<String> = []
        /// Hit from the main thread (editor typing, the rules pane) and from
        /// the tracker's sweep queue (rule matching), so every access is
        /// serialized.
        private static let regexLock = NSLock()
        private static func regex(_ pattern: String) -> NSRegularExpression? {
            regexLock.lock()
            defer { regexLock.unlock() }
            if let ok = regexOK[pattern] { return ok }
            if regexBad.contains(pattern) { return nil }
            guard let re = try? NSRegularExpression(pattern: pattern) else {
                if regexBad.count > 64 { regexBad.removeAll() }
                regexBad.insert(pattern)
                return nil
            }
            if regexOK.count > 64 { regexOK.removeAll() }
            regexOK[pattern] = re
            return re
        }
    }

    /// One Rules-pane row: matches an app (bundle id) and optionally its
    /// window titles (no condition = every window of the app), then applies
    /// any of: hide the window, show it under an alias. An empty bundle id is
    /// the generic row: every app, narrowed only by its title conditions.
    struct WindowRule: Equatable {
        var bundleId: String
        /// Title conditions: all must match, or (with `matchAll` off) any one.
        var matchers: [Matcher] = []
        /// false = "any" (OR), true = "all" (AND).
        var matchAll: Bool = false
        var hide: Bool
        var alias: String
        /// "#RRGGBB" color tag, "" = none.
        var color: String = ""
        /// CGWindowID this rule is pinned to (0 = not pinned; `matchers` are used).
        /// Survives title/tab changes; lost when the window closes — re-link it
        /// from Preferences ("Pick from open windows").
        var windowId: UInt32 = 0
        /// Title the pinned window had when linked (display only).
        var windowTitle: String = ""
    }

    /// Persisted rule list. First read migrates the legacy "apps to not show"
    /// lists (bundle/name entries + "bundle|pattern" entries) into hide rules.
    static var windowRules: [WindowRule] {
        get {
            if let raw = d.array(forKey: Key.windowRules) as? [[String: Any]] {
                return raw.map {
                    WindowRule(bundleId: $0["bundleId"] as? String ?? "",
                               matchers: ($0["matchers"] as? [[String: Any]])?.map(matcher)
                                   ?? legacyMatchers($0["pattern"] as? String ?? ""),
                               matchAll: $0["matchAll"] as? Bool ?? false,
                               hide: $0["hide"] as? Bool ?? false,
                               alias: $0["alias"] as? String ?? "",
                               color: $0["color"] as? String ?? "",
                               windowId: ($0["windowId"] as? Int).map { UInt32(clamping: $0) } ?? 0,
                               windowTitle: $0["windowTitle"] as? String ?? "")
                }
            }
            var migrated: [WindowRule] = []
            for e in d.stringArray(forKey: Key.workspaceExcludes) ?? [] where !e.isEmpty {
                migrated.append(WindowRule(bundleId: e, hide: true, alias: ""))
            }
            for e in d.stringArray(forKey: Key.workspaceTitleExcludes) ?? [] {
                guard let sep = e.firstIndex(of: "|") else { continue }
                migrated.append(WindowRule(bundleId: String(e[..<sep]),
                                           matchers: legacyMatchers(String(e[e.index(after: sep)...])),
                                           hide: true, alias: ""))
            }
            d.set(migrated.map(dict), forKey: Key.windowRules)
            // One source of truth from here on: drop the legacy lists.
            d.removeObject(forKey: Key.workspaceExcludes)
            d.removeObject(forKey: Key.workspaceTitleExcludes)
            return migrated
        }
        set {
            d.set(newValue.map(dict), forKey: Key.windowRules)
            NotificationCenter.default.post(name: windowRulesChanged, object: nil)
        }
    }

    /// Posted after every write to `windowRules` (Preferences list reloads).
    static let windowRulesChanged = Notification.Name("at.windowRulesChanged")

    private static func dict(_ r: WindowRule) -> [String: Any] {
        ["bundleId": r.bundleId,
         "matchers": r.matchers.map { ["attribute": $0.attribute.rawValue,
                                        "kind": $0.kind.rawValue, "text": $0.text] },
         "matchAll": r.matchAll,
         "hide": r.hide, "alias": r.alias, "color": r.color,
         "windowId": Int(r.windowId), "windowTitle": r.windowTitle]
    }

    private static func matcher(_ raw: [String: Any]) -> Matcher {
        Matcher(attribute: Matcher.Attribute(rawValue: raw["attribute"] as? String ?? "") ?? .title,
                kind: Matcher.Kind(rawValue: raw["kind"] as? String ?? "") ?? .contains,
                text: raw["text"] as? String ?? "")
    }

    /// Entries stored before matchers carried one `pattern` string: "=x"
    /// exact, "^x" prefix, "x$" suffix, else contains. Read as one condition;
    /// the next write persists the new shape.
    private static func legacyMatchers(_ pattern: String) -> [Matcher] {
        if pattern.hasPrefix("=") { return [Matcher(kind: .exact, text: String(pattern.dropFirst()))] }
        if pattern.hasPrefix("^") { return [Matcher(kind: .startsWith, text: String(pattern.dropFirst()))] }
        if pattern.hasSuffix("$") { return [Matcher(kind: .endsWith, text: String(pattern.dropLast()))] }
        return pattern.isEmpty ? [] : [Matcher(kind: .contains, text: pattern)]
    }

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
    // 0 means unset → Option (defaults).

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
