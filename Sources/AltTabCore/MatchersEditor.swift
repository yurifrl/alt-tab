import AppKit

/// The boxed condition editor of the Windows tab: "Match [any|all] of the
/// following:" over one row per condition ([attribute ▾][kind ▾][value][−]),
/// an "+ Add matcher" footer, and a live problem line under a bad value
/// (invalid regex, non-numeric id/pid).
///
/// The kinds a row offers follow its attribute: text attributes get
/// Contains / Exact / Starts with / Ends with / Regex, window id and pid get
/// Is / Is not. One row is focused (outlined); value clicks in the open-windows
/// table land there through `fillFocused(attribute:value:)`.
///
/// Every edit is reported through `onEdit`. The editor owns its UI state, so
/// owners push values back only via `load(matchers:matchAll:)` (which does not
/// report) — rewriting the fields while the user types would fight the first
/// responder.
final class MatcherListEditor: NSView, NSTextFieldDelegate {
    var onEdit: (([PrefsStore.Matcher], Bool) -> Void)?

    /// The live conditions (empty-text rows dropped) and the any/all switch.
    var current: ([PrefsStore.Matcher], Bool) { live() }

    private struct Row {
        let attr: NSPopUpButton
        let kind: NSPopUpButton
        let field: NSTextField
        let minus: NSButton
        let wrap: NSStackView
        let error: NSTextField
    }

    private var matchers: [PrefsStore.Matcher] = []
    private var rows: [Row] = []
    /// `load` runs while the owner repaints and must not report back.
    private var loading = false
    /// The row a value click lands in (outlined).
    private var focused = 0

    private let caption = NSTextField(labelWithString: "Match")
    private let modePopup = NSPopUpButton(frame: .zero)
    private let tailLabel = NSTextField(labelWithString: "of the following:")
    private let rowsStack = NSStackView()
    private let addButton = NSButton(title: "+ Add matcher", target: nil, action: nil)

    private static let attrWidth: CGFloat = 92
    private static let kindWidth: CGFloat = 96
    private static let minusWidth: CGFloat = 26
    /// Left inset of a row's error line: under its value field.
    private static let errorInset = attrWidth + kindWidth + 12

    // MARK: Build

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func live() -> ([PrefsStore.Matcher], Bool) {
        (matchers.filter { !$0.text.isEmpty }, modePopup.indexOfSelectedItem == 1)
    }

