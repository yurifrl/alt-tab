import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Select-letter walk spec mode (.planning/specs/001-select-letter-walk/README.md)

/// `swift run AltTabCore spec` — the spec's validation layers:
///
/// - V1 (@see spec §5): one assertion group per rule SL-1..SL-12, driven
///   through the production hooks. Every failure names the rule it breaks.
/// - V2 (@see spec §5): the differential oracle — a small reference model of
///   §2–§3 fed the same inputs as the live session, compared after every key:
///   (a) every input sequence up to length 3 over small synthetic row sets,
///   (b) longer random sequences against the live rows, and (c) the pure
///   decision exhaustively over carrier patterns × selection × pressed letter.
///   A divergence reports the minimal key sequence and the rules it breaks.
/// - V3 scoreboard: each break in the mutation catalogue (re-added wrap,
///   ≥2→≥1, swallowed append, dropped reset, off-by-one below-scan, stepping
///   auto-repeat, typing step) must diverge from the live session on some
///   sequence — a mutant that survives every sequence is reported as a hole.
///   The full V3 runs apply the breaks to the live file and rerun this mode.
///
/// Prints PASS or FAIL with the failing rules and exits non-zero on failure.
func runSpecDemo() {
    NSApplication.shared.setActivationPolicy(.accessory)
    var failures: [String] = []

    // The walk lives inside type-to-search (SL-11), so the run pins it and
    // restores the user's value at the end. In-panel action keys need no pin:
    // they never match a bare letter (their modifiers are non-zero), so routed
    // letters stay safe; the hold letters e/v/h/i/q are kept out of the routed
    // alphabets instead (an empty query routes them to their hold timers).
    let savedSearch = PrefsStore.typingStartsFastSearch
    PrefsStore.typingStartsFastSearch = true

    // Live row snapshot for V2b and the V1 live smoke (§5: "the live rows").
    // A bare refresh enumerates once (refresh is standalone; start() would
    // only add the AX/workspace observers and fire live refreshes into the
    // middle of replays); open() kicks one more, drained where it matters.
    WindowTracker.shared.refresh(reason: "spec harness")
    waitForTrackerModel(10)
    SwitcherSession.shared.openForTest()
    let liveRows = SwitcherSession.shared.panelRows
    let liveNames = liveRows.map(\.displayName)
    SwitcherSession.shared.close(commit: false)
    waitForModel({ false }, timeout: 0.3)

    var steps = 0
    specRunV1(&failures)

    // ── V2c [SL-2/SL-9/SL-10]: the pure decision, exhaustive.
    let pureCases = specRunPure(&failures)

    // ── V2a [SL-1..SL-12]: every sequence up to length 3 over small row sets.
    let setA: [SpecKey] = [.letter("a"), .letter("b"), .move(1), .backspace, .space]
    steps += specReplayFamily(rows: ["a0", "b0", "a1"], alphabet: setA, upTo: 3,
                              label: "V2a(3 rows)", failures: &failures)
    let setB: [SpecKey] = [.letter("a"), .backspace, .move(1), .autoRepeat("a")]
    steps += specReplayFamily(rows: ["a0", "a1"], alphabet: setB, upTo: 3,
                              label: "V2a(2 rows)", failures: &failures)

    // ── V2b [end-to-end]: longer random sequences against the live rows.
    // Hold letters (e/v/h/i/q) stay out of the routed alphabet: their
    // key-downs arm hold timers with an empty query, and V1 covers their taps.
    if liveNames.isEmpty {
        print("spec: V2b skipped — no live rows")
    } else {
        var rng = SpecRNG(seed: 0x5EED_2026)
        let carrierLetters = Set(liveNames.compactMap(specQuickGoLetter)).sorted()
        let routable = carrierLetters.filter { !"evhiq".contains($0) }
        var alphabet = routable.map { SpecKey.letter($0) }
        alphabet += [.space, .backspace, .move(1), .move(-1)]
        if liveNames.count >= 2 { alphabet.append(.digit(1)) }
        if let held = routable.first { alphabet.append(.autoRepeat(held)) }
        for round in 0..<6 {
            let keys = (0..<40).map { _ in alphabet[rng.int(alphabet.count)] }
            steps += specReplay(rows: liveNames, keys: keys, label: "V2b r\(round)",
                                failures: &failures)
        }
        print("spec: V2b 6 rounds × 40 keys on \(liveNames.count) live rows, \(carrierLetters.count) carriers")
    }

    let mutants = specRunScoreboard()
    var killed = 0
    for (name, sequence) in mutants {
        if let sequence {
            killed += 1
            print("spec: V3 mutant \"\(name)\" killed by \(sequence)")
        } else {
            failures.append("V3: mutant \"\(name)\" survived every sequence — the suite has a hole")
        }
    }

    SwitcherSession.shared.specClose()
    PrefsStore.typingStartsFastSearch = savedSearch

    print("spec: V1 12 rules; V2 \(pureCases) pure cases, \(steps) steps exercised, V3 \(killed)/\(mutants.count) mutants killed")
    let head = failures.prefix(12).joined(separator: "; ")
    print(failures.isEmpty ? "PASS"
          : "FAIL: \(head)\(failures.count > 12 ? " … (+\(failures.count - 12) more)" : "")")
    exit(failures.isEmpty ? 0 : 1)
}

