<p align="center">
  <img src="assets/logo/header.svg" alt="AltTab — keyboard-driven window switcher for macOS" width="100%">
</p>

A macOS window switcher: a keyboard-driven overlay listing app windows across displays, with search, per-window color tags, and more. Requires macOS 12+.

## Install

Via [Homebrew](https://brew.sh):

```bash
brew tap yurifrl/casks

# pinned to the newest tagged release (updated automatically on each release)
brew install --cask yurifrl-alt-tab

# or: always the newest GitHub release, whatever the tap's pinned version says
brew install --cask yurifrl-alt-tab@latest
```

The two casks install the same `AltTab.app`, so they conflict; pick one.

Then launch AltTab and grant it **Accessibility** access when prompted
(System Settings → Privacy & Security → Accessibility).

### Updating

```bash
brew update && brew upgrade --cask yurifrl-alt-tab
# the @latest cask is unversioned, so Homebrew needs --greedy to refresh it:
brew upgrade --cask --greedy yurifrl-alt-tab@latest
```

### Manual download

Grab `AltTab.dmg` from the [latest release](https://github.com/yurifrl/alt-tab/releases/latest) and drag AltTab to Applications.

### Uninstall

```bash
brew uninstall --cask yurifrl-alt-tab        # or yurifrl-alt-tab@latest
```

## Build from source

```bash
task install        # build release, sign, install to /Applications (-- -l for ~/Applications)
```

## Releasing

Bump the `VERSION` file and merge to `main`. The **Tag** workflow creates `vX.Y.Z`, and the **Release** workflow builds a universal, Developer ID signed and notarized `AltTab.dmg`, publishes the GitHub Release, and bumps the pinned cask in [yurifrl/homebrew-casks](https://github.com/yurifrl/homebrew-casks).

Required repo configuration:

| Kind | Name |
|---|---|
| variable | `DEVELOPER_ID_APPLICATION` |
| secrets | `MACOS_SIGNING_P12_BASE64`, `MACOS_SIGNING_P12_PASSWORD`, `ASC_API_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID` |
| secret | `HOMEBREW_TAP_TOKEN` (PAT with write access to `yurifrl/homebrew-casks`) |