    private func build() {
        caption.font = .systemFont(ofSize: 13)
        caption.textColor = .secondaryLabelColor
        modePopup.addItems(withTitles: ["any", "all"])
        modePopup.controlSize = .small
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        modePopup.widthAnchor.constraint(equalToConstant: 66).isActive = true
        modePopup.setContentHuggingPriority(.required, for: .horizontal)
        tailLabel.font = .systemFont(ofSize: 13)
        tailLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [caption, modePopup, tailLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6

        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = .systemFont(ofSize: 11.5)
        addButton.target = self
        addButton.action = #selector(addPressed(_:))
        addButton.toolTip = "Add another condition to this rule"

        let footer = NSStackView(views: [addButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let box = NSStackView(views: [rowsStack, footer])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView(views: [header, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsStack.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -10),
        ])
    }

    // MARK: Public

    /// Owner → editor (no callback). Always keeps at least one row: "no
    /// conditions" is the "All windows" scope, not an empty box.
    func load(matchers: [PrefsStore.Matcher], matchAll: Bool) {
        loading = true
        self.matchers = matchers.isEmpty ? [PrefsStore.Matcher()] : matchers
        modePopup.selectItem(at: matchAll ? 1 : 0)
        for row in rows { row.wrap.superview?.removeFromSuperview() }
        rows = []
        focused = 0
        for m in self.matchers { addRowView(m) }
        updateMinus()
        updateFocus()
        loading = false
    }

    /// Drop a clicked value into the focused row, then hand that row the
    /// keyboard so typing continues where the click left off.
    func fillFocused(attribute: PrefsStore.Matcher.Attribute, value: String) {
        let kind: PrefsStore.Matcher.Kind = attribute.numeric ? .isExactly : .contains
        if matchers.isEmpty {
            matchers = [PrefsStore.Matcher(attribute: attribute, kind: kind, text: value)]
            addRowView(matchers[0])
            focused = 0
        } else {
            let i = max(0, min(focused, matchers.count - 1))
            matchers[i] = PrefsStore.Matcher(attribute: attribute, kind: kind, text: value)
            rows[i].field.stringValue = value
            applyAttribute(i)
            decorate(i)
            focused = i
        }
        updateMinus()
        updateFocus()
        let field = rows[max(0, min(focused, rows.count - 1))].field
        window?.makeFirstResponder(field)
        // The attached field editor owns the visible text, so a value dropped
        // into a row that is already being edited must be written through it
        // too (`stringValue` alone would leave the old text on screen).
        if let editor = field.currentEditor() {
            editor.string = value
            editor.selectedRange = NSRange(location: (value as NSString).length, length: 0)
        }
        emit()
    }

    /// Give the first condition's value field the keyboard (editing a rule).
    func focusFirstField() {
        focused = 0
        updateFocus()
        window?.makeFirstResponder(rows.first?.field)
    }

    // MARK: Rows

    private func addRowView(_ m: PrefsStore.Matcher) {
        let attr = NSPopUpButton(frame: .zero)
        attr.addItems(withTitles: PrefsStore.Matcher.Attribute.allCases.map(\.title))
        attr.controlSize = .small
        attr.font = .systemFont(ofSize: 12)
        attr.target = self
        attr.action = #selector(attrChanged(_:))
        attr.translatesAutoresizingMaskIntoConstraints = false
        attr.widthAnchor.constraint(equalToConstant: Self.attrWidth).isActive = true
        attr.toolTip = "What this condition looks at"

        let kind = NSPopUpButton(frame: .zero)
        kind.controlSize = .small
        kind.font = .systemFont(ofSize: 12)
        kind.target = self
        kind.action = #selector(kindChanged(_:))
        kind.translatesAutoresizingMaskIntoConstraints = false
        kind.widthAnchor.constraint(equalToConstant: Self.kindWidth).isActive = true
        kind.toolTip = "How the value is compared"

        let field = NSTextField(frame: .zero)
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12.5)
        field.placeholderString = m.attribute.placeholder
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let minus = NSButton(title: "−", target: self, action: #selector(removePressed(_:)))
        minus.bezelStyle = .rounded
        minus.controlSize = .small
        minus.font = .systemFont(ofSize: 12.5)
        minus.translatesAutoresizingMaskIntoConstraints = false
        minus.widthAnchor.constraint(equalToConstant: Self.minusWidth).isActive = true
        minus.toolTip = "Remove this condition"

        let wrap = NSStackView(views: [attr, kind, field, minus])
        wrap.orientation = .horizontal
        wrap.alignment = .centerY
        wrap.spacing = 6
        wrap.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 6

        let error = NSTextField(labelWithString: "")
        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.isHidden = true
        error.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSStackView(views: [wrap, error])
        holder.orientation = .vertical
        holder.alignment = .leading
        holder.spacing = 1
        holder.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.addArrangedSubview(holder)
        holder.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        error.leadingAnchor.constraint(equalTo: holder.leadingAnchor,
                                       constant: CGFloat(Self.errorInset)).isActive = true

        rows.append(Row(attr: attr, kind: kind, field: field, minus: minus, wrap: wrap, error: error))
        let i = rows.count - 1
        field.stringValue = m.text
        applyAttribute(i)
        decorate(i)
    }

    /// Re-seed a row's kind popup from its attribute and clamp the kind into
    /// that list (a string kind left on a numeric attribute matches nothing,
    /// so it is rewritten the moment the editor sees it).
    private func applyAttribute(_ i: Int) {
        guard i >= 0, i < rows.count else { return }
        let row = rows[i]
        row.attr.selectItem(at: PrefsStore.Matcher.Attribute.allCases
            .firstIndex(of: matchers[i].attribute) ?? 0)
        let kinds = PrefsStore.Matcher.Kind.list(for: matchers[i].attribute)
        if !kinds.contains(matchers[i].kind) { matchers[i].kind = kinds[0] }
        let titles = kinds.map(\.title)
        if row.kind.itemTitles != titles {
            row.kind.removeAllItems()
            row.kind.addItems(withTitles: titles)
        }
        row.kind.selectItem(at: kinds.firstIndex(of: matchers[i].kind) ?? 0)
    }

    /// Per-row look after any change: placeholder/mono per attribute+kind and
    /// the live problem line (red outline + message).
    private func decorate(_ i: Int) {
        guard i >= 0, i < rows.count else { return }
        let m = matchers[i]
        let row = rows[i]
        row.field.placeholderString = m.kind == .regex ? "Regular expression" : m.attribute.placeholder
        row.field.font = m.kind == .regex
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12.5)
        let problem = Self.problem(m)
        row.field.layer?.borderWidth = problem == nil ? 0 : 1.5
        row.field.layer?.borderColor = problem == nil ? nil : NSColor.systemRed.cgColor
        row.error.stringValue = problem ?? ""
        row.error.isHidden = problem == nil
    }

    /// The message under a value that cannot work, or nil.
    private static func problem(_ m: PrefsStore.Matcher) -> String? {
        if m.attribute.numeric {
            guard !m.text.isEmpty, Int64(m.text) == nil else { return nil }
            return "Enter a number, e.g. \(m.attribute == .windowId ? "74821" : "1183")"
        }
        if m.kind == .regex, !m.text.isEmpty, !PrefsStore.Matcher.isValidRegex(m.text) {
            return "Invalid regular expression"
        }
        return nil
    }

    /// Outline the row a value click would land in.
    private func updateFocus() {
        for (i, row) in rows.enumerated() {
            let on = i == focused
            row.wrap.layer?.borderWidth = on ? 1 : 0
            row.wrap.layer?.borderColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : nil
            row.wrap.layer?.backgroundColor = on
                ? NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func updateMinus() {
        let enabled = rows.count > 1
        for row in rows { row.minus.isEnabled = enabled }
    }

    private func emit() {
        guard !loading else { return }
        onEdit?(live().0, live().1)
    }

    // MARK: Actions

    @objc private func modeChanged(_ sender: Any?) { emit() }

    @objc private func attrChanged(_ sender: NSPopUpButton) {
        guard let i = rows.firstIndex(where: { $0.attr === sender }) else { return }
        matchers[i].attribute = PrefsStore.Matcher.Attribute.allCases[max(0, sender.indexOfSelectedItem)]
        focused = i
        applyAttribute(i)
        decorate(i)
        updateFocus()
        emit()
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        guard let i = rows.firstIndex(where: { $0.kind === sender }) else { return }
        let kinds = PrefsStore.Matcher.Kind.list(for: matchers[i].attribute)
        matchers[i].kind = kinds[max(0, min(sender.indexOfSelectedItem, kinds.count - 1))]
        focused = i
        decorate(i)
        updateFocus()
        emit()
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard rows.count > 1,
              let i = rows.firstIndex(where: { $0.minus === sender }) else { return }
        matchers.remove(at: i)
        rows[i].wrap.superview?.removeFromSuperview()
        rows.remove(at: i)
        focused = max(0, min(focused, rows.count - 1))
        updateMinus()
        updateFocus()
        emit()
    }

    @objc private func addPressed(_ sender: Any?) {
        matchers.append(PrefsStore.Matcher())
        addRowView(matchers[matchers.count - 1])
        focused = rows.count - 1
        updateMinus()
        updateFocus()
        window?.makeFirstResponder(rows.last?.field)
        emit()
    }

    // MARK: Field edits

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let i = rows.firstIndex(where: { $0.field === field }) else { return }
        focused = i
        updateFocus()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let i = rows.firstIndex(where: { $0.field === field }) else { return }
        matchers[i].text = field.stringValue
        decorate(i)
        emit()
    }
}
