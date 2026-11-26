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
  skill headless, commits the new `[Unreleased]` entry, and pushes it, so a
  closed session can't leave its work out of the next release notes.

### Changed

- Check for Updates… now lives only in Preferences → General — removed from the
  status menu along with the app-name header and the non-functional ⌘, / ⌘Q
  shortcut labels.

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
