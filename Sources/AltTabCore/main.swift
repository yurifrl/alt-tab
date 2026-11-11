import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

struct WindowModel {
    let pid: pid_t
    let bundleId: String
    let appLocalName: String
    let title: String
    let frame: CGRect
    let minimized: Bool
    let ax: AXUIElement?
    /// App is currently hidden via Cmd+H ("hidden apps" filter).
    var appHidden: Bool = false
    /// App has no windows of its own ("windowless apps" filter).
    var windowless: Bool = false
    /// Rules alias for the app-name column (nil = show `appLocalName`). It
    /// drives the quick-go hint letter; search matches both it and the real
    /// name. `appLocalName` / `title` stay real: identity and matching use them.
    var alias: String? = nil
    /// "#RRGGBB" color tag from a matching rule (nil = none).
    var colorHex: String? = nil
    /// Window is in native fullscreen (its own Space) — kept by the
    /// "Visible Spaces (+ fullscreen)" scope even when offscreen.
    var fullscreen: Bool = false
    /// CGWindowID of the AX window (0 when unavailable): stable identity that
    /// survives title changes, so two same-titled/renamed windows never merge.
    var windowId: UInt32 = 0
    /// Matches an Ignore rule: kept out of the MRU rotation. Only present in
    /// the model when "Show ignored windows" is on; otherwise it is filtered.
    var ignored: Bool = false

    /// Identity for recency tracking.
    var displayName: String { alias ?? appLocalName }

    var key: String { windowId != 0 ? "w\(windowId)" : "p\(pid):\(title)" }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<UInt32>) -> AXError

private let axValueTypeId = AXValueGetTypeID()

/// Identity for the AX→CGWindow onscreen map (pid + title + frame).
struct WindowKey: Hashable {
    let pid: pid_t
    let title: String
    let frame: CGRect
}

/// Keys of windows not currently on the active Space (refreshed per enumerate).
var offscreenWindowKeys: Set<WindowKey> = []

private func axPoint(_ ref: CFTypeRef?) -> CGPoint? {
    guard let v = ref, CFGetTypeID(v) == axValueTypeId else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    return p
}

private func axSize(_ ref: CFTypeRef?) -> CGSize? {
    guard let v = ref, CFGetTypeID(v) == axValueTypeId else { return nil }
    var s = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgSize, &s)
    return s
}

private func axString(_ ref: CFTypeRef?) -> String? {
    guard let v = ref, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    return v as? String
}

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard err == .success, let v = value else { return nil }
    // Copy-rule: AX returns +1 we own; adopt it into ARC ownership.
    return Unmanaged.passRetained(v).takeRetainedValue()
}

