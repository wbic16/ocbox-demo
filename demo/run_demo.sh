#!/bin/bash
# run_demo.sh — end-to-end demo of the ocbox x phext MVP against the local shim.
# Cleans its own state, runs init/start/exec x4/context/stop, verifies the
# phext directly through SQ, kills its managed sq host, and tees everything
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

kill_host_from_file() {
  local f="$STORE/sq-host.json"
  if [ -f "$f" ]; then
    local pid
    pid="$(python3 -c "import json,sys; print(json.load(open('$f'))['pid'])" 2>/dev/null || true)"
    if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null || true; fi
  fi
}

main() {
  echo "=== ocbox x phext MVP demo — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "--- cleaning prior demo state ---"
  kill_host_from_file
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
import hashlib, json, sys, urllib.parse, urllib.request
from pathlib import Path

store = Path(sys.argv[1])
info = json.loads((store / "sq-host.json").read_text())
port = info["port"]

def get(endpoint, **params):
    qs = urllib.parse.urlencode(params)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v2/{endpoint}?{qs}") as r:
        return r.read().decode("utf-8", "replace")

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

  echo "--- killing the demo's managed sq host ---"
  kill_host_from_file
  sleep 1
  echo "sq host stopped (pid from $STORE/sq-host.json)"
  echo "=== demo complete ==="
}

set -e
main 2>&1 | tee "$TRANSCRIPT"
test "${PIPESTATUS[0]}" -eq 0
