#!/bin/bash
# run_stress.sh — Layer 2 stress gauntlet for the ocbox x phext MVP.
# Runs against its own throwaway shim home + SQ store (under
# stress/.stress-state/, gitignored except the final .phext), tees to
# stress/STRESS-TRANSCRIPT.txt, and asserts every case in a final
# verification pass that reads the phext DIRECTLY through SQ.
set -u

# Re-exec under a minimal environment (same reason as run_demo.sh: the
# phext env lane records variable NAMES, and this transcript is published).
if [ -z "${OCBOX_STRESS_SANITIZED:-}" ] && [ -z "${OCBOX_DEMO_KEEP_ENV:-}" ]; then
  exec env -i PATH="$PATH" HOME="$HOME" OCBOX_STRESS_SANITIZED=1 /bin/bash "$0" "$@"
fi

STRESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$STRESS_DIR")"
STATE="$STRESS_DIR/.stress-state"
SHIM="$STATE/shim"
STORE="$STATE/store"
SRC="$STATE/src"
TRANSCRIPT="$STRESS_DIR/STRESS-TRANSCRIPT.txt"
export OCBOX_SHIM_HOME="$SHIM"
OCBOX="$ROOT_DIR/ocbox"

stop_daemon() {  # $1 = store dir (default $STORE)
  local d="${1:-$STORE}"
  if [ -d "$d" ]; then
    (cd "$d" && timeout 10 "$HOME/.cargo/bin/sq" shutdown >/dev/null 2>&1) || true
    # reap any verified leftover `sq share` whose cwd is this store
    python3 - "$d" <<'PYEOF' || true
import os, signal, sys
from pathlib import Path
store = sys.argv[1]
for e in Path("/proc").glob("[0-9]*"):
    try:
        cmd = (e / "cmdline").read_bytes().decode("utf-8", "replace")
        if "share" in cmd and ".phext" in cmd and os.readlink(e / "cwd") == store:
            os.kill(int(e.name), signal.SIGTERM)
    except OSError:
        continue
PYEOF
  fi
}

run() {  # run one ocbox exec, echo its exit code, NEVER abort the script
  echo "\$ ocbox exec $1"
  "$OCBOX" exec "$1"
  local rc=$?
  echo "(ocbox exit: $rc)"
  return 0
}

run_big() {  # like run(), but stdout goes to a side file: multi-MB output
  # belongs in the phext lane, not sprayed into this transcript. The side
  # file's size + SHA-256 are printed here as an independent capture.
  echo "\$ ocbox exec $1   (stdout redirected to a capture file)"
  "$OCBOX" exec "$1" > "$STATE/capture.bin" 2> "$STATE/capture.err"
  local rc=$?
  cat "$STATE/capture.err"
  echo "(ocbox exit: $rc; captured stdout: $(stat -c %s "$STATE/capture.bin") bytes, sha256 $(sha256sum "$STATE/capture.bin" | awk '{print $1}'))"
  return 0
}

