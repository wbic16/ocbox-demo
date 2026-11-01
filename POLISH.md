# POLISH.md — Layers 1–4 log for the ocbox × phext MVP

What was run, what broke, what changed. All runs recorded 2026-11-01
against SQ v0.6.0, ffmpeg/ffprobe 8.1.2. Failure-first: every bug below
was found by a failing check, not by inspection alone — except where
noted as a code-review fix.

## Layer 1 — Polish

**Read-through of `ocbox` (977 lines). Found & fixed:**

1. **Lossy output handling (the big one).** `exec` decoded stdout/stderr
   with `errors="replace"` and chunked the resulting *string* by
   character count. Three defects in one: invalid UTF-8 was silently
   destroyed, chunk sizes were characters not bytes (a 64 KB scroll
   could be up to 256 KB on the wire for 4-byte characters), and a chunk
   boundary could split a multi-byte character. → Replaced with the
   byte-exact encoding policy (Layer 2, below) and byte-aware chunking.
2. **No per-command help.** Only a one-line usage existed. → `HELP`
   table: `ocbox --help` lists every command with a summary,
   `ocbox help <command>` / `ocbox <command> --help` give details.
   Unknown commands and usage errors exit 2 with specific messages
   (verified: no project, no active session, SQ missing/down, double
   `start`, `stop` on a stopped session each die with their own text).
3. **Signal deaths were invisible.** A command killed by a signal showed
   up as a bare negative/143 exit with no explanation. → The transcript
   lane now records `signal: SIGTERM (15)` and `exit_shell: 143` when
   the wrapped process dies by signal (subprocess rc < 0), the CLI
   prints a notice to stderr, and the CLI itself exits 128+signum, the
   shell convention. Meta lane gains a `signal=` flag.
4. **Transcript lanes were thin.** They recorded only command/exit/
   duration. → They now record per-stream byte counts, SHA-256 of the
   raw bytes, and encoding — a reader can verify any lane independently.
5. **Snapshot path check bug (latent).** `snapshot()` tested exclusion
   names against the *absolute* path's parts, so a shim-home component
   named e.g. `node_modules` would have silently emptied the manifest.
   → Now tested against the workspace-relative path's parts.
6. **Continuation chaining added** (needed by Layer 4, useful in
   general): when `start` follows a session that left a checkpoint, the
   new session's meta scroll quotes the previous session's id and its
   checkpoint checksum (`continuation_of_session`,
   `continuation_checkpoint_checksum`).
7. **Self-copy recursion (found by exercising the error paths, after
   this layer was "done").** With `OCBOX_SHIM_HOME` placed *inside* the
   project root, `start` copied the project tree — including the shim
   home's own sessions directory, which contains the workspace being
   created — recursively, until path names overflowed (`Errno 36`) and
   the CLI died with a traceback. → `create_workspace` now takes
   resolved-path exclusions (the shim home and the phext store) that are
   never copied, at any depth. Re-verified in both layouts: shim home
   inside the project works, double `start` and double `stop` die
   cleanly with exit 2 and specific messages, normal layout unchanged.

**README:** added "What the demo shows" (keyed to the demo transcript's
coordinates, lane by lane), the encoding-policy and teleportation
sections, per-command/exit-code documentation, and the evidence index
for Layers 2–4. Every claim re-checked against the final transcripts.

## Layer 2 — Stress (`stress/run_stress.sh` → `STRESS-TRANSCRIPT.txt`)

**Result: 28/28 PASS.** One session of 81 execs plus a second session;
verifier reads the phext directly via SQ (`toc` + `select`).

