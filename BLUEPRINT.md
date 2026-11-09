# alt-tab — Reimplementation Blueprint

Reference: Contexts 3.9.0 (license held by Yuri — legitimate behavioral reference).
Clean-room: architecture/techniques/behavior reused; **no** Contexts code, assets, or binary formats copied.

## Feature model (extracted via RE)

| Subsystem | Contexts behavior | Priority |
|---|---|---|
| Command Tab switcher | Overlay panel per display; app+window list; key-driven cycling; activation on release | P0 |
| Window model | Live app/window inventory via Accessibility; geometry + titles + minimized state | P0 |
| Number switcher | Direct window jump by index | P2 |
| Workspaces | Space-aware grouping; rules (exclude apps, no-window apps) | P3 |
| Gestures | Double-touch trackpad switch (private MultitouchSupport) | P3 |
| Search | Fuzzy title search in switcher | P3 |
| Prefs | `CTPreference*`-style UserDefaults keys; per-pane UI | P2 |
| Appearance | Vibrant Dark/Light themes | P2 |

Explicitly **dropped**: Realm persistence (overkill — SQLite/SwiftData/files suffice; Contexts only stored `CLIShortcut` rows), AppCenter telemetry (never ship), Sparkle (reuse directly — open source), RSA license scheme (not applicable).

## Architecture

```
Sources/AltTab/
  Core/            — no AppKit UI imports
    AXWorld.swift      AXUIElement system: app/window enumeration, observers
    WindowModel.swift  Window identity: pid, AX ref, title, frame, minimized, space
    FocusTracker.swift activation-change events → model refresh
  UI/
    SwitcherPanel.swift borderless NSPanel per display, vibrant material
    CellView.swift      icon + title cell rendering
  Control/
    HotkeyCenter.swift  MASShortcut-equivalent (Carbon RegisterEventHotKey)
    KeyTrap.swift       panel-local keydown: cycle/select/cancel
  Prefs/
    Keys.swift          UserDefaults schema (namespaced `at.*`)
```

Communication flows down only (Core ← UI ← Control); model pushes updates via NotificationCenter.

## Techniques validated against the reference binary

1. **AX enumeration**: `AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute`; per-window `kAXTitle/Position/Size` (AXValue unwrap). Contexts binds `AXObserverCreate/AddNotification` for live updates — do the same after slice 2; polling is slice-1 fallback.
2. **Geometry fallback**: `CGWindowListCopyWindowInfo` for frames of AX-uncooperative apps (Electron etc.).
3. **Per-display panels**: borderless `NSPanel`, `level = .statusBar + 1`, `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`, one per `NSScreen`. Vibrant material matches reference's VibrantDark/Light.
4. **Hotkeys**: Contexts wraps MASShortcut (Carbon `RegisterEventHotKey`). Reimplement thin wrapper — ~100 LOC, no pod needed.
5. **Spaces awareness** (P3): NSWorkspace `activeSpaceDidChangeNotification` + CGWindow on-screen ordering. Contexts additionally reads private Spaces prefs — copy that behavior only if needed, flag as review-risk.
6. **MultitouchSupport** (P3): private framework, matches Contexts' exact import set (`MTDeviceCreateList`, callbacks). App-Store-disqualifying; fine for personal builds.

## Phase plan

| Phase | Slice | Acceptance |
|---|---|---|
| 1 | AX enumeration | Real table of live apps/windows w/ geometry printed from CLI |
| 2 | Switcher panel v1 | Hotkey → panel over focused display → arrows cycle → Enter activates correct window |
| 3 | Live tracking | AXObserver wired; panel stays correct across focus/space changes |
| 4 | Per-display + fullscreen panels | Panels on every screen incl. fullscreen spaces |
| 5 | Prefs + themes | UserDefaults schema, vibrant light/dark |
| 6 | Contexts-parity extras | Number switcher, workspaces, gestures (in order) |

## Risks

- **TCC Accessibility**: build must be granted Accessibility (Terminal/IDE or signed app). Slice 1 proves this immediately; untrusted → system prompt.
- **Secure input / password fields**: Contexts shows SecureInputWarning; replicate eventually.
- **Hardened runtime needed** before distributing (notarization) — irrelevant until Phase 6.

## Build status (all phases verified live, 2026-10-30)

| Component | File(s) | Verified by |
|---|---|---|
| AX enumeration | `main.swift` | `enum` — live windows with frames/titles |
| Window activation | `main.swift` `activate()` | `activate` — frontmost + focused-title assertions, Chrome-profile disambiguation |
| Global hotkey | `HotkeyCenter.swift` | `hotkey` — 2/2 synthetic fires; active session CGEventTap (Carbon ignores synthetic keys); tap auto-disable → `rearm()` |
| Hold-to-switch trigger | `HotkeyCenter.swift` + `SwitcherPanel.swift` | synthetic + real-key (`holdKeys`) against live agent: hold opens panel (preselects previous window), Tab/Shift+Tab cycle while held, release commits (AX-confirmed activation); quick double-tap instant-commits without panel; Esc cancels and post-close release never commits. Hold arms from the trigger keyDown itself (binding match proves the mods are down — immune to ⌥-down/Tab-down report order); `flagsChangedHandler` + event-flag-authoritative `sideMask` detects release. **Contexts must be quit: it hooks ⌥Tab too and reacts to every ⌥ flap** |
| Switcher panel | `SwitcherPanel.swift` | `panel` — open/cycle/commit/cancel sequence assertions |
| Live tracking | `WindowTracker.swift` | `track` — NSWorkspace + AXObserver notifications rebuild model, selection pinned |
| Per-display panels | `SwitcherPanel.swift` | `panel` — geometry: 2 screens → 2 panels, rows partitioned, centered in `visibleFrame` |
| Prefs + themes | `Prefs.swift` | `prefs` + cross-launch `defaults read AltTabCore` (`at.*` keys) |
| Parity extras | `SwitcherPanel.swift` (digits/search/excludes), `GestureSwitch.swift` | `extras` — search narrows 4→3, excludes filter Chrome, 2 MT devices installed |
| Trigger shortcut list | `Prefs.swift` (`at.shortcuts`), `SwitcherPanel.swift` (`installShortcuts`/`routeKey`/`routeHoldRelease`), `PrefsUI.swift` | Synthetic A–E suite against live agent: hold opens+preselects, Tab/Shift+Tab cycle, release commits, double-tap instant-commits, Esc cancels, trigger-press arming race-safe; per-entry move-up recorded in prefs UI; legacy `at.hotkey.*` keys migrated on launch |

**Event-tap starvation (regression finding, fixed 2026-10-30).** The session tap's run-loop source is added to the main run loop, so any synchronous AX work inside a callback starves it — WindowServer silently drops/disables deliveries mid-hold (observed: lost release and shift+Tab events, commits lagging ~2 s while Chrome was busy). Fixes: `open()`/`openInstantCommit()` no longer sweep AX synchronously in the callback (tracker is observer-maintained), `WindowTracker.refresh` enumerates+filters on a serial background queue with a generation-guarded main-thread apply, and `activate` is split into a fast main-thread raise (`beginActivation`) plus a backgrounded verify poll (`verifyActivation`). `AT_DEBUG=1` enables timestamped tap-level tracing (`TapLog` in `HotkeyCenter.swift`) for diagnosing this class of failure.

Run modes: `enum`, `activate`, `hotkey`, `panel`, `track`, `prefs`, `extras`.
