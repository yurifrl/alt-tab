# Spike Manifest

## Ideas

### lean-formal-verification
Whether any part of this project should be carried by formal methods (Lean 4 / TLA+
class), and what that workflow actually looks like here in practice. Trigger: Boris
Cherny's Lean + TLA+ verification of the Claude Agent SDK (2026-09) — how far does the
"a couple of prompts" story compress today's formal-methods workflow? Explored
2026-11-25 with a live Lean 4 toolchain in a sandbox, modeling the select-letter walk
(`SELECT-LETTER-SPEC.md`).

**Requirements:**
- Spike artifacts are knowledge, not product: nothing here wires into `Package.swift`,
  the app build, or CI. The app's verification authority stays the `spec` run mode
  (rule-mapped checks + bounded-exhaustive enumeration + reference model).
- Any formal model kept in the repo lives in this spike folder and must be
  `sorry`-free by `#print axioms` (no `sorryAx`) — or explicitly labeled a gap —
  and reproducible from its README with a sandboxed toolchain that is removed
  afterwards.

## Spikes

| # | Idea | Name | Type | Validates | Verdict | Tags |
|---|------|------|------|-----------|---------|------|
| 001 | lean-formal-verification | lean-select-letter-walk | standard | Given the walk's core rules (SL-2/SL-3/SL-10), when modeled as a Lean 4 state machine, then it compiles sorry-free and a warnings-as-errors gate fails on any gap | VALIDATED | lean, formal-verification, tla+, select-letter-walk |