main() {
  echo "=== ocbox x phext STRESS — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "--- cleaning prior stress state ---"
  stop_daemon
  rm -rf "$STATE"
  mkdir -p "$SHIM" "$STORE" "$SRC"

  echo "--- generating stress project in $SRC ---"
  printf 'hello stress\n' > "$SRC/hello.txt"
  printf 'alpha\nbeta\ngamma\n' > "$SRC/words.txt"
  dd if=/dev/urandom of="$SRC/blob.bin" bs=1024 count=1024 2>/dev/null
  printf '{"project": "stress", "phext_store": "%s", "env_refs": []}\n' "$STORE" > "$SRC/.ocbox.json"
  cd "$SRC"

  echo "\$ ocbox start   (session 1)"
  "$OCBOX" start

  echo "--- CASE 1: volume / chunking (~5 MB of stdout) ---"
  run_big 'seq 1 700000'
  echo "--- CASE 2: one single line > 200 KB, no newline ---"
  run_big "python3 -c \"import sys; sys.stdout.write('x'*250000)\""
  echo "--- CASE 3a: output with no trailing newline ---"
  run "printf 'no trailing newline'"
  echo "--- CASE 3b: completely empty stdout AND stderr ---"
  run 'true'
  echo "--- CASE 3c: stderr only ---"
  run "python3 -c \"import sys; sys.stderr.write('only stderr here\n')\""
  echo "--- CASE 4a: binary stdout (dd urandom 64 KB) ---"
  run_big 'dd if=/dev/urandom bs=1024 count=64'
  echo "--- CASE 4b: binary stdout (openssl rand 4096, raw) ---"
  run_big 'openssl rand 4096'
  echo "--- CASE 5a: unicode + emoji + combining characters ---"
  run "python3 -c \"print('héllo wörld 🌍🔥'); print('é combining, ünïcodé')\""
  echo "--- CASE 5b: carriage-return progress output, no newline ---"
  run "printf '\rprogress 0%%\rprogress 50%%\rprogress 100%%'"
  echo "--- CASE 6: exit-code zoo ---"
  run 'exit 0'
  run 'false'
  run "python3 -c \"import sys; sys.exit(2)\""
  run "python3 -c \"import sys; sys.exit(42)\""
  run 'definitely-not-a-real-command-xyz123'
  run 'timeout 1 sleep 10'
  run "python3 -c \"import os, signal; os.kill(os.getpid(), signal.SIGTERM)\""
  run "exec python3 -c \"import os, signal; os.kill(os.getpid(), signal.SIGTERM)\""
  run "printf 'alpha\nbeta\n' > g.txt; grep zzz g.txt"
  run "printf 'a\n' > d1.txt; printf 'b\n' > d2.txt; diff d1.txt d2.txt"
  echo "--- CASE 7: many steps (60 sequential execs) ---"
  for i in $(seq 1 60); do
    run "echo step-$i"
  done
  echo "--- CASE 8: filenames with spaces and unicode ---"
  run "printf 'space content\n' > 'file with spaces.txt'; printf 'unicode content\n' > 'ünïcodé ﬁle.txt'; ls -1"
  echo "--- CASE 10: large binary created + start binary modified ---"
  run "dd if=/dev/urandom of=big.bin bs=1M count=10; printf 'tail' >> blob.bin"

  echo "\$ ocbox stop   (session 1)"
  "$OCBOX" stop

  echo "--- CASE 9: second session on the same project ---"
  echo "\$ ocbox start   (session 2)"
  "$OCBOX" start
  run 'echo second session'
  run 'sha256sum hello.txt'
  echo "\$ ocbox stop   (session 2)"
  "$OCBOX" stop

  echo
  echo "=== VERIFICATION (direct SQ reads) ==="
  python3 - "$STORE" "$SHIM" <<'PYEOF'
import base64, hashlib, json, math, re, subprocess, sys
from pathlib import Path

store, shim = Path(sys.argv[1]), Path(sys.argv[2])
SQ = str(Path.home() / ".cargo" / "bin" / "sq")

def _cli(*args, timeout=60):
    r = subprocess.run([SQ, *args], cwd=store, capture_output=True,
                       timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("sq " + args[0] + " failed: "
                           + r.stderr.decode("utf-8", "replace")[:200])
    return r.stdout

def _ensure_daemon():
    import time as _time
    want = "Hosting: stress.phext"
    def _hosting():
        try:
            out = subprocess.run([SQ, "status"], cwd=store,
                                 capture_output=True, timeout=10) \
                .stdout.decode("utf-8", "replace")
            return want in out
        except subprocess.TimeoutExpired:
            return False
    # Patience first: `sq status` blocks while a daemon loads a large
    # phext, so probe for a while before concluding none is coming —
    # spawning anyway stacks duplicate daemons on one phext.
    deadline = _time.time() + 30
    while _time.time() < deadline:
        if _hosting():
            return
        _time.sleep(2)
    # Wedged-daemon recovery: kill any `sq share stress.phext` process
    # whose cwd is this store (found via /proc — works even when no
    # sq-daemon.json exists) and clear stale .sq before the respawn.
    import os as _os, shutil as _shutil, signal as _signal
    for _entry in Path("/proc").glob("[0-9]*"):
        try:
            _cmd = (_entry / "cmdline").read_bytes().decode("utf-8", "replace")
            if "share" in _cmd and "stress.phext" in _cmd and \
                    _os.readlink(_entry / "cwd") == str(store):
                _os.kill(int(_entry.name), _signal.SIGKILL)
        except OSError:
            continue
    _time.sleep(1)
    _shutil.rmtree(store / ".sq", ignore_errors=True)
    # Settle before spawning: zero store daemons (even mid-exit) and
    # no .sq directory — the proven-clean preconditions for `sq share`.
    import os as _os2, shutil as _shutil2, signal as _signal2
    def _store_procs():
        _found = []
        for _e in Path("/proc").glob("[0-9]*"):
            try:
                _c = (_e / "cmdline").read_bytes().decode("utf-8", "replace")
                if "share" in _c and "stress.phext" in _c and \
                        _os2.readlink(_e / "cwd") == str(store):
                    _found.append(int(_e.name))
            except OSError:
                continue
        return _found
    _dl = _time.time() + 10
    while _store_procs() and _time.time() < _dl:
        _time.sleep(0.2)
    for _pid in _store_procs():
        try:
            _os2.kill(_pid, _signal2.SIGKILL)
        except OSError:
            pass
    if _store_procs():
        _time.sleep(1)
    _shutil2.rmtree(store / ".sq", ignore_errors=True)
    subprocess.Popen([SQ, "share", "stress.phext"], cwd=store,
                     stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    deadline = _time.time() + 60
    while _time.time() < deadline:
        if _hosting():
            return
        _time.sleep(1)
    raise RuntimeError("verifier could not start the sq daemon")

_ensure_daemon()

def get(endpoint, **params):
    if endpoint == "toc":
        return _cli("toc").decode("utf-8", "replace")
    if endpoint == "select":
        f = store / ".verify-pull.tmp"
        _cli("pull", params["c"], str(f))
        data = f.read_bytes().decode("utf-8", "replace")
        f.unlink(missing_ok=True)
        return data
    if endpoint == "json-export":
        items = []
        for line in get("toc", p="stress").splitlines():
            if line.startswith("* "):
                c = line[2:].split(":", 1)[0].strip()
                if c:
                    items.append({"coord": c,
                                  "scroll": get("select", p="stress", c=c)})
        return json.dumps(items)
    raise ValueError(endpoint)

# Exact reads: toc for the coordinate list, pull per coordinate.
# (json-export is lossy — it does not escape tabs or backslashes in
# scrolls, so a recorded command line containing a literal \r or \n
# comes back corrupted; `select` to stdout appends a newline.
# pull is byte-faithful.)
E = {}
for line in get("toc", p="stress").splitlines():
    if line.startswith("* "):
        c = line[2:].split(":", 1)[0].strip()
        if c:
            E[c] = get("select", p="stress", c=c)
COORD = re.compile(r"^(\d+)\.(\d+)\.1/(\d+)\.1\.1/(\d+)\.1\.(\d+)$")

def lane(proj, sess, cls, seq):
    out = {}
    for c, s in E.items():
        m = COORD.match(c)
        if m and (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))) == (proj, sess, cls, seq):
            out[int(m.group(5))] = s
    return [out[k] for k in sorted(out)]

def stream_bytes(proj, sess, cls, seq):
    parts = lane(proj, sess, cls, seq)
    if not parts:
        return b""
    if parts[0].startswith("ocbox:encoding=base64"):
        return base64.b64decode("".join(parts[1:]))
    return "".join(parts).encode("utf-8")

def kv(scroll):
    d = {}
    for line in scroll.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            d[k.strip()] = v.strip()
    return d

# session transcripts: (sess_int, seq) -> (cmdline, kv)
trans = {}
for c, s in E.items():
    m = COORD.match(c)
    if m and int(m.group(3)) == 2:
        key = (int(m.group(2)), int(m.group(4)))
        trans[key] = (s.splitlines()[0], kv(s))

def find(sess, needle):
    hits = [(seq, cmd, d) for (si, seq), (cmd, d) in sorted(trans.items())
            if si == sess and needle in cmd]
    assert hits, f"no transcript for {needle!r} in session {sess}"
    return hits[0]

results = []
def check(case, ok, detail=""):
    results.append((case, ok))
    print(f"{'PASS' if ok else 'FAIL'}  {case}  {detail}")

PJ = 2  # stress is the first real project in its own phext

# CASE 1 — volume/chunking
seq, cmd, d = find(1, "seq 1 700000")
raw = subprocess.run(["seq", "1", "700000"], capture_output=True).stdout
parts = lane(PJ, 1, 3, seq)
check("1 volume chunk count", len(parts) == math.ceil(len(raw) / 65536),
      f"{len(parts)} chunks for {len(raw)} bytes")
check("1 volume reassembly sha256", stream_bytes(PJ, 1, 3, seq) == raw
      and hashlib.sha256(raw).hexdigest() == d["stdout_sha256"],
      hashlib.sha256(raw).hexdigest()[:16])

# CASE 2 — single 250 KB line
seq, cmd, d = find(1, "'x'*250000")
check("2 single long line", stream_bytes(PJ, 1, 3, seq) == b"x" * 250000
      and len(lane(PJ, 1, 3, seq)) == math.ceil(250000 / 65536), f"seq {seq}")

# CASE 3 — newline / empty / stderr-only
seq, cmd, d = find(1, "no trailing newline")
check("3a no trailing newline", stream_bytes(PJ, 1, 3, seq) == b"no trailing newline", "")
seq, cmd, d = find(1, "true")
check("3b empty stdout+stderr", lane(PJ, 1, 3, seq) == [] and lane(PJ, 1, 4, seq) == []
      and d["stdout_bytes"] == "0" and d["stderr_bytes"] == "0", "")
seq, cmd, d = find(1, "only stderr")
check("3c stderr only", lane(PJ, 1, 3, seq) == []
      and stream_bytes(PJ, 1, 4, seq) == b"only stderr here\n", "")

# CASE 4 — binary policy
for needle, nbytes in (("dd if=/dev/urandom", 65536), ("openssl rand 4096", 4096)):
    seq, cmd, d = find(1, needle)
    parts = lane(PJ, 1, 3, seq)
    raw = stream_bytes(PJ, 1, 3, seq)
    hdr = {}
    if parts:
        for ln in parts[0].splitlines():
            if "=" in ln:
                k, v = ln.split("=", 1)
                hdr[k.strip()] = v.strip()
    ok = (d.get("stdout_encoding") == "base64" and parts
          and parts[0].startswith("ocbox:encoding=base64")
          and hdr.get("ocbox:bytes") == str(nbytes)
          and len(raw) == nbytes
          and hashlib.sha256(raw).hexdigest() == d["stdout_sha256"] == hdr.get("ocbox:sha256"))
    check(f"4 binary round-trip ({needle.split()[0]})", ok,
          f"{nbytes} bytes via {len(parts)} scrolls")

# CASE 5 — unicode / CR
seq, cmd, d = find(1, "héllo")
expected = "héllo wörld 🌍🔥\né combining, ünïcodé\n".encode("utf-8")
check("5a unicode byte-exact", stream_bytes(PJ, 1, 3, seq) == expected, "")
seq, cmd, d = find(1, "progress 0")
check("5b CR progress byte-exact",
      stream_bytes(PJ, 1, 3, seq) == b"\rprogress 0%\rprogress 50%\rprogress 100%", "")

# CASE 6 — exit zoo (from the phext transcripts, which are the record)
zoo = [("exit 0", {"0"}), ("false", {"1"}), ("sys.exit(2)", {"2"}),
       ("sys.exit(42)", {"42"}), ("definitely-not-a-real", {"127"}),
       ("timeout 1 sleep 10", {"124"}),
       ("grep zzz", {"1"}), ("diff d1.txt", {"1"})]
for needle, want in zoo:
    seq, cmd, d = find(1, needle)
    check(f"6 exit[{needle}] == {sorted(want)}", d["exit"] in want, f"recorded {d['exit']}")
seq, cmd, d = find(1, "os.kill(os.getpid()")
sig_ok = d["exit"] in ("-15", "143") and ("signal" in d if d["exit"] == "-15" else True)
check("6 exit[signal SIGTERM via shell]", sig_ok, f"recorded exit {d['exit']}, signal={d.get('signal')}")
seq, cmd, d = find(1, "exec python3")
check("6 exit[signal SIGTERM direct]", d["exit"] == "-15" and "SIGTERM" in d.get("signal", ""),
      f"recorded exit {d['exit']}, signal={d.get('signal')}")
seq, cmd, d = find(1, "diff d1.txt")
check("6 diff exit-1 stdout has the difference",
      b"< a" in stream_bytes(PJ, 1, 3, seq) and b"> b" in stream_bytes(PJ, 1, 3, seq), "")

# CASE 7 — 60 steps, seq contiguity, checkpoint
s1_seqs = sorted(seq for (si, seq) in trans if si == 1)
check("7 seqs contiguous, no gaps/dupes", s1_seqs == list(range(2, 2 + len(s1_seqs))),
      f"session 1 seqs 2..{s1_seqs[-1]} ({len(s1_seqs)} execs)")
steps = [1 for (si, seq), (cmd, d) in trans.items() if si == 1 and cmd.startswith("$ echo step-") or (si == 1 and "echo step-" in cmd)]
ck1 = kv(E.get(f"{PJ}.1.1/8.1.1/1.1.1", ""))
check("7 checkpoint final_seq == last seq", ck1.get("final_seq") == str(s1_seqs[-1]),
      f"final_seq {ck1.get('final_seq')}")

# CASE 8 — spaced / unicode filenames in manifest + diff
man1 = E.get(f"{PJ}.1.1/6.1.1/1.1.1", "")
diff1 = E.get(f"{PJ}.1.1/5.1.1/1.1.1", "")
check("8 filenames in manifest+diff",
      "file with spaces.txt" in man1 and "ünïcodé ﬁle.txt" in man1
      and "file with spaces.txt" in diff1 and "ünïcodé ﬁle.txt" in diff1, "")

# CASE 9 — second session
reg_sess = E.get("1.1.1/1.1.2/1.1.1", "")
s2_seqs = sorted(seq for (si, seq) in trans if si == 2)
s1_coords = {c for c in E if c.startswith(f"{PJ}.1.1/")}
s2_coords = {c for c in E if c.startswith(f"{PJ}.2.1/")}
ck2 = kv(E.get(f"{PJ}.2.1/8.1.1/1.1.1", ""))
check("9 session 2 registered + disjoint lanes",
      len([ln for ln in reg_sess.splitlines() if ln.strip()]) == 2
      and len(s2_seqs) == 2 and not (s1_coords & s2_coords)
      and ck2.get("session_int") == "2", f"registry lines + {len(s2_coords)} coords")
cont = kv(E.get(f"{PJ}.2.1/1.1.1/1.1.1", "") )
check("9 session 2 meta chains to session 1",
      cont.get("continuation_checkpoint_checksum") == ck1.get("pre_checkpoint_checksum"),
      f"chain {str(cont.get('continuation_checkpoint_checksum'))[:16]}")

# CASE 10 — big binary + modified binary
man = {}
for ln in man1.splitlines():
    p = ln.split("\t")
    if len(p) == 3:
        man[p[0]] = (int(p[1]), p[2])
ws = None
for cand in sorted(shim.glob("sessions/*/workspace")):
    if (cand / "big.bin").exists():
        ws = cand
        break
big_ok = False
if ws and "big.bin" in man:
    actual = hashlib.sha256((ws / "big.bin").read_bytes()).hexdigest()
    big_ok = man["big.bin"][0] == 10485760 and man["big.bin"][1] == actual
check("10 big.bin manifest hash == sha256sum", big_ok, f"workspace {ws}")
blob_sec = diff1.split("--- diff for blob.bin ---", 1)[-1] if "blob.bin" in diff1 else ""
check("10 modified binary = hash record, no difflib dump",
      "sha256 at start" in blob_sec and "--- a/blob.bin" not in diff1, "")

phext = store / "stress.phext"
print(f"phext size: {phext.stat().st_size} bytes "
      f"({sum(len(s.encode()) for s in E.values())} bytes of scroll text, "
      f"{len(E)} scrolls)")
failed = [c for c, ok in results if not ok]
print(f"STRESS RESULT: {len(results) - len(failed)}/{len(results)} PASS"
      + (f" — FAILED: {failed}" if failed else ""))
sys.exit(1 if failed else 0)
PYEOF
  local rc=$?
  echo
  echo "Stress phext: $STORE/stress.phext"
  echo "SHA-256: $(sha256sum "$STORE/stress.phext" | awk '{print $1}')"
  echo "Size: $(stat -c %s "$STORE/stress.phext") bytes"
  stop_daemon
  sleep 1
  echo "=== stress complete (verification rc=$rc) ==="
  return $rc
}

# NOTE: deliberately no `set -e` — half the zoo is commands that MUST fail;
# the script's exit status is the verifier's verdict, nothing else's.
main 2>&1 | tee "$TRANSCRIPT"
test "${PIPESTATUS[0]}" -eq 0
