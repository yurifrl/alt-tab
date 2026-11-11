import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global-hotkey engine built on an active CGEventTap (Contexts-style:
/// `CFMachPortCreateRunLoopSource` session tap). Matches keyDown events by
/// exact keycode + modifier-set intersection on the standard modifier bits.
/// Carbon `RegisterEventHotKey` is NOT used: on this macOS it ignores
/// synthetic key events, and an active tap both catches hardware and
/// synthetic posts uniformly and lets us consume the matched key.
///
/// Supports multiple simultaneous bindings (main switcher key, "move up",
/// "search with") and tracks held modifiers per physical side from
/// flagsChanged keycodes (left/right Command/Option/Control/Shift + Fn) —
/// CGEventFlags cannot distinguish sides; keycodes 54/55/58/61/59/62/56/60/63 can.

final class HotkeyCenter {
    static let shared = HotkeyCenter()

    struct Binding {
        let id: String
        let keyCode: UInt32
        let mods: CGEventFlags
        let handler: (CGEvent) -> Void
    }

    /// Side-mask bits (mirrors PrefsStore scheme).
    static let sideLeftCmd: UInt32 = 1
    static let sideRightCmd: UInt32 = 2
    static let sideLeftOpt: UInt32 = 4
    static let sideRightOpt: UInt32 = 8
    static let sideFn: UInt32 = 16

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Physical sides currently held, refreshed from flagsChanged keycodes.
    /// Bits: leftCmd=1, rightCmd=2, leftOpt=4, rightOpt=8, fn=16,
    /// leftCtrl=32, rightCtrl=64, leftShift=128, rightShift=256.
    private(set) var sideMask: UInt32 = 0

    /// Optional first-pass consumer (panel key routing). Return true to consume.
    var interceptor: ((CGEvent) -> Bool)?

    /// Second-pass consumer for tap-level features the panel does not own:
    /// global number-switcher digits.
    /// Return true to consume.
    var rawKeyHandler: ((CGEvent, UInt32) -> Bool)?

    /// keyUp consumer (hold-vs-tap keys, e.g. hold Q to close a window).
    /// Return true to consume.
    var keyUpHandler: ((CGEvent) -> Bool)?

    /// Idempotent enable; used after consuming events, since WindowServer may
    /// disable an active tap after matched/consumed deliveries.
    private func poke() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private init() {}

    /// WindowServer silently disables active taps whose callbacks it deems slow;
    /// re-arming before synthetic/expected bursts restores delivery.
    func rearm() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Carbon modifier mask → CGEventFlags. Internal: the session builds
    /// multi-binding arrays with it.
    static func cgFlags(fromCarbon mask: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mask & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if mask & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if mask & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if mask & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }

    static let modifierBits: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]
    /// Public alias for callers matching modifier sets outside this file.
    static var modifierBitsPublic: CGEventFlags { modifierBits }

    /// CGEventFlags → Carbon modifier mask (inverse of cgFlags(fromCarbon:)).
    static func carbonFlags(fromCG flags: CGEventFlags) -> UInt32 {
        var mask: UInt32 = 0
        let f = flags.intersection(modifierBits)
        if f.contains(.maskControl) { mask |= UInt32(controlKey) }
        if f.contains(.maskAlternate) { mask |= UInt32(optionKey) }
        if f.contains(.maskCommand) { mask |= UInt32(cmdKey) }
        if f.contains(.maskShift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Carbon mask → the side-mask bits of every modifier it contains (both
    /// sides). Sessions compare this against the live side mask to detect the
    /// hold-to-switch trigger's release.
    static func sideBits(fromCarbon mask: UInt32) -> UInt32 {
        var bits: UInt32 = 0
        if mask & UInt32(cmdKey) != 0 { bits |= 0b11 }
        if mask & UInt32(optionKey) != 0 { bits |= 0b1100 }
        if mask & UInt32(controlKey) != 0 { bits |= 0b110_0000 }
        if mask & UInt32(shiftKey) != 0 { bits |= 0b11_0000_0000 }
        return bits
    }

    /// Modifier keycode → (flag reflecting that modifier's current state in the
    /// event, this key's side bit, both sides' bits of the same modifier).
    private static let sideKeycodes: [Int64: (flag: CGEventFlags, bit: UInt32, both: UInt32)] = [
        55: (.maskCommand, 1, 0b11),
        54: (.maskCommand, 2, 0b11),       // left/right Command
        58: (.maskAlternate, 4, 0b1100),
        61: (.maskAlternate, 8, 0b1100),   // left/right Option
        63: (.maskSecondaryFn, 16, 16),    // Function
        59: (.maskControl, 32, 0b110_0000),
        62: (.maskControl, 64, 0b110_0000), // left/right Control
        56: (.maskShift, 128, 0b11_0000_0000),
        60: (.maskShift, 256, 0b11_0000_0000), // left/right Shift
    ]

    /// Tear down the current tap (bindings live inside its closure, so a
    /// rebind needs a fresh tap). No-op when nothing registered.
    func unregister() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        bindings = []
    }

    @discardableResult
    func register(_ newBindings: [Binding]) -> Bool {
        guard !newBindings.isEmpty else { return false }
        unregister()
        bindings = newBindings

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask((1 << CGEventType.keyDown.rawValue)
                                          | (1 << CGEventType.keyUp.rawValue)
                                          | (1 << CGEventType.flagsChanged.rawValue)),
            callback: { _, type, event, _ in
                if TapLog.on {
                    TapLog.log("event type=\(type.rawValue) kc=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=0x\(String(event.flags.rawValue, radix: 16))")
                }
                if type == .flagsChanged {
                    HotkeyCenter.updateSides(event, into: HotkeyCenter.shared)
                    if TapLog.on { TapLog.log("sides → 0x\(String(HotkeyCenter.shared.sideMask, radix: 16))") }
                    HotkeyCenter.shared.flagsChangedHandler?(HotkeyCenter.shared.sideMask)
                    HotkeyCenter.shared.rearm()
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyUp {
                    // keyUps never reach bindings; only the hold-key consumer sees them.
                    if !HotkeyCenter.shared.suspended, HotkeyCenter.shared.keyUpHandler?(event) == true {
                        HotkeyCenter.shared.rearm()
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }
                return HotkeyCenter.shared.dispatch(event)
            },
            userInfo: nil
        ) else { return false }

        let src = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = src
        return true
    }

    /// Compatibility shim for the single-binding callers.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        register([Binding(id: "main", keyCode: keyCode,
                          mods: Self.cgFlags(fromCarbon: modifiers),
                          handler: { _ in handler() })])
    }

    /// While the prefs window records a combo, dispatch passes every keyDown
    /// through untouched: the recorder's local monitor needs the event, and a
    /// recorded combo matching a live trigger would otherwise be consumed (or
    /// open the panel) before it ever reached the recorder.
    var suspended = false

    private func dispatch(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        defer { poke() }
        if TapLog.on {
            TapLog.log("dispatch kc=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=0x\(String(event.flags.rawValue, radix: 16))")
        }
        if suspended { return Unmanaged.passUnretained(event) }
        if interceptor?(event) == true {
            if TapLog.on { TapLog.log("dispatch → interceptor consumed") }
            return nil
        } // consume

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Exact binding match (modifiers must equal the registered set).
        if let b = bindings.first(where: {
            $0.keyCode == keyCode && $0.mods == event.flags.intersection(Self.modifierBits)
        }) {
            if TapLog.on { TapLog.log("dispatch → binding hit id=\(b.id)") }
            b.handler(event)
            return nil // consume
        }

        // Tap-level extras: number switcher digits.
        if rawKeyHandler?(event, sideMask) == true {
            if TapLog.on { TapLog.log("dispatch → rawKeyHandler consumed") }
            return nil
        }

        if TapLog.on { TapLog.log("dispatch → passthrough") }
        return Unmanaged.passUnretained(event)
    }

    /// Fired after every flagsChanged with the fresh side mask. Sessions use
    /// it for hold-to-switch semantics: the trigger combo's release commits.
    var flagsChangedHandler: ((UInt32) -> Void)?

    private static func updateSides(_ event: CGEvent, into center: HotkeyCenter) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard let side = sideKeycodes[kc] else { return }
        if event.flags.intersection(side.flag).isEmpty {
            // Modifier's flag is gone: EVERY side of it is up. Authoritative
            // even when the matching physical keyUp was swallowed (synthetic
            // events, keyState lag), so a stuck side bit can never pin the
            // hold-session open. Holding the other side is impossible here —
            // one event reflects one modifier's whole state.
            center.sideMask &= ~side.both
        } else {
            // The event's own flag is the only authority for press: keyState
            // misses synthetic and just-landed modifier presses.
            center.sideMask |= side.bit
        }
    }
}

/// Env-gated tap tracing (AT_DEBUG=1): timestamped event-level trace for
/// diagnosing lost, delayed, or disabled tap deliveries. Zero cost otherwise.
enum TapLog {
    static let on = ProcessInfo.processInfo.environment["AT_DEBUG"] != nil
    static func log(_ s: @autoclosure () -> String) {
        guard on else { return }
        let t = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        print(String(format: "[tap %08.3f] %@", t.truncatingRemainder(dividingBy: 1000), s()))
    }
}
