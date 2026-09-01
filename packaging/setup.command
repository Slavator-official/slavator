#!/bin/bash
# Установка Славатора. Запускается в Терминале при первом старте приложения.
#
# Почему Терминал, а не окно: мастер обязан работать ДО того, как установлен
# нормальный Python. Системный python3 на macOS несёт Tk 8.5 2010 года, и на
# современных версиях системы он не перерисовывает окно - подписи пропадают,
# кнопки накладываются друг на друга. Терминал есть всегда и не врёт.

set -uo pipefail

RESOURCES="${MEETING_TRANSCRIBER_RESOURCES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SUPPORT="$HOME/Library/Application Support/Славатор"
VENV="$SUPPORT/env"
UV="$HOME/.local/bin/uv"
PYTHON_VERSION="3.12"
DEFAULT_LLM="qwen3:8b"

B=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'

step()  { printf '\n%s==>%s %s%s\n' "$B" "$N" "$1" "$N"; }
ok()    { printf '    %s✓%s %s\n' "$GREEN" "$N" "$1"; }
warn()  { printf '    %s!%s %s\n' "$Y" "$N" "$1"; }
die()   { printf '\n%sНе получилось:%s %s\n\n' "$RED" "$N" "$1"; printf 'Окно можно закрыть. Попробуйте запустить Славатор ещё раз.\n\n'; exit 1; }

clear
cat <<'HEADER'
  ╭──────────────────────────────────────────╮
  │                                          │
  │   С Л А В А Т О Р                        │
  │   расшифровка встреч на вашем Mac        │
  │                                          │
  ╰──────────────────────────────────────────╯

Это первый запуск. Сейчас установим всё необходимое.
Записи никуда не отправляются: и распознавание, и языковая
модель работают на вашем компьютере.

HEADER

FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
printf 'Свободно на диске: %s ГБ (нужно около 10 ГБ)\n' "$FREE_GB"
if [[ "$FREE_GB" -lt 10 ]]; then
    warn "Места может не хватить."
fi

printf '\nБудет установлено:\n'
printf '  • Python и библиотеки обработки   ~250 МБ\n'
printf '  • Модели распознавания и голосов  ~1,5 ГБ, при первой обработке\n'
if [[ -f "${MEETING_TRANSCRIBER_PAYLOAD:-}/Ollama.dmg" ]]; then
    printf '  • Ollama и языковая модель        ~5 ГБ, из комплекта\n'
else
    printf '  • Ollama и языковая модель        ~5 ГБ, скачаются\n'
fi
printf '\nЗанимает 20–40 минут: почти всё время идёт загрузка.\n'
printf 'Прервать можно в любой момент: Control+C.\n\n'
read -r -p "Продолжить? [Enter — да, n — выход] " answer
[[ "$answer" == "n" || "$answer" == "N" ]] && { printf '\nОтменено.\n\n'; exit 0; }

mkdir -p "$SUPPORT" || die "нет доступа к $SUPPORT"

# --------------------------------------------------------------------------
step "Движок распознавания речи"
# --------------------------------------------------------------------------
printf '  1) Whisper large-v3 — сохраняет англицизмы, аббревиатуры и пунктуацию\n'
printf '  2) GigaAM v3       — быстрее на чистом русском, но БЕЗ латиницы и пунктуации\n\n'
read -r -p "Выберите [Enter — 1] " engine_choice
if [[ "$engine_choice" == "2" ]]; then
    ENGINE="gigaam"; ok "GigaAM v3"
else
    ENGINE="faster-whisper"; ok "Whisper large-v3"
fi

# --------------------------------------------------------------------------
step "Шаг 1 из 4: инструмент установки uv"
# --------------------------------------------------------------------------
if [[ -x "$UV" ]]; then
    ok "uv уже установлен"
else
    printf '    Загружаю с https://astral.sh/uv/install.sh\n'
    export UV_INSTALL_DIR="$HOME/.local/bin"
    export UV_NO_MODIFY_PATH=1
    curl -LsSf https://astral.sh/uv/install.sh | sh || die "не удалось установить uv (проверьте интернет)"
    [[ -x "$UV" ]] || die "uv установился, но не найден в $UV"
    ok "uv установлен"
fi

# --------------------------------------------------------------------------
step "Шаг 2 из 4: Python $PYTHON_VERSION"
# --------------------------------------------------------------------------
# Готовое окружение не пересобираем: повторный запуск установки должен
# чинить недостающее, а не сносить рабочее.
if [[ -x "$VENV/bin/python3" ]]; then
    ok "окружение Python уже есть"
