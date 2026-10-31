# build_new.ps1 - Сборка нового install.exe с внедрённым uninstall.exe
# Версия: 1.0.2
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) { throw "Не найден csc.exe (.NET Framework 4.x)" }

$uninstallerSrc = Join-Path $here "uninstaller_new.cs"
$launcherSrc    = Join-Path $here "launcher_new.cs"
$uninstallerExe = Join-Path $here "uninstall.exe"
$launcherExe    = Join-Path $here "install.exe"
$manifestFile   = Join-Path $here "app.manifest"
$buildDir       = Join-Path $here "build"
$standaloneExe  = Join-Path $buildDir "install-claude-auto-V1.0.2.exe"

# Создаём папку build
if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir | Out-Null }

if (-not (Test-Path $uninstallerSrc)) { throw "Не найден uninstaller_new.cs: $uninstallerSrc" }
if (-not (Test-Path $launcherSrc))    { throw "Не найден launcher_new.cs: $launcherSrc" }
if (-not (Test-Path $manifestFile))   { throw "Не найден app.manifest: $manifestFile" }

# 0. Удаляем старые exe если есть
if (Test-Path $uninstallerExe) {
    try { Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction Stop }
    catch {
        throw "Не удалось удалить старый uninstall.exe (возможно, он запущен): $($_.Exception.Message)"
    }
}
if (Test-Path $launcherExe) {
    try { Remove-Item -LiteralPath $launcherExe -Force -ErrorAction Stop }
    catch {
        throw "Не удалось удалить старый install.exe (возможно, он запущен): $($_.Exception.Message)"
    }
}

# 1. Компилируем uninstall.exe (самостоятельный)
Write-Host "Компиляция uninstall.exe..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$uninstallerExe" `
    /reference:System.dll `
    /reference:System.Core.dll `
    $uninstallerSrc
if ($LASTEXITCODE -ne 0) { throw "Компиляция uninstaller_new.cs не удалась" }
Write-Host "Собрано: $uninstallerExe" -ForegroundColor DarkYellow

# 2. Компилируем install.exe с внедрённым uninstall.exe как ресурс
Write-Host "Компиляция install.exe с внедрённым uninstall.exe..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$launcherExe" `
    "/resource:$uninstallerExe,Uninstaller.exe" `
    "/win32manifest:$manifestFile" `
    /reference:System.dll `
    /reference:System.Core.dll `
    /reference:System.Net.Http.dll `
    $launcherSrc
$launcherOk = ($LASTEXITCODE -eq 0)

# 3. Удаляем standalone uninstall.exe (он внутри install.exe)
Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction SilentlyContinue

if (-not $launcherOk) { throw "Компиляция launcher_new.cs не удалась" }

Write-Host "Собрано: $launcherExe (uninstall.exe внедрён как ресурс, UAC манифест)" -ForegroundColor Green

# 4. Создаём standalone версию (копия с версией в имени)
Copy-Item -LiteralPath $launcherExe -Destination $standaloneExe -Force
Write-Host "Создан standalone установщик: $standaloneExe" -ForegroundColor Green

Write-Host "`n=== СБОРКА ЗАВЕРШЕНА ===" -ForegroundColor Green
Write-Host "Файлы для распространения:" -ForegroundColor Cyan
Write-Host "  - $standaloneExe  (standalone установщик для пользователей)" -ForegroundColor White
Write-Host "  - $launcherExe    (для разработки, требует исходников рядом)" -ForegroundColor White
Write-Host "`nУстановка:" -ForegroundColor Cyan
Write-Host "  1. Запустите install-claude-auto-V1.0.2.exe от имени администратора" -ForegroundColor White
Write-Host "  2. Программа установится в C:\Program Files (x86)\fcc-auto-claude" -ForegroundColor White
Write-Host '  3. Удаление: через "Добавление/удаление программ" или uninstall.exe' -ForegroundColor White