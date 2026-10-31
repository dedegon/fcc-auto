<#
.SYNOPSIS
  Полное удаление fcc-auto-claude и FCC.
  Запускается из uninstall.exe (внедрённого в install.exe).
.PARAMETER Silent
  Тихий режим без подтверждений.
#>
param([switch]$Silent, [switch]$Yes)
$ErrorActionPreference = "Stop"

$APP_NAME = "fcc-auto-claude"
$INSTALL_DIR = "C:\Program Files (x86)\fcc-auto-claude"
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Step([string]$t)  { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok([string]$t)    { Write-Host "    OK: $t" -ForegroundColor Green }
function Warn([string]$t)  { Write-Host "    ВНИМАНИЕ: $t" -ForegroundColor Yellow }

if (-not $Silent -and -not $Yes) {
    Write-Host "Будет удалено:" -ForegroundColor Yellow
    Write-Host "  - Программа: $INSTALL_DIR"
    Write-Host "  - FCC (Free Claude Code) и его данные"
    Write-Host "  - Записи в реестре (Add/Remove Programs)"
    Write-Host "  - Запись в системном PATH"
    Write-Host ""
    $ans = Read-Host "Продолжить? (y/N)"
    if ($ans -notmatch '^(y|yes|д|да)$') { Write-Host "Отменено."; exit 0 }
}

try {
    # 1. Удаляем FCC
    Step "Удаление FCC (Free Claude Code)"
    $fccPaths = @(
        (Join-Path $env:USERPROFILE ".local\bin\fcc-server"),
        (Join-Path $env:USERPROFILE ".fcc")
    )
    foreach ($p in $fccPaths) {
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p).PSIsContainer) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
            Ok "Удалено: $p"
        }
    }
    # Пробуем через uv
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        & uv tool uninstall free-claude-code 2>&1 | Out-Null
        Ok "uv tool uninstall выполнен"
    }
    Ok "FCC удалён"

    # 2. Удаляем файлы программы
    Step "Удаление файлов программы"
    if (Test-Path -LiteralPath $INSTALL_DIR) {
        # Удаляем с повторными попытками
        for ($i = 1; $i -le 10; $i++) {
            try {
                Remove-Item -LiteralPath $INSTALL_DIR -Recurse -Force -ErrorAction Stop
                Ok "Папка удалена на попытке $i"
                break
            }
            catch {
                if ($i -eq 10) { throw }
                Start-Sleep -Seconds 1
            }
        }
    }
    Ok "Файлы программы удалены"

    # 3. Удаляем из реестра
    Step "Удаление записей реестра"
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$APP_NAME"
    if (Test-Path $regPath) {
        Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
        Ok "Запись реестра удалена"
    }
    Ok "Реестр очищен"

    # 4. Удаляем из PATH
    Step "Очистка системного PATH"
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    if ($currentPath) {
        $parts = $currentPath -split ';' | Where-Object { $_ -and $_ -ne $INSTALL_DIR }
        $newPath = $parts -join ';'
        if ($newPath -ne $currentPath) {
            [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
            Ok "PATH обновлён"
        }
    }
    Ok "PATH очищен"

    Write-Host "`n=== УДАЛЕНИЕ ЗАВЕРШЕНО УСПЕШНО ===" -ForegroundColor Green
    Write-Host "fcc-auto-claude и FCC полностью удалены из системы." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`nОШИБКА УДАЛЕНИЯ: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Попробуйте запустить от имени администратора." -ForegroundColor Yellow
    exit 1
}