// MARK: - V1 — acceptance, rule-mapped

/// One assertion group per rule. Every message names its rule ids.
private func specRunV1(_ failures: inout [String]) {
    let s = SwitcherSession.shared

    // SL-1/SL-2/SL-4/SL-6/SL-10 — the scripted walk: three carriers.
    s.specOpen(specRows(["a0", "a1", "a2"]))
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "a" && s.panelSelection == 0 && s.panelLastSelectLetter == "a",
               "V1 [SL-1]", "first press did not type/select the top (query \"\(s.panelQuery)\" sel \(s.panelSelection) seq \(specName(s.panelLastSelectLetter)))")
    s.pressForTest("a")
    specExpect(&failures, s.panelSelection == 1 && s.panelQuery == "a",
               "V1 [SL-2]", "repeat did not step to the first carrier below (sel \(s.panelSelection) query \"\(s.panelQuery)\")")
    let orderAfterStep = s.panelRows.map(\.displayName)
    s.pressForTest("a")
    specExpect(&failures, s.panelSelection == 2 && s.panelQuery == "a",
               "V1 [SL-2]", "second repeat did not step (sel \(s.panelSelection))")
    specExpect(&failures, s.panelRows.map(\.displayName) == orderAfterStep,
               "V1 [SL-4]", "a step re-ranked the rows")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0 && s.panelLastSelectLetter == "a",
               "V1 [SL-3/SL-10]", "no carrier below: repeat did not fall back to typing (query \"\(s.panelQuery)\" sel \(s.panelSelection))")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 1,
               "V1 [SL-6]", "the fallback did not keep the sequence alive (query \"\(s.panelQuery)\" sel \(s.panelSelection))")

    // SL-2/SL-8 — carriers re-ordered by the typed query; the step follows the
    // displayed order, judged on the current rows.
    s.specOpen(specRows(["a0", "b0", "a1", "a2"]))
    s.pressForTest("a")
    s.pressForTest("a")
    specExpect(&failures, s.panelRows.indices.contains(s.panelSelection) &&
               s.panelRows[s.panelSelection].title == "t-a1",
               "V1 [SL-2/SL-8]", "step did not land on the first carrier in displayed order (sel \(s.panelSelection))")
    s.specSetRows(specRows(["a0", "b0", "a1", "a2", "a3"]))
    s.pressForTest("a")
    specExpect(&failures, s.panelRows.indices.contains(s.panelSelection) &&
               s.panelRows[s.panelSelection].title == "t-a2" && s.panelQuery == "a",
               "V1 [SL-8]", "repeat did not judge the re-rendered carrier set (sel \(s.panelSelection) query \"\(s.panelQuery)\")")

    // SL-9 — one carrier is never a walk; none at all types every time (§4).
    s.specOpen(specRows(["a0", "b0"]))
    s.pressForTest("a")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0,
               "V1 [SL-9]", "lone carrier: repeat did not type (query \"\(s.panelQuery)\" sel \(s.panelSelection))")
    s.specOpen(specRows(["b0", "b1"]))
    s.pressForTest("a")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0,
               "V1 [SL-9/§4]", "no carrier: repeat did not type (query \"\(s.panelQuery)\" sel \(s.panelSelection))")

    // SL-10 — carriers at/above the selection are never revisited: at the last
    // carrier the repeat types instead of wrapping back.
    s.specOpen(specRows(["b0", "a1", "a2"]))
    s.pressForTest("a")
    let firstCarrier = s.panelSelection
    s.pressForTest("a")
    let secondCarrier = s.panelSelection
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0 && firstCarrier < secondCarrier,
               "V1 [SL-10]", "repeat wrapped instead of typing at the last carrier (query \"\(s.panelQuery)\" sel \(s.panelSelection))")

    // SL-5 — an arrow between presses ends the sequence.
    s.specOpen(specRows(["a0", "a1"]))
    s.pressForTest("a")
    s.pressForTest("a")                      // step to 1
    s.moveSelectionForTest(1)                // wraps to 0 and ends the sequence
    specExpect(&failures, s.panelLastSelectLetter == nil && s.panelSelection == 0,
               "V1 [SL-5]", "selection move did not end the sequence (sel \(s.panelSelection) seq \(specName(s.panelLastSelectLetter)))")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0,
               "V1 [SL-5]", "the press after a move was not a first press (query \"\(s.panelQuery)\" sel \(s.panelSelection))")

    // SL-5 — a digit between presses ends the sequence.
    s.specOpen(specRows(["a0", "a1", "a2"]))
    s.pressForTest("a")
    let digitHandled = s.routeKeyEventForTest(specDigitEvent(1))
    specExpect(&failures, digitHandled && s.panelSelection == 1 && s.panelLastSelectLetter == nil,
               "V1 [SL-5]", "digit did not select its row and end the sequence (handled \(digitHandled) sel \(s.panelSelection))")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0,
               "V1 [SL-5]", "the press after a digit was not a first press (query \"\(s.panelQuery)\" sel \(s.panelSelection))")

    // SL-5/§4 — backspace: an action that kills the sequence; the next press
    // starts a fresh one.
    s.specOpen(specRows(["a0", "a1"]))
    s.pressForTest("a")
    let deleted = s.backspaceForTest()
    specExpect(&failures, deleted && s.panelQuery == "" && s.panelLastSelectLetter == nil,
               "V1 [SL-5]", "backspace did not delete and end the sequence (deleted \(deleted))")
    s.pressForTest("a")
    s.pressForTest("a")
    specExpect(&failures, s.panelSelection == 1 && s.panelQuery == "a",
               "V1 [SL-5]", "the sequence did not restart after backspace (sel \(s.panelSelection) query \"\(s.panelQuery)\")")

    // SL-5/§4 — space after a walk: types (non-empty query) and ends it.
    s.specOpen(specRows(["a0", "a1"]))
    s.pressForTest("a")
    let spaced = s.spaceForTest()
    specExpect(&failures, spaced && s.panelQuery == "a " && s.panelLastSelectLetter == nil,
               "V1 [SL-5]", "space did not type/end the sequence (typed \(spaced) query \"\(s.panelQuery)\")")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "a a" && s.panelSelection == 0,
               "V1 [SL-5]", "the press after a space was not a first press (query \"\(s.panelQuery)\" sel \(s.panelSelection))")

    // SL-5/§4 — space and backspace with an empty query change nothing.
    s.specOpen(specRows(["a0", "a1"]))
    let noSpace = s.spaceForTest()
    let noDelete = s.backspaceForTest()
    specExpect(&failures, !noSpace && !noDelete && s.panelQuery == "" &&
               s.panelSelection == 0 && s.panelLastSelectLetter == nil,
               "V1 [SL-5/§4]", "space/backspace with an empty query changed the panel (space \(noSpace) delete \(noDelete))")

    // SL-5 — a panel open and close end the sequence.
    s.specOpen(specRows(["a0", "a1"]))
    s.pressForTest("a")
    s.specClose()
    s.specOpen(specRows(["a0", "a1"]))
    specExpect(&failures, s.panelQuery == "" && s.panelSelection == 0 && s.panelLastSelectLetter == nil,
               "V1 [SL-5]", "reopen did not clear the sequence (query \"\(s.panelQuery)\" seq \(specName(s.panelLastSelectLetter)))")
    s.pressForTest("a")
    specExpect(&failures, s.panelQuery == "a" && s.panelLastSelectLetter == "a",
               "V1 [SL-1]", "the press after a reopen was not a first press (query \"\(s.panelQuery)\")")

    // SL-7 — auto-repeat types, never steps, never touches the sequence.
    s.specOpen(specRows(["a0", "a1"]))
    s.autoRepeatForTest("a")
    specExpect(&failures, s.panelQuery == "a" && s.panelSelection == 0 && s.panelLastSelectLetter == nil,
               "V1 [SL-7]", "held key did not type without touching the sequence (query \"\(s.panelQuery)\" seq \(specName(s.panelLastSelectLetter)))")
    s.specOpen(specRows(["a0", "a1"]))
    s.pressForTest("a")
    s.autoRepeatForTest("a")
    specExpect(&failures, s.panelQuery == "aa" && s.panelSelection == 0 && s.panelLastSelectLetter == "a",
               "V1 [SL-7]", "held key stepped or disturbed the sequence (query \"\(s.panelQuery)\" sel \(s.panelSelection) seq \(specName(s.panelLastSelectLetter)))")
    s.pressForTest("a")
    specExpect(&failures, s.panelSelection == 1 && s.panelQuery == "aa",
               "V1 [SL-7]", "the sequence did not survive the held key (sel \(s.panelSelection) query \"\(s.panelQuery)\")")

    // SL-11 — §2 eligibility: ⌃, or ⌘+⌥ together, route elsewhere; the
    // sequence is untouched.
    for (flags, eligible) in [(CGEventFlags.maskControl, false),
                              ([.maskCommand, .maskAlternate], false),
                              (CGEventFlags.maskCommand, true)] {
        s.specOpen(specRows(["a0", "a1"]))
        let handled = s.routeKeyEventForTest(specKeyEvent("a", flags: flags))
        specExpect(&failures, handled == eligible && s.panelQuery == (eligible ? "a" : "") &&
                   s.panelLastSelectLetter == (eligible ? "a" : nil),
                   "V1 [SL-11]", "flags \(flags.rawValue): handled \(handled) ≠ \(eligible) (query \"\(s.panelQuery)\")")
    }

    // SL-11 — with type-to-search off a letter is not a letter press.
    let on = PrefsStore.typingStartsFastSearch
    PrefsStore.typingStartsFastSearch = false
    s.specOpen(specRows(["a0", "a1"]))
    let offHandled = s.routeKeyEventForTest(specKeyEvent("a"))
    specExpect(&failures, !offHandled && s.panelQuery == "" && s.panelLastSelectLetter == nil,
               "V1 [SL-11]", "letter with type-to-search off was consumed (handled \(offHandled))")
    PrefsStore.typingStartsFastSearch = on

    // §4 — the select letter is the alias, and a digit-led name with letters
    // still carries its first letter (§2); a name without letters never does.
    s.specOpen([specRow("Terminal", alias: "Work"), specRow("TextEdit", alias: "Words"), specRow("Terminal2")])
    s.pressForTest("w")
    s.pressForTest("w")
    specExpect(&failures, s.panelRows.indices.contains(s.panelSelection) &&
               s.panelRows[s.panelSelection].displayName == "Words",
               "V1 [§4 alias]", "step did not follow the alias letters (sel \(s.panelSelection))")
    s.specOpen([specRow("Terminal", alias: "Work"), specRow("Terminal2")])
    s.pressForTest("t")
    s.pressForTest("t")
    specExpect(&failures, s.panelQuery == "tt" && s.panelSelection == 0,
               "V1 [§4 alias]", "an alias row acted as a carrier for its real name (query \"\(s.panelQuery)\" sel \(s.panelSelection))")
    s.specOpen(specRows(["Émile", "e0", "e1", "42"]))
    s.pressForTest("e")
    s.pressForTest("e")
    specExpect(&failures, s.panelRows.indices.contains(s.panelSelection) &&
               s.panelRows[s.panelSelection].title == "t-e1",
               "V1 [§4 Émile/42]", "a non-keyable or letterless name was stepped to (sel \(s.panelSelection))")

    // §4 — the same app several times: every window is a carrier.
    s.specOpen(specRows(["Safari", "Safari", "Safari"]))
    s.pressForTest("s")
    s.pressForTest("s")
    let second = s.panelSelection
    s.pressForTest("s")
    specExpect(&failures, second == 1 && s.panelSelection == 2 && s.panelQuery == "s",
               "V1 [§4 same app]", "the walk did not step between an app's own windows (\(second)→\(s.panelSelection))")

    // §5 V1 uses the existing session hooks on the live rows, end to end.
    s.specClose()
    s.openForTest()
    // Drain the open's queued sweeps first (SL-8: a refresh landing between
    // presses is input to the next press, not an action) so the walk below
    // runs against a settled model.
    waitForModel({ false }, timeout: 0.3)
    let rows = s.panelRows
    let dup = Dictionary(grouping: rows.indices, by: { rows[$0].displayName.quickGoLetter })
        .filter { $0.key != nil && $0.value.count > 1 }
    if let (key, _) = dup.first, let letter = key {
        s.pressForTest(letter)                    // first press: types, selects the top (SL-1)
        let typedQuery = s.panelQuery
        specExpect(&failures, typedQuery == String(letter),
                   "V1 [SL-1]", "live first press did not type (query \"\(typedQuery)\")")
        // SL-8: live refreshes may add or drop carriers between presses, so
        // the walk follows the panel's current rows instead of a precomputed
        // carrier list — only the invariants hold: every step moves strictly
        // forward (SL-10: never back or around) and, with no carrier left
        // below, a press types again (SL-3, the fallback).
        var last = s.panelSelection
        var steps = 0
        var typed = false
        for _ in 0..<max(3 * rows.count, 12) {
            s.pressForTest(letter)
            if s.panelQuery != typedQuery { typed = true; break }   // SL-3: the fallback types
            if s.panelSelection <= last { break }                   // a wrap (SL-10) or a stall
            steps += 1
            last = s.panelSelection
        }
        specExpect(&failures, steps >= 1 && typed && s.panelQuery == typedQuery + String(letter),
                   "V1 [SL-2/SL-3/SL-8/SL-10]", "live walk did not step forward and stop by typing (steps \(steps) typed \(typed) query \"\(s.panelQuery)\")")
        print("spec: V1 live smoke — letter \"\(letter)\", \(steps) step(s), \(rows.count) live rows")
    } else {
        print("spec: V1 live smoke skipped — no letter carried by 2+ live rows")
    }
    if SwitcherSession.shared.isOpen { SwitcherSession.shared.close(commit: false) }
}

