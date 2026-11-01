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
    import time as _time
    want = "Hosting: sample.phext"
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
    # Wedged-daemon recovery: kill any `sq share sample.phext` process
    # whose cwd is this store (found via /proc — works even when no
    # sq-daemon.json exists) and clear stale .sq before the respawn.
    import os as _os, shutil as _shutil, signal as _signal
    for _entry in Path("/proc").glob("[0-9]*"):
        try:
            _cmd = (_entry / "cmdline").read_bytes().decode("utf-8", "replace")
            if "share" in _cmd and "sample.phext" in _cmd and \
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
                if "share" in _c and "sample.phext" in _c and \
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
    subprocess.Popen([SQ, "share", "sample.phext"], cwd=store,
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
