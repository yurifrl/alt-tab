import AppKit
import Sparkle

/// Manual-only updater: checks happen solely from the status-menu item.
/// Info.plist pins SUEnableAutomaticChecks/SUAutomaticallyUpdate to false, so
/// Sparkle never schedules a check of its own.
///
/// Channel policy: the stable feed (`releases/latest/download/appcast.xml`)
/// carries numbered releases untagged. Opting into Nightly also aims checks at
/// the nightly release's feed, which merges those stable items with one rolling
/// `sparkle:channel=nightly` item — nightly builds are offered only to clients
/// that asked for them, while a nightly client can still move to a newer
/// numbered release. `allowedChannels` is the second gate: clients without the
/// delegate (any pre-channel build) allow the default channel only, so tagged
/// items stay invisible to them even if a feed ever carries one.
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Sparkle needs a real .app bundle (bundle id, Info.plist feed URL, code
    /// signature). Unpackaged demo runs (`swift run AltTabCore extras`) get no
    /// updater, and the menu item is omitted.
    @discardableResult
    func start() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
        return true
    }

    @objc func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// True once `start()` built a controller — i.e. the process runs from an
    /// .app bundle. Preferences gates the check button on this.
    var isAvailable: Bool { controller != nil }

    // MARK: - SPUUpdaterDelegate

    /// Nightly channel checks the rolling pre-release feed; `nil` keeps the
    /// Info.plist `SUFeedURL` (the stable feed).
    func feedURLString(for updater: SPUUpdater) -> String? {
        PrefsStore.updateChannel == .nightly
            ? "https://github.com/yurifrl/alt-tab/releases/download/nightly/appcast.xml"
            : nil
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        PrefsStore.updateChannel == .nightly ? ["nightly"] : []
    }
}
