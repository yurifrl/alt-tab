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
    /// Window keys by most recent focus (front = most recent). Per window, not
    /// per app: focusing one Chrome window moves only that window.
    private(set) var windowRecency: [String] = []
    /// Key of the window that currently has focus (ignored ones included).
    private(set) var focusedKey: String?
    private var ignoredKeys: Set<String> = []
    private var focusSuppressUntil = Date.distantPast

    var focusedIsIgnored: Bool { focusedKey.map { ignoredKeys.contains($0) } ?? false }

    /// Ignored windows are never bumped, so focusing them leaves order intact.
    private func noteFocused(_ key: String) {
        guard key != focusedKey else { return }
        focusedKey = key
        guard !ignoredKeys.contains(key) else { return }
        windowRecency.removeAll { $0 == key }
        windowRecency.insert(key, at: 0)
        if windowRecency.count > 300 { windowRecency.removeLast(windowRecency.count - 300) }
    }

    /// Switcher commit: the target is authoritative. Observed focus can lag
    /// and briefly report the app's previous window, so ignore observed
    /// changes for a moment instead of letting them bump the wrong window.
    func commitFocus(_ wm: WindowModel) {
        noteFocused(wm.key)
        focusSuppressUntil = Date().addingTimeInterval(0.8)
    }

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
            // Focused window of the frontmost app → its model key.
            var focused: String?
            if let front = NSWorkspace.shared.frontmostApplication,
               let fw = axCopy(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute),
               CFGetTypeID(fw) == AXUIElementGetTypeID() {
                let el = fw as! AXUIElement
                focused = rows.first { $0.ax.map { CFEqual($0, el) } ?? false }?.key
            }
            // Contexts filters, applied at model build time. Panel policies drive
            // the shared model; the switcher/session slices further by scope.
            if PrefsStore.hiddenPolicy == .doNotShow { rows.removeAll { $0.appHidden } }
            // Windowless apps: Do not show filters them; Show at bottom sinks
            // them below every windowed row (Contexts "Apps without windows").
            if PrefsStore.windowlessPolicy == .doNotShow { rows.removeAll { $0.windowless } }
            // Minimized windows: Do not show filters them; Show at bottom sinks
            // them below every visible row (Contexts "Minimized windows").
            if PrefsStore.minimizedPolicy == .doNotShow { rows.removeAll { $0.minimized } }
            // "Show at bottom" for minimized / hidden / windowless: one stable
            // sink pass (Array.sort is not stable — sort on (sinkKey, index)).
            let minBottom = PrefsStore.minimizedPolicy == .showAtBottom
            let hidBottom = PrefsStore.hiddenPolicy == .showAtBottom
            let wlBottom = PrefsStore.windowlessPolicy == .showAtBottom
            if minBottom || hidBottom || wlBottom {
                func sinkKey(_ w: WindowModel) -> (Int, Int, Int) {
                    (hidBottom && w.appHidden ? 1 : 0,
                     minBottom && w.minimized ? 1 : 0,
                     wlBottom && w.windowless ? 1 : 0)
                }
                rows = rows.enumerated()
                    .sorted {
                        let l = sinkKey($0.element), r = sinkKey($1.element)
                        return (l.0, l.1, l.2, $0.offset) < (r.0, r.1, r.2, $1.offset)
                    }
                    .map(\.element)
            }
            // Space scope: offscreen (other-Space) windows drop out; the
            // "+ fullscreen" variant keeps native-fullscreen windows.
            let scope = PrefsStore.spaceScope
            if scope != .allSpaces {
                rows.removeAll { w in
                    guard !w.minimized, !w.appHidden else { return false }
                    if scope == .visibleAndFullscreen, w.fullscreen { return false }
                    return offscreenWindowKeys.contains(WindowKey(pid: w.pid, title: w.title, frame: w.frame))
                }
            }
            // Rules excludes: one matcher, owned by the store (bundle rules +
            // per-app title patterns), applied to the whole model.
            // With "Show ignored windows" they stay, flagged, and sink in the panel.
            let showIgnored = PrefsStore.showIgnored
            if showIgnored {
                for i in rows.indices {
                    rows[i].ignored = PrefsStore.isExcluded(
                        bundleId: rows[i].bundleId, appLocalName: rows[i].appLocalName, title: rows[i].title)
                }
            } else {
                rows.removeAll { w in
                    PrefsStore.isExcluded(bundleId: w.bundleId, appLocalName: w.appLocalName, title: w.title)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.refreshGen else { return } // superseded sweep
                self.windows = rows
                self.ignoredKeys = Set(rows.filter(\.ignored).map(\.key))
                if let focused, Date() >= self.focusSuppressUntil { self.noteFocused(focused) }
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
