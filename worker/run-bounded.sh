#!/bin/bash
# Run a command with a hard deadline, killing the ENTIRE process group on
# expiry — not just the direct child.
#
# `timeout` alone is not enough: it signals the command it launched, so a
# grandchild (fc-list, hyprctl, a wedged helper) outlives the deadline and can
# keep holding memory or a lock. Verified on this machine: plain
# `timeout -k 2 3` left two `sleep` descendants running past the deadline.
#
# Usage: run-bounded.sh <timeout-secs> <kill-after-secs> <command> [args...]
# Exit:  the command's own status, or 124 if the deadline was reached.
set -u
[ $# -ge 3 ] || { echo "run-bounded.sh: need <timeout> <kill-after> <command>" >&2; exit 2; }
deadline=$1; grace=$2; shift 2

# `set -m` (job control) makes each background job a process-group leader, so
# $! is both the child's pid AND its pgid — which is what lets one kill to the
# negative pgid reap the whole tree. `setsid` is not usable here: it forks, so
# $! would be setsid's pid rather than the new group leader's.
set -m
"$@" &
child=$!
set +m

# The watcher records that it fired, so the exit status can distinguish "the
# command failed" from "we killed it". Checking whether the watcher is still
# alive does not work: during the grace period it is sleeping, not gone.
fired="$(mktemp -t omashuzhi-deadline.XXXXXX)"
rm -f "$fired"

( sleep "$deadline"
  : > "$fired"
  # Negative pid = the whole process group, which `set -m` made this child the
  # leader of. Fall back to the bare pid if the group is already gone.
  kill -TERM -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
  sleep "$grace"
  kill -KILL -"$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null
) & watcher=$!

wait "$child"; rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

if [ -e "$fired" ]; then
  rm -f "$fired"
  exit 124
fi
rm -f "$fired"
exit "$rc"
