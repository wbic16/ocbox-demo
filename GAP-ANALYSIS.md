# GAP ANALYSIS — ocbox × phext MVP

Audit date: 2026-11-01. Method: full read of `ocbox` (977 lines),
SPEC-v0.2.md, README.md, POLISH.md, and the five transcripts, plus live
probes (P1–P13) run in throwaway dirs under /tmp with per-case
`OCBOX_SHIM_HOME`s, cleaned up afterward. Repo state untouched.

Severity scale: **blocker** = breaks the demo/intro claim on a realistic
path · **major** = silent data loss, silent wrong state, or a spec
commitment missing where it matters · **minor** = rough edge, honest
failure, or narrow precondition.

**No blockers found.** The happy path is as strong as the transcripts
claim (see §D). Everything below is about what happens off it.

---

## A. Confirmed gaps

### A.1 Verified by probe

| # | Gap | Severity | Evidence | Fix sketch |
|---|-----|----------|----------|------------|
| P9b | **Symlink escape at `start`**: a directory symlink inside the project pointing *outside* it is followed and its contents copied wholesale into the workspace (file symlinks too). The workspace copy is the shim's stand-in for "files synced into the untrusted Session" — a repo containing `innocent -> ~/.ssh` would ship the keys into the session. Nothing in the copy path checks that a resolved path stays under the project root. | major | Probe project with `escape -> /tmp/.../outside` (held a marker file): marker content present at `workspace/escape/key.txt` after `start`; its hash recorded in the stop manifest. | In `create_workspace`, resolve every entry and refuse/skip anything whose real path leaves the project root (the `excluded()` helper already does resolved-path checks for two paths — generalise it to root containment). Copy symlinks *as* symlinks or skip them; never follow dir links. |
| P9a | **Symlink loop crashes `start`** with an unhandled `shutil.Error` traceback (exit 1, not the CLI's exit-2 error style) after building a deep partial recursive copy in the workspace. Partial workspace is orphaned (no state entry; `ls` can't see it; disk leak). | major | Probe: `loop -> ..` in project root → `Errno 40 Too many levels of symbolic links`, traceback from `create_workspace`, workspace left holding `loop/proj/loop/proj/…`. | Same fix as P9b (not following dir symlinks removes the loop case too); also wrap copy errors in `die()` and remove the partial workspace on failure. |
| P1 | **Concurrent `exec` loses data and crashes.** Two shells running `exec` on one session: both processes share one fixed temp filename in `State.save()` (`state.tmp`), one save's `os.replace` races the other's → `FileNotFoundError` traceback in one CLI; that exec's output **never reaches the phext** (0 occurrences vs the winner's 3); both had also allocated from the same `last_seq`. SPEC §6 documents the single-writer rule, but the failure mode is silent record loss + traceback, not a clean refusal. | major | Probe: two parallel `exec "sleep 1; echo FIRST/SECOND"` — phext contains exactly one meta exec line (seq=2) and only FIRST's output; loser died in `State.save()`. | Take an advisory lock (`flock` on a lockfile in the shim home) around state read-modify-write and seq allocation, or fail fast with "another ocbox process is writing" (exit 2). Per-process temp names (`state.tmp.<pid>`) fix the crash but not the seq collision — do both. |
| P2 | **`teleport-in` of a checkpoint-less phext lies about the session.** A phext copied mid-session (no checkpoint — exactly the "stream my state" case) teleports in with rc=0; the rebuilt state marks the session `status: stopped` (it never stopped), resets `last_seq` to 1 while the phext holds seq 2, and the briefing prints `next_seq_for_last_session: 2` — the coordinate of an existing transcript. No warning anywhere that the session was live/incomplete. | major | Probe: start + 1 exec, copy phext pre-stop → teleport-in rc=0; rebuilt state shows `stopped / None / last_seq 1`; briefing session line reads "stopped ?, final_seq ?" but the state file says stopped. | In `teleport_in`, sessions without a checkpoint scroll get status `interrupted` (or `unknown`), `last_seq` derived from the max transcript seq actually present, and the briefing prints a visible `⚠ no checkpoint — session may be incomplete` line. |
| P3a | **`teleport-in` performs no integrity verification — a truncated phext is accepted as complete.** With the last 40% of the file cut (diff/manifest/checkpoint gone), teleport-in returns rc=0 and a confident briefing (silently "0 files"). The phext already carries per-stream SHA-256s in transcript scrolls and a checkpoint checksum chain; none of it is checked on the way in. | major | Probe: 1,418 B phext truncated to 850 B → rc=0, briefing lists both commands, manifest shown as 0 files, checkpoint shown as "?" with no error. | Add verification to `teleport-in`: recompute each transcript's recorded stream hashes against the lanes present; require a checkpoint per session (or report which sessions lack one, cf. P2); print a `integrity: OK / DEGRADED (details)` verdict line. Refuse (or `--force`) below a threshold. |
| P4 | **`teleport-in` silently adopts a *different* project's phext when the registry holds exactly one project.** If the local `.ocbox.json` name doesn't match the registry name, the single-project fallback (`elif len(proj_reg) == 1`) adopts that project's integer and lanes under the local name — the file is installed as `<local-name>.phext` and the briefing presents the other project's history as this project's. With ≥2 registry projects it dies cleanly, so the common one-project case is precisely the unguarded one. | major | Probe: phext from project `proj` teleported into a project named `totally-different` → copied to `totally-different.phext`, briefing header "project: totally-different (int 2)" over the other project's session. | Drop the silent adoption: name mismatch → die with both names shown, plus an explicit `--as <name>` / `--force` escape hatch for deliberate renames. |
| P6 | **Managed SQ host identity is never validated.** `_ensure_host` trusts any process on the port recorded in `sq-host.json` whose `/api/v2/version` starts with `0.` — the recorded `pid` and `data_dir` are written but never read. A stale port file (port since reused by another store's host, or anything that answers version) makes every command read/write the *wrong* phext store while reporting success. | major | Probe: `sq-host.json` planted with port of a fake server (pid 999999, data_dir `/somewhere/else`) answering "0.6.0" → `ocbox context` rc=0, printed the fake body as the toc, and recorded a delta baseline against garbage. | Validate the recorded pid is alive and its cmdline contains `sq host` + this store's `--data-dir` before reuse; otherwise spawn fresh. Cheap belt: also compare `GET /api/v2/status` output if SQ exposes the data dir. |
| P10 | **`context` is not economical at scale — the agent's front door dumps content and re-reads everything.** On the 5.17 MB stress phext (250 scrolls): `context` prints **352,836 bytes** (toc section alone 352,348 B — SQ's toc "preview" of a 64 KB chunk scroll is the whole scroll; longest line 65,557 B), i.e. ~7% of the entire log before the agent selects anything. Worse, the changed-coordinate computation calls `export_exact()` — 1 toc + **250 `select`s**, pulling all 5.17 MB over HTTP — and in the stateless case (teleported phext, no local state: exactly the resume case this feature exists for) the checkpoint scan calls `export_exact()` **a second time** (~503 requests, ~10.3 MB pulled) to answer "no changes." A no-change resume costs a full re-read; the delta mechanism saves nothing yet (POLISH.md notes the O(scroll) design; this is its measured price). | major | Probe: copied stress phext to /tmp project; `context` run 1 = 352,836 B out, 265 lines, 0.49 s; run 2 (nothing changed) still 0.42 s and full export behind a correct "No coordinate changes" line. Longest toc line measured 65,557 B. | (1) Truncate toc previews client-side (or fetch coordinates via toc and print coord + size only) — target ≤ ~10 KB for 250 scrolls. (2) Persist per-lane checksums *in the phext* at stop (one checksum scroll per session) so resume = select checkpoint + checksum scroll, compare locally, then ranged-`query` only changed lanes — i.e. implement SPEC §4's original delta design. (3) Cache `export_exact()` within a single `context` run (one call, not two). |
| P11a | **The managed `sq host` binds 0.0.0.0 and runs with no key by default, and is never shut down.** SQ itself binds all interfaces (SPEC §0 noted it); the writer starts it keyless unless `OCBOX_SQ_KEY` happens to be set, so on any shared/networked machine anyone who can reach the port can read *and overwrite* the session phext during and after the run. README discloses this ("don't run a no-key host on an untrusted network") but the CLI never warns, and there is no `ocbox` command to stop the host — at audit time **18 `sq host` processes** were alive on this machine, leftovers from the repo's own demo/live runs and these probes. | major (networked machines) / minor (single-user laptop) | Probe: `ss -ltn` shows `0.0.0.0:<port>` LISTEN after `start`; host persists after `stop` and after CLI exit; `ps` count of `sq host` = 18. | Default to a generated per-store key (stored 0600 in the store dir) even locally, print one warning line when starting a keyless host, and add host shutdown on `destroy` / an `ocbox host stop` — or at minimum document `kill $(cat sq-host.json pid)` in README's limits. |
| P8 | **`stop` reports a "complete" record for a vanished workspace.** Delete the workspace mid-session, then `stop`: rc=0, "Phext record complete", diff = everything deleted, manifest = empty. A destroyed/corrupted workspace and a session that genuinely deleted all its files are indistinguishable in the record. | minor | Probe: `rm -rf` workspace between exec and stop → clean stop, no warning. | In `cmd_stop`, if the workspace path doesn't exist, die (or require `--force`) with a message naming the missing path; an all-deleted diff on an *existing* empty workspace stays legal. |
| P12 | **Killing the CLI mid-`exec` orphans the wrapped command and leaves no trace.** `kill -9` on `ocbox exec "sleep 20"`: the shell+sleep keep running in the workspace (observed alive after the CLI's death); the session stays `active` with `last_seq` un-advanced; when the orphan later writes files, `stop`'s diff shows changes no transcript explains. Recovery is otherwise good — a later `exec` and `stop` both work (see §D). | minor | Probe: orphan `/bin/sh -c sleep 20` + `sleep 20` PIDs alive ≥1 s after CLI kill; state shows active/last_seq 1; subsequent exec rc=0, stop OK. | Spawn the wrapped command in its own process group and record a "running" marker scroll at exec start (cleared on flush); on `start`/`status`, surface a stale running marker. At minimum, document that the wrapped command is not killed with the CLI. |
| P5 | **`exec` inherits the CLI's stdin and has no timeout.** A command that reads stdin consumes the caller's stdin (agent drivers, pipes) directly; an interactive or stuck command hangs `ocbox exec` indefinitely — there is no `--timeout`, env knob, or signal forwarding story beyond killing the CLI (which orphans the command, P12). | minor | Probe: `printf "hello-stdin\n" \| ocbox exec 'read line; echo got:$line'` → `got:hello-stdin`. | Default wrapped stdin to DEVNULL (with `--stdin` to opt into inheritance) and add `OCBOX_EXEC_TIMEOUT` / `exec --timeout` that kills the process group and records the timeout in the transcript like a signal death. |
| P7 | **`start` with SQ unavailable leaves a phantom active session.** State is saved (session marked active, workspace copied) *before* the writer is constructed; when the writer dies (SQ missing/down), `start` exits 2 but every later `start` refuses ("already active") and `status` shows a normal active session whose phext has no meta/env lanes. It heals if SQ returns (a later `stop` completes the record), but nothing flags the half-written state in between. | minor | Probe: `OCBOX_SQ_BIN=/nonexistent` → start rc=2, state.json already lists the session active; second start rc=2 "already active". With SQ restored, stop rc=0. | Construct the writer (or at least probe SQ) *before* saving state; or mark the session `status: unregistered` until `ensure_registry` + meta writes succeed, and have `status` say so. |
| P13 | **Phext-filename collisions silently merge projects.** `safe_phext_name` maps both `a b` and `a-b` to `a-b.phext`; with a shared `phext_store` (a supported config key) two different projects land in one phext file with a two-name registry. Lanes don't collide (project ints differ) but "one phext per project" quietly stops being true, and `context`/`teleport-in` on either project see both histories. | minor | Probe: projects `a b` and `a-b` sharing one store → single `a-b.phext` containing registry lines `a b\t2` and `a-b\t3` and both sessions' lanes. | Detect an existing phext whose registry names a different project for the same filename and die with both names; or make the safe-name mapping injective (e.g. percent-encode). Default per-project stores make this opt-in, hence minor. |

### A.2 Found by reading (not probed)

| # | Gap | Severity | Evidence (code) | Fix sketch |
|---|-----|----------|-----------------|------------|
| R1 | **`OCBOX_SQ_KEY` is silently ignored whenever a host is reused.** The key is passed at spawn (`--key`) and sent as `Authorization` on requests — but if `sq-host.json` points at a live host started *without* a key (or with another key), `_alive()` succeeds and the writer proceeds keylessly. Setting the env var later changes nothing and says nothing. Separately, when a key *is* used, it appears in the `sq host` command line — visible to any local user via `ps`. | minor | `PhextWriter._ensure_host` reuses on `_alive()` alone; probe-adjacent: `context` with `OCBOX_SQ_KEY=probe-secret` against a running no-key host returned rc=0 with full toc. `--key` visible in `ps` output during P11. | On reuse, if `self.key` is set and the running host doesn't challenge (version answers without auth), kill/respawn our own host with the key, or die saying the existing host predates the key. Long-term: SQ-side fix (key via env/file, not argv) — file it against SQ. |
| R2 | **`destroy` on an *active* session silently discards the un-captured session.** `cmd_destroy` uses `need_active=False` and never checks `status == "stopped"`; destroying a live session deletes the workspace with no diff/manifest/checkpoint ever written — the phext keeps lanes that end mid-air, indistinguishable from a crash. SPEC §3 frames destroy as a separate, deliberate step after stop. | minor | `cmd_destroy` in `ocbox` (no status guard). | Refuse to destroy an active session without `--force`, and say what will be lost; with `--force`, write a tombstone line into the meta lane first. |
| R3 | **Non-idempotent writes are retried blindly.** `_req` retries any non-HTTP exception up to 10× — including POST `insert` (append). If SQ applied the insert but the response was lost, the retry duplicates the scroll content (registry lines are deduped by `ensure_registry`'s line check, but meta-lane exec lines are not). | minor | `PhextWriter._req` retry loop; `insert` semantics per SPEC §0 (append). | Retry only idempotent reads + `update`; for `insert`, verify-then-retry (select the coordinate and check the tail) or accept-and-document. Narrow window (localhost), hence minor. |
| R4 | **No redaction hook anywhere.** Transcript lanes store command lines verbatim and stdout/stderr verbatim: a token passed as a CLI argument (`curl -H "Authorization: Bearer …"`) or printed by a command is persisted in the phext, echoed in `context`'s toc previews, and — the real footgun — published if that phext is committed as demo evidence. SPEC §5 covers env values (excluded) but is silent on argv/stdout secrets; the tool inherits the silence. | minor (documented-risk) | grep: no redact/filter code in `ocbox`; transcripts confirm verbatim command storage (by design). | Add an opt-in `OCBOX_REDACT` (comma-separated regexes) applied to transcript + stream text before insert, and a README warning: "the phext is a record — don't put secrets in argv; demo phexts get published." |
| R5 | **Project identity is the absolute path.** State is keyed by `str(root)`: moving/renaming a project directory orphans its session state (phext intact, sessions "forgotten"; `teleport-in` is the unadvertised recovery). | minor | `State.project(root)` keyed on `str(root)`; `state.data["projects"][str(root)]`. | Key state by phext-store path or project name + store, falling back to a phext-side lookup (registry) when the path key misses. |
| R6 | **Exec flush is not atomic and burns the sequence number before writing.** `cmd_exec` increments `last_seq` and saves state *before* any phext write; a writer failure mid-flush (SQ dies between transcript and stream inserts) leaves a seq with partial lanes and no marker, and the transcript scroll is written twice (before/after encoding backfill), so a crash between the two updates leaves a transcript missing its encoding lines. | minor | `cmd_exec` ordering: `state.save()` precedes `writer_for(...)`; transcript `w.update` called twice per exec. | Write streams first, transcript last (it is the commit record — its SHA-256s already describe the streams); only advance `last_seq` after the transcript lands. A seq whose transcript is absent is then recognisably incomplete. |

---

## B. Spec divergences (SPEC-v0.2 vs implementation)

| Spec | Implementation | Assessment |
|------|----------------|------------|
| §3 checkpoint carries "the session's final sequence counters **per class**" and "the `delta` hierarchical checksum map" | Checkpoint scroll carries a single global `final_seq`, the whole-phext `pre_checkpoint_checksum`, and `delta_sha256` — a *hash of* the delta output, not the map; no per-class counters. (Verified in all transcripts' checkpoint scrolls.) | **minor divergence.** The map's absence is partly forced (SQ's GET /delta doesn't return a parsed map — POLISH.md), but per-class counters are free to add and would let a resumer detect a missing/truncated lane class without a full scan. Add both counters and the previous checkpoint's SHA-256 (see C/E4). |
| §3 sequence counter "kept in the session's meta lane" | Counter lives in `state.json`; mirrored into the checkpoint at stop. Mid-session, the phext itself does not know the current seq — one reason P2's rebuild guesses wrong. | **minor divergence**, deliberate per README ("writer bookkeeping"), but it is what makes checkpoint-less teleports lossy. Writing the counter into the meta lane per exec is one extra insert per exec — expensive under whole-file rewrites; a fair compromise is a `last_seq` line appended to meta *at stop and at each checkpoint-worthy event*. |
| §5 "For multi-tenant sessions use SQ Router mode with a token per tenant" | No router-mode code path, config, or mention in the implementation. | **Noted, not a defect of the shim**: the requirement is conditional on multi-tenant sessions, which a single-user local shim never has. It becomes a real gap the day the writer is shared — flag it in the spec's MVP scope so the intro doesn't overclaim. |
| §6 "Sequence exhaustion: roll to the next class group, or compact at checkpoint" | Neither implemented; seq is an unbounded int in the chapter slot. | **Trivial divergence** — spec itself calls exhaustion theoretical. Compact-at-checkpoint is still worth having for a different reason (phext size), see C. |
| §4 agent resume via `delta` map diff + ranged `query` lane pulls | `query` is **never used** anywhere in the code; resume = full `export_exact` + local hash diff (measured in P10). | **The §4 protocol is unimplemented as designed** — the largest spec/impl gap, and the cheapest big win available (C/E3). The current mechanism produces correct answers at O(everything) cost. |
| §2 "One key per project" | One key per *environment* (`OCBOX_SQ_KEY`), applied per store at spawn; reuse hole at R1. | Close enough for a local MVP; the per-project framing matters only in managed mode. Note in spec. |
| §0 contract commands `login, snapshot, sync push/diff/pull, env set, agent setup/doctor, start --repo` | Absent (README discloses "lifecycle subset"). Present: init/start/exec/status/ls/stop/destroy + context + teleport-in. | **Which absences matter for the integration story:** `sync diff` — its *output* is class 5's content in the real product; here the same computation exists but is trapped inside `stop` (extracting it as a command is small and makes the demo story match the contract). `env set` — the env lane currently records the *writer process's ambient env names* plus `.ocbox.json` lists; there is no way to declare a workload-secret reference except hand-editing config, so class 7's spec meaning ("references declared for the session") is only approximated. `snapshot` — matters to the preservation story (stop currently keeps the local workspace; nothing exercises provider-policy preservation). `login`, `agent setup/doctor`, `--repo` — provider plumbing the shim can honestly skip. |
| Provider seam (README "Re-pointing", step 1: "implement `RealOcboxProvider` with the same four operations") | The four methods exist, but their *shapes* assume a local filesystem: `snapshot(workspace: Path)` walks the workspace with `rglob`; unified diffs depend on `startcopy`, a local byte-copy of the workspace; `run()` returns both streams as in-memory `bytes` (whole output buffered twice — pump buffers plus `bytes()` copies — so a multi-GB output is a RAM problem, and there is no spool/chunk callback); `run()` has no timeout, stdin, env, or cancellation parameters; `create_workspace` is a full copy with no delta/sync hooks. | **The writer seam is exactly where the spec says it is; the provider seam is not.** A real provider's workspace is remote: snapshot/manifest must be computed inside the session (via exec) or via a provider API, and output arrives as a stream. "Same four operations" understates the port: expect `snapshot` and `run` to change shape (async/iterator + remote manifest call). Worth one honest paragraph in README's re-pointing section — for the intro audience, an accurate seam story is a feature, not a confession. |

---

## C. Enhancement proposals (ranked by intro-value ÷ effort)

| # | Enhancement | Pitch | Why it matters for the intro | Effort |
|---|-------------|-------|------------------------------|--------|
| E1 | **Record the 90-second demo** (asciinema → gif/svg in README) | SPEC §7's original Day-One ask is still unmet: the repo has transcripts, no recording. `demo/teleport.sh` output is already scripted and timed; recording it (plus 20 s of the live relay) gives the intro a watchable artifact instead of homework. | Highest: it's the difference between "read my transcript" and "watch state teleport." | S |
| E2 | **`ocbox export`** — render a session (or whole phext) to a human-readable Markdown log | The spec's founding claim is "a human can open the same file." A phext *is* openable, but a one-command render (commands, exits, outputs, diff, manifest — with base64 lanes decoded to files) proves it in the form a human actually reads, and doubles as the PR/blog format. | High: gives non-phext readers a door; every future demo gets a readable artifact for free. | S |
| E3 | **Implement SPEC §4 resume properly**: per-session lane-checksum scroll written at stop + `context --lane <class>` / truncated toc + ranged `query` pulls | Turns P10's 353 KB / 503-request resume into ~2 selects + changed lanes only. This *is* the product claim ("reads a toc and a delta instead of the whole log") — currently the one claim the implementation doesn't yet cash. | High: makes the headline efficiency claim true at 5 MB+ scale, with before/after numbers for the intro. | M |
| E4 | **Checkpoint chain + `teleport-in --verify`** | Checkpoint scroll gains `prev_checkpoint_sha256` (hash of the previous checkpoint scroll — the meta lane already quotes its checksum; move the chain into the checkpoints themselves), and teleport-in verifies transcript stream hashes + chain continuity and prints an integrity verdict. Fixes P2/P3a's silent-degradation class and gives the relay demo a "tamper-evident" line no log-shipping tool can match. | High: converts three audit findings into a selling point. | S–M |
| E5 | **`ocbox replay`** | Re-run a recorded session's commands (from transcript lanes) in a fresh workspace and diff exit codes/output hashes against the record. | Medium-high: "the session is an executable artifact" is a demo nobody else has; also a regression harness for the tool itself. | M |
| E6 | **MCP wrapper for `context`/`select`** | Expose the phext as MCP tools (context, select, toc) so any MCP-speaking agent can resume a session without shelling out. opencloudbox's own surface includes hosted MCP; Will already has phext-mcp in his repos to crib from. | Medium-high: speaks directly to the opencloudbox team's own architecture slide. | M |
| E7 | **Batched/deferred flush** (`exec --batch` or writer-side insert coalescing) | Attack the measured top cost (POLISH.md: ~24 s for the 81-exec/5 MB session, dominated by SQ whole-file rewrites — ~180 writes × growing file). Even a stop-time batch for chunk inserts cuts most of it; measure before/after on the stress case. | Medium: removes the first scaling objection an evaluator will raise. | M |
| E8 | **Class 9: notes / handoff lane** | A dedicated lane (`ocbox note "…"`) for agent→agent and agent→human messages inside the session record — the natural place for a resume briefing, a "next steps" note, or the sending agent's intent at teleport time. | Medium: cheap, and it's the feature every multi-agent user asks for the moment they see teleportation. | S |
| E9 | **CI on the repo** (GitHub Actions: run demo + stress + teleport verifiers on push) | The transcripts are point-in-time; CI turns "52/52" from a claim into a badge that stays true. Needs SQ installed in the runner (cargo install or the Docker image) — the only real work. | Medium: credibility infrastructure for exactly the audience that will check. | S–M |
| E10 | **Redaction patterns** (`OCBOX_REDACT`, see R4) | Regex list scrubbed from transcript/stream text before insert; ship with the README warning about argv secrets and published phexts. | Low-medium for the intro, high for real adoption; prevents the worst footgun in the current design. | S |

---

## D. Checked and NOT gaps (don't re-audit these)

- **Env lane values**: names only, verified — the published demo phexts' env scrolls contain zero `=` and the demo driver sanitises its environment. Ambient-name collection (writer's shell, not a declared session env) is a semantic quirk noted in §B, not a leak.
- **Encoding policy**: byte-exact as advertised — stress cases 1–5 (chunk math ⌈bytes/65536⌉, reassembly SHA-256, base64 round-trip, single 250 KB line, `\r` progress) all re-verified in the recorded transcripts; chunking is byte-based and line-independent.
- **SQ 0.5.6 compatibility**: the code uses version/toc/select/checksum/delta/json-export/insert/update — all present in 0.5.6; the full lifecycle ran live on Rock Mountain's 0.5.6 in the relay. `query` (the one endpoint 0.5.6 lacks) is never called.
- **Crash recovery of session state** (beyond P12's orphan): after `kill -9` mid-exec, the session remains usable — later `exec` and `stop` succeed and the record completes. No state-file corruption (atomic tmp+replace in the single-process case).
- **Registry collision fix from SPEC §1**: project int 1 is genuinely reserved in code (`next_proj_int` starts at 2; registry coords are constants) and in all recorded phexts.
- **Sync exclusion of the phext (§1)**: enforced twice — `.ocbox-phext` is in `EXCLUDE_DIRS` at copy time *and* the resolved store path is passed as a path exclusion (so a renamed store is still excluded), plus `*.phext` files are excluded at every depth in both copy and snapshot. Verified in code and consistent with all transcripts. (What is *not* excluded is the subject of P9b: symlinks pointing out.)
- **Pre-stop capture order (§3 FIX)**: diff/manifest/checkpoint are written while the session is live, before the state flips to stopped — matches the corrected spec, visible in `cmd_stop`.
- **Class 2 transcript semantics**: implementation is a *superset* of §3 (command, exit, signal, per-stream bytes/SHA-256/encoding, duration, timestamp) — richer than spec, not divergent in any harmful direction.
- **`stop` failure atomicity**: if the delta fetch dies mid-capture, `stop` aborts before the checkpoint and before the state save (the `SystemExit` is deliberately re-raised), leaving the session active and retryable.
- **teleport-in name mismatch with ≥2 registered projects**: dies cleanly with both the local name and the registry contents (the P4 hole is specifically the 1-project fallback).
- **Garbage phext to teleport-in**: a delimiter-less text file is rejected (exit 2, "not in this phext's registry") — though note it is *copied into the store before* validation runs, so a failed teleport-in still replaces the store's phext file. Minor wart, recorded here rather than in §A because the error itself is clean; worth a copy-to-temp-then-swap fix alongside P4.
- **Whole-file rewrite cost** and **json-export lossiness**: already documented in POLISH.md/README as known limits — not re-reported as findings; P10/E3/E7 build on them.

---

*Probes P1–P13 were run against the published `ocbox` at
`~/workspace/ocbox-phext/ocbox` (977 lines) on 2026-11-01, SQ v0.6.0
locally. All probe state lived under /tmp/audit and was removed; the
`sq host` processes belonging to probe stores were killed (pre-existing
ones from the repo's own runs remain — see P11a).*


---

# Addendum — Fix pass (2026-11-01)

Directed by Will: "fix the bugs and consider using sq in daemon mode."
Implemented the same day; SPEC-v0.2.md unchanged (divergences are
recorded as SPEC-DEVIATIONS in README.md, as v0.3 candidates).
Regression coverage: `tests/fix_regressions.sh` (35 asserts). Final
suite results against the fixed binary: demo **PASS**, stress
**28/28**, showcase **14/14**, teleport **10/10**, fix regressions
**35/35**.

## Transport decision: SQ daemon mode (daemon-only, no host fallback)

The writer now drives SQ exclusively through its daemon:
`sq share <phext>` in the store directory, scroll bytes via `pull`/
`push` (byte-exact), small appends via `insert` argv, plus `toc`,
`save`, `shutdown`. The HTTP host code path was removed, not kept.

Measured per-op latency (median of ~20 runs, existing 250-scroll /
5.17 MB stress phext, SQ 0.6.0 local):

| op | HTTP host | daemon CLI |
|---|---|---|
| update small scroll | 2.97 ms | 1.69 ms |
| update/insert 64 KB | 2.66 ms | push 1.77 ms |
| insert small | 3.19 ms | 2.56 ms (argv) |
| select 64 KB scroll | 0.6 ms | 1.65 ms (pull to file 2.24 ms) |
| toc (250 scrolls) | 8.37 ms | 12.84 ms |
| whole-phext checksum | 1.1 ms | **no such op** (per-scroll only) |
| delta | 9.3 ms | **no no-arg form** (prints usage) |

Deciding factors, in order:

1. **Trust surface.** The daemon is filesystem-local IPC scoped to the
   store directory: no TCP listener at all, no 0.0.0.0 keyless port, no
   port/pid file to adopt blindly. P6 and P11a die by construction.
   `OCBOX_SQ_KEY` becomes irrelevant locally (documented in README).
2. **Lifecycle.** `stop` ends with `sq shutdown`; the daemon is also
   shut down by `destroy --force`. Nothing is left listening or running
   after a session closes.
3. **Cost parity.** Per-op latency is the same order as HTTP (the old
   writer already made one HTTP request per op). Daemon facts that
   shaped the implementation: mutations live in daemon memory until
   `sq save` (cheap — 4 ms on the 5 MB phext — so the writer saves once
   per command, after its writes); `sq select` to stdout appends a
   trailing newline, so payloads move via `pull`/`push` files only;
   daemon `checksum` is per-scroll and `delta` differs across SQ
   versions (0.5.6 vs 0.6.0 semantics diverge), so whole-phext identity
   is the SHA-256 of the phext file after save — computed by the writer,
   not delegated to SQ.
4. **Compatibility.** The needed CLI ops (share/status/insert/select/
   push/pull/toc/save/shutdown, per-scroll checksum) were verified live
   against SQ **0.5.6** on rock-mountain (a ranch node), not just 0.6.0
   locally. argv limits checked: a 64 KB chunk (~87 KB base64) passes
   as a single argument; larger appends go pull+concat+push.
5. **Not claimed:** SQ's whole-file rewrite per mutation is
   transport-independent and unchanged. One daemon serves one phext;
   in a shared multi-project store dir the writer takes the single
   daemon slot over (the displaced project's next command restarts its
   own daemon; phext files are never touched by the takeover).

**Daemon robustness findings (new, from this pass).** SQ's daemon IPC
wedges intermittently: a live `sq share` process whose clients block
forever. The wedge correlates with clients killed by short timeouts
while the daemon is loading or busy — including, in early iterations of
this pass, our own `sq status` probes. The writer therefore: decides
daemon existence from `/proc` (cmdline + cwd, never from a probe),
proves liveness with ONE long-fused warm-up op (`toc`, 60 s) instead of
probe loops, settles (zero store daemons, no `.sq` dir) before
spawning, and recovers a wedged daemon scoped to its own store
(SIGKILL verified store processes only, clear `.sq`, respawn — one
retry, then a loud death). `shutdown()` escalates CLI → SIGTERM →
SIGKILL so `stop` really stops it. Under this discipline the full
suite set passes end-to-end; under heavy concurrent machine load a
single regression-suite assert has occasionally flaked and passed on
rerun (noted honestly; the demo/stress/showcase/teleport verifiers use
the same settle discipline).

## Resolutions

| # | Status | Fix + evidence |
|---|--------|----------------|
| P9b symlink escape | **RESOLVED** | `create_workspace` walks with `followlinks=False`; dir symlinks never descended; file symlinks materialized only when the resolved target is a file inside the project and not excluded; skips recorded in meta + manifest as `symlink-skipped`. Regressions 1a/1b/1d/1e/1f. |
| P9a symlink loop crash | **RESOLVED** | Same walk (loops are never followed); copy failure removes the partial workspace and dies cleanly. Regression 1c. |
| P1 concurrent exec | **RESOLVED** | `State` holds an exclusive `fcntl.flock` on `state.lock` for the process lifetime (concurrent invocations serialize, both records land); state writes are unique-tmp + `os.replace`. Proof: regressions 2a–2d — 2×10 parallel execs → 20 transcripts, `last_seq` 21, seqs contiguous, zero errors. (Do not call `ocbox` from inside an exec'd command: it would wait on the lock its parent holds.) |
| P2 checkpoint-less teleport lie | **RESOLVED** | Sessions without checkpoints rebuild as `interrupted`; `last_seq` = max seq present in the lanes; briefing prints `INTERRUPTED … (no checkpoint)` and the next free sequence. Regressions 3a–3d. |
| P3a no integrity verification | **RESOLVED** | teleport-in validates on a scratch copy BEFORE installing: registry parses, per-session checkpoint consistency (`final_seq` vs lanes, manifest presence), every recorded stream re-hashed against its transcript. Briefing prints `phext_sha256:` and an `integrity: OK / DEGRADED (details)` verdict; `--expect-sha256` refuses on mismatch. Regressions 4a–4d. **Detectability boundary, stated plainly:** the audited 40% tail-truncation class is caught (DEGRADED/refusal). A truncation confined to the tail of the *final* scroll, where that scroll carries no hash of its own (e.g. the lane-map scroll), is not detectable from the file alone — `--expect-sha256` (out-of-band hash) is the airtight check. |
| P4 foreign project adoption | **RESOLVED** | Registry name ≠ local name → refuse with both names; `--adopt` is the explicit escape hatch, announced in the briefing. Regressions 5a–5d. |
| P6 host identity unvalidated | **RESOLVED (by transport)** | No host, no port, no `sq-host.json`. Daemon adoption is verified via /proc (cmdline + cwd match this store) plus the warm-up op. |
| P10 context economy | **RESOLVED** | §4 implemented with local machinery (see below). Regressions 6a–6c. |
| P11a keyless 0.0.0.0 host, never shut down | **RESOLVED (by transport)** | No listener exists. `stop`/`destroy` shut the store daemon down; startup is on demand. |
| P8 stop lies about missing workspace | **RESOLVED** | Capture proceeds (the record's job is to say what happened): diff + checkpoint record `workspace: missing at stop`; CLI prints `record closed (workspace missing)`. Regressions 9a/9b. |
| P12 orphaned wrapped commands | **PARTIAL** | Wrapped command runs in its own process group; SIGINT/SIGTERM to the CLI are forwarded to the group before exit; timeouts kill the group and are recorded. `kill -9` of the CLI itself cannot be handled by anyone — documented in README. (The fix sketch's "running marker scroll" was not adopted: the transcript-last write order already makes an in-flight exec recognizably incomplete.) |
| P5 stdin inheritance, no timeout | **RESOLVED** | stdin defaults to DEVNULL; `--interactive` inherits; `--timeout N` / `OCBOX_EXEC_TIMEOUT` kills the process group (TERM, 2 s grace, KILL) and records `timed_out` in the transcript. Regression 8a. |
| P7 phantom session on SQ-missing start | **RESOLVED** | The writer (transport preflight) is constructed before any state is saved or workspace copied. Verified: `SQ_BIN=/nonexistent ocbox start` → specific error, no `state.json` created. |
| P13 phext-name collisions | **RESOLVED** | `init` refuses when a different raw name sanitizes to the same phext file for the same store; `start` refuses when the store registry holds a colliding name. |
| R1 key ignored on host reuse | **RESOLVED (by transport)** | No host to reuse. `OCBOX_SQ_KEY` is a documented no-op locally. |
| R2 destroy discards active session | **RESOLVED** | Refuses on active sessions; `--force` writes a tombstone line into the meta lane first. Regressions 7a–7c. |
| R3 blind write retries | **RESOLVED** | The daemon writer makes exactly one attempt per op and checks the exit code; there are no retries to duplicate an append. |
| R4 no redaction hook | **RESOLVED** | `OCBOX_REDACT` (comma-separated regexes) applied to the recorded command line and both streams before hashing/insert; redaction count recorded in the transcript. Documented best-effort in README. Regressions 10a–10d. |
| R5 identity = absolute path | **OPEN** | State is still keyed by absolute path; teleport-in remains the recovery for a moved project. Changing identity semantics is a data-model decision beyond this fix list; recorded here so it is a decision, not an oversight. |
| R6 non-atomic exec flush | **RESOLVED** | Streams are written first, the transcript LAST (it is the commit record), meta index line after; `last_seq` and state advance only after the phext writes land, and the writer saves once at the end. |
| §B checkpoint contents | **RESOLVED** | Checkpoint now carries per-class `max_seq_*` counters, `lane_map_coord`/`lane_map_sha256`/`lane_map_scrolls`, `prev_checkpoint_sha256` (the E4 chain), and `delta_sha256` = the lane-map hash. The lane-map scroll itself (checkpoint class, chunk 2) is a SPEC-DEVIATION / v0.3 candidate (README). |
| §B §4 resume design (delta + query) | **RESOLVED, different mechanism** | SQ's daemon `delta` is version-divergent and `checksum` is per-scroll, so the map lives in the phext instead: the checkpoint's lane-hash map (coordinate→SHA-256, written at stop). `context` compares it, plus a store-local `delta-state.json`, against current scroll hashes. SQ `query` remains unused — with the map in the phext, ranged pulls are unnecessary. |

## Context economy — before/after (P10, measured)

Same stress phext (5,198,797 B, 251 scrolls), transport ops counted
exactly via a logging `SQ_BIN` wrapper:

| | audit (HTTP era) | fix pass (daemon) |
|---|---|---|
| no-change resume output | 352,836 B | **1,001 B** |
| no-change resume transport ops | 252–503 requests | **4 ops** (warm-up toc, save, toc, 1 pull) |
| baseline-establishing context | (same full cost) | 6,302 B out / 259 ops (one full hash pass) |

The no-change path is: file SHA-256 unchanged → print summary +
checkpoint. The change path diffs per-scroll hashes (baseline from
`delta-state.json`, or from checkpoint lane maps on a teleported phext)
and prints only the changed coordinates. `--lane <class>` /
`--session <int>` scope the toc; `--full` is the explicit opt-in to the
old everything-listing.

# Addendum — Layer 7 (2026-11-01): daemon-lifecycle cluster + detector verification

Found after the fix pass shipped, when Will challenged the P10
headline ("353 KB → 1 KB sounds like undetected failure") and Emise's
verification probes failed: `teleport-in` of the real stress phext
failed 2/2 with a wedge-recovery event, and her follow-up context
measurements (~150 B) turned out to be reading an empty phext. Full
diagnosis: POLISH.md Layer 6 (SQ 0.6.0 source + deterministic
reproduction). Resolutions below; verification: POLISH.md Layer 7.

| # | Gap | Status | Resolution |
|---|---|---|---|
| L1 | Spawn/warm-up ownership race: the writer's first client op runs concurrently with daemon startup; an sq client that executes first creates the shared-memory channel itself and waits forever, while the daemon serves — "wedge" diagnosed against a healthy daemon | **RESOLVED** | Readiness gate: no client op until the daemon's log proves service (`Serving N scrolls` past the pre-spawn offset + flink files), then a content-checked warm-up. Deterministic repro (3 s delayed share): was rc=1/121.5 s, now rc=0/10.3 s, no leftovers |
| L2 | Recovery identity was cmdline-deep: /proc cmdline+cwd cannot distinguish serving / starting / share-turned-client processes; recovery SIGKILLed healthy daemons | **RESOLVED** | sq-daemon.json records pid + /proc start time + shm link/work names, written only after confirmation; adoption verifies all; recovery requires PROVEN unresponsiveness (a stalled content-checked op against a believed-serving daemon) and kills by start-time-guarded signals |
| L3 | Failure paths orphaned processes: `die()` inside daemon startup left the respawned daemon running; teleport-in built its scratch writer outside the try/finally, leaking daemon + `.sq` + scratch dir | **RESOLVED** | Startup kills its own unconfirmed spawn on every failure path; scratch writer constructed inside the try/finally |
| L4 | `context` leaked its daemon (one per call, surviving even project-dir deletion); `status` probed with a 2 s-fused client of the same steal-prone class | **RESOLVED** | `context`/`destroy` shut the daemon down unless a session is active in the store; `status`/`ls` report daemon state from /proc only and start no clients |
| L5 | Warm-up trusted exit code; SQ prints `Error: MapOpenFailed(2)` with exit 0 — a false "healthy" was possible against a stale `.sq` | **RESOLVED** | Warm-up requires rc=0 AND a real toc payload (`* ` prefix) |
| L6 | Twin daemons on one file reachable via duplicate `share`; client-based shutdown/status probes in the shared-store path could hang or steal | **RESOLVED** | Twins → clean recovery; settle requires a verified-empty dir; slot takeover and shutdown are signal-based (SQ `shutdown` does not save; callers save first) |
| L7 | `--adopt` identity split: adoption renamed the project in shim state but not `.ocbox.json`, so every later command addressed a fresh empty `<oldname>.phext` — post-teleport contexts measured the wrong file entirely | **RESOLVED** | Adoption rewrites `.ocbox.json`'s `project` as well; found by `tests/change_detection.sh`, whose stress leg initially "detected nothing" for this reason |
| L8 | Suite verifiers (5 copies) carried the L1 race in their own daemon-start code | **RESOLVED** | All five upgraded to the gated spawn; showcase's one verifier-start failure in this layer's first pass is recorded in POLISH.md Layer 7, not hidden |

## Detector verdict (P10 revisited)

Will's challenge was justified as a demand for evidence: between
the fix pass and this addendum, the 1,001 B / 4 ops figure was
**not reproducible** — L1 made the teleport path fail outright and
L7 made every post-teleport measurement read an empty file. With
both fixed, `tests/change_detection.sh` (new, 7/7) reproduces the
figure exactly on the teleported stress phext (1,001 B output; ops:
warm-up toc, save, toc, checkpoint pull; a cold store adds one
`share` spawn) and proves the detector awake: out-of-band raw-sq
INSERT + UPDATE at small scale are both named by the next context,
and a single out-of-band INSERT at stress scale is reported as
EXACTLY that one coordinate among 251 scrolls. Residual boundary:
changes made by editing the phext FILE directly while a session
daemon is live can be overwritten by that daemon's next `save()`
(its memory is authoritative in SQ's model); channel-driven
changes, and any changes while no session daemon is live, are
detected as tested.