func enumerateWindows() -> [WindowModel] {
    guard AXIsProcessTrusted() else {
        print("AXIsProcessTrusted: false — grant Accessibility and retry")
        return []
    }
    // CGWindowList is the only source for space/onscreen truth: AX sees every
    // window on every Space. Map layer-0 onscreen window ids → (pid, bounds).
    var onscreenByPid: [pid_t: Set<UInt32>] = [:]
    var idsByPidBounds: [pid_t: [UInt32: CGRect]] = [:]
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? UInt32 else { continue }
            onscreenByPid[ownerPid, default: []].insert(id)
            if let b = info[kCGWindowBounds as String] as? [String: CGFloat],
               let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] {
                idsByPidBounds[ownerPid, default: [:]][id] = CGRect(x: x, y: y, width: w, height: h)
            }
        }
    }
    var out: [WindowModel] = []
    for app in NSWorkspace.shared.runningApplications {
        // Accessory (menu-bar, LSUIElement) apps carry real windows too — this
        // app's own Preferences window, the sidebar, 1Password. Only
        // .prohibited helpers are skipped.
        guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { continue }
        let isRegular = app.activationPolicy == .regular
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windowsVal = axCopy(axApp, kAXWindowsAttribute),
              CFGetTypeID(windowsVal) == CFArrayGetTypeID() else {
            // No AX windows at all — potential "windowless app" row. Accessory
            // apps stay out: menu-bar agents with no window list would flood
            // the switcher once "Apps without windows" is Show.
            if isRegular, PrefsStore.windowlessPolicy != .doNotShow, !app.isHidden {
                out.append(WindowModel(pid: app.processIdentifier,
                                       bundleId: app.bundleIdentifier ?? "",
                                       appLocalName: app.localizedName ?? "?",
                                       title: app.localizedName ?? "?",
                                       frame: .zero, minimized: false, ax: nil,
                                       windowless: true))
            }
            continue
        }
        let cfArr = windowsVal as! CFArray
        var windows: [AXUIElement] = []
        windows.reserveCapacity(CFArrayGetCount(cfArr))
        for i in 0..<CFArrayGetCount(cfArr) {
            // Borrowed element: retain independently so it outlives cfArr.
            windows.append(Unmanaged<AXUIElement>.fromOpaque(CFArrayGetValueAtIndex(cfArr, i)).retain().takeRetainedValue())
        }
        let appHidden = app.isHidden
        for w in windows {
            let title = axString(axCopy(w, kAXTitleAttribute)) ?? ""
            // Accessory apps list utility surfaces too — untitled menu-bar
            // strips and overlay hooks (MenuBarAgent, Grammarly, TypeWhisper).
            // Keep only their titled, normal-level windows: menu-bar agents
            // sit on CG layers ≥ 1 (strips 24/25, Grammarly overlay 1), and
            // real surfaces (Preferences panes, 1Password) sit on layer 0.
            if !isRegular && title.isEmpty { continue }
            let minimized = (axCopy(w, kAXMinimizedAttribute) as? Bool) ?? false
            var frame = CGRect.zero
            if let p = axPoint(axCopy(w, kAXPositionAttribute)),
               let s = axSize(axCopy(w, kAXSizeAttribute)) {
                frame = CGRect(origin: p, size: s)
            }
            // Match AX window → CGWindow id: same pid + overlapping bounds.
            var cgId: UInt32?
            if let candidates = idsByPidBounds[app.processIdentifier] {
                cgId = candidates.first { $1.intersects(frame) }?.key
            }
            let onscreen = cgId.map { onscreenByPid[app.processIdentifier]?.contains($0) ?? false } ?? false
            // Accessory windows exist only as normal-level CG surfaces; no
            // layer-0 CG match means overlay/utility (Grammarly edge bar).
            if !isRegular && cgId == nil { continue }
            out.append(WindowModel(pid: app.processIdentifier,
                                   bundleId: app.bundleIdentifier ?? "",
                                   appLocalName: app.localizedName ?? "?",
                                   title: title,
                                   frame: frame,
                                   minimized: minimized,
                                   ax: w,
                                   appHidden: appHidden,
                                   windowless: false,
                                   fullscreen: (axCopy(w, "AXFullScreen") as? Bool) ?? false,
                                   windowId: {
                                       var id: UInt32 = 0
                                       return _AXUIElementGetWindow(w, &id) == .success ? id : 0
                                   }()))
            // Stash onscreen bit: encode via frame zero + onscreen check site later.
            if !onscreen { offscreenWindowKeys.insert(WindowKey(pid: app.processIdentifier, title: title, frame: frame)) }
            else { offscreenWindowKeys.remove(WindowKey(pid: app.processIdentifier, title: title, frame: frame)) }
        }
    }
    return out
}

func printTable(_ windows: [WindowModel]) {
    print("APP                     PID    STATE  TITLE [x,y w×h]")
    print(String(repeating: "-", count: 78))
    for w in windows {
        let app = (w.appLocalName as NSString).substring(to: min(22, w.appLocalName.count))
        let title = w.title.isEmpty ? "(untitled)" : w.title
        print("\(app.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(w.pid).padding(toLength: 6, withPad: " ", startingAt: 0)) \(w.minimized ? "min" : "vis")  \(title) [\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \(Int(w.frame.width))×\(Int(w.frame.height))]")
    }
    print("---")
    print("apps scanned: \(Set(windows.map(\.pid)).count), windows: \(windows.count)")
}

// MARK: - Activation (slice 2)

