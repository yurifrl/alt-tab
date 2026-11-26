# Select-letter walk — spec

Status: draft for review (2026-11-25). Rule IDs (`SL-#`) are stable: acceptance
checks, the differential fuzzer and mutation reports all cite them.

> One sentence: press a letter — it types; press the same letter again — it jumps
> to the next window whose name starts with that letter; when none are left
> below, it types again.

## 1. Scope

**In scope:** what a letter press does in the open switcher panel (type-to-search),
and what repeating it does.

**Out of scope / explicitly unchanged:** ranking, activation/commit, rendering
(including that a row's hint shows its select letter), and the hold-key actions
themselves (close / minimize / hide / quit / rename).

## 2. Terms

| Term | Meaning |
|---|---|
| Displayed rows | The panel's current rows in displayed order — the exact list and indices selection uses (all screens flattened; ignored rows sink to the bottom). |
| Select letter (of a row) | First letter of the row's displayed name (alias if set, else app name), lowercased. Rows whose name has no letters have none. The letter a row's hint gutter shows is this letter. |
| Carrier | A displayed row whose select letter equals the pressed letter. |
| Letter press | Key-down of an ANSI letter key (a–z, base letter; Shift/Caps fine) that the panel routes to type-to-search — today's eligibility rule, unchanged (the trigger's own ⌘ or ⌥ hold is fine; ⌃, or ⌘+⌥ together, routes elsewhere). Auto-repeat is *not* a letter press (SL-7). |
| Repeat press | A letter press whose immediately preceding panel event was a letter press of the same letter. Any other panel action in between ends the sequence (SL-5). |
| Normal path | Unchanged behavior: the typed character appends to the search, rows re-rank, the first row becomes selected. |
| Step | Move the selection to the first carrier strictly below the current selection, in displayed order. Query, order and windows untouched. |

## 3. Rules

| ID | Rule |
|---|---|
| SL-1 | A letter press that is not a repeat press follows the normal path — identical to this feature not existing. |
| SL-2 | A repeat press steps **iff** (a) the displayed rows hold **≥ 2 carriers** and (b) **≥ 1 carrier sits strictly below** the current selection. |
| SL-3 | Every other repeat press follows the normal path and nothing else — the *fallback*: the letter types, rows re-rank, the first row becomes selected. |
| SL-4 | A step changes the selection and nothing else: no query change, no re-rank, no window action, no tracker refresh. |
| SL-5 | Consecutive only. Any panel action between presses ends the sequence — selection moves (arrows, digits, hover, scroll, trigger cycling), deletion (backspace with a non-empty query), typing a space, a hold-key action firing (close / minimize / hide / quit / rename opens), panel open, panel close. The next letter press is then a first press (SL-1). |
| SL-6 | The fallback keeps the sequence alive: the letter typed by SL-3 counts as the last letter press, so pressing it again is a repeat press again — judged against the rows and selection as they are then. |
| SL-7 | Auto-repeat never steps and never touches the sequence: a key-down carrying the auto-repeat flag follows the normal path (types), exactly as before this feature. |
| SL-8 | Carriers are re-computed from the displayed rows at each press. Changes between presses (window closed, refresh landed, selection re-rendered) are simply the input to the next press — nothing is remembered from earlier carrier sets. |
| SL-9 | One carrier is never a walk: SL-2(a) requires ≥ 2. With a lone carrier, repeats type (SL-3). |
| SL-10 | Forward only, no wrap: carriers at or above the current selection are never stepped to inside a walk. |
| SL-11 | The walk lives inside type-to-search only: with type-to-search off, or a key failing §2's eligibility rule, it is not a letter press and the sequence is untouched. |
| SL-12 | Invariants: (a) every press that is not a step is exactly the behavior without this feature; (b) a step does exactly SL-4. No other observable effect exists. |

## 4. Edge cases

