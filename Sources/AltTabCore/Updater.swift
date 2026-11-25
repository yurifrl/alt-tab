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
