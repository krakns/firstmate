#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-run-lib.sh - the ONE owner of no-mistakes run
# attribution, shared by bin/fm-crew-state.sh (current-state reporting) and
# bin/fm-teardown.sh (pre-teardown run abort).
#
# Two contracts are pinned here, both of which decide whether a run may bind to
# a worktree WITHOUT head equality:
#
#   (a) branch_sync.state is the DIRECT CHILD of the top-level branch_sync
#       block. A sub-block's own `state:` must never be read as the custody
#       label: reading a nested `pipeline_owned` grants the exemption to a run
#       the pipeline does not own (branch-name-only attribution, the exact
#       reused-branch misattribution the head rule exists to prevent), and
#       reading a nested `dirty` denies a legitimate exemption.
#
#   (b) the exemption is BOUNDED. `axi status` reports a run `running` with
#       `pipeline_owned` indefinitely when the daemon dies without writing an
#       outcome, so an unbounded exemption reports that crew as working
#       forever and every signal and turn-end wake from it is absorbed - a
#       wedged worker permanently invisible to supervision. Binding requires
#       positive current custody evidence: a gate the daemon wrote, or a run
#       age inside the custody window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

NOW=$(date +%s)

# --- fixtures ---------------------------------------------------------------

# The well-formed shape the live incident run emitted: branch_sync's own state
# first, nested sub-blocks after it.
toon_direct_child_first() {  # <sync-state>
  cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat-x
  status: running
  head: "f0f0f0f0"
branch_sync:
  state: $1
  changed: false
  local:
    branch: fm/feat-x
    head: "e5e5e5e5"
    clean: true
EOF
}

# A sub-block carrying its own `state:` AHEAD of the direct child. Nothing in
# the CLI contract forbids this, and a first-match-at-any-indent parse reads
# the nested value instead of the block's own.
toon_nested_state_first() {  # <nested-state> <direct-child-state>
  cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat-x
  status: running
  head: "f0f0f0f0"
branch_sync:
  pipeline:
    state: $1
  state: $2
EOF
}

# A whole nested `branch_sync:` BLOCK ahead of the real top-level one. Its own
# direct child is perfectly well-formed, so direct-child anchoring alone still
# reads it; only anchoring the block header at top level rejects it.
toon_nested_branch_sync_block() {  # <nested-state> <top-level-state>
  cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat-x
  status: running
  head: "f0f0f0f0"
  branch_sync:
    state: $1
branch_sync:
  state: $2
EOF
}

toon_parked_pipeline_owned() {
  cat <<'EOF'
run:
  id: "01RUN"
  branch: fm/feat-x
  status: awaiting_approval
  awaiting_agent: parked 7h39m
  head: "f0f0f0f0"
gate: review
branch_sync:
  state: pipeline_owned
EOF
}

# --- (a) direct-child indentation anchor ------------------------------------

test_direct_child_state_is_read() {
  local out
  out=$(fm_nm_branch_sync_state "$(toon_direct_child_first pipeline_owned)")
  [ "$out" = pipeline_owned ] || fail "well-formed branch_sync.state read as '$out'"
  out=$(fm_nm_branch_sync_state "$(toon_direct_child_first synced)")
  [ "$out" = synced ] || fail "well-formed non-custody state read as '$out'"
  pass "branch_sync.state reads the block's own scalar"
}

test_nested_state_never_grants_the_exemption() {
  local toon out
  toon=$(toon_nested_state_first pipeline_owned synced)
  out=$(fm_nm_branch_sync_state "$toon")
  [ "$out" = synced ] || fail "a nested state: was read as the custody label ('$out')"
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "a nested pipeline_owned granted the head-rule exemption"
  fi
  pass "a sub-block's pipeline_owned never grants the exemption"
}

test_nested_state_never_denies_a_real_exemption() {
  local toon out
  toon=$(toon_nested_state_first dirty pipeline_owned)
  out=$(fm_nm_branch_sync_state "$toon")
  [ "$out" = pipeline_owned ] || fail "a nested state: masked the real custody label ('$out')"
  fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))" \
    || fail "a nested dirty denied a legitimate live pipeline-owned exemption"
  pass "a sub-block's state never masks the block's own custody label"
}

test_child_indent_unit_is_not_assumed() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' \
    'branch_sync:' \
    '    pipeline:' \
    '        state: pipeline_owned' \
    '    state: synced')")
  [ "$out" = synced ] || fail "a four-space indent unit was misparsed as '$out'"
  pass "the direct-child indent is taken from the block, never assumed"
}

