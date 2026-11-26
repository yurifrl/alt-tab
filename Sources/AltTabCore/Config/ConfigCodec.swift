import Foundation
import Carbon.HIToolbox
import CoreGraphics
import Yams

/// YAML ⇄ `Config.Values`. The walk is manual so every failure names the
/// offending node's line and key path.
enum ConfigCodec {
    private static let header = """
    # alt-tab settings. Everything the app persists lives in this file.
    # Edit it while the app is not running. A file that cannot be read or
    # validated stops the app, naming this path, the line and the problem.

    """

    // MARK: - Decode

    static func decode(_ yaml: String, file: String) throws -> Config.Values {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch {
            throw parseError(error, file: file)
        }
        guard let root else {
            throw ConfigError(file: file, line: nil, path: nil,
                              problem: "the file is empty; a settings document is required")
        }
        var out = Config.Values()
        for (key, node) in try entries(root, at: "", file: file) {
            let path = key
            switch key {
            case "version":
                let n = try integer(node, path, file)
                guard n == Config.currentVersion else {
                    throw ConfigError(file: file, line: line(node), path: path,
                                      problem: "unsupported version \(n); this build reads version \(Config.currentVersion)")
                }
                out.version = n
            case "appearance":
                out.appearance = try appearance(node, path, file, base: out.appearance)
            case "panel":
                out.panel = try panel(node, path, file, base: out.panel)
            case "shortcuts":
                out.shortcuts = try shortcuts(node, path, file)
            case "search":
                out.search = try search(node, path, file, base: out.search)
            case "workspaces":
                out.workspaces = try workspaces(node, path, file, base: out.workspaces)
            case "rules":
                out.rules = try rules(node, path, file)
            case "updates":
                out.updates = try updates(node, path, file, base: out.updates)
            default:
                throw unknownKey(key, node, path, file,
                                 accepted: ["version", "appearance", "panel", "shortcuts",
                                            "search", "workspaces", "rules", "updates"])
            }
        }
        return out
    }

    // MARK: Sections

    private static func appearance(_ node: Node, _ path: String, _ file: String,
                                   base: Config.Appearance) throws -> Config.Appearance {
        var out = base
        for (key, child) in try entries(node, at: path, file: file) {
            let p = "\(path).\(key)"
            switch key {
            case "theme":
                out.theme = try choice(child, p, file, Config.Theme.self, "theme")
            default:
                throw unknownKey(key, child, p, file, accepted: ["theme"])
            }
        }
        return out
    }

    private static func panel(_ node: Node, _ path: String, _ file: String,
                              base: Config.Panel) throws -> Config.Panel {
        var out = base
        for (key, child) in try entries(node, at: path, file: file) {
            let p = "\(path).\(key)"
            switch key {
            case "maxRows":
                out.maxRows = try rangedInt(child, p, file, 1...20)
            case "width":
                let w = try number(child, p, file)
                guard w > 0 else {
                    throw ConfigError(file: file, line: line(child), path: p,
                                      problem: "expected a width above 0, found \(format(w))")
                }
                out.width = w
            case "display":
                out.display = try choice(child, p, file, Config.PanelDisplay.self, "display")
            case "showDelay":
                out.showDelay = try rangedNumber(child, p, file, 0...10)
            case "activeDisplayOnly":
                out.activeDisplayOnly = try boolean(child, p, file)
            case "hoverSelects":
                out.hoverSelects = try boolean(child, p, file)
            case "scrollSelects":
                out.scrollSelects = try boolean(child, p, file)
            case "ignoreMouse":
                out.ignoreMouse = try boolean(child, p, file)
            case "rowIndicator":
                out.rowIndicator = try choice(child, p, file, Config.RowIndicator.self, "row indicator")
            case "typingStartsFastSearch":
                out.typingStartsFastSearch = try boolean(child, p, file)
            default:
                throw unknownKey(key, child, p, file,
                                 accepted: ["maxRows", "width", "display", "showDelay",
                                            "activeDisplayOnly", "hoverSelects", "scrollSelects",
                                            "ignoreMouse", "rowIndicator", "typingStartsFastSearch"])
            }
        }
        return out
    }

