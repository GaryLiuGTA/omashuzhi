#!/bin/bash
# Run a command with a hard deadline, killing the ENTIRE process group on
# expiry — not just the direct child.
#
# `timeout` alone is not enough: it signals the command it launched, so a
# grandchild (fc-list, hyprctl, a wedged helper) outlives the deadline and can
# keep holding memory or a lock. Verified: plain `timeout -k 2 3` left two
# `sleep` descendants running past the deadline.
#
# Usage: run-bounded.sh <timeout-secs> <kill-after-secs> <command> [args...]
# Exit:  the command's own status, 124 if the deadline was reached,
#        2 on bad usage, 78 if the environment is not safe to run in.
set -u

# Terminating failure. Every precondition below routes through this, so a
# failed check cannot fall through into doing the work anyway. An earlier
# version called `die` without defining it and without `set -e`: bash printed
# "die: command not found" and CARRIED ON, so the runtime-directory checks
# silently failed open. Preconditions must fail closed.
die() {
  printf 'run-bounded.sh: %s\n' "$*" >&2
  exit 78
}

[ $# -ge 3 ] || { printf 'run-bounded.sh: need <timeout> <kill-after> <command>\n' >&2; exit 2; }
deadline=$1
grace=$2
shift 2
[[ $deadline =~ ^[0-9]+$ ]] || die "timeout must be a whole number of seconds (got: $deadline)"
[[ $grace =~ ^[0-9]+$ ]] || die "kill-after must be a whole number of seconds (got: $grace)"

# --- Deadline marker, validated BEFORE anything is launched ----------------
# The watcher has to tell us it fired, so the exit status can distinguish "the
# command failed" from "we killed it".
#
# This must NOT signal by unlinking a path and re-creating it later. An earlier
# version created a marker with `mktemp -t` in shared /tmp, unlinked it, and had
# the watcher re-create that now-predictable pathname — a symlink race: any
# local user watching /tmp could plant a symlink at that name in the window and
# have the timeout path truncate a file they do not own.
#
# Instead the marker lives in $XDG_RUNTIME_DIR, which is mode 0700 and owned by
# us, so other users can neither observe nor plant paths inside it. All of this
# is validated and created up front: if the environment is not safe we exit
# without having spawned the command, rather than leaving an unsupervised
# process behind.
runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] \
  || die "XDG_RUNTIME_DIR is unset; refusing to put the deadline marker in shared /tmp"

# lstat, NOT stat -L: a symlink must be rejected as a symlink. Dereferencing
# would let a link that currently points somewhere safe pass the checks and be
# repointed afterwards.
# `%F` can be multi-word ("symbolic link", "regular empty file"), so split on
# a delimiter rather than whitespace or the fields misalign.
runtime_meta=$(stat -c '%F|%u|%a' "$runtime" 2> /dev/null) \
  || die "cannot stat XDG_RUNTIME_DIR ($runtime)"
IFS='|' read -r rt_type rt_uid rt_mode <<< "$runtime_meta"
[ "$rt_type" = directory ] \
  || die "XDG_RUNTIME_DIR ($runtime) is a $rt_type, not a directory"
[ "$rt_uid" = "$(id -u)" ] \
  || die "XDG_RUNTIME_DIR ($runtime) is owned by uid $rt_uid, not $(id -u)"
[ "$rt_mode" = 700 ] \
  || die "XDG_RUNTIME_DIR ($runtime) mode is $rt_mode, expected 700"

marker_dir="$runtime/omashuzhi"
mkdir -p -m 700 "$marker_dir" || die "cannot create $marker_dir"
marker_meta=$(stat -c '%F|%u|%a' "$marker_dir" 2> /dev/null) \
  || die "cannot stat $marker_dir"
IFS='|' read -r md_type md_uid md_mode <<< "$marker_meta"
[ "$md_type" = directory ] || die "$marker_dir is a $md_type, not a directory"
[ "$md_uid" = "$(id -u)" ] || die "$marker_dir is owned by uid $md_uid, not $(id -u)"
[ "$md_mode" = 700 ] || die "$marker_dir mode is $md_mode, expected 700"

fired=$(mktemp "$marker_dir/deadline.XXXXXX") || die "cannot create the deadline marker"
chmod 600 "$fired" || die "cannot chmod the deadline marker"
# Descriptor 9 stays open for the life of the run; the watcher writes to the
# descriptor, not to the name, so there is no second path resolution to race.
# The securely created file is never unlinked until after the watcher exits.
exec 9> "$fired" || die "cannot open the deadline marker"

# --- Run -------------------------------------------------------------------
# `set -m` (job control) makes each background job a process-group leader, so
# $! is both the child's pid AND its pgid — which is what lets one kill to the
# negative pgid reap the whole tree. `setsid` is not usable here: it forks, so
# $! would be setsid's pid rather than the new group leader's.
set -m
"$@" &
child=$!
set +m

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

# Non-empty marker => the watcher fired.
timed_out=0
[ -s "$fired" ] && timed_out=1
rm -f "$fired"
rmdir "$marker_dir" 2>/dev/null || true

[ "$timed_out" = 1 ] && exit 124
exit "$rc"
