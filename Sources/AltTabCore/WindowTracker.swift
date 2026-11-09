import AppKit
import ApplicationServices

/// Keeps a fresh window model without blind re-enumeration (Contexts-style):
/// NSWorkspace activation/termination notifications + per-app AXObservers for
/// focused-window, title, and minimized changes. Any change rebuilds the model
/// and notifies listeners.
final class WindowTracker {
    static let shared = WindowTracker()

    private var started = false
    private var observers: [pid_t: (AXObserver, CFRunLoopSource)] = [:]
    /// Observed window elements must outlive the observer registration.
    private var observedWindows: [pid_t: [AXUIElement]] = [:]
    private(set) var windows: [WindowModel] = []

    /// Main-thread listeners, called after every model rebuild.
    private var changeHandlers: [String: () -> Void] = [:]

    func addChangeHandler(_ key: String, _ handler: @escaping () -> Void) {
        changeHandlers[key] = handler
    }

    func removeChangeHandler(_ key: String) {
        changeHandlers.removeValue(forKey: key)
    }

    private func notifyChange() {
        for handler in changeHandlers.values { handler() }
    }

    private var lastChangeLog = ""

    /// Serial queue for the AX enumeration sweep. Serial so overlapping
    /// sweeps never interleave writes to `offscreenWindowKeys`.
    private let sweepQueue = DispatchQueue(label: "at.windowtracker.sweep")
    /// Main-thread generation counter: a slow sweep finishing after a newer
    /// refresh must not clobber the newer model.
    private var refreshGen = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let ws = NSWorkspace.shared
        ws.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        refresh(reason: "start")
        for app in ws.runningApplications
        where app.activationPolicy == .regular || app.activationPolicy == .accessory {
            attachObserver(to: app)
        }
    }

    // MARK: - NSWorkspace notifications

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        log("ws:activated pid=\(app.processIdentifier) \(app.localizedName ?? "?")")
        refresh(reason: "activate")
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        detachObserver(pid: app.processIdentifier)
        log("ws:terminated pid=\(app.processIdentifier) \(app.localizedName ?? "?")")
        refresh(reason: "terminate")
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular || app.activationPolicy == .accessory else { return }
        attachObserver(to: app)
        log("ws:launched pid=\(app.processIdentifier) \(app.localizedName ?? "?")")
        refresh(reason: "launch")
    }

    // MARK: - AX observers

    /// NOTE: AXObserverGetNotificationCenter returns a CFNotificationCenter whose
    /// sources must be a CFRunLoopSource — AXObserver's own source. Adding via
    /// CFRunLoopAddSource(NSRunLoop.main.getCFRunLoop(), src, .defaultMode).
    private func attachObserver(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid as pid_t, axObserverCallback, &observer)
        guard result == .success, let obs = observer else { return }

        // Observer callback refcon: singleton outlives the process; unretained is safe.
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let appElement = AXUIElementCreateApplication(pid)
        // App-level: focused/main window swaps drive refresh.
        AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, ctx)
        AXObserverAddNotification(obs, appElement, kAXMainWindowChangedNotification as CFString, ctx)
        // Window-level: title/minimize/destroy on current windows (best effort).
        if let windowsVal = axCopy(appElement, kAXWindowsAttribute),
           CFGetTypeID(windowsVal) == CFArrayGetTypeID() {
            let cfArr = windowsVal as! CFArray
            var kept: [AXUIElement] = []
            kept.reserveCapacity(CFArrayGetCount(cfArr))
            for i in 0..<CFArrayGetCount(cfArr) {
                let w = Unmanaged<AXUIElement>.fromOpaque(CFArrayGetValueAtIndex(cfArr, i))
                    .retain().takeRetainedValue()
                AXObserverAddNotification(obs, w, kAXTitleChangedNotification as CFString, ctx)
                AXObserverAddNotification(obs, w, kAXWindowMiniaturizedNotification as CFString, ctx)
                AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, ctx)
                kept.append(w)
            }
            observedWindows[pid] = kept
        }

        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        observers[pid] = (obs, src)
    }

    private func detachObserver(pid: pid_t) {
        guard let (_, src) = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        observedWindows.removeValue(forKey: pid)
    }

    // MARK: - Model

    /// Must be called on the main thread (generation stamping and the apply/
    /// notify tail are main-confined). The AX sweep itself can block for
    /// seconds on busy apps — observed ~2 s while a busy Chrome was being
    /// activated — and on main it starves the event tap: WindowServer then
    /// silently drops hotkey events until the tap recovers. Enumerate + filter
    /// on the serial sweep queue, apply the snapshot on main.
    func refresh(reason: String) {
        let gen = refreshGen + 1
        refreshGen = gen
        sweepQueue.async { [weak self] in
            var rows = enumerateWindows()
            // Contexts filters, applied at model build time. Panel policies drive
            // the shared model; the switcher/session slices further by scope.
            if PrefsStore.hiddenPolicy == .doNotShow { rows.removeAll { $0.appHidden } }
            // Windowless apps: Do not show filters them; Show at bottom sinks
            // them below every windowed row (Contexts "Apps without windows").
            if PrefsStore.windowlessPolicy == .doNotShow { rows.removeAll { $0.windowless } }
            // Minimized windows: Do not show filters them; Show at bottom sinks
            // them below every visible row (Contexts "Minimized windows").
            if PrefsStore.minimizedPolicy == .doNotShow { rows.removeAll { $0.minimized } }
            if PrefsStore.minimizedPolicy == .showAtBottom || PrefsStore.windowlessPolicy == .showAtBottom {
                // One stable sink pass: minimized first, then windowless
                // (windowless rows are never minimized, so the keys don't fight).
                func sinkKey(_ w: WindowModel) -> (Int, Int) {
                    (PrefsStore.minimizedPolicy == .showAtBottom && w.minimized ? 1 : 0,
                     PrefsStore.windowlessPolicy == .showAtBottom && w.windowless ? 1 : 0)
                }
                rows.sort { sinkKey($0) < sinkKey($1) }
            }
            if PrefsStore.spaceScope != .allSpaces {
                rows.removeAll { !$0.minimized && offscreenWindowKeys.contains(WindowKey(pid: $0.pid, title: $0.title, frame: $0.frame)) }
            }
            // Rules excludes: one matcher, owned by the store (bundle rules +
            // per-app title patterns), applied to the whole model.
            rows.removeAll { w in
                PrefsStore.isExcluded(bundleId: w.bundleId, appLocalName: w.appLocalName, title: w.title)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.refreshGen else { return } // superseded sweep
                self.windows = rows
                let summary = self.windows.map { "\($0.pid):\($0.title.isEmpty ? "-" : $0.title)" }.joined(separator: " | ")
                if summary != self.lastChangeLog {
                    self.lastChangeLog = summary
                    self.log("model[\(reason)] \(self.windows.count) rows — \(summary)")
                } else {
                    self.log("model[\(reason)] \(self.windows.count) rows (unchanged)")
                }
                self.notifyChange()
            }
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("TRACK \(s)\n".utf8))
    }
}

/// C entry point for AXObserver callbacks. refcon carries WindowTracker.
private func axObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement,
    _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        tracker.refresh(reason: "ax:\(notification as String)")
    }
}
