import Foundation
import Carbon.HIToolbox

/// The settings document, laid out like the Preferences panes.
/// Pure data: no AppKit, no UserDefaults.
enum Config {
    static let currentVersion = 1

    // MARK: Enumerations (YAML spells these with their raw value)

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
    /// Sparkle update channel. `stable` (default) sees numbered releases only;
    /// `nightly` also sees rolling builds tracked by the nightly workflow.
    enum UpdateChannel: String, CaseIterable { case stable, nightly }

    // MARK: Rules

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

    // MARK: Switcher shortcuts

    /// One switcher trigger shortcut. `mods`/`key` open+cycle (hold-to-switch);
    /// `upMods`/`upKey` optionally move the selection back (0 = unset).
    struct Shortcut: Equatable {
        var on: Bool
        var mods: UInt32
        var key: UInt32
        var upMods: UInt32
        var upKey: UInt32
    }

    /// Default set: ⌘Tab (move up ⌘`), ⌘` (move up ⌘Tab), ⌥Tab
    /// (move up ⌥`), ⌥` (move up ⌥Tab) — the Command pair enabled.
    static let defaultShortcuts: [Shortcut] = [
        Shortcut(on: true, mods: UInt32(cmdKey), key: UInt32(kVK_Tab),
                 upMods: UInt32(cmdKey), upKey: UInt32(kVK_ANSI_Grave)),
        Shortcut(on: true, mods: UInt32(cmdKey), key: UInt32(kVK_ANSI_Grave),
                 upMods: UInt32(cmdKey), upKey: UInt32(kVK_Tab)),
        Shortcut(on: false, mods: UInt32(optionKey), key: UInt32(kVK_Tab),
                 upMods: UInt32(optionKey), upKey: UInt32(kVK_ANSI_Grave)),
        Shortcut(on: false, mods: UInt32(optionKey), key: UInt32(kVK_ANSI_Grave),
                 upMods: UInt32(optionKey), upKey: UInt32(kVK_Tab)),
    ]

    // MARK: Sections

    struct Appearance: Equatable {
        var theme: Theme = .vibrantDark
    }

    struct Panel: Equatable {
        var maxRows: Int = 8
        /// Panel width in points, Narrow→Wide slider (default ≈ 560).
        var width: Double = 920
        var display: PanelDisplay = .active
        /// "Show Panel after a slight delay" (avoids flicker on quick
        /// switch to last window). Seconds, 0 = immediate.
        var showDelay: Double = 0.35
        /// List only windows on the display holding the mouse (minimized ones stay).
        var activeDisplayOnly: Bool = false
        var hoverSelects: Bool = false
        var scrollSelects: Bool = false
        /// Master switch: the panel ignores hover, click and scroll entirely.
        var ignoreMouse: Bool = false
        var rowIndicator: RowIndicator = .searchHints
        /// Panel-only: letters type into the search while the panel is visible.
        var typingStartsFastSearch: Bool = true
    }

    struct Search: Equatable {
        /// Search Shortcuts depth (0 off,1,3,5 remembered-query chars).
        var shortcutsDepth: Int = 0
        var allowMismatch: Bool = false
    }

    struct Workspaces: Equatable {
        var spaceScope: SpaceScope = .allSpaces
        /// nil window = any window; false = list only the active app.
        var appsOfAll: Bool = true
        /// Order apps by most recent activation (default) instead of launch order.
        var orderByRecency: Bool = true
        /// Show ignored (excluded) windows at the bottom of the panel. Tab cycling
        /// skips them and focusing one never changes the recency order.
        var showIgnored: Bool = false
        var minimized: WindowPolicy = .doNotShow
        var hidden: WindowPolicy = .doNotShow
        var windowless: WindowPolicy = .doNotShow
        var grouping: Grouping = .bySpace
        var groupCount: Int = 5
    }

    struct Updates: Equatable {
        var channel: UpdateChannel = .stable
    }

    struct Values: Equatable {
        var version: Int = Config.currentVersion
        var appearance: Appearance = Appearance()
        var panel: Panel = Panel()
        var shortcuts: [Shortcut] = Config.defaultShortcuts
        var search: Search = Search()
        var workspaces: Workspaces = Workspaces()
        var rules: [WindowRule] = []
        var updates: Updates = Updates()
    }
}
