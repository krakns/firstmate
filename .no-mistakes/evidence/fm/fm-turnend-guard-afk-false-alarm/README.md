# Away-mode turn-end guard false alarm - test evidence

Change under test: `fix(turnend): accept the away-mode daemon as the supervision owner` (d9d25fb, base d22318e).

Every transcript here comes from the real scripts - `bin/fm-supervise-daemon.sh` running as a
long-lived process, wrapping the real one-shot `bin/fm-watch.sh`, over a real home with
`state/.afk` set and one task in flight, with the real `bin/fm-turnend-guard.sh` invoked exactly
the way the Claude Stop hook invokes it (`{"stop_hook_active":false}` on stdin, `CLAUDECODE=1`,
`FM_HOME` set).
The only shim is a fake `tmux` standing in for the supervisor pane, so nothing is ever injected.

## What the captain sees

- [e2e-repro-pre-fix.txt](e2e-repro-pre-fix.txt) - 40 simulated turn boundaries on the base commit:
  **4 of 40 BLOCKED** with `TURN WOULD END BLIND - SUPERVISION IS OFF`, every one of them with the
  away-mode daemon alive, the beacon 1-2 seconds old, and no watcher holding the lock - the reported
  symptom, including a different watcher pid on each cycle (64610, 67979, 80527).
- [e2e-repro-post-fix.txt](e2e-repro-post-fix.txt) - the same reproduction on the target commit:
  **0 of 40 BLOCKED**, including nine samples that landed squarely in a hand-off window
  (`watcher=no-lock`).
- Both files end with the genuine-lapse control: daemon and watcher killed, away mode still on and
  the beacon deliberately fresh - the guard still blocks, with the away-mode repair banner.

## Away mode is the only variable

[away-mode-ab-post-fix.txt](away-mode-ab-post-fix.txt) freezes one live daemon (SIGSTOP, so it
cannot restart its watcher) with its watcher killed and the beacon fresh, then runs the guard twice:

- away mode ON  -> allowed (the daemon owns supervision)
- away mode OFF -> still BLOCKED, with the unchanged strict-watcher instruction

[away-mode-ab-pre-fix.txt](away-mode-ab-pre-fix.txt) is the same A/B on the base commit, where both
halves block.

## Fail-closed diagnostics

[daemon-identity-warning.txt](daemon-identity-warning.txt) starts the daemon with an unreadable `ps`.
The daemon keeps running, records no `pid-identity`, logs
`warn: could not record this daemon's process identity; the turn-end guard cannot recognize away-mode supervision`,
and the guard then keeps blocking at the hand-off - the documented fail-closed behavior.

## Automated coverage

- [regression-before-after.txt](regression-before-after.txt) - the seven new cases run individually
  against base and target.
- [fm-turnend-guard.test.log](fm-turnend-guard.test.log) - the whole colocated suite, 77 cases, 0 failures.
- [fm-wake-daemon-lifecycle-e2e.test.log](fm-wake-daemon-lifecycle-e2e.test.log) - the watcher +
  supervise-daemon lifecycle e2e, unaffected by the daemon's new startup warning.

The `repro-script-*.sh` files are the scripts that produced these transcripts; each takes a repo
checkout path and a label.