// MARK: - V2 — differential oracle

/// Every sequence up to `maxLen` over `alphabet`, shortest first (V2a).
private func specSequences(_ alphabet: [SpecKey], upTo maxLen: Int) -> [[SpecKey]] {
    var all: [[SpecKey]] = []
    var level: [[SpecKey]] = [[]]
    for _ in 1...maxLen {
        level = level.flatMap { seq in alphabet.map { seq + [$0] } }
        all.append(contentsOf: level)
    }
    return all
}

/// Replays every V2a sequence against one row set; reports the first five of
/// each family. Returns the number of steps taken (lesson: 0 means the family
/// never exercised the walk).
private func specReplayFamily(rows: [String], alphabet: [SpecKey], upTo: Int,
                              label: String, failures: inout [String]) -> Int {
    var steps = 0
    var reported = 0
    for keys in specSequences(alphabet, upTo: upTo) {
        var scratch: [String] = []
        steps += specReplay(rows: rows, keys: keys, label: label, failures: &scratch)
        for failure in scratch {
            if reported < 5 { failures.append(failure) }
            reported += 1
        }
    }
    if reported > 5 { failures.append("\(label): \(reported - 5) more divergences") }
    return steps
}

/// Applies one key to the live session, then to the model, comparing the whole
/// observable state (spec 001 §5 V2). Returns the steps taken.
@discardableResult
private func specReplay(rows names: [String], keys: [SpecKey], label: String,
                        variant: SpecModel.Variant = .correct,
                        failures: inout [String]) -> Int {
    let s = SwitcherSession.shared
    s.specOpen(specRows(names))
    var model = SpecModel(rows: names, variant: variant)
    var prefix: [String] = []
    for key in keys {
        prefix.append(key.name)
        specApplyLive(key)
        specApplyModel(key, &model)
        if let bad = specStateDiff(model) {
            failures.append("\(label): \(prefix.joined(separator: " ")) — \(bad)")
            return model.steps
        }
    }
    return model.steps
}