| Situation | Behavior |
|---|---|
| No row's name starts with the letter | First press types (SL-1); repeats fall back (SL-3) — the letter simply types every time. |
| Exactly one carrier | Same: repeats type (SL-9). |
| Two carriers, selection now on the first | The repeat steps to the second (SL-2). |
| Selection at/below the last carrier | No carrier below → repeat types (SL-2b, SL-3). |
| Carriers exist only at/above the selection | Same — never revisited (SL-10). |
| Same app, several windows (same displayed name) | Each window is a carrier → the walk steps between the app's own windows. |
| Alias set ("Terminal" → "Work") | The select letter comes from the alias — the letter the hint gutter shows. |
| Name starts with a digit/symbol, or with a letter no a–z key produces ("Émile") | Never a carrier for any key. |
| Letter, then a different letter | The second letter is a first press for itself (SL-1); pressing it again steps *its* carriers. |
| Letter, backspace, letter | Backspace is an action → sequence dead; the later press is a first press (SL-5). |
| Letter, arrow, letter | Same (SL-5). |
| Letter, close panel, reopen, letter | Same — open/close clear (SL-5). |
| Rows re-render between presses (a window closed, a refresh landed) | The repeat judges the current rows/selection only (SL-8). |
| Held letter (auto-repeat) | Types repeatedly, never steps (SL-7). |
| Space after a walk | Types when the query is non-empty and ends the sequence (SL-5). |
| e/h/v/i/q with an empty query | The released tap is a letter press like any other (FLAG-2): it types, and a repeat walks. |

## 5. How this gets validated

- **V1 — acceptance, rule-mapped.** New `swift run AltTabCore spec` mode: one
  assertion group per `SL-#` citing the ID, using the existing session test
  hooks (`openForTest`, `pressForTest`, `panelRows`, `panelSelection`,
  `panelQuery`). Any violation: the failing rule ID + a non-zero exit.
- **V2 — differential checking (model as oracle).** Same mode: a small
  reference implementation of §2–§3 fed the same inputs as the live session.
  Two layers: **(a) bounded exhaustive** — every input sequence up to length N
  over a small synthetic row set is enumerated (explicit-state model checking:
  the walk's state is only rows × selection × query × last letter, so the
  reachable space is tiny); **(b) random** — longer sequences against the live
  rows, for the end-to-end smoke case. On any divergence: the minimal key
  sequence and the rule it breaks.
- **V3 — mutation subagents (hand-applied, no tooling).** Each applies one
  deliberate break from a catalogue — re-add the wrap; relax ≥ 2 to ≥ 1;
  swallow the fallback's append; drop a reset; off-by-one the below-scan; let
  auto-repeat step; make a step change the query — rebuilds, runs V1 + V2,
  restores the file, and reports killed / survivors. A survivor is a hole:
  closed by adding the missing check or the missing rule.
- **V4 — independent validator subagent.** Runs V1–V3 and additionally reads
  live behavior traces, reporting every observed transition that is (a) not
  covered by a rule or (b) contradicts one — validating the *spec*, not just
  the tests.

## 6. Implementation deltas (applied 2026-11-25, `Sources/AltTabCore/SwitcherPanel.swift`)

| Rule | Delta |
|---|---|
| SL-2 / SL-3 / SL-10 | `nextIndexForHint` (:508-512): drop the `?? matching[0]` wrap so exhaustion returns nil. `cycleToNextRow` (:1594-1599) and `letterPressed` (:1584-1591) already fall through to the normal path. Fix the stale "wrapping" doc comments. |
| SL-5 | Sequence is currently cleared only on open (:857), close (:1121) and backspace (:1208). Add the clear on the other panel actions (selection moves, window actions, space) — preferably one choke point, not scattered lines. |
| SL-7 | Letter branch (:1279-1283): on the auto-repeat flag, append + `applyQuery()` directly — skip the walk and the sequence. |
| SL-6, SL-9 | Already implemented — `count > 1` guard (:510), fall-through (:1586). |
| FLAG-2 | `flushPendingE/V/H/I/Q`: route the released letter through the letter path instead of appending directly, so hold-key taps walk like every other letter. |

## 7. Flags — one decision each

Resolved: the shipped implementation takes every recommended option below (§6; the
`spec` mode asserts it).

1. **SL-7 auto-repeat:** *never steps* (recommended) | a held letter steps like
   repeated presses.
2. **Hold-key taps** (e/h/v/i/q, empty query): *route them through the walk so
   all letters behave identically* (recommended) | keep them outside the walk
   as a permanent, documented exception.
3. **SL-5 breadth:** *any panel action ends the sequence* (recommended) |
   narrower: only another letter / open / close ends it; selection moves in
   between keep the walk alive.
