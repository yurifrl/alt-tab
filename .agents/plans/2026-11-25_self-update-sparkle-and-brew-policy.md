---
title: Self-update via GitHub Releases (Sparkle) + Homebrew cask policy
date: 2026-11-25
description: Manual "Check for Updates…" menu item backed by Sparkle 2, EdDSA-signed appcast hosted as a GitHub Release asset, and fixes to the tap-bump path so brew always tracks the newest release.
tags: [release, ci, sparkle, homebrew, macos]
---

# Self-update via GitHub Releases (Sparkle) + Homebrew cask policy

## Context

Current state (verified, not assumed):

- Release pipeline: `VERSION` on main → `tag.yml` → annotated tag → `release.yml` builds universal, Developer ID signs, notarizes + staples app and DMG, publishes `AltTab.dmg` to the GitHub Release, then bumps the pinned cask in `yurifrl/homebrew-casks`.
- The cask bump is **silently dead**: `HOMEBREW_TAP_TOKEN` is not in the repo secrets; release run 43037246905 logged `##[warning]HOMEBREW_TAP_TOKEN not set; pinned cask not bumped` and the step exited 0. Tap commit `7cb488e` ("yurifrl-alt-tab 0.1.0 sha256") was authored manually by Yuri.
- The app has no networking code, no updater, no "Check for Updates" item. Status menu is built in `runAgent()` (`Sources/AltTabCore/main.swift:682`), actions in `AgentActions` (`main.swift:791`).
- Repo is public; app is an LSUIElement menu-bar agent; min macOS 12; bundle id `at.yuri.alt-tab`.

Decisions this plan implements:

- **Sparkle 2.10.1** via SwiftPM binary target (verified compatible: `platforms: [.macOS(.v12)]`, universal `macos-arm64_x86_64` slice, `bin/` tools inside the SPM zip).
- Feed = `appcast.xml` attached to every GitHub Release; `SUFeedURL = https://github.com/yurifrl/alt-tab/releases/latest/download/appcast.xml` (same trick as the `@latest` cask; GitHub's `latest` skips prereleases).
- **Manual checks only**: `SUEnableAutomaticChecks=false`, `SUAutomaticallyUpdate=false`. The only trigger is the menu item — no timer, no background checks, no "install on quit".
- Pinned cask gets `auto_updates true`; the tap bump becomes a hard requirement of the release.

## Constraints discovered (must not be broken)

- One executable target, `AltTabCore`; its demo modes (`swift run AltTabCore extras|prefs-ui|enum|…`) are the de-facto test harness and must keep running **unpackaged**.
- SwiftPM's output directory is toolchain-dependent (`.build/out/Products/{Debug,Release}` on Xcode 26.2; `.build/<triple>/{debug,release}` on older toolchains) — derive it from `swift build --show-bin-path`, never hardcode.
- Sparkle's nested code (`Autoupdate`, `XPCServices/Downloader.xpc`, `XPCServices/Installer.xpc`, `Updater.app`) ships **ad-hoc signed with its own entitlements**; it must be re-signed with the Developer ID using `--preserve-metadata=entitlements`, before the framework and the app (inside-out).
- rpath `@executable_path/../Frameworks` serves both the `.app` bundle and the staged dev build (verified: framework resolves via the `.build/release` symlink and via `swift run`).

## Steps

### 1. One-time: EdDSA key + CI secrets (manual, no code)

1. Extract Sparkle 2.10.1 tarball, then from its `bin/`:
   - `./generate_keys` → writes the `ed25519` private key to the login Keychain, prints the public key.
   - `./generate_keys -x ~/Downloads/alt-tab-sparkle-private-key.txt` → exports the private key (done).
2. Store both keys in 1Password. The public key is permanent: every installed build trusts only the key baked into it, and losing the private key means existing installs can never be updated again (one-time manual reinstall to recover).
3. `gh secret set SPARKLE_ED_PRIVATE_KEY < ~/Downloads/alt-tab-sparkle-private-key.txt`, then `rm` the file. (The generated key is already at that path: 44 bytes, no trailing newline; `generate_appcast` also tolerates a trailing newline — verified locally against the real toolchain.)
4. Fine-grained PAT (`contents: write` on `yurifrl/homebrew-casks`) → `gh secret set HOMEBREW_TAP_TOKEN`.
5. Put the public key into `Support/Info.plist` (step 2).

Verify: `gh secret list` shows both secrets.

### 2. App declares feed + keys — `Support/Info.plist`

```xml
<key>SUFeedURL</key>
<string>https://github.com/yurifrl/alt-tab/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key>
<false/>
<key>SUAutomaticallyUpdate</key>
<false/>
```

`SUEnableAutomaticChecks=false` also suppresses Sparkle's first-run "check automatically?" prompt — no automatic updates, no questions. `LSMinimumSystemVersion` stays 12.0 (matches Sparkle's floor). `make-app.sh`/CI keep patching `CFBundleShortVersionString`/`CFBundleVersion` (`GITHUB_RUN_NUMBER` → monotonic `sparkle:version`, correct ordering).