    private static func shortcuts(_ node: Node, _ path: String, _ file: String) throws -> [Config.Shortcut] {
        guard case .sequence(let seq) = node else {
            throw typeError(node, path, file, "a list of 4 shortcuts")
        }
        guard seq.count == 4 else {
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected exactly 4 shortcuts, found \(seq.count)")
        }
        var out: [Config.Shortcut] = []
        for (i, item) in seq.enumerated() {
            let p = "\(path)[\(i)]"
            var sc = Config.Shortcut(on: false, mods: 0, key: 0, upMods: 0, upKey: 0)
            for (key, child) in try entries(item, at: p, file: file) {
                let cp = "\(p).\(key)"
                switch key {
                case "on":
                    sc.on = try boolean(child, cp, file)
                case "trigger":
                    (sc.mods, sc.key) = try combo(child, cp, file)
                case "moveUp":
                    (sc.upMods, sc.upKey) = try combo(child, cp, file)
                default:
                    throw unknownKey(key, child, cp, file, accepted: ["on", "trigger", "moveUp"])
                }
            }
            out.append(sc)
        }
        return out
    }

    private static func search(_ node: Node, _ path: String, _ file: String,
                               base: Config.Search) throws -> Config.Search {
        var out = base
        for (key, child) in try entries(node, at: path, file: file) {
            let p = "\(path).\(key)"
            switch key {
            case "shortcutsDepth":
                out.shortcutsDepth = try rangedInt(child, p, file, 0...20)
            case "allowMismatch":
                out.allowMismatch = try boolean(child, p, file)
            default:
                throw unknownKey(key, child, p, file, accepted: ["shortcutsDepth", "allowMismatch"])
            }
        }
        return out
    }

    private static func workspaces(_ node: Node, _ path: String, _ file: String,
                                   base: Config.Workspaces) throws -> Config.Workspaces {
        var out = base
        for (key, child) in try entries(node, at: path, file: file) {
            let p = "\(path).\(key)"
            switch key {
            case "spaceScope":
                out.spaceScope = try choice(child, p, file, Config.SpaceScope.self, "space scope")
            case "appsOf":
                let v = try string(child, p, file)
                switch v {
                case "all": out.appsOfAll = true
                case "active": out.appsOfAll = false
                default:
                    throw ConfigError(file: file, line: line(child), path: p,
                                      problem: "expected all or active, found “\(v)”")
                }
            case "orderByRecency":
                out.orderByRecency = try boolean(child, p, file)
            case "showIgnored":
                out.showIgnored = try boolean(child, p, file)
            case "minimized":
                out.minimized = try choice(child, p, file, Config.WindowPolicy.self, "window policy")
            case "hidden":
                out.hidden = try choice(child, p, file, Config.WindowPolicy.self, "window policy")
            case "windowless":
                out.windowless = try choice(child, p, file, Config.WindowPolicy.self, "window policy")
            case "grouping":
                out.grouping = try choice(child, p, file, Config.Grouping.self, "grouping")
            case "groupCount":
                out.groupCount = try rangedInt(child, p, file, 1...9)
            default:
                throw unknownKey(key, child, p, file,
                                 accepted: ["spaceScope", "appsOf", "orderByRecency", "showIgnored",
                                            "minimized", "hidden", "windowless", "grouping", "groupCount"])
            }
        }
        return out
    }

    private static func rules(_ node: Node, _ path: String, _ file: String) throws -> [Config.WindowRule] {
        guard case .sequence(let seq) = node else {
            throw typeError(node, path, file, "a list of rules")
        }
        var out: [Config.WindowRule] = []
        for (i, item) in seq.enumerated() {
            let p = "\(path)[\(i)]"
            var rule = Config.WindowRule(bundleId: "", hide: false, alias: "")
            for (key, child) in try entries(item, at: p, file: file) {
                let cp = "\(p).\(key)"
                switch key {
                case "bundleId": rule.bundleId = try string(child, cp, file)
                case "hide": rule.hide = try boolean(child, cp, file)
                case "alias": rule.alias = try string(child, cp, file)
                case "color": rule.color = try string(child, cp, file)
                case "matchAll": rule.matchAll = try boolean(child, cp, file)
                case "windowId": rule.windowId = try uint32(child, cp, file)
                case "windowTitle": rule.windowTitle = try string(child, cp, file)
                case "matchers":
                    rule.matchers = try matchers(child, cp, file)
                default:
                    throw unknownKey(key, child, cp, file,
                                     accepted: ["bundleId", "hide", "alias", "color", "matchAll",
                                                "matchers", "windowId", "windowTitle"])
                }
            }
            out.append(rule)
        }
        return out
    }

