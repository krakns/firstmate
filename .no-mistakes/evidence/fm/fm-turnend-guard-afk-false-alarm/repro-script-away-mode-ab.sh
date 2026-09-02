#!/usr/bin/env bash
# A/B on ONE live away-mode daemon: away mode is the only variable.
# The daemon is SIGSTOPped so it cannot restart its watcher, and its watcher is
# killed - i.e. the exact hand-off shape, frozen, with the beacon kept fresh.
set -u
ROOT=$1; LABEL=$2
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-ab-$LABEL.XXXXXX"); HOME_DIR=$(cd -P -- "$HOME_DIR" && pwd -P)
cp -R "$ROOT"/. "$HOME_DIR"/ 2>/dev/null
rm -rf "$HOME_DIR/.git"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/fakebin"
git init -q "$HOME_DIR"; git -C "$HOME_DIR" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cat > "$HOME_DIR/fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0;; esac; done; printf 'fakepane\n'; exit 0 ;;
  list-windows|capture-pane|send-keys) exit 0 ;;
esac
exit 1
TMUX
chmod +x "$HOME_DIR/fakebin/tmux"
date '+%s' > "$HOME_DIR/state/.afk"; : > "$HOME_DIR/state/task1.meta"; printf 'working: x\n' > "$HOME_DIR/state/task1.status"
export PATH="$HOME_DIR/fakebin:$PATH" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_HOME="$HOME_DIR"
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane FM_POLL=1 FM_HEARTBEAT=600 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_INJECT_SKIP=all
"$HOME_DIR/bin/fm-supervise-daemon.sh" >"$HOME_DIR/daemon.out" 2>"$HOME_DIR/daemon.err" & D=$!
trap 'kill -CONT $D 2>/dev/null; kill $D 2>/dev/null; pkill -P $D 2>/dev/null' EXIT
sleep 8
W=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
kill -STOP "$D" 2>/dev/null            # daemon alive, frozen: cannot restart the watcher
[ -n "$W" ] && kill "$W" 2>/dev/null; sleep 2
touch "$HOME_DIR/state/.last-watcher-beat"

run_guard() {
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$HOME_DIR" bash "$HOME_DIR/bin/fm-turnend-guard.sh" 2>&1
}
report() {
  local out rc; out=$(run_guard); rc=$?
  printf 'away mode: %s | daemon pid %s alive: %s | watcher lock: %s | beacon: fresh\n' \
    "$([ -e "$HOME_DIR/state/.afk" ] && echo ON || echo OFF)" "$D" \
    "$(kill -0 "$D" 2>/dev/null && echo yes || echo no)" \
    "$([ -e "$HOME_DIR/state/.watch.lock/pid" ] && echo held || echo 'none (hand-off)')"
  printf 'guard exit=%d  ->  %s\n' "$rc" "$([ "$rc" -eq 2 ] && echo BLOCKED || echo allowed)"
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  | /'
  printf '\n'
}
printf '=== %s / A: away mode ON, daemon owns supervision, no watcher process ===\n' "$LABEL"; report
rm -f "$HOME_DIR/state/.afk"
printf '=== %s / B: same daemon, same lock, away mode OFF ===\n' "$LABEL"; report
