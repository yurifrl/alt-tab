import AppKit
import CoreGraphics

/// Gesture switch (Phase 6): a two-finger "double touch"
/// (second finger lands while one is already down, then both lift) cycles
/// windows. Uses the private MultitouchSupport framework — the same private
/// API surface used (`MTDeviceCreateList`, `MTRegisterContactFrameCallback`).
///
/// Contacts semantics: each MTTouch has `state` (touch-start bitmask) and
/// `frame` (0-based contact ordinal in the current gesture frame).
final class GestureSwitch {
    static let shared = GestureSwitch()

    var handler: (() -> Void)?

    private var deviceRefs: [UnsafeMutableRawPointer] = []
    private var installed = false
    private var downContact = -1          // contact id of the first finger
    private var sawSecond = false
    private var armed = true              // re-arm only after both fingers lift

    private init() {}

    /// Installs callbacks on every attached multitouch device.
    /// Returns the number of devices observed (0 on desktops without trackpads).
    @discardableResult
    func start() -> Int {
        guard !installed else { return deviceRefs.count }
        installed = true
        deviceRefs = Self.copyDevices()
        for dev in deviceRefs {
            _ = MTDeviceStart(dev)
            _ = MTRegisterContactFrameCallback(dev, { _, data, _, _, refcon in
                GestureSwitch.shared.consume(data, refcon: refcon)
                return 0
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        return deviceRefs.count
    }

    private func consume(_ data: UnsafeMutableRawPointer?, refcon: UnsafeMutableRawPointer?) {
        guard let data, eventMask.contains(.gestureSwitch) else { return }
        let frame = data.bindMemory(to: MTTouchFrame.self, capacity: 1).pointee
        let touches = UnsafeBufferPointer(start: frame.touches.0, count: Int(frame.contacts))

        for t in touches {
            if t.state.contains(.touchStarted) {
                if downContact < 0 {
                    downContact = Int(t.frame)          // finger one
                } else if armed, Int(t.frame) != downContact {
                    // Second finger lands while armed → double-touch switch.
                    armed = false
                    sawSecond = true
                    DispatchQueue.main.async { GestureSwitch.shared.handler?() }
                }
            }
            if t.state.contains(.touchEnded) {
                if Int(t.frame) == downContact {
                    downContact = -1
                } else if sawSecond {
                    sawSecond = false
                }
                if downContact < 0 && !sawSecond && !armed {
                    // All gesture fingers lifted → re-arm after a debounce.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        if self?.downContact ?? 0 < 0 || self?.downContact == -1 { self?.armed = true }
                    }
                }
            }
        }
    }

    private static func copyDevices() -> [UnsafeMutableRawPointer] {
        let list = MTDeviceCreateList()
        let count = list.map { CFArrayGetCount($0) } ?? 0
        guard let list, count > 0 else { return [] }
        // `list` is an ARC-managed CFArray; device pointers are independent CF objects.
        var refs: [UnsafeMutableRawPointer] = []
        refs.reserveCapacity(count)
        for i in 0..<count {
            let dev = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: UnsafeMutableRawPointer.self)
            refs.append(dev)
        }
        return refs
    }
}

// MARK: - MultitouchSupport (private framework, dlopen — no SDK headers)

private let eventMask: MTEventMask = [.touchStarted, .touchEnded, .gestureSwitch]

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> CFArray?

@_silgen_name("MTDeviceStart")
private func MTDeviceStart(_ device: UnsafeMutableRawPointer!) -> Int32

@_silgen_name("MTDeviceStop")
private func MTDeviceStop(_ device: UnsafeMutableRawPointer!) -> Int32

@_silgen_name("MTRegisterContactFrameCallback")
private func MTRegisterContactFrameCallback(
    _ device: UnsafeMutableRawPointer!, _ callback: @convention(c) (
        _ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?,
        _ timestamp: Double, _ frame: Int32, _ refcon: UnsafeMutableRawPointer?
    ) -> Int32, _ refcon: UnsafeMutableRawPointer?) -> Int32

private struct MTPoint { var x, y: Float32 }
private struct MTSize { var width, height: Float32 }
private struct MTVector { var x, y: Float32 }

private struct MTTouch {
    var frame: Int16            // contact ordinal within the frame
    var inRange: UInt8
    var state: MTTouchState
    var size: MTSize
    var zero: MTPoint
    var pos: MTPoint            // normalized 0..1
    var velocity: MTVector
    var deviceID: Int16
}

private struct MTTouchState: OptionSet {
    var rawValue: UInt32
    static let touchStarted = MTTouchState(rawValue: 1 << 0)
    static let touchMoved   = MTTouchState(rawValue: 1 << 1)
    static let touchEnded   = MTTouchState(rawValue: 1 << 4)
}

private struct MTEventMask: OptionSet {
    var rawValue: UInt32
    static let touchStarted  = MTEventMask(rawValue: 1 << 0)
    static let touchEnded    = MTEventMask(rawValue: 1 << 4)
    static let gestureSwitch = MTEventMask(rawValue: 1 << 16)
}

private struct MTTouchFrame {
    var frame: Int32            // frame counter
    var timestamp: Double
    var contacts: Int32         // number of touches in this frame
    var touches: (UnsafeMutablePointer<MTTouch>?, UnsafeMutablePointer<MTTouch>?)
    var deviceID: Int16
    var frameVendor: Int32
    var unknown: (UInt8, UInt8, UInt8, UInt8)
}
