#!/usr/bin/env bash
# End-to-end demonstration of the pipeline-custody exemption fixes, driven
# through the real supervision surface a firstmate operator sees:
#   bin/fm-crew-state.sh <id>   -> the one authoritative crew-state line
#   crew_absorb_class <id>      -> whether supervision ABSORBS or SURFACES a wake
#
# The same three scenarios are replayed against the pre-fix commit and the
# post-fix commit of the SAME repository, with a fake `no-mistakes` CLI serving
# the exact `axi status` shapes the review's fixtures recorded.
set -u

REPO=${1:?repo path}
BEFORE_REF=${2:?before ref}
AFTER_REF=${3:?after ref}

SCRATCH=$(mktemp -d /tmp/fm-custody-demo.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
for side in before after; do
  mkdir -p "$SCRATCH/$side"
done
git -C "$REPO" archive "$BEFORE_REF" | tar -x -C "$SCRATCH/before"
git -C "$REPO" archive "$AFTER_REF"  | tar -x -C "$SCRATCH/after"

# A ULID whose 48-bit time prefix is <seconds> ago: the run id `axi status`
# publishes for a run created then.
ulid_ago() {
  local a='0123456789ABCDEFGHJKMNPQRSTVWXYZ' ms out='' i=0
  ms=$(( ( $(date +%s) - $1 ) * 1000 ))
  while [ "$i" -lt 10 ]; do out="${a:$((ms % 32)):1}$out"; ms=$((ms / 32)); i=$((i + 1)); done
  printf '%s0123456789ABCDEF' "$out"
}

# --- axi status fixtures -----------------------------------------------------

# A daemon that died without writing an outcome: still `running`, still
# pipeline_owned, at a lane head that is not a git object in the worktree.
stranded_status() {  # <age-secs>
  cat <<EOF
run:
  id: "$(ulid_ago "$1")"
  branch: fm/demo-crew
  status: running
  head: "f0f0f0f0"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
branch_sync:
  state: pipeline_owned
  changed: false
  local:
    branch: fm/demo-crew
    head: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
    clean: true
EOF
}

# The pipeline does NOT own this branch (branch_sync.state: synced). A nested
# sub-block carries its own `state: pipeline_owned` AHEAD of the real value.
nested_state_spoof_status() {
  cat <<EOF
run:
  id: "$(ulid_ago 600)"
  branch: fm/demo-crew
  status: running
  head: "f0f0f0f0"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
branch_sync:
  pipeline:
    state: pipeline_owned
    lane: review
  state: synced
  changed: false
EOF
}

# --- one crew sandbox --------------------------------------------------------

make_case() {  # <side> <name> -> case dir
  local co="$SCRATCH/$1" d="$SCRATCH/$1/case-$2"
  mkdir -p "$d/state" "$d/fakebin"
  git init -q "$d/wt"
  git -C "$d/wt" -c user.email=d@d -c user.name=d commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/demo-crew
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift; case "${1:-}" in status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;; esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;   # an idle pane: no busy signature
esac
exit 0
SH
  chmod +x "$d/fakebin/no-mistakes" "$d/fakebin/tmux"
  {
    printf 'window=fm:fm-demo-crew\n'
    printf 'worktree=%s\n' "$d/wt"
    printf 'kind=ship\n'
    printf 'harness=claude\n'
  } > "$d/state/demo-crew.meta"
  printf 'working: pushed through the gate\n' > "$d/state/demo-crew.status"
  local gen
  gen=$("$co/bin/fm-busy-event.sh" arm "$d/state" demo-crew)
  "$co/bin/fm-busy-event.sh" apply "$d/state" demo-crew idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null
  printf '%s\n' "$d"
}

report() {  # <side> <case-name> <status-toon>
  local side=$1 name=$2 toon=$3 d line absorb
  d=$(make_case "$side" "$name")
  line=$(FM_FAKE_AXI_STATUS="$toon" FM_FAKE_RUNS_LIST="" \
    PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    "$SCRATCH/$side/bin/fm-crew-state.sh" demo-crew)
  absorb=$(FM_FAKE_AXI_STATUS="$toon" FM_FAKE_RUNS_LIST="" \
    PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" bash -c '
      . "$1/bin/fm-classify-lib.sh"; crew_absorb_class demo-crew' _ "$SCRATCH/$side")
  printf '  %-6s  fm-crew-state.sh demo-crew -> %s\n' "$side" "$line"
  printf '  %-6s  crew_absorb_class demo-crew -> %s   (%s)\n' "$side" "$absorb" \
    "$( [ "$absorb" = working ] && printf 'wake ABSORBED - crew invisible' || printf 'wake SURFACES to the captain' )"
}

banner() { printf '\n=== %s ===\n' "$1"; }

printf 'firstmate pipeline-custody exemption - end-to-end supervision surface\n'
printf 'before = %s (pre-fix)   after = %s (post-fix)\n' \
  "$(git -C "$REPO" rev-parse --short "$BEFORE_REF")" "$(git -C "$REPO" rev-parse --short "$AFTER_REF")"

banner "Finding 2: daemon died 30h ago, axi status still says running + pipeline_owned"
report before stranded "$(stranded_status 108000)"
report after  stranded "$(stranded_status 108000)"

banner "Control: the same crew with a run created 10 minutes ago (legitimately working)"
report before live "$(stranded_status 600)"
report after  live "$(stranded_status 600)"

banner "Finding 1: branch_sync.state is 'synced'; a nested sub-block spoofs 'pipeline_owned'"
report before spoof "$(nested_state_spoof_status)"
report after  spoof "$(nested_state_spoof_status)"
printf '\n'
