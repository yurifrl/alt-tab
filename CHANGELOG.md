# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Updates show what changed: the in-app update window and the GitHub release
  carry the same release notes — a curated summary plus the commit list since
  the previous release.
- Release notes are curated where the work happens: the project-scoped
  `add-feature` skill records each session's changes into `CHANGELOG.md`, and
  the release workflow stamps them into each versioned release.
- Recording happens without asking: a session-end hook runs the `add-feature`
  skill headless, then commits the new `[Unreleased]` entry and pushes it — if
  the push fails the commit stays local and the failure is logged — so a
  closed session can't leave its work out of the next release notes. The
  commit is marked `chore(changelog):` and the release notes skip it.
- Window rules can be generic: "+" adds a rule not tied to an app or a window,
  where the title conditions alone (none = every window) decide what it
  applies to — so one rule can hide, alias or color matching windows across
  apps.
- Repeating a select letter walks its matches: pressing the same letter again
  in the switcher moves the selection to the next window whose name starts
  with it, down the list and without wrapping; when no match is left below,
  the press goes back to typing as before. A lone match, a different letter,
  other keys and key auto-repeat follow the unchanged path.
- The select-letter behavior is written down and checked: the rules SL-1…SL-12
  in `.planning/specs/001-select-letter-walk/` and `swift run AltTabCore spec`
  verify the implementation against them — per-rule acceptance checks, a
  reference-model differential fuzzer and a mutation scoreboard, non-zero exit
  on any divergence.
- Window rules match on more than the title: each condition picks an attribute
  (Title, Window ID, App name, Bundle ID, PID) and a comparison its type allows
  — Contains, Exact, Starts with, Ends with and Regex for text, Is and Is not
  for the numeric IDs — so a rule can target one Chrome instance by PID or an
  app by bundle id without depending on titles that change with the tab. Rules
  saved before the change keep matching as one title condition.
- "More details" under the rule's Match list shows every open window and the
  values a condition can be built from: Title, Window ID, App and PID, with the
  bundle id on each row's sub-line. Windows the rule already matches are tinted
  green with a ✓, values a condition uses are tinted accent, and clicking a
  value fills the focused condition (numeric attributes land as "Is"). The
  table collapses to a count line, scrolls at a fixed height, and long titles
  slide into view on hover with the full text as a tooltip.

### Changed

- Check for Updates… now lives only in Preferences → General — removed from the
  status menu along with the app-name header and the non-functional ⌘, / ⌘Q
  shortcut labels.
- Switcher rows show each app's icon in the identity slot again, with the select
  letter confined to the left hint gutter instead of replacing the icon.
- Nightly builds only run when code changed: the nightly workflow diffs `main`
  against the last successful nightly and skips changelog-, docs- and
  planning-only commits. Manual dispatch, a first-ever nightly, and force
  pushes still build; stable releases were already gated on `VERSION` bumps.
- The window-rules list is wider (188 → 216 pt), so rule names and their
  summaries truncate less.

## [0.2.2] - 2026-11-26

### Added

- Nightly update channel: rolling pre-release builds from `main`, opt-in via
  Preferences → General (Update channel) or the new `yurifrl-alt-tab@nightly`
  Homebrew cask. Stable remains the default; numbered releases are always
  offered.

## [0.2.1] - 2026-11-26

## [0.2.0] - 2026-11-26

### Added

- Check for Updates… menu item — verifies, downloads and installs new releases
  from GitHub (manual only; never checks in the background). Updates are signed
  and notarized like the app itself.
- Start at Login, on its own General pane in Preferences.

### Changed

- Preferences window is wider and resizable.
