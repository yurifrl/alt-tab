import Foundation

/// Reads the pre-YAML `UserDefaults` once, when `config.yaml` does not exist,
/// and returns the document to write. This is the app's only `UserDefaults`
/// reader; after the first launch the file is the database.
enum DefaultsImporter {
    static func importFromUserDefaults(_ d: UserDefaults = .standard) -> Config.Values {
        var values = Config.Values()

        // MARK: Appearance
        values.appearance.theme = enumValue(d.string(forKey: "at.appearance.theme"),
                                            Config.Theme.vibrantDark)

        // MARK: Panel
        values.panel.maxRows = clamp(d.object(forKey: "at.panel.maxRows") as? Int ?? 8, 1...20)
        let width = d.object(forKey: "at.panel.width") as? Double ?? 920
        values.panel.width = width > 0 ? width : 920
        values.panel.display = enumValue(d.string(forKey: "at.panel.showOn"),
                                         Config.PanelDisplay.active)
        // The old preference was a switch around a fixed 0.35 s delay.
        let showDelay = d.object(forKey: "at.panel.showAfterDelay") as? Bool ?? true
        values.panel.showDelay = showDelay ? 0.35 : 0
        values.panel.activeDisplayOnly = d.bool(forKey: "at.panel.activeDisplayOnly")
        values.panel.hoverSelects = d.bool(forKey: "at.panel.hoverSelects")
        values.panel.scrollSelects = d.bool(forKey: "at.panel.scrollSelects")
        values.panel.ignoreMouse = d.bool(forKey: "at.panel.ignoreMouse")
        values.panel.rowIndicator = enumValue(d.string(forKey: "at.panel.rowIndicator"),
                                              Config.RowIndicator.searchHints)
        values.panel.typingStartsFastSearch =
            d.object(forKey: "at.panel.typingStartsFastSearch") as? Bool ?? true

        // MARK: Shortcuts (including the pre-list single-trigger schema)
        values.shortcuts = shortcuts(d)

        // MARK: Search
        values.search.shortcutsDepth = clamp(d.object(forKey: "at.search.shortcutsDepth") as? Int ?? 0, 0...20)
        values.search.allowMismatch = d.bool(forKey: "at.search.allowMismatch")

        // MARK: Workspaces
        values.workspaces.spaceScope = enumValue(d.string(forKey: "at.panel.spaceScope"),
                                                 Config.SpaceScope.allSpaces)
        values.workspaces.appsOfAll = d.string(forKey: "at.panel.appsOf") != "active"
        values.workspaces.orderByRecency = d.object(forKey: "at.panel.orderByRecency") as? Bool ?? true
        values.workspaces.showIgnored = d.bool(forKey: "at.panel.showIgnored")
        values.workspaces.minimized = enumValue(d.string(forKey: "at.panel.minimizedPolicy"),
                                                Config.WindowPolicy.doNotShow)
        values.workspaces.hidden = enumValue(d.string(forKey: "at.panel.hiddenPolicy"),
                                             Config.WindowPolicy.doNotShow)
        values.workspaces.windowless = windowlessPolicy(d)
        values.workspaces.grouping = enumValue(d.string(forKey: "at.workspaces.grouping"),
                                               Config.Grouping.bySpace)
        values.workspaces.groupCount = clamp(d.object(forKey: "at.workspaces.groupCount") as? Int ?? 5, 1...9)

        // MARK: Rules
        values.rules = rules(d)

        // MARK: Updates
        values.updates.channel = enumValue(d.string(forKey: "at.updates.channel"),
                                           Config.UpdateChannel.stable)
        return values
    }

    // MARK: - Shortcuts

    /// Stored list, or the default four. A persisted single-trigger setup
    /// (pre-list schema: one trigger in `at.hotkey.*`) enables the matching
    /// entry and adopts its recorded move-up.
    private static func shortcuts(_ d: UserDefaults) -> [Config.Shortcut] {
        var list = Config.defaultShortcuts
        if let raw = d.string(forKey: "at.shortcuts.list"), let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([StoredShortcut].self, from: data),
           !decoded.isEmpty {
            list = decoded.map { Config.Shortcut(on: $0.on, mods: $0.mods, key: $0.key,
                                                 upMods: $0.upMods, upKey: $0.upKey) }
        }

        guard let mods = d.object(forKey: "at.hotkey.modifierFlags") as? Int, mods != 0,
              let key = d.object(forKey: "at.hotkey.virtualKey") as? Int else { return list }
        guard let i = list.firstIndex(where: { $0.mods == UInt32(mods) && $0.key == UInt32(key) })
        else { return list }
        list[i].on = true
        if let upMods = d.object(forKey: "at.hotkey.moveUpFlags") as? Int,
           let upKey = d.object(forKey: "at.hotkey.moveUpKey") as? Int,
           upMods != 0, upKey != 0, list[i].upMods == 0 {
            list[i].upMods = UInt32(upMods)
            list[i].upKey = UInt32(upKey)
        }
        return list
    }

