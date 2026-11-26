/-
  Select-letter walk (see ../../specs/001-select-letter-walk/README.md, rules SL-2/SL-3/SL-10) modeled as
  a Lean 4 state machine.

  state: letters — the displayed rows' select letters, in displayed order — and
         sel     — the selection index.
  event: pressing letter `c`.

  Proved below:
    SL-10      a step lands strictly below `sel`: forward only, no wrap
    SL-2/SL-3  with no carrier below `sel`, a repeat press yields no step — the
               app falls back to its normal path (type into the search)
-/

structure WalkState where
  letters : List Char
  sel : Nat

/-- Indices of the rows whose select letter is `c`, in displayed order. -/
def carriers (letters : List Char) (c : Char) : List Nat :=
  (letters.zipIdx.filter (·.1 == c)).map (·.2)

/-- The step a repeat press takes: the first carrier strictly below `sel`. -/
def nextCarrier (s : WalkState) (c : Char) : Option Nat :=
  (carriers s.letters c).find? (· > s.sel)

/-- SL-10 (no wrap): any step lands strictly below the current selection, so the
walk can never reach a carrier at or above `sel`. -/
theorem walk_strictly_down (s : WalkState) (c : Char) {i : Nat}
    (h : nextCarrier s c = some i) : i > s.sel := by
  simpa [nextCarrier] using List.find?_some h

/-- SL-2/SL-3 (fallback): when no carrier sits below the selection, the repeat
press yields no step, so the app's normal path (type into the search) runs. -/
theorem walk_exhausted (s : WalkState) (c : Char)
    (h : ∀ i ∈ carriers s.letters c, i ≤ s.sel) : nextCarrier s c = none := by
  unfold nextCarrier
  have step : ∀ l : List Nat, (∀ i ∈ l, i ≤ s.sel) → List.find? (· > s.sel) l = none := by
    intro l
    induction l with
    | nil => intro _; rfl
    | cons x xs ih =>
        intro hx
        have hxn : ¬ (x > s.sel) := Nat.not_lt.mpr (hx x (by simp))
        have hrest : List.find? (· > s.sel) xs = none :=
          ih (fun i hi => hx i (by simp [hi]))
        simp [List.find?, hxn, hrest]
  exact step (carriers s.letters c) h

#print axioms walk_strictly_down
#print axioms walk_exhausted