| Case | Result |
|---|---|
| 1. ~4.79 MB stdout (`seq 1 700000`) | 74 chunk scrolls = ⌈bytes/65536⌉; reassembly SHA-256 == locally generated |
| 2. Single 250,000-char line, no newline | byte-exact, 4 chunks — chunking is line-independent |
| 3. No trailing newline / empty streams / stderr-only | exact; empty streams leave no scrolls, transcript records 0 bytes |
| 4. Binary stdout (`dd` 64 KB, `openssl rand` 4096) | base64 policy round-trips losslessly; decoded SHA-256 == transcript's recorded raw SHA-256 |
| 5. Unicode/emoji/combining; `\r` progress, no `\n` | byte-exact both |
| 6. Exit zoo: 0, 1, 2, 42, 127, `timeout` 124, SIGTERM via shell (143), SIGTERM direct (exit −15 + signal line), `grep` no-match 1, `diff` differs 1 | all recorded raw in the phext; CLI propagated every code; `ocbox` never crashed |
| 7. 60 sequential `echo` execs | session seqs 2..81 contiguous, no gaps/dupes; checkpoint `final_seq` == 81 |
| 8. Filenames with spaces + unicode | manifest and diff list both correctly |
| 9. Second session | registry gains its line (int 2), lanes disjoint from session 1, meta chains to session 1's checkpoint, `context` works |
| 10. 10 MB binary created; 1 MB binary modified | manifest SHA-256 == `sha256sum`; modified binary gets a hash/size diff record, no difflib dump |

**Encoding policy (decided + implemented):** per stream, per exec —
valid UTF-8 → text scrolls, chunked on byte boundaries backed off to
character boundaries (each scroll ≤ 64 KB encoded, concatenation ==
original bytes). Invalid UTF-8 → chunk 1 is a header scroll
(`ocbox:encoding=base64`, raw byte count, raw SHA-256), chunks 2… carry
base64 at 64 KB per scroll; decode(concat) == original bytes. Empty →
no scrolls. The transcript lane always records bytes/SHA-256/encoding
per stream.

**Bugs found by this layer:**

- **SQ `json-export` is lossy (the important find).** It escapes neither
  tabs nor backslashes inside scrolls. A recorded command line containing
  a literal `\r` (backslash-r, case 5b) came back from `json.loads` as a
  real carriage return, which first showed up as a verifier
  `AssertionError` on a transcript that demonstrably existed via
  `select`. The phext itself is byte-exact; the export format is not.
  → `PhextWriter.export_exact()` added (coordinates from `toc`, content
  from per-coordinate `select`); `context` and `teleport-in` now use it,
  and so do all three verification passes. `json_export()` remains but
  is documented as lossy.