Verify: `plutil -lint Support/Info.plist`; `PlistBuddy -c Print` shows the four keys.

### 3. Dependency — `Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "alt-tab",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "AltTabCore",
            path: "Sources/AltTabCore",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-weak_framework", "MultitouchSupport", "-F", "/System/Library/PrivateFrameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
```

Verify: `swift build` succeeds; `otool -l .build/release/AltTabCore | grep -A2 LC_RPATH` shows `@executable_path/../Frameworks`; `otool -L` shows `@rpath/Sparkle.framework/Versions/B/Sparkle`.

### 4. Updater + menu item — `Sources/AltTabCore/Updater.swift` (new) + `main.swift`

```swift
import AppKit
import Sparkle

/// Manual-only updater: checks happen solely from the status-menu item.
/// Info.plist pins SUEnableAutomaticChecks/SUAutomaticallyUpdate to false, so
/// Sparkle never schedules a check of its own.
final class Updater: NSObject {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Sparkle needs a real .app bundle (bundle id, Info.plist feed URL, code
    /// signature). Unpackaged demo runs (`swift run AltTabCore extras`) get no
    /// updater, and the menu item is omitted.
    @discardableResult
    func start() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        return true
    }

    @objc func checkForUpdates() { controller?.checkForUpdates(nil) }
}
```

In `runAgent()` (`main.swift`), start it before the menu is built and add the item after "Open Switcher Now":

```swift
let updatesAvailable = Updater.shared.start()
...
if updatesAvailable {
    let updatesItem = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(Updater.checkForUpdates), keyEquivalent: "")
    updatesItem.target = Updater.shared
    menu.addItem(updatesItem)
}
```

Verify: menu shows the item for the bundled app and omits it under `swift run`; `swift run AltTabCore extras` → PASS (unchanged behavior).

### 5. Stage the framework for unpackaged runs — `scripts/stage-sparkle.sh` (new) + `Taskfile.yml`

```bash
#!/bin/bash
# Stage Sparkle.framework next to the built executables so unpackaged runs
# (`swift run AltTabCore extras`) resolve @rpath/Sparkle.framework.
set -euo pipefail
cd "$(dirname "$0")/.."

XC="$(find .build/artifacts -maxdepth 4 -name 'Sparkle.xcframework' -print -quit)"
[[ -n "$XC" ]] || { echo "Sparkle.xcframework not resolved — run: swift package resolve" >&2; exit 1; }

for config in debug release; do
  DEST="$(dirname "$(swift build -c "$config" --show-bin-path)")/Frameworks"
  mkdir -p "$DEST"
  rm -rf "$DEST/Sparkle.framework"
  cp -R "$XC/macos-arm64_x86_64/Sparkle.framework" "$DEST/"
  echo "staged $DEST/Sparkle.framework"
