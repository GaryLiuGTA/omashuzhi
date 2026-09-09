#!/bin/bash
# Run a command with a hard deadline, reaping the ENTIRE process tree on exit.
#
# This wrapper is the OUTERMOST process of a run, so it must be the one the
# caller can kill: Quickshell's Process::signal()/terminate() signal only the
# direct child's pid, so anything nested below the direct child survives. The
# EXIT trap below is what turns "kill the direct child" into "the whole run is
# gone", including a `flock` holding a lock fd and the gjs renderer under it.
#
# `timeout` is not usable for this: it signals only the command it launched, so
# grandchildren outlive the deadline (measured: `timeout -k 2 3` left two
# `sleep` descendants running).
#
# Usage: run-bounded.sh <timeout-secs> <kill-after-secs> <command> [args...]
# Exit:  the command's own status, 124 if the deadline was reached,
#        2 on bad usage, 78 if the environment is not safe to run in.
set -u

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
# The watcher tells us it fired so the exit status can distinguish "the command
# failed" from "we killed it".
#
# It must NOT signal by unlinking a path and re-creating it: an earlier version
# used `mktemp -t` in shared /tmp, unlinked it, and had the watcher re-create
# that predictable name — a symlink race in which a local user could have the
# timeout path truncate a file they do not own. So: the marker lives in
# $XDG_RUNTIME_DIR (mode 0700, ours, not observable by other users), the
# securely created file is never unlinked mid-run, and the watcher signals
# through an already-open descriptor rather than by name.
runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] \
  || die "XDG_RUNTIME_DIR is unset; refusing to put the deadline marker in shared /tmp"

# lstat, NOT `stat -L`: a symlink must be rejected as a symlink, since
# dereferencing lets a link that currently points somewhere safe pass and be
# repointed afterwards. `%F` can be multi-word, so split on a delimiter.
runtime_meta=$(stat -c '%F|%u|%a' "$runtime" 2> /dev/null) \
  || die "cannot stat XDG_RUNTIME_DIR ($runtime)"
IFS='|' read -r rt_type rt_uid rt_mode <<< "$runtime_meta"
[ "$rt_type" = directory ] || die "XDG_RUNTIME_DIR ($runtime) is a $rt_type, not a directory"
[ "$rt_uid" = "$(id -u)" ] || die "XDG_RUNTIME_DIR ($runtime) is owned by uid $rt_uid, not $(id -u)"
[ "$rt_mode" = 700 ] || die "XDG_RUNTIME_DIR ($runtime) mode is $rt_mode, expected 700"

marker_dir="$runtime/omashuzhi"
mkdir -p -m 700 "$marker_dir" || die "cannot create $marker_dir"
marker_meta=$(stat -c '%F|%u|%a' "$marker_dir" 2> /dev/null) || die "cannot stat $marker_dir"
IFS='|' read -r md_type md_uid md_mode <<< "$marker_meta"
[ "$md_type" = directory ] || die "$marker_dir is a $md_type, not a directory"
[ "$md_uid" = "$(id -u)" ] || die "$marker_dir is owned by uid $md_uid, not $(id -u)"
[ "$md_mode" = 700 ] || die "$marker_dir mode is $md_mode, expected 700"

fired=$(mktemp "$marker_dir/deadline.XXXXXX") || die "cannot create the deadline marker"
chmod 600 "$fired" || die "cannot chmod the deadline marker"
# 9 = write side (watcher signals through it), 8 = retained read side. Reading
# the result through fd 8 rather than re-opening the path means a marker that
# has been removed underneath us cannot make a real timeout look like a signal
# death. Deliberately NOT rmdir'ing $marker_dir on exit: concurrent runs share
# it, and an rmdir between another run's mkdir and its mktemp would fail it.
exec 9> "$fired" || die "cannot open the deadline marker for writing"
exec 8< "$fired" || die "cannot open the deadline marker for reading"

child=0
watcher=0

# Reap everything we started. Killing the negative pid targets the process
# GROUP, which is why both the child and the watcher are started under `set -m`
# (job control), making each its own group leader.
reap() {
  if [ "$child" -gt 0 ]; then
    kill -TERM -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  fi
  if [ "$watcher" -gt 0 ]; then
    # The watcher's foreground `sleep` is a separate process and inherits every
    # fd this script holds — including flock's lock descriptor. Killing only the
    # subshell left that sleep alive for the whole deadline, holding the lock
    # and making every subsequent run exit 75. Kill the group.
    kill -TERM -"$watcher" 2>/dev/null || kill -TERM "$watcher" 2>/dev/null || true
  fi
  rm -f "$fired" 2>/dev/null || true
}
trap 'reap' EXIT
trap 'exit 143' TERM INT HUP

# --- Run -------------------------------------------------------------------
# The child must not inherit the marker descriptors: with fd 9 writable it
# could `printf >&9` and forge a timeout for itself.
set -m
"$@" 9>&- 8<&- &
child=$!
set +m

# The watcher gets its own process group (so it is reapable as a group), no
# marker read fd, stdout to /dev/null so it can never hold the caller's stdout
# pipe open, and every inherited descriptor above 2 closed so it does not keep
# an outer flock lock alive.
set -m
( trap - EXIT
  for fd in /proc/self/fd/*; do
    fd=${fd##*/}
    case "$fd" in 0 | 1 | 2 | 9) continue ;; esac
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
  sleep "$deadline"
  printf 1 >&9
  kill -TERM -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  sleep "$grace"
  kill -KILL -"$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
) > /dev/null &
watcher=$!
set +m

wait "$child"
rc=$?

kill -TERM -"$watcher" 2>/dev/null || kill -TERM "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true

# Non-empty marker => the watcher fired. Read through the retained descriptor.
timed_out=0
if IFS= read -r -n 1 flag <&8 2>/dev/null && [ -n "${flag:-}" ]; then
  timed_out=1
fi
exec 8<&- || true
exec 9>&- || true

[ "$timed_out" = 1 ] && exit 124
exit "$rc"
