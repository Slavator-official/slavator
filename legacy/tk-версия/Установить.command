#!/bin/bash
# Установка Славатора с образа. Друг получает DMG и дважды кликает этот файл.
#
# Скрипт делает три вещи, которые иначе пришлось бы объяснять словами:
# копирует программу в «Программы», снимает карантин Gatekeeper (иначе macOS
# откажется запускать неподписанное приложение) и передаёт установщику путь к
# комплекту, чтобы Ollama и языковая модель ставились с образа, а не из сети.

set -uo pipefail

DMG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="$DMG_ROOT/Славатор.app"
APP_DST="/Applications/Славатор.app"

B=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; N=$'\033[0m'

clear
cat <<'HEADER'
  ╭──────────────────────────────────────────╮
  │                                          │
  │   С Л А В А Т О Р                        │
  │   расшифровка встреч на вашем Mac        │
  │                                          │
  ╰──────────────────────────────────────────╯

HEADER

if [[ ! -d "$APP_SRC" ]]; then
    printf '%sНе нахожу Славатор.app рядом с этим файлом.%s\n' "$RED" "$N"
    printf 'Запускайте «Установить» прямо с открытого образа.\n\n'
    exit 1
fi

printf 'Копирую программу в «Программы»...\n'
if [[ -d "$APP_DST" ]]; then
    printf '    Найдена прежняя версия — заменяю.\n'
    rm -rf "$APP_DST" || { printf '%sНет прав на замену %s%s\n' "$RED" "$APP_DST" "$N"; exit 1; }
fi
cp -R "$APP_SRC" "$APP_DST" || { printf '%sНе удалось скопировать программу.%s\n' "$RED" "$N"; exit 1; }

# Без этого macOS покажет «программа повреждена»: файл пришёл из интернета,
# а подписи Apple Developer у нас нет.
xattr -cr "$APP_DST" 2>/dev/null
codesign --force --deep --sign - "$APP_DST" 2>/dev/null

printf '%s✓%s Славатор установлен\n\n' "$GREEN" "$N"
printf 'Теперь настроим окружение. Это займёт 15–40 минут.\n\n'
read -r -p "Продолжить? [Enter — да, n — позже] " answer
if [[ "$answer" == "n" || "$answer" == "N" ]]; then
    printf '\nХорошо. Запустите Славатор из «Программ», когда будет удобно.\n\n'
    exit 0
fi

export MEETING_TRANSCRIBER_PAYLOAD="$DMG_ROOT/ресурсы"
exec "$APP_DST/Contents/Resources/setup.command"
