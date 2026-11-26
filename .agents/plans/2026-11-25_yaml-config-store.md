---
title: Move all alt-tab settings into ~/.config/alt-tab/config.yaml
date: 2026-11-25
description: Round-1 grilling draft. Replace UserDefaults with one YAML document, fail closed on a broken file, keep the in-app editing experience byte-for-byte the same.
tags: [config, persistence, yaml, prefs]
status: draft — answers pending
---

# Goal

Every setting alt-tab persists today moves into **`~/.config/alt-tab/config.yaml`**, one file.
A file the app cannot understand **kills the app with a visible error naming the problem and the path**.
The editing experience does not change: same Preferences window, same controls, same live effect, same hotkey recorder.

# What exists today (facts)

| Fact | Where |
|---|---|
| Single persistence facade, read live on every use | `Sources/AltTabCore/Prefs.swift:20` — `enum PrefsStore`, `private static let d = UserDefaults.standard` |
| Storage | UserDefaults domain `at.yuri.alt-tab` (bundle id in `Support/Info.plist`) |
| Settings | 20 scalars/enums + 4 shortcut rows list + rules list (see table below) |
| Nothing in `~/.config/alt-tab` today | `ls` — no directory |
| YAML dependency | none; only SPM dep is Sparkle |
| Rule edits save per keystroke | `WindowRulesView.swift:645` `controlTextDidChange` → `PrefsStore.windowRules = rules` |
| Rules changes are observed | `Prefs.swift:514` posts `at.windowRulesChanged` |
| Demo modes mutate the real prefs | `runPrefsDemo`, `runPrefsUIDemo`, `runExtrasDemo`, `runSpecDemo` in `main.swift` |
| Dead keys still written/read | `at.action.{closeWindow,quit,minimize,hide}Flags` (never set), `at.search.lastQuery` (`rememberedQuery`, no readers), legacy `at.search.enabled`, `at.sidebars.enabled`, `at.fastsearch.flags` |

Persisted values:

| Group | Fields |
|---|---|
| appearance | `theme`: auto / vibrantLight / vibrantDark |
| panel | `maxRows` 1–9, `width` 600–1400, `showOn`: all/primary/active, `activeDisplayOnly`, `showAfterDelay`, `hoverSelects`, `scrollSelects`, `ignoreMouse`, `rowIndicator`: searchHints/numbers/neither, `spaceScope`: allSpaces/visibleAndFullscreen/visibleSpaces, `appsOf`: all/active, `orderByRecency`, `showIgnored`, `minimized`/`hidden`/`windowless`: show/showAtBottom/doNotShow, `typingStartsFastSearch` |
| search | `shortcutDepth` 0/1/3/5, `allowMismatch` |
| grouping | `mode`: bySpace/oneGroup/manually, `count` 1–9 |
| shortcuts | ordered list (first 4 rows fixed, cannot be deleted): `on`, trigger `mods`+`key`, move-up `mods`+`key` |
| rules | ordered list: `bundleId`, `matchers[]` (`attribute`: title/windowId/app/bundle/pid, `kind`: contains/exact/startsWith/endsWith/regex/is/isNot, `text`), `matchAll`, `hide`, `alias`, `color` `#RRGGBB`, `windowId` (pinned, 0 = none), `windowTitle` |
| updates | `channel`: stable / nightly |

# Proposed shape

One document, versioned, grouped like the panes. Full document written on every save.

```yaml
# alt-tab configuration. Written by the app; edit while alt-tab is not running.
version: 1

appearance:
  theme: auto

switcher:
  maxRows: 8
  width: 920
  showOn: active
  activeDisplayOnly: true
  showAfterDelay: true
  hoverSelects: true
  scrollSelects: true
  ignoreMouse: false
  rowIndicator: searchHints
  spaceScope: visibleAndFullscreen
  appsOf: all
  orderByRecency: true
  showIgnored: false
  minimized: doNotShow
  hidden: doNotShow
  windowless: doNotShow
  typingStartsFastSearch: true

search:
  shortcutDepth: 0
  allowMismatch: false

grouping:
  mode: bySpace
  count: 5

shortcuts:
  - on: true
    trigger: { mods: [command], key: tab }
    moveUp:  { mods: [command], key: grave }
  - on: true
    trigger: { mods: [command], key: grave }
    moveUp:  { mods: [command], key: tab }
  - on: false
    trigger: { mods: [option], key: tab }
    moveUp:  { mods: [option], key: grave }
  - on: false
    trigger: { mods: [option], key: grave }
    moveUp:  { mods: [option], key: tab }

rules:
  - bundle: com.tinyspeck.slackmacgap
    hide: true
    matchers:
      - attribute: title
        kind: is
        text: "=yuri-test - Flutter Entertainment - Slack"
    matchAll: false
    alias: ""
    color: ""
    windowId: 0
    windowTitle: ""

updates:
  channel: nightly
```

