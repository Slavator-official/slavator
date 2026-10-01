#!/usr/bin/env bash
# Сборка Славатор.app и тестовой «Славатор Dev.app».
#
# Интерфейс нативный, на SwiftUI: компилируется swiftc из Command Line Tools,
# полный Xcode не нужен. Обработка осталась на Python и лежит внутри бандла —
# Swift запускает её подпроцессом и читает stdout.
set -euo pipefail

# Две сборки на одной машине.
#
#   build_app.sh            — «Славатор Dev», тестовая: синяя иконка с
#                             плашкой DEV, свой идентификатор, ставится
#                             рядом с основной; собирается из папки как есть
#   build_app.sh --stable   — «Славатор», основная: ей пользуются каждый
#                             день, из неё же делается образ для выпуска.
#                             Руками не вызывать: build_stable.sh собирает
#                             её из коммита, без недоделанного из папки
#
# Тестовая по умолчанию намеренно: раньше каждая пробная сборка заменяла
# в «Программах» ту, которой человек работал, и недоделанное попадало
# прямо в его день. Пока основная запущена, тестовая выключает у себя
# диктовку, виджет, значок в меню и слежение за встречами (Edition в
# app/App.swift) — иначе обе ловили бы одну и ту же клавишу.
EDITION="dev"
[[ "${1:-}" == "--stable" ]] && EDITION="stable"
if [[ "$EDITION" == "stable" ]]; then
    NAME="Славатор";     BUNDLE_ID="ru.slavator.app";     EXE="slavator"
    LATIN="Slavator"
else
    NAME="Славатор Dev"; BUNDLE_ID="ru.slavator.app.dev"; EXE="slavator-dev"
    LATIN="Slavator Dev"
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
SWIFT="$PROJECT/app"
CORE="$PROJECT/core"
# Сборочная папка — с суффиксом .noindex: Spotlight и Launchpad не
# заглядывают внутрь таких папок. Иначе рядом с установленным «Славатором»
# в поиске висел второй, точно такой же, и какой из них настоящий — было
# не понять. Проверено: .metadata_never_index в обычной папке Spotlight
# игнорирует, суффикс .noindex работает.
DIST="$ROOT/dist.noindex"
APP="$DIST/$NAME.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31mОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

command -v swiftc >/dev/null || fail "нет swiftc — поставьте Command Line Tools"

# SDK под свой компилятор. После обновления Command Line Tools рядом может
# остаться SDK от другой версии Swift, и xcrun берёт самый новый — тогда
# swiftc не собирает ничего («this SDK is not supported by the compiler»).
# MacOSX.sdk — ссылка, которую установщик ставит на SDK своего компилятора.
if [[ -z "${SDKROOT:-}" && -d "$(xcode-select -p)/SDKs/MacOSX.sdk" ]]; then
    export SDKROOT="$(xcode-select -p)/SDKs/MacOSX.sdk"
fi

SOURCES=(Configuration.swift ProcessOutput.swift OutputVolume.swift Theme.swift Models.swift
         SpeakerMemory.swift SpeakerMemoryScreen.swift Ribbon.swift Player.swift
         Pipeline.swift SystemAudio.swift LiveCapture.swift Mixdown.swift Recovery.swift
         Dictation.swift Chat.swift Enroll.swift Screens.swift Doctor.swift
         DeskWidget.swift MeetingWatch.swift App.swift)
for f in "${SOURCES[@]}"; do
    [[ -f "$SWIFT/$f" ]] || fail "нет исходника: $SWIFT/$f"
done
for f in meeting_transcriber_v25_1.py onnx_engine.py glossary_fix.py repeats.py dictation_worker.py app_config.py speaker_memory.py speaker_links.py meeting_store.py speech_alignment.py audio_preview.py desktop_contract.json app_icon.png; do
    [[ -f "$CORE/$f" ]] || fail "нет файла ядра: $CORE/$f"
