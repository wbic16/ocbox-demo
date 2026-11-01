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
