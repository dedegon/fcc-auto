# build_new.ps1 - Build install.exe with embedded uninstall.exe
# Version read from pyproject.toml
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }

# Read version from pyproject.toml
$pyproject = Join-Path $here "pyproject.toml"
if (-not (Test-Path -LiteralPath $pyproject)) { throw "pyproject.toml not found: $pyproject" }
$tomlContent = Get-Content -LiteralPath $pyproject -Raw
$versionMatch = [regex]::Match($tomlContent, 'version\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) { throw "Version not found in pyproject.toml" }
$VERSION = $versionMatch.Groups[1].Value
Write-Host "Version from pyproject.toml: $VERSION" -ForegroundColor Cyan

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $csc)) { throw "csc.exe not found (.NET Framework 4.x)" }

$uninstallerSrc = Join-Path $here "uninstaller_new.cs"
$launcherSrc    = Join-Path $here "launcher_new.cs"
$uninstallerExe = Join-Path $here "uninstall.exe"
$launcherExe    = Join-Path $here "install.exe"
$manifestFile   = Join-Path $here "app.manifest"
$distDir        = Join-Path $here "dist"
$standaloneExe  = Join-Path $distDir "install-claude-auto-V$VERSION.exe"

# Create dist directory
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }

if (-not (Test-Path $uninstallerSrc)) { throw "uninstaller_new.cs not found: $uninstallerSrc" }
if (-not (Test-Path $launcherSrc))    { throw "launcher_new.cs not found: $launcherSrc" }
if (-not (Test-Path $manifestFile))   { throw "app.manifest not found: $manifestFile" }

# 0. Remove old exe if exists
if (Test-Path $uninstallerExe) {
    try { Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction Stop }
    catch {
        throw "Failed to remove old uninstall.exe (maybe running): $($_.Exception.Message)"
    }
}
if (Test-Path $launcherExe) {
    try { Remove-Item -LiteralPath $launcherExe -Force -ErrorAction Stop }
    catch {
        throw "Failed to remove old install.exe (maybe running): $($_.Exception.Message)"
    }
}

# 1. Compile uninstall.exe (standalone)
Write-Host "Compiling uninstall.exe..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$uninstallerExe" `
    /reference:System.dll `
    /reference:System.Core.dll `
    $uninstallerSrc
if ($LASTEXITCODE -ne 0) { throw "Compilation of uninstaller_new.cs failed" }
Write-Host "Built: $uninstallerExe" -ForegroundColor DarkYellow

# 2. Compile install.exe with embedded uninstall.exe as resource
Write-Host "Compiling install.exe with embedded uninstall.exe..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$launcherExe" `
    "/resource:$uninstallerExe,Uninstaller.exe" `
    "/win32manifest:$manifestFile" `
    /reference:System.dll `
    /reference:System.Core.dll `
    /reference:System.Net.Http.dll `
    $launcherSrc
$launcherOk = ($LASTEXITCODE -eq 0)

# 3. Remove standalone uninstall.exe (it's inside install.exe)
Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction SilentlyContinue

if (-not $launcherOk) { throw "Compilation of launcher_new.cs failed" }

Write-Host "Built: $launcherExe (uninstall.exe embedded as resource, UAC manifest)" -ForegroundColor Green

# 4. Create standalone version (copy with version in name) in dist/
Copy-Item -LiteralPath $launcherExe -Destination $standaloneExe -Force
Write-Host "Created standalone installer: $standaloneExe" -ForegroundColor Green

Write-Host "`n=== BUILD COMPLETE ===" -ForegroundColor Green
Write-Host "Files for distribution:" -ForegroundColor Cyan
Write-Host "  - $standaloneExe  (standalone installer for users)" -ForegroundColor White
Write-Host "  - $launcherExe    (for development, requires sources nearby)" -ForegroundColor White
Write-Host "`nInstallation:" -ForegroundColor Cyan
Write-Host "  1. Run $standaloneExe as administrator" -ForegroundColor White
Write-Host "  2. Program installs to C:\Program Files (x86)\claude-auto" -ForegroundColor White
Write-Host '  3. Uninstall: via "Add/Remove Programs" or uninstall.exe' -ForegroundColor White
Write-Host '  4. For uninstall with FCC: uninstall.exe --purge-fcc' -ForegroundColor White