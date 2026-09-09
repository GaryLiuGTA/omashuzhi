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

# The watcher has to tell us it fired, so the exit status can distinguish "the
# command failed" from "we killed it". Checking whether the watcher is still
# alive does not work: during the grace period it is sleeping, not gone.
#
# This must NOT signal by unlinking a path and re-creating it later. An earlier
# version created a marker with `mktemp -t` in shared /tmp, unlinked it, and had
# the watcher re-create that now-predictable pathname — a symlink race: any
# local user watching /tmp could plant a symlink at that name in the window and
# have the timeout path truncate a file they do not own.
#
# Instead: put the marker in $XDG_RUNTIME_DIR, which is mode 0700 and owned by
# us, so other users can neither observe nor plant paths inside it; keep the
# securely created file in place for the whole run; and have the watcher signal
# by writing through an ALREADY-OPEN DESCRIPTOR, so the pathname is never
# resolved again after creation. Cleanup happens only after the watcher exits.
runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] \
  || die "XDG_RUNTIME_DIR is unset; refusing to put the deadline marker in shared /tmp"
runtime_meta=$(stat -Lc '%F %u %a' "$runtime" 2> /dev/null) \
  || die "cannot stat XDG_RUNTIME_DIR ($runtime)"
read -r rt_type rt_uid rt_mode <<< "$runtime_meta"
[ "$rt_type" = directory ] || die "XDG_RUNTIME_DIR is not a directory"
[ "$rt_uid" = "$(id -u)" ] || die "XDG_RUNTIME_DIR is not owned by this user"
[ "$rt_mode" = 700 ] || die "XDG_RUNTIME_DIR mode is $rt_mode, expected 700"

marker_dir="$runtime/omashuzhi"
mkdir -p -m 700 "$marker_dir" || die "cannot create $marker_dir"
fired=$(mktemp "$marker_dir/deadline.XXXXXX") || die "cannot create the deadline marker"
chmod 600 "$fired"
# Descriptor 9 stays open for the life of the run; the watcher writes to the
# descriptor, not to the name, so there is no second path resolution to race.
exec 9> "$fired"

( sleep "$deadline"
  printf 1 >&9
  # Negative pid = the whole process group, which `set -m` made this child the
  # leader of. Fall back to the bare pid if the group is already gone.
  kill -TERM -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
  sleep "$grace"
  kill -KILL -"$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null
) & watcher=$!

wait "$child"; rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
exec 9>&-

# Non-empty marker => the watcher fired. The file has existed, unlinked-by-no-one
# and inside our own 0700 directory, since it was created.
timed_out=0
[ -s "$fired" ] && timed_out=1
rm -f "$fired"
rmdir "$marker_dir" 2>/dev/null || true

[ "$timed_out" = 1 ] && exit 124
exit "$rc"
