#!/bin/bash
# run_demo.sh — end-to-end demo of the ocbox x phext MVP against the local shim.
# Cleans its own state, runs init/start/exec x4/context/stop, verifies the
# phext directly through SQ, kills its managed sq daemon, and tees everything
# to DEMO-TRANSCRIPT.txt next to this script.
set -u

# Re-exec under a minimal environment: the phext env lane records variable
# NAMES present when the session runs, and the recorded demo is published —
# it should show a small, deliberate set, not the host machine's runtime
# variables. Set OCBOX_DEMO_KEEP_ENV=1 to bypass.
if [ -z "${OCBOX_DEMO_SANITIZED:-}" ] && [ -z "${OCBOX_DEMO_KEEP_ENV:-}" ]; then
  exec env -i PATH="$PATH" HOME="$HOME" OCBOX_DEMO_SANITIZED=1 /bin/bash "$0" "$@"
fi

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$DEMO_DIR")"
SAMPLE="$DEMO_DIR/sample"
STATE="$DEMO_DIR/.demo-state"
STORE="$SAMPLE/.ocbox-phext"
TRANSCRIPT="$DEMO_DIR/DEMO-TRANSCRIPT.txt"
export OCBOX_SHIM_HOME="$STATE/shim"
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

main() {
  echo "=== ocbox x phext MVP demo — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "--- cleaning prior demo state ---"
  stop_daemon
  rm -rf "$STATE" "$STORE" "$SAMPLE/.ocbox.json"
  mkdir -p "$STATE"

  cd "$SAMPLE"
  echo "\$ ocbox init"
  "$OCBOX" init
  echo "\$ ocbox start"
  "$OCBOX" start
  echo "\$ ocbox status"
  "$OCBOX" status

  echo "\$ ocbox exec python3 hello.py"
  "$OCBOX" exec python3 hello.py || { echo "UNEXPECTED FAILURE"; return 1; }

  echo "\$ ocbox exec python3 -m unittest -v"
  "$OCBOX" exec python3 -m unittest -v || { echo "UNEXPECTED FAILURE"; return 1; }

  echo "\$ ocbox exec \"python3 -c ...create notes.txt; append a line to README.md\""
  "$OCBOX" exec "python3 -c \"open('notes.txt','w').write('created inside the session\n')\" && echo 'a change from inside the session' >> README.md" \
    || { echo "UNEXPECTED FAILURE"; return 1; }

  echo "\$ ocbox exec (failing command, exit 3, writes to stderr)"
  set +e
  "$OCBOX" exec "python3 -c \"import sys; print('something went wrong on purpose', file=sys.stderr); sys.exit(3)\""
  rc=$?
  set -e
  echo "(ocbox exec returned exit code $rc, as expected)"

  echo "\$ ocbox context"
  "$OCBOX" context
  echo "\$ ocbox stop"
  "$OCBOX" stop
  echo "\$ ocbox context (after stop — checkpoint + delta changes)"
  "$OCBOX" context

  echo
  echo "=== VERIFICATION (direct SQ reads, independent of the CLI's printouts) ==="
  python3 - "$STORE" <<'PYEOF'
import hashlib, json, subprocess, sys
from pathlib import Path

store = Path(sys.argv[1])
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
                if "share" in _c and "sample.phext" in _c and \
                        _os.readlink(_e / "cwd") == str(store):
                    _found.append(int(_e.name))
            except OSError:
                continue
        return _found
    def _spawn_gated():
        _logf = store / ".verify-daemon.log"
        _off = _logf.stat().st_size if _logf.exists() else 0
        _log = open(_logf, "ab")
        _proc = subprocess.Popen([SQ, "share", "sample.phext"], cwd=store,
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
        for line in get("toc", p="sample").splitlines():
            if line.startswith("* "):
                c = line[2:].split(":", 1)[0].strip()
                if c:
                    items.append({"coord": c,
                                  "scroll": get("select", p="sample", c=c)})
        return json.dumps(items)
    raise ValueError(endpoint)

items = json.loads(get("json-export", p="sample"), strict=False)  # SQ does not escape tabs in scrolls
by_coord = {i["coord"]: i["scroll"] for i in items}
classes = {}
for c in by_coord:
    g1, g2, g3 = c.split("/")
    cls = int(g2.split(".")[0])
    classes.setdefault(cls, []).append(c)

names = {1: "meta", 2: "transcript", 3: "stdout", 4: "stderr",
         5: "diff", 6: "files manifest", 7: "env", 8: "checkpoints"}
print("Coordinates found, by class:")
for cls in sorted(classes):
    print(f"  class {cls} ({names.get(cls, '?')}):")
    for c in sorted(classes[cls]):
        print(f"    {c}  ({len(by_coord[c])} bytes)")

assert "1.1.1/1.1.1/1.1.1" in by_coord, "project registry scroll missing"
assert "1.1.1/1.1.2/1.1.1" in by_coord, "session registry scroll missing"
print("Registry scrolls:")
print("  project registry:", by_coord["1.1.1/1.1.1/1.1.1"].strip().replace("\n", " | "))
print("  session registry:", by_coord["1.1.1/1.1.2/1.1.1"].strip().replace("\n", " | "))

for cls in range(1, 9):
    assert cls in classes, f"class {cls} missing from phext"
stderr_scrolls = [by_coord[c] for c in classes[4]]
assert any("something went wrong on purpose" in s for s in stderr_scrolls), "stderr scroll missing marker"
diff = by_coord[[c for c in classes[5]][0]]
assert "notes.txt" in diff and "README.md" in diff, "diff scroll missing added/modified files"
manifest = by_coord[[c for c in classes[6]][0]]
assert "notes.txt" in manifest and "hello.py" in manifest, "manifest incomplete"
checkpoint = by_coord[[c for c in classes[8]][0]]
assert "pre_checkpoint_checksum:" in checkpoint, "checkpoint missing checksum"
print("Checkpoint scroll:")
for line in checkpoint.strip().splitlines():
    print(f"  {line}")
print("VERIFICATION: PASS — all 8 classes present, registries present, "
      "stderr/diff/manifest/checkpoint contents check out")
PYEOF

  local phext="$STORE/sample.phext"
  echo
  echo "Demo phext: $phext"
  echo "SHA-256: $(sha256sum "$phext" | awk '{print $1}')"
  echo "Size: $(stat -c %s "$phext") bytes"

  echo "--- stopping the demo's sq daemon ---"
  stop_daemon
  sleep 1
  echo "sq daemon stopped (sq shutdown)"
  echo "=== demo complete ==="
}

set -e
main 2>&1 | tee "$TRANSCRIPT"
test "${PIPESTATUS[0]}" -eq 0