    private static func matchers(_ node: Node, _ path: String, _ file: String) throws -> [Config.Matcher] {
        guard case .sequence(let seq) = node else {
            throw typeError(node, path, file, "a list of conditions")
        }
        var out: [Config.Matcher] = []
        for (i, item) in seq.enumerated() {
            let p = "\(path)[\(i)]"
            var m = Config.Matcher()
            for (key, child) in try entries(item, at: p, file: file) {
                let cp = "\(p).\(key)"
                switch key {
                case "attribute":
                    m.attribute = try choice(child, cp, file, Config.Matcher.Attribute.self, "attribute")
                case "kind":
                    m.kind = try choice(child, cp, file, Config.Matcher.Kind.self, "condition")
                case "text": m.text = try string(child, cp, file)
                default:
                    throw unknownKey(key, child, cp, file, accepted: ["attribute", "kind", "text"])
                }
            }
            out.append(m)
        }
        return out
    }

    private static func updates(_ node: Node, _ path: String, _ file: String,
                                base: Config.Updates) throws -> Config.Updates {
        var out = base
        for (key, child) in try entries(node, at: path, file: file) {
            let p = "\(path).\(key)"
            switch key {
            case "channel":
                out.channel = try choice(child, p, file, Config.UpdateChannel.self, "channel")
            default:
                throw unknownKey(key, child, p, file, accepted: ["channel"])
            }
        }
        return out
    }

    /// `{mods: [command], key: tab}` → (mods bitmask, keycode).
    private static func combo(_ node: Node, _ path: String, _ file: String) throws -> (UInt32, UInt32) {
        var mods: UInt32 = 0
        var key: UInt32 = 0
        for (name, child) in try entries(node, at: path, file: file) {
            let p = "\(path).\(name)"
            switch name {
            case "mods": mods = try modsValue(child, p, file)
            case "key": key = try keyValue(child, p, file)
            default:
                throw unknownKey(name, child, p, file, accepted: ["mods", "key"])
            }
        }
        return (mods, key)
    }

    private static func modsValue(_ node: Node, _ path: String, _ file: String) throws -> UInt32 {
        if case .scalar(let s) = node, let bits = UInt32(s.string) { return bits }
        guard case .sequence(let seq) = node else {
            throw typeError(node, path, file, "a list of modifier words or an integer bitmask")
        }
        var bits: UInt32 = 0
        for child in seq {
            let word = try string(child, path, file)
            guard let bit = ModWord(rawValue: word)?.bit else {
                throw ConfigError(file: file, line: line(child), path: path,
                                  problem: "expected one of \(ModWord.all), found “\(word)”")
            }
            bits |= bit
        }
        return bits
    }

    private static func keyValue(_ node: Node, _ path: String, _ file: String) throws -> UInt32 {
        let s = try string(node, path, file)
        if let code = KeyName.code(for: s) { return code }
        if let code = UInt32(s) { return code }
        throw ConfigError(file: file, line: line(node), path: path,
                          problem: "expected a key name (\(KeyName.spellings)) or an integer keycode, found “\(s)”")
    }

    // MARK: - Node access

    private static func entries(_ node: Node, at path: String, file: String) throws -> [(String, Node)] {
        guard case .mapping(let map) = node else {
            throw typeError(node, path.isEmpty ? "document" : path, file, "a mapping")
        }
        var out: [(String, Node)] = []
        var seen = Set<String>()
        for (keyNode, value) in map {
            guard case .scalar(let scalar) = keyNode else {
                throw ConfigError(file: file, line: line(keyNode), path: path.isEmpty ? nil : path,
                                  problem: "map keys must be text, found \(described(keyNode))")
            }
            let key = scalar.string
            guard seen.insert(key).inserted else {
                throw ConfigError(file: file, line: line(keyNode),
                                  path: path.isEmpty ? key : "\(path).\(key)",
                                  problem: "duplicate key “\(key)”")
            }
            out.append((key, value))
        }
        return out
    }

