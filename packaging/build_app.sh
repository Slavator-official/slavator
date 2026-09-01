#!/usr/bin/env bash
# Сборка Славатор.app.
#
# Интерфейс нативный, на SwiftUI: компилируется swiftc из Command Line Tools,
# полный Xcode не нужен. Обработка осталась на Python и лежит внутри бандла —
# Swift запускает её подпроцессом и читает stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
SWIFT="$PROJECT/app"
CORE="$PROJECT/core"
DIST="$ROOT/dist"
APP="$DIST/Славатор.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31mОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

command -v swiftc >/dev/null || fail "нет swiftc — поставьте Command Line Tools"

SOURCES=(Theme.swift Models.swift Ribbon.swift Player.swift Pipeline.swift
         SystemAudio.swift LiveCapture.swift Dictation.swift Enroll.swift Screens.swift App.swift)
for f in "${SOURCES[@]}"; do
    [[ -f "$SWIFT/$f" ]] || fail "нет исходника: $SWIFT/$f"
done
for f in meeting_transcriber_v25_1.py onnx_engine.py glossary_fix.py dictation_worker.py app_icon.png; do
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
swiftc -O -parse-as-library -target arm64-apple-macos14.2 \
    -Xlinker -dead_strip_dylibs \
    -o "$DIST/.slavator-bin" "${SOURCES[@]}" || fail "не собирается интерфейс"

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
cp "$PROJECT/VERSION" "$RESOURCES/VERSION"
plutil -lint "$CONTENTS/Info.plist" >/dev/null || fail "Info.plist некорректен"
printf 'APPL????' > "$CONTENTS/PkgInfo"
install -m 755 "$DIST/.slavator-bin" "$CONTENTS/MacOS/slavator"
rm -f "$DIST/.slavator-bin"

say "Собираю иконку"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
MASTER="$ROOT/icon_master.png"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$MASTER" --out "$ICONSET/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"
cp "$CORE/app_icon.png" "$RESOURCES/app_icon.png"

say "Копирую ядро обработки"
for module in meeting_transcriber_v25_1.py onnx_engine.py glossary_fix.py dictation_worker.py; do
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
