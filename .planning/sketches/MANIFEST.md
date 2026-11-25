# Sketch Manifest

## Design Direction
Native macOS settings pane (AltTab → Windows tab). Widen the rule form from a single
title matcher to a list of matchers, each with its own kind (Contains, Exact, Starts with,
Ends with, new: Regex) and pattern, combined by any/all. Visual language stays stock
System Settings: small rounded fields, popups with blue chevrons, 13px SF text.

## Reference Points
- macOS System Settings form controls
- The app's own WindowRulesView (Sources/AltTabCore/WindowRulesView.swift)

## Sketches

| # | Name | Design Question | Winner | Tags |
|---|------|-----------------|--------|------|
| 001 | window-rule-matchers | How should multiple matchers (with Regex) live in the rule form? | B — boxed list (implemented) | form, matchers, macos, regex |
