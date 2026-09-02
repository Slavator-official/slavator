$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SupportDir = Join-Path $env:APPDATA "Славатор"
$VenvPython = Join-Path $SupportDir "env\Scripts\python.exe"

if (Test-Path $VenvPython) {
    & $VenvPython (Join-Path $PSScriptRoot "slavator.py")
    exit $LASTEXITCODE
}

$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) {
    throw "Python не найден. Сначала запустите windows\install.ps1"
}
& $Python.Source (Join-Path $PSScriptRoot "slavator.py")
