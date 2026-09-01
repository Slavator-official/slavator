# Meeting Transcriber v25.10 — build 10

v25.10 is a point release over the existing v25.6 GUI. No application rewrite and no business/API redesign.

## Changes
- removed the global light/dark theme control from the application chrome; the primary action remains the only header control on Overview;
- aligned all Settings controls to the card's right edge using layout geometry instead of fixed x coordinates;
- reserved an explicit overflow-menu column in Recent Records and ellipsized long values inside their own columns;
- replaced coarse polygon button corners with true Canvas arc-based rounded rectangles for smoother, more even button chrome;
- restored a normal native macOS desktop window with close/minimize/zoom and mouse resizing; the product canvas itself remains borderless;
- normalized canvas button typography, border and radius treatment through the shared `button()` renderer;
- kept button geometry owned by the layout so normalization cannot make controls cross card boundaries;
- reserved a dedicated action column in Recent Records so status badges cannot overlap the overflow menu;
- unified the new-record file selection into one container driven only by `selected_file`;
- removed the duplicate empty-state block and hid the transcription action until a file is selected;
- kept the Finder selection path and the existing backend boundary;
- added stable Play/Pause/Resume state for WAV playback using the macOS `afplay` process;
- removed assigned unknown voices from the unresolved list without deleting the source WAV;
- conditionally hide the Overview "Новые голоса" section when there are no unresolved voices;
- constrained Recent Records columns proportionally and ellipsized long values;
- fixed the `+N` badge/arrow layout with a deterministic flex-like geometry;
- made the initial window size screen-aware and capped it to a practical 1280×800 target;
- removed the fixed scale floor that caused horizontal overflow on smaller windows;
- verified all six screens at 1280×800, 1100×700 and 1400×850 with no canvas item outside the window bounds;
- added clean shutdown of scheduled GUI polling when the window is closed;
- preserved the hidden-by-default sidebar, Company field, person editing, separate `speaker_service`, and v25.1 backend adapter.

## Validation
Run `./validate_v25_10.sh` from this exact build directory before installation. The installer performs exact filename preflight checks before copying anything.

## v25.10 build 10 UI fixes
- removed the remaining Overview theme segmented control;
- kept Settings theme/language values as aligned right-side value boxes inside «Общее»;
- kept the diagnostic toggle in «Безопасность и приватность» aligned to the same right edge as «Изменить» and «Проверить»;
- increased spacing between «Новые голоса», its counter and «Архив» so the counter cannot touch adjacent labels;
- unified all action buttons through the same smooth rounded renderer.