test_scan_stops_at_the_end_of_the_block() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' \
    'branch_sync:' \
    '  changed: false' \
    'other_block:' \
    '  state: pipeline_owned')")
  [ -z "$out" ] || fail "a later block's state: leaked into branch_sync ('$out')"
  pass "the scan stops at the end of the branch_sync block"
}

test_nested_branch_sync_block_never_wins_over_the_real_one() {
  local toon out
  toon=$(toon_nested_branch_sync_block pipeline_owned synced)
  out=$(fm_nm_branch_sync_state "$toon")
  [ "$out" = synced ] || fail "a nested branch_sync block was read as the custody label ('$out')"
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "a nested branch_sync block granted the head-rule exemption"
  fi
  pass "only the top-level branch_sync block is read as the custody label"
}

test_only_nested_branch_sync_reads_empty() {
  local toon
  toon=$(printf '%s\n' 'run:' '  status: running' '  branch_sync:' '    state: pipeline_owned')
  [ -z "$(fm_nm_branch_sync_state "$toon")" ] \
    || fail "a document whose only branch_sync is nested reported a custody label"
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "a nested-only branch_sync granted the head-rule exemption"
  fi
  pass "a nested-only branch_sync reads empty and denies the exemption"
}

test_absent_block_reads_empty() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' 'run:' '  status: running')")
  [ -z "$out" ] || fail "an absent branch_sync block read as '$out'"
  pass "an absent branch_sync block reads empty"
}

test_quoted_child_value_is_unquoted() {
  local out
  out=$(fm_nm_branch_sync_state "$(printf '%s\n' 'branch_sync:' '  state: "pipeline_owned"')")
  [ "$out" = pipeline_owned ] || fail "a quoted state read as '$out'"
  pass "a quoted branch_sync.state is unquoted"
}

# --- (b) the exemption is bounded -------------------------------------------

test_fresh_pipeline_owned_run_binds() {
  fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first pipeline_owned)" "$((NOW - 600))" \
    || fail "a live pipeline-owned run inside the custody window did not bind"
  pass "a fresh pipeline-owned run binds without head equality"
}

test_stranded_custody_stops_binding() {
  local toon
  toon=$(toon_direct_child_first pipeline_owned)
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 108000))"; then
    fail "a pipeline-owned run 30h old still bound: a stranded run reads working forever"
  fi
  pass "a pipeline-owned run past the custody window stops binding"
}

test_no_age_evidence_denies_the_exemption() {
  local toon
  toon=$(toon_direct_child_first pipeline_owned)
  if fm_nm_run_is_pipeline_owned_active "$toon" ""; then
    fail "the exemption bound with no custody evidence at all"
  fi
  if fm_nm_run_is_pipeline_owned_active "$toon" "not-an-epoch"; then
    fail "the exemption bound on an unparseable run age"
  fi
  pass "absent or unparseable run age never grants the exemption"
}

test_future_dated_run_denies_the_exemption() {
  if fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first pipeline_owned)" "$((NOW + 86400))"; then
    fail "a run dated a day in the future bound"
  fi
  pass "an implausibly future-dated run age never grants the exemption"
}

test_absent_status_is_not_a_live_run() {
  local toon
  toon=$(printf '%s\n' 'run:' '  id: "01RUN"' '  branch: fm/feat-x' 'branch_sync:' '  state: pipeline_owned')
  if fm_nm_run_is_active "$toon"; then
    fail "a run object with no status: read as active"
  fi
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "the exemption bound on a run with no positive status evidence"
  fi
  pass "an absent status is not evidence of a live run"
}

test_terminal_run_is_never_exempt() {
  local toon
  toon="$(toon_direct_child_first pipeline_owned)
outcome: failed"
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "a terminal run bound through the exemption"
  fi
  toon=$(printf '%s\n' 'run:' '  status: cancelled' 'branch_sync:' '  state: pipeline_owned')
  if fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "a cancelled run bound through the exemption"
  fi
  pass "the exemption never applies to a terminal run"
}

test_non_custody_state_is_never_exempt() {
  if fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first synced)" "$((NOW - 600))"; then
    fail "a synced branch bound through the exemption"
  fi
  pass "the exemption requires branch_sync.state=pipeline_owned"
}