/// The live side of V2: routed through the production gate where the key is a
/// router key — letters and auto-repeat through `routeKey` (SL-11), space and
/// backspace through their production branches (SL-5/§4), digits through the
/// digit branch, the move through `panel.moveSelection` (the arrow path).
private func specApplyLive(_ key: SpecKey) {
    let s = SwitcherSession.shared
    switch key {
    case .letter(let ch):     _ = s.routeKeyEventForTest(specKeyEvent(ch))
    case .autoRepeat(let ch): _ = s.routeKeyEventForTest(specKeyEvent(ch, autoRepeat: true))
    case .space:              _ = s.routeKeyEventForTest(specSpaceEvent())
    case .backspace:          _ = s.routeKeyEventForTest(specDeleteEvent())
    case .move(let delta):    s.moveSelectionForTest(delta)
    case .digit(let index):   _ = s.routeKeyEventForTest(specDigitEvent(index))
    }
}

/// The model side of V2.
private func specApplyModel(_ key: SpecKey, _ model: inout SpecModel) {
    switch key {
    case .letter(let ch):     model.press(ch)
    case .autoRepeat(let ch): model.autoRepeat(ch)
    case .space:              model.space()
    case .backspace:          model.backspace()
    case .move(let delta):    model.move(delta)
    case .digit(let index):   model.digit(index)
    }
}

