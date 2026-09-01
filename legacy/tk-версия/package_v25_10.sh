#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(dirname "$ROOT")"
OUT="${1:-$PARENT/Meeting_Transcriber_v25_10_build_10.zip}"

# Never create a downloadable archive before the full validation suite passes.
"$ROOT/validate_v25_10.sh"

# Validation creates Python caches; they are never part of a release archive.
find "$ROOT" -type d \( -name __pycache__ -o -name .pytest_cache \) -prune -exec rm -rf {} +

[[ -f "$ROOT/PACKAGE_MANIFEST_v25_10.txt" ]] || { echo "ERROR: missing package manifest" >&2; exit 2; }
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$ROOT/$f" ]] || { echo "ERROR: manifest file missing: $ROOT/$f" >&2; exit 2; }
done < "$ROOT/PACKAGE_MANIFEST_v25_10.txt"

if find "$ROOT" -maxdepth 2 -type f -name '*v25_8*' -o -name '*v25_7*' -print -quit | grep -q .; then
  echo "ERROR: stale v25.8/v25.7 artifact found: $ROOT" >&2
  exit 2
fi

rm -f "$OUT"
BASE="$(basename "$ROOT")"
(cd "$PARENT" && zip -qr "$OUT" "$BASE")
unzip -t "$OUT" >/dev/null
printf 'Archive validation: PASS\n%s\n' "$OUT"
