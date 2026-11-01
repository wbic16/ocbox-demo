#!/bin/bash
# teleport.sh — Layer 4: STATE TELEPORTATION.
# Machine A runs a session and stops. ONLY the resulting .phext file is
# copied to machine B (fresh shim home, fresh store, no state.json, no
# workspace). B rebuilds its writer state from the phext alone
# (`ocbox teleport-in`), prints a resume briefing generated only from
# phext data, then CONTINUES: session 2 on the same phext, its meta
# quoting session 1's checkpoint checksum.
# Both "machines" are state dirs under demo/.teleport-state/ (gitignored
# except the phexts). Tees to demo/TELEPORT-TRANSCRIPT.txt.
set -u

if [ -z "${OCBOX_TELEPORT_SANITIZED:-}" ] && [ -z "${OCBOX_DEMO_KEEP_ENV:-}" ]; then
  exec env -i PATH="$PATH" HOME="$HOME" OCBOX_TELEPORT_SANITIZED=1 /bin/bash "$0" "$@"
fi

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$DEMO_DIR")"
STATE="$DEMO_DIR/.teleport-state"
A="$STATE/A"
B="$STATE/B"
TRANSCRIPT="$DEMO_DIR/TELEPORT-TRANSCRIPT.txt"
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

run() {
  echo "\$ ocbox exec $1"
  "$OCBOX" exec "$1"
  local rc=$?
  echo "(ocbox exit: $rc)"
  return 0
}