(Values above illustrate the *shape*; real values come from your current defaults during the import.)

# Code plan

| Phase | Change | Check |
|---|---|---|
| P0 | Add `Yams` (pinned `from: 6.2.2`) to `Package.swift`; new `Sources/AltTabCore/Config/`: `ConfigDocument.swift` (Codable model = exactly the persisted fields), `ConfigCodec.swift` (decode + validate + encode; throws `ConfigError` with line/column and accepted values), `ConfigStore.swift` (in-memory document, debounced atomic save, `FatalConfigAlert`) | `swift build` |
| P1 | `PrefsStore` keeps its public surface, becomes a facade: getters read `ConfigStore.shared.document`, setters mutate + post existing notifications + schedule save. `PrefsUI.swift`, `WindowRulesView.swift`, `SwitcherPanel.swift`, `HotkeyCenter.swift`, `WindowTracker.swift` untouched | `swift build`; every call site compiles unchanged |
| P2 | Boot: `main.swift` loads the config before the status item; `ConfigError` → alert (path, line, message, Reveal in Finder, Quit) → `exit(1)`. CLI modes print and exit 1 | `swift run AltTabCore prefs` against a temp config; broken-file manual test |
| P3 | One-time import from `at.yuri.alt-tab` when the file is absent: read live keys, run today's three legacy migrations (`migrateShortcuts`, `showWindowlessApps` → `windowlessPolicy`, `appExcludes`/`titleExcludes` → hide rules), write file once | import test seeded from a dump of your current defaults |
| P4 | Delete UserDefaults usage and dead keys; keep migrations only in the importer | `grep UserDefaults Sources/` → only the importer |
| P5 | Demo modes get `ALT_TAB_CONFIG` so `prefs`/`prefs-ui`/`extras`/`spec` stop rewriting the real file | run each demo, `config.yaml` mtime unchanged |
| P6 | Verification sweep: `swift run AltTabCore spec`, all demos, round-trip equality, 6 broken-file cases | all green |

Invariants: `PrefsStore` API and call sites unchanged; `at.windowRulesChanged` still posted; hotkey install path unchanged; no file watching; no UI additions.

# Round 1 questions

:::question
After this ships, who owns the settings — the YAML, the old UserDefaults, or both?

Everything today lives in the defaults domain `at.yuri.alt-tab` and is read on every use. Importing the old values once and then trusting only the file means one owner and no drift; the frozen defaults stay behind as an accidental backup you never read while the file exists.

- [ ] YAML only; import defaults once when the file is absent, never read them again — one owner, old values double as a backup
- [ ] YAML only; delete the old defaults keys after the import — nothing stale, but deleting the file later starts from code defaults
- [ ] YAML with a per-key defaults fallback — survives a deleted file, but two owners can drift and disagree

Recommended: YAML only; import defaults once when the file is absent, never read them again
:::

:::question
The file will not exist on the first launch after this change. How does it appear?

Your current setup is in defaults right now (themes, rules, the Slack title exclusion, nightly channel). Starting from code defaults instead would silently reset your app on update day.

- [ ] Import the current defaults once at first launch and write the YAML immediately — you land on the same setup, now in a file
- [ ] Start from code defaults and ignore the old values — clean slate, you re-set everything by hand
- [ ] Import only when you explicitly ask (a menu item or button) — an extra click and a new UI affordance

Recommended: Import the current defaults once at first launch and write the YAML immediately
:::

:::question
What should the app do with a key it does not recognize?

You will hand-edit this file, so a typo is the likeliest breakage. Ignoring unknowns makes a misspelled key silently do nothing; the same rule decides whether an older build accepts a file written by a newer version.

- [ ] Treat it as broken: crash naming the key and line — typos cannot silently no-op; an older build refuses a newer file
- [ ] Ignore the key, keep it on rewrite — versions interoperate, typos silently do nothing
- [ ] Ignore and drop it on rewrite — versions interoperate, but lines disappear from your file

Recommended: Treat it as broken: crash naming the key and line
:::

:::question
Where is the line between "missing" and "broken"?

