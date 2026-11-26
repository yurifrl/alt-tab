// Session-end changelog recorder — spawns a detached headless omp run that
// records what the closing TUI session built (the `add-feature` skill in its
// headless mode), commits it, and pushes.
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

function recorderPrompt(sessionFile: string): string {
  return [
    "You are the session-end changelog recorder for this repository. A TUI",
    "session just closed; a hook spawned this headless run to record what it",
    "built.",
    "",
    `Transcript (JSONL): ${sessionFile}`,
    "",
    "1. Load the skill `add-feature` (skill://add-feature) and follow its",
    "   \"Headless mode\" section. No questions, no confirmation — this",
    "   invocation is the confirmation, and there is no user to ask.",
    "2. Digest the transcript with that section's extraction commands; never",
    "   read the raw file (it can be many megabytes).",
    "3. If the session delivered nothing a user of this project could notice,",
    "   write nothing and finish.",
    "4. If the skill wrote an entry, commit ONLY CHANGELOG.md through the",
    "   commit namespace: draft, d.only([\"CHANGELOG.md\"]), commit with",
    "   subject \"docs(changelog): <short outcome>\". Never git add / git",
    "   commit from the shell.",
    "5. Push: `git push origin HEAD`. If rejected, `git pull --rebase",
    "   --autostash` once and push again; if it still fails, keep the commit.",
    "6. End with exactly one status line:",
    "   RECORDED <sha> | NOTHING-TO-RECORD | COMMITTED-LOCAL <sha> | FAILED: <reason>",
  ].join("\n");
}

function recorderCommand(repoDir: string, sessionFile: string, sessionId: string): string {
  const log = `${LOG_DIR}/${new Date().toISOString().replaceAll(":", "-")}_${sessionId.slice(0, 8)}.log`;
  return [
    `export ${GUARD_ENV}=1`,
    `mkdir -p ${shellQuote(LOG_DIR)}`,
    `exec "$(command -v omp || printf '%s' "$HOME/Library/Application Support/Tern/omp/bin/omp")" \\`,
    `  -p ${shellQuote(recorderPrompt(sessionFile))} \\`,
    `  --cwd ${shellQuote(repoDir)} --no-session --no-lsp --no-title \\`,
    `  --approval-mode yolo --max-time ${RECORDER_MAX_TIME} \\`,
    `  > ${shellQuote(log)} 2>&1`,
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
