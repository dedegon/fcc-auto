# build_new.ps1 - РЎР±РѕСЂРєР° install.exe СЃ РІРЅРµРґСЂС‘РЅРЅС‹Рј uninstall.exe
# Р’РµСЂСЃРёСЏ С‡РёС‚Р°РµС‚СЃСЏ РёР· pyproject.toml
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }

# Р§РёС‚Р°РµРј РІРµСЂСЃРёСЋ РёР· pyproject.toml
$pyproject = Join-Path $here "pyproject.toml"
if (-not (Test-Path -LiteralPath $pyproject)) { throw "pyproject.toml РЅРµ РЅР°Р№РґРµРЅ: $pyproject" }
$tomlContent = Get-Content -LiteralPath $pyproject -Raw
$versionMatch = [regex]::Match($tomlContent, 'version\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) { throw "Р’РµСЂСЃРёСЏ РЅРµ РЅР°Р№РґРµРЅР° РІ pyproject.toml" }
$VERSION = $versionMatch.Groups[1].Value
Write-Host "Р’РµСЂСЃРёСЏ РёР· pyproject.toml: $VERSION" -ForegroundColor Cyan

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) { throw "csc.exe РЅРµ РЅР°Р№РґРµРЅ (.NET Framework 4.x)" }

$uninstallerSrc = Join-Path $here "uninstaller_new.cs"
$launcherSrc    = Join-Path $here "launcher_new.cs"
$uninstallerExe = Join-Path $here "uninstall.exe"
$launcherExe    = Join-Path $here "install.exe"
$manifestFile   = Join-Path $here "app.manifest"
$distDir        = Join-Path $here "dist"
$standaloneExe  = Join-Path $distDir "install-claude-auto-V$VERSION.exe"

# РЎРѕР·РґР°С‘Рј РїР°РїРєСѓ dist
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }

if (-not (Test-Path $uninstallerSrc)) { throw "uninstaller_new.cs РЅРµ РЅР°Р№РґРµРЅ: $uninstallerSrc" }
if (-not (Test-Path $launcherSrc))    { throw "launcher_new.cs РЅРµ РЅР°Р№РґРµРЅ: $launcherSrc" }
if (-not (Test-Path $manifestFile))   { throw "app.manifest РЅРµ РЅР°Р№РґРµРЅ: $manifestFile" }

# 0. РЈРґР°Р»СЏРµРј СЃС‚Р°СЂС‹Рµ exe РµСЃР»Рё РµСЃС‚СЊ
if (Test-Path $uninstallerExe) {
    try { Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction Stop }
    catch {
        throw "РќРµ СѓРґР°Р»РѕСЃСЊ СѓРґР°Р»РёС‚СЊ СЃС‚Р°СЂС‹Р№ uninstall.exe (РІРѕР·РјРѕР¶РЅРѕ, Р·Р°РїСѓС‰РµРЅ): $($_.Exception.Message)"
    }
}
if (Test-Path $launcherExe) {
    try { Remove-Item -LiteralPath $launcherExe -Force -ErrorAction Stop }
    catch {
        throw "РќРµ СѓРґР°Р»РѕСЃСЊ СѓРґР°Р»РёС‚СЊ СЃС‚Р°СЂС‹Р№ install.exe (РІРѕР·РјРѕР¶РЅРѕ, Р·Р°РїСѓС‰РµРЅ): $($_.Exception.Message)"
    }
}