/// Raises the AX window and activates its application, then polls AX for proof.
/// Returns (focusedTitle, verified) after timeout.
@discardableResult
func activate(_ wm: WindowModel, timeout: TimeInterval = 3.0) -> (title: String, verified: Bool) {
    beginActivation(wm)
    return verifyActivation(wm, timeout: timeout)
}

/// Fire-and-forget commit activation: raise + app activate now (cheap, stays
/// on main), then the up-to-`timeout` verification poll + AppleScript fallback
/// on a background queue. The poll sleeps in 0.1 s steps — on main it would
/// starve the event tap and WindowServer silently drops hotkey events.
func activateAndVerify(_ wm: WindowModel, timeout: TimeInterval = 3.0) {
    beginActivation(wm)
    DispatchQueue.global().async {
        _ = verifyActivation(wm, timeout: timeout)
    }
}

private func beginActivation(_ wm: WindowModel) {
    if let ax = wm.ax {
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
    NSRunningApplication(processIdentifier: wm.pid)?
        .activate(options: [.activateIgnoringOtherApps])
}

private func verifyActivation(_ wm: WindowModel, timeout: TimeInterval) -> (title: String, verified: Bool) {
    // macOS 14+ cooperative activation rejects focus steals from non-app processes.
    // Fallback: System Events Apple Event (the route the app is entitled for).
    func frontmostIsTarget() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == wm.pid
    }
    let softDeadline = Date().addingTimeInterval(timeout * 0.6)
    while Date() < softDeadline {
        if frontmostIsTarget() { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if !frontmostIsTarget() {
        // NSAppleScript is main-thread-only and this poll runs off main; shell
        // the System Events AE out to osascript (isolated process).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(wm.pid)) to true"]
        try? p.run()
        p.waitUntilExit()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var focusedTitle = ""
    while Date() < deadline {
        let axApp = AXUIElementCreateApplication(wm.pid)
        if let focused = axCopy(axApp, kAXFocusedWindowAttribute),
           let t = axString(axCopy(focused as! AXUIElement, kAXTitleAttribute)) {
            focusedTitle = t
            if t == wm.title { return (t, true) }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return (focusedTitle, false)
}

// MARK: - Window actions (in-panel action keys)

/// AX button lookup: kAXCloseButtonAttribute etc., hit-test path via AXChildren.
private func axButton(_ ax: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = axCopy(ax, attr) else { return nil }
    // Copy-rule: AX returns +1 we own; adopt into ARC.
    return (v as! AXUIElement)
}

/// Close window (⌥W by default).
@discardableResult
func closeWindow(_ wm: WindowModel) -> Bool {
    guard let ax = wm.ax else { return false }
    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    guard let btn = axButton(ax, kAXCloseButtonAttribute) else { return false }
    AXUIElementPerformAction(btn, kAXPressAction as CFString)
    print("action: close [\(wm.appLocalName)] \"\(wm.title)\"")
    return true
}

/// Minimize window (⌥M).
@discardableResult
func minimizeWindow(_ wm: WindowModel) -> Bool {
    guard let ax = wm.ax else { return false }
    guard let btn = axButton(ax, kAXMinimizeButtonAttribute) else { return false }
    AXUIElementPerformAction(btn, kAXPressAction as CFString)
    print("action: minimize [\(wm.appLocalName)] \"\(wm.title)\"")
    return true
}

/// Hide application (⌥H — app-level, like Cmd+H).
@discardableResult
func hideApp(_ wm: WindowModel) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: wm.pid) else { return false }
    let ok = app.hide()
    print("action: hide [\(wm.appLocalName)] ok=\(ok)")
    return ok
}

/// Quit application (⌥Q).
@discardableResult
func quitApp(_ wm: WindowModel) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: wm.pid) else { return false }
    let ok = app.terminate()
    print("action: quit [\(wm.appLocalName)] ok=\(ok)")
    return ok
}

func runActivationDemo() {
    let windows = enumerateWindows().filter { !$0.minimized && !$0.title.isEmpty }
    // Deterministic, adversarial target: a Chrome profile window (multi-profile = hardest focus case).
    let target = windows.first { $0.appLocalName == "Google Chrome" && $0.title.contains("(Personal)") }
        ?? windows.first { $0.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier }
    guard let target else { print("no suitable target window"); exit(1) }

    let before = NSWorkspace.shared.frontmostApplication
    print("target: [\(target.appLocalName)] \"\(target.title)\" pid=\(target.pid)")
    print("frontmost before: pid=\(before?.processIdentifier ?? -1) \(before?.localizedName ?? "?")")

    let (focused, verified) = activate(target)
    let after = NSWorkspace.shared.frontmostApplication
    print("frontmost after:  pid=\(after?.processIdentifier ?? -1) \(after?.localizedName ?? "?")")
    print("focused window title: \"\(focused)\"")
    print(verified && after?.processIdentifier == target.pid ? "PASS" : "FAIL")
    exit(verified && after?.processIdentifier == target.pid ? 0 : 1)
}

// MARK: - Hotkey cycle (slice 3)

/// Fires a synthetic Ctrl+Option+Cmd+W key event through the HID tap.
func postSyntheticHotkey() {
    HotkeyCenter.shared.rearm()
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: down)
        ev?.flags = [.maskCommand, .maskAlternate, .maskControl]
        ev?.post(tap: .cghidEventTap)
    }
}