done
```

`Taskfile.yml`: `build` runs the script before `swift build`. README dev note: `task build` stages the framework; a bare `swift build` yields a binary that fails at launch with a clear dyld error until staged.

Verify: without staging → `swift run AltTabCore enum` fails with `Library not loaded: @rpath/Sparkle.framework…`; after `task build` → works.

### 6. App bundle carries the framework — `make-app.sh` + `.github/workflows/release.yml`

Same block in both, immediately before the existing app `codesign` (keep the two files in lockstep):

```bash
XC="$(find .build/artifacts -maxdepth 4 -name 'Sparkle.xcframework' -print -quit)"
[[ -n "$XC" ]] || { echo "Sparkle.xcframework missing — swift package resolve first" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$XC/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/"

FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
  --keychain "$KEYCHAIN_PATH" --sign "$IDENTITY" \
  "$FW/Versions/B/Autoupdate" \
  "$FW/Versions/B/XPCServices/Downloader.xpc" \
  "$FW/Versions/B/XPCServices/Installer.xpc" \
  "$FW/Versions/B/Updater.app" \
  "$FW"
codesign --verify --strict --verbose=2 "$FW"
```

`make-app.sh` uses the same list minus `--timestamp`/`--keychain`. The app's own signing + `codesign --verify --strict` stays last, and CI adds `codesign --verify --deep --strict` on the finished bundle. Same signing identity for app and framework (Library Validation requires it; hardened runtime is already on).

Verify (local): `./make-app.sh -l`; `codesign --verify --deep --strict ~/Applications/AltTab.app`; `otool -L ~/Applications/AltTab.app/Contents/MacOS/AltTab | grep Sparkle`; app launches, menu item present, up-to-date check opens Sparkle's window without errors.

### 7. Release workflow generates + publishes the signed appcast — `.github/workflows/release.yml`

In "Publish GitHub Release" (after the DMG is final — the signature covers the exact bytes, and the enclosure `length` is the final size):

```bash
: "${SPARKLE_ED_PRIVATE_KEY:?secret SPARKLE_ED_PRIVATE_KEY is required}"

SPARKLE_DIR="$RUNNER_TEMP/sparkle"
mkdir -p "$SPARKLE_DIR" "$RUNNER_TEMP/feed"
curl -sSL -o "$SPARKLE_DIR/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz"
tar -xJf "$SPARKLE_DIR/sparkle.tar.xz" -C "$SPARKLE_DIR"
cp AltTab.dmg "$RUNNER_TEMP/feed/"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$RUNNER_TEMP/sparkle-ed-key.txt"
"$SPARKLE_DIR/bin/generate_appcast" \
  --ed-key-file "$RUNNER_TEMP/sparkle-ed-key.txt" \
  --link "https://github.com/yurifrl/alt-tab" \
  --download-url-prefix "https://github.com/yurifrl/alt-tab/releases/download/$TAG/" \
  "$RUNNER_TEMP/feed"
rm -f "$RUNNER_TEMP/sparkle-ed-key.txt"

grep -q 'sparkle:edSignature' "$RUNNER_TEMP/feed/appcast.xml" \
  || { echo "appcast unsigned — is SUPublicEDKey in the built app's Info.plist?" >&2; exit 1; }
```

then publish both files atomically: `gh release create "$TAG" AltTab.dmg "$RUNNER_TEMP/feed/appcast.xml" --title … --generate-notes` / `gh release upload "$TAG" AltTab.dmg "$RUNNER_TEMP/feed/appcast.xml" --clobber`, with `env: SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}`.

Behavior verified against the published 0.1.0 DMG:

- Version comes from the app inside the DMG (no version in the filename needed): produced `sparkle:version 3`, `sparkle:shortVersionString 0.1.0`, `sparkle:minimumSystemVersion 12.0`.
- Enclosure URL = `--download-url-prefix` + local filename → `…/download/v0.2.0/AltTab.dmg`, matching the asset name.
- `sparkle:edSignature` appears only when the app inside the archive declares `SUPublicEDKey` — hence step 2 must land before the first Sparkle-bearing release, and the `grep` gate above turns the failure red instead of shipping an unverifiable feed.

### 8. Tap bump becomes mandatory; cask policy — `.github/workflows/release.yml` + tap repo

- Replace the warn-and-`exit 0` in "Bump pinned Homebrew cask" with `: "${TAP_TOKEN:?secret HOMEBREW_TAP_TOKEN is required}"` so a missing/failed tap bump fails the job instead of silently leaving brew users stale.
- PR in `yurifrl/homebrew-casks`: add `auto_updates true` to `Casks/yurifrl-alt-tab.rb` (pinned cask). Leave `yurifrl-alt-tab@latest.rb` without it — its whole point is re-fetching `releases/latest/download` on demand.

Verify: after the next release, `brew info --cask yurifrl-alt-tab` shows the new version; the tap commit is authored by `github-actions[bot]`.

### 9. Version bump + end-to-end proof

- First Sparkle-bearing release must be a **new version** (0.2.0): the 0.1.0 build has no updater, so it needs one manual/brew step. Note it in the 0.2.0 release notes.
- Bump `VERSION` to 0.2.0 on main → tag → release + appcast + cask bump.
- Install 0.2.0 (`brew install --cask yurifrl-alt-tab`), confirm menu item + "You're up to date".
- Bump to 0.2.1, confirm from the 0.2.0 install: check → the update window shows the curated `CHANGELOG.md` section plus the commit appendix → download → EdDSA verify → install → relaunch, and that the Accessibility grant survives (signature-based, unchanged Team ID).

### 10. Cleanup

Remove the throwaway key file (`~/Downloads/alt-tab-sparkle-private-key.txt`) after importing into 1Password + CI; no scratch dirs left in the repo.

## Verification

| # | Check | Command |
|---|---|---|
| 1 | framework linked, rpath present | `otool -l .build/release/AltTabCore \| grep -A2 LC_RPATH` |
| 2 | unpackaged demo modes still pass | `task build && swift run AltTabCore extras` → `PASS` |
| 3 | bundle seal + embedded framework | `./make-app.sh -l && codesign --verify --deep --strict ~/Applications/AltTab.app` |
| 4 | notarization still passes | CI release job green (app + DMG) |
| 5 | published feed signed | `curl -sL https://github.com/yurifrl/alt-tab/releases/latest/download/appcast.xml \| grep edSignature` |
| 6 | brew tracks releases | `brew info --cask yurifrl-alt-tab` right after a release |
| 7 | self-update end-to-end | 0.2.0 install → 0.2.1 release → menu check installs + relaunches, permission intact |

