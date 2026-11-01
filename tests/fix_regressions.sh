#!/usr/bin/env bash
# fix_regressions.sh — regression tests for the 2026-11-01 fix pass.
# One assert group per closed GAP item:
#   1 symlink escape + loop at start        (GAP major 1)
#   2 concurrent exec 2x10, nothing lost    (GAP major 2)
#   3 checkpoint-less teleport -> interrupted, seq from lanes (GAP major 3a)
#   4 truncated teleport refused or DEGRADED + --expect-sha256 (GAP major 3b)
#   5 foreign project refusal + --adopt     (GAP major 3c)
#   6 context economy on a >=200-scroll phext (GAP major 5)
#   7 destroy on active session refusal + tombstone (minor)
#   8 exec stdin defaults to /dev/null      (minor)
#   9 stop with missing workspace           (minor)
#  10 OCBOX_REDACT redaction hook          (minor)
# Sanitized env, all state under a /tmp dir, daemons cleaned up on exit.
set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCBOX="$ROOT_DIR/ocbox"
SQ="$HOME/.cargo/bin/sq"
T="$(mktemp -d /tmp/ocbox-fixreg.XXXXXX)"
export OCBOX_SHIM_HOME="$T/shim"
export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
unset OCBOX_REDACT OCBOX_EXEC_TIMEOUT OCBOX_SQ_KEY || true

