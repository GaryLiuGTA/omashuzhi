#!/bin/bash
# Installed font families as JSON for the Omashuzhi font picker:
# [{ "value": ..., "label": ..., "description": "CJK" | "" }], CJK first.
# The popup runs this as `bash list-fonts.sh`, so the exec bit is not needed.
#
# Deliberately NOT `set -e -o pipefail`. Two failure modes came from that:
#   - `grep .` returns 1 on empty input, so a machine with no Chinese fonts
#     aborted the whole script and the picker showed ZERO families — on a
#     plugin whose point is choosing a CJK font.
#   - capping with `head -n` SIGPIPEs the producer, and pipefail turned that
#     into exit 141 even though stdout was complete and valid JSON, so a
#     font-heavy machine got "Options command exited 141".
# Failures are handled explicitly instead.
set -u

die() {
  printf 'list-fonts.sh: %s\n' "$*" >&2
  exit 1
}

command -v fc-list > /dev/null 2>&1 || die "fc-list not found (install fontconfig)"
command -v jq > /dev/null 2>&1 || die "jq not found"

# At most this many families, and a hard byte cap on the emitted JSON:
# StdioCollector has no size limit of its own.
MAX_FAMILIES=2000
MAX_BYTES=262144

# fc-list escapes punctuation with backslashes and lists a font's aliases
# comma-separated on one row; split so each family name appears once.
# `awk NF` drops blanks without grep's empty-input exit status, and
# `awk NR<=n` caps without SIGPIPE-ing the producer.
families() {
  fc-list "$@" --format='%{family}\n' 2> /dev/null \
    | tr ',' '\n' \
    | sed 's/\\//g' \
    | awk 'NF' \
    | sort -u
}

cjk=$(families :lang=zh)   # legitimately empty on a machine with no CJK fonts
all=$(families)
[ -n "$all" ] || die "fc-list reported no font families at all"

cjk_json=$(printf '%s' "$cjk" | jq -R . | jq -s .) \
  || die "could not encode the CJK family list"

# CJK first, then everything else, deduped in that order.
printf '%s\n%s\n' "$cjk" "$all" \
  | awk 'NF && !seen[$0]++ { n++ } n <= '"$MAX_FAMILIES"' && NF && seen[$0] == 1 { print }' \
  | jq -Rn --argjson cjk "$cjk_json" \
    '[inputs] | map({ value: ., label: ., description: (if (. as $f | $cjk | index($f)) then "CJK" else "" end) })' \
  | head -c "$MAX_BYTES"
