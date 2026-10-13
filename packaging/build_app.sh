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
# Сборочная папка — с суффиксом .noindex: Spotlight и Launchpad не
# заглядывают внутрь таких папок. Иначе рядом с установленным «Славатором»
# в поиске висел второй, точно такой же, и какой из них настоящий — было
# не понять. Проверено: .metadata_never_index в обычной папке Spotlight
# игнорирует, суффикс .noindex работает.
DIST="$ROOT/dist.noindex"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31mОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

# Редакция сборки: SLAVATOR_EDITION=2 собирает «Славатор 2».
#
# Вторая редакция стоит рядом с обычным Славатором, а не вместо него, поэтому
# у неё всё своё: идентификатор (иначе macOS считает их одной программой и
# делит разрешения на микрофон), имя процесса (иначе установка закрывает обе
# версии разом через pkill -x), папка с настройками и окружением Python и
# папка голосовых профилей - форматы данных у версий расходятся, и общая
# папка значила бы, что одна портит файлы другой. Общие только модели
# распознавания и словарь терминов: их обе версии лишь читают.
EDITION="${SLAVATOR_EDITION:-1}"
case "$EDITION" in
    1) APP_NAME="Славатор";   BUNDLE_ID="ru.slavator.app";  EXEC="slavator"
       SHORT_NAME="Slavator";   PROFILES_DIR="speaker_profiles";   ICON_SUFFIX="" ;;
    2) APP_NAME="Славатор 2"; BUNDLE_ID="ru.slavator.app2"; EXEC="slavator2"
       SHORT_NAME="Slavator 2"; PROFILES_DIR="speaker_profiles 2"; ICON_SUFFIX="_2" ;;
    *) fail "неизвестная редакция SLAVATOR_EDITION=$EDITION: бывает 1 или 2" ;;
esac
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"

command -v swiftc >/dev/null || fail "нет swiftc — поставьте Command Line Tools"

SOURCES=(Configuration.swift ProcessOutput.swift OutputVolume.swift Theme.swift Models.swift Documents.swift
         SpeakerMemory.swift SpeakerMemoryScreen.swift Ribbon.swift Player.swift
         Pipeline.swift SystemAudio.swift LiveCapture.swift Mixdown.swift
         Dictation.swift Chat.swift Enroll.swift Screens.swift Doctor.swift
         DeskWidget.swift MeetingWatch.swift App.swift)
for f in "${SOURCES[@]}"; do
    [[ -f "$SWIFT/$f" ]] || fail "нет исходника: $SWIFT/$f"
done
for f in meeting_transcriber_v25_1.py onnx_engine.py glossary_fix.py dictation_worker.py app_config.py speaker_memory.py speaker_links.py meeting_store.py speech_alignment.py audio_preview.py desktop_contract.json "app_icon$ICON_SUFFIX.png"; do
    [[ -f "$CORE/$f" ]] || fail "нет файла ядра: $CORE/$f"
done
[[ -f "$ROOT/icon_master$ICON_SUFFIX.png" ]] || fail "нет иконки: $ROOT/icon_master$ICON_SUFFIX.png"

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
# Имя выходного файла - без точки в начале. С ".slavator-bin" ссылка на
# SwiftUICore появлялась при тех же исходниках и флагах, с "slavator-bin" -
# нет (проверено попеременными сборками 8 сентября). На коде коллеги от 15
# сентября старое имя валит сборку на проверке ниже. -dead_strip вдобавок
# выбрасывает мёртвый код, из которого эта ссылка и росла.
swiftc -O -parse-as-library -target arm64-apple-macos14.2 \
    -Xlinker -dead_strip -Xlinker -dead_strip_dylibs \
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
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXEC" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $SHORT_NAME" "$CONTENTS/Info.plist"
# Папки данных интерфейс читает отсюда (AppConfiguration в Configuration.swift).
/usr/libexec/PlistBuddy -c "Add :SlavatorSupportFolder string $APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SlavatorProfilesFolder string $PROFILES_DIR" "$CONTENTS/Info.plist"
cp "$PROJECT/VERSION" "$RESOURCES/VERSION"
plutil -lint "$CONTENTS/Info.plist" >/dev/null || fail "Info.plist некорректен"
printf 'APPL????' > "$CONTENTS/PkgInfo"
install -m 755 "$DIST/slavator-bin" "$CONTENTS/MacOS/$EXEC"
rm -f "$DIST/slavator-bin"

say "Собираю иконку"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
MASTER="$ROOT/icon_master$ICON_SUFFIX.png"

# Иконка сборки из рабочего дерева красится в свой цвет.
#
# Рабочих копий репозитория на машине несколько — по одной на ветку, — и
# каждая складывает свой бандл. Раньше все они выглядели одинаково: в
# Spotlight и Launchpad висело несколько «Славаторов», различить которые
# можно было только по дате файла. Теперь цвет иконки — это ветка.
#
# Основная копия остаётся с исходной иконкой: она и есть настоящий
# Славатор, каким его видит человек, поставивший программу.
TINTS=("FF6FB5:0.45:розовый" "30D5C8:0.45:бирюзовый" "FFB020:0.40:янтарный"
       "A06CFF:0.45:сиреневый" "C8CEDA:0.55:бледный")
if [[ "$(git -C "$PROJECT" rev-parse --git-dir 2>/dev/null || true)" == */worktrees/* ]]; then
    COPY="$(basename "$PROJECT")"
    INDEX=$(( $(printf '%s' "$COPY" | cksum | cut -d' ' -f1) % ${#TINTS[@]} ))
    SPEC="${TINTS[$INDEX]}"
    say "Рабочая копия «$COPY» — иконка ${SPEC##*:}"
    /usr/bin/python3 "$ROOT/make_icon.py" --tint "${SPEC%:*}" "$MASTER" "$DIST/icon_tinted.png"
    MASTER="$DIST/icon_tinted.png"
fi
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$MASTER" --out "$ICONSET/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET" "$DIST/icon_tinted.png"
cp "$CORE/app_icon$ICON_SUFFIX.png" "$RESOURCES/app_icon.png"

say "Копирую ядро обработки"
for module in meeting_transcriber_v25_1.py onnx_engine.py glossary_fix.py dictation_worker.py app_config.py speaker_memory.py speaker_links.py meeting_store.py meeting_chat.py document_tools.py privacy_files.py speech_alignment.py audio_preview.py desktop_contract.json; do
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
# Установка — отдельное явное действие: сборка не должна закрывать документ
# с несохранёнными правками. SLAVATOR_INSTALL=1 включает замену приложения;
# SLAVATOR_NO_INSTALL=1 всегда оставляет установленную копию нетронутой.
INSTALLED="/Applications/$(basename "$APP")"
if [[ -n "${SLAVATOR_NO_INSTALL:-}" || "${SLAVATOR_INSTALL:-}" != "1" ]]; then
    say "Сборка готова; установленная копия не изменена (для установки: SLAVATOR_INSTALL=1)"
elif [[ ! -w /Applications ]]; then
    say "Нет прав на запись в /Applications — установите вручную"
else
    # Ищем по имени исполняемого файла, а не по пути: имя бандла — кириллица,
    # и pgrep -f по такому пути не находит ничего (проверено: процесс есть,
    # а поиск пуст), из-за чего замена шла под работающим приложением.
    RUNNING=""
    pgrep -x "$EXEC" >/dev/null && RUNNING="да"
    if [[ -n "$RUNNING" ]]; then
        say "Закрываю работающий $APP_NAME"
        osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "$EXEC" >/dev/null || break
            sleep 0.5
        done
        pkill -x "$EXEC" 2>/dev/null || true
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
