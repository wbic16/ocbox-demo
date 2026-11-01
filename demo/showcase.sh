#!/bin/bash
# showcase.sh — Layer 3: real-tool gauntlet + ffmpeg showcase.
# One ocbox session on the `showcase` sample project; every tool run is a
# separate exec, so each lands in its own sequence lane of the phext.
# Own state under demo/.showcase-state/ (gitignored except the final
# phext). Tees to demo/SHOWCASE-TRANSCRIPT.txt. The final verification
# reads the phext DIRECTLY through SQ (toc + select; json-export is lossy
# for backslashes/tabs) and cross-checks the workspace artifacts.
set -u

# Re-exec under a minimal environment (published transcript hygiene —
# the phext env lane records variable NAMES only, keep them deliberate).
if [ -z "${OCBOX_SHOWCASE_SANITIZED:-}" ] && [ -z "${OCBOX_DEMO_KEEP_ENV:-}" ]; then
  exec env -i PATH="$PATH" HOME="$HOME" OCBOX_SHOWCASE_SANITIZED=1 /bin/bash "$0" "$@"
fi

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$DEMO_DIR")"
STATE="$DEMO_DIR/.showcase-state"
SHIM="$STATE/shim"
STORE="$STATE/store"
PROJ="$STATE/project"
TRANSCRIPT="$DEMO_DIR/SHOWCASE-TRANSCRIPT.txt"
export OCBOX_SHIM_HOME="$SHIM"
OCBOX="$ROOT_DIR/ocbox"
CURL_RC=""

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
  LAST_RC=$rc
  return 0
}

