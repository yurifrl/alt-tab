// Session-end changelog recorder — spawns a detached headless omp run that
// records what the closing TUI session built (the `add-feature` skill in its
// headless mode). The model only writes text; the wrapper this hook spawns
// commits CHANGELOG.md and pushes it, and says so loudly when either fails.
//
// Fire-and-forget by design: session_shutdown handlers share a 2-second
// budget, so this hook starts the recorder and returns immediately — it never
// awaits the run. Guards, outermost first: the marker env var (a recorder
// never records itself), TUI mode only (print/RPC/automation runs never
// record), real closes only (the session file must end with its own
// session_exit record), conversation ends only (no sibling branch of the
// same conversation is still open), and sessions large enough to have
// produced something.

import { closeSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

/// Degenerate sessions (opened and closed) are tiny; this is the cheap cut
/// before spending a recorder run on one. Any real interaction clears it — a
/// one-edit test session measured ~19 KB — and the recorder still decides for
/// itself, writing nothing when it finds nothing. Raise to record less, lower
/// to record more.
const MIN_SESSION_BYTES = 8_000;
/// Wall-clock cap for the recorder run.
const RECORDER_MAX_TIME = "15m";
const GUARD_ENV = "OMP_ADD_FEATURE_RECORDER";
/// The closing session's own executable, passed to the wrapper: `command -v
/// omp` in the detached child resolved to a different, older build (18.2.5)
/// than the session that just closed (19.2.1).
export const RECORDER_BIN_ENV = "OMP_ADD_FEATURE_RECORDER_BIN";
const LOG_DIR = `${process.env.HOME ?? "/tmp"}/.omp/logs/add-feature-recorder`;

type BunLike = {
  spawn?: (command: string[], options: Record<string, unknown>) => { unref?: () => void };
  file?: (path: string) => { size: number };
};

/// The host is a Bun-compiled binary: `Bun` exists at runtime but not in this
/// file's TS lib types. Assignment widening, not a cast — the optional
/// property is checked, and nothing is fabricated.
const hostGlobals: typeof globalThis & { Bun?: BunLike } = globalThis;

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function sessionByteSize(path: string): number | undefined {
  try {
    const size = hostGlobals.Bun?.file?.(path)?.size;
    return typeof size === "number" ? size : undefined;
  } catch {
    return undefined;
  }
}

/// A real close writes a terminal record as the session file's last entry —
/// `{"customType":"session_exit","data":{"reason":"dispose","kind":"normal"}}`,
/// observed 1 ms before this hook ran on a Ctrl+D close. A replaced or
/// still-open session has no such record (the file is live, or was abandoned
/// mid-switch). Exported as a test seam: verified against real session files.
export function sessionExitReason(path: string): string | undefined {
  try {
    const stat = statSync(path, { throwIfNoEntry: false });
    if (!stat?.isFile() || stat.size === 0) return undefined;
    const cap = Math.min(4096, stat.size);
    const fd = openSync(path, "r");
    try {
      const tail = Buffer.alloc(cap);
      readSync(fd, tail, 0, cap, stat.size - cap);
      const at = tail.lastIndexOf('"customType":"session_exit"');
      if (at < 0) return undefined;
      const reason = /"reason":"([^"]*)"/.exec(tail.toString("utf8", at));
      return reason?.[1] ?? "unknown";
    } finally {
      closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

/// The `parentSession` recorded in a session file's header — the conversation
/// it continues, or undefined for a root session. Exported as a test seam.
export function sessionParent(path: string): string | undefined {
  try {
    const fd = openSync(path, "r");
    try {
      const head = Buffer.alloc(4096);
      const read = readSync(fd, head, 0, head.length, 0);
      const parent = /"parentSession":"([^"]+)"/.exec(head.subarray(0, read).toString("utf8"));
      return parent?.[1];
    } finally {
      closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

/// Continuation branches of one conversation share their `parentSession`, and
/// an abandoned branch can be disposed while the branch that actually ran the
/// chat keeps going (observed: a 14-second branch disposing for a live 12 MB
/// conversation). A sibling with no session_exit record is still open — that
/// close is a fork being dropped, not the conversation ending. Exported as a
/// test seam.
export function hasLiveSibling(sessionFile: string): boolean {
  try {
    const parent = sessionParent(sessionFile);
    if (!parent) return false;
    const dir = dirname(sessionFile);
    const own = basename(sessionFile);
    for (const entry of readdirSync(dir)) {
      if (!entry.endsWith(".jsonl") || entry === own) continue;
      const sibling = join(dir, entry);
      if (sessionParent(sibling) !== parent) continue;
      if (!sessionExitReason(sibling)) return true;
    }
    return false;
  } catch {
    return false;
  }
}

/// The title a session gave itself (`{"type":"title","v":1,"title":"…"}` as
/// its first record), stripped of the leading icon glyph — a deterministic,
/// informative commit subject that costs no model trust. Exported as a test
/// seam.
export function sessionTitle(path: string): string | undefined {
  try {
    const fd = openSync(path, "r");
    try {
      const head = Buffer.alloc(4096);
      const read = readSync(fd, head, 0, head.length, 0);
      const match = /"type":"title","v":1,"title":"((?:[^"\\]|\\.)*)"/.exec(head.subarray(0, read).toString("utf8"));
      if (!match) return undefined;
      const title = JSON.parse(`"${match[1]}"`) as string;
      const plain = title.replace(/^[^\p{L}\p{N}]+/u, "").trim();
      return plain || undefined;
    } finally {
      closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

function recorderPrompt(sessionFile: string): string {
  return [
    "You are the session-end changelog recorder for this repository. A TUI",
    "session just closed; a hook spawned this headless run to record what it",
    "built. You write text; the hook owns git and will commit and push",
    "CHANGELOG.md itself — never run git, never stage, never commit.",
    "",
    `Transcript (JSONL): ${sessionFile}`,
    "",
    "1. Load the skill `add-feature` (skill://add-feature) and follow its",
    "   \"Headless mode\" section. No questions, no confirmation — this",
    "   invocation is the confirmation, and there is no user to ask.",
    "2. Digest the transcript with that section's extraction commands; never",
    "   read the raw file (it can be many megabytes).",
    "3. Judge only the CHANGELOG.md in this worktree, read now. Earlier",
    "   recorder logs (~/.omp/logs), commit messages and remembered context are",
    "   NOT evidence: if this session's user-visible outcome is not written in",
    "   CHANGELOG.md as it is right now, it is not recorded.",
    "4. If it is not recorded, edit CHANGELOG.md only: add the entry under",
    "   `[Unreleased]` in the skill's format. Touch no other file. End with",
    "   exactly one line: ENTRY-WRITTEN.",
    "5. If the session delivered nothing a user of this project could notice,",
    "   end with exactly one line: NO-USER-VISIBLE-WORK.",
    "6. Never assert the work is already recorded without proof: to do that,",
    "   end with `NOTHING-TO-RECORD | <one line copied verbatim from the",
    "   current CHANGELOG.md that covers this session's work>`. The hook checks",
    "   that line exists and repeats the run when it does not.",
  ].join("\n");
}

/// Second pass after an unverified NOTHING-TO-RECORD: the model claimed the
/// work was already recorded and quoted nothing that exists in CHANGELOG.md.
function recorderRetryPrompt(sessionFile: string): string {
  return [
    recorderPrompt(sessionFile),
    "",
    "RETRY: the previous attempt ended with NOTHING-TO-RECORD and its quoted",
    "CHANGELOG.md line does not exist there, so that claim was false. Re-audit",
    "the transcript and act: if this session's user-visible outcome is missing",
    "from CHANGELOG.md, add it now (edit CHANGELOG.md only) and end with",
    "ENTRY-WRITTEN; if the session truly has no user-visible outcome, end with",
    "NO-USER-VISIBLE-WORK.",
  ].join("\n");
}

/// The hook's own wrapper commits and pushes — the model only writes text.
/// Delegating git to the model failed in practice: the `commit` eval namespace
/// is absent when an extension fails to load, one run reported a sha for a
/// commit that never existed, and a run that gave up left the entry
/// uncommitted. The contract: if CHANGELOG.md changed, it is committed; a
/// failed push keeps the commit; a failure is loud in two places — the run's
/// log (START/END lines) and FAILURES.log — and never on the terminal. The
/// runtime is pinned to the closing session's own binary; `command -v omp` is
/// only the fallback. Exported as a test seam.
export function recorderCommand(repoDir: string, sessionFile: string, sessionId: string): string {
  const stamp = new Date().toISOString().replaceAll(":", "-");
  const log = `${LOG_DIR}/${sessionId}_${stamp}.log`;
  const lock = `${LOG_DIR}/${sessionId}.lock`;
  const failures = `${LOG_DIR}/FAILURES.log`;
  const title = sessionTitle(sessionFile);
  // `chore(changelog)` is the bookkeeping marker: release-notes.sh skips it,
  // so recording a session never shows up as a commit in the release notes.
  const subject = `chore(changelog): ${(title ?? `session ${sessionId.slice(0, 8)}`).slice(0, 72)}`;
  // Everything goes to the log file; the wrapper never writes to the terminal.
  return [
    `export ${GUARD_ENV}=1`,
    `mkdir -p ${shellQuote(LOG_DIR)}`,
    `log=${shellQuote(log)}`,
    `failures=${shellQuote(failures)}`,
    `ln -sf "$log" ${shellQuote(`${LOG_DIR}/latest.log`)}`,
    `now() { date -u +%FT%TZ; }`,
    `status() { printf '%s\\t%s\\n' "$(now)" "$1" >>"$log"; }`,
    `fail() { t=$(now); printf '%s\\tFAILED: %s\\n' "$t" "$1" >>"$log"; printf '%s\\tFAILED: %s\\n' "$t" "$1" >>"$failures"; printf '%s\\tEND FAILED\\n' "$t" >>"$log"; exit 1; }`,
    `lock=${shellQuote(lock)}`,
    `if ! mkdir "$lock" 2>/dev/null; then`,
    `  [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null`,
    `  mkdir "$lock" 2>/dev/null || { status "SKIP: another recorder holds $lock"; exit 0; }`,
    `fi`,
    `trap 'rmdir "$lock" 2>/dev/null' EXIT`,
    `cd ${shellQuote(repoDir)} || fail "cannot cd ${repoDir}"`,
    `git rev-parse --git-dir >/dev/null 2>&1 || fail "$PWD is not a git work tree"`,
    `omp_bin="\${${RECORDER_BIN_ENV}:-}"`,
    `[ -n "$omp_bin" ] && [ -x "$omp_bin" ] || omp_bin=$(command -v omp || printf '%s' "$HOME/Library/Application Support/Tern/omp/bin/omp")`,
    `status "START session ${sessionId} bin $omp_bin"`,
    `prompt=${shellQuote(recorderPrompt(sessionFile))}`,
    `retry=${shellQuote(recorderRetryPrompt(sessionFile))}`,
    `attempt=0`,
    `while [ "$attempt" -lt 2 ]; do`,
    `  attempt=$((attempt + 1))`,
    `  if [ "$attempt" -eq 1 ]; then p=$prompt; else p=$retry; status "RETRY: previous verdict was not backed by CHANGELOG.md"; fi`,
    `  off=$(wc -c <"$log" | tr -d ' ')`,
    `  "$omp_bin" \\`,
    `    -p "$p" \\`,
    `    --cwd ${shellQuote(repoDir)} --no-session --no-lsp --no-title \\`,
    `    --approval-mode yolo --max-time ${RECORDER_MAX_TIME} \\`,
    `    >>"$log" 2>&1`,
    `  rc=$?`,
    `  if [ -n "$(git status --porcelain -- CHANGELOG.md)" ]; then`,
    `    git add -- CHANGELOG.md >>"$log" 2>&1 || fail "git add CHANGELOG.md failed (recorder exit $rc)"`,
    `    git commit -m ${shellQuote(subject)} -- CHANGELOG.md >>"$log" 2>&1 || fail "git commit failed (recorder exit $rc)"`,
    `    sha=$(git rev-parse HEAD)`,
    `    if ! git push origin HEAD >>"$log" 2>&1; then`,
    `      git pull --rebase --autostash >>"$log" 2>&1 || true`,
    `      git push origin HEAD >>"$log" 2>&1 || { t=$(now); m="COMMITTED-LOCAL $sha (push failed)"; printf '%s\\t%s\\n' "$t" "$m" >>"$log"; printf '%s\\t%s\\n' "$t" "$m" >>"$failures"; printf '%s\\tEND FAILED (push)\\n' "$t" >>"$log"; exit 1; }`,
    `    fi`,
    `    status "RECORDED $sha"; status "END OK"; exit 0`,
    `  fi`,
    `  [ "$rc" -ne 0 ] && fail "recorder exited $rc with no CHANGELOG.md change"`,
    `  out=$(tail -c +$((off + 1)) "$log")`,
    `  verdict=$(printf '%s\\n' "$out" | grep -o 'NOTHING-TO-RECORD *|.*' | tail -1)`,
    `  if [ -z "$verdict" ] && printf '%s\\n' "$out" | grep -q 'NO-USER-VISIBLE-WORK'; then verdict=NO-USER-VISIBLE-WORK; fi`,
    `  if [ "$verdict" = "NO-USER-VISIBLE-WORK" ]; then`,
    `    status "NOTHING-TO-RECORD (nothing user-visible)"; status "END OK"; exit 0`,
    `  fi`,
    `  case "$verdict" in`,
    `    NOTHING-TO-RECORD*)`,
    `      quote=${'${verdict#*|}'}`,
    `      quote=$(printf '%s' "$quote" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')`,
    `      if [ -n "$quote" ] && grep -Fq -- "$quote" CHANGELOG.md; then`,
    `        status "NOTHING-TO-RECORD (already recorded: $quote)"; status "END OK"; exit 0`,
    `      fi`,
    `      status "UNVERIFIED NOTHING-TO-RECORD: the quoted line is not in CHANGELOG.md" ;;`,
    `    *) status "no verdict line in the recorder output" ;;`,
    `  esac`,
    `done`,
    `fail "recorder ran twice without recording or backing its verdict"`,
  ].join("\n");
}

/// `session_shutdown` also carries a legacy `targetSessionFile`. Its `reason`
/// proved unreliable in practice — a real Ctrl+D close carried none at the
/// event (only `dispose` inside the session file) — so terminal state is read
/// from the session file itself instead.
type ShutdownMeta = { targetSessionFile?: string };

export default function (pi: HookAPI): void {
  let spawned = false; // one close, one recorder — duplicate shutdown events change nothing
  const skip = (why: string): void => {
    pi.logger?.info?.(`add-feature-recorder: skipped (${why})`);
  };

  pi.on("session_shutdown", async (event, ctx) => {
    try {
      if (process.env[GUARD_ENV]) return; // a recorder closing: never record itself
      if (spawned) return;
      if (ctx?.mode !== "tui") return skip(`mode ${ctx?.mode ?? "unknown"}`);
      if (ctx?.agent && ctx.agent.kind !== "main") return skip(`agent ${ctx.agent.kind}`);
      const meta: ShutdownMeta = event ?? {};
      const sessionFile = ctx?.sessionManager?.getSessionFile?.() ?? meta.targetSessionFile;
      if (!sessionFile) return skip("no session file on disk");
      // Only a real close: the file ends with its own terminal record. Live
      // sessions (mid-continuation, still being written) have none — that
      // shutdown event is a session replacement, not a close.
      const exitReason = sessionExitReason(sessionFile);
      if (!exitReason) return skip(`no session_exit record at the end of ${sessionFile}`);
      if (hasLiveSibling(sessionFile)) return skip("a sibling branch of this conversation is still open");
      const sessionId = ctx?.sessionManager?.getSessionId?.() ?? "session";
      const size = sessionByteSize(sessionFile);
      if (size !== undefined && size < MIN_SESSION_BYTES) return skip(`session ${size} bytes < ${MIN_SESSION_BYTES}`);

      const repoDir = ctx?.cwd ?? process.cwd();
      const spawn = hostGlobals.Bun?.spawn;
      if (typeof spawn !== "function") return skip("no Bun.spawn in host");
      const child = spawn(["bash", "-lc", recorderCommand(repoDir, sessionFile, sessionId)], {
        cwd: repoDir,
        detached: true,
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
        env: { ...process.env, [RECORDER_BIN_ENV]: process.execPath },
      });
      child?.unref?.();
      spawned = true;
      pi.logger?.info?.(`add-feature-recorder: started for ${sessionId} (${size ?? "unknown"} bytes, exit ${exitReason})`);
    } catch (error) {
      try {
        pi.logger?.warn?.(`add-feature-recorder: ${String(error)}`);
      } catch {
        // logger itself failing is not worth anything more
      }
    }
  });
}