A hand-edited file goes partial the moment you delete a line. Wrong types, unknown enum values, out-of-range numbers, and duplicate keys are a different failure: no default can honour what was written.

- [ ] Missing key → its default value; wrong type, bad enum, out of range, duplicate key → crash
- [ ] Missing key → crash too; the file must be complete and explicit
- [ ] Missing key → default; bad values clamp to the nearest valid one — never crashes on values

Recommended: Missing key → its default value; wrong type, bad enum, out of range, duplicate key → crash
:::

:::question
What does "crash with an error message" look like on screen?

alt-tab is a login-item menu-bar agent: a silent exit is invisible, and a half-started agent would keep intercepting shortcuts with no settings. The alert has to name the path, the line, and what is wrong.

- [ ] Modal alert with the path, line, and problem; buttons Reveal in Finder and Quit; then exit — you fix the file and relaunch
- [ ] Same alert plus a "Reset to defaults" button that renames the broken file to `config.yaml.broken` and starts fresh — faster recovery, one more way to lose an edit (the renamed file survives)
- [ ] No alert; write the error to stderr and exit — invisible for a login item

Recommended: Modal alert with the path, line, and problem; buttons Reveal in Finder and Quit; then exit
:::

:::question
What does the YAML look like — grouped with plain names, or your existing `at.*` keys?

The app rewrites the whole document on every change, so any comment you add is erased; the shape is what survives. Grouping follows the three Preferences panes, which is how you already think about these settings.

- [ ] Grouped by pane with camelCase names, `version: 1` on top, enums as words (`theme: auto`, `minimized: doNotShow`) — as sketched above
- [ ] Flat, one line per setting, using today's `at.panel.maxRows` style keys verbatim — smallest mental diff, ugly file
- [ ] Grouped but snake_case (`max_rows`, `show_on`) — nicer for YAML, renames every field away from the code

Recommended: Grouped by pane with camelCase names, `version: 1` on top, enums as words
:::

:::question
How are shortcut keys written in the file?

Each row is a keycode plus modifier flags in Carbon terms today (48 = Tab, 50 = grave, 256 = Command). The first four rows are fixed in the UI; rows after them are yours, and any row can be switched off but not deleted.

- [ ] Words: `mods: [command]`, `key: tab`, `moveUp: {mods: [command], key: grave}` — readable and editable; an unknown key name is a broken file
- [ ] Raw numbers: `key: 48, mods: 256` — no mapping code to get wrong, unreadable, silent mistakes
- [ ] One rendered string per combo: `"⌘Tab"` — pretty, but ambiguous to parse back

Recommended: Words: `mods: [command]`, `key: tab`, `moveUp: {mods: [command], key: grave}`
:::

:::question
When does the file hit disk?

The rules editor saves on every keystroke and the sliders fire continuously. Writing straight through means a burst of rewrites while you type or drag; a short debounce means one write and, at worst, the last fraction of a second lost if the app is killed.

- [ ] Debounce ~200 ms after the last change, flush on quit — one write per burst, negligible loss window
- [ ] Write on every setter — simplest, dozens of full-file rewrites per drag or typed word
- [ ] Write only on quit and when the prefs window closes — fewest writes, a crash loses the session's edits

Recommended: Debounce ~200 ms after the last change, flush on quit
:::

# Taking without asking (annotate the line if you disagree)

- **Parser:** Yams via SPM, pinned `from: 6.2.2`. Boring, maintained, parses real YAML including block scalars and anchors.
- **Writes:** whole document every save; atomic (temp file in the same directory + `rename`), mode `0600`, directory created `0755`.
- **No file watching.** In-app UI stays the only editor; a file edit takes effect on the next launch.
- **Not in the file:** login-item state (SMAppService), AppKit frame autosaves (`NSColorPanel`, `SUUpdateAlert`), the agent lock, and `at.search.lastQuery`.
- **Dropped:** the four `at.action.*Flags` keys and legacy `at.search.enabled` / `at.sidebars.enabled` / `at.fastsearch.flags` — all unread or unwritten dead weight.
- **Model:** plain `ConfigDocument` struct; `PrefsStore` stays the name every call site uses, so no UI file changes.

# Round 2, queued

`ALT_TAB_CONFIG` for demos and tests · rule-row validation (empty bundle on title-only rules, pinned `windowId`) · fixed-four shortcut list validation · `version` mismatch policy · file mode and directory creation · a walk of P0–P6 before implementation starts.
