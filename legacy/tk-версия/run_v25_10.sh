#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$ROOT/meeting_transcriber_gui_v25_10.py" ]] || { echo "ERROR: GUI file not found: $ROOT/meeting_transcriber_gui_v25_10.py" >&2; exit 2; }
grep -q 'APP_VERSION = "25.10"' "$ROOT/meeting_transcriber_gui_v25_10.py" || { echo "ERROR: GUI version mismatch: $ROOT/meeting_transcriber_gui_v25_10.py" >&2; exit 2; }
PY="${MEETING_TRANSCRIBER_PYTHON:-$HOME/whisper-work/.venv-diarization/bin/python}"
if [[ ! -x "$PY" ]]; then PY="$(command -v python3)"; fi
exec "$PY" "$ROOT/meeting_transcriber_gui_v25_10.py"
