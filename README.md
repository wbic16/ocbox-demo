# ocbox-demo — every Session leaves behind a phext

A working Day-One MVP of the **opencloudbox × phext/SQ integration**
(spec: [SPEC-v0.2.md](SPEC-v0.2.md)): run a coding session through an
`ocbox`-shaped CLI, and instead of a log file you get a **phext** — a
structured, addressable record an agent can read selectively (a table of
contents and only the lanes it needs), that survives restarts and machines,
and that a human can open as plain text.

opencloudbox itself is still a specification preview (its docs publish a
locked v0.1 CLI contract but no installable package yet), so this MVP runs
against a **local shim provider**: a "remote Session" here is a workspace
directory on your own machine. The phext half — the part this project
actually owns — is real: it talks to [SQ](https://github.com/wbic16/SQ)
v0.6.0 over its verified HTTP API. When the real `ocbox` CLI ships, a
`RealOcboxProvider` swaps in behind the same interface and the phext writer
does not change.

## Quickstart — run the demo

Prerequisites: Python 3 (standard library only — nothing to install) and an
`sq` binary (found on `PATH`, at `~/.cargo/bin/sq`, or via `OCBOX_SQ_BIN`).

```sh
./demo/run_demo.sh
```

That cleans its own state, then, against a tiny sample repo
(`demo/sample/`: a program that prints and a test that passes):

1. `ocbox init` / `ocbox start` — session `s_xxxx` created, meta + env-names written to the phext
2. `ocbox exec python3 hello.py` — a passing command
3. `ocbox exec python3 -m unittest -v` — the test suite
4. `ocbox exec …` — a command that creates `notes.txt` and modifies `README.md` inside the session
5. `ocbox exec …` — a failing command (exit 3, output on stderr)
6. `ocbox context` — the agent's view: toc, what changed, the checkpoint
7. `ocbox stop` — diff + file manifest + checkpoint captured *before* the session ends

It then verifies the phext with independent SQ reads (every artifact class
present, registries present, stderr/diff/manifest/checkpoint contents) and
tees everything to [`demo/DEMO-TRANSCRIPT.txt`](demo/DEMO-TRANSCRIPT.txt).
The resulting phext is left at `demo/sample/.ocbox-phext/sample.phext`,
with its SHA-256 recorded at the end of the transcript.

Use it interactively from any repo of your own:

```sh
./ocbox init     # writes .ocbox.json in the current directory
./ocbox start
./ocbox exec npm test
./ocbox context
./ocbox stop
```

## What the demo shows

Keyed to the coordinates in
[`demo/DEMO-TRANSCRIPT.txt`](demo/DEMO-TRANSCRIPT.txt) (the demo project
is project **2**, its session is session **1**; only the session's string
id changes between runs):

| Coordinate | What is in it |
|---|---|
| `1.1.1/1.1.1/1.1.1`, `1.1.1/1.1.2/1.1.1` | The registries (reserved project 1): `sample → 2`, and session `s_xxxx → 1` |
| `2.1.1/1.1.1/1.1.1` | Meta lane: session header plus one appended line per exec (`seq`, command, exit code, duration — and signal/encoding flags when they apply) |
| `2.1.1/7.1.1/1.1.1` | Env lane: variable **names** only — `HOME`, `PATH`, … from the demo's sanitized environment |
| `2.1.1/2.1.1/2.1.1` … `5.1.1` | Transcript lanes, one per exec (seqs 2–5): the command line, exit code, per-stream byte counts / SHA-256 / encoding, duration |
| `2.1.1/3.1.1/2.1.1` | Stdout of seq 2 (`python3 hello.py`): `hello, world` |
| `2.1.1/4.1.1/3.1.1` | Stderr of seq 3: `unittest` writes its report to stderr — it lands in class 4, not class 3 |
| `2.1.1/4.1.1/5.1.1` | Stderr of seq 5, the deliberate failure: `something went wrong on purpose`, with `exit: 3` in its transcript lane |
| `2.1.1/5.1.1/1.1.1` | Diff captured *before* stop: `notes.txt` added, `README.md` modified — with a real unified diff for the modification |
| `2.1.1/6.1.1/1.1.1` | Files manifest: every workspace file with size + SHA-256 |
| `2.1.1/8.1.1/1.1.1` | Checkpoint: final seq (5), the pre-checkpoint SQ checksum, and the delta hash — what a resuming agent compares against |
| `context` after `stop` | The delta names exactly the three coordinates stop created: classes 5, 6, 8 — nothing else is re-read |

Beyond the demo, three more recorded runs live in this repo:

- **Stress** — [`stress/run_stress.sh`](stress/run_stress.sh) →
  [`stress/STRESS-TRANSCRIPT.txt`](stress/STRESS-TRANSCRIPT.txt):
  ~4.8 MB of stdout chunked and reassembled byte-exact, binary output,
  the exit-code zoo, 80 sequential execs, spaced/unicode filenames,
  a second session. 28/28 checks pass; the resulting phext is
  5,167,598 bytes carrying 5,167,256 bytes of scroll text — 342 bytes
  of phext structure in total (the coordinate prefixes are
  delta-encoded, so volume is nearly free of overhead).
- **Showcase** — [`demo/showcase.sh`](demo/showcase.sh) →
  [`demo/SHOWCASE-TRANSCRIPT.txt`](demo/SHOWCASE-TRANSCRIPT.txt): one
  session driving ffmpeg (lavfi → H.264/AAC MP4 → 320 px WebM), ffprobe
  JSON, jq (including a malformed-JSON run), sqlite3, git, rg, tar/gzip,
  zip, gcc, node, openssl and a localhost curl fetch. 14/14 checks pass.
- **Teleportation** — [`demo/teleport.sh`](demo/teleport.sh) →
  [`demo/TELEPORT-TRANSCRIPT.txt`](demo/TELEPORT-TRANSCRIPT.txt): see
  "State teleportation" below. 10/10 checks pass.
- **Live cross-machine relay (2026-11-01)** —
  [`demo/LIVE-TELEPORT-TRANSCRIPT.txt`](demo/LIVE-TELEPORT-TRANSCRIPT.txt):
  the same demo run for real across three machines — a session born on a
  cloud VM, teleported to aletheia-core (SQ 0.6.0), continued there,
  teleported to Rock Mountain (SQ 0.5.6), continued there, and brought
  home. One phext the whole way: 3,215 B → 5,856 B → 8,357 B, SHA-256
  verified at every hop; the final artifact is
  [`demo/live-relay.phext`](demo/live-relay.phext).

## Architecture

Two layers, one direction of trust:

- **Provider layer** (`LocalShimProvider`): owns the Session — creating the
  workspace (copying the project in, applying exclusions), running commands
  in it, snapshotting file hashes, destroying it. This is the only layer
  that would change for the real opencloudbox.
- **Phext writer** (`PhextWriter`): the single, trusted-side writer to SQ.
  It drives SQ in **daemon mode**: `sq share <phext>` in the store dir,
  payloads moved byte-exact via `pull`/`push`, small appends via `insert`,
  plus `toc`/`save` (see "Transport" under Known MVP limits for
  why daemon, and GAP-ANALYSIS.md's fix-pass addendum for the measured
  decision). Daemon startup is readiness-gated on the daemon's own log
  (POLISH.md Layer 6 explains why: SQ's channel has no handshake, and a
  client started too early can steal it), identity is /proc-verified,
  and shutdown is by signal — SQ's `shutdown` command doesn't save, and
  its client can hang on a stalled channel. Session output is inert *data* to
  this layer — untrusted output never gets a handle to SQ and never chooses
  a coordinate or a sequence number.

Writer bookkeeping that is *not* phext data — sequence counters, session
records, start-of-session file hashes — lives in a JSON state file under
the shim home (`~/.ocbox-shim/`, or `$OCBOX_SHIM_HOME`). The final counters
are mirrored into the checkpoint scroll at `stop` — which is what makes
the state file *rebuildable from the phext alone* (`ocbox teleport-in`,
see "State teleportation"). The one thing the state file holds that the
phext cannot rebuild is the start-of-session file *contents* used for
unified diffs (hashes are in the manifest; contents re-sync from the
repo).

## Commands

| Command | What it does |
|---|---|
| `ocbox init` | Write `.ocbox.json` (project name) in the current directory |
| `ocbox start` | Start a Session: copy the project into a fresh workspace, register the project/session, write meta (class 1) and env **names only** (class 7) |
| `ocbox exec [--interactive] [--timeout N] <command...>` | Run in the session workspace, streaming output live; on exit, flush transcript / stdout / stderr scrolls and return the command's exit code. stdin defaults to DEVNULL (`--interactive` inherits it); `--timeout N` (or `OCBOX_EXEC_TIMEOUT`) kills the command's process group on expiry and records the timeout |
| `ocbox status` | Current project, session, workspace, sequence state, plus the store's SQ daemon state (from /proc — status starts no SQ client) |
| `ocbox ls` | All sessions across projects known to the shim; projects whose store daemon is running say so |
| `ocbox context [--lane <class>] [--session <int>] [--full]` | **New command (this integration, not upstream ocbox):** print a per-session/class toc *summary* (coordinate + size + clipped preview only with `--full` or a scope filter), which coordinates changed since the last `context`, and the latest checkpoint. A no-change resume on the 5 MB stress phext prints ~1 KB and costs 4 SQ ops (see POLISH.md Layer 5; independently reproduced in Layer 7). Daemon hygiene: `context` shuts the store daemon down again on exit unless a session is active in the store |
| `ocbox stop` | Pre-stop capture (diff → class 5, manifest → class 6, checkpoint → class 8), then mark the session stopped and shut the store's SQ daemon down (`context`/`start` restart it on demand). If the workspace vanished mid-session, the record says so (`workspace: missing at stop`) instead of claiming completeness |
| `ocbox destroy [--force]` | Delete the session workspace. The phext remains — that is the point. Refuses on an *active* session; `--force` first writes a tombstone line into the session's meta lane |
| `ocbox teleport-in [--expect-sha256 <hex>] [--adopt] <file.phext>` | **Layer 4:** in a fresh environment, rebuild writer state from a phext file alone and print a resume briefing generated only from phext data (see "State teleportation"). The incoming phext is validated *before* it is installed (structure, checkpoint consistency, per-stream hashes); the briefing prints the file's SHA-256 and an `integrity: OK / DEGRADED` verdict. A registry name that doesn't match the local project is refused unless `--adopt` is passed; adoption renames the local project in shim state AND in `.ocbox.json`, so every later command addresses the teleported phext |

Every subcommand has `ocbox help <command>` text. The CLI's own exit
codes: 0 on success, 2 for usage/state errors (no project, no active
session, SQ unreachable — each with a specific message); `exec` instead
propagates the wrapped command's exit code, or 128+signum when the
command died by signal (the transcript lane records the raw code and,
for signal deaths, the signal name).

Copy exclusions at `start`: `.git`, `*.phext`, `.ocbox-phext` (the phext
store must never be synced *into* a session), `.ocbox.json`, `__pycache__`,
`node_modules`. **Symlinks are never followed out of the project:**
directory symlinks are not descended; a file symlink is copied as a
regular file only when its resolved target is a file inside the project
(and not excluded); anything else is skipped and recorded in the meta
lane and the stop manifest as `symlink-skipped`.

## Coordinate map

One phext per project: `<project>.phext`, in `<project>/.ocbox-phext/`.
Coordinate = `group1 / group2 / group3`:

- **group1** = `<project-int>.<session-int>.1`
- **group2** = artifact class: **1** meta · **2** transcript · **3** stdout ·
  **4** stderr · **5** diff · **6** files manifest · **7** env ·
  **8** checkpoints — encoded `<class>.1.1`
- **group3** = `<seq>.1.<chunk>` — seq increments per `exec`, chunk is the
  64 KB stdout/stderr chunk index

So project 2, session 1, stdout of the second command, first chunk =
`2.1.1 / 3.1.1 / 3.1.1`.

**Project integer 1 is reserved for the registry** and never assigned:
`1.1.1/1.1.1/1.1.1` is the project registry (`name<TAB>int` lines) and
`1.1.1/1.1.2/1.1.1` the session registry
(`project-int<TAB>session-string<TAB>session-int` lines). Real projects are
numbered from 2.

## Encoding policy (binary output in a text phext)

A phext is text; command output may not be. Per stream, per `exec`,
`ocbox` decides:

- **Valid UTF-8** → stored as text, chunked on byte boundaries backed
  off to character boundaries, so every scroll is ≤ 64 KB when UTF-8
  encoded and concatenating a lane's scrolls reproduces the original
  bytes exactly. (Chunking never depends on lines: a single 250 KB line
  and `\r`-progress output with no newline at all round-trip byte-exact
  in the stress run.)
- **Not valid UTF-8** (binary) → chunk 1 of the lane is a header scroll
  (`ocbox:encoding=base64`, raw byte count, raw SHA-256); chunks 2… carry
  base64 in 64 KB pieces. Decoding the concatenation reproduces the
  original bytes losslessly.
- **Empty stream** → no scrolls; the transcript lane records 0 bytes.

The transcript lane (class 2) always records, per stream: byte count,
SHA-256 of the raw bytes, and the encoding used — so a reader can verify
any lane without trusting the writer. Verified end-to-end in
`stress/run_stress.sh` (cases 4a/4b: `dd` urandom and raw `openssl
rand`).

## State teleportation

A Session's entire state is **one `.phext` file**. Copy that single file
to a fresh machine — fresh shim home, fresh SQ store, no `state.json`,
no workspace — and everything needed to resume is recoverable from the
phext alone:

```sh
# machine B, after cloning the project repo and receiving only the file:
ocbox init
ocbox teleport-in /path/to/received.phext
```

`teleport-in` reads the registry scrolls (project/session integers), the
checkpoint scrolls (final sequence counters), and the manifest, rebuilds
the local writer state, and prints a **resume briefing generated only
from phext data**: project, sessions, the last session's commands with
exit codes (transcript lanes), the files at stop (manifest + diff), the
checkpoint checksum, and the next free session/sequence numbers.
`ocbox context` on a teleported phext also works with zero local state —
its checkpoint is found by scanning the phext itself.

Continuing is then just `ocbox start`: the new session is session
*N*+1 in the same phext, and its meta scroll quotes the teleported
session's id and checkpoint checksum, so the chain A→B is verifiable
from the phext alone. In `demo/teleport.sh`, machine B even recreates
machine A's session-created `note.txt` and its SHA-256 matches A's
manifest entry.

**What teleports:** history (all lanes), context (toc/delta
checkpoints), the registry, sequence counters, and the manifest's file
hashes.
**What does not:** workspace file *contents*. Those re-sync from the
project repo, by design — exactly opencloudbox's model, where the
Project moves explicitly and the provider holds the workspace. The phext
is the session's memory, not its disk.

## How the demo verifies itself

`run_demo.sh` ends with an independent check that talks to SQ directly
(not through the CLI): it shares the phext with its own daemon, reads
every coordinate via `toc` + `pull` (byte-exact), groups them by
class, asserts all eight classes and both registry scrolls are present, and
content-checks the stderr scroll (the failing command's message), the diff
scroll (the created + modified files), the manifest, and the checkpoint
(contains the pre-checkpoint phext checksum). The full output, verification
included, is in `demo/DEMO-TRANSCRIPT.txt`.

## Known MVP limits

- **Local provider only.** No real remote compute, no `login`/`sync`/
  `snapshot` — the shim implements the lifecycle subset the demo needs.
- **Transport: SQ daemon mode (fix pass, 2026-11-01).** The writer uses
  `sq share` + the SQ CLI in the store directory — filesystem-local IPC,
  **no TCP listener, no port, no key**. The earlier HTTP host mode
  (0.0.0.0, keyless unless `OCBOX_SQ_KEY` was set, hosts left running,
  port files adopted unvalidated) is gone; `OCBOX_SQ_KEY` is now
  **ignored** — there is nothing local for a key to protect. The daemon
  is started on demand, proven to be serving (its own log's `Serving`
  line — SQ's shared-memory channel has no handshake, and a client
  started before its daemon can steal the channel and wait forever;
  POLISH.md Layer 6 has the full diagnosis), identity-verified via
  /proc, and shut down by `stop`/`destroy` — and by `context` too,
  unless a session is active in the store. A daemon proven
  unresponsive (alive, not answering) is recovered automatically:
  one verified kill + respawn + retry, then a loud failure. SQ still
  rewrites the whole phext per mutation — that cost is
  transport-independent and unchanged.
- **The checkpoint checksum is the *pre-checkpoint* checksum** — the
  SHA-256 of the phext file after the diff, manifest and lane-map
  scrolls are written and saved, before the checkpoint scroll itself is
  inserted, and labelled as such in the scroll.
- **`context` change detection is local.** It compares per-scroll
  SHA-256 hashes against a store-local `delta-state.json`, seeded from
  the checkpoint's lane-hash map on a teleported phext — SQ's daemon
  `delta` is not used (its semantics differ across SQ versions, and
  daemon `checksum` is per-scroll only). Changed coordinates are listed;
  unchanged lanes are never pulled. Verified out-of-band by
  `tests/change_detection.sh`: mutations made with raw `sq` behind
  ocbox's back (an insert and an update at small scale, a single
  insert at stress scale) are named exactly by the next `context`.
  One boundary: editing the phext *file* directly while a session
  daemon is live can be overwritten by that daemon's next save (its
  memory is authoritative in SQ's model).
- **SQ `json-export` is lossy.** It escapes neither tab characters nor
  backslashes inside scrolls: a recorded command line containing a
  literal `\r` (backslash-r) parses back as a real carriage return, and
  literal tabs need lenient parsing (`json.loads(..., strict=False)`).
  The phext itself is byte-exact — so wherever bytes matter, this writer
  reads via `toc` + per-coordinate `pull` instead, and so do all the
  verification passes in this repo. (Found by
  the Layer 2 stress run; see POLISH.md.)
- **Binary output costs ~4/3× its size** in the phext (base64), plus the
  header scroll. That is the price of keeping the phext pure text that a
  human can open; the raw bytes' SHA-256 in the transcript keeps it
  honest.
- **Single project, serialized writers.** State mutation is serialized
  with an advisory file lock (`state.lock` in the shim home), so
  concurrent `ocbox` invocations queue instead of corrupting state —
  but do not invoke `ocbox` from inside an `ocbox exec` command (it
  would wait on the lock its parent holds). Sequence allocation is
  still per-project (SPEC-v0.2 §6).
- **Env lane holds names only** — variable names present plus any names
  referenced in `.ocbox.json` — never values, by design.
- **Redaction is opt-in and best-effort.** Set `OCBOX_REDACT` to a
  comma-separated list of regexes and matching spans in the recorded
  command line and in stdout/stderr are replaced with `[redacted]`
  before anything is hashed or stored; the count is recorded in the
  transcript. The phext is a *record* — it gets published as demo
  evidence — so don't put secrets in argv in the first place.
- **Teleport integrity has a stated boundary.** `teleport-in` verifies
  structure, checkpoint consistency and every recorded stream hash, and
  prints an `integrity:` verdict; the GAP audit's truncation class
  (40% tail cut) is caught. A truncation confined to the tail of the
  final scroll, where that scroll carries no hash of its own, is not
  detectable from the file alone — use `--expect-sha256` with an
  out-of-band hash when the transfer channel is untrusted.
- **Killing the CLI.** `exec` runs the wrapped command in its own
  process group and forwards SIGINT/SIGTERM to it. `kill -9` of the CLI
  itself cannot be intercepted by any program — the wrapped command
  may survive it; the phext record stays consistent either way (the
  transcript is written last, as the commit record).

## SPEC-DEVIATIONS (fix pass, 2026-11-01 — v0.3 candidates)

SPEC-v0.2.md is unchanged; where the fix pass diverges from or extends
it, the divergence lives here:

- **Lane-hash map scroll (addition).** At `stop`, the writer stores a
  map scroll in the checkpoint class (chunk 2 of the checkpoint seq):
  one `coordinate<TAB>sha256` line per scroll of the session, classes
  1–7. The checkpoint scroll references it (`lane_map_coord`,
  `lane_map_sha256`, `lane_map_scrolls`) and `delta_sha256` is now the
  hash of that map. This is what makes §4 resume cheap and
  teleport-verifiable.
- **Checkpoint per-class counters + chain (closes a §B divergence).**
  The checkpoint carries `max_seq_<class>` for every class and
  `prev_checkpoint_sha256`, chaining each checkpoint to the previous
  one — §3's "final sequence counters per class" and the delta map are
  now actually present.
- **§4 resume mechanism.** Change detection uses the lane-hash map +
  a store-local delta-state file, not SQ's `delta` endpoint or ranged
  `query` (daemon `delta` semantics diverge across SQ versions;
  `query` is unnecessary once the map is in the phext). The §4
  *outcome* — resume reads a toc and a delta, not the whole log — is
  met and measured (POLISH.md Layer 5).
- **Transport.** SPEC §0/§2 assume SQ's HTTP API and per-project keys.
  The implementation uses SQ daemon mode (local IPC); keys do not
  apply locally. If a networked SQ deployment is ever targeted, the
  key story returns with it — and, per the Submilli Route A invariant,
  the key must then live only on the trusted side of the writer.
- **Sequence counter location.** Still in writer state mid-session
  (mirrored to the checkpoint at stop, and recoverable from the lanes
  at teleport-in); the §B compromise stands.

## Re-pointing at the real ocbox CLI later

1. Implement `RealOcboxProvider` with the same four operations the shim
   provider exposes (`create_workspace`, `run`, `snapshot`, `destroy`)
   backed by the real `ocbox start`/`exec`/`stop` lifecycle and the
   provider's workspace.
2. Point `start`'s snapshot at the real session's start state and `stop`'s
   pre-stop capture at a live session, exactly as now.
3. Nothing else moves: the registry, coordinate map, chunking, checkpoint
   and `context` are all provider-independent.

## Files

- `ocbox` — the whole CLI (single file, Python 3 stdlib only)
- `SPEC-v0.2.md` — the checked integration spec this MVP implements
- `POLISH.md` — the Layer 1–4 polish/stress log: tests, bugs, fixes, policies
- `demo/sample/` — tiny demo repo · `demo/run_demo.sh` — the demo driver ·
  `demo/DEMO-TRANSCRIPT.txt` — the recorded, verified run
- `demo/showcase.sh` + `demo/SHOWCASE-TRANSCRIPT.txt` — the real-tool
  gauntlet (Layer 3) · `demo/teleport.sh` +
  `demo/TELEPORT-TRANSCRIPT.txt` — state teleportation (Layer 4)
- `stress/run_stress.sh` + `stress/STRESS-TRANSCRIPT.txt` — the stress
  gauntlet (Layer 2); the stress/showcase/teleport `.phext` files are
  kept as evidence under their (otherwise gitignored) state dirs
- `tests/fix_regressions.sh` — the fix-pass regression suite (Layer 5):
  one assert group per GAP-ANALYSIS finding
- `tests/change_detection.sh` — the out-of-band mutation suite
  (Layer 7): raw-`sq` insert/update behind ocbox's back at small and
  stress scale, plus the measured no-change context (1,001 B / 4 ops)
- `GAP-ANALYSIS.md` — the audit, with dated addenda: transport
  decision, per-gap resolutions, before/after measurements, and the
  Layer 7 lifecycle cluster (L1–L8)