/// The observable state after a key: selection, query, sequence and displayed
/// rows. Returns nil when live and model agree (SL-12).
private func specStateDiff(_ model: SpecModel) -> String? {
    let s = SwitcherSession.shared
    if s.panelQuery != model.query {
        return "query \"\(s.panelQuery)\" ≠ model \"\(model.query)\" (SL-1/SL-3/SL-4/SL-7/SL-12)"
    }
    if s.panelSelection != model.selection {
        return "selection \(s.panelSelection) ≠ model \(model.selection) (SL-2/SL-3/SL-4/SL-5/SL-10/SL-12)"
    }
    if s.panelLastSelectLetter != model.lastLetter {
        return "sequence \(specName(s.panelLastSelectLetter)) ≠ model \(specName(model.lastLetter)) (SL-5/SL-6/SL-7/SL-12)"
    }
    let shown = s.panelRows.map(\.displayName)
    if shown != model.shown {
        return "displayed rows \(shown) ≠ model \(model.shown) (SL-8/SL-12)"
    }
    return nil
}

/// A reference model of §§2–3 (spec 001 §5 V2): the walk's whole
/// state is rows × displayed order × selection × query × last letter. Fed the
/// same keys as the live session; `variant` switches in one catalogue break
/// for the V3 scoreboard.
private struct SpecModel {
    enum Variant: CaseIterable {
        case correct, reWrap, relaxToOne, swallowAppend, dropReset, offByOne,
             autoRepeatSteps, stepTyped
    }

