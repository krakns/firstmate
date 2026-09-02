#!/usr/bin/env bash
# End-to-end reproduction of the away-mode turn-end guard false alarm.
#
# Drives the REAL away-mode daemon (bin/fm-supervise-daemon.sh) wrapping the
# REAL one-shot watcher (bin/fm-watch.sh) over a real home with state/.afk set
# and one task in flight, and samples the REAL turn-end guard
# (bin/fm-turnend-guard.sh) at 40 simulated turn boundaries.
#
# usage: fm-afk-repro.sh <repo-root> <label> <samples>
set -u
ROOT=$1; LABEL=$2; SAMPLES=${3:-40}

HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-repro-$LABEL.XXXXXX")
HOME_DIR=$(cd -P -- "$HOME_DIR" && pwd -P)
cp -R "$ROOT"/. "$HOME_DIR"/ 2>/dev/null
rm -rf "$HOME_DIR/.git"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/fakebin"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"

# Minimal tmux surface: the daemon only needs its supervisor pane to resolve
# and be quiet. Nothing is ever injected in this run.
cat > "$HOME_DIR/fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  list-windows) exit 0 ;;
  capture-pane) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 1
TMUX
chmod +x "$HOME_DIR/fakebin/tmux"

# Away mode on, one task in flight - exactly the reported situation.
date '+%s' > "$HOME_DIR/state/.afk"
: > "$HOME_DIR/state/task1.meta"
printf 'working: building the thing\n' > "$HOME_DIR/state/task1.status"

export PATH="$HOME_DIR/fakebin:$PATH"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane
export FM_HOME="$HOME_DIR"
export FM_POLL=1 FM_HEARTBEAT=6 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
export FM_INJECT_SKIP=all FM_WEDGE_ALARM_EXEC=discard

"$HOME_DIR/bin/fm-supervise-daemon.sh" >"$HOME_DIR/daemon.out" 2>"$HOME_DIR/daemon.err" &
DAEMON_PID=$!
cleanup() { kill "$DAEMON_PID" 2>/dev/null; pkill -P "$DAEMON_PID" 2>/dev/null; }
trap cleanup EXIT

# Let the daemon acquire its lock and get the first watcher cycle underway.
sleep 6

beacon_age() {
  local f="$HOME_DIR/state/.last-watcher-beat" m now
  [ -e "$f" ] || { printf 'none\n'; return; }
  m=$(stat -f %m "$f" 2>/dev/null) || { printf '?\n'; return; }
  now=$(date '+%s'); printf '%ss\n' $((now - m))
}
watcher_pid() { cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || printf '%s\n' -; }
watcher_live() {
  local p; p=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null) || { printf 'no-lock\n'; return; }
  if kill -0 "$p" 2>/dev/null; then printf 'live\n'; else printf 'dead\n'; fi
}

printf '=== %s: 40 turn-end samples, away mode ON, daemon supervising ===\n' "$LABEL"
blocked=0; allowed=0; pids=""
for i in $(seq 1 "$SAMPLES"); do
  age=$(beacon_age); wl=$(watcher_live); wp=$(watcher_pid)
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$HOME_DIR" \
        bash "$HOME_DIR/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  dstate=dead; kill -0 "$DAEMON_PID" 2>/dev/null && dstate=alive
  if [ "$rc" -eq 2 ]; then
    blocked=$((blocked + 1))
    printf '%02d  BLOCKED  daemon=%s watcher=%-7s watcher_pid=%-7s beacon=%s\n' "$i" "$dstate" "$wl" "$wp" "$age"
    printf '%s\n' "$out" | sed -n '1,3p' | sed 's/^/         | /'
  else
    allowed=$((allowed + 1))
    printf '%02d  allowed  daemon=%s watcher=%-7s watcher_pid=%-7s beacon=%s\n' "$i" "$dstate" "$wl" "$wp" "$age"
  fi
  case " $pids " in *" $wp "*) : ;; *) pids="$pids $wp" ;; esac
  sleep 0.4
done
printf -- '--- %s: %d/%d turn-end samples BLOCKED, %d allowed\n' "$LABEL" "$blocked" "$SAMPLES" "$allowed"
printf -- '--- distinct watcher pids seen while the daemon supervised:%s\n' "$pids"

printf '\n=== %s: genuine lapse control - kill the daemon and its watcher, away mode still ON ===\n' "$LABEL"
wp=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
kill "$DAEMON_PID" 2>/dev/null; [ -n "$wp" ] && kill "$wp" 2>/dev/null
sleep 2
kill -9 "$DAEMON_PID" 2>/dev/null; [ -n "$wp" ] && kill -9 "$wp" 2>/dev/null
sleep 1
touch "$HOME_DIR/state/.last-watcher-beat"   # beacon deliberately FRESH
printf 'daemon alive: %s   watcher alive: %s   beacon age: %s   away mode: %s\n' \
  "$(kill -0 "$DAEMON_PID" 2>/dev/null && echo yes || echo no)" \
  "$(watcher_live)" "$(beacon_age)" \
  "$([ -e "$HOME_DIR/state/.afk" ] && echo on || echo off)"
out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$HOME_DIR" \
      bash "$HOME_DIR/bin/fm-turnend-guard.sh" 2>&1); rc=$?
printf 'guard exit=%d (2 = blocked)\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