## Out of scope

- Delta/binary-diff updates (`BinaryDelta`) — the full DMG is ~1 MB.
- Automatic or background checks, "install on quit", Sparkle UI customization (pre-release channel and in-appcast release notes moved into scope — see Addendum).
- Moving the feed off GitHub Releases (e.g. gh-pages) unless `latest/download` proves unreliable.
- App Store distribution; non-macOS targets.

## Problems / risks

1. **Signing surface grows** (framework + two XPC services + Updater.app + Autoupdate). Mitigated by doing `make-app.sh -l` locally first, plus `codesign --verify --deep --strict` and the existing `spctl` check in CI. Highest-risk step; if notarization rejects nested code, inspect with `xcrun notarytool log`.
2. **No self-update path from 0.1.0** — updater code doesn't exist there. One-time `brew upgrade`/DMG; documented in release notes.
3. **Key custody is permanent** — the public key is baked into every install; loss/rotation = one-time manual reinstall for everyone. Store in 1Password + CI secret; never rotate.
4. **Feed host coupling** — `releases/latest/download` skips prereleases (desired) and 404s if the latest release is deleted/draft. Recover by re-publishing.
5. **Installer location** — Sparkle replaces the bundle in place; a non-admin or read-only install location triggers a credential prompt (expected, not an error).
6. **Brew version drift** — Homebrew records the version it installed, so after a self-update a plain cask may look "outdated"; `auto_updates true` (step 8) is what stops `brew upgrade` from fighting the app.

## Addendum — locked in conversation (2026-11-25)

Notes only; no code written from these yet.

### A. Pre-release channel