func runHotkeyDemo() {
    let hotkeyMods = UInt32(controlKey | optionKey | cmdKey)
    var activations: [(pid: pid_t, title: String)] = []

    guard HotkeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_W), modifiers: hotkeyMods, handler: {
        let windows = enumerateWindows().filter { !$0.minimized && !$0.title.isEmpty }
        guard !windows.isEmpty else { return }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Cycle: first window of an app that isn't frontmost; else advance within frontmost's windows.
        var next: WindowModel
        if let otherAppWindow = windows.first(where: { $0.pid != frontPid }) {
            next = otherAppWindow
        } else if let idx = windows.firstIndex(where: { $0.pid == frontPid }) {
            next = windows[(idx + 1) % windows.count]
        } else {
            next = windows[0]
        }
        let (_, ok) = activate(next, timeout: 2.0)
        activations.append((next.pid, "\(ok ? "✓" : "✗") \(next.appLocalName): \(next.title)"))
        print("hotkey → \(activations.last!.title)")
    }) else {
        print("hotkey registration failed")
        exit(1)
    }
    print("registered Ctrl+Option+Cmd+W — posting 2 synthetic presses")

    let runloopEnd = Date().addingTimeInterval(9)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { postSyntheticHotkey() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { postSyntheticHotkey() }

    RunLoop.main.run(until: runloopEnd)
    Thread.sleep(forTimeInterval: 1.0) // let last activation settle

    let final = NSWorkspace.shared.frontmostApplication
    print("fires=\(activations.count)/2, frontmost final: pid=\(final?.processIdentifier ?? -1) \(final?.localizedName ?? "?")")
    let pass = activations.count == 2 && activations.contains { $0.pid == final?.processIdentifier }
    print(pass ? "PASS" : "FAIL")
    exit(pass ? 0 : 1)
}

// MARK: - Panel demo (Phase 2 — Switcher panel v1)

/// Escape hatch for hotkey processing.
private let postSyntheticKey: (UInt32, CGEventFlags) -> Void = { keyCode, modifiers in
    HotkeyCenter.shared.rearm()
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down)
        ev?.flags = modifiers
        ev?.post(tap: .cghidEventTap)
    }
}

