#!/usr/bin/env bash
# tests/change_detection.sh — the out-of-band mutation test for
# `ocbox context` change detection (POLISH.md Layer 6/7).
#
# The headline claim under test: a no-change `context` on a large
# session phext is cheap (file-SHA short-circuit) AND the detector
# still catches changes it did not make. Cheap is only impressive
# if the detector is awake, so this suite mutates the phext BEHIND
# ocbox's back — raw `sq` only, no ocbox code path involved — and
# requires the next `context` to name the mutated coordinates.
#
# Legs:
#   small  — build a session via the CLI, baseline context, mutate
#            (INSERT a fresh scroll into session 1's stdout lane +
#            UPDATE an existing stdout scroll) via raw sq, then
#            context must list BOTH coordinates as changed.
#   stress — teleport-in the real 5.2 MB stress phext, baseline +
#            no-change context (bytes + SQ op count recorded), then
#            one out-of-band INSERT; context must report EXACTLY
#            that one coordinate.
#
# Discipline: every subprocess is time-bounded (bash `timeout` for
# ocbox, subprocess timeouts inside the python mutation helper);
# sanitized env; all state under a mktemp dir; the suite cleans up
# its daemons and says so.

set -u
cd "$(dirname "$0")/.."
REPO="$PWD"
OCBOX="$REPO/ocbox"
STRESS_SRC="$REPO/stress/.stress-state/store/stress.phext"
REAL_SQ="$(command -v sq || true)"
[ -n "$REAL_SQ" ] || REAL_SQ="$HOME/.cargo/bin/sq"

WORK="$(mktemp -d /tmp/ocbox-changedetect.XXXXXX)"
PASSN=0; FAILN=0
FAILED=""

pass() { PASSN=$((PASSN+1)); echo "PASS $1 — $2"; }
fail() { FAILN=$((FAILN+1)); FAILED="$FAILED $1"; echo "FAIL $1 — $2"; }
note() { echo "  .. $*"; }

# ocbox in a project dir with sanitized env + hard timeout.
#   $1=projdir $2=shimhome $3=timeout_s $4=outfile; rest=args
run_ocbox() {
  local proj="$1" home="$2" tmo="$3" out="$4"; shift 4
  ( cd "$proj" && timeout -k 5 "$tmo" env -i PATH="$PATH" HOME="$HOME" \
      OCBOX_SHIM_HOME="$home" ${SQ_BIN:+SQ_BIN="$SQ_BIN"} \
      ${OCBOX_OPLOG:+OCBOX_OPLOG="$OCBOX_OPLOG"} \
      "$OCBOX" "$@" >"$out" 2>"$out.err" )
  return $?
}

sq_census() { # dirs under $WORK still hosting sq share processes
  python3 - "$WORK" <<'PYEOF'
import os, sys
from pathlib import Path
base = sys.argv[1]
for e in Path("/proc").glob("[0-9]*"):
    try:
        cl = (e / "cmdline").read_bytes().replace(b"\0", b" ").decode(
            "utf-8", "replace")
        cwd = os.readlink(e / "cwd")
        if " share " in " " + cl + " " and cwd.startswith(base):
            print(f"pid {e.name} cwd={cwd}")
    except OSError:
        pass
PYEOF
}