    /// The pre-YAML JSON shape of one stored shortcut row.
    private struct StoredShortcut: Decodable {
        var on: Bool
        var mods: UInt32
        var key: UInt32
        var upMods: UInt32
        var upKey: UInt32
    }

    // MARK: - Windowless policy

    /// Three-state value, or the older bool / string popup it replaced.
    private static func windowlessPolicy(_ d: UserDefaults) -> Config.WindowPolicy {
        if let raw = d.string(forKey: "at.panel.windowlessPolicy"),
           let policy = Config.WindowPolicy(rawValue: raw) { return policy }
        if let legacy = d.object(forKey: "at.rules.showWindowlessApps") as? Bool {
            return legacy ? .show : .doNotShow
        }
        return .doNotShow
    }

    // MARK: - Rules

    /// Stored rule rows; else the legacy "apps to not show" lists
    /// (bundle ids and "bundle|pattern" entries) become hide rules. Legacy
    /// shapes are read into today's matchers, exactly as the old getter did.
    private static func rules(_ d: UserDefaults) -> [Config.WindowRule] {
        if let raw = d.array(forKey: "at.rules.windowRules") as? [[String: Any]] {
            return raw.map { row in
                Config.WindowRule(
                    bundleId: row["bundleId"] as? String ?? "",
                    matchers: (row["matchers"] as? [[String: Any]])?.map(matcher)
                        ?? legacyMatchers(row["pattern"] as? String ?? ""),
                    matchAll: row["matchAll"] as? Bool ?? false,
                    hide: row["hide"] as? Bool ?? false,
                    alias: row["alias"] as? String ?? "",
                    color: row["color"] as? String ?? "",
                    windowId: (row["windowId"] as? Int).map { UInt32(clamping: $0) } ?? 0,
                    windowTitle: row["windowTitle"] as? String ?? "")
            }
        }

        var migrated: [Config.WindowRule] = []
        for entry in d.stringArray(forKey: "at.workspaces.appExcludes") ?? [] where !entry.isEmpty {
            migrated.append(Config.WindowRule(bundleId: entry, hide: true, alias: ""))
        }
        for entry in d.stringArray(forKey: "at.workspaces.titleExcludes") ?? [] {
            guard let sep = entry.firstIndex(of: "|") else { continue }
            migrated.append(Config.WindowRule(bundleId: String(entry[..<sep]),
                                              matchers: legacyMatchers(String(entry[entry.index(after: sep)...])),
                                              hide: true, alias: ""))
        }
        return migrated
    }

    private static func matcher(_ raw: [String: Any]) -> Config.Matcher {
        Config.Matcher(attribute: Config.Matcher.Attribute(rawValue: raw["attribute"] as? String ?? "") ?? .title,
                       kind: Config.Matcher.Kind(rawValue: raw["kind"] as? String ?? "") ?? .contains,
                       text: raw["text"] as? String ?? "")
    }

    /// Entries stored before matchers carried one `pattern` string: "=x"
    /// exact, "^x" prefix, "x$" suffix, else contains.
    private static func legacyMatchers(_ pattern: String) -> [Config.Matcher] {
        if pattern.hasPrefix("=") { return [Config.Matcher(kind: .exact, text: String(pattern.dropFirst()))] }
        if pattern.hasPrefix("^") { return [Config.Matcher(kind: .startsWith, text: String(pattern.dropFirst()))] }
        if pattern.hasSuffix("$") { return [Config.Matcher(kind: .endsWith, text: String(pattern.dropLast()))] }
        return pattern.isEmpty ? [] : [Config.Matcher(kind: .contains, text: pattern)]
    }

    // MARK: - Helpers

    private static func enumValue<T: RawRepresentable>(_ raw: String?, _ fallback: T) -> T
    where T.RawValue == String {
        raw.flatMap(T.init(rawValue:)) ?? fallback
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
