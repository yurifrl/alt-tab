---
sketch: 001
name: window-rule-matchers
question: "How should multiple title matchers — now including Regex — live inside the window rule form?"
winner: null
tags: [form, matchers, macos, regex]
---

# Sketch 001: Multiple matchers for a window rule

## Design Question
Today "Title matches" holds one `kind + pattern` row (Contains / Exact / Starts with /
Ends with). This sketch adds: a **+** that appends more matchers, per-row kind (plus
**Regex**), and an any/all combiner — inside the stock System Settings–style form.

## How to View
open .planning/sketches/001-window-rule-matchers/index.html

## Variants
- **A: Stacked rows** — plain form rows; "+ Add matcher" button under the last row;
  "Match [any ▾] of the following:" caption above.
- **B: Boxed list** — matchers grouped in a bordered well with its own footer
  ("+ Add matcher" inside the box).
- **C: Token chips** — rules as inline token chips in one wrapped box; click a chip's
  kind to change it; "+" adds a chip of the chosen kind; typing + Enter adds a
  Contains chip.

## What to Look For
- Density at 4+ matchers (B/C vs A)
- Regex affordance: row 2 is `Regex  ^PR #\d+`; type `[` into a Regex field to see the
  invalid state (red field + "Invalid regular expression")
- The count line is live: matched against 5 fake open windows, recomputed per keystroke,
  and honors any/all
- Where the any/all control lives and whether it reads naturally
- "+" stays a real add affordance in each direction

## Interactions Wired
- Kind popups open a menu (Contains / Exact / Starts with / Ends with / **Regex**);
  switching to Regex flips the field to monospace and enables validation
- `−` removes a row, `✕` removes a chip, `Enter` in the chip input adds one
- `any ▾` popup flips OR/AND combination; the "APPLIES TO" segments dim the matcher area
  for "This window" / "All windows"
