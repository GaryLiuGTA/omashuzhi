#!/bin/bash
# Installed font families as JSON for the Omashuzhi font picker:
# [{ "value": ..., "label": ..., "description": "CJK" | "" }], CJK first.
# The popup runs this as `bash list-fonts.sh`, so the exec bit is not needed.
set -euo pipefail

# fc-list escapes punctuation with backslashes and lists a font's aliases
# comma-separated on one row; split so each family name appears once.
cjk="$(fc-list :lang=zh --format='%{family}\n' 2>/dev/null | tr ',' '\n' | sed 's/\\//g' | grep . | sort -u)"
all="$(fc-list --format='%{family}\n' 2>/dev/null | tr ',' '\n' | sed 's/\\//g' | grep . | sort -u)"
cjk_json="$(printf '%s\n' "$cjk" | jq -R . | jq -s .)"

# CJK first, then everything else, deduped in that order.
printf '%s\n' "$cjk" "$all" | awk 'NF && !seen[$0]++' | jq -Rn --argjson cjk "$cjk_json" \
  '[inputs] | map({ value: ., label: ., description: (if (. as $f | $cjk | index($f)) then "CJK" else "" end) })'
