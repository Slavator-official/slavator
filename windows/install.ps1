param(
    [switch]$SkipOllama,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SupportDir = Join-Path $env:APPDATA "Славатор"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\Славатор"
$VenvDir = Join-Path $SupportDir "env"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"

function Step([string]$Text) {
    Write-Host "`n▶ $Text" -ForegroundColor Cyan
}

function Find-Python312 {
    $Launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($Launcher) {
        $Candidate = & $Launcher.Source -3.12 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $Candidate)) { return $Candidate }
    }
    $Python = Get-Command python -ErrorAction SilentlyContinue
    if ($Python) {
        $Version = & $Python.Source -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        if ($Version -eq "3.12") { return $Python.Source }
    }
    $PerUser = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"
    if (Test-Path $PerUser) { return $PerUser }
    return $null
}

Step "Python 3.12"
$BasePython = Find-Python312
if (-not $BasePython) {
    $Winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $Winget) {
        throw "Нужен Python 3.12. Установите его с python.org и повторите запуск."
    }
    & $Winget.Source install --exact --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Не удалось установить Python 3.12" }
    $BasePython = Find-Python312
}
if (-not $BasePython) { throw "Python 3.12 установлен, но не найден в PATH" }

New-Item -ItemType Directory -Force -Path $SupportDir, $InstallDir | Out-Null
if (-not (Test-Path $VenvPython)) {
    & $BasePython -m venv $VenvDir
}

Step "Библиотеки распознавания"
& $VenvPython -m pip install --upgrade pip
& $VenvPython -m pip install -r (Join-Path $PSScriptRoot "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "Не удалось установить Python-библиотеки" }

Step "Файлы Славатора"
foreach ($Name in @("core", "legacy", "windows")) {
    Copy-Item -Recurse -Force (Join-Path $ProjectRoot $Name) $InstallDir
}
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "packaging") | Out-Null
Copy-Item -Force (Join-Path $ProjectRoot "packaging\requirements*.txt") (Join-Path $InstallDir "packaging")
Copy-Item -Force (Join-Path $ProjectRoot "VERSION") $InstallDir

$Glossary = Join-Path $SupportDir "glossary.txt"
if (-not (Test-Path $Glossary)) {
    @"
# Термины вашей команды: по одному в строке.
CJM
бэклог
спринт
"@ | Set-Content -Encoding UTF8 $Glossary
}

$Config = Join-Path $SupportDir "config.env"
if (-not (Test-Path $Config)) {
@"
# Локальная конфигурация Windows.
MEETING_TRANSCRIBER_ASR="faster-whisper"
MEETING_TRANSCRIBER_LLM="qwen3:8b"
MEETING_TRANSCRIBER_GLOSSARY="$Glossary"
"@ | Set-Content -Encoding UTF8 $Config
}

if (-not $SkipOllama) {
    Step "Ollama и qwen3:8b"
    $Ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $Ollama) {
        $Winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($Winget) {
            & $Winget.Source install --exact --id Ollama.Ollama --scope user --accept-package-agreements --accept-source-agreements
        }
        $Ollama = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $Ollama) {
            $OllamaPath = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
            if (Test-Path $OllamaPath) { $Ollama = [pscustomobject]@{ Source = $OllamaPath } }
        }
    }
    if ($Ollama) {
        Start-Process -FilePath $Ollama.Source -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        & $Ollama.Source pull qwen3:8b
        & $Ollama.Source pull embeddinggemma:300m
        if ($LASTEXITCODE -ne 0) { Write-Warning "Модель смыслового поиска не скачалась. Повторите: ollama pull embeddinggemma:300m" }
    } else {
        Write-Warning "Ollama не установлена. Стенограмма будет работать, резюме — нет."
    }
}

Step "Ярлык в меню «Пуск»"
$Pythonw = Join-Path $VenvDir "Scripts\pythonw.exe"
$Launcher = Join-Path $InstallDir "windows\slavator.py"
$Programs = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path $Programs "Славатор.lnk"
$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $Pythonw
$Shortcut.Arguments = "`"$Launcher`""
$Shortcut.WorkingDirectory = $InstallDir
$Shortcut.Description = "Локальная расшифровка встреч"
$Shortcut.Save()

Write-Host "`nСлаватор установлен. Данные: $SupportDir" -ForegroundColor Green
if (-not $NoLaunch) {
    Start-Process -FilePath $Pythonw -ArgumentList "`"$Launcher`"" -WorkingDirectory $InstallDir
}
