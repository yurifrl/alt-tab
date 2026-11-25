---
sketch: 002
name: match-attributes-debug
question: "How do match attributes (title, id, …) and a collapsible debug view of open windows live inside the rule form?"
winner: null
tags: [form, matchers, attributes, debug, marquee, macos]
---

# Sketch 002: Match attributes & the debug view

## Design Question
The app shipped the boxed matcher list (`MatchersEditor.swift`): `Match [any|all] of the
following:` — one row per condition (kind popup + pattern + remove), `+ Add matcher`,
and a live count line. This sketch replaces the kind-only popup with **kind + attribute**
and pairs the list with a view of the open windows, where every value it shows (title,
id, app, bundle id, pid) is clickable and lands in the rule's **focused row**. The
questions: where does that view live, and how do attribute + kind read in each row?

## How to View
open .planning/sketches/002-match-attributes-debug/index.html
(opens on D; the A/B/C/D tabs switch variants — `?v=a`…`?v=d` and `#a`…`#d` deep-link)

## Variants
- **A: Inline disclosure** — "More details" under the matcher list expands a chip list of
  the 8 open windows (title, id, app, bundle id, pid, flags). Clicking a chip fills the
  focused row.
- **B: Popover inspector** — the matcher header carries a **Debug** button that opens a
  floating card with the same windows as title + linked values; its body scrolls at 340px
  so the card always fits the window; the form stays minimal.
- **C: Bottom drawer** — a full-width **MORE DETAILS** bar at the bottom of the pane opens
  a four-column table (Title / ID / App / PID, bundle + flags on the sub-line). The bar is
  its own toggle and stays visible when collapsed.
- **D: Under the selector (review pick)** — fixed-height 266px table directly under the
  matcher list, scrolling when the list outgrows it; overflowing titles run a marquee and
  show the full text in a hover tooltip; the `com.…` sub-line is clickable (Bundle ID).

## Screenshots
`variant-a.png` / `variant-a-open.png` (chip clicked → Window ID row), `variant-b.png` /
`variant-b-open.png` (linked value clicked), `variant-c.png` / `variant-c-open.png`,
`variant-d.png` (open), `variant-d-hover.png` (full-title tooltip), `variant-d-closed.png`,
`db-zoom.png` (D table detail).

## What to Look For
- Attribute-first reading order — does `[Title ▾] [Contains ▾] pattern` read better than
  kind-first for a row that can now filter more than titles?
- Kind popup adapts per attribute: text kinds vs numeric kinds (Is / Is not)
- `any ▾` / `all ▾` flips OR/AND over the rows; `+ Add matcher` appends; `−` removes
  (one row minimum); the outlined row is the click target for values
- Click targets: chip vs linked value vs table cell vs `com.…` sub-line — is "click a
  value to build the rule" obvious without a caption? (D carries a caption row)
- D: the box keeps its size while 8 windows scroll inside; titles that clip marquee back
  and forth, pause on hover, and show the full text in the tooltip
- B: the card scrolls its body instead of outgrowing the window
- Flag chips (fullscreen, minimized) are context only, not matchable yet
- Count line, ✓ marks and the hit-row tint are live against 8 fake windows; the preview
  row follows the first hit

## Interactions Wired
- Editor: `any ▾`/`all ▾`, per-row `[attribute ▾] [kind ▾] [pattern] [−]`, `+ Add matcher`;
  clicking a row (or typing in it) focuses it
- Attribute menu: Title / Window ID / App name / Bundle ID / PID — numeric attributes
  (Window ID, PID) re-seed the kind list to Is / Is not and validate numbers
- Kind menu opens per attribute; Regex flips the field to monospace and validates on input
- Toggles: A's "More details" link; B's Debug button and the popover ✕; C's MORE DETAILS
  bar; D's "More details" link collapses/expands the table
- Clicking any value (chip / linked value / table cell / `com.…` sub-line) sets the
  focused row's attribute + kind + pattern and flashes that row; matching rows are tinted
  with ✓ and the clicked value tinted blue (exact equality with the row's pattern)
- Invalid states: `[` in a Regex field → red field + message; letters in a Window ID or
  PID field → "Enter a number"
- "APPLIES TO" segments dim the editor and the windows view for "This window" /
  "All windows"; the count line switches to "Applies to …"

## D specifics
- 266px content box (+1px border), inner list scrolls (8 windows ≈ 319px of content)
- Marquee travel and duration measured per title on load (min 3s, max 9s), pauses on
  hover; clipped titles switch to `text-overflow: clip` while animating
- Caption row: `OPEN WINDOWS` + "click a value to use it in the rule"
