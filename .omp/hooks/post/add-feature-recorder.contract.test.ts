// Contract test for the recorder wrapper's git behaviour, with fake `omp`
// binaries standing in for the model. Five scenarios: commit+push, nothing,
// push-fail (commit kept), commit-fail (loud), pinned binary.
//
// Run it directly; it re-executes itself under a throwaway HOME so the hook's
// load-time log dir lands in the sandbox instead of the real one:
//   bun .omp/hooks/post/add-feature-recorder.contract.test.ts
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The hook resolves its log directory from HOME at module load. Static imports
// are hoisted, so the sandboxed re-exec has to happen before the import — hence
// the dynamic one below, which is the module-loading boundary this test guards.
if (process.env.RECORDER_TEST_HOME !== "1") {
  const home = mkdtempSync(join(tmpdir(), "recorder-contract-"));
  const child = Bun.spawnSync([process.execPath, import.meta.path], {
    env: { ...process.env, HOME: home, RECORDER_TEST_HOME: "1" },
    stdout: "inherit",
    stderr: "inherit",
  });
  process.exit(child.exitCode ?? 1);
}

const { RECORDER_BIN_ENV, recorderCommand } = await import("./add-feature-recorder.ts");

const base = process.env.HOME!;
const logDir = join(base, ".omp/logs/add-feature-recorder");
const failuresLog = join(logDir, "FAILURES.log");
mkdirSync(logDir, { recursive: true });