main() {
  echo "=== ocbox x phext SHOWCASE (real tools + ffmpeg) — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "--- cleaning prior showcase state ---"
  stop_daemon
  rm -rf "$STATE"
  mkdir -p "$SHIM" "$STORE" "$PROJ"
  cp -r "$DEMO_DIR/showcase-sample/." "$PROJ/"
  printf '{"project": "showcase", "phext_store": "%s", "env_refs": []}\n' "$STORE" > "$PROJ/.ocbox.json"
  cd "$PROJ"

  echo "\$ ocbox start"
  "$OCBOX" start

  echo "--- ffmpeg: generate 6s test-pattern video + tone (lavfi only) ---"
  echo "(watch the stderr lane at verification: ffmpeg's CR progress lines are the"
  echo " classic logging edge case — they must land intact in class 4)"
  run 'ffmpeg -y -f lavfi -i testsrc2=duration=6:size=640x360:rate=30 -f lavfi -i sine=frequency=440:duration=6 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest out.mp4'
  echo "--- ffprobe: JSON to stdout ---"
  run 'ffprobe -v error -show_format -show_streams -of json out.mp4'
  echo "--- ffprobe: same JSON to a file, for jq ---"
  run 'ffprobe -v error -show_format -show_streams -of json out.mp4 > probe_out.json'
  echo "--- ffmpeg: transcode/scale to 320px WebM (VP8) ---"
  run 'ffmpeg -y -i out.mp4 -vf scale=320:-2 -c:v libvpx -b:v 300k -c:a libopus clip.webm'
  echo "--- ffprobe: WebM JSON to stdout ---"
  run 'ffprobe -v error -show_format -show_streams -of json clip.webm'
  echo "--- jq: pretty-print the ffprobe JSON ---"
  run 'jq . probe_out.json'
  echo "--- jq: malformed JSON (exit code + stderr are the record) ---"
  run "printf '{not json' > bad.json; jq . bad.json"
  echo "--- sqlite3: create media.db, insert the media rows ---"
  run 'sqlite3 media.db "CREATE TABLE media(name TEXT, bytes INTEGER, duration REAL); INSERT INTO media VALUES('"'"'out.mp4'"'"', $(stat -c%s out.mp4), $(jq -r .format.duration probe_out.json)); INSERT INTO media VALUES('"'"'clip.webm'"'"', $(stat -c%s clip.webm), $(jq -r .format.duration probe_out.json));"'
  echo "--- sqlite3: query them back ---"
  run 'sqlite3 media.db "SELECT name, bytes, duration FROM media ORDER BY name;"'
  echo "--- git: init + commit the session's work ---"
  run "git init -q && git config user.email demo@example.com && git config user.name 'Ocbox Demo' && git add -A && git commit -qm 'showcase session work'"
  echo "--- git: log as a later exec ---"
  run 'git log --oneline'
  echo "--- rg: match (exit 0) ---"
  run 'rg printf hello.c'
  echo "--- rg: no match (exit 1 — a result, not a failure) ---"
  run 'rg zzz_no_match_zzz hello.c'
  echo "--- tar + gzip: archive the media, list it ---"
  run 'mkdir -p logs && cp probe_out.json logs/ && tar -czf media.tar.gz out.mp4 clip.webm && tar -tzf media.tar.gz'
  echo "--- zip: the logs dir ---"
  run 'zip -q logs.zip logs/probe_out.json && unzip -l logs.zip'
  echo "--- gcc: compile hello.c and run it ---"
  run 'gcc -O2 -o hello hello.c && ./hello'
  echo "--- node: print JSON ---"
  run 'node -e "console.log(JSON.stringify({tool: '"'"'node'"'"', value: 6 * 7}))"'
  echo "--- openssl: sha256 of out.mp4 + random base64 ---"
  run 'openssl dgst -sha256 out.mp4 && openssl rand -base64 24'
  echo "--- curl: localhost fetch of hello.txt from a workspace http.server ---"
  run 'python3 -m http.server 18799 --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!; sleep 1; curl -s http://127.0.0.1:18799/hello.txt; RC=$?; kill $SRV 2>/dev/null; exit $RC'
  CURL_RC=$LAST_RC
  if [ "$CURL_RC" != "0" ]; then
    echo "NOTED SKIP: localhost curl fetch failed in this sandbox (ocbox exit $CURL_RC) — recorded, not faked."
  fi

  echo "\$ ocbox stop"
  "$OCBOX" stop

  echo
  echo "=== VERIFICATION (direct SQ reads + workspace cross-check) ==="
  python3 - "$STORE" "$SHIM" "$CURL_RC" <<'PYEOF'
import base64, hashlib, json, re, subprocess, sys
from pathlib import Path

store, shim, curl_rc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
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
                if "share" in _c and "showcase.phext" in _c and \
                        _os.readlink(_e / "cwd") == str(store):
                    _found.append(int(_e.name))
            except OSError:
                continue
        return _found
    def _spawn_gated():
        _logf = store / ".verify-daemon.log"
        _off = _logf.stat().st_size if _logf.exists() else 0
        _log = open(_logf, "ab")
        _proc = subprocess.Popen([SQ, "share", "showcase.phext"], cwd=store,
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
        for line in get("toc", p="showcase").splitlines():
            if line.startswith("* "):
                c = line[2:].split(":", 1)[0].strip()
                if c:
                    items.append({"coord": c,
                                  "scroll": get("select", p="showcase", c=c)})
        return json.dumps(items)
    raise ValueError(endpoint)

E = {}
for line in get("toc", p="showcase").splitlines():
    if line.startswith("* "):
        c = line[2:].split(":", 1)[0].strip()
        if c:
            E[c] = get("select", p="showcase", c=c)

COORD = re.compile(r"^(\d+)\.(\d+)\.1/(\d+)\.1\.1/(\d+)\.1\.(\d+)$")
def lane(sess, cls, seq):
    out = {}
    for c, s in E.items():
        m = COORD.match(c)
        if m and (int(m.group(2)), int(m.group(3)), int(m.group(4))) == (sess, cls, seq):
            out[int(m.group(5))] = s
    return [out[k] for k in sorted(out)]

def stream(sess, cls, seq):
    parts = lane(sess, cls, seq)
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

trans = {}
for c, s in E.items():
    m = COORD.match(c)
    if m and int(m.group(3)) == 2:
        trans[int(m.group(4))] = (s.splitlines()[0], kv(s))

def find(needle):
    hits = [(seq, cmd, d) for seq, (cmd, d) in sorted(trans.items()) if needle in cmd]
    assert hits, f"no transcript matching {needle!r}"
    return hits[0]

results = []
def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")

seqs = sorted(trans)
check("seq lanes contiguous", seqs == list(range(2, 2 + len(seqs))),
      f"{len(seqs)} execs, seqs 2..{seqs[-1]}")

seq, cmd, d = find("testsrc2")
err = stream(1, 4, seq)
check("ffmpeg stderr lane holds 'frame=' progress", b"frame=" in err,
      f"{len(err)} stderr bytes in {len(lane(1, 4, seq))} scroll(s)")

seq, cmd, d = find("ffprobe -v error -show_format -show_streams -of json out.mp4")
probe = None
try:
    probe = json.loads(stream(1, 3, seq).decode("utf-8"))
except Exception as e:
    print("ffprobe JSON parse error:", e)
check("ffprobe stdout reassembles to valid JSON",
      probe is not None and "streams" in probe and "format" in probe,
      f"{len(probe.get('streams', []))} streams" if probe else "")

ws = next(shim.glob("sessions/*/workspace"))
def sha_ws(name):
    return hashlib.sha256((ws / name).read_bytes()).hexdigest()

man = {}
for ln in E.get("2.1.1/6.1.1/1.1.1", "").splitlines():
    p = ln.split("\t")
    if len(p) == 3:
        man[p[0]] = p[2]
for f in ("out.mp4", "clip.webm", "media.db"):
    check(f"manifest hash == sha256sum({f})", man.get(f) == sha_ws(f), man.get(f, "?")[:16])

seq, cmd, d = find("openssl dgst")
out_txt = stream(1, 3, seq).decode("utf-8", "replace")
check("openssl stdout records out.mp4 sha256", sha_ws("out.mp4") in out_txt, "")

diff = E.get("2.1.1/5.1.1/1.1.1", "")
check("diff lists created media files", "out.mp4" in diff and "clip.webm" in diff, "")

seq, cmd, d = find("git log")
check("git log recorded", b"showcase session work" in stream(1, 3, seq), "")

seq, cmd, d = find("bad.json")
check("jq malformed: nonzero exit + stderr",
      d["exit"] != "0" and len(stream(1, 4, seq)) > 0, f"exit {d['exit']}")

seq, cmd, d = find("SELECT name, bytes, duration")
rows = stream(1, 3, seq).decode("utf-8", "replace")
check("sqlite query returns both rows", "out.mp4" in rows and "clip.webm" in rows,
      rows.replace("\n", " | ")[:80])

seq, cmd, d = find("rg zzz_no_match")
check("rg no-match recorded as exit 1", d["exit"] == "1", "")

seq, cmd, d = find("./hello")
check("gcc binary ran", b"computed = 42" in stream(1, 3, seq), "")

seq, cmd, d = find("http.server")
if curl_rc == "0":
    check("curl localhost fetch recorded",
          b"hello from the showcase workspace" in stream(1, 3, seq), "")
else:
    print(f"NOTED SKIP  curl localhost fetch (ocbox exit {curl_rc} in this sandbox)")

phext = store / "showcase.phext"
print(f"phext size: {phext.stat().st_size} bytes, {len(E)} scrolls")
failed = [n for n, ok in results if not ok]
print(f"SHOWCASE RESULT: {len(results) - len(failed)}/{len(results)} PASS"
      + (f" — FAILED: {failed}" if failed else ""))
sys.exit(1 if failed else 0)
PYEOF
  local rc=$?
  echo
  echo "Showcase phext: $STORE/showcase.phext"
  echo "SHA-256: $(sha256sum "$STORE/showcase.phext" | awk '{print $1}')"
  echo "Size: $(stat -c %s "$STORE/showcase.phext") bytes"
  stop_daemon
  sleep 1
  echo "=== showcase complete (verification rc=$rc) ==="
  return $rc
}

main 2>&1 | tee "$TRANSCRIPT"
test "${PIPESTATUS[0]}" -eq 0
