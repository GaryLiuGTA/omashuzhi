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

# Sweep markers orphaned by an untrappable SIGKILL of a previous wrapper. The
# EXIT trap cannot run in that case, so without this they accumulate in
# $XDG_RUNTIME_DIR for the life of the session. Safe and bounded: the directory
# has already been validated as a real directory, ours, mode 0700; only regular
# files (never symlinks — find does not follow, and -type f is false for a
# link) matching our own fixed-width name are considered; and an hour is far
# longer than any run can live, which is bounded by deadline + kill-after.
find "$marker_dir" -maxdepth 1 -type f -name 'deadline.??????' -mmin +60 -delete 2> /dev/null || true

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
reaped=0

# Signal one of our process GROUPS. Killing the negative pid targets the group,
# which is why both the child and the watcher are started under `set -m` (job
# control), making each its own group leader. Fall back to the bare pid if the
# group is already gone.
signal_group() {
  kill -"$2" -"$1" 2>/dev/null || kill -"$2" "$1" 2>/dev/null || true
}

# Bounded TERM -> grace -> KILL -> reap over one group.
#
# An earlier version sent a single TERM and returned immediately, so a
# descendant that IGNORES TERM (a wedged renderer, a helper with its own
# handler) outlived the wrapper and kept holding flock's lock descriptor —
# which is the whole failure this script exists to prevent. The escalation
# existed only inside the deadline watcher; now every path uses it.
#
# `kill -0` on a negative pid is the liveness probe. It is checked BEFORE
# signalling, for two reasons: a group with no live members must not be
# signalled at all (once the leader has been reaped its pgid could in principle
# have been recycled), and the common case where nothing ignored TERM returns on
# the first poll instead of burning the whole grace. On the external-signal
# path neither job has been waited on, so bash still holds each as an unreaped
# job and neither the pid nor the pgid can have been recycled.
teardown_group() {
  local pg=$1 i=0 limit=$(( grace * 10 ))

  [ "$pg" -gt 0 ] || return 0
  if ! kill -0 -"$pg" 2>/dev/null; then
    wait "$pg" 2>/dev/null || true
    return 0
  fi

  signal_group "$pg" TERM
  while kill -0 -"$pg" 2>/dev/null; do
    [ "$i" -ge "$limit" ] && break
    sleep 0.1
    i=$(( i + 1 ))
  done

  if kill -0 -"$pg" 2>/dev/null; then
    signal_group "$pg" KILL
    i=0
    while kill -0 -"$pg" 2>/dev/null && [ "$i" -lt 20 ]; do
      sleep 0.1
      i=$(( i + 1 ))
    done
  fi

  # Reap the job so the paths that never `wait` do not leave a zombie behind.
  wait "$pg" 2>/dev/null || true
}

# EXIT is the single cleanup funnel: TERM/INT/HUP just `exit`, which runs this,
# so normal completion, the deadline path and external cancellation all get the
# identical bounded teardown. Idempotent, because the normal path drains the
# groups itself and then exits through here.
reap() {
  [ "$reaped" = 1 ] && return 0
  reaped=1
  # Watcher first: it must not fire its own TERM/KILL at the child while we are
  # dismantling the child ourselves.
  teardown_group "$watcher"
  teardown_group "$child"
  # Unlink only once both groups are gone, so nothing can still be writing.
  rm -f "$fired" 2>/dev/null || true
}
trap 'reap' EXIT
# TERM/INT/HUP only `exit`; EXIT does the work, so there is exactly one
# teardown implementation and no path that can skip it.
#
# Caveat, verified: a signal inherited as SIG_IGN cannot be trapped or reset by
# the shell (POSIX). bash sets SIGINT and SIGQUIT to SIG_IGN for asynchronous
# commands, so a wrapper launched as `run-bounded.sh ... &` from another shell
# shows `SigIgn: 0000000000000006` and this INT trap is inert — the run then
# ends at its deadline instead. That is not the path that matters here:
# Quickshell starts the wrapper directly, not through a shell, and sends only
# SIGTERM (Process::terminate) and SIGKILL (Process::signal).
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

# Stop the watcher before reading its verdict, so the decision below cannot
# race a watcher that fires in the gap after the command was reaped.
teardown_group "$watcher"
watcher=0

# The command is gone, but a grandchild it spawned can still be in its group
# holding the lock. Drain that now, while the pgid is provably still ours.
teardown_group "$child"
child=0

# Non-empty marker => the watcher fired. Read through the retained descriptor.
timed_out=0
if IFS= read -r -n 1 flag <&8 2>/dev/null && [ -n "${flag:-}" ]; then
  timed_out=1
fi
exec 8<&- || true
exec 9>&- || true

[ "$timed_out" = 1 ] && exit 124
exit "$rc"
