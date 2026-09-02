#!/usr/bin/env bash
# The daemon cannot read its own process identity at startup (ps unreadable).
# It must keep running and SAY SO, because the turn-end guard then cannot
# recognize away-mode supervision.
set -u
ROOT=$1; LABEL=$2
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-noident-$LABEL.XXXXXX"); HOME_DIR=$(cd -P -- "$HOME_DIR" && pwd -P)
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
printf '#!/bin/sh\nexit 1\n' > "$HOME_DIR/fakebin/ps"; chmod +x "$HOME_DIR/fakebin/ps"
date '+%s' > "$HOME_DIR/state/.afk"; : > "$HOME_DIR/state/task1.meta"; printf 'working: x\n' > "$HOME_DIR/state/task1.status"
export FM_STATE_OVERRIDE="$HOME_DIR/state" FM_HOME="$HOME_DIR"
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fakepane FM_POLL=1 FM_HEARTBEAT=600 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_INJECT_SKIP=all
PATH="$HOME_DIR/fakebin:$PATH" "$HOME_DIR/bin/fm-supervise-daemon.sh" >"$HOME_DIR/daemon.out" 2>"$HOME_DIR/daemon.err" & D=$!
trap 'kill $D 2>/dev/null; pkill -P $D 2>/dev/null' EXIT
sleep 6
printf '=== %s: away-mode daemon started with an unreadable ps ===\n' "$LABEL"
printf 'daemon alive: %s\n' "$(kill -0 $D 2>/dev/null && echo yes || echo no)"
printf 'daemon lock records pid-identity: %s\n' "$([ -e "$HOME_DIR/state/.supervise-daemon.lock/pid-identity" ] && echo yes || echo no)"
printf 'daemon log:\n'; sed 's/^/  | /' "$HOME_DIR/state/.supervise-daemon.log"
W=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
kill -STOP "$D" 2>/dev/null; [ -n "$W" ] && kill "$W" 2>/dev/null; sleep 2
touch "$HOME_DIR/state/.last-watcher-beat"
out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$HOME_DIR" bash "$HOME_DIR/bin/fm-turnend-guard.sh" 2>&1); rc=$?
printf 'turn-end guard at the hand-off, away mode ON, no recorded identity: exit=%d (%s)\n' "$rc" "$([ "$rc" -eq 2 ] && echo BLOCKED || echo allowed)"
printf '%s\n' "$out" | sed 's/^/  | /'
kill -CONT "$D" 2>/dev/null