    private static func string(_ node: Node, _ path: String, _ file: String) throws -> String {
        guard case .scalar(let s) = node else {
            throw typeError(node, path, file, "text")
        }
        return s.string
    }

    private static func boolean(_ node: Node, _ path: String, _ file: String) throws -> Bool {
        let s = try string(node, path, file)
        switch s {
        case "true": return true
        case "false": return false
        default:
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected true or false, found “\(s)”")
        }
    }

    private static func integer(_ node: Node, _ path: String, _ file: String) throws -> Int {
        let s = try string(node, path, file)
        guard let n = Int(s) else {
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected an integer, found “\(s)”")
        }
        return n
    }

    private static func rangedInt(_ node: Node, _ path: String, _ file: String,
                                  _ range: ClosedRange<Int>) throws -> Int {
        let n = try integer(node, path, file)
        guard range.contains(n) else {
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected \(range.lowerBound)...\(range.upperBound), found \(n)")
        }
        return n
    }

    private static func number(_ node: Node, _ path: String, _ file: String) throws -> Double {
        let s = try string(node, path, file)
        guard let n = Double(s), n.isFinite else {
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected a number, found “\(s)”")
        }
        return n
    }

    private static func rangedNumber(_ node: Node, _ path: String, _ file: String,
                                     _ range: ClosedRange<Double>) throws -> Double {
        let n = try number(node, path, file)
        guard range.contains(n) else {
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected \(format(range.lowerBound))...\(format(range.upperBound)) seconds, found \(format(n))")
        }
        return n
    }

    private static func uint32(_ node: Node, _ path: String, _ file: String) throws -> UInt32 {
        let s = try string(node, path, file)
        guard let n = UInt32(s) else {
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected an integer from 0 to \(UInt32.max), found “\(s)”")
        }
        return n
    }

    private static func choice<T: RawRepresentable & CaseIterable>(
        _ node: Node, _ path: String, _ file: String, _ type: T.Type, _ name: String
    ) throws -> T where T.RawValue == String {
        let s = try string(node, path, file)
        guard let value = T(rawValue: s) else {
            let accepted = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw ConfigError(file: file, line: line(node), path: path,
                              problem: "expected \(name) \(accepted), found “\(s)”")
        }
        return value
    }

    private static func typeError(_ node: Node, _ path: String, _ file: String, _ expected: String) -> ConfigError {
        ConfigError(file: file, line: line(node), path: path,
                    problem: "expected \(expected), found \(described(node))")
    }

    private static func unknownKey(_ key: String, _ node: Node, _ path: String, _ file: String,
                                   accepted: [String]) -> ConfigError {
        ConfigError(file: file, line: line(node), path: path,
                    problem: "unknown key “\(key)”; accepted keys: \(accepted.joined(separator: ", "))")
    }

    private static func line(_ node: Node) -> Int? {
        switch node {
        case .scalar(let s): return s.mark?.line
        case .mapping(let m): return m.mark?.line
        case .sequence(let s): return s.mark?.line
        case .alias: return nil
        }
    }

    private static func described(_ node: Node) -> String {
        switch node {
        case .scalar(let s): return "“\(s.string)”"
        case .mapping: return "a mapping"
        case .sequence: return "a list"
        case .alias: return "an alias"
        }
    }

    private static func parseError(_ error: Error, file: String) -> ConfigError {
        switch error {
        case let YamlError.scanner(context, problem, mark, _):
            return ConfigError(file: file, line: mark.line, path: nil,
                               problem: [context?.text, problem].compactMap { $0 }.joined(separator: ": "))
        case let YamlError.parser(context, problem, mark, _):
            return ConfigError(file: file, line: mark.line, path: nil,
                               problem: [context?.text, problem].compactMap { $0 }.joined(separator: ": "))
        case let YamlError.composer(context, problem, mark, _):
            return ConfigError(file: file, line: mark.line, path: nil,
                               problem: [context?.text, problem].compactMap { $0 }.joined(separator: ": "))
        case let YamlError.duplicatedKeysInMapping(duplicates, context):
            return ConfigError(file: file, line: context.mark.line, path: nil,
                               problem: "duplicate key \(duplicates.joined(separator: ", "))")
        default:
            return ConfigError(file: file, line: nil, path: nil, problem: String(describing: error))
        }
    }