done

say "Проверка синтаксиса Python"
/usr/bin/python3 -m py_compile \
    "$CORE/meeting_transcriber_v25_1.py" "$CORE/onnx_engine.py" \
    "$CORE/glossary_fix.py" "$CORE/speaker_service/service.py"
bash -n "$ROOT/setup.command" || fail "setup.command содержит синтаксическую ошибку"

say "Компиляция SwiftUI"
mkdir -p "$DIST"
cd "$SWIFT"
# -parse-as-library обязателен: иначе @main конфликтует с кодом верхнего уровня.
# Цель сборки - macOS 14.2: на ней появились Core Audio process taps, без
# которых нет записи звука компьютера. Ниже опускать нельзя, выше - незачем.
#
# -dead_strip_dylibs убирает зависимости, из которых ничего не используется.
# Без него линковщик прописывал SwiftUICore - фреймворк из macOS 15, которого
# на Sonoma не существует, и приложение там падало при запуске.
#
# Имя промежуточного файла — без точки в начале. С Command Line Tools 26.6
# бинарник с именем «.slavator-bin» при тех же исходниках и флагах получал
# зависимость от SwiftUICore, а с именем без точки — нет (проверено
# несколько раз подряд, 29.09.2026).
swiftc -O -parse-as-library -target arm64-apple-macos14.2 \
    -Xlinker -dead_strip_dylibs \
    -o "$DIST/slavator-bin" "${SOURCES[@]}" || fail "не собирается интерфейс"

# A view modifier added in a future edit can pull SwiftUICore back in even
# with dead stripping. Fail before replacing the last runnable bundle.
if otool -L "$DIST/slavator-bin" | grep -q '/SwiftUICore.framework/'; then
    fail "бинарник зависит от SwiftUICore (macOS 15), но поддерживается macOS 14.2"
fi

say "Создаю бандл"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES/core"
VERSION="$(tr -d '[:space:]' < "$PROJECT/VERSION")"
[[ -n "$VERSION" ]] || fail "пустой файл VERSION"
say "Версия $VERSION"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
# Версия проставляется из VERSION, а не правится в манифесте руками:
# два независимых номера на одну программу — источник путаницы.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleExecutable $EXE" -c "Set :CFBundleName '$LATIN'" \
    -c "Set :CFBundleDisplayName '$NAME'" "$CONTENTS/Info.plist"
say "Сборка «$NAME» ($BUNDLE_ID)"
cp "$PROJECT/VERSION" "$RESOURCES/VERSION"
plutil -lint "$CONTENTS/Info.plist" >/dev/null || fail "Info.plist некорректен"
printf 'APPL????' > "$CONTENTS/PkgInfo"
install -m 755 "$DIST/slavator-bin" "$CONTENTS/MacOS/$EXE"
rm -f "$DIST/slavator-bin"

say "Собираю иконку"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
MASTER="$ROOT/icon_master.png"

# Тестовая сборка — ярко-синий фон и плашка DEV: в Dock, Spotlight и
# переключателе программ её видно сразу. Сплошная синяя тонировка не
# годилась: исходный фон сам голубой, и две иконки читались как одна.
# Основная — с исходной иконкой, какой её видит человек, поставивший
# программу.
if [[ "$EDITION" == "dev" ]]; then
    say "Иконка DEV — тестовая сборка"
    /usr/bin/python3 "$ROOT/make_icon.py" --dev "$MASTER" "$DIST/icon_tinted.png" >/dev/null
    MASTER="$DIST/icon_tinted.png"
fi
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$MASTER" --out "$ICONSET/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET" "$DIST/icon_tinted.png"
if [[ "$EDITION" == "dev" ]]; then
    /usr/bin/python3 "$ROOT/make_icon.py" --dev "$CORE/app_icon.png" "$RESOURCES/app_icon.png" >/dev/null
else
    cp "$CORE/app_icon.png" "$RESOURCES/app_icon.png"
