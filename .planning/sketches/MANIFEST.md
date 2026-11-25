# Sketch Manifest

## Design Direction
Native macOS settings pane (AltTab → Windows tab). Widen the rule form from a single
title matcher to a list of matchers, each with its own kind (Contains, Exact, Starts with,
Ends with, new: Regex) and pattern, combined by any/all. Visual language stays stock
System Settings: small rounded fields, popups with blue chevrons, 13px SF text.

**002** goes one step further: the matcher becomes attribute-first (Title / Window ID /
App name / Bundle ID / PID), the kind list adapts per attribute, and a collapsible
**More details** section shows every open window's matchable values so a rule can be
built by clicking what you see. The boxed matcher list shipped in the app
(`MatchersEditor.swift`) — the sketch's editor now mirrors it (`Match [any|all] of the
following:` + `+ Add matcher`, values fill the focused row). Review feedback added **D**: the same table directly
under the selector row, fixed 266px, scrolling, with marquee titles + hover tooltip.

## Reference Points
- macOS System Settings form controls
- The app's own WindowRulesView (Sources/AltTabCore/WindowRulesView.swift)

## Sketches

| # | Name | Design Question | Winner | Tags |
|---|------|-----------------|--------|------|
| 001 | window-rule-matchers | How should multiple matchers (with Regex) live in the rule form? | B — boxed list (implemented) | form, matchers, macos, regex |
| 002 | match-attributes-debug | How do match attributes and a collapsible debug view of open windows live in the rule form? | — | form, attributes, debug, table, marquee, macos |
