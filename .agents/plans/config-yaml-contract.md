# alt-tab YAML config — implementation contract (locked)

Locked by the owner's answers (round 1, Plannotator Inbox, 2026-11-26). Do not re-open decisions.

## Goal

`~/.config/alt-tab/config.yaml` becomes **the** settings database. `UserDefaults` is read **once**, only when the
file does not exist, to create it. After that it is never consulted. A file that cannot be read or validated
stops the app with an error naming the path, line and problem.

**No experience change:** the Preferences window, every control, every label, every live-update behavior stays
byte-for-byte identical. `PrefsUI.swift`, `SwitcherPanel.swift`, `WindowRulesView.swift`, `MatchersEditor.swift`,
`WindowMatchTableView.swift`, `WindowTracker.swift`, `HotkeyCenter.swift`, `ColorTag.swift`, `RenameEditor.swift`
are **not edited**. The `PrefsStore` public surface (names, types, semantics) is preserved so they compile unchanged.

## Locked decisions

1. YAML owns settings. Defaults are imported exactly once at first launch (file absent) and the file is written immediately.
2. Unknown key, wrong type, bad enum value, out-of-range value, duplicate key, empty file, `version` ≠ 1 → **broken**: crash with an error naming path, line and problem.
3. Missing key → its default value (silently).
4. Missing file → import defaults, write file. Empty file → broken (refuse to silently reset a database).
5. Broken file in the app: modal alert with file path, line, problem; buttons **Reveal in Finder** and **Quit**; the process then exits 1. In CLI/demo modes: the same text on stderr, exit 1 (no UI).
6. Layout mirrors the Preferences panes, camelCase keys, `version: 1` first.
7. Shortcut keys are words: `{mods: [command], key: tab}`; unknown-but-recordable keycodes fall back to the integer keycode.
8. Save is debounced ~200 ms after the last mutation, plus a synchronous flush on quit.

## YAML schema (authoritative)

```yaml
version: 1
appearance:
  theme: auto                        # auto | vibrantLight | vibrantDark
panel:
  maxRows: 7                         # 1...20
  width: 900                         # px, > 0
  display: all                       # all | primary | active
  showDelay: 0.0                     # seconds, 0 = immediate, 0...10
  activeDisplayOnly: false
  hoverSelects: true
  scrollSelects: false
  ignoreMouse: false
  rowIndicator: searchHints          # searchHints | numbers | neither
  typingStartsFastSearch: true
shortcuts:                           # ordered list; row 0 is the primary trigger
  - on: true
    trigger: {mods: [command], key: tab}
    moveUp: {mods: [command], key: grave}
search:
  shortcutsDepth: 3                  # 0...20
  allowMismatch: false
workspaces:
  spaceScope: visibleAndFullscreen   # allSpaces | visibleAndFullscreen | visibleSpaces
  appsOf: all                        # all | active
  orderByRecency: true
  showIgnored: false
  minimized: doNotShow               # show | showAtBottom | doNotShow
  hidden: doNotShow
  windowless: doNotShow
  grouping: bySpace                  # bySpace | oneGroup | manually
  groupCount: 3                      # 1...9
rules:                               # window rules, in list order
  - bundleId: com.tinyspeck.slackmacgap
    hide: false
    alias: ""
    color: ""
    matchAll: true
    matchers:
      - {attribute: title, kind: is, text: "=yuri-test"}
    windowId: 0                      # 0 = any window
    windowTitle: ""
updates:
  channel: nightly                   # stable | nightly
```

Rule fields map 1:1 to `PrefsStore.WindowRule`; matcher fields to `PrefsStore.Matcher`
(`attribute`: title | windowId | app | bundle | pid; `kind`: contains | exact | startsWith | endsWith | regex | is | isNot).
The field list above is the full set of live keys. **Dropped** (dead or legacy): `at.action.*Flags`, `at.search.lastQuery`
(`rememberedQuery`), `at.search.enabled`, `at.sidebars.enabled`, `at.fastsearch.flags`, `at.hotkey.*` — the last group
survives only inside the one-time importer migration.

## Swift API contract

```swift
// Config/ConfigModel.swift — pure data, no AppKit, no UserDefaults
enum Config {
    static let currentVersion = 1

    enum Theme: String, CaseIterable { case auto, vibrantLight, vibrantDark }
    enum PanelDisplay: String, CaseIterable { case all, primary, active }
    enum SpaceScope: String, CaseIterable { case allSpaces, visibleAndFullscreen, visibleSpaces }
    enum WindowPolicy: String, CaseIterable { case show, showAtBottom, doNotShow }
    enum RowIndicator: String, CaseIterable { case searchHints, numbers, neither }
    enum Grouping: String, CaseIterable { case bySpace, oneGroup, manually }
    enum UpdateChannel: String, CaseIterable { case stable, nightly }

    struct Matcher: Equatable { var attribute: Attribute; var kind: Kind; var text: String
        enum Attribute: String, CaseIterable { case title, windowId, app, bundle, pid }
        enum Kind: String, CaseIterable { case contains, exact, startsWith, endsWith, regex, isExactly = "is", isNot = "isNot" }
    }
    struct WindowRule: Equatable { var bundleId: String; var matchers: [Matcher]; var matchAll: Bool
        var hide: Bool; var alias: String; var color: String; var windowId: UInt32; var windowTitle: String }
    struct Shortcut: Equatable { var on: Bool; var mods: UInt32; var key: UInt32; var upMods: UInt32; var upKey: UInt32 }

    struct Values: Equatable {
        var version: Int
        var appearance: Appearance   // theme
        var panel: Panel             // maxRows width display showDelay activeDisplayOnly hoverSelects scrollSelects
                                     // ignoreMouse rowIndicator typingStartsFastSearch
        var shortcuts: [Shortcut]
        var search: Search           // shortcutsDepth allowMismatch
        var workspaces: Workspaces   // spaceScope appsOfAll orderByRecency showIgnored minimized hidden windowless grouping groupCount
        var rules: [WindowRule]
        var updates: Updates         // channel
    }
}
```