main() {
  echo "=== ocbox x phext STATE TELEPORTATION — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  stop_daemon "$A/widget/.ocbox-phext"
  stop_daemon "$B/widget/.ocbox-phext"
  rm -rf "$STATE"
  mkdir -p "$A" "$B"

  echo
  echo "########## MACHINE A ##########"
  cp -r "$DEMO_DIR/teleport-sample" "$A/widget"
  cd "$A/widget"
  export OCBOX_SHIM_HOME="$A/shim"
  echo "\$ ocbox init";   "$OCBOX" init
  echo "\$ ocbox start";  "$OCBOX" start
  run 'python3 compute.py'
  run "printf 'teleport me\n' > note.txt && sha256sum note.txt"
  run 'ffmpeg -nostdin -y -f lavfi -i testsrc=duration=1:size=320x240:rate=10 -pix_fmt yuv420p clip.mp4'
  run 'cat data.txt'
  echo "\$ ocbox stop";   "$OCBOX" stop

  local A_PHEXT="$A/widget/.ocbox-phext/widget.phext"
  local SHA_A SIZE_A
  SHA_A="$(sha256sum "$A_PHEXT" | awk '{print $1}')"
  SIZE_A="$(stat -c %s "$A_PHEXT")"
  echo "Machine A phext: $A_PHEXT"
  echo "Machine A phext SHA-256: $SHA_A"
  echo "Machine A phext size: $SIZE_A bytes"

  echo "--- recording machine A's facts (direct SQ reads, for later assertions) ---"
  python3 - "$A/widget/.ocbox-phext" "$STATE/a-facts.json" <<'PYEOF'
import json, re, subprocess, sys
from pathlib import Path
store, out_path = Path(sys.argv[1]), Path(sys.argv[2])
SQ = str(Path.home() / ".cargo" / "bin" / "sq")

def _cli(*args, timeout=60):
    r = subprocess.run([SQ, *args], cwd=store, capture_output=True,
                       timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("sq " + args[0] + " failed: "
                           + r.stderr.decode("utf-8", "replace")[:200])
    return r.stdout

def _ensure_daemon():
    import os as _os, shutil as _shutil, signal as _signal
    import time as _time
    # Layer 7 discipline (same as the ocbox writer — POLISH.md Layer
    # 6): NEVER probe a starting daemon with client ops. An sq client
    # that runs before the daemon creates its shared-memory channel
    # can steal the channel and wait forever, and a `share` that
    # loses that race silently becomes a client — the old probe-loop
    # version of this function raced exactly that way and could
    # report "could not start the sq daemon" against a healthy
    # spawn. Existence comes from /proc; a fresh spawn is gated on
    # the daemon's own "Serving" log line before any client op runs.
    def _store_procs():
        _found = []
        for _e in Path("/proc").glob("[0-9]*"):
            try:
                _c = (_e / "cmdline").read_bytes().decode(
                    "utf-8", "replace")
                if "share" in _c and "widget.phext" in _c and \
                        _os.readlink(_e / "cwd") == str(store):
                    _found.append(int(_e.name))
            except OSError:
                continue
        return _found
    def _spawn_gated():
        _logf = store / ".verify-daemon.log"
        _off = _logf.stat().st_size if _logf.exists() else 0
        _log = open(_logf, "ab")
        _proc = subprocess.Popen([SQ, "share", "widget.phext"], cwd=store,
                                 stdout=_log, stderr=_log,
                                 stdin=subprocess.DEVNULL,
                                 start_new_session=True)
        _log.close()
        _dl = _time.time() + 90
        while _time.time() < _dl:
            if _proc.poll() is not None:
                return False
            try:
                with open(_logf, "rb") as _f:
                    _f.seek(_off)
                    if b"Serving " in _f.read():
                        return True
            except OSError:
                pass
            _time.sleep(0.1)
        return False
    if _store_procs():
        return  # a daemon for this phext is already up in this store
    if _spawn_gated():
        return
    # One recovery cycle: clear the store's daemon state, respawn.
    for _pid in _store_procs():
        try:
            _os.kill(_pid, _signal.SIGKILL)
        except OSError:
            pass
    _time.sleep(1)
    _shutil.rmtree(store / ".sq", ignore_errors=True)
    if not _spawn_gated():
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
        for line in get("toc", p="widget").splitlines():
            if line.startswith("* "):
                c = line[2:].split(":", 1)[0].strip()
                if c:
                    items.append({"coord": c,
                                  "scroll": get("select", p="widget", c=c)})
        return json.dumps(items)
    raise ValueError(endpoint)
E = {}
for line in get("toc", p="widget").splitlines():
    if line.startswith("* "):
        c = line[2:].split(":", 1)[0].strip()
        if c:
            E[c] = get("select", p="widget", c=c)
def kv(s):
    d = {}
    for ln in s.splitlines():
        if ": " in ln:
            k, v = ln.split(": ", 1)
            d[k.strip()] = v.strip()
    return d
COORD = re.compile(r"^(\d+)\.(\d+)\.1/(\d+)\.1\.1/(\d+)\.1\.(\d+)$")
cmds = []
for c, s in E.items():
    m = COORD.match(c)
    if m and int(m.group(3)) == 2 and int(m.group(2)) == 1:
        cmds.append((int(m.group(4)), s.splitlines()[0], kv(s).get("exit")))
cmds.sort()
meta = kv(E["2.1.1/1.1.1/1.1.1"])
ckpt = kv(E["2.1.1/8.1.1/1.1.1"])
man = {}
for ln in E["2.1.1/6.1.1/1.1.1"].splitlines():
    p = ln.split("\t")
    if len(p) == 3:
        man[p[0]] = p[2]
facts = {"session": meta["session"], "commands": cmds,
         "checkpoint_pre_checksum": ckpt["pre_checkpoint_checksum"],
         "final_seq": ckpt["final_seq"], "manifest": man}
out_path.write_text(json.dumps(facts, indent=1))
print(json.dumps(facts, indent=1))
PYEOF
  stop_daemon "$A/widget/.ocbox-phext"

  echo
  echo "########## THE JUMP ##########"
  echo "Machine B starts from NOTHING but the project repo (re-synced from"
  echo "source, as opencloudbox would) plus the single .phext file."
  cp -r "$DEMO_DIR/teleport-sample" "$B/widget"
  mkdir -p "$B/received"
  echo "--- machine B files BEFORE the jump (project source only) ---"
  find "$B" -type f | sort
  if [ -e "$B/shim" ]; then echo "B shim home EXISTS (unexpected)"; else echo "B shim home: absent — no state.json, no workspaces"; fi
  cp "$A_PHEXT" "$B/received/widget.phext"
  local SHA_RECV
  SHA_RECV="$(sha256sum "$B/received/widget.phext" | awk '{print $1}')"
  echo "--- machine B files AFTER the jump (exactly one file crossed) ---"
  find "$B" -type f | sort
  echo "A phext SHA-256:      $SHA_A"
  echo "B received SHA-256:   $SHA_RECV"
  if [ "$SHA_A" = "$SHA_RECV" ]; then echo "JUMP INTEGRITY: MATCH"; else echo "JUMP INTEGRITY: MISMATCH"; return 1; fi

  echo
  echo "########## MACHINE B ##########"
  cd "$B/widget"
  export OCBOX_SHIM_HOME="$B/shim"
  echo "\$ ocbox init";   "$OCBOX" init
  echo "\$ ocbox teleport-in $B/received/widget.phext"
  "$OCBOX" teleport-in "$B/received/widget.phext" | tee "$STATE/briefing.txt"

  echo "\$ ocbox context   (baseline at the teleport point)"
  "$OCBOX" context > /dev/null
  echo "(context ran with state rebuilt from the phext only; toc/delta baseline recorded)"

  echo "--- CONTINUATION on machine B ---"
  echo "Project files came from the repo (re-copy above). Session state —"
  echo "registry, counters, checkpoint chain — came from the phext alone."
  echo "\$ ocbox start   (continuation session)"
  "$OCBOX" start
  run "printf 'teleport me\n' > note.txt && sha256sum note.txt"
  echo "\$ ocbox stop";   "$OCBOX" stop
  echo "\$ ocbox context   (what changed since the teleport point?)"
  "$OCBOX" context | tee "$STATE/context-after.txt"

  echo
  echo "=== VERIFICATION (direct SQ reads on machine B's phext) ==="
  python3 - "$B/widget/.ocbox-phext" "$STATE/a-facts.json" "$STATE/briefing.txt" "$STATE/context-after.txt" "$SHA_A" <<'PYEOF'
import hashlib, json, re, subprocess, sys
from pathlib import Path
store, facts_p, briefing_p, ctx_p, sha_a = sys.argv[1:6]
store = Path(store)
SQ = str(Path.home() / ".cargo" / "bin" / "sq")

def _cli(*args, timeout=60):
    r = subprocess.run([SQ, *args], cwd=store, capture_output=True,
                       timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("sq " + args[0] + " failed: "
                           + r.stderr.decode("utf-8", "replace")[:200])
    return r.stdout

def _ensure_daemon():
    import os as _os, shutil as _shutil, signal as _signal
    import time as _time
    # Layer 7 discipline (same as the ocbox writer — POLISH.md Layer
    # 6): NEVER probe a starting daemon with client ops. An sq client
    # that runs before the daemon creates its shared-memory channel
    # can steal the channel and wait forever, and a `share` that
    # loses that race silently becomes a client — the old probe-loop
    # version of this function raced exactly that way and could
    # report "could not start the sq daemon" against a healthy
    # spawn. Existence comes from /proc; a fresh spawn is gated on
    # the daemon's own "Serving" log line before any client op runs.
    def _store_procs():
        _found = []
        for _e in Path("/proc").glob("[0-9]*"):
            try:
                _c = (_e / "cmdline").read_bytes().decode(
                    "utf-8", "replace")
                if "share" in _c and "widget.phext" in _c and \
                        _os.readlink(_e / "cwd") == str(store):
                    _found.append(int(_e.name))
            except OSError:
                continue
        return _found
    def _spawn_gated():
        _logf = store / ".verify-daemon.log"
        _off = _logf.stat().st_size if _logf.exists() else 0
        _log = open(_logf, "ab")
        _proc = subprocess.Popen([SQ, "share", "widget.phext"], cwd=store,
                                 stdout=_log, stderr=_log,
                                 stdin=subprocess.DEVNULL,
                                 start_new_session=True)
        _log.close()
        _dl = _time.time() + 90
        while _time.time() < _dl:
            if _proc.poll() is not None:
                return False
            try:
                with open(_logf, "rb") as _f:
                    _f.seek(_off)
                    if b"Serving " in _f.read():
                        return True
            except OSError:
                pass
            _time.sleep(0.1)
        return False
    if _store_procs():
        return  # a daemon for this phext is already up in this store
    if _spawn_gated():
        return
    # One recovery cycle: clear the store's daemon state, respawn.
    for _pid in _store_procs():
        try:
            _os.kill(_pid, _signal.SIGKILL)
        except OSError:
            pass
    _time.sleep(1)
    _shutil.rmtree(store / ".sq", ignore_errors=True)
    if not _spawn_gated():
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
        for line in get("toc", p="widget").splitlines():
            if line.startswith("* "):
                c = line[2:].split(":", 1)[0].strip()
                if c:
                    items.append({"coord": c,
                                  "scroll": get("select", p="widget", c=c)})
        return json.dumps(items)
    raise ValueError(endpoint)
E = {}
for line in get("toc", p="widget").splitlines():
    if line.startswith("* "):
        c = line[2:].split(":", 1)[0].strip()
        if c:
            E[c] = get("select", p="widget", c=c)
def kv(s):
    d = {}
    for ln in s.splitlines():
        if ": " in ln:
            k, v = ln.split(": ", 1)
            d[k.strip()] = v.strip()
    return d
facts = json.loads(Path(facts_p).read_text())
briefing = Path(briefing_p).read_text()
results = []
def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")

# briefing vs machine A's recorded facts
b_cmds = re.findall(r"seq (\d+): (\$ .*) -> exit (\S+)", briefing)
a_cmds = [(str(s), c, e) for s, c, e in facts["commands"]]
check("briefing commands == machine A commands", b_cmds == a_cmds,
      f"{len(b_cmds)} commands" if b_cmds == a_cmds else f"B={b_cmds} A={a_cmds}")
check("briefing last command + exit match A",
      f"last_command: {a_cmds[-1][1]}" in briefing and f"last_exit: {a_cmds[-1][2]}" in briefing, "")
check("briefing file list match A manifest",
      all(f in briefing for f in facts["manifest"]), f"{sorted(facts['manifest'])}")
check("briefing checkpoint checksum == A checkpoint",
      f"checkpoint_pre_checksum: {facts['checkpoint_pre_checksum']}" in briefing, "")

# continuation chain, from B's phext alone
meta2 = kv(E.get("2.2.1/1.1.1/1.1.1", ""))
check("session 2 meta quotes session 1 id + checkpoint checksum",
      meta2.get("continuation_of_session") == facts["session"]
      and meta2.get("continuation_checkpoint_checksum") == facts["checkpoint_pre_checksum"],
      f"of {meta2.get('continuation_of_session')}, sum {str(meta2.get('continuation_checkpoint_checksum'))[:16]}")
reg = E.get("1.1.1/1.1.2/1.1.1", "")
check("registry now holds both sessions",
      len([ln for ln in reg.splitlines() if ln.strip()]) == 2, reg.replace("\n", " | "))
s2 = [c for c in E if c.startswith("2.2.1/")]
check("session 2 lanes exist", len(s2) >= 6, f"{len(s2)} coords")
note_hash = facts["manifest"].get("note.txt", "")
found = any(note_hash and note_hash in s for c, s in E.items() if c.startswith("2.2.1/3.1.1/"))
check("continuation recreated note.txt with A's manifest hash", found, note_hash[:16])
check("note.txt content hash is the known content",
      note_hash == hashlib.sha256(b"teleport me\n").hexdigest(), "")

ctx = Path(ctx_p).read_text()
changed = re.findall(r"^  (\S+)$", ctx.split("Coordinates changed since last context:")[-1], re.M)
allowed = [c for c in changed if c.startswith("2.2.1/") or c == "1.1.1/1.1.2/1.1.1"]
check("context delta since teleport = continuation coords only",
      bool(changed) and changed == allowed, f"{len(changed)} changed coords")

print(f"A phext sha256 (pre-jump): {sha_a}")
failed = [n for n, ok in results if not ok]
print(f"TELEPORT RESULT: {len(results) - len(failed)}/{len(results)} PASS"
      + (f" — FAILED: {failed}" if failed else ""))
sys.exit(1 if failed else 0)
PYEOF
  local rc=$?
  local B_PHEXT="$B/widget/.ocbox-phext/widget.phext"
  echo
  echo "Machine B phext after continuation: $B_PHEXT"
  echo "SHA-256: $(sha256sum "$B_PHEXT" | awk '{print $1}')"
  echo "Size: $(stat -c %s "$B_PHEXT") bytes (A's file was $SIZE_A bytes)"
  stop_daemon "$B/widget/.ocbox-phext"
  sleep 1
  echo "=== teleport complete (verification rc=$rc) ==="
  return $rc
}

main 2>&1 | tee "$TRANSCRIPT"
test "${PIPESTATUS[0]}" -eq 0