PASS=0; FAIL=0; FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
assert() { # name, then command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
assert_contains() { # name file needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}
assert_not_contains() { # name file needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi
}

cleanup() {
  python3 - "$T" <<'PYEOF' >/dev/null 2>&1 || true
import os, signal, sys
from pathlib import Path
root = sys.argv[1]
for e in Path("/proc").glob("[0-9]*"):
    try:
        cmd = (e / "cmdline").read_bytes().decode("utf-8", "replace")
        if "share" in cmd and os.readlink(e / "cwd").startswith(root):
            os.kill(int(e.name), signal.SIGKILL)
    except OSError:
        continue
PYEOF
  rm -rf "$T"
}
trap cleanup EXIT

# read one scroll through the writer's own daemon machinery (which
# carries the settle/recovery discipline). The project int is resolved
# from the phext registry, so callers pass a coord template with {pi}:
# read_scroll STORE PHEXT PROJNAME COORD_TEMPLATE OUT
read_scroll_once() {
  python3 - "$ROOT_DIR/ocbox" "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import importlib.machinery, importlib.util, sys
from pathlib import Path
_loader = importlib.machinery.SourceFileLoader("ocboxmod", sys.argv[1])
spec = importlib.util.spec_from_loader("ocboxmod", _loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
store, name, projname, template, out = (Path(sys.argv[2]), sys.argv[3],
                                        sys.argv[4], sys.argv[5],
                                        Path(sys.argv[6]))
w = mod.PhextWriter(store, name)
try:
    reg = mod.parse_tsv(w.select(mod.REG_PROJ_COORD))
    coord = template.replace("{pi}", reg[projname])
    out.write_bytes(w._pull_bytes(coord))
finally:
    w.shutdown()
PYEOF
}

read_scroll() { # one retry: a wedged-daemon recovery cycle can still
  # lose a race under load; the product dies loudly, the test retries
  read_scroll_once "$@" && [ -s "$5" ] && return 0
  read_scroll_once "$@"
}

mkproj() { # dir name
  mkdir -p "$1"
  printf '{"project": "%s", "phext_store": null, "env_refs": []}\n' "$2" > "$1/.ocbox.json"
}

echo "=== fix-pass regressions (state: $T) ==="

# ---------------------------------------------------------- 1. symlinks
P="$T/links"; mkproj "$P" links
mkdir -p "$T/outside" && echo "SECRET-OUTSIDE" > "$T/outside/secret.txt"
echo "real content" > "$P/real.txt"
ln -s "$T/outside" "$P/link-out-dir"
ln -s "$T/outside/secret.txt" "$P/link-escape"
ln -s real.txt "$P/link-in"
ln -s loop-b "$P/loop-a"; ln -s loop-a "$P/loop-b"
(cd "$P" && "$OCBOX" start >start.log 2>&1)
WS="$(python3 -c "import json;print(json.load(open('$OCBOX_SHIM_HOME/state.json'))['projects']['$P']['sessions']['s_1']['workspace'])")"
assert "1a dir symlink not followed out of the tree" test ! -e "$WS/link-out-dir/secret.txt"
assert "1b escaping file symlink not copied" test ! -e "$WS/link-escape"
assert "1c symlink loop skipped, start survived" test ! -e "$WS/loop-a"
[ -f "$WS/link-in" ] && [ ! -L "$WS/link-in" ] && grep -q "real content" "$WS/link-in"
if [ $? -eq 0 ]; then ok "1d inside file symlink materialized as a regular file"; else bad "1d inside file symlink materialized as a regular file"; fi
(cd "$P" && "$OCBOX" stop >stop.log 2>&1)
read_scroll "$P/.ocbox-phext" links links "{pi}.1.1/6.1.1/1.1.1" "$T/man1.txt"
assert_contains "1e manifest records symlink-skipped entries" "$T/man1.txt" "symlink-skipped:"
read_scroll "$P/.ocbox-phext" links links "{pi}.1.1/1.1.1/1.1.1" "$T/meta1.txt"
assert_contains "1f meta records skipped symlinks" "$T/meta1.txt" "symlink-skipped:"

# ---------------------------------------------------------- 2. concurrency
P="$T/conc"; mkproj "$P" conc
echo x > "$P/f.txt"
(cd "$P" && "$OCBOX" start >/dev/null 2>&1)
( cd "$P" && for i in $(seq 1 10); do "$OCBOX" exec "echo A$i" >>"$T/concA.log" 2>&1; done ) &
( cd "$P" && for i in $(seq 1 10); do "$OCBOX" exec "echo B$i" >>"$T/concB.log" 2>&1; done ) &
wait
LASTSEQ="$(python3 -c "import json;print(json.load(open('$OCBOX_SHIM_HOME/state.json'))['projects']['$P']['sessions']['s_1']['last_seq'])")"
assert "2a 20 parallel execs -> last_seq 21 (start=1 + 20)" test "$LASTSEQ" = "21"
NTRANS="$(cd "$P" && "$OCBOX" context --lane transcript 2>/dev/null | grep -c '^\* ')"
assert "2b 20 transcript scrolls recorded, none lost" test "$NTRANS" = "20"
assert_not_contains "2c no tracebacks in concurrent exec output" "$T/concA.log" "Traceback"
assert_not_contains "2d no state errors in concurrent exec output" "$T/concB.log" "ocbox:"
(cd "$P" && "$OCBOX" stop >/dev/null 2>&1)

# ---------------------------------------------------------- 3. checkpoint-less teleport
SRC="$T/ckless-src"; mkdir -p "$SRC/store"
python3 - "$ROOT_DIR/ocbox" "$SRC/store" <<'PYEOF'
import hashlib, importlib.machinery, importlib.util, sys
from pathlib import Path
_loader = importlib.machinery.SourceFileLoader("ocboxmod", sys.argv[1])
spec = importlib.util.spec_from_loader("ocboxmod", _loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
w = mod.PhextWriter(Path(sys.argv[2]), "ckless")
hi_sha = hashlib.sha256(b"hi\n").hexdigest()
empty_sha = hashlib.sha256(b"").hexdigest()
w.update("1.1.1/1.1.1/1.1.1", "ckless\t2\n")
w.update("1.1.1/1.1.2/1.1.1", "s_1\t1\n")
w.update("2.1.1/1.1.1/1.1.1",
         "project: ckless\nproject_int: 2\nsession: s_1\nsession_int: 1\n"
         "started: 2026-11-01T00:00:00Z\n")
w.update("2.1.1/3.1.1/2.1.1", "hi\n")
w.update("2.1.1/2.1.1/2.1.1",
         "$ echo hi\nstarted: 2026-11-01T00:00:01Z\nexit: 0\n"
         "stdout_chunks: 1\nstderr_chunks: 1\n"
         f"stdout_sha256: {hi_sha}\nstderr_sha256: {empty_sha}\n")
w.save()
w.shutdown()
PYEOF
B="$T/ckless-b"; mkproj "$B" ckless
( cd "$B" && "$OCBOX" teleport-in "$SRC/store/ckless.phext" > briefing.txt 2>&1 )
assert_contains "3a briefing says INTERRUPTED" "$B/briefing.txt" "INTERRUPTED"
assert_contains "3b briefing says no checkpoint plainly" "$B/briefing.txt" "no checkpoint"
STATUS="$(python3 -c "import json;print(json.load(open('$OCBOX_SHIM_HOME/state.json'))['projects']['$B']['sessions']['s_1']['status'])")"
assert "3c rebuilt session status is interrupted, not stopped" test "$STATUS" = "interrupted"
( cd "$B" && "$OCBOX" start >/dev/null 2>&1 && "$OCBOX" exec "echo continued" >/dev/null 2>&1 && "$OCBOX" stop >/dev/null 2>&1 )
NTRANS="$(cd "$B" && "$OCBOX" context --lane transcript 2>/dev/null | grep -c '^\* 2\.2\.1/2\.1\.1/')"
assert "3d continuation session starts at int 2 with its own lanes" test "$NTRANS" = "1"

# ---------------------------------------------------------- 4. truncation + expect-sha256
P="$T/trunc"; mkproj "$P" trunc
echo data > "$P/d.txt"
( cd "$P" && "$OCBOX" start >/dev/null 2>&1 && "$OCBOX" exec "seq 1 2000" >/dev/null 2>&1 && "$OCBOX" stop >/dev/null 2>&1 )
FULL="$P/.ocbox-phext/trunc.phext"
SIZE="$(stat -c %s "$FULL")"
head -c $((SIZE * 60 / 100)) "$FULL" > "$T/trunc60.phext"
B="$T/trunc-b"; mkproj "$B" trunc
( cd "$B" && "$OCBOX" teleport-in "$T/trunc60.phext" > briefing.txt 2>&1 )
RC=$?
if [ $RC -ne 0 ] || grep -q "DEGRADED" "$B/briefing.txt"; then
  ok "4a 40%-truncated phext refused or loudly DEGRADED (rc=$RC)"
else
  bad "4a 40%-truncated phext refused or loudly DEGRADED (rc=$RC)"
fi
( cd "$B" && "$OCBOX" teleport-in --expect-sha256 0000000000000000000000000000000000000000000000000000000000000000 "$FULL" > expect.log 2>&1 )
RC=$?
assert "4b --expect-sha256 mismatch refuses" test $RC -ne 0
assert_contains "4c refusal names the mismatch" "$B/expect.log" "SHA-256 mismatch"
GOOD_SHA="$(sha256sum "$FULL" | awk '{print $1}')"
( cd "$B" && "$OCBOX" teleport-in --expect-sha256 "$GOOD_SHA" "$FULL" > good.txt 2>&1 )
assert_contains "4d correct --expect-sha256 imports, sha printed" "$B/good.txt" "phext_sha256: $GOOD_SHA"

# ---------------------------------------------------------- 5. foreign project
B="$T/foreign-b"; mkproj "$B" othername
( cd "$B" && "$OCBOX" teleport-in "$FULL" > no.txt 2>&1 )
RC=$?
assert "5a foreign phext refused without --adopt" test $RC -ne 0
assert_contains "5b refusal explains the mismatch" "$B/no.txt" "project mismatch"
( cd "$B" && "$OCBOX" teleport-in --adopt "$FULL" > yes.txt 2>&1 )
assert_contains "5c --adopt imports and says so" "$B/yes.txt" "adopted"
assert_contains "5d briefing carries the phext's own name" "$B/yes.txt" "teleported: trunc"

# ---------------------------------------------------------- 6. context economy
P="$T/big"; mkproj "$P" big
mkdir -p "$P/.ocbox-phext"
python3 - "$ROOT_DIR/ocbox" "$P/.ocbox-phext" <<'PYEOF'
import importlib.machinery, importlib.util, sys
from pathlib import Path
_loader = importlib.machinery.SourceFileLoader("ocboxmod", sys.argv[1])
spec = importlib.util.spec_from_loader("ocboxmod", _loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
w = mod.PhextWriter(Path(sys.argv[2]), "big")
w.update("1.1.1/1.1.1/1.1.1", "big\t2\n")
w.update("1.1.1/1.1.2/1.1.1", "s_1\t1\n")
for i in range(2, 212):
    w.update(f"2.1.1/3.1.1/{i}.1.1", f"chunk {i} " + "x" * 50)
w.save()
w.shutdown()
PYEOF
( cd "$P" && "$OCBOX" context > ctx1.txt 2>&1 )
( cd "$P" && "$OCBOX" context > ctx2.txt 2>&1 )
BYTES="$(stat -c %s "$P/ctx2.txt")"
assert "6a no-change context resume < 5 KB (was 352,836 B pre-fix)" test "$BYTES" -lt 5120
assert_contains "6b no-change resume says so" "$P/ctx2.txt" "no changes"
FULL_BYTES="$(cd "$P" && "$OCBOX" context --full 2>/dev/null | wc -c)"
assert "6c --full is available and much larger (opt-in)" test "$FULL_BYTES" -gt "$BYTES"

# ---------------------------------------------------------- 7. destroy refusal
P="$T/dest"; mkproj "$P" dest
echo x > "$P/f.txt"
( cd "$P" && "$OCBOX" start >/dev/null 2>&1 )
( cd "$P" && "$OCBOX" destroy > d1.log 2>&1 ); RC=$?
assert "7a destroy on ACTIVE session refuses" test $RC -ne 0
( cd "$P" && "$OCBOX" destroy --force > d2.log 2>&1 ); RC=$?
assert "7b destroy --force proceeds" test $RC -eq 0
read_scroll "$P/.ocbox-phext" dest dest "{pi}.1.1/1.1.1/1.1.1" "$T/meta7.txt"
assert_contains "7c tombstone written to meta lane" "$T/meta7.txt" "destroyed:"

# ---------------------------------------------------------- 8. exec stdin
P="$T/stdin"; mkproj "$P" stdin
echo x > "$P/f.txt"
( cd "$P" && "$OCBOX" start >/dev/null 2>&1 )
OUT="$( cd "$P" && timeout 8 bash -c 'sleep 20 | "$1" exec "read x; echo returned" ' _ "$OCBOX" 2>&1 )"
assert "8a exec does not block on inherited stdin (DEVNULL default)" test "$OUT" = "returned"
( cd "$P" && "$OCBOX" stop >/dev/null 2>&1 )

# ---------------------------------------------------------- 9. stop, workspace missing
P="$T/gone"; mkproj "$P" gone
echo x > "$P/f.txt"
( cd "$P" && "$OCBOX" start >/dev/null 2>&1 && "$OCBOX" exec "echo hi" >/dev/null 2>&1 )
WS="$(python3 -c "import json;print(json.load(open('$OCBOX_SHIM_HOME/state.json'))['projects']['$P']['sessions']['s_1']['workspace'])")"
rm -rf "$WS"
( cd "$P" && "$OCBOX" stop > stop.log 2>&1 )
assert_contains "9a stop reports the missing workspace honestly" "$P/stop.log" "record closed (workspace missing)"
read_scroll "$P/.ocbox-phext" gone gone "{pi}.1.1/8.1.1/1.1.1" "$T/ck9.txt"
assert_contains "9b checkpoint records workspace: missing at stop" "$T/ck9.txt" "workspace: missing at stop"

# ---------------------------------------------------------- 10. redaction
P="$T/redact"; mkproj "$P" redact
echo x > "$P/f.txt"
( cd "$P" && "$OCBOX" start >/dev/null 2>&1 )
( cd "$P" && OCBOX_REDACT='hunter2' "$OCBOX" exec "echo hunter2" >/dev/null 2>&1 )
read_scroll "$P/.ocbox-phext" redact redact "{pi}.1.1/2.1.1/2.1.1" "$T/trans10.txt"
assert_not_contains "10a secret not present in transcript" "$T/trans10.txt" "hunter2"
assert_contains "10b redaction marker recorded" "$T/trans10.txt" "[redacted]"
assert_contains "10c redaction count recorded" "$T/trans10.txt" "redactions:"
read_scroll "$P/.ocbox-phext" redact redact "{pi}.1.1/3.1.1/2.1.1" "$T/out10.txt"
assert_not_contains "10d secret not present in stdout lane" "$T/out10.txt" "hunter2"
( cd "$P" && "$OCBOX" stop >/dev/null 2>&1 )

echo
echo "FIX-REGRESSIONS RESULT: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
