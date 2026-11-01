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
  It manages an `sq host` subprocess (free port, `--data-dir` = the
  project's phext store, port/pid recorded in `sq-host.json` in that store
  dir; an existing live host is reused). Session output is inert *data* to
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
| `ocbox exec <command...>` | Run in the session workspace, streaming output live; on exit, flush transcript / stdout / stderr scrolls and return the command's exit code |
| `ocbox status` | Current project, session, workspace, sequence state |
| `ocbox ls` | All sessions across projects known to the shim |
| `ocbox context` | **New command (this integration, not upstream ocbox):** print the phext toc, which coordinates changed since the last `context`, and the latest checkpoint |
| `ocbox stop` | Pre-stop capture (diff → class 5, manifest → class 6, checkpoint → class 8), then mark the session stopped |
| `ocbox destroy` | Delete the session workspace. The phext remains — that is the point |
| `ocbox teleport-in <file.phext>` | **Layer 4:** in a fresh environment, rebuild writer state from a phext file alone and print a resume briefing generated only from phext data (see "State teleportation") |

Every subcommand has `ocbox help <command>` text. The CLI's own exit
codes: 0 on success, 2 for usage/state errors (no project, no active
session, SQ unreachable — each with a specific message); `exec` instead
propagates the wrapped command's exit code, or 128+signum when the
command died by signal (the transcript lane records the raw code and,
for signal deaths, the signal name).

Copy exclusions at `start`: `.git`, `*.phext`, `.ocbox-phext` (the phext
store must never be synced *into* a session), `.ocbox.json`, `__pycache__`,
`node_modules`.

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
(not through the CLI): it pulls `json-export`, groups every coordinate by
class, asserts all eight classes and both registry scrolls are present, and
content-checks the stderr scroll (the failing command's message), the diff
scroll (the created + modified files), the manifest, and the checkpoint
(contains the pre-checkpoint SQ checksum). The full output, verification
included, is in `demo/DEMO-TRANSCRIPT.txt`.

## Known MVP limits

- **Local provider only.** No real remote compute, no `login`/`sync`/
  `snapshot` — the shim implements the lifecycle subset the demo needs.
- **No SQ key locally.** The managed `sq host` runs without `--key` on a
  free localhost port. Set `OCBOX_SQ_KEY` and the CLI starts SQ with that
  key and sends it as the `Authorization` header. (SQ binds `0.0.0.0` —
  don't run a no-key host on an untrusted network.)
- **The checkpoint checksum is the *pre-checkpoint* checksum** — taken
  before the checkpoint scroll itself is inserted, and labelled as such in
  the scroll.
- **`context` delta is MVP-simplified.** It fetches SQ's `/delta` (and
  records its SHA-256), but the changed-coordinate list is computed by
  comparing per-scroll SHA-256 hashes (read exactly, see the next bullet)
  against the delta-state file kept in the store dir — because SQ
  0.6.0's `GET /delta` returns a raw delta phext, not the parsed checksum
  map the README wording suggests.
- **SQ `json-export` is lossy.** It escapes neither tab characters nor
  backslashes inside scrolls: a recorded command line containing a
  literal `\r` (backslash-r) parses back as a real carriage return, and
  literal tabs need lenient parsing (`json.loads(..., strict=False)`).
  The phext itself is byte-exact — so wherever bytes matter, this writer
  reads via `toc` + per-coordinate `select` (`PhextWriter.export_exact`)
  instead, and so do all the verification passes in this repo. (Found by
  the Layer 2 stress run; see POLISH.md.)
- **Binary output costs ~4/3× its size** in the phext (base64), plus the
  header scroll. That is the price of keeping the phext pure text that a
  human can open; the raw bytes' SHA-256 in the transcript keeps it
  honest.
- **Single writer.** Sequence allocation is only safe because one CLI
  process writes a project's phext at a time (SPEC-v0.2 §6).
- **Env lane holds names only** — variable names present plus any names
  referenced in `.ocbox.json` — never values, by design.

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
