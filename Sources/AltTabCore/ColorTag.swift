import AppKit

/// Per-window color tags (Window rules → color): palette + hex helpers and
/// the swatch strip shown under the row while renaming (hold E).
enum ColorTag {
    /// Hex strings, in swatch order (digit N picks palette[N-1]; 0 = none).
    static let palette = ["#ef4444", "#f97316", "#eab308", "#34d399",
                          "#06b6d4", "#3b82f6", "#a855f7", "#ec4899"]

    static func color(_ hex: String?) -> NSColor? {
        guard var h = hex, !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Row of color dots: "none" + palette. Purely visual; the session routes keys.
final class SwatchStripView: NSView {
    static let size = NSSize(width: 9 * 30 + 24, height: 44)
    /// 0 = none, 1...8 = palette, nil = custom color (nothing highlighted).
    var selected: Int? = 0 { didSet { needsDisplay = true } }
    /// Keyboard focus is on the strip (⇥ toggled) — brighter ring + hint.
    var focused = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.78).setFill(); bg.fill()
        NSColor.white.withAlphaComponent(focused ? 0.45 : 0.16).setStroke(); bg.lineWidth = 1; bg.stroke()
        for i in 0...ColorTag.palette.count {
            let c = NSPoint(x: 24 + CGFloat(i) * 30, y: bounds.midY + 5)
            let r = NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)
            if i == 0 {
                NSColor.white.withAlphaComponent(0.5).setStroke()
                let o = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                o.lineWidth = 1.2; o.setLineDash([3, 3], count: 2, phase: 0); o.stroke()
                let l = NSBezierPath()
                l.move(to: NSPoint(x: r.minX + 4, y: r.minY + 4)); l.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 4))
                l.lineWidth = 1.2; l.stroke()
            } else {
                ColorTag.color(ColorTag.palette[i - 1])?.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            if selected == i {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -4, dy: -4))
                ring.lineWidth = 2; ring.stroke()
            }
        }
        let hint = (focused ? "←/→ or 0–8 · ⇥ name" : "⇥ color") as NSString
        hint.draw(at: NSPoint(x: 14, y: 4), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
    }
}