// Login bash rebuilds PATH from /etc/paths (path_helper), so the fake bin has
// to be exported inside the command string, after the profile scripts ran.
const binDir = join(base, "bin");
mkdirSync(binDir, { recursive: true });
function fakeOmp(dir: string, marker: string, bullet: string): string {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "omp");
  writeFileSync(
    path,
    [
      "#!/bin/sh",
      `printf '%s\\n' "${marker}"`,
      `if [ "\${FAKE_APPEND:-0}" = 1 ]; then printf -- '- ${bullet}\\n' >> CHANGELOG.md; fi`,
      "exit ${FAKE_RC:-0}",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  return path;
}
fakeOmp(binDir, "FAKE-OMP-RAN", "a new recorder bullet");
const fakePin = fakeOmp(join(base, "bin-pinned"), "FAKE2-OMP-RAN", "a pinned-binary bullet");

function run(cmd: string, cwd: string) {
  // Bun.spawnSync's default `env` is a startup snapshot: mutations to
  // process.env (scenario switches) only reach the child when passed in.
  const r = Bun.spawnSync(["bash", "-lc", cmd], { cwd, env: { ...process.env }, stdout: "pipe", stderr: "pipe" });
  return { out: `${r.stdout.toString()}${r.stderr.toString()}`, code: r.exitCode ?? -1 };
}
function recorder(id8: string, session: string, repo: string) {
  return run(`export PATH=${binDir}:$PATH\n${recorderCommand(repo, session, id8)}`, repo);
}
function git(cwd: string, args: string): string {
  return run(`git ${args}`, cwd).out.trim();
}
function logFor(id8: string): string {
  const file = readdirSync(logDir)
    .filter((f) => f.endsWith(`_${id8}.log`))
    .sort()
    .pop();
  return file ? readFileSync(join(logDir, file), "utf8") : "";
}
function failuresText(): string {
  try {
    return readFileSync(failuresLog, "utf8");
  } catch {
    return "";
  }
}
function failuresSize(): number {
  return failuresText().length;
}

let repoN = 0;
function makeRepo() {
  const dir = join(base, `repo${repoN++}`);
  const remote = `${dir}-remote.git`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n");
  writeFileSync(join(dir, "peer.txt"), "peer work in progress\n");
  run(
    `git init -q -b main && git config user.email t@t.example && git config user.name t \
&& git add -A && git commit -qm init && git init -q --bare ${remote} \
&& git remote add origin ${remote} && git push -q -u origin main`,
    dir,
  );
  return { dir, remote };
}

const session = join(base, "session.jsonl");
writeFileSync(
  session,
  '{"type":"title","v":1,"title":"\u{f0f0} ICON: Test session","source":"auto"}\n{"type":"session","id":"abcd1234-0000"}\n',
);

const results: string[] = [];
const check = (name: string, ok: boolean, detail: string) => {
  results.push(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : ` — ${detail}`}`);
};
const setEnv = (append: boolean, rc?: number) => {
  process.env.FAKE_APPEND = append ? "1" : "0";
  if (rc === undefined) delete process.env.FAKE_RC;
  else process.env.FAKE_RC = String(rc);
  delete process.env[RECORDER_BIN_ENV];
};

// A — append happened: commit CHANGELOG.md only, push, real sha logged.
{
  const a = makeRepo();
  setEnv(true);
  writeFileSync(join(a.dir, "peer.txt"), "peer work in progress\npeer edit not mine\n");
  const before = failuresSize();
  const r = recorder("aaaa1111", session, a.dir);
  const log = logFor("aaaa1111");
  const head = git(a.dir, "rev-parse HEAD");
  const remoteHead = git(base, `--git-dir=${a.remote} rev-parse main`);
  const subject = git(a.dir, "log -1 --format=%s");
  const changed = git(a.dir, "show --name-only --format= HEAD");
  check("A fake model ran", log.includes("FAKE-OMP-RAN"), log.slice(-200));
  check("A logged real sha", /^RECORDED [0-9a-f]{40}$/m.test(log), log.slice(-200));
  check("A sha matches HEAD", log.includes(`RECORDED ${head}`), `${log.slice(-80)} vs ${head}`);
  check("A pushed", head === remoteHead, `local ${head} remote ${remoteHead}`);
  check("A commit subject", /^docs\(changelog\): .*test session/i.test(subject), subject);
  check("A only CHANGELOG committed", changed === "CHANGELOG.md", changed);
  check("A peer edit stays uncommitted", git(a.dir, "status --porcelain -- peer.txt").includes("peer.txt"), "peer.txt was committed");
  check("A no loud failure", failuresSize() === before, failuresText().slice(before));
  check("A exit 0", r.code === 0, `exit ${r.code}: ${r.out.slice(-300)}`);
}

// B — model wrote nothing: NOTHING-TO-RECORD, no commit.
{
  const b = makeRepo();
  setEnv(false);
  const before = git(b.dir, "rev-parse HEAD");
  const r = recorder("bbbb2222", session, b.dir);
  const log = logFor("bbbb2222");
  check("B NOTHING-TO-RECORD", /^NOTHING-TO-RECORD$/m.test(log), log.slice(-200));
  check("B no commit", git(b.dir, "rev-parse HEAD") === before, "HEAD moved");
  check("B exit 0", r.code === 0, `exit ${r.code}`);
}

// C — push fails: commit kept locally, loud COMMITTED-LOCAL + FAILURES line.
{
  const c = makeRepo();
  setEnv(true);
  run(`git remote set-url origin ${base}/does-not-exist.git`, c.dir);
  const before = git(c.dir, "rev-parse HEAD");
  const failuresBefore = failuresSize();
  const r = recorder("cccc3333", session, c.dir);
  const log = logFor("cccc3333");
  const head = git(c.dir, "rev-parse HEAD");
  check("C commit kept locally", head !== before && /^COMMITTED-LOCAL [0-9a-f]{40} \(push failed\)$/m.test(log), `${before} -> ${head}: ${log.slice(-200)}`);
  check("C loud FAILURES entry", failuresText().slice(failuresBefore).includes("push failed — commit kept locally"), failuresText().slice(failuresBefore));
  check("C exit nonzero", r.code !== 0, `exit ${r.code}`);
}

// D — commit fails (stale index lock): loud FAILED, no commit.
{
  const d = makeRepo();
  setEnv(true);
  writeFileSync(join(d.dir, ".git/index.lock"), "");
  const before = git(d.dir, "rev-parse HEAD");
  const failuresBefore = failuresSize();
  const r = recorder("dddd4444", session, d.dir);
  const log = logFor("dddd4444");
  check("D no commit", git(d.dir, "rev-parse HEAD") === before, "HEAD moved");
  check("D loud FAILED", /^FAILED: git (add|commit)/m.test(log), log.slice(-300));
  check("D FAILURES entry", failuresText().slice(failuresBefore).includes("commit failed"), failuresText().slice(failuresBefore));
  check("D exit nonzero", r.code !== 0, `exit ${r.code}`);
}

// E — pinned binary wins over PATH.
{
  const e = makeRepo();
  setEnv(true);
  process.env[RECORDER_BIN_ENV] = fakePin;
  const r = recorder("eeee5555", session, e.dir);
  delete process.env[RECORDER_BIN_ENV];
  const log = logFor("eeee5555");
  check("E pinned binary used", log.includes("FAKE2-OMP-RAN") && !log.includes("FAKE-OMP-RAN"), log.slice(-300));
  check("E committed and pushed", /^RECORDED [0-9a-f]{40}$/m.test(log) && git(e.dir, "log -1 --format=%s").startsWith("docs(changelog): "), log.slice(-200));
  check("E exit 0", r.code === 0, `exit ${r.code}: ${r.out.slice(-300)}`);
}

console.log(results.join("\n"));
const failed = results.filter((r) => r.startsWith("FAIL")).length;
console.log(failed === 0 ? "\nALL PASS" : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
