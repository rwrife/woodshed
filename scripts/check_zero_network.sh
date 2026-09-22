#!/usr/bin/env bash
# Zero-network gate (issue #1, binding project contract).
#
# Woodshed is zero-network BY CONSTRUCTION: the app, the UI tests, and the
# domain package must never use network APIs. The allowlist is intentionally
# EMPTY — any match in scanned sources fails the build.
#
# Scanned roots: App/ and UITests/ (app sources) and Packages/*/Sources/.
# SwiftPM .build directories are skipped so vendored checkouts never trip
# the first-party scan.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTS=("App" "UITests" "Packages")
ALLOWLIST=()   # empty by design; extend only with explicit user sign-off

PATTERNS=(
  '\bURLSession\b'
  '\bNWConnection\b'
  '\bNWListener\b'
  '\bNWConnectionGroup\b'
  '\bNWBrowser\b'
  '\bNetService\b'
  '\bCFNetwork\b'
  '\bimport[[:space:]]+Network\b'
  '\bCFStream\b'
  '\bCFSocket\b'
  '\bCocoaHTTPServer\b'
  '\bWebSocket\b'
  '\bgetaddrinfo\b'
  '\bsocket[[:space:]]*\('
  '\bconnect[[:space:]]*\('
  '\blisten[[:space:]]*\('
  '\bbind[[:space:]]*\('
  '\baccept[[:space:]]*\('
  '\bNSURLSession\b'
)

matches=""
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  for pat in "${PATTERNS[@]}"; do
    hits=$(grep -RnE --include='*.swift' --include='*.h' --include='*.m' --include='*.c' \
      --exclude-dir=.build --exclude-dir=.swiftpm \
      "$pat" "$root" 2>/dev/null || true)
    [ -n "$hits" ] && matches+="$hits"$'\n'
  done
done

# Filter allowlisted lines (exact substring match against allowlist entries)
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
    echo "ZERO-NETWORK GATE FAILED — network API usage found (allowlist is empty):"
    printf '%s' "$filtered"
    exit 1
  fi
fi

echo "Zero-network gate: PASS (empty allowlist, no network API usage found)"