    var rows: [String]
    var shown: [String]
    var selection = 0
    var query = ""
    var lastLetter: Character?
    private let variant: Variant
    /// Steps taken — evidence the sequences exercise the walk.
    private(set) var steps = 0

    init(rows: [String], variant: Variant = .correct) {
        self.rows = rows
        self.shown = rows
        self.variant = variant
    }

    mutating func rank() { shown = specRankNames(rows, query: query) }

    /// The normal path (§2): append, re-rank, the first row becomes selected.
    mutating func type(_ text: String, letter: Character?, keepSequence: Bool = false) {
        if variant != .swallowAppend { query += text }
        if !keepSequence { lastLetter = letter }
        rank()
        if variant == .dropReset { return }
        selection = 0
    }

    /// A letter press: a repeat press (SL-6) steps (SL-2), everything else
    /// types (SL-1/SL-3) — including a repeat press with no step left.
    mutating func press(_ l: Character) {
        rank()
        if l == lastLetter {
            let carriers = shown.indices.filter { specQuickGoLetter(shown[$0]) == l }
            let enough = variant == .relaxToOne ? carriers.count >= 1 : carriers.count >= 2
            if enough {
                let offset = variant == .offByOne ? 1 : 0
                if let next = carriers.first(where: { $0 > selection + offset }) {
                    selection = next
                    steps += 1
                    if variant == .stepTyped { query += String(l) }   // catalogue: a step that types
                    return
                }
                if variant == .reWrap, let first = carriers.first {   // catalogue: the old wrap
                    selection = first
                    return
                }
            }
        }
        type(String(l), letter: l)
    }

