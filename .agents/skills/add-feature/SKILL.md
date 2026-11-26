---
name: add-feature
description: Use when the user wants the feature, fix, or change built in the current chat session recorded for the release notes — triggers "add-feature", "note this for the release", "add it to the changelog". Appends curated bullets under `[Unreleased]` in the repo's CHANGELOG.md. The source is the session itself; git is CI's job and is never consulted.
---

# Add Feature

Records what **this session built** into `CHANGELOG.md` — the curated half of every release's notes. The release workflow appends the commit list automatically (that's git's job, in CI); this entry is the part a human decided mattered. It follows Keep a Changelog + SemVer, and the release tooling parses `## [version]` / `### Category` / `- bullet` mechanically — the grammar is load-bearing, not decoration.

## Procedure

1. Read `CHANGELOG.md` at the repo root. If missing, create it from the Format below with an empty `## [Unreleased]`.
2. Source material is **this conversation, nothing else** — the feature, fix, or change just produced in this session. Do not run git commands (`status`, `diff`, `log`, …): git history belongs to CI, which appends it at release time, and it must never influence the entry. If the session produced several things, propose a bullet for each.
3. Draft the entry: ONE category, one or two bullets per item, outcome wording for a reader ("Check for Updates… menu item", not "added Updater.swift").
4. **Propose the exact bullets to the user and wait for confirmation.** They own the wording; write nothing before they confirm.
5. On confirmation: ensure `## [Unreleased]` exists, add or reuse its `### <Category>`, append the bullets. Never touch sections of already-released versions.
6. Show the updated `[Unreleased]` section by reading the file back — not via git.

If the session produced nothing a user of the project could notice, say so instead of inventing an entry.

Never call the harness `changelog_update` tool — its `## <date> <title>` format is not this grammar and the release parser will skip those entries.

## Headless mode (session-end recorder)

`.omp/hooks/post/add-feature-recorder.ts` spawns `omp -p` when a TUI session closes and passes this skill a transcript path. In that run:

- There is no user: never ask, never wait for confirmation — the hook invocation is the confirmation. Step 4 of the Procedure is replaced by this.
- The source is the transcript file the hook names, and it can be many megabytes. Never read it raw; extract a bounded digest (these recipes are tested):

  ```bash
  F=<transcript path>
  # Intent — everything the user asked for in the session
  jq -r 'select(.type=="message" and .message.role=="user") | [.message.content[]? | select(.type=="text") | .text] | join(" ")' "$F" | head -c 12000
  # Actions — which tools ran (edit/write > 0 means the session shipped code)
  jq -r 'select(.type=="message" and .message.role=="assistant") | .message.content[]? | select(.type=="toolCall") | .name' "$F" | sort | uniq -c | sort -rn
  # Outcome — what it reported when done
  jq -r 'select(.type=="message" and .message.role=="assistant") | [.message.content[]? | select(.type=="text") | .text] | join(" ")' "$F" | tail -c 12000
  ```

- If the session delivered nothing a user of the project could notice (pure questions, reading, planning), write nothing and finish with `NOTHING-TO-RECORD`. Otherwise write the entry and finish with `WRITTEN`.
- Git stays off-limits here too — the recorder prompt commits (`commit` namespace, `CHANGELOG.md` only) and pushes after this skill returns. Never `git add` / `git commit` / `git push` from this skill.
- Logs: `~/.omp/logs/add-feature-recorder/`.

## Format

```markdown
# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Thing the user can now do.

## [0.2.0] - 2026-11-25

### Fixed

- Thing that used to break.
```

- Categories, ordered when several exist: Added, Changed, Deprecated, Removed, Fixed, Security.
- Released sections are immutable once stamped; corrections go under `[Unreleased]`.
- Never bump versions or edit `VERSION` from this skill — the release workflow stamps `[Unreleased]` into `## [x.y.z] - date`; bumping the version is a separate decision.

## Example

Request: "add-feature — the preferences window is resizable now"

Propose, with the heading it will land under:

> ### Changed
>
> - Preferences window is wider and resizable.

Then append it under `## [Unreleased]` once confirmed.
