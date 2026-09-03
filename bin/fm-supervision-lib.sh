# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

FM_SUP_UNREADABLE_AGE=999999
# fm_sup_path_age <path> -> seconds since mtime, or FM_SUP_UNREADABLE_AGE.
# THE SAME CONTRACT fm_path_age carries in bin/fm-wake-lib.sh, enforced here at
# this function's single return boundary: what escapes is ALWAYS either a plain
# non-negative base-10 number of seconds that was really measured, or the
# sentinel. Never empty, never negative, never a non-numeric token.
# This file deliberately does not call fm_path_age directly: bin/fm-wake-lib.sh
# runs `mkdir -p "$STATE"` at source time, and this library is sourced on its own
# by consumers that must not acquire that side effect. The contract is therefore
# restated rather than delegated, and it must stay identical in shape to
# fm_path_age's - extend both together, and do not let either grow a per-input
# special case the other lacks.
# It is load-bearing, not cosmetic. FM_SUP_WATCHER_FRESH below has one consumer,
# the away-mode allow gate in bin/fm-turnend-guard.sh, and a raw subtraction let a
# beacon stamped in the future read as FRESH (a negative age is `-lt` any grace),
# which allowed a blind turn end on a beacon whose age was never measurable. A
# non-numeric mtime was worse: under the `set -u` both guards run, the arithmetic
# aborted the whole script, and for the Claude Stop hook that exit is not the
# blocking rc 2, so the turn also ended blind.
fm_sup_path_age() {
  local path=$1 m now
  m=$(fm_sup_stat_mtime "$path") || { echo "$FM_SUP_UNREADABLE_AGE"; return; }
  case "$m" in
    ''|*[!0-9]*) echo "$FM_SUP_UNREADABLE_AGE"; return ;;
  esac
  now=$(date +%s)
  case "$now" in
    ''|*[!0-9]*) echo "$FM_SUP_UNREADABLE_AGE"; return ;;
  esac
  case "$(( 10#$now - 10#$m ))" in
    ''|*[!0-9]*) echo "$FM_SUP_UNREADABLE_AGE" ;;
    *) echo $(( 10#$now - 10#$m )) ;;
  esac
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    # Both the freshness verdict and the banner text come from the one contracted
    # read, so an unmeasurable beacon can neither pass as fresh nor be printed to
    # the captain as a duration that was actually observed.
    age=$(fm_sup_path_age "$beat")
    if [ "$age" = "$FM_SUP_UNREADABLE_AGE" ]; then
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
