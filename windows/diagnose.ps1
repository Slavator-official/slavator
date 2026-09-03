# Что не так со Славатором на этой машине.
#
# Программа запускается ярлыком через pythonw.exe, у которого нет консоли:
# если что-то не сложилось, окно просто не появляется, и причину увидеть
# нечем. Этот скрипт проверяет всё по цепочке и говорит, где обрыв.
#
#   powershell -ExecutionPolicy Bypass -File windows\diagnose.ps1

$ErrorActionPreference = "Continue"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SupportDir = Join-Path $env:APPDATA "Славатор"
$VenvPython = Join-Path $SupportDir "env\Scripts\python.exe"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\Славатор"

$bad = 0
function Ok([string]$t)   { Write-Host "  [ок]   $t" -ForegroundColor Green }
function Bad([string]$t)  { Write-Host "  [нет]  $t" -ForegroundColor Red; $script:bad++ }
function Note([string]$t) { Write-Host "  [.]    $t" -ForegroundColor DarkGray }
function Step([string]$t) { Write-Host "`n$t" -ForegroundColor Cyan }

Write-Host "Проверка Славатора" -ForegroundColor White

Step "Окружение Python"
if (Test-Path $VenvPython) {
    Ok "питон окружения: $VenvPython"
    $v = & $VenvPython -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
    Note "версия $v"
} else {
    Bad "нет питона окружения ($VenvPython). Запустите windows\install.ps1"
}

Step "Библиотеки окна"
if (Test-Path $VenvPython) {
    $webview = & $VenvPython -c "import webview; print(webview.__version__)" 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "pywebview $webview" }
    else { Bad "pywebview не импортируется: $webview" }

    # На Windows окно рисует Edge через мост pythonnet. Без него pywebview
    # ставится, но не запускается — и это самая частая причина «ничего не
    # происходит».
    $clr = & $VenvPython -c "import clr; print('ok')" 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "pythonnet на месте" }
    else { Bad "нет pythonnet — окно не откроется: $clr" }
}

Step "Движок Edge (WebView2)"
$keys = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
) | Where-Object { Test-Path $_ }
if ($keys) { Ok "WebView2 установлен" }
else { Bad "нет WebView2: https://go.microsoft.com/fwlink/p/?LinkId=2124703" }

Step "Файлы программы"
foreach ($item in @("windows\slavator.py", "windows\ui\index.html", "core\meeting_transcriber_v25_1.py")) {
    $path = Join-Path $ProjectRoot $item
    if (Test-Path $path) { Ok $item } else { Bad "нет $item" }
}
if (Test-Path $InstallDir) { Note "установленная копия: $InstallDir" }

Step "Библиотеки обработки"
if (Test-Path $VenvPython) {
    foreach ($pair in @(@("av","чтение видео"), @("faster_whisper","распознавание"),
                        @("sherpa_onnx","разделение голосов"), @("docx","документы"),
                        @("soundcard","запись звука"))) {
        $out = & $VenvPython -c "import $($pair[0])" 2>&1
        if ($LASTEXITCODE -eq 0) { Ok "$($pair[0]) — $($pair[1])" }
        else { Bad "$($pair[0]) не ставится: $($pair[1])" }
    }
}

Step "Ollama"
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/version" -TimeoutSec 3 -UseBasicParsing
    Ok "Ollama отвечает"
    $tags = (Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5 -UseBasicParsing).Content
    if ($tags -match '"name":"qwen3:8b"') { Ok "модель qwen3:8b на месте" }
    else { Note "нет модели qwen3:8b — резюме и чат работать не будут: ollama pull qwen3:8b" }
} catch {
    Note "Ollama не запущена. Расшифровка и голоса работают без неё, резюме и чат — нет"
}

Step "Журнал запусков"
$log = Join-Path $SupportDir "logs\app.log"
if (Test-Path $log) {
    Note $log
    Get-Content $log -Tail 12 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
} else {
    Note "журнала нет — программа ещё ни разу не стартовала"
}

Write-Host ""
if ($bad -eq 0) {
    Write-Host "Всё на месте. Если окно всё равно не открывается — пришлите журнал выше." -ForegroundColor Green
} else {
    Write-Host "Помечено красным: $bad. Начинать чинить отсюда." -ForegroundColor Yellow
}