cleanup() {
  # Kill any daemon rooted under $WORK (suite-owned). The workdir
  # itself is removed only on a fully green run; on failure it is
  # preserved and its path printed, for forensics.
  python3 - "$WORK" <<'PYEOF'
import os, signal, time
from pathlib import Path
import sys
base = sys.argv[1]
pids = []
for e in Path("/proc").glob("[0-9]*"):
    try:
        cl = (e / "cmdline").read_bytes().replace(b"\0", b" ").decode(
            "utf-8", "replace")
        if " share " in " " + cl + " " and \
                os.readlink(e / "cwd").startswith(base):
            pids.append(int(e.name))
    except OSError:
        pass
for p in pids:
    try: os.kill(p, signal.SIGKILL)
    except OSError: pass
if pids:
    time.sleep(0.5)
PYEOF
  if [ "$FAILN" -eq 0 ]; then
    rm -rf "$WORK"
  else
    echo "forensics preserved in $WORK"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------ raw-sq helper
# All raw SQ work happens in this python helper: subprocess timeouts
# on every call, readiness-gated spawn (wait for the daemon's own
# "Serving" log line before any client op — the Layer 6 lesson),
# clean shutdown of any daemon the helper itself spawned.
cat > "$WORK/rawsq.py" <<'PYEOF'
import os, re, subprocess, sys, time
from pathlib import Path

SQ = os.environ["RAW_SQ"]
COORD_RE = re.compile(r"^\* (\d+)\.(\d+)\.1/(\d+)\.1\.1/(\d+)\.1\.(\d+):")

def run(args, cwd, timeout=30):
    return subprocess.run([SQ, *args], cwd=cwd, capture_output=True,
                          timeout=timeout)

def share_pids(store):
    out = []
    for e in Path("/proc").glob("[0-9]*"):
        try:
            cl = (e / "cmdline").read_bytes().replace(b"\0", b" ") \
                .decode("utf-8", "replace")
            if " share " in " " + cl + " " and \
                    os.readlink(e / "cwd") == str(store):
                out.append(int(e.name))
        except OSError:
            pass
    return out

class RawStore:
    def __init__(self, store, phext_name):
        self.store = Path(store)
        self.name = phext_name
        self.spawned = None
        if not share_pids(self.store):
            log_f = self.store / "rawsq-daemon.log"
            offset = log_f.stat().st_size if log_f.exists() else 0
            log = open(log_f, "ab")
            proc = subprocess.Popen(
                [SQ, "share", phext_name], cwd=self.store, stdout=log,
                stderr=log, stdin=subprocess.DEVNULL,
                start_new_session=True)
            log.close()
            self.spawned = proc
            deadline = time.time() + 60
            ok = False
            while time.time() < deadline:
                if proc.poll() is not None:
                    break
                try:
                    with open(log_f, "rb") as f:
                        f.seek(offset)
                        if b"Serving " in f.read():
                            ok = True
                            break
                except OSError:
                    pass
                time.sleep(0.1)
            if not ok:
                raise RuntimeError("raw sq daemon did not serve in 60s")

    def toc(self):
        r = run(["toc"], self.store, timeout=60)
        if r.returncode != 0:
            raise RuntimeError(f"toc failed rc={r.returncode}")
        return r.stdout.decode("utf-8", "replace")

    def insert(self, coord_, text):
        r = run(["insert", coord_, text], self.store, timeout=30)
        if r.returncode != 0:
            raise RuntimeError(f"insert {coord_} rc={r.returncode}: "
                               f"{r.stderr[:200]!r}")

    def update(self, coord_, text):
        tmp = self.store / ".rawsq-push.tmp"
        tmp.write_text(text)
        try:
            r = run(["push", coord_, str(tmp)], self.store, timeout=30)
        finally:
            tmp.unlink(missing_ok=True)
        if r.returncode != 0:
            raise RuntimeError(f"push {coord_} rc={r.returncode}: "
                               f"{r.stderr[:200]!r}")

    def save(self):
        r = run(["save", self.name], self.store, timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"save rc={r.returncode}")

    def close(self):
        if self.spawned is None:
            return
        try:
            run(["shutdown"], self.store, timeout=15)
        except subprocess.TimeoutExpired:
            pass
        deadline = time.time() + 5
        while share_pids(self.store) and time.time() < deadline:
            time.sleep(0.2)
        for pid in share_pids(self.store):
            try: os.kill(pid, 9)
            except OSError: pass

def main():
    cmd = sys.argv[1]
    store, name = sys.argv[2], sys.argv[3]
    rs = RawStore(store, name)
    try:
        if cmd == "discover":
            proj, sess = int(sys.argv[4]), int(sys.argv[5])
            existing = None
            taken = set()
            for line in rs.toc().splitlines():
                m = COORD_RE.match(line)
                if not m:
                    continue
                p, s, cl, sq_, ch = (int(x) for x in m.groups())
                taken.add((p, s, cl, sq_, ch))
                if (p, s, cl) == (proj, sess, 3) and existing is None:
                    existing = f"{p}.{s}.1/{cl}.1.1/{sq_}.1.{ch}"
            print(f"existing={existing}")
            fresh = f"{proj}.{sess}.1/3.1.1/900.1.1"
            print(f"fresh={fresh}")
            print(f"fresh_taken={(proj, sess, 3, 900, 1) in taken}")
        elif cmd == "insert":
            rs.insert(sys.argv[4], sys.argv[5])
            rs.save()
        elif cmd == "update":
            rs.update(sys.argv[4], sys.argv[5])
            rs.save()
        else:
            raise RuntimeError(f"unknown rawsq command {cmd}")
    finally:
        rs.close()

if __name__ == "__main__":
    main()
PYEOF

rawsq() { # cmd store phext args... (hard outer timeout as a backstop)
  timeout -k 5 300 env RAW_SQ="$REAL_SQ" python3 "$WORK/rawsq.py" "$@"
}

changed_section() { # context output file -> changed-coordinate lines
  awk '/^Coordinates changed since last context:/{f=1; next}
       /^=== /{f=0} f' "$1" | sed -n 's/^  //p' | grep -v '^(' || true
}

# ================================================================ SMALL LEG
echo "=== change detection: small leg ==="
P1="$WORK/small/proj"; H1="$WORK/small/home"
mkdir -p "$P1"
run_ocbox "$P1" "$H1" 60 "$WORK/s-init.out" init || fail CD-S0 "init failed"
run_ocbox "$P1" "$H1" 120 "$WORK/s-start.out" start || fail CD-S0 "start failed"
run_ocbox "$P1" "$H1" 120 "$WORK/s-exec1.out" exec echo alpha-one >/dev/null
run_ocbox "$P1" "$H1" 120 "$WORK/s-exec2.out" exec echo beta-two >/dev/null
run_ocbox "$P1" "$H1" 120 "$WORK/s-stop.out" stop || fail CD-S0 "stop failed"
STORE1="$P1/.ocbox-phext"
note "session built and stopped; store: $STORE1"

run_ocbox "$P1" "$H1" 120 "$WORK/s-ctx1.out" context || fail CD-S1 "baseline context rc!=0"
run_ocbox "$P1" "$H1" 120 "$WORK/s-ctx2.out" context || fail CD-S1 "no-change context rc!=0"
if grep -q "(no changes" "$WORK/s-ctx2.out"; then
  pass CD-S1 "baseline established; second context verdict: $(grep '(no changes' "$WORK/s-ctx2.out" | head -1 | sed 's/^ *//')"
else
  fail CD-S1 "second context did not report '(no changes': $(tail -5 "$WORK/s-ctx2.out")"
fi
note "no-change context output bytes: $(wc -c < "$WORK/s-ctx2.out")"

DISC="$(rawsq discover "$STORE1" proj.phext 2 1)" || fail CD-S2 "rawsq discover failed"
EXISTING="$(echo "$DISC" | sed -n 's/^existing=//p')"
FRESH="$(echo "$DISC" | sed -n 's/^fresh=//p')"
FRESH_TAKEN="$(echo "$DISC" | sed -n 's/^fresh_taken=//p')"
note "existing stdout scroll: $EXISTING ; fresh coord: $FRESH (taken=$FRESH_TAKEN)"
[ "$FRESH_TAKEN" = "False" ] || fail CD-S2 "fresh coord $FRESH already taken — suite bug"

rawsq insert "$STORE1" proj.phext "$FRESH" "out-of-band insert: the detector must see this" \
  || fail CD-S2 "raw insert failed"
rawsq update "$STORE1" proj.phext "$EXISTING" "alpha-one MUTATED out of band" \
  || fail CD-S3 "raw update failed"
note "out-of-band mutation saved (insert $FRESH, update $EXISTING); raw daemon shut down"

run_ocbox "$P1" "$H1" 120 "$WORK/s-ctx3.out" context || fail CD-S2 "post-mutation context rc!=0"
CHANGED="$(changed_section "$WORK/s-ctx3.out")"
note "context reports changed: $(echo "$CHANGED" | tr '\n' ' ')"
if echo "$CHANGED" | grep -qx "$FRESH"; then
  pass CD-S2 "out-of-band INSERT detected: $FRESH"
else
  fail CD-S2 "context MISSED the out-of-band insert at $FRESH (reported: $CHANGED)"
fi
if echo "$CHANGED" | grep -qx "$EXISTING"; then
  pass CD-S3 "out-of-band UPDATE detected: $EXISTING"
else
  fail CD-S3 "context MISSED the out-of-band update at $EXISTING (reported: $CHANGED)"
fi

# ================================================================ STRESS LEG
echo "=== change detection: stress leg (real 5.2 MB phext) ==="
P2="$WORK/stress/proj"; H2="$WORK/stress/home"
mkdir -p "$P2"
run_ocbox "$P2" "$H2" 60 "$WORK/l-init.out" init || fail CD-L0 "init failed"
SQ_BIN="" OCBOX_OPLOG=""
run_ocbox "$P2" "$H2" 600 "$WORK/l-tele.out" teleport-in --adopt "$STRESS_SRC"
if [ $? -eq 0 ] && grep -q "integrity: OK" "$WORK/l-tele.out"; then
  pass CD-L0 "stress phext teleported in ($(wc -c < "$STRESS_SRC") B, integrity OK)"
else
  fail CD-L0 "teleport-in failed: rc=$? err=$(cat "$WORK/l-tele.out.err" 2>/dev/null | head -3)"
fi
STORE2="$P2/.ocbox-phext"

run_ocbox "$P2" "$H2" 600 "$WORK/l-ctx1.out" context || fail CD-L1 "baseline context rc!=0"

# op-counting SQ_BIN wrapper for the no-change measurement
cat > "$WORK/sq_count.py" <<PYEOF
#!/usr/bin/env python3
import os, sys
with open(os.environ["OCBOX_OPLOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
os.execv("$REAL_SQ", ["$REAL_SQ"] + sys.argv[1:])
PYEOF
chmod +x "$WORK/sq_count.py"
: > "$WORK/oplog.txt"
SQ_BIN="$WORK/sq_count.py" OCBOX_OPLOG="$WORK/oplog.txt" \
  run_ocbox "$P2" "$H2" 600 "$WORK/l-ctx2.out" context || fail CD-L1 "no-change context rc!=0"
SQ_BIN="" OCBOX_OPLOG=""
OPS_TOTAL="$(wc -l < "$WORK/oplog.txt")"
OPS_SHARE="$(grep -c '^share' "$WORK/oplog.txt" || true)"
OPS_CHAN="$(grep -vc '^share' "$WORK/oplog.txt" || true)"
CTX_BYTES="$(wc -c < "$WORK/l-ctx2.out")"
if grep -q "(no changes" "$WORK/l-ctx2.out"; then
  pass CD-L1 "stress no-change verdict OK — output ${CTX_BYTES} B, SQ invocations: ${OPS_TOTAL} total (${OPS_SHARE} share spawn, ${OPS_CHAN} channel ops)"
else
  fail CD-L1 "stress context did not report '(no changes': $(tail -5 "$WORK/l-ctx2.out")"
fi
note "op log:"; sed 's/^/    op: /' "$WORK/oplog.txt"
note "no-change context output (verbatim):"; sed 's/^/    | /' "$WORK/l-ctx2.out"

DISC2="$(rawsq discover "$STORE2" stress.phext 2 1)" || fail CD-L2 "rawsq discover failed (stress)"
FRESH2="$(echo "$DISC2" | sed -n 's/^fresh=//p')"
FRESH2_TAKEN="$(echo "$DISC2" | sed -n 's/^fresh_taken=//p')"
note "stress fresh coord: $FRESH2 (taken=$FRESH2_TAKEN)"
[ "$FRESH2_TAKEN" = "False" ] || fail CD-L2 "fresh coord $FRESH2 already taken — suite bug"
rawsq insert "$STORE2" stress.phext "$FRESH2" "single out-of-band scroll at stress scale" \
  || fail CD-L2 "raw insert failed (stress)"
note "one scroll inserted out of band at $FRESH2; raw daemon shut down"

run_ocbox "$P2" "$H2" 600 "$WORK/l-ctx3.out" context || fail CD-L2 "post-mutation context rc!=0"
CHANGED2="$(changed_section "$WORK/l-ctx3.out")"
NCHANGED="$(echo "$CHANGED2" | grep -c . || true)"
note "context reports changed ($(echo "$NCHANGED")): $CHANGED2"
if [ "$CHANGED2" = "$FRESH2" ]; then
  pass CD-L2 "stress-scale mutation detected exactly: only $FRESH2 reported changed"
else
  fail CD-L2 "expected exactly '$FRESH2' changed; got: $(echo "$CHANGED2" | tr '\n' ' ')"
fi

# ================================================================ HYGIENE
LEFT="$(sq_census)"
if [ -z "$LEFT" ]; then
  pass CD-H1 "no suite daemons left running"
else
  fail CD-H1 "daemons left behind: $LEFT"
fi

echo "=== change_detection: $PASSN passed, $FAILN failed${FAILED:+ (failed:$FAILED)} ==="
[ "$FAILN" -eq 0 ]
