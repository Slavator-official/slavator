#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:?Укажите путь к проекту meeting_transcriber_v25_1_project}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

# Preflight: never install a partial/mismatched build.
[[ -f "$ROOT/PACKAGE_MANIFEST_v25_10.txt" ]] || { echo "ERROR: missing package manifest: $ROOT/PACKAGE_MANIFEST_v25_10.txt" >&2; exit 2; }
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$ROOT/$f" ]] || { echo "ERROR: manifest file missing: $ROOT/$f" >&2; exit 2; }
done < "$ROOT/PACKAGE_MANIFEST_v25_10.txt"
if find "$ROOT" -maxdepth 2 -type f -name '*v25_8*' -o -name '*v25_7*' -print -quit | grep -q .; then
  echo "ERROR: stale v25.8/v25.7 artifact found in build directory: $ROOT" >&2
  exit 2
fi
[[ -d "$ROOT/speaker_service" ]] || { echo "ERROR: missing speaker_service" >&2; exit 2; }
grep -q 'APP_VERSION = "25.10"' "$ROOT/meeting_transcriber_gui_v25_10.py" || { echo "ERROR: GUI version mismatch" >&2; exit 2; }

mkdir -p "$TARGET"
for previous in v25_6 v25_5; do
  if [[ -f "$TARGET/meeting_transcriber_gui_${previous}.py" ]]; then cp "$TARGET/meeting_transcriber_gui_${previous}.py" "$TARGET/meeting_transcriber_gui_${previous}.py.backup_25_10"; fi
done
if [[ -f "$TARGET/meeting_transcriber_gui.py" ]]; then cp "$TARGET/meeting_transcriber_gui.py" "$TARGET/meeting_transcriber_gui.py.backup_25_10"; fi
rm -rf "$TARGET/speaker_service"
cp -R "$ROOT/speaker_service" "$TARGET/speaker_service"
cp "$ROOT/meeting_transcriber_gui_v25_10.py" "$TARGET/meeting_transcriber_gui_v25_10.py"
cp "$ROOT/run_v25_10.sh" "$TARGET/run_v25_10.sh"
cp "$ROOT/README_v25_10.md" "$TARGET/README_v25_10.md"
chmod +x "$TARGET/run_v25_10.sh"
printf '\nInstalled Meeting Transcriber GUI v25.10 into: %s\nRun: %s/run_v25_10.sh\n' "$TARGET" "$TARGET"
