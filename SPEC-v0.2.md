# INTEGRATION SPEC: opencloudbox x phext / SQ (v0.2, checked)

Status: v0.1 draft revised 2026-11-01 after verification against:
- opencloudbox.dev homepage, /docs (Quickstart and CLI reference, "locked v0.1 interface"), and /security (Security model v0.1) — live read 2026-11-01.
- SQ v0.6.0 as installed locally (~/.cargo/bin/sq, libphext 0.3.3), per the live-tested surface in ~/workspace/bickford-llama-ranch/research/sq-api.md.
Changes from v0.1 are marked [FIX], [CLARIFY], or [NEW].

Goal (unchanged): every ocbox Session leaves behind a phext. An agent reads a table of contents instead of a whole log, state survives restarts and machines, and a human can open the same file.

## 0. Verified ground truth

opencloudbox CLI contract (v0.1, per /docs):
`ocbox login`, `ocbox init`, `ocbox start [--repo <url>]`, `ocbox exec <command...>`,
`ocbox status`, `ocbox ls`, `ocbox stop`, `ocbox destroy`, `ocbox snapshot`,
`ocbox sync push|diff|pull`, `ocbox env set`, `ocbox agent setup|doctor`.

- `start`, `exec`, `stop` in v0.1 of this spec match the real contract. Session ids are strings like `s_9c2a` (the homepage example uses exactly that id).
- [FIX] There is **no `ocbox context` command** in the v0.1 contract. It is a new command proposed by this integration (§4), not an existing lifecycle name.
- [FIX] `ocbox stop` = "Stop compute and preserve according to provider policy." Preservation is provider-dependent, so nothing in §3 may be captured *at* stop — capture must happen *before* stop, while the Session is live (§3).
- `ocbox destroy` is a separate, destructive step. The phext is precisely what survives it.
- Availability caveat: /docs labels this a **specification preview** — "the verified package and hosted MCP connection paths will be published here when access opens," and the `npm install -g opencloudbox` package name is "planned." No `ocbox` binary is installed on this machine. The Day-One MVP (§7) therefore either waits for preview access or demos against a local shim implementing the locked v0.1 contract.

SQ v0.6.0 HTTP surface (verified locally, `sq host <port> [--key <token>] [--data-dir <path>]`):
`version, load, toc, select, get, status, checksum, delta, json-export, query` (GET reads);
`insert, update` (GET with `s=` or POST with raw body — POST preferred: no URL escaping, 64 MB body cap);
`delete` (GET only); `where` (POST). Auth via `Authorization: <key>` / `Authorization: Bearer <key>`; `X-SQ-API-Key` also accepted server-side in 0.6.0 but is **not** in SQ's CORS preflight allow-list, so browser clients should use `Authorization`. Saving is automatic: every mutation re-writes the whole phext file immediately. Per-phext writes are serialised by a server mutex; last write wins per scroll.

## 1. DATA MODEL

