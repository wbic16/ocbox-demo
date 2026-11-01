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

kill_host() {  # $1 = store dir
  local f="$1/sq-host.json"
  if [ -f "$f" ]; then
    local pid
    pid="$(python3 -c "import json; print(json.load(open('$f'))['pid'])" 2>/dev/null || true)"
    if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null || true; fi
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
  kill_host "$A/widget/.ocbox-phext"
  kill_host "$B/widget/.ocbox-phext"
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
import json, re, sys, urllib.parse, urllib.request
from pathlib import Path
store, out_path = Path(sys.argv[1]), Path(sys.argv[2])
port = json.loads((store / "sq-host.json").read_text())["port"]
def get(endpoint, **params):
    qs = urllib.parse.urlencode(params)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v2/{endpoint}?{qs}") as r:
        return r.read().decode("utf-8", "replace")
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
  kill_host "$A/widget/.ocbox-phext"

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
import hashlib, json, re, sys, urllib.parse, urllib.request
from pathlib import Path
store, facts_p, briefing_p, ctx_p, sha_a = sys.argv[1:6]
store = Path(store)
port = json.loads((store / "sq-host.json").read_text())["port"]
def get(endpoint, **params):
    qs = urllib.parse.urlencode(params)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v2/{endpoint}?{qs}") as r:
        return r.read().decode("utf-8", "replace")
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
  kill_host "$B/widget/.ocbox-phext"
  sleep 1
  echo "=== teleport complete (verification rc=$rc) ==="
  return $rc
}

main 2>&1 | tee "$TRANSCRIPT"
test "${PIPESTATUS[0]}" -eq 0