# A run parked at a gate is the case bin/fm-teardown.sh must still conclude:
# its lane head is routinely not a git object in the worktree, and the parked
# duration is exactly what makes it an orphan worth aborting. The daemon wrote
# that gate, and a parked run never maps to `working`, so gate evidence binds
# regardless of run age.
test_gate_parked_run_binds_regardless_of_age() {
  local toon
  toon=$(toon_parked_pipeline_owned)
  fm_nm_run_is_gate_parked "$toon" || fail "a parked run was not recognized as gate-parked"
  fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 108000))" \
    || fail "a long-parked pipeline-owned run did not bind, so teardown would orphan it"
  fm_nm_run_is_pipeline_owned_active "$toon" "" \
    || fail "a parked pipeline-owned run needed a run age to bind"
  pass "a gate-parked pipeline-owned run binds on the daemon's own gate evidence"
}

test_running_run_is_not_gate_parked() {
  if fm_nm_run_is_gate_parked "$(toon_direct_child_first pipeline_owned)"; then
    fail "an autonomous running run was read as gate-parked"
  fi
  pass "an autonomous running step is not gate evidence"
}

# --- custody window configuration -------------------------------------------

test_custody_window_is_configurable() {
  local toon
  toon=$(toon_direct_child_first pipeline_owned)
  FM_NM_CUSTODY_MAX_AGE_SECS=172800 fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 108000))" \
    || fail "a widened custody window was ignored"
  if FM_NM_CUSTODY_MAX_AGE_SECS=60 fm_nm_run_is_pipeline_owned_active "$toon" "$((NOW - 600))"; then
    fail "a narrowed custody window was ignored"
  fi
  pass "the custody window honours FM_NM_CUSTODY_MAX_AGE_SECS"
}

test_malformed_custody_window_falls_back_to_the_default() {
  local v
  v=$(FM_NM_CUSTODY_MAX_AGE_SECS=forever fm_nm_custody_max_age_secs)
  [ "$v" = "$FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT" ] || fail "a malformed window resolved to '$v'"
  v=$(FM_NM_CUSTODY_MAX_AGE_SECS=0 fm_nm_custody_max_age_secs)
  [ "$v" = "$FM_NM_CUSTODY_MAX_AGE_SECS_DEFAULT" ] || fail "a zero window resolved to '$v'"
  if FM_NM_CUSTODY_MAX_AGE_SECS=forever \
     fm_nm_run_is_pipeline_owned_active "$(toon_direct_child_first pipeline_owned)" "$((NOW - 108000))"; then
    fail "a malformed window removed the custody bound"
  fi
  pass "a malformed custody window falls back to the default instead of removing the bound"
}

# --- runs-list row age evidence ---------------------------------------------

test_runs_row_epoch_parses_the_listed_date() {
  local got want
  got=$(fm_nm_runs_row_epoch '2026-08-27 13:53  https://github.com/o/r/pull/9')
  case "$got" in ''|*[!0-9]*) fail "a valid runs row date did not parse ('$got')" ;; esac
  want=$(date -r "$got" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$got" '+%Y-%m-%d %H:%M' 2>/dev/null)
  [ "$want" = "2026-08-27 13:53" ] || fail "runs row date parsed to '$want'"
  pass "a runs-list row date parses to its own local timestamp"
}

test_runs_row_epoch_rejects_unusable_rows() {
  local got
  for got in '' 'not-a-date 13:53' '2026-08-27' '2026-08-27 noon'; do
    if fm_nm_runs_row_epoch "$got" >/dev/null; then
      fail "an unusable runs row remainder parsed: '$got'"
    fi
  done
  pass "an unusable runs-list row yields no age evidence"
}

test_direct_child_state_is_read
test_nested_state_never_grants_the_exemption
test_nested_state_never_denies_a_real_exemption
test_child_indent_unit_is_not_assumed
test_nested_branch_sync_block_never_wins_over_the_real_one
test_only_nested_branch_sync_reads_empty
test_scan_stops_at_the_end_of_the_block
test_absent_block_reads_empty
test_quoted_child_value_is_unquoted
test_fresh_pipeline_owned_run_binds
test_stranded_custody_stops_binding
test_no_age_evidence_denies_the_exemption
test_future_dated_run_denies_the_exemption
test_absent_status_is_not_a_live_run
test_terminal_run_is_never_exempt
test_non_custody_state_is_never_exempt
test_gate_parked_run_binds_regardless_of_age
test_running_run_is_not_gate_parked
test_custody_window_is_configurable
test_malformed_custody_window_falls_back_to_the_default
test_runs_row_epoch_parses_the_listed_date
test_runs_row_epoch_rejects_unusable_rows

echo "all fm-nm-run-lib tests passed"
