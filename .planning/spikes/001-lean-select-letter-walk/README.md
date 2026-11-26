---
spike: "001"
idea: lean-formal-verification
name: lean-select-letter-walk
type: standard
validates: "Given the select-letter walk's core rules (SL-2/SL-3/SL-10), when modeled as a Lean 4 state machine, then the model compiles sorry-free and a warnings-as-errors gate turns any gap into a failure"
verdict: VALIDATED
related: []
tags: [lean, formal-verification, tla+, select-letter-walk]
---

# Spike 001: Lean 4 model of the select-letter walk

## What This Validates

Given the walk's core rules (`SL-2`, `SL-3`, `SL-10` in
[SELECT-LETTER-SPEC.md](../../../SELECT-LETTER-SPEC.md)), when modeled as a Lean 4
state machine, then `Walk.lean` compiles with both theorems proved and `#print axioms`
reports no `sorryAx`.

This is a feasibility/fact spike: it answers "what does the Lean/TLA+ workflow look
like in practice here, and is it worth anything for this codebase" with a real
artifact rather than an opinion.

## Research

| Approach | Tool | Pros | Cons | Status |
|---|---|---|---|---|
| Deductive proof assistant | Lean 4 (+ elan) | One curl + one toolchain (~200 MB, 46 s here); proofs are machine-checked statements; no JVM; no libraries needed for this model | Proof scripts are their own skill; a failed proof silently degrades to `sorryAx` unless gated | **Chosen — implemented** |
| Model checker | TLA+ (+ TLC) | Enumerates a system's interleavings natively — the natural tool for concurrency / state management | Needs a JVM — none on this machine (only the macOS stub); heavier for a 40-line model | Not used |

Choices: Lean for the artifact (zero-dependency install, statements instead of traces);
TLA+ stays the right tool when a *system's* interleavings are the question. The walk's
state space is tiny, so its enumeration happens in the app's `spec` run mode instead
(SELECT-LETTER-SPEC.md §5) — the two approaches are complementary, not competing.

## How to Run

Everything lives under `$ELAN_HOME` (no `$HOME` writes), and the toolchain is removed
after the check:

```bash
# 1. Sandbox toolchain (~200 MB download; a minute or two)
export ELAN_HOME=/private/tmp/alt-tab-lean-check
mkdir -p "$ELAN_HOME" && cd "$ELAN_HOME"
curl -sSf https://elan.lean-lang.org/elan-init.sh | sh -s -- -y --default-toolchain leanprover/lean4:stable

# 2. Check the model (from this folder)
cd /Users/yuri/Workdir/Yuri/alt-tab/.planning/spikes/001-lean-select-letter-walk
"$ELAN_HOME/bin/lean" Walk.lean
# zero-sorry gate: any gap (`sorry`) becomes an error
"$ELAN_HOME/bin/lean" -DwarningAsError=true Walk.lean

# 3. Remove the toolchain
rm -rf "$ELAN_HOME"
```

## What to Expect

```
'walk_strictly_down' depends on axioms: [propext]
'walk_exhausted' depends on axioms: [propext, Quot.sound]
```

Both runs exit 0. `propext` / `Quot.sound` are Lean's stock kernel axioms — their
presence is normal; `sorryAx` (the silent-gap axiom) must **not** appear. A file with a
single unproved step fails the `-DwarningAsError=true` run with
`declaration uses 'sorry'` and a non-zero exit.

## Investigation Trail

1. **Toolchain** — `leanprover/lean4:stable` (v4.36.0) installed via elan into
   `/private/tmp`, 46 s including download, ~3.1 GB unpacked. No JVM on the machine,
   so TLA+/TLC was not installable without adding one.
2. **First proof attempt** (`walk_strictly_down` with `exact List.find?_some h`) —
   failed: `find?_some` yields `decide (i > s.sel) = true`, not `i > s.sel`. Worse,
   `#print axioms` then reported `[sorryAx]` for **both** theorems: a failed proof
   degrades silently to the sorry axiom; only `#print axioms` / warnings-as-errors
   reveal it. Fix: `simpa [nextCarrier] using List.find?_some h`.
3. **Second proof attempt** (`walk_exhausted`) — direct induction on the goal produced
   `simp made no progress` and applied a non-function `ih` (wrong induction motive: the
   hypothesis must generalize with the list). Fix: prove a general
   `have step : ∀ l, (∀ i ∈ l, i ≤ s.sel) → List.find? (· > s.sel) l = none` first,
   then apply it to `carriers`.
4. **Final** — both theorems green; axioms `[propext]` / `[propext, Quot.sound]`; gate
   exits 0; a probe file carrying one `sorry` exits non-zero under the gate (so the
   all-clear means something).
5. **Cleanup** — sandbox deleted (~3.1 GB); no `~/.elan`, no shell-rc edits.
6. **Re-verify against the saved artifact** — whole flow re-run from a clean sandbox:
   `plain_exit=0`, `gate_exit=0`, `probe_gate_exit=1`, sandbox removed, no `~/.elan`,
   no shell-rc edits.

## Results

**Verdict: VALIDATED** — the workflow works end to end, is cheap to reproduce, and the
artifact is a machine-checked statement about the walk.

Findings:

- The proof loop is real (two genuine failures → fixes), but both failures were
  proof-script mechanics, not model insight. The model is 40 lines and states rules the
  spec had already fixed — the compiler found nothing spec review had not.
- The transferable mechanism is the **gate**: `#print axioms` +
  `-DwarningAsError=true` turn "I think it is proved" into a machine check, and catch
  the silent degradation of failed proofs to `sorryAx`.
- Scale judgment for this repo: the walk's state space is combinatorially tiny, so
  bounded-exhaustive enumeration (the `spec` run mode's V2 layer) is the higher-yield
  verification. Lean buys reviewable statements, not bug yield at this scale.
- What this does **not** give: validation that the rules are the right rules — a proof
  only verifies its own model. That part stays with spec review and the independent
  validator.
- The model is not wired to the app. If a rule changes, `Walk.lean`,
  `SELECT-LETTER-SPEC.md` and the `spec` mode must be updated together (the model cites
  SL ids).
