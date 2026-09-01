#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="${MEETING_TRANSCRIBER_PYTHON:-$(command -v python3)}"
cd "$ROOT"
for f in meeting_transcriber_gui_v25_10.py speaker_service/service.py speaker_service/backend.py test_v25_10.py; do [[ -f "$f" ]] || { echo "ERROR: missing validation file: $ROOT/$f" >&2; exit 2; }; done
"$PY" -m py_compile meeting_transcriber_gui_v25_10.py speaker_service/service.py speaker_service/backend.py
"$PY" test_v25_10.py
"$PY" -m pytest -q tests
xvfb-run -a -s '-screen 0 1600x1000x24' "$PY" - <<'PY'
from meeting_transcriber_gui_v25_10 import UI

app=UI(); app.update_idletasks(); app.update()
assert app.page=='overview' and app.sidebar_open is False
assert app.overrideredirect() in (None, False, 0, '0')
fullscreen = app.attributes('-fullscreen')
assert fullscreen in (False, 0, '0', 'false', 'False')
assert app.resizable() in ((True, True), (1, 1))
assert app.winfo_width() <= app.winfo_screenwidth()
assert app.winfo_height() <= app.winfo_screenheight()

# Verify the six product screens at practical desktop sizes. The assertion is
# deliberately geometry-based: no rendered Canvas item may cross the window.
for geom in ('1280x800+40+40', '1100x700+40+40', '1400x850+40+40'):
    app.geometry(geom); app.update_idletasks(); app.update()
    for page in ('overview','speakers','new_voices','person','records','settings'):
        app.show(page); app.update_idletasks(); app.update()
        cw,ch=app.canvas.winfo_width(),app.canvas.winfo_height()
        for item in app.canvas.find_all():
            bbox=app.canvas.bbox(item)
            if not bbox:
                continue
            x1,y1,x2,y2=bbox
            assert x1 >= -1 and y1 >= -1 and x2 <= cw+1 and y2 <= ch+1, (geom,page,item,bbox,cw,ch)

app.toggle_sidebar(); app.update_idletasks(); app.update(); assert app.sidebar_open
app.toggle_sidebar(); app._on_close()
print('GUI smoke: PASS')
print('Window/layout matrix: PASS (1280x800, 1100x700, 1400x850)')
PY
printf 'v25.10 validation: PASS\n'
