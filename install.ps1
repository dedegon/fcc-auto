<#
.SYNOPSIS
  Установка claude-auto и FCC (Free Claude Code) на Windows.
  Запускать из папки репозитория: .\install.ps1
  Удалить только claude-auto: .\install.ps1 -Uninstall
#>
param([switch]$Uninstall)
$ErrorActionPreference = "Stop"

$LocalBin = Join-Path $env:USERPROFILE ".local\bin"
function Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok([string]$t)   { Write-Host "    OK: $t" -ForegroundColor Green }
function Warn([string]$t) { Write-Host "    ВНИМАНИЕ: $t" -ForegroundColor Yellow }
function Refresh-Path     { $env:Path = "$LocalBin;$env:Path" }
function Has([string]$cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

if (-not $MyInvocation.MyCommand.Path) {
    Write-Host "Запустите install.ps1 из папки клонированного репозитория." -ForegroundColor Red
    exit 1
}
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Uninstall) {
    Step "Удаление claude-auto"
    if (Has "uv") { uv tool uninstall claude-auto }
    Ok "claude-auto удалён. FCC и Claude Code не трогаются."
    exit 0
}

try {
    Step "1/4 uv"
    Refresh-Path
    if (-not (Has "uv")) {
        Warn "uv не найден, устанавливаю"
        irm https://astral.sh/uv/install.ps1 | iex
        Refresh-Path
    }
    if (-not (Has "uv")) { throw "uv не установлен" }
    Ok ("uv " + (uv --version))

    Step "2/4 FCC (Free Claude Code)"
    if (-not (Has "fcc-server")) {
        Warn "FCC не найден, запускаю официальный установщик FCC. Он спросит про агенты: для Claude Code ответьте Y, остальные N."
        & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.ps1")))
        Refresh-Path
    }
    if (-not (Has "fcc-server")) { throw "fcc-server не появился в PATH. Откройте новое окно PowerShell и запустите установщик снова." }
    Ok "FCC найден"

    Step "3/4 claude-auto"
    uv tool install --force $Root
    if ($LASTEXITCODE -ne 0) { throw "uv tool install завершился с ошибкой" }
    Refresh-Path
    Ok "claude-auto установлен"

    Step "4/4 Проверка"
    claude-auto --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "claude-auto --help не работает" }
    Ok "claude-auto работает"
    Write-Host "`nГотово. Перейдите в папку проекта и запустите: claude-auto" -ForegroundColor Green
}
catch {
    Write-Host "`nОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    Warn "откат: удаляю claude-auto. FCC и Claude Code не удаляются."
    if (Has "uv") { uv tool uninstall claude-auto *> $null }
    exit 1
}