else
    "$UV" venv --python "$PYTHON_VERSION" "$VENV" || die "не удалось создать окружение Python"
fi
PY="$VENV/bin/python3"
[[ -x "$PY" ]] || die "Python не найден в $PY"
ok "Python $("$PY" -V 2>&1 | cut -d' ' -f2)"

# --------------------------------------------------------------------------
step "Шаг 3 из 4: библиотеки обработки"
# --------------------------------------------------------------------------
printf '    Это самая долгая часть. Можно заварить чай.\n\n'
"$UV" pip install --python "$PY" -r "$RESOURCES/requirements.txt" \
    || die "не удалось установить библиотеки"
if [[ -f "$RESOURCES/requirements-$ENGINE.txt" ]]; then
    "$UV" pip install --python "$PY" -r "$RESOURCES/requirements-$ENGINE.txt" \
        || die "не удалось установить движок распознавания"
fi
ok "библиотеки установлены"

# --------------------------------------------------------------------------
step "Шаг 4 из 4: Ollama"
# --------------------------------------------------------------------------
# PAYLOAD задаёт «Установить.command» с образа: там уже лежат Ollama и модель,
# поэтому качать 5 ГБ из интернета не нужно.
# Комплект ищем сами на смонтированном образе: раньше путь передавал
# «Установить.command», но его с образа убрали - в macOS 15 и новее система
# не даёт открыть файл .command, скачанный из интернета.
PAYLOAD="${MEETING_TRANSCRIBER_PAYLOAD:-}"
if [[ -z "$PAYLOAD" ]]; then
    for candidate in /Volumes/*/ресурсы; do
        [[ -d "$candidate" ]] && { PAYLOAD="$candidate"; break; }
    done
fi
[[ -n "$PAYLOAD" ]] && ok "найден комплект: $PAYLOAD"

# Образ Ollama берём из комплекта, а если его нет - качаем с сайта. Лёгкий
# образ весит два мегабайта именно потому, что всё тяжёлое приезжает здесь.
OLLAMA_DMG=""
if [[ ! -d "/Applications/Ollama.app" ]]; then
    if [[ -f "$PAYLOAD/Ollama.dmg" ]]; then
        printf '    Устанавливаю Ollama из комплекта...\n'
        OLLAMA_DMG="$PAYLOAD/Ollama.dmg"
    else
        printf '    Скачиваю Ollama (около 200 МБ)...\n'
        OLLAMA_DMG="$SUPPORT/Ollama.dmg"
        # Пробуем несколько адресов и не ждём подолгу: у curl тайм-аут
        # подключения по умолчанию пять минут, и на недоступном хосте
        # установка молча стояла всё это время.
        got=0
        for url in "https://ollama.com/download/Ollama.dmg" \
                   "https://github.com/ollama/ollama/releases/latest/download/Ollama.dmg"; do
            printf '      %s\n' "${url#https://}"
            if curl -fL --progress-bar --connect-timeout 15 --max-time 1800 \
                    --retry 2 --retry-delay 3 -o "$OLLAMA_DMG" "$url"; then
                got=1; break
            fi
            rm -f "$OLLAMA_DMG"
        done
        if [[ $got -eq 0 ]]; then
            warn "не удалось скачать Ollama - похоже, GitHub недоступен"
            OLLAMA_DMG=""
        fi
    fi
fi

if [[ -n "$OLLAMA_DMG" ]]; then
    MOUNT=$(hdiutil attach -nobrowse -quiet "$OLLAMA_DMG" | awk -F'\t' 'END{print $NF}')
    if [[ -d "$MOUNT/Ollama.app" ]]; then
        cp -R "$MOUNT/Ollama.app" /Applications/ && ok "Ollama установлена"
        xattr -cr /Applications/Ollama.app 2>/dev/null
    else
        warn "не удалось прочитать образ Ollama"
    fi
    hdiutil detach "$MOUNT" -quiet 2>/dev/null
    [[ "$OLLAMA_DMG" == "$SUPPORT/Ollama.dmg" ]] && rm -f "$OLLAMA_DMG"
fi

if [[ -d "/Applications/Ollama.app" ]]; then
    open -ga Ollama 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
        sleep 1
    done
fi

if curl -fsS --max-time 4 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ok "Ollama запущена"
    if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null | grep -q "${DEFAULT_LLM%%:*}"; then
        if [[ -d "$PAYLOAD/ollama-models" ]]; then
            printf '    Переношу модель %s из комплекта (5 ГБ, пара минут)...\n' "$DEFAULT_LLM"
            mkdir -p "$HOME/.ollama/models"
            cp -R "$PAYLOAD/ollama-models/"* "$HOME/.ollama/models/" \
                && ok "модель $DEFAULT_LLM на месте" \
                || warn "не удалось перенести модель"
        else
            printf '    Скачиваю языковую модель %s (около 5 ГБ)...\n' "$DEFAULT_LLM"
            if "/Applications/Ollama.app/Contents/Resources/ollama" pull "$DEFAULT_LLM" \
               || ollama pull "$DEFAULT_LLM"; then
                ok "модель $DEFAULT_LLM установлена"
            else
                warn "модель не скачалась — выполните позже: ollama pull $DEFAULT_LLM"
            fi
        fi
    else
        ok "модель $DEFAULT_LLM уже установлена"
    fi
else
    warn "Ollama не установлена - это НЕ ошибка установки"
    printf '\n      Расшифровка, разделение по голосам и стенограмма работают\n'
    printf '      без неё. Ollama нужна только для резюме встречи и для\n'
    printf '      определения имён участников по разговору.\n\n'
    printf '      Добавить её можно в любой момент:\n'
    printf '        1. Скачать с https://ollama.com/download/mac\n'
    printf '        2. Выполнить: ollama pull %s\n\n' "$DEFAULT_LLM"
    printf '      Если сайт не открывается, попросите у отправителя\n'
    printf '      «Славатор-полный.dmg» - там Ollama и модель уже внутри.\n\n'
fi

# --------------------------------------------------------------------------
step "Модели распознавания"
# --------------------------------------------------------------------------
SPEECH_DIR="$HOME/whisper-work/models"
if [[ -d "$PAYLOAD/speech-models" ]]; then
    mkdir -p "$SPEECH_DIR"
    cp -R "$PAYLOAD/speech-models/"* "$SPEECH_DIR/" 2>/dev/null
    ok "модели разделения голосов взяты из комплекта"
else
    ok "модели скачаются при первой обработке (~33 МБ)"
fi

# --------------------------------------------------------------------------
step "Сохраняю настройки"
# --------------------------------------------------------------------------
{
    printf '# Настройки Славатора. Файл создан при установке.\n'
    printf 'MEETING_TRANSCRIBER_ASR="%s"\n' "$ENGINE"
    printf 'MEETING_TRANSCRIBER_LLM="%s"\n' "$DEFAULT_LLM"
    printf 'MEETING_TRANSCRIBER_GLOSSARY="%s/whisper-work/glossary.txt"\n' "$HOME"
} > "$SUPPORT/config.env"
chmod 600 "$SUPPORT/config.env"     # внутри личный токен
ok "настройки сохранены"

GLOSSARY="$HOME/whisper-work/glossary.txt"
if [[ ! -f "$GLOSSARY" ]]; then
    mkdir -p "$(dirname "$GLOSSARY")"
    cat > "$GLOSSARY" <<'GLOSS'
# Словарь терминов вашей команды: по одному в строке.
#
# Это главный рычаг качества. Приложение знает, как аббревиатуры звучат
# в речи, и восстанавливает их написание: услышав «си джей эм», напишет
# CJM. Но только для того, что есть в этом файле.
#
# Впишите: аббревиатуры, названия проектов и продуктов, фамилии коллег,
# англицизмы вашей предметной области.
CJM
ЦОК
МП Учителя
бэклог
спринт
дейли
ретро
стейкхолдер
GLOSS
    ok "создан словарь терминов: $GLOSSARY"
fi

date > "$SUPPORT/.ready"

printf '\n%s╭────────────────────────────────────────╮%s\n' "$GREEN" "$N"
printf '%s│  Готово. Славатор установлен.          │%s\n' "$GREEN" "$N"
printf '%s╰────────────────────────────────────────╯%s\n\n' "$GREEN" "$N"
printf 'Открываю Славатор. Дальше запускайте его как обычно —\n'
printf 'из Launchpad или папки «Программы».\n\n'

open -a "Славатор" 2>/dev/null || printf 'Откройте Славатор из папки «Программы».\n\n'