- **Harness bug (mine, not the tool's):** the first stress run died at
  the first intentionally-failing exec — `set -e` in the driver. Removed;
  the driver's exit status is now the verifier's verdict only. The big
  cases also no longer spray megabytes into the transcript file itself:
  their stdout goes to a capture file whose size + SHA-256 are printed
  (the full output lives in the phext lane, which is the point).

**Volume economics:** the ~4.79 MB output case yields a final stress
phext of 5,167,598 bytes containing 5,167,256 bytes of scroll text —
**342 bytes of phext structure overhead in total** (coordinate prefixes
are delta-encoded). Write cost is real, though: every chunk insert makes
SQ rewrite the whole file, so the 81-exec stress session takes ~24 s
wall, most of it in whole-file rewrites of a growing 5 MB phext. That is
SPEC-v0.2 §6's "flush frequency is the cost knob" made concrete; per-
command flush is still the right default, but a future `exec --batch`
could amortise it.

## Layer 3 — Real-tool gauntlet + ffmpeg showcase (`demo/showcase.sh` → `SHOWCASE-TRANSCRIPT.txt`)

**Result: 14/14 PASS.** One session, 19 execs, each in its own lane:

- **ffmpeg** generated a 6 s testsrc2 + sine-tone H.264/AAC `out.mp4`
  (651,291 B) entirely from lavfi, then transcoded to a 320 px VP8
  `clip.webm` (287,434 B). Verification asserts the class-4 lane for the
  encode contains ffmpeg's `frame=` progress text — the `\r` progress
  chatter lands intact.
- **ffprobe** JSON to stdout reassembles and parses (2 streams);
  **jq** pretty-prints it from file, and a malformed-JSON jq run is
  recorded with exit 5 and its stderr.
- **sqlite3** created `media.db`, inserted both files' real sizes and
  durations (read from the ffprobe JSON inside the session), queried
  them back; the binary `.db` appears in the stop manifest with a
  matching SHA-256.
- **git** init/add/commit inside the workspace, `git log --oneline`
  recorded in a later lane. **rg** match (0) and no-match (1). **tar +
  gzip** archive listed; **zip** of the logs dir. **gcc** compiled
  hello.c, output `computed = 42`. **node** printed JSON. **openssl**
  `dgst -sha256 out.mp4` — the verifier asserts the stdout lane's hash
  equals both the manifest entry and a fresh `sha256sum`.
- **curl**: a `python3 -m http.server` was started in the workspace by
  one exec and fetched by the same exec — localhost networking works in
  this sandbox, so the fetch is recorded for real (no skip needed).

No tool-specific bugs found in this layer; everything the gauntlet
threw at the lanes (binary db, multi-MB media referenced by hash, `git`
exit codes, jq's exit 5) was already covered by the Layer 1/2 fixes.

## Layer 4 — State teleportation (`demo/teleport.sh` → `TELEPORT-TRANSCRIPT.txt`)

**Result: 10/10 PASS.**

Built: `ocbox teleport-in <path-to.phext>` — in a fresh environment
(fresh shim home, fresh store, no `state.json`, no workspace) it copies
the phext into the store, rebuilds writer state from the registry +
checkpoint scrolls, and prints a resume briefing generated **only** from
phext data: project, sessions, last session's commands with exit codes,
files at stop (manifest + diff), checkpoint checksum, next free
session/sequence numbers. Also fixed `context` to find its checkpoint
by scanning the phext when there is no local state, so a teleported
phext is fully readable before any rebuild.

The demo: machine A runs 4 execs (python compute, a file creation with
known content, a 1 s ffmpeg clip, a `cat`) and stops — phext 8,019
bytes. The jump copies **only** that file (transcript shows `find`
listings before/after: one file crossed; B's shim home absent). B's
briefing matches A's recorded commands, exit codes, file list, and
checkpoint checksum exactly. B then continues: session 2 starts on the
same phext (its meta quotes session 1's id + checkpoint checksum), an
exec recreates A's `note.txt` and its SHA-256 matches A's manifest
entry, and a fresh `context` delta since the teleport point names only
the continuation's coordinates plus the session-registry scroll. B's
phext after continuation: 9,663 bytes.

Precisely what teleports: history (all lanes), context (toc/delta/
checkpoints), the registry, sequence counters, manifest hashes. What
does not: workspace file contents — those re-sync from the project
repo, matching opencloudbox's explicit-Project-movement model.

## Remaining limits (honest list)

- **Whole-file rewrite cost** grows with phext size (above). A 5 MB
  phext with per-command flushes is fine; a 100 MB session log would
  want batched inserts or per-session phext files.
- **Base64 lanes cost 4/3×** and are not human-readable — the deliberate
  price of a pure-text phext.
- **`context`'s changed-coordinate list** is computed by hashing every
  scroll via `export_exact` — O(scroll count) `select` calls. Fine at
  this scale; SQ's `/delta` should eventually make it O(changes).
- **Single writer** remains a spec-level constraint (SPEC-v0.2 §6):
  sequence allocation is only safe because one CLI process writes a
  project's phext at a time.
- **Teleport rebuilds sessions as `stopped`** with no workspace and an
  empty start-snapshot: continuing work starts a *new* session (by
  design), and a teleported session's own unified diffs can't be
  regenerated — its diff/manifest scrolls, of course, travel with the
  file.
- The demo/stress/showcase/teleport transcripts contain this machine's
  absolute paths and per-run session ids; coordinates, hashes and check
  results are the stable content.


## Layer 5 — Fix pass (2026-11-01): daemon transport + the GAP-ANALYSIS majors

Directed by Will ("fix the bugs and consider using sq in daemon
mode"). The full record — transport decision, per-gap resolution
table, before/after numbers — is the dated addendum in
GAP-ANALYSIS.md; this is the layer summary.

**Transport: SQ daemon mode, daemon-only.** The writer drives
`sq share` + CLI ops (`pull`/`push` for payloads — `select` to stdout
appends a trailing newline and must not carry bytes; argv `insert`
for small appends; `toc`, `save`, `shutdown`). The HTTP host path was
deleted: no listener, no port adoption, no key story (`OCBOX_SQ_KEY`
is a documented no-op locally). Latency is at parity with HTTP
(medians on the stress phext: small update 1.69 ms vs 2.97 ms;
64 KB push 1.77 ms vs 2.66 ms; toc 12.84 ms vs 8.37 ms). Daemon
mutations need `sq save` to reach the file (4 ms on 5 MB; the writer
saves once per command). The needed CLI ops were verified live on
SQ 0.5.6 (rock-mountain) as well as 0.6.0 locally.

Two daemon behaviours shaped the writer. (1) **No whole-phext
checksum/delta**: daemon `checksum` is per-scroll and `delta`'s
semantics diverge across versions, so identity is the writer-computed
SHA-256 of the phext file after save. (2) **IPC wedging**: SQ daemons
intermittently stop answering while alive, correlated with
timeout-killed probe clients. The writer's discipline: existence from
/proc (cmdline + cwd), one long-fused warm-up op instead of probe
loops, settle-before-spawn, store-scoped recovery (SIGKILL verified
store processes, clear `.sq`, respawn once), and an escalating
shutdown (CLI → SIGTERM → SIGKILL).

**Majors fixed** (regression tests in `tests/fix_regressions.sh`,
35/35): symlink containment at start/snapshot (P9a/P9b); flock-
serialized state + atomic saves, concurrent execs both land (P1);
teleport-in validation + integrity verdict + `--expect-sha256` +
`--adopt`, checkpoint-less sessions rebuild as `interrupted` with
lane-derived seq (P2/P3a/P4); host trust eliminated by the transport
(P6/P11a); context economy (P10). **Minors fixed:** missing-workspace
stop honesty (P8), exec stdin DEVNULL / `--interactive` /
`--timeout` + process-group signal forwarding (P5/P12; kill -9 of the
CLI remains unhandleable by construction), transport preflight at
start (P7), project-name collision checks (P13), destroy refusal +
`--force` tombstone (R2), no blind write retries (R3), `OCBOX_REDACT`
(R4), transcript-last flush ordering (R6). **Left open deliberately:**
R5 (state keyed by absolute path; teleport-in is the recovery).

**Checkpoint grows** (SPEC-DEVIATIONS in README, v0.3 candidates): a
lane-hash map scroll (coordinate→SHA-256) at the checkpoint class,
per-class max-seq counters, and `prev_checkpoint_sha256` — the E4
checkpoint chain. `pre_checkpoint_checksum` is now the phext-file
SHA-256 taken after diff+manifest+map are saved, before the
checkpoint insert.

**Context economy, measured** (op-counting `SQ_BIN` wrapper, stress
phext 5,198,797 B / 251 scrolls): no-change resume went from
**352,836 B / 252–503 requests** (audit) to **1,001 B / 4 transport
ops**. The one-time baseline context costs 259 ops (a full hash pass)
or zero when a checkpoint lane map already exists.

**Suites against the final binary:** demo PASS · stress 28/28 ·
showcase 14/14 · teleport 10/10 · fix regressions 35/35. All four
verifiers were ported from HTTP reads to daemon-CLI reads
(json-export is synthesized from toc+pull, byte-exact). One honest
caveat: under heavy concurrent load on this machine, a single
regression-suite assert has occasionally flaked (daemon wedge class)
and passed on rerun; the suites' verifiers use the same
settle/recovery discipline as the writer.

## Layer 6 — Daemon-lifecycle defect cluster: DIAGNOSIS (2026-11-01, post-publish)

Written BEFORE the fix, at Will's challenge ("353 KB to 1 KB sounds
like undetected failure") and Emise's failed verification probes:
`teleport-in` of the real 5.2 MB stress phext failed 2/2 (rc=1) with
a wedge-recovery event and "sq daemon did not come up"; a trivial
start→exec→stop→context cycle also triggered wedge recovery; the
1,001 B / 4 ops figure had never been independently reproduced and
no out-of-band mutation test of the change detector had ever run.
Diagnosis method: SQ 0.6.0 source read directly (cargo registry
copy), controlled experiments, and a deterministic reproduction.

**How SQ daemon mode actually works (from `sq-0.6.0/src/main.rs`).**
The channel is a single-slot shared-memory mailbox: one 1 GB segment
(messages) + one 1 KB segment (work event), named by files
`.sq/link` / `.sq/work` in the daemon's cwd, each containing a
RANDOM per-spawn OS shm name (`/shmem_<hex>`). Addressing is strictly
per-directory (no parent-dir discovery; same phext basename in two
dirs is fully independent — both verified experimentally). A client
writes its request into the slot, signals the event, and waits with
`Timeout::Infinite` — **no client-side timeout, no server-identity
check, one request at a time**. Segment acquisition is
create-or-open: whichever sq process (client OR `share`) creates the
segment first owns it; a process that opens instead of creating is
treated as a client. Consequences, all confirmed by experiment:

- A **client started in a dir with no live daemon blocks forever**
  (it creates the segment itself and waits for a server that will
  never attach). `sq toc` / `sq status` with no daemon: still blocked
  at 8 s, killed by the test harness's timeout.
- A **`share` process that loses the create race silently becomes a
  client** and blocks forever — alive in /proc as `sq share <file>`,
  indistinguishable by cmdline from a real daemon, never serving.
  Only its log betrays it: a real server prints `Operating in daemon
  mode.` / `Serving N scrolls.`; a share-turned-client prints neither.
- **`sq share` deletes `.sq` on every startup**
  (`recreate_sq_work_files`), so a duplicate `share` unlinks the live
  daemon's flink files: afterwards two daemons serve divergent
  in-memory copies of one file, and `sq shutdown` reaches only the
  current link owner (reproduced: shutdown killed the second daemon,
  left the first alive and unreachable).
- **`shutdown` does not save** (server-side it just ends the loop);
  `save` is the only persistence. Signal-based shutdown after an
  explicit save is therefore semantically equivalent.
- SQ clients print errors like `Error: MapOpenFailed(2)` yet **exit
  0** (observed against a stale `.sq`), so exit code alone cannot
  prove channel health.
- Killed daemons leak their /dev/shm segments (owner-drop cleanup
  does not run under SIGKILL, and segments were observed to persist
  even after clean shutdowns); each daemon also reserves a sparse
  1 GB work segment. Segment names are random, so leaks cost inodes,
  not collisions.

**The race at the heart of the cluster.** `PhextWriter._spawn_and_
confirm` Popen's the daemon and IMMEDIATELY runs the warm-up `sq toc`
client. The daemon must be scheduled, delete/recreate `.sq`, and
create both segments before that client runs its own create-or-open —
on an idle box the daemon wins easily (teleport of the stress phext:
2/2 clean, ~4 s, integrity OK); under load the newborn daemon's
scheduling lag is arbitrarily long, and if the warm-up client runs
first it **creates the segment itself and waits forever on its
orphan segment**. The daemon then starts normally and serves — but
the warm-up never returns. At the 60 s fuse, subprocess kills the
(client) process, `_warmup_ok` reports failure, and `_recover_wedged`
SIGKILLs **the healthy daemon** — its /proc scan (cmdline + cwd)
cannot distinguish serving / starting / zombie processes, and the
actually-broken process (the writer's own timed-out client) is
already dead and never examined. The respawn rolls the same dice
under the same conditions and fails the same way; `die()` then
leaves the respawned (healthy) daemon running and — because
`cmd_teleport_in` constructs its validation writer OUTSIDE the
try/finally — leaves the whole `.validate-<pid>` scratch dir behind.

**Deterministic reproduction** (3 s delayed-`share` SQ_BIN shim,
simulating spawn scheduling lag; census + independent witness):
warm-up client stole ownership at t≈0; daemon pid 7082 was serving
by t=3.6 s (`Serving 251 scrolls` in its log); an independent `sq
toc` at t≈12 s returned rc=0 with the full 352,574-byte toc **while
ocbox believed the daemon wedged**; recovery killed pid 7082 at
t=60.4 s; respawn pid 8153 hit the identical race; teleport-in died
at t=121.5 s leaving healthy daemon 8153 and the scratch dir in
place. This matches Emise's live observations (recovery event,
"did not come up", leftover `sq share incoming.phext`) point for
point. The 5 MB size of the stress phext is a red herring: the race
window is spawn scheduling lag, not load time (the daemon loads
5.2 MB in well under a second); the stress phext was simply the file
being teleported in the heaviest-tested, busiest-box moments.

**Defects (ocbox side), numbered for the fix:**
- **D1** Warm-up races daemon startup — a client can steal segment
  ownership; "wedged" is diagnosed against a healthy daemon. There
  is no readiness gate between spawn and first client op.
- **D2** Recovery identity is cmdline-deep: it cannot tell a serving
  daemon from a starting one or a share-turned-client zombie, so it
  kills healthy daemons; one respawn under unchanged conditions is
  not a remedy for a scheduling race.
- **D3** Failure paths orphan processes: `_ensure_daemon`'s `die()`
  kills nothing it spawned; teleport-in's scratch writer is built
  outside the try/finally, so a construction failure leaks the
  daemon, `.sq`, `sq-daemon.json`, and the scratch dir.
- **D4** Read-path leaks: `cmd_context` spawns a daemon and NEVER
  shuts it down (measured: 8 stop→context cycles, daemon pid churned
  every cycle, one always left alive — including after its project
  dir was deleted, per Emise's probe). `cmd_status` probes with a
  2 s-fused `sq status` client of the same steal-prone class.
- **D5** `_warmup_ok` trusts exit code only; SQ's rc=0 error prints
  make a false "healthy" possible against a stale `.sq`.
- **D6** Duplicate-share twins are reachable whenever a spawn is
  issued against a dir whose daemon is mid-exit; the writer's
  settle logic polls the same ambiguous /proc signal.

**Status of the detector question at diagnosis time: UNANSWERED.**
The 1,001 B / 4 ops figure is context's file-SHA short-circuit on an
unchanged file, measured by the builder in the original stress
store. The short-circuit is only as sound as "the file is ground
truth" — and this writer's `context` opens with `save()`, flushing
the attached daemon's memory over the file, so an out-of-band change
that never reached that daemon's memory could in principle be
overwritten before it is ever compared. Whether that happens in
practice — and whether the per-scroll diff catches direct SQ-level
mutation at all — is exactly what the new `tests/change_detection.sh`
suite (Layer 7) exists to answer at small and stress scale.

## Layer 7 — Lifecycle fix + detector verdict (2026-11-01)

**Writer fixes (one per Layer 6 defect):**
- **D1 → readiness gate.** `_spawn_and_confirm` now waits for the new
  daemon's own proof of service — `Serving N scrolls` in
  sq-daemon.log past the pre-spawn offset, plus both `.sq` flink
  files — BEFORE any client op runs, then confirms with one
  content-checked warm-up. No client ever races a spawn again.
- **D5 → content-checked warm-up.** `toc` must return rc=0 AND a
  payload starting with `* ` (SQ's `Error: MapOpenFailed(2)` exits
  0; rc alone proved nothing).
- **D2 → proven identity, proven unresponsiveness.** sq-daemon.json
  is written only AFTER confirmation and records pid + /proc start
  time + the shm link/work names; adoption verifies all of them
  (pid-reuse- and daemon-swap-proof). Recovery fires only after a
  daemon believed serving stalls a content-checked op, kills by
  /proc-verified scope (TERM→KILL, start-time-guarded waits), and
  respawns exactly once, behind the gate. Every op is bounded:
  reads and absolute writes get ONE recovery+respawn+retry via
  `_cli`; `insert` (an append) first verifies through `pull`
  whether the append landed, so it is applied exactly once.
- **D3 → no orphans.** `_ensure_daemon` kills its own unconfirmed
  spawn on every failure path, and `cmd_teleport_in` constructs its
  scratch writer inside the try/finally (a failed validation now
  leaves neither daemon nor scratch dir).
- **D4 → read-path hygiene.** `context` shuts the store daemon down
  on exit unless a session is active in that store; `destroy` does
  the same check. `status`/`ls` report a running daemon from /proc
  evidence only — status's 2 s probe client (itself steal-prone) is
  gone. Shared-store slot takeover is by verified signals, not
  client `shutdown`/`status` probes (SQ's `shutdown` doesn't save
  anyway; callers save first).
- **D6 → twins handled.** Adoption finding >1 verified daemon for
  one phext goes straight to clean recovery; settle-before-spawn
  waits for a verified-empty dir.

**New bug found BY the detector suite (not in the Layer 6 list):**
`teleport-in --adopt` renamed the project in shim *state* only —
`.ocbox.json` kept the old name, and every command derives the phext
filename from `.ocbox.json`. After adoption, context/start/exec
addressed a fresh empty `<oldname>.phext` while the teleported
phext sat untouched. (This is exactly what Emise's ~150 B
post-teleport context measurements were reading.) Fix: adoption now
rewrites `.ocbox.json`'s `project` too — the briefing's "local
project renamed" is finally true of all three records.

**Harness fix:** the five suite-verifier `_ensure_daemon` copies
(byte-identical modulo phext name) carried the same probe-race;
all five now use the gated spawn. This mattered in practice — see
the flake record below.

**Verification, all on the final binary:**
- The Layer 6 deterministic repro (3 s delayed `share`): OLD —
  rc=1 after 121.5 s, healthy daemon killed, orphan + scratch dir
  left. NEW — rc=0 in 10.3 s, no stderr, zero leftovers.
- Genuine wedge (SIGSTOP'd daemon): recovery works on both the
  between-commands path (next `exec` recovers in ~63 s and lands)
  and the mid-session path (a stalled `toc` recovers + retries in
  ~63 s; post-recovery write/read verified). The 63 s is one 60 s
  fuse plus respawn — honesty over speed: the fuse only burns when
  a daemon is truly not answering.
- Trivial cycles: 3× start→exec→stop→context with no wedge events;
  mid-session `status` reports `sq daemon: running (pid N,
  recorded)`; after stop+context the store has NO daemon.
- Teleport of the real stress phext (idle box): rc=0 in ~1 s,
  integrity OK, 166 streams verified, nothing left running.

**Detector verdict — the claim stands, and now it's earned.**
`tests/change_detection.sh` (7/7): at small scale, an out-of-band
INSERT and an out-of-band UPDATE (raw `sq` only, saved, raw daemon
shut down) are BOTH named by the next `context`. At stress scale,
the no-change `context` on the teleported 5,198,797 B stress phext
measures **1,001 B of output and 4 channel ops** (warm-up toc, save,
toc, checkpoint pull) — the Layer 5 figure reproduced EXACTLY, once
the adoption bug stopped pointing the measurement at an empty file.
Honest footnotes: a cold store adds one `share` spawn invocation
before the 4 ops; the baseline (first) context on this phext costs
a full hash pass, as Layer 5 recorded. After one out-of-band INSERT
at stress scale, `context` reports **exactly that one coordinate**
(`2.1.1/3.1.1/900.1.1`) — no false positives across 251 scrolls,
so per-scroll content is byte-stable through SQ load/save
round-trips. Residual boundary (SQ's model, documented not fixed):
`context` opens with `save()` through the store's daemon, whose
memory is authoritative — a phext *file* edited directly on disk
while a session daemon is live can be overwritten by that daemon's
next save. Changes driven through the channel (raw sq), or made
while no session daemon is live, are fully detected, as tested.

**Suites on the final binary:** demo PASS · stress 28/28 ·
showcase 14/14 · teleport 10/10 · fix regressions 35/35 ·
change detection 7/7. Post-suite census: zero `sq` processes.
**Flake record (not hidden):** showcase failed ONCE in this layer's
first full pass — its session ran perfectly; the suite *verifier's*
own daemon start died with `verifier could not start the sq
daemon` (the harness race above, 135 s run). The harness fix
followed; showcase then passed 14/14 in 21 s, and demo/teleport/
stress were re-run green after the harness change (their second
consecutive green run on the final writer). No other flakes.
