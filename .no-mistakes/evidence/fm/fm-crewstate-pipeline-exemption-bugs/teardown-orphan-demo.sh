#!/usr/bin/env bash
# End-to-end demonstration of Finding 3, driven through the real operator
# surface: `bin/fm-teardown.sh <task>` on a task whose no-mistakes run is PARKED
# at a gate while the pipeline owns the branch (its lane head is not a git
# object in the worktree - the recorded incident was parked 7h39m).
#
# The observable end-user artifact is the no-mistakes command teardown actually
# issued before removing the worker. If no `axi abort` is issued, the parked run
# is orphaned and keeps holding a fleet slot with nobody left to answer its gate.
#
# The sandbox (real git project + origin + worktree, fake treehouse/tmux/gh/
# no-mistakes) is the repository's own tests/fm-teardown.test.sh harness with
# its assertion list stripped, so the same fixture is replayed against both the
# pre-fix and post-fix bin/.
set -u

REPO=${1:?repo path}
BEFORE_REF=${2:?before ref}
AFTER_REF=${3:?after ref}

SCRATCH=$(mktemp -d /tmp/fm-teardown-demo.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/before" "$SCRATCH/after"
git -C "$REPO" archive "$BEFORE_REF" | tar -x -C "$SCRATCH/before"
git -C "$REPO" archive "$AFTER_REF"  | tar -x -C "$SCRATCH/after"
# Same harness on both sides: only bin/ differs between the two checkouts.
cp "$SCRATCH/after/tests/fm-teardown.test.sh" "$SCRATCH/before/tests/fm-teardown.test.sh"

for side in before after; do
  # Keep the harness (fixtures + helpers), drop the trailing test invocations.
  sed -n '1,/^test_local_only_fork_remote_allows$/p' "$SCRATCH/$side/tests/fm-teardown.test.sh" \
    | sed '$d' > "$SCRATCH/$side/tests/demo-driver.sh"
  cat >> "$SCRATCH/$side/tests/demo-driver.sh" <<'DRV'
case_dir=$(make_case parked-run-pipeline-owned)
write_meta "$case_dir" no-mistakes ship
land_shippable_commit "$case_dir"
rc=0
FM_FAKE_AXI_STATUS="$(parked_pipeline_owned_axi_status_toon fm/task-x1)" \
FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
printf '  teardown exit status: %s\n' "$rc"
printf '  no-mistakes commands teardown issued for the parked run:\n'
if [ -s "$case_dir/nm-abort.log" ]; then
  sed 's/^/      /' "$case_dir/nm-abort.log"
else
  printf '      (none) -> the parked run was ORPHANED, still holding a fleet slot\n'
fi
printf '  what teardown told the operator:\n'
grep -Ei 'run|park|abort' "$case_dir/stderr" | sed 's/^/      /' | head -4
DRV
  # Driver 2: teardown's herdr preflight on stock macOS bash 3.2 (/bin/bash),
  # with the herdr adapter file removed. Under `set -e` bash 3.2 treats `.` on a
  # missing file as a fatal special-builtin error, so a fm_backend_source that
  # does not prove the file readable first kills teardown mid-preflight: the
  # operator sees no refusal and the EXIT trap reports success for a teardown
  # that did nothing.
  sed -n '1,/^test_local_only_fork_remote_allows$/p' "$SCRATCH/$side/tests/fm-teardown.test.sh" \
    | sed '$d' > "$SCRATCH/$side/tests/demo-driver2.sh"
  cat >> "$SCRATCH/$side/tests/demo-driver2.sh" <<'DRV2'
case_dir=$(make_case herdr-preflight-missing-adapter)
write_meta "$case_dir" local-only ship
configure_flat_herdr_teardown_case "$case_dir"
: > "$case_dir/state/task-x1.status"
: > "$case_dir/state/task-x1.turn-ended"
mkdir -p "$case_dir/test-root"
cp -R "$ROOT/bin" "$case_dir/test-root/bin"
rm -f "$case_dir/test-root/bin/backends/herdr.sh"
rc=0
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" FM_FAKE_HERDR_SESSION_LIST_GARBAGE=0 PATH="$case_dir/fakebin:$PATH"   /bin/bash "$case_dir/test-root/bin/fm-teardown.sh" task-x1 --force     > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
printf '  bash running teardown: %s
' "$(/bin/bash -c 'echo $BASH_VERSION')"
printf '  teardown exit status: %s%s
' "$rc"   "$( [ "$rc" -eq 0 ] && printf '   <- reports SUCCESS for a teardown that refused nothing' || printf '   <- refused, as it must' )"
printf '  what teardown told the operator:
'
if [ -s "$case_dir/stderr" ]; then sed 's/^/      /' "$case_dir/stderr" | tail -3
else printf '      (nothing) -> the shell was killed mid-preflight
'; fi
DRV2
done

printf 'firstmate teardown of a gate-parked, pipeline-owned run\n'
printf 'before = %s (pre-fix)   after = %s (post-fix)\n' \
  "$(git -C "$REPO" rev-parse --short "$BEFORE_REF")" "$(git -C "$REPO" rev-parse --short "$AFTER_REF")"
for side in before after; do
  printf '\n=== %s ===\n' "$side"
  bash "$SCRATCH/$side/tests/demo-driver.sh" 2>&1 | grep -v '^FM_TEST_'
done

printf '\n\nfirstmate teardown preflight on stock macOS bash 3.2 with a missing backend adapter\n'
for side in before after; do
  printf '\n=== %s ===\n' "$side"
  bash "$SCRATCH/$side/tests/demo-driver2.sh" 2>&1 | grep -v '^FM_TEST_'
done
printf '\n'
