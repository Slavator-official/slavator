#!/usr/bin/env bash
# Основная сборка — только из закоммиченного кода.
#
#   packaging/build_stable.sh            — из HEAD
#   packaging/build_stable.sh v0.13.0    — из тега или коммита
#
# В рабочей папке почти всегда лежит недоделанное: её собирает тестовая
# «Славатор Dev», для того она и есть. 21.09 основную собрали прямо из
# папки, и в неё уехала незаконченная доработка диктовки — у человека,
# который работает основной каждый день, диктовка стала кривой. Поэтому
# код берётся из коммита во временную папку и собирается там.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
REF="${1:-HEAD}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/slavator-stable.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf '\033[1m==>\033[0m Основная из %s (%s)\n' "$REF" "$(git -C "$PROJECT" rev-parse --short "$REF")"
git -C "$PROJECT" archive "$REF" | tar -x -C "$TMP"
bash "$TMP/packaging/build_app.sh" --stable

# Копия остаётся в dist.noindex: из неё make_dmg.sh делает образ выпуска.
BUILT="$TMP/packaging/dist.noindex/Славатор.app"
KEPT="$ROOT/dist.noindex/Славатор.app"
mkdir -p "$ROOT/dist.noindex"
rm -rf "$KEPT"
ditto "$BUILT" "$KEPT"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$KEPT" >/dev/null 2>&1 || true
