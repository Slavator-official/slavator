#!/usr/bin/env bash
# Сборка образа Славатора для передачи коллегам.
#
#   ./make_dmg.sh          — лёгкий образ (~2 МБ), всё качается при установке
#   ./make_dmg.sh --full   — полный (~5,5 ГБ): Ollama и языковая модель внутри
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
DIST="$ROOT/dist.noindex"
APP="$DIST/Славатор.app"
STAGE="$DIST/dmg"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

if [[ $FULL -eq 1 ]]; then
    DMG="$DIST/Славатор-полный.dmg"
    VOLNAME="Славатор"
else
    DMG="$DIST/Славатор.dmg"
    VOLNAME="Славатор"
fi

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31mОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -d "$APP" ]] || fail "сначала соберите приложение: $ROOT/build_app.sh"

say "Готовлю содержимое образа"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/ПРОЧТИ_МЕНЯ.txt" "$STAGE/ПРОЧТИ МЕНЯ.txt"

if [[ $FULL -eq 1 ]]; then
    PAYLOAD="$STAGE/ресурсы"
    mkdir -p "$PAYLOAD"

    [[ -f "$ROOT/payload/Ollama.dmg" ]] || fail "нет $ROOT/payload/Ollama.dmg"
    say "Кладу Ollama в комплект"
    cp "$ROOT/payload/Ollama.dmg" "$PAYLOAD/Ollama.dmg"

    # Модели разделения голосов - всего 33 МБ, кладём в комплект, чтобы у
    # получателя не было и этой загрузки.
    SPEECH="$HOME/whisper-work/models"
    if [[ -d "$SPEECH/sherpa-onnx-pyannote-segmentation-3-0" ]]; then
        say "Кладу модели разделения голосов в комплект"
        mkdir -p "$PAYLOAD/speech-models"
        cp -R "$SPEECH/sherpa-onnx-pyannote-segmentation-3-0" "$PAYLOAD/speech-models/"
        cp "$SPEECH/wespeaker_en_voxceleb_resnet34_LM.onnx" "$PAYLOAD/speech-models/" 2>/dev/null || true
        cp "$SPEECH/silero_vad.onnx" "$PAYLOAD/speech-models/" 2>/dev/null || true
    fi

    MODELS="$PROJECT/transfer/Meeting_Transcriber_FULL_TRANSFER_20260828_192521/ollama/models"
    if [[ -d "$MODELS" ]]; then
        say "Кладу языковую модель в комплект (5 ГБ, займёт минуту)"
        mkdir -p "$PAYLOAD/ollama-models"
        cp -R "$MODELS/"* "$PAYLOAD/ollama-models/"
    else
        printf '    модель не найдена в %s — образ будет без неё\n' "$MODELS"
    fi
fi

if [[ $FULL -eq 1 ]]; then
    # Опись комплекта вшивается в приложение, а приложение переподписывается:
    # установщик верит папке «ресурсы» только если она совпала с описью, а
    # опись лежит там, где её не подменить, не сломав подпись. Сама папка на
    # томе ничем не защищена — такую же может принести любая флешка.
    say "Составляю опись комплекта"
    STAGED_APP="$STAGE/$(basename "$APP")"
    (cd "$PAYLOAD" && find . -type f ! -name '.DS_Store' | LC_ALL=C sort | tr '\n' '\0' \
        | xargs -0 shasum -a 256) > "$STAGED_APP/Contents/Resources/payload.sha256"
    IDENTITY="Slavator Local Signing"
    if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
        codesign --force --deep --sign "$IDENTITY" "$STAGED_APP" 2>/dev/null \
            || fail "не удалось переподписать приложение с описью"
    else
        codesign --force --deep --sign - "$STAGED_APP" 2>/dev/null || true
    fi
fi

say "Создаю образ"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "образ собрался повреждённым"

SIZE="$(du -sh "$DMG" | cut -f1)"
say "Готово: $DMG ($SIZE)"

cat <<'NOTE'

Что сказать коллеге при передаче:

  1. Перетащить «Славатор» в «Программы» и открыть.
  2. macOS заблокирует - это ожидаемо. Системные настройки →
     Конфиденциальность и безопасность → внизу «Открыть всё равно».
  3. В окне программы нажать «Установить» и подождать.

Скрипт-установщик с образа убран намеренно: в macOS 15 и новее обход
«правой кнопкой → Открыть» больше не работает, а для файлов .command
кнопки «Открыть всё равно» система не показывает вовсе - тупик. Для
приложения показывает, поэтому единственный барьер теперь один и проходимый.

NOTE
