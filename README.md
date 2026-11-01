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
are mirrored into the checkpoint scroll at `stop`.

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
  comparing per-scroll SHA-256 hashes from `json-export` against the
  delta-state file kept in the store dir — because SQ 0.6.0's `GET /delta`
  returns a raw delta phext, not the parsed checksum map the README
  wording suggests.
- **SQ `json-export` quirk:** it does not escape tab characters inside
  scrolls, so consumers must parse it leniently (Python: `json.loads(...,
  strict=False)`). This writer does.
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
- `demo/sample/` — tiny demo repo · `demo/run_demo.sh` — the demo driver ·
  `demo/DEMO-TRANSCRIPT.txt` — the recorded, verified run
