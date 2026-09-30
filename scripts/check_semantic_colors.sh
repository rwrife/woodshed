#!/usr/bin/env bash
# Semantic-color / contrast gate (issue #7).
#
# Contrast correctness on iOS comes from the system type system: semantic
# foreground styles (.primary/.secondary/.tertiary), semantic fills, and
# system tints automatically adapt to Light/Dark appearance, Increase
# Contrast, and High Contrast modes. Hard-coded RGB or fixed white/black
# colors do NOT — they are the classic cause of low-contrast text in
# enhanced-contrast appearances.
#
# This gate keeps app sources on the semantic system: literal color
# construction in UI code is rejected. The allowlist is intentionally
# EMPTY (mirrors the zero-network gate policy).
#
# Scanned roots: App/ (app UI sources only; packages are non-UI).
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTS=("App")
ALLOWLIST=()   # empty by design; extend only with explicit user sign-off

PATTERNS=(
  'Color[[:space:]]*\([[:space:]]*(red|white|black|gray|green|blue|opacity:)'
  'Color\(hex'
  'UIColor[[:space:]]*\('
  'CGColor'
  'foregroundStyle[[:space:]]*\([[:space:]]*(Color|UIColor)[[:space:]]*\('
  '\.foregroundColor\([[:space:]]*(Color|UIColor)[[:space:]]*\('
)

matches=""
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  for pat in "${PATTERNS[@]}"; do
    hits=$(grep -RnE --include='*.swift' \
      --exclude-dir=.build --exclude-dir=.swiftpm \
      "$pat" "$root" 2>/dev/null || true)
    [ -n "$hits" ] && matches+="$hits"$'\n'
  done
done

if [ -n "$matches" ]; then
  filtered=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    skip=0
    for a in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
      [[ "$line" == *"$a"* ]] && { skip=1; break; }
    done
    [ "$skip" -eq 0 ] && filtered+="$line"$'\n'
  done <<< "$matches"
  if [ -n "$filtered" ]; then
    echo "SEMANTIC-COLOR GATE FAILED — hard-coded color in UI source (use .primary/.secondary/semantic styles or system tints):"
    printf '%s' "$filtered"
    exit 1
  fi
fi

echo "Semantic-color gate: PASS (app UI sources use system semantic colors only)"