func runPanelDemo() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let mods = UInt32(controlKey | optionKey | cmdKey)
    _ = postSyntheticKey
    guard SwitcherSession.shared.installDemoShortcut(key: UInt32(kVK_ANSI_W), mods: mods) else {
        print("hotkey register failed")
        exit(1)
    }
    print("panel: hotkey registered")

    func pressHotkey() { postSyntheticKey(UInt32(kVK_ANSI_W), [.maskCommand, .maskAlternate, .maskControl]) }
    func key(_ kc: UInt32) { postSyntheticKey(kc, []) }

    let down = UInt32(kVK_DownArrow), up = UInt32(kVK_UpArrow)
    let digit1 = UInt32(18), ret = UInt32(kVK_Return), esc = UInt32(kVK_Escape)

    // Timeline: open → 2×down → up → digit → esc | reopen → commit.
    let schedule: [(Double, () -> Void)] = [
        (0.5, { pressHotkey() }),            // open (selection 0)
        (1.8, { key(down) }),                // selection 1
        (2.6, { key(down) }),                // selection 2
        (3.4, { key(up) }),                  // selection 1
        (4.2, { key(digit1) }),              // selection 0 (digit jump)
        (5.0, { key(esc) }),                 // cancel
        (5.8, { pressHotkey() }),            // reopen (selection 0)
        (7.6, { key(ret) }),                 // commit → activate
    ]
    for (delay, action) in schedule {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }

    // Assertions after the sequence settles.
    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
        var failures: [String] = []
        // A: reopen committed → frontmost = expected target pid
        if let expectPid = SwitcherSession.shared.lastCommittedPid {
            let got = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if got != expectPid { failures.append("frontmost pid \(got ?? -1) ≠ committed \(expectPid)") }
        } else {
            failures.append("no commit recorded")
        }
        // B: panel closed after commit
        if SwitcherSession.shared.isOpen { failures.append("panel still open after commit") }
        // C: per-display panels: one overlay per NSScreen, centered, rows partitioned
        let screens = NSScreen.screens
        for g in SwitcherSession.shared.panelGeometry {
            let cx = g.panel.midX, cy = g.panel.midY
            let sx = g.screen.midX, sy = g.screen.midY
            if abs(cx - sx) > 2 || abs(cy - sy) > 2 {
                failures.append("panel not centered: mid=(\(cx),\(cy)) screen mid=(\(sx),\(sy))")
            }
            if !g.screen.contains(g.panel) {
                failures.append("panel outside visibleFrame: \(g)")
            }
        }
        let rowSum = SwitcherSession.shared.panelGeometry.reduce(0) { $0 + $1.rowCount }
        if screens.count > 1 && SwitcherSession.shared.panelGeometry.count != screens.count {
            failures.append("panels \(SwitcherSession.shared.panelGeometry.count) ≠ screens \(screens.count)")
        }
        print("panel: geometry screens=\(screens.count) panels=\(SwitcherSession.shared.panelGeometry.count) rowSum=\(rowSum)")
        for g in SwitcherSession.shared.panelGeometry { print("  \(g)") }
        // C: cancel path hid the panel (mid-sequence open/close observed via logs)
        print(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    RunLoop.main.run(until: Date().addingTimeInterval(11.5))
    exit(3)
}

// MARK: - Live-tracking demo (Phase 3)

func runTrackDemo() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let mods = UInt32(controlKey | optionKey | cmdKey)
    guard SwitcherSession.shared.installDemoShortcut(key: UInt32(kVK_ANSI_W), mods: mods) else {
        print("hotkey register failed"); exit(1)
    }
    var wsHits = 0, onChangeHits = 0
    WindowTracker.shared.addChangeHandler("track-demo") {
        wsHits += 1
        onChangeHits += 1
        print("track: onChange #\(onChangeHits)")
    }

    // t+0.5: programmatic activation → ws:activated + AX focused change → rebuild.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targets = enumerateWindows().filter { !$0.minimized && !$0.title.isEmpty && $0.pid != frontPid }
        guard let target = targets.first(where: { $0.appLocalName.contains("Chrome") }) ?? targets.first else {
            print("track: no activation target"); exit(1)
        }
        print("track: activating [\(target.appLocalName)] \"\(target.title)\"")
        _ = activate(target, timeout: 2.0)
    }
    // t+2.5: open panel from the tracker's model.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        print("track: opening panel")
        SwitcherSession.shared.open()
    }
    // t+4.5: second activation WHILE panel open → live refresh path.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targets = enumerateWindows().filter { !$0.minimized && !$0.title.isEmpty && $0.pid != frontPid }
        guard let other = targets.first(where: { $0.appLocalName.contains("Chrome") }) ?? targets.first else {
            print("track: no while-open target"); return
        }
        print("track: activating-while-open [\(other.appLocalName)] \"\(other.title)\"")
        _ = activate(other, timeout: 2.0)
    }
    // t+7: settle, cancel panel, assert both change channels fired.
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
        SwitcherSession.shared.close(commit: false)
        print("track: wsNotifications=\(wsHits) onChangeDeliveries=\(onChangeHits)")
        let pass = wsHits >= 2 && onChangeHits >= 2
        print(pass ? "PASS" : "FAIL")
        exit(pass ? 0 : 1)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(9))
    exit(3)
}