- Publish a pre-release build tracking `main`: rolling release under a fixed tag (`nightly`), marked **pre-release** so `releases/latest` — and therefore the stable feed URL and the stable casks — keep resolving to numbered releases only.
- User picks the channel in two independent places; both default to numbered/stable:
  - **App → Preferences → Updates**: "Channel: Stable | Pre-release", default Stable. One feed, items gated via `SPUUpdaterDelegate.allowedChannels` (untagged = stable only). The pref changes *what a check finds*, not *when* it checks — background checks stay off (unchanged decision).
  - **Brew**, at install time: `yurifrl-alt-tab` (newest numbered release; recommended), `yurifrl-alt-tab@latest` (newest stable), `yurifrl-alt-tab@nightly` (rolling main). They `conflicts_with` each other; switching = uninstall + install. Nightly cask also gets `auto_updates true`.
- Ordering is safe by construction: nightly builds keep the run-number `sparkle:version`, so a nightly install left on Stable follows the next numbered release — no downgrade trap. Same Team ID signs nightlies → Accessibility grant survives channel swaps.
- Open: cadence (daily cron + manual dispatch recommended; per-push as a later toggle) and channel plumbing (single feed + `sparkle:channel` vs separate nightly feed). Order: prove stable end-to-end first, then add nightlies — same machinery.

### B. Changelog + release notes (the `changelog` skill)

- **Format**: Keep a Changelog + SemVer — `## [Unreleased]`, `## [x.y.z] - <date>`, `### Added|Changed|Fixed|…`, `-` bullets. Rigid heading grammar = machine-parseable by the release script; plain markdown for humans.
- **Skill `changelog`** (global; supersedes the earlier "add-feature" idea): triggers when the user asks to update the changelog or declares a feature/change to record. Sole writer of curated content; appends under `## [Unreleased]` (creating that section if missing), proposing the entry for confirmation first.
- **Release-time stamping** (release workflow, on the `VERSION` change): move the `[Unreleased]` content under a new `## [x.y.z] - <date>` heading and do NOT create a fresh `[Unreleased]` — the skill recreates it on next append. Stamp commit is pushed back to `main` (safe: `tag.yml` path filter is `VERSION` only).
- **Assembly** (`scripts/release-notes.sh`): curated version section first, then a commit appendix from `git log <prev-tag>..<tag>` (categorized). `--generate-notes` gets dropped — with direct-to-main commits GitHub generates nothing but a compare link (verified on the 0.1.0 release).
- **Same assembled markdown, three destinations**: GitHub Release body (`gh release create --notes-file`), Sparkle update window (`AltTab.md` next to `AltTab.dmg` → appcast `<description sparkle:format="markdown">`; renders as the standard notes panel — version heading + bullets, per the Sparkle example screenshot, plus the commit appendix below), and it always matches the `CHANGELOG.md` section for that version.

### C. Non-functional: GitHub Actions architecture

- Goal: a deliberate, readable Actions setup worth copying as a reference — not one jumbled YAML. Thin workflow files (`tag.yml`, `release.yml`, `nightly.yml`) composing shared local **composite actions** (`.github/actions/<name>/action.yml`: signing setup, build+embed+sign, notarize, appcast, publish, changelog stamp) and/or a reusable `workflow_call` workflow — zero copy-paste between stable and nightly paths.
- Use the deliberate features: job `outputs` + `needs`, least-privilege `permissions`, `concurrency` groups, workflow-level `env`, `timeout-minutes`, typed `workflow_dispatch` inputs, artifacts passed between jobs, `if: always()` cleanup (temp keychain). Only GitHub-owned `actions/*` — no third-party marketplace actions.

### D. First-release checks (open) + review rulings

- **Notarization of `Autoupdate`** (unproven): the re-sign preserves Sparkle's ad-hoc entitlement (`com.apple.application-identifier = org.sparkle-project.Sparkle.Autoupdate`). Read the `notarytool log` of the first real release; if it objects, re-sign `Autoupdate` with `--preserve-metadata=flags` instead of `entitlements`.
- **EdDSA key handling** (ruled): piped to `generate_appcast` over stdin (`--ed-key-file -`), never written to disk — verified locally against a `SUPublicEDKey`-declaring build (`sparkle:edSignature` present); the CI step uses the same path.
- **Dependency pin** (ruled): `Package.resolved` is tracked; the declared `from: "2.10.1"` only bounds resolution, the lockfile is the pin.