    /// SL-7: a held key types and never touches the sequence.
    mutating func autoRepeat(_ l: Character) {
        if variant == .autoRepeatSteps { press(l); return }       // catalogue: a held key steps
        type(String(l), letter: l, keepSequence: true)
    }

    /// SL-5/§4: space types (and ends the sequence) only when the query is
    /// non-empty; otherwise nothing changes.
    mutating func space() {
        guard !query.isEmpty else { return }
        type(" ", letter: nil)
    }

    /// SL-5/§4: backspace deletes (and ends the sequence) only when the query
    /// is non-empty; the emptied query re-ranks to the full row set.
    mutating func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        lastLetter = nil
        rank()
        selection = 0
    }

    /// SL-5: any real selection move (arrows, hover, scroll, cycling) ends the
    /// sequence; a move that cannot change the selection does not.
    mutating func move(_ delta: Int) {
        rank()
        guard !shown.isEmpty else { return }
        let next = (selection + delta + shown.count) % shown.count
        if next != selection { lastLetter = nil }
        selection = next
    }

    /// SL-5: a digit selects its row and ends the sequence; out of range it is
    /// swallowed and changes nothing.
    mutating func digit(_ index: Int) {
        rank()
        guard index < shown.count else { return }
        if index != selection { lastLetter = nil }
        selection = index
    }
}

/// §2 reference for the pure decision: step only with ≥ 2 carriers and one
/// strictly below the selection.
private func specReferenceStep(_ letters: [Character?], _ selection: Int, _ pressed: Character) -> Int? {
    let carriers = letters.indices.filter { letters[$0] == pressed }
    guard carriers.count >= 2 else { return nil }
    return carriers.first { $0 > selection }
}

/// V2c: the pure decision, exhaustively over 4-row carrier patterns (a, b, no
/// letter) × selection 0...4 × pressed a/b, against the §2 reference; and no
/// step may ever land at or above the selection (SL-10). Returns the cases run.
private func specRunPure(_ failures: inout [String]) -> Int {
    var cases = 0
    var bad: [String] = []
    for code in 0..<81 {
        var letters: [Character?] = []
        var rest = code
        for _ in 0..<4 { letters.append(["a", "b", nil][rest % 3].map(Character.init)); rest /= 3 }
        for selection in 0...4 {
            for pressed in "ab" {
                cases += 1
                let reference = specReferenceStep(letters, selection, pressed)
                let live = SwitcherPanelController.selectLetterStep(letters: letters, selection: selection, pressed: pressed)
                if live != reference {
                    if bad.count < 5 {
                        bad.append("V2c [SL-2/SL-9]: \(specLetters(letters)) sel \(selection) press \(pressed) — \(live.map(String.init) ?? "nil") ≠ reference \(reference.map(String.init) ?? "nil")")
                    }
                } else if let step = live, step <= selection {
                    if bad.count < 5 {
                        bad.append("V2c [SL-10]: step to \(step) at/above selection \(selection) (\(specLetters(letters)))")
                    }
                }
            }
        }
    }
    failures.append(contentsOf: bad)
    print("spec: V2c \(cases) pure cases (patterns × selection × letter)")
    return cases
}

/// V3 scoreboard: replays the catalogue breaks through the model and requires
/// each to diverge somewhere. Returns (mutant, killing sequence).
private func specRunScoreboard() -> [(String, String?)] {
    let catalogue: [(SpecModel.Variant, String)] = [
        (.reWrap, "re-added wrap [SL-2/SL-3/SL-10]"),
        (.relaxToOne, "≥2 relaxed to ≥1 [SL-2]"),
        (.swallowAppend, "fallback append swallowed [SL-1/SL-3]"),
        (.dropReset, "reset dropped [SL-5/SL-6]"),
        (.offByOne, "below-scan off by one [SL-4/SL-10]"),
        (.autoRepeatSteps, "auto-repeat steps [SL-7]"),
        (.stepTyped, "step types [SL-2/SL-4]"),
    ]
    let alphabet: [SpecKey] = [.letter("a"), .letter("b"), .backspace, .move(1), .autoRepeat("a")]
    let rowSets = [["a0", "a1"], ["a0", "b1"], ["a0", "b0", "a1"]]
    var results: [(String, String?)] = []
    for (variant, name) in catalogue {
        var killing: String?
        outer: for rows in rowSets {
            for keys in specSequences(alphabet, upTo: 3) {
                var scratch: [String] = []
                _ = specReplay(rows: rows, keys: keys, label: "V3", variant: variant, failures: &scratch)
                if !scratch.isEmpty {
                    killing = "\(rows.joined(separator: ",")) | \(keys.map(\.name).joined(separator: " "))"
                    break outer
                }
            }
        }
        results.append((name, killing))
    }
    return results
}