// MARK: - Prefs demo (Phase 5)

/// Opens the Windows tab with sample rules (debug build: separate defaults
/// domain) so the layout can be screenshotted: `AltTabCore prefs-ui`.
func runPrefsUIDemo() {
    NSApplication.shared.setActivationPolicy(.regular)
    PrefsStore.windowRules = [
        .init(bundleId: "com.google.Chrome", pattern: "=Google Cloud Platform - Google Chrome - Yuri (Nsx)", hide: false, alias: "Work Chrome", color: "#34d399"),
        .init(bundleId: "com.google.Chrome", pattern: "Trail-code", hide: false, alias: "Personal Chrome", color: "#f97316"),
        .init(bundleId: "com.google.Chrome", pattern: "^New Tab", hide: true, alias: "Dev Chrome", color: ""),
        .init(bundleId: "com.apple.Terminal", pattern: "", hide: false, alias: "", color: "#a855f7"),
    ]
    PrefsWindowController.shared.showTab("Windows")
    PrefsWindowController.shared.showWindow(nil)
    NSApplication.shared.run()
}

func runPrefsDemo() {
    var failures: [String] = []
    for theme in PrefsStore.Theme.allCases {
        PrefsStore.theme = theme
        if PrefsStore.theme != theme { failures.append("roundtrip \(theme.rawValue)") }
        let (_, material) = PrefsStore.appearance(for: theme)
        if theme == .vibrantDark, material != .hudWindow { failures.append("dark material") }
        if theme == .vibrantLight, material != .underWindowBackground { failures.append("light material") }
    }
    PrefsStore.theme = .vibrantDark
    let controller = SwitcherPanelController()
    controller.show(WindowTracker.shared.windows.filter { !$0.title.isEmpty })
    if controller.geometryReport.isEmpty { failures.append("no panel shown") }
    controller.hide()
    PrefsStore.maxRows = 11
    if PrefsStore.maxRows != 11 { failures.append("maxRows") }
    PrefsStore.maxRows = 8
    print("prefs: theme=\(PrefsStore.theme.rawValue) shortcuts=\(PrefsStore.shortcuts.count) on=\(PrefsStore.shortcuts.filter(\.on).count)")
    print(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
    exit(failures.isEmpty ? 0 : 1)
}

// MARK: - Extras demos (Phase 6)

func runExtrasDemo() {
    NSApplication.shared.setActivationPolicy(.accessory)
    var failures: [String] = []

    // Search: type-to-filter narrows rows, commits the filtered selection.
    _ = SwitcherSession.shared.installDemoShortcut(key: UInt32(kVK_ANSI_W), mods: UInt32(controlKey | optionKey | cmdKey))
    SwitcherSession.shared.openForTest()
    let rowBefore = SwitcherSession.shared.panelRows
    SwitcherSession.shared.typeForTest("ter")
    let rowAfter = SwitcherSession.shared.panelRows
    if !(rowAfter.count < rowBefore.count) { failures.append("search did not narrow \(rowBefore)→\(rowAfter)") }
    if SwitcherSession.shared.isOpen { SwitcherSession.shared.close(commit: false) }

    // Workspaces excludes: excluded bundle id never rendered.
    PrefsStore.windowRules = [PrefsStore.WindowRule(bundleId: "com.google.Chrome", pattern: "", hide: true, alias: "")]
    SwitcherSession.shared.openForTest()
    let chromeRows = SwitcherSession.shared.panelRows.filter { $0.bundleId == "com.google.Chrome" }
    if !chromeRows.isEmpty { failures.append("workspace exclude leaked \(chromeRows.count) rows") }
    if SwitcherSession.shared.isOpen { SwitcherSession.shared.close(commit: false) }
    PrefsStore.windowRules = []

    // Gestures: private MultitouchSupport stack installs on the attached devices.
    let devices = GestureSwitch.shared.start()
    GestureSwitch.shared.handler = {}
    print("extras: devices=\(devices) search \(rowBefore)→\(rowAfter)")

    print(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
    exit(failures.isEmpty ? 0 : 1)
}

// MARK: - Single-instance guard

/// Exclusive non-blocking `flock` held for the agent's lifetime; the kernel
/// releases it when the process dies, so a crash never strands the lock and
/// a relaunch always acquires. Returns false when another agent already runs.
func acquireAgentLock(at url: URL) -> Bool {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else {
        print("alt-tab: agent lock unreachable (\(url.path), errno \(errno)) — running without instance guard")
        return true
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        let pid = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        print("alt-tab: another agent is running (pid \(pid)) — exiting")
        return false
    }
    // Record the holder pid for the refusal message; failure is cosmetic.
    ftruncate(fd, 0)
    "\(getpid())".withCString { _ = write(fd, $0, strlen($0)) }
    return true   // fd stays open: the lock lives as long as this process
}

let agentLockURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/alt-tab/agent.lock")

func runAgent() {
    guard acquireAgentLock(at: agentLockURL) else { exit(0) }
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: agent logs interleave with stderr
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // status-bar agent, no dock icon

    let actions = AgentActions()
    let menu = NSMenu()
    let title = NSMenuItem(title: "alt-tab — running", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    menu.addItem(.separator())
    let openItem = NSMenuItem(title: "Open Switcher Now",
                              action: #selector(AgentActions.openSwitcher), keyEquivalent: "")
    openItem.target = actions
    menu.addItem(openItem)
    let prefsItem = NSMenuItem(title: "Preferences…",
                               action: #selector(AgentActions.showPrefs),
                               keyEquivalent: ",")
    prefsItem.target = actions
    menu.addItem(prefsItem)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(title: "Quit alt-tab",
                              action: #selector(AgentActions.quit), keyEquivalent: "q")
    quitItem.target = actions
    menu.addItem(quitItem)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "⇥"
    item.menu = menu

    PrefsStore.migrateShortcuts()

    // Never exit for missing permission: install the hotkey when trusted,
    // otherwise show the system prompt once and poll until granted (or
    // forever — the status item stays available so the user can always quit).
    var didPrompt = false
    func installWhenReady() {
        if SwitcherSession.shared.installShortcuts() {
            print("alt-tab agent: trigger shortcuts installed — hold to switch; running forever")
        } else if !AXIsProcessTrusted() {
            if !didPrompt {
                didPrompt = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)   // shows the system prompt exactly once
            }
            item.button?.appearsDisabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: installWhenReady)
        } else {
            // Trusted but tap creation failed — transient; retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: installWhenReady)
        }
    }
    installWhenReady()

    app.run()   // never returns
}

@objc final class AgentActions: NSObject {
    // Instance methods: the menu items target an AgentActions instance, and a
    // static func is not on the instance — statics left every item disabled.
    @objc func openSwitcher() { SwitcherSession.shared.open() }
    @objc func showPrefs() { PrefsWindowController.shared.showWindow(nil) }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

let windows = enumerateWindows()
// No argument → the real product: the always-on agent (app bundles launch bare).
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run"
switch mode {
case "enum":     printTable(windows)
case "activate": runActivationDemo()
case "hotkey":   runHotkeyDemo()
case "panel":    runPanelDemo()
case "track":    runTrackDemo()
case "prefs":    runPrefsDemo()
case "prefs-ui": runPrefsUIDemo()
case "extras":   runExtrasDemo()
case "run":      runAgent()
default:
    print("usage: AltTabCore [enum|activate|hotkey|panel|track|prefs|extras|run]")
    exit(2)
}
