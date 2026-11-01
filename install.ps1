<#
.SYNOPSIS
  Установка и удаление claude-auto.
  Путь установки записывается в манифест (%LOCALAPPDATA%\claude-auto\install.json).
  Удаление работает из любой папки: удаляется папка, из которой запущен установщик.
.EXAMPLE
  .\install.ps1                  установка или обновление
  .\install.ps1 -Uninstall       удаление с подтверждением
  .\install.ps1 -Uninstall -Yes  удаление без вопроса
#>
param([switch]$Uninstall, [switch]$Yes)
$ErrorActionPreference = "Stop"

if (-not $MyInvocation.MyCommand.Path) {
    Write-Host "Запустите install.ps1 из папки клонированного репозитория." -ForegroundColor Red
    exit 1
}
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalBin = Join-Path $env:USERPROFILE ".local\bin"
$DataDir  = Join-Path $env:LOCALAPPDATA "claude-auto"
$Manifest = Join-Path $DataDir "install.json"
$LogFile  = Join-Path $DataDir "install.log"
$Utf8     = New-Object System.Text.UTF8Encoding $false

function Step([string]$t)  { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok([string]$t)    { Write-Host "    OK: $t" -ForegroundColor Green }
function Warn([string]$t)  { Write-Host "    ВНИМАНИЕ: $t" -ForegroundColor Yellow }
function Refresh-Path      { $env:Path = "$LocalBin;$env:Path" }
function Has([string]$cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $Manifest)) { return $null }
    try { Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Write-Manifest([string]$status) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $data = [ordered]@{
        repo_path = $Root
        status    = $status
        updated   = (Get-Date).ToString("s")
        data_dir  = $DataDir
    }
    [IO.File]::WriteAllText($Manifest, ($data | ConvertTo-Json), $Utf8)
}

function Test-OurRepo([string]$path) {
    $toml = Join-Path $path "pyproject.toml"
    if (-not (Test-Path -LiteralPath $toml)) { return $false }
    return [bool]((Get-Content -LiteralPath $toml -Raw) -match 'name\s*=\s*"claude-auto"')
}

function Uninstall-Tool {
    if (Has "uv") { try { uv tool uninstall claude-auto 2>&1 | Out-Null } catch { } }
}

# Надёжный запуск внешней команды с захватом и stdout, и stderr.
function Invoke-Captured([string]$exe, [string[]]$argv) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Write-Host "    команда: $exe $($argv -join ' ')" -ForegroundColor DarkGray

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = ($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $code = $p.ExitCode

    $all = @()
    if ($stdout.Trim()) { $all += $stdout.TrimEnd().Split("`n") }
    if ($stderr.Trim()) { $all += $stderr.TrimEnd().Split("`n") }

    foreach ($line in $all) { Write-Host "    $line" }

    try {
        Add-Content -LiteralPath $LogFile -Value ("`n=== $exe $($argv -join ' ') (exit $code) ===") -Encoding UTF8
        Add-Content -LiteralPath $LogFile -Value ($all -join "`n") -Encoding UTF8
    } catch { }

    return @{ Code = $code; Output = $all }
}

if ($Uninstall) {
    Step "Удаление claude-auto"
    if (-not (Test-OurRepo $Root)) { throw "В $Root не найден проект claude-auto. Ничего не удалено." }

    $m = Read-Manifest
    if ($m -and $m.repo_path -and ($m.repo_path -ne $Root)) {
        Warn "манифест указывает на $($m.repo_path), а установщик запущен из $Root. Удаляю папку, из которой запущен установщик."
    }
    Write-Host "`nБудет удалено:"
    Write-Host "  - команда claude-auto (uv tool)"
    Write-Host "  - данные и кэш: $DataDir"
    Write-Host "  - папка проекта: $Root (вместе с .git)"
    Write-Host "Не затрагивается: FCC, Claude Code, ~\.fcc"
    if (-not $Yes) {
        $ans = Read-Host "Продолжить? (y/N)"
        if ($ans -notmatch '^(y|yes|д|да)$') { Write-Host "Отменено."; exit 0 }
    }

    Uninstall-Tool
    if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
    Ok "команда и данные удалены"

    Set-Location $env:USERPROFILE
    try {
        Remove-Item -LiteralPath $Root -Recurse -Force
        Ok "папка проекта удалена"
    }
    catch {
        $inner = @"
`$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Seconds 3
for (`$i = 1; `$i -le 20; `$i++) {
    if (-not (Test-Path -LiteralPath '$($Root.Replace("'","''"))')) { break }
    Remove-Item -LiteralPath '$($Root.Replace("'","''"))' -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath '$($Root.Replace("'","''"))') { Start-Sleep -Seconds 1 }
}
"@
        Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $inner
        Warn "папка занята, удалю её в фоне через пару секунд: $Root"
    }
    Write-Host "`nFCC и Claude Code не тронуты." -ForegroundColor Green
    exit 0
}

