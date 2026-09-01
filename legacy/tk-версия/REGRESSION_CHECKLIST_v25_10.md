# v25.10 Regression Checklist — build 10

## New recording
- [x] One visual container is used for file selection.
- [x] `selected_file` is the single source of truth.
- [x] No separate "Файл не выбран" block exists.
- [x] Transcription action appears only after successful file selection.
- [x] Long filenames are ellipsized.

## Audio / speakers
- [x] Play starts `afplay`.
- [x] Play changes to Pause while running.
- [x] Pause uses SIGSTOP and Resume uses SIGCONT.
- [x] Playback returns to Play after process completion.
- [x] Assigning an unknown voice removes it from unresolved voices.
- [x] The source WAV is preserved and copied into the person's samples.
- [x] Empty unresolved-voice section is hidden on Overview.
- [x] Company field remains available even when empty.

## Window / responsive layout
- [x] Uses a normal native desktop window instead of `overrideredirect`.
- [x] Window is resizable in both directions.
- [x] Window has native close/minimize/zoom controls.
- [x] Initial size is calculated from the available screen instead of a fixed oversized geometry.
- [x] Minimum size is bounded by the actual available screen.
- [x] Design scale fits the available canvas without the previous 0.78 floor.
- [x] Overview, Speakers, New Voices, Person, Records and Settings were checked at 1280×800, 1100×700 and 1400×850.
- [x] No Canvas item crosses the window bounds at those tested sizes.
- [x] No horizontal page overflow is introduced by window resizing.

## Layout
- [x] Recent Records uses proportional columns.
- [x] Long record names are ellipsized.
- [x] Status and action columns stay inside the row.
- [x] New-voice badge has deterministic gap from the arrow.
- [x] No reference image is rendered at runtime.
- [x] Sidebar remains hidden by default.
- [x] Product canvas contains no custom traffic-light controls; native macOS window controls are provided by the OS title bar.
- [x] Shared button renderer normalizes typography/radius without changing caller geometry.
- [x] Recent Records status badge cannot overlap the overflow action column.

## Build
- [x] Exact v25.10 filenames are checked by installer and validation.
- [x] Python compile.
- [x] Unit/contract tests.
- [x] Headless GUI smoke.
- [x] ZIP integrity.

## Build 10 UI regression
- [x] Overview has no theme segmented control.
- [x] Settings «Общее» keeps Theme/Language values aligned to the right edge.
- [x] Settings diagnostic toggle is aligned to the same right edge as action buttons.
- [x] Speakers counter has deterministic gaps from «Новые голоса» and «Архив».
- [x] Shared action buttons use smooth arc-based rounded corners.
- [x] Existing caller geometry and product layout are preserved.