fi

say "Копирую ядро обработки"
for module in meeting_transcriber_v25_1.py onnx_engine.py glossary_fix.py repeats.py dictation_worker.py app_config.py speaker_memory.py speaker_links.py meeting_store.py meeting_chat.py speech_alignment.py audio_preview.py desktop_contract.json; do
    cp "$CORE/$module" "$RESOURCES/core/"
done
cp -R "$CORE/speaker_service" "$RESOURCES/core/speaker_service"
find "$RESOURCES/core" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
install -m 755 "$ROOT/setup.command" "$RESOURCES/setup.command"
cp "$ROOT"/requirements*.txt "$RESOURCES/"

# Постоянная локальная подпись вместо ad-hoc.
#
# У ad-hoc подписи идентичность меняется при каждой сборке, и macOS считает
# приложение новым: разрешения на микрофон и системный звук приходится
# выдавать заново после каждого обновления. С постоянным сертификатом
# система узнаёт программу и разрешения сохраняются.
# Кэш Python внутри бандла ломает подпись, а с ней слетают разрешения macOS.
find "$RESOURCES" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

IDENTITY="Slavator Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    say "Подписываю постоянным сертификатом"
    codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null \
        || fail "не удалось подписать сертификатом «$IDENTITY»"
else
    say "Подписываю (ad-hoc — разрешения будут переспрашиваться)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

say "Готово: $APP ($(du -sh "$APP" | cut -f1))"

# Свежая сборка заменяет установленную копию.
#
# Без этого шага собранное лежало в dist, а человек запускал старое из
# /Applications и не видел ни одной правки: три сборки подряд «прошли
# успешно», а программа на экране оставалась позавчерашней.
#
# Работающий экземпляр перед заменой закрывается — подменить бандл под
# запущенным процессом значит получить наполовину старое приложение, — и
# поднимается снова, если он работал. Путь и подпись те же, поэтому
# выданные разрешения на микрофон и системный звук остаются.
#
# SLAVATOR_NO_INSTALL=1 — собрать, не трогая установленное.
INSTALLED="/Applications/$(basename "$APP")"
if [[ -n "${SLAVATOR_NO_INSTALL:-}" ]]; then
    say "Установка пропущена: SLAVATOR_NO_INSTALL"
elif [[ ! -w /Applications ]]; then
    say "Нет прав на запись в /Applications — установите вручную"
else
    # Ищем по имени исполняемого файла, а не по пути: имя бандла — кириллица,
    # и pgrep -f по такому пути не находит ничего (проверено: процесс есть,
    # а поиск пуст), из-за чего замена шла под работающим приложением.
    #
    # Закрывается только своя сборка: у основной и тестовой разные имена
    # исполняемого файла, и пересборка тестовой не трогает ту, которой
    # человек сейчас работает.
    RUNNING=""
    pgrep -x "$EXE" >/dev/null && RUNNING="да"
    if [[ -n "$RUNNING" ]]; then
        say "Закрываю работающий «$NAME»"
        osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "$EXE" >/dev/null || break
            sleep 0.5
        done
        pkill -x "$EXE" 2>/dev/null || true
        sleep 0.5
    fi
    say "Ставлю в /Applications"
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED" || fail "не удалось поставить в /Applications"
    codesign -v "$INSTALLED" 2>/dev/null || say "внимание: подпись установленной копии не проверяется"
    # Снимаем сборочную копию с учёта: иначе Launchpad и Spotlight держат её
    # как ещё одно приложение рядом с установленным.
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    if [[ -n "$RUNNING" ]]; then
        # -g: не выводить вперёд. Сборка идёт, пока человек занят другим, и
        # выведенное окно забирает фокус посреди его работы — а диктовка,
        # начатая после этого, печатала бы уже не туда, куда он смотрит.
        say "Запускаю заново"
        open -g "$INSTALLED"
    fi
fi