Preserve today's `Matcher`/`WindowRule`/`TriggerShortcut` initializers and default values verbatim (views call
`PrefsStore.WindowRule(bundleId:hide:alias:color:)`, `PrefsStore.Matcher()`, `PrefsStore.Matcher(kind:text:)`,
`PrefsStore.Matcher(attribute:kind:text:)`). `Prefs.swift` then declares `typealias`es inside `PrefsStore`
(`Theme`, `PanelDisplay`, `SpaceScope`, `WindowPolicy`, `RowIndicator`, `Grouping`, `UpdateChannel`, `Matcher`,
`WindowRule`, `TriggerShortcut`) pointing at the `Config` types, so no other file changes.

```swift
// Config/ConfigCodec.swift
enum ConfigCodec {
    static func decode(_ yaml: String, file: String) throws -> Config.Values   // throws ConfigError with line numbers
    static func encode(_ values: Config.Values) -> String                      // deterministic order, header comment, flow-style combos
}

// Config/ConfigStore.swift
struct ConfigError: Error, CustomStringConvertible {
    let file: String        // absolute path
    let line: Int?          // 1-based, nil when the file as a whole is at fault
    let path: String?       // e.g. "panel.maxRows"
    let problem: String     // one sentence, names accepted values
    var description: String // "open /…/config.yaml: line 12, panel.maxRows: expected …, found …"
}

enum ConfigStore {
    static var file: URL { get }                     // ALT_TAB_CONFIG if set, else ~/.config/alt-tab/config.yaml
    static func load() throws                        // absent → import + write; present → decode/validate (throws)
    static var values: Config.Values { get set }     // setter schedules the debounced save
    static func mutate(_ body: (inout Config.Values) -> Void)
    static func flush()                              // synchronous save if dirty; safe to call twice
}
```

Parsing must go through `Yams.compose(yaml:) -> Node?` and a manual, path-tracking walk — **not** `YAMLDecoder` —
so every error carries the offending node's `Mark` (line/column) and duplicate keys are visible. `nil` document
(empty/comment-only file) is a `ConfigError`. Encoding builds `Node.mapping` trees (ordered) and emits; combos use
`style: .flow`. Writes are atomic: temp file in the same directory, mode `0600`, directory `0700`, then rename.
Runtime save failures must not crash or show an alert: log to stderr, keep the document dirty, retry on next save/flush.

Key/mods words: `command`, `option`, `control`, `shift`, `fn`, `capsLock` (Carbon flag bits). Key names:
`a`...`z`, `0`...`9`, `grave minus equal leftBracket rightBracket backslash semicolon quote comma period slash tab
space return escape delete forwardDelete home end pageUp pageDown left right up down f1`...`f20`. Emit mods in
`[control, option, shift, command, fn, capsLock]` order; unknown mods bit or unknown keycode → integer fallback
for the key, and unknown flags are dropped from `mods` only if zero remain (else the file is broken? no — write the
integer bitmask is not allowed; drop unknown bits, they are not produced by the recorder).

## Slice ownership

| Slice | Files |
|---|---|
| A | `Package.swift`, `Sources/AltTabCore/Config/{ConfigModel,ConfigCodec,ConfigStore,DefaultsImporter}.swift`, `Sources/AltTabCore/Prefs.swift` (keeps a temporary no-op `migrateShortcuts()` so the not-yet-edited `main.swift` still compiles) |
| C | **all** of `Sources/AltTabCore/main.swift` (remove `PrefsStore.migrateShortcuts()`, boot load before the status item, fatal alert, per-mode temp config isolation, flush on quit, and the UI-free `config` mode: print resolved path, `try ConfigStore.load()`, one-line summary per section; on `ConfigError` print `error.description` to stderr and `exit(1)`), `Sources/AltTabCore/Config/ConfigFatalAlert.swift` |

`main.swift` has exactly one owner (C) so no two slices ever edit the same file.

A must leave the module compiling: `swift build` green with every non-owned file unchanged.

## Verification (run once, at the end of the slice)

```bash
cd /Users/yuri/Workdir/Yuri/alt-tab/.worktrees/config-yaml
swift build
ALT_TAB_CONFIG=/tmp/at-$$-fresh.yaml swift run AltTabCore prefs   # demos must never touch the real config
```
Never touch `~/.config/alt-tab/config.yaml` or the real defaults while testing: always point `ALT_TAB_CONFIG` at a
temp path. `defaults read at.yuri.alt-tab` is read-only and fine.