try {
    Write-Manifest "in_progress"

    Step "1/5 uv"
    Refresh-Path
    if (-not (Has "uv")) {
        Warn "uv не найден, устанавливаю"
        irm https://astral.sh/uv/install.ps1 | iex
        Refresh-Path
    }
    if (-not (Has "uv")) { throw "uv не установлен" }
    Ok ("uv " + (uv --version))

    Step "2/5 FCC (Free Claude Code)"
    if (-not (Has "fcc-server")) {
        Warn "FCC не найден, запускаю официальный установщик FCC. Для Claude Code ответьте Y, остальные агенты N."
        & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.ps1")))
        Refresh-Path
    }
    if (-not (Has "fcc-server")) { throw "fcc-server не появился в PATH. Откройте новое окно PowerShell и запустите установщик снова." }
    Ok "FCC найден"

    Step "3/5 claude-auto"

    $tomlPath = Join-Path $Root "pyproject.toml"
    if (-not (Test-Path -LiteralPath $tomlPath)) { throw "Не найден pyproject.toml в $Root" }
    $toml = Get-Content -LiteralPath $tomlPath -Raw
    if ($toml -notmatch 'name\s*=\s*"claude-auto"') {
        Warn "в pyproject.toml не найдено name = `"claude-auto`". uv может установить не тот пакет."
    }

    try { uv cache clean 2>&1 | Out-Null } catch { }

    # Расширенный набор попыток: от самой совместимой к более агрессивной.
    $attempts = @(
        @{ Name = "базовая";                          Args = @("tool", "install", "--force", $Root) },
        @{ Name = "без build-isolation";              Args = @("tool", "install", "--force", "--no-build-isolation", $Root) },
        @{ Name = "с Python 3.12";                    Args = @("tool", "install", "--force", "--python", "3.12", $Root) },
        @{ Name = "с Python 3.11";                    Args = @("tool", "install", "--force", "--python", "3.11", $Root) },
        @{ Name = "с Python 3.11 без isolation";      Args = @("tool", "install", "--force", "--python", "3.11", "--no-build-isolation", $Root) },
        @{ Name = "без кэша и с reinstall";           Args = @("tool", "install", "--force", "--no-cache", "--reinstall", $Root) }
    )

    $installed = $false
    $lastOutput = @()
    foreach ($a in $attempts) {
        Write-Host "    попытка: $($a.Name)" -ForegroundColor DarkGray
        $r = Invoke-Captured "uv" $a.Args
        if ($r.Code -eq 0) { $installed = $true; break }
        $lastOutput = $r.Output
        Warn "попытка '$($a.Name)' не удалась (exit $($r.Code))"
    }

    if (-not $installed) {
        Write-Host "`nПолный вывод uv (последняя попытка):" -ForegroundColor Red
        foreach ($line in $lastOutput) { Write-Host "    $line" -ForegroundColor Red }
        throw "uv tool install не удался. Полный лог: $LogFile"
    }

    Refresh-Path
    Ok "claude-auto установлен"

    Step "4/5 Проверка"
    claude-auto --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "claude-auto --help не работает (exit $LASTEXITCODE). Смотрите лог: $LogFile" }
    Ok "claude-auto работает"

    Step "5/5 Манифест"
    Write-Manifest "installed"
    Ok "путь установки записан: $Manifest"
    Write-Host "`nГотово. Перейдите в папку проекта и запустите: claude-auto" -ForegroundColor Green
}
catch {
    Write-Host "`nОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    Warn "откат: удаляю claude-auto. FCC и Claude Code не удаляются."
    Uninstall-Tool
    try { Write-Manifest "failed" } catch { }
    exit 1
}