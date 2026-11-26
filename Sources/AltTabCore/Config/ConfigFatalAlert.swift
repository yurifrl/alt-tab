import AppKit

/// The app's answer to a settings file it cannot read: name the file, line and
/// problem in a modal alert with the two useful ways out. The caller exits 1
/// afterwards; a button press only clears the alert.
enum ConfigFatalAlert {
    static func present(_ error: ConfigError) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "alt-tab cannot read its settings"
        alert.informativeText = error.description
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Quit")

        app.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: error.file)])
        }
    }
}
