import AppKit

/// Always-on per-screen window lists (Contexts Sidebar parity, Phase 6).
/// One borderless non-activating panel per NSScreen listing that screen's
/// windows; refreshes from WindowTracker changes.
final class SidebarController {
    static let shared = SidebarController()
    private(set) var listCount: Int = 0
    private final class ScreenList {
        let panel: NSPanel
        let stack: NSStackView
        let effect: NSVisualEffectView
        let screenFrame: NSRect

        init(screenFrame: NSRect) {
            self.screenFrame = screenFrame
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            effect = NSVisualEffectView(frame: panel.frame)
            effect.material = PrefsStore.appearance(for: PrefsStore.theme).material
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            panel.contentView = effect
            NSLayoutConstraint.activate([
                effect.widthAnchor.constraint(equalToConstant: 240),
                effect.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -10),
            ])
        }

        func update(_ windows: [WindowModel]) {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (i, wm) in windows.prefix(9).enumerated() {
                let prefix = PrefsStore.sidebarsNumbers || PrefsStore.numberShowOnSidebar
                    ? "\(i + 1)  " : ""
                let label = NSTextField(labelWithString: "\(prefix) \(wm.title)")
                label.font = .systemFont(ofSize: 12)
                if PrefsStore.sidebarsNumbers || PrefsStore.numberShowOnSidebar {
                    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                }
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(label)
            }
            let target = NSRect(x: screenFrame.maxX - 250, y: screenFrame.midY - 120,
                                width: 240, height: min(280, CGFloat(max(windows.count, 1) * 22 + 20)))
            panel.setFrame(target, display: false)
        }

        func applyTheme() {
            effect.material = PrefsStore.appearance(for: PrefsStore.theme).material
        }

        func orderFront() { panel.orderFrontRegardless() }
        func orderOut() { panel.orderOut(nil) }
    }

    private var lists: [ScreenList] = []
    private var observation: (() -> Void)?

    /// Re-skins open lists after a theme change (prefs live-apply).
    func applyTheme() {
        lists.forEach { $0.applyTheme() }
    }

    /// Re-applies grouping/number/windowless prefs to live lists.
    func refreshForPrefs() { refresh() }

    func enable() {
        guard lists.isEmpty else { return }
        for screen in NSScreen.screens {
            let list = ScreenList(screenFrame: screen.visibleFrame)
            lists.append(list)
        }
        listCount = lists.count
        observation = { [weak self] in self?.refresh() }
        WindowTracker.shared.addChangeHandler("sidebar", observation!)
        WindowTracker.shared.refresh(reason: "sidebar")
        refresh()
    }

    func disable() {
        lists.forEach { $0.orderOut() }
        lists.removeAll()
        listCount = 0
        WindowTracker.shared.removeChangeHandler("sidebar")
        observation = nil
    }

    private func refresh() {
        guard !lists.isEmpty else { return }
        let all = WindowTracker.shared.windows
        let windowless = PrefsStore.sidebarsWindowless ? all.filter { $0.windowless } : []
        let rows = all.filter { !$0.windowless } + windowless
        let screens = NSScreen.screens
        switch PrefsStore.grouping {
        case .oneGroup:
            // One list on the primary screen holds everything.
            lists[0].update(rows)
            for list in lists.dropFirst() { list.update([]) }
        case .manually:
            // Split rows across N configured groups, one list per screen slot.
            let n = max(1, PrefsStore.groupCount)
            let per = (rows.count + n - 1) / max(1, min(n, lists.count))
            var start = 0
            for (i, list) in lists.enumerated() {
                guard i < n else { list.update([]); continue }
                let chunk = rows.dropFirst(start).prefix(per)
                start += per
                list.update(Array(chunk))
            }
        case .bySpace:
            for (i, list) in lists.enumerated() {
                guard i < screens.count else { break }
                let screen = screens[i]
                let onScreen = rows.filter { screen.frame.intersects($0.frame) }
                list.update(onScreen)
            }
        }
        lists.forEach { $0.orderFront() }
    }

    var geometry: [(screen: CGRect, windows: Int)] {
        get {
            let screens = NSScreen.screens
            return lists.enumerated().map { i, _ in
                let onScreen = screens.indices.contains(i)
                    ? WindowTracker.shared.windows.filter { screens[i].frame.intersects($0.frame) }.count
                    : 0
                return (screens.indices.contains(i) ? screens[i].visibleFrame : .zero, onScreen)
            }
        }
    }
}