// MARK: - Keys

private enum SpecKey {
    case letter(Character)
    case autoRepeat(Character)
    case space
    case backspace
    case move(Int)
    case digit(Int)

    var name: String {
        switch self {
        case .letter(let ch):     return String(ch)
        case .autoRepeat(let ch): return "\(ch)~"
        case .space:              return "␣"
        case .backspace:          return "⌫"
        case .move(let delta):    return delta < 0 ? "↑" : "↓"
        case .digit(let index):   return String(index + 1)
        }
    }
}

/// ANSI keycodes for the letters (the inverse of the production
/// `SwitcherSession.letterKeycodes` — that table is private to the session).
private let specLetterKeyCodes: [Character: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
    "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
    "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
]

/// kVK_ANSI_1..9 → selection index (the inverse of the production
/// `SwitcherSession.digitKeycodes`).
private let specDigitKeyCodes: [Int: CGKeyCode] = [
    0: 18, 1: 19, 2: 20, 3: 21, 4: 23, 5: 22, 6: 26, 7: 28, 8: 25,
]

private func specKeyEvent(_ ch: Character, flags: CGEventFlags = [], autoRepeat: Bool = false) -> CGEvent? {
    guard let code = specLetterKeyCodes[ch],
          let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return nil }
    event.flags = flags
    if autoRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    return event
}

private func specSpaceEvent() -> CGEvent? {
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true)
}

private func specDeleteEvent() -> CGEvent? {
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)
}

private func specDigitEvent(_ index: Int) -> CGEvent? {
    guard let code = specDigitKeyCodes[index] else { return nil }
    return CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
}

// MARK: - Small helpers

/// A row every spec check can act on: no AX element, pid 0, empty bundle id —
/// window actions can run against it without touching anything real (§4).
private func specRow(_ name: String, alias: String? = nil) -> WindowModel {
    var wm = WindowModel(pid: 0, bundleId: "", appLocalName: name, title: "t-\(name)",
                         frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                         minimized: false, ax: nil)
    wm.alias = alias
    return wm
}

private func specRows(_ names: [String]) -> [WindowModel] { names.map { specRow($0) } }

/// §2 select letter: first letter of the displayed name, lowercased.
private func specQuickGoLetter(_ name: String) -> Character? {
    name.lowercased().first { $0.isLetter }
}

/// §2/§3 written as the harness's own ranking: for `specRow` rows this must
/// equal `SwitcherSession.specRank` (which the live side runs), so a mismatch
/// between the two implementations surfaces as a row-order divergence (SL-8).
private func specRankNames(_ names: [String], query: String) -> [String] {
    guard !query.isEmpty else { return names }
    let ranked = names.enumerated().map { (i: $0.offset, name: $0.element,
        score: max(SearchText.score(app: $0.element, title: "t-\($0.element)", query: query),
                   SearchText.score(app: $0.element, title: "", query: query))) }
    return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }.map(\.name)
}

private func specName(_ letter: Character?) -> String {
    letter.map { "\"\($0)\"" } ?? "nil"
}

private func specLetters(_ letters: [Character?]) -> String {
    letters.map { $0.map { String($0) } ?? "·" }.joined()
}

private func specExpect(_ failures: inout [String], _ ok: Bool, _ rule: String, _ what: String) {
    if !ok { failures.append("\(rule): \(what)") }
}

/// Tiny deterministic LCG (V2b): reproducibility over quality.
private struct SpecRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }

    mutating func int(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}
