#!/bin/bash
# Точка входа Славатор.app.
#
# Бандл намеренно не тащит внутри себя Python, torch и модели: это несколько
# гигабайт, которые невозможно передать коллегам обычным способом. Вместо
# этого при первом запуске открывается окно установки, которое разворачивает
# окружение в ~/Library/Application Support.
set -uo pipefail

CONTENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$CONTENTS/Resources"
SUPPORT="$HOME/Library/Application Support/Славатор"
VENV="$SUPPORT/env"
PYTHON="$VENV/bin/python3"

export MEETING_TRANSCRIBER_BACKEND="$RESOURCES/app/meeting_transcriber_v25_1.py"
export MEETING_TRANSCRIBER_APP_SUPPORT="$SUPPORT"
export PYTHONUNBUFFERED=1

# Первый запуск или повреждённое окружение -> установка в Терминале.
# Именно в Терминале, а не в окне: до установки нормального Python доступен
# только системный, а его Tk 8.5 на современной macOS не перерисовывает окно.
#
# Перед этим показываем нативное окно: увидеть Терминал вместо программы -
# неожиданно, и без объяснения выглядит как сбой.
if [[ ! -x "$PYTHON" || ! -f "$SUPPORT/.ready" ]]; then
    ANSWER=$(osascript <<'DIALOG' 2>/dev/null
try
    display dialog "Славатор запускается впервые.

Сейчас откроется окно Терминала — это установщик. Он развернёт всё необходимое и задаст пару вопросов.

Занимает 5–15 минут и делается один раз." ¬
        with title "Славатор" ¬
        buttons {"Отмена", "Установить"} ¬
        default button "Установить" ¬
        with icon note
    return button returned of result
on error
    return "Установить"
end try
DIALOG
)
    if [[ "$ANSWER" == "Отмена" ]]; then
        exit 0
    fi
    open -a Terminal "$RESOURCES/setup.command"
    exit 0
fi

# Пользовательские настройки: токен HuggingFace, выбранные модели, движок ASR.
if [[ -f "$SUPPORT/config.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$SUPPORT/config.env"
    set +a
fi

LOG_DIR="$SUPPORT/logs"
mkdir -p "$LOG_DIR"

cd "$RESOURCES/app" || exit 1
exec "$PYTHON" "$RESOURCES/app/meeting_transcriber_gui_v25_10.py" \
    >>"$LOG_DIR/app.log" 2>&1
