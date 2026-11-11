import Foundation

/// Single-line text model behind the hold-R rename: caret, "all selected"
/// state, kill/word operations and undo/redo. Pure value type (no UI).
struct RenameEditor {
    private(set) var text: String
    private(set) var caret: Int
    /// Whole text selected (just entered edit mode, or ⌘A): typing replaces it.
    private(set) var allSelected: Bool
    private var undoStack: [(String, Int)] = []
    private var redoStack: [(String, Int)] = []

    init(_ text: String) {
        self.text = text
        caret = text.count
        allSelected = true
    }

    private var chars: [Character] { Array(text) }

    private mutating func checkpoint() {
        undoStack.append((text, caret))
        if undoStack.count > 64 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private mutating func set(_ c: [Character], caret: Int) {
        text = String(c)
        self.caret = max(0, min(caret, c.count))
        allSelected = false
    }

    /// Typing / paste: replaces the selection, else inserts at the caret.
    mutating func insert(_ s: String, maxLength: Int) {
        let clean = s.filter { !$0.isNewline }
        guard !clean.isEmpty else { return }
        checkpoint()
        var c = allSelected ? [] : chars
        let at = allSelected ? 0 : caret
        let room = max(0, maxLength - c.count)
        let add = Array(clean.prefix(room))
        c.insert(contentsOf: add, at: at)
        set(c, caret: at + add.count)
    }

    mutating func deleteBackward() {
        if allSelected { checkpoint(); set([], caret: 0); return }
        guard caret > 0 else { return }
        checkpoint()
        var c = chars; c.remove(at: caret - 1)
        set(c, caret: caret - 1)
    }

    mutating func deleteForward() {
        if allSelected { checkpoint(); set([], caret: 0); return }
        guard caret < text.count else { return }
        checkpoint()
        var c = chars; c.remove(at: caret)
        set(c, caret: caret)
    }

    mutating func killToEnd() {
        if allSelected { checkpoint(); set([], caret: 0); return }
        guard caret < text.count else { return }
        checkpoint()
        set(Array(chars[..<caret]), caret: caret)
    }

    mutating func killToStart() {
        if allSelected { checkpoint(); set([], caret: 0); return }
        guard caret > 0 else { return }
        checkpoint()
        set(Array(chars[caret...]), caret: 0)
    }

    mutating func deleteWordBackward() {
        if allSelected { checkpoint(); set([], caret: 0); return }
        let start = wordStart(before: caret)
        guard start < caret else { return }
        checkpoint()
        var c = chars; c.removeSubrange(start..<caret)
        set(c, caret: start)
    }

    mutating func deleteWordForward() {
        if allSelected { checkpoint(); set([], caret: 0); return }
        let end = wordEnd(after: caret)
        guard end > caret else { return }
        checkpoint()
        var c = chars; c.removeSubrange(caret..<end)
        set(c, caret: caret)
    }

    mutating func moveToStart() { caret = 0; allSelected = false }
    mutating func moveToEnd() { caret = text.count; allSelected = false }
    mutating func moveLeft() { caret = allSelected ? 0 : max(0, caret - 1); allSelected = false }
    mutating func moveRight() { caret = allSelected ? text.count : min(text.count, caret + 1); allSelected = false }
    mutating func moveWordLeft() { caret = allSelected ? 0 : wordStart(before: caret); allSelected = false }
    mutating func moveWordRight() { caret = allSelected ? text.count : wordEnd(after: caret); allSelected = false }
    mutating func selectAll() { allSelected = !text.isEmpty }

    mutating func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append((text, caret))
        text = prev.0; caret = prev.1; allSelected = false
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((text, caret))
        text = next.0; caret = next.1; allSelected = false
    }

    private func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private func wordStart(before i: Int) -> Int {
        let c = chars
        var p = i
        while p > 0, !isWord(c[p - 1]) { p -= 1 }
        while p > 0, isWord(c[p - 1]) { p -= 1 }
        return p
    }

    private func wordEnd(after i: Int) -> Int {
        let c = chars
        var p = i
        while p < c.count, !isWord(c[p]) { p += 1 }
        while p < c.count, isWord(c[p]) { p += 1 }
        return p
    }

    /// Label text with a caret glyph at the caret (omitted while all selected).
    var display: String {
        guard !allSelected else { return text }
        let c = chars
        return String(c[..<caret]) + "\u{258F}" + String(c[caret...])
    }
}