    // MARK: - Encode

    static func encode(_ values: Config.Values) -> String {
        let root = Node.map([
            ("version", scalar(values.version)),
            ("appearance", Node.map([
                ("theme", scalar(values.appearance.theme.rawValue)),
            ])),
            ("panel", Node.map([
                ("maxRows", scalar(values.panel.maxRows)),
                ("width", scalar(format(values.panel.width))),
                ("display", scalar(values.panel.display.rawValue)),
                ("showDelay", scalar(format(values.panel.showDelay))),
                ("activeDisplayOnly", scalar(values.panel.activeDisplayOnly)),
                ("hoverSelects", scalar(values.panel.hoverSelects)),
                ("scrollSelects", scalar(values.panel.scrollSelects)),
                ("ignoreMouse", scalar(values.panel.ignoreMouse)),
                ("rowIndicator", scalar(values.panel.rowIndicator.rawValue)),
                ("typingStartsFastSearch", scalar(values.panel.typingStartsFastSearch)),
            ])),
            ("shortcuts", Node.seq(values.shortcuts.map(shortcut))),
            ("search", Node.map([
                ("shortcutsDepth", scalar(values.search.shortcutsDepth)),
                ("allowMismatch", scalar(values.search.allowMismatch)),
            ])),
            ("workspaces", Node.map([
                ("spaceScope", scalar(values.workspaces.spaceScope.rawValue)),
                ("appsOf", scalar(values.workspaces.appsOfAll ? "all" : "active")),
                ("orderByRecency", scalar(values.workspaces.orderByRecency)),
                ("showIgnored", scalar(values.workspaces.showIgnored)),
                ("minimized", scalar(values.workspaces.minimized.rawValue)),
                ("hidden", scalar(values.workspaces.hidden.rawValue)),
                ("windowless", scalar(values.workspaces.windowless.rawValue)),
                ("grouping", scalar(values.workspaces.grouping.rawValue)),
                ("groupCount", scalar(values.workspaces.groupCount)),
            ])),
            ("rules", Node.seq(values.rules.map(rule))),
            ("updates", Node.map([
                ("channel", scalar(values.updates.channel.rawValue)),
            ])),
        ])
        // The tree holds only strings, integers, doubles and booleans built
        // above; libyaml cannot refuse it.
        let body = try! Yams.serialize(node: root)
        return header + body
    }

    private static func shortcut(_ sc: Config.Shortcut) -> Node {
        var pairs: [(Node, Node)] = [
            (scalar("on"), scalar(sc.on)),
            (scalar("trigger"), combo(sc.mods, sc.key)),
        ]
        if sc.upMods != 0 || sc.upKey != 0 {
            pairs.append((scalar("moveUp"), combo(sc.upMods, sc.upKey)))
        }
        return Node.map(pairs, style: .block)
    }

    private static func rule(_ r: Config.WindowRule) -> Node {
        Node.map([
            (scalar("bundleId"), scalar(r.bundleId)),
            (scalar("hide"), scalar(r.hide)),
            (scalar("alias"), scalar(r.alias)),
            (scalar("color"), scalar(r.color)),
            (scalar("matchAll"), scalar(r.matchAll)),
            (scalar("matchers"), Node.seq(r.matchers.map { m in
                Node.map([
                    (scalar("attribute"), scalar(m.attribute.rawValue)),
                    (scalar("kind"), scalar(m.kind.rawValue)),
                    (scalar("text"), scalar(m.text)),
                ], style: .flow)
            })),
            (scalar("windowId"), scalar(Int(r.windowId))),
            (scalar("windowTitle"), scalar(r.windowTitle)),
        ], style: .block)
    }