One phext per project: `<project>.phext`, stored **outside the synced workspace** (or in the project's ocbox exclusion list) — [NEW] the phext must never be uploaded into the untrusted Session by `ocbox sync push` / `start`.

Every session gets a coordinate lane.
Coordinate = group1 / group2 / group3 (each group is `x.y.z`):
- group1: `<project>.<session>.1`
- group2: artifact class. 1 meta, 2 transcript, 3 stdout, 4 stderr, 5 diff, 6 files manifest, 7 env, 8 checkpoints — encoded `<class>.1.1`
- group3: sequence, encoded in the **chapter** slot: `<seq>.1.<chunk>` [CLARIFY] — seq increments per command/turn, chunk increments per 64 KB stdout/stderr chunk (§6). The scroll slot is the chunk index, not padding.

Example: project 3, session 7, transcript turn 12 = `3.7.1 / 2.1.1 / 12.1.1` (unchanged from v0.1).

Registry:
- [FIX] v0.1's registry addresses collided with project 1 / session 1 / meta. **Project integer 1 is reserved for the registry and is never assigned to a real project; real projects are numbered from 2.**
- `1.1.1/1.1.1/1.1.1` — project registry: one appended line per project, `<project-name>\t<project-int>`.
- `1.1.1/1.1.2/1.1.1` — session registry: one appended line per session, `<project-int>\t<session-string>\t<session-int>`. Session integers are per-project, assigned once, never renumbered. (Session strings like `s_9c2a` look globally unique, but the registry does not rely on that.)

## 2. ENDPOINTS (SQ v0.6.0)

insert, update, select, toc, delta, query — all verified present in v0.6.0, plus `checksum` (used by checkpoints, §3) and `load`/`get` for human inspection.
- Writes use POST with a raw body, not GET `s=` parameters.
- One key per project. [FIX] Who holds it depends on mode: in managed mode, the control plane; in bring-your-own-provider mode the provider credential stays on the local device by design, so the SQ key likewise stays with the local trusted writer. In both modes: never inside the Session, never in the env lane, never in a synced file.

## 3. LIFECYCLE

Single-writer principle: only the trusted ocbox-side writer (local CLI in BYO mode, control plane in managed mode) ever talks to SQ. Remote Session output is data, never a writer.

- `ocbox start`: insert meta at class 1 (image, provider, start time, project/session registry ids), insert env at class 7 — [FIX] **names and secret references only, never values**. `ocbox env set` creates a workload-secret *reference*; opencloudbox does not durably store plaintext secrets, and a provider may expose a secret as a plain env var readable by Session code, so values do not belong in the phext even "redacted" (redaction still leaks names+lengths and invites mistakes).
- `ocbox exec`: allocate the next sequence (counter kept in the session's meta lane, incremented only by the single writer). Run the command; on exit, flush stdout to class 3, stderr to class 4 (chunked per §6), and append exit code + duration + command line to class 1. Flush on command exit, not per line.
- Pre-stop capture [FIX — was "ocbox stop: insert diff…"]: **before** issuing `ocbox stop`, while the Session is live: run the diff capture (`ocbox sync diff` output and/or `git diff` via exec) → class 5, seq 1; files manifest → class 6, seq 1; then insert a checkpoint at class 8, seq 1 carrying: the SQ `checksum` of the whole phext, the session's final sequence counters per class, and the `delta` hierarchical checksum map.
- `ocbox stop`: stop compute (provider preservation policy applies to the workspace, not to the phext — the phext is already complete).
- `ocbox destroy` (optional, explicit): remote workspace gone; phext remains as the full record.

## 4. WHAT THE AGENT DOES [the one new command]

[NEW] `ocbox context` is this integration's proposed addition (a wrapper over SQ, not an upstream ocbox command):
- Print `toc` for the phext, plus the current session's checkpoint.
- The agent then `select`s only the lanes it needs, or uses `query?from=<lane-start>&to=<lane-end>` to pull a whole session lane in one call.
- On resume: the agent keeps the last `delta` checksum map it saw. It fetches the new `delta`, diffs the two maps locally to find changed lanes, and re-reads only those. [CLARIFY] `GET /api/v2/delta` returns the hierarchical checksum map with no input; this local-diff flow is the verified one. (The POST `delta` variant takes a whole phext body — not needed here.)
That is the whole win over re-syncing and re-reading logs.

## 5. SECURITY

- The provider stays the compute boundary (opencloudbox security model v0.1: adapters normalise provider APIs; the selected provider supplies the isolation; everything inside the Session — repo code, dependencies, build scripts, agent output, network input — is untrusted).
- [CLARIFY] The local agent and the ocbox CLI are the *trusted client* side of that model; the untrusted side is the remote Session and its output. So: phext writes happen from the ocbox side, outside the sandbox; untrusted output is inserted only as inert scroll text at writer-chosen coordinates, size-capped per §6, with env secrets excluded per §3. Untrusted output never gets a handle to SQ and never dictates a coordinate, a registry entry, or a sequence number.
- Redact env before insert — strengthened above to names/references only.
- The project phext and the SQ key are excluded from sync bundles (§1).
- For multi-tenant sessions use SQ Router mode with a token per tenant.

## 6. FAILURE MODES

- High-volume stdout: chunk at 64 KB, one chunk per scroll (chunk index in the scroll slot, §1), or one scroll per command, whichever comes first. Never insert per line.
- Whole-file rewrite cost: SQ re-writes the entire phext on every mutation, so flush frequency is the cost knob — per-command flush (above) is the ceiling, and very large projects should expect checkpoint-time growth. [NEW, from verified SQ behaviour]
- Concurrent sessions on one phext: SQ serialises writes per phext, but sequence allocation is not atomic across writers — the single-writer rule (§3) is what makes it safe: one writer process per project, or router mode with per-session tokens and one writer per session lane.
- Sequence exhaustion: roll to the next class group, or compact at checkpoint. (With seq in the chapter slot and chunks in the scroll slot, exhaustion is a theoretical limit, not a practical one.)

## 7. DAY-ONE MVP

`start`, `exec`, pre-stop capture + `stop`, `context`, plus the registry. That is it.
- Demo it on one repo and record 90 seconds of it.
- Demo prerequisite [from §0]: a working `ocbox` (preview access) **or** a contract-faithful local shim for `start`/`exec`/`stop` so the phext half — the part this spec actually owns — can be filmed and tested now, then re-pointed at the real CLI unchanged.

Open questions for Will:
1. Shim-first demo, or wait for opencloudbox preview access?
2. Managed mode, BYO (daytona is the documented example), or both in v1 of the integration?
3. Where does this live? No existing repo in the site map covers opencloudbox; the natural homes are a new repo or the SQ repo as an integration doc/example.