# 1. РљРѕРјРїРёР»РёСЂСѓРµРј uninstall.exe (СЃР°РјРѕСЃС‚РѕСЏС‚РµР»СЊРЅС‹Р№)
Write-Host "РљРѕРјРїРёР»СЏС†РёСЏ uninstall.exe..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$uninstallerExe" `
    /reference:System.dll `
    /reference:System.Core.dll `
    $uninstallerSrc
if ($LASTEXITCODE -ne 0) { throw "РљРѕРјРїРёР»СЏС†РёСЏ uninstaller_new.cs РЅРµ СѓРґР°Р»Р°СЃСЊ" }
Write-Host "РЎРѕР±СЂР°РЅРѕ: $uninstallerExe" -ForegroundColor DarkYellow

# 2. РљРѕРјРїРёР»РёСЂСѓРµРј install.exe СЃ РІРЅРµРґСЂС‘РЅРЅС‹Рј uninstall.exe РєР°Рє СЂРµСЃСѓСЂСЃ
Write-Host "РљРѕРјРїРёР»СЏС†РёСЏ install.exe СЃ РІРЅРµРґСЂС‘РЅРЅС‹Рј uninstall.exe..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$launcherExe" `
    "/resource:$uninstallerExe,Uninstaller.exe" `
    "/win32manifest:$manifestFile" `
    /reference:System.dll `
    /reference:System.Core.dll `
    /reference:System.Net.Http.dll `
    $launcherSrc
$launcherOk = ($LASTEXITCODE -eq 0)

# 3. РЈРґР°Р»СЏРµРј standalone uninstall.exe (РѕРЅ РІРЅСѓС‚СЂРё install.exe)
Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction SilentlyContinue

if (-not $launcherOk) { throw "РљРѕРјРїРёР»СЏС†РёСЏ launcher_new.cs РЅРµ СѓРґР°Р»Р°СЃСЊ" }

Write-Host "РЎРѕР±СЂР°РЅРѕ: $launcherExe (uninstall.exe РІРЅРµРґСЂС‘РЅ РєР°Рє СЂРµСЃСѓСЂСЃ, UAC РјР°РЅРёС„РµСЃС‚)" -ForegroundColor Green

# 4. Standalone version (copy with versioned name)
Copy-Item -LiteralPath $launcherExe -Destination $standaloneExe -Force
Write-Host "РЎРѕР·РґР°РЅ standalone СѓСЃС‚Р°РЅРѕРІС‰РёРє: $standaloneExe" -ForegroundColor Green

Write-Host "`n=== РЎР‘РћР РљРђ Р—РђР’Р•Р РЁР•РќРђ ===" -ForegroundColor Green
Write-Host "Р¤Р°Р№Р»С‹ РґР»СЏ СЂР°СЃРїСЂРѕСЃС‚СЂР°РЅРµРЅРёСЏ:" -ForegroundColor Cyan
Write-Host "  - $standaloneExe  (standalone СѓСЃС‚Р°РЅРѕРІС‰РёРє РґР»СЏ РїРѕР»СЊР·РѕРІР°С‚РµР»РµР№)" -ForegroundColor White
Write-Host "  - $launcherExe    (РґР»СЏ СЂР°Р·СЂР°Р±РѕС‚РєРё, С‚СЂРµР±СѓРµС‚ РёСЃС…РѕРґРЅРёРєРѕРІ СЂСЏРґРѕРј)" -ForegroundColor White
Write-Host "`nРЈСЃС‚Р°РЅРѕРІРєР°:" -ForegroundColor Cyan
Write-Host "  1. Р—Р°РїСѓСЃС‚РёС‚Рµ $standaloneExe РѕС‚ РёРјРµРЅРё Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°" -ForegroundColor White
Write-Host "  2. РџСЂРѕРіСЂР°РјРјР° СѓСЃС‚Р°РЅРѕРІРёС‚СЃСЏ РІ C:\Program Files (x86)\claude-auto" -ForegroundColor White
Write-Host '  3. РЈРґР°Р»РµРЅРёРµ: С‡РµСЂРµР· "Р”РѕР±Р°РІР»РµРЅРёРµ/СѓРґР°Р»РµРЅРёРµ РїСЂРѕРіСЂР°РјРј" РёР»Рё uninstall.exe' -ForegroundColor White
Write-Host '  4. Р”Р»СЏ СѓРґР°Р»РµРЅРёСЏ СЃ FCC: uninstall.exe --purge-fcc' -ForegroundColor White