    /// `{mods: [command], key: tab}` with mods always a flow list.
    private static func combo(_ mods: UInt32, _ key: UInt32) -> Node {
        var words: [Node] = []
        for word in ModWord.emitOrder where mods & word.bit != 0 {
            words.append(scalar(word.rawValue))
        }
        let keyNode: Node = KeyName.name(for: key).map(scalar) ?? scalar(Int(key))
        return Node.map([
            (scalar("mods"), Node.seq(words, style: .flow)),
            (scalar("key"), keyNode),
        ], style: .flow)
    }

    /// Text goes out plain when the emitter can spell it that way. An empty
    /// string has no plain form (bare `key:` reads back as null), so it is
    /// always written as `""`.
    private static func scalar(_ text: String) -> Node {
        text.isEmpty
            ? Node.scalar(Node.Scalar(text, .implicit, .doubleQuoted))
            : Node.scalar(Node.Scalar(text))
    }
    private static func scalar(_ n: Int) -> Node { Node.scalar(Node.Scalar(String(n))) }
    private static func scalar(_ b: Bool) -> Node { Node.scalar(Node.Scalar(b ? "true" : "false")) }

    /// Whole numbers without a trailing `.0`; everything else shortest round-trip.
    private static func format(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }
}

/// Shorthand for the two composite nodes this file builds; `Node.mapping` and
/// `Node.sequence` name enum cases, so the values must be wrapped explicitly.
private extension Node {
    static func map(_ pairs: [(Node, Node)], style: Node.Mapping.Style = .any) -> Node {
        .mapping(Node.Mapping(pairs, .implicit, style))
    }

    static func seq(_ nodes: [Node], style: Node.Sequence.Style = .any) -> Node {
        .sequence(Node.Sequence(nodes, .implicit, style))
    }
}

// MARK: - Modifier words

private enum ModWord: String, CaseIterable {
    case control, option, shift, command, fn, capsLock

    var bit: UInt32 {
        switch self {
        case .control: return UInt32(controlKey)
        case .option: return UInt32(optionKey)
        case .shift: return UInt32(shiftKey)
        case .command: return UInt32(cmdKey)
        case .fn: return UInt32(CGEventFlags.maskSecondaryFn.rawValue)
        case .capsLock: return UInt32(alphaLock)
        }
    }

    /// Contract order: control, option, shift, command, fn, capsLock.
    static let emitOrder: [ModWord] = [.control, .option, .shift, .command, .fn, .capsLock]
    static var all: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

// MARK: - Key names

private enum KeyName {
    private static let names: [(String, Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
        ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
        ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
        ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
        ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
        ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ("grave", kVK_ANSI_Grave), ("minus", kVK_ANSI_Minus), ("equal", kVK_ANSI_Equal),
        ("leftBracket", kVK_ANSI_LeftBracket), ("rightBracket", kVK_ANSI_RightBracket),
        ("backslash", kVK_ANSI_Backslash), ("semicolon", kVK_ANSI_Semicolon),
        ("quote", kVK_ANSI_Quote), ("comma", kVK_ANSI_Comma), ("period", kVK_ANSI_Period),
        ("slash", kVK_ANSI_Slash),
        ("tab", kVK_Tab), ("space", kVK_Space), ("return", kVK_Return),
        ("escape", kVK_Escape), ("delete", kVK_Delete), ("forwardDelete", kVK_ForwardDelete),
        ("home", kVK_Home), ("end", kVK_End),
        ("pageUp", kVK_PageUp), ("pageDown", kVK_PageDown),
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
        ("up", kVK_UpArrow), ("down", kVK_DownArrow),
        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
        ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
        ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15), ("f16", kVK_F16),
        ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),
    ]

    private static let byName: [String: UInt32] = Dictionary(uniqueKeysWithValues: names.map { ($0.0, UInt32($0.1)) })
    private static let byCode: [UInt32: String] = Dictionary(uniqueKeysWithValues: names.map { (UInt32($0.1), $0.0) })

    static func code(for name: String) -> UInt32? { byName[name] }
    static func name(for code: UInt32) -> String? { byCode[code] }
    static var spellings: String { names.map(\.0).joined(separator: ", ") }
}
