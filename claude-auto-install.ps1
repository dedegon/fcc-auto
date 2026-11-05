<#
.SYNOPSIS
    claude-auto installer logic called by Inno Setup.
.DESCRIPTION
    Installs claude-auto and optionally FCC (free-claude-code) via uv.
    Writes installation manifest to track state for rollback/uninstall.
    Uses dedicated uv tool environment for isolation.
.PARAMETER InstallDir
    Target directory for program files. Default: %LOCALAPPDATA%\claude-auto\app
.PARAMETER DataDir
    Directory for manifest and logs. Default: %LOCALAPPDATA%\claude-auto
.PARAMETER InstallFcc
    Switch: install FCC if not already present.
.PARAMETER Silent
    Switch: suppress console output, only write to log file.
.PARAMETER ManifestPath
    Path to installation manifest JSON. Default: $DataDir\install.json
.PARAMETER FccVersionFile
    Path to fcc.version file (x.y.z format). Default: fcc.version next to script.
.PARAMETER SourceDir
    Source directory with program files. Default: script directory.
.PARAMETER LogPath
    Path to log file. Default: $DataDir\install.log
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\claude-auto\app",
    [string]$DataDir = "$env:LOCALAPPDATA\claude-auto",
    [switch]$InstallFcc,
    [switch]$Silent,
    [string]$ManifestPath,
    [string]$FccVersionFile,
    [string]$SourceDir,
    [string]$LogPath
)

# Initialize paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $FccVersionFile) { $FccVersionFile = Join-Path $scriptDir "fcc.version" }
if (-not $SourceDir) { $SourceDir = $scriptDir }
# Ensure DataDir exists for logging and manifest
if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}
if (-not $LogPath) { $LogPath = Join-Path $DataDir "install.log" }
# Default ManifestPath to DataDir\install.json if not provided
if (-not $ManifestPath) { $ManifestPath = Join-Path $DataDir "install.json" }

# Dedicated uv tool environment for isolation
$UvToolDir = Join-Path $DataDir "uv-tools"
$UvToolBinDir = Join-Path $DataDir "uv-tools\bin"
$env:UV_TOOL_DIR = $UvToolDir
$env:UV_TOOL_BIN_DIR = $UvToolBinDir

# State tracking for rollback
$script:fccPreexisting = $false
$script:fccInstalledByUs = $false
$script:fccInstalledThisRun = $false
$script:installDirCreated = $false
$script:claudeAutoInstalled = $false
$script:claudeAutoInstalledThisRun = $false
$script:claudeAutoPreexisting = $false
$script:claudeAutoUpgradeFromOurPrevious = $false
$script:fccUpgradeFromOurPrevious = $false
$script:filesBackedUp = @{}

# Logging functions
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    $line | Out-File -FilePath $LogPath -Encoding UTF8 -Append
    if (-not $Silent) { Write-Host $line }
}

function Write-ErrorLog {
    param([string]$Message)
    Write-Log $Message "ERROR"
}

function Get-ProjectVersion {
    param([string]$InstallDir)
    $pyproject = Join-Path $InstallDir 'pyproject.toml'
    if (Test-Path -LiteralPath $pyproject) {
        $content = Get-Content -LiteralPath $pyproject -Raw
        if ($content -match 'version\s*=\s*"([^"]+)"') { return $matches[1] }
    }
    return '0.0.0'
}

# JSON helper for manifest (simple, no dependencies)
function Write-Manifest {
    param(
        [string]$Status,
        [string]$FccVersion = $null,
        [string]$ManifestPathOverride = $null
    )
    $path = if ($ManifestPathOverride) { $ManifestPathOverride } else { $ManifestPath }
    try {
        $version = Get-ProjectVersion -InstallDir $InstallDir
        $manifest = @{
            repo_path                      = $InstallDir
            install_dir                    = $InstallDir
            data_dir                       = $DataDir
            uv_tool_dir                    = $UvToolDir
            uv_tool_bin_dir                = $UvToolBinDir
            status                         = $Status
            updated                        = (Get-Date).ToString("o")
            fcc_preexisting                = $script:fccPreexisting
            fcc_installed_by_us            = $script:fccInstalledByUs
            fcc_upgrade_from_our_previous  = $script:fccUpgradeFromOurPrevious
            claude_auto_preexisting        = $script:claudeAutoPreexisting
            claude_auto_installed_by_us    = $script:claudeAutoInstalled
            claude_auto_upgrade_from_our_previous = $script:claudeAutoUpgradeFromOurPrevious
            version                        = $version
        }
        if (($script:fccInstalledByUs -or $script:fccPreexisting) -and $FccVersion) { $manifest.fcc_version = $FccVersion }
        $json = $manifest | ConvertTo-Json -Depth 5
        $json | Out-File -FilePath $path -Encoding UTF8
        Write-Log "Manifest written: $Status"
    }
    catch {
        Write-ErrorLog "Failed to write manifest: $($_.Exception.Message)"
    }
}

function Read-FccVersion {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ErrorLog "FCC version file not found: $Path"
        return $null
    }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $version = $content.Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        Write-ErrorLog ("Invalid FCC version format in {0}: '{1}' (expected x.y.z)" -f $Path, $version)
        return $null
    }
    return $version
}

function Detect-Fcc {
    # Check 1: file in %USERPROFILE%\.local\bin
    $fccExe = Join-Path $env:USERPROFILE ".local\bin\fcc-server.exe"
    if (Test-Path -LiteralPath $fccExe) {
        $version = &(Get-Command -Name "cmd.exe" -CommandType Application) /c "$fccExe --version" 2>$null
        if ($version) {
            Write-Log "FCC detected via file: $fccExe (version: $version)"
            return @{ State = "Installed"; Version = $version.Trim() }
        }
    }

    # Check 2: Get-Command fcc-server
    try {
        $cmd = Get-Command "fcc-server" -ErrorAction SilentlyContinue
        if ($cmd) {
            $version = & "fcc-server.exe" --version 2>$null
            if ($version) {
                Write-Log "FCC detected via Get-Command (version: $version)"
                return @{ State = "Installed"; Version = $version.Trim() }
            }
        }
    } catch { }

    # Check 3: uv tool list (in dedicated environment)
    try {
        $output = & "uv" tool list 2>$null
        if ($output -and $output -match "free-claude-code") {
            $match = [regex]::Match($output, "free-claude-code\s+(\S+)")
            if ($match.Success) {
                $version = $match.Groups[1].Value
                Write-Log "FCC detected via uv tool list (version: $version)"
                return @{ State = "Installed"; Version = $version }
            }
        }
    } catch { }

    Write-Log "FCC not detected"
    return @{ State = "NotInstalled"; Version = $null }
}

function Detect-ClaudeAuto {
    # Check if claude-auto is already installed in OUR dedicated uv tool environment
    $claudeExe = Join-Path $UvToolBinDir "claude-auto.exe"
    if (Test-Path -LiteralPath $claudeExe) {
        # Check uv tool list for version (don't run claude-auto.exe --version)
        try {
            $output = & "uv" tool list 2>$null
            if ($output -and $output -match "claude-auto") {
                $match = [regex]::Match($output, "claude-auto\s+(\S+)")
                if ($match.Success) {
                    $version = $match.Groups[1].Value
                    Write-Log "Pre-existing claude-auto detected via uv tool list (version: $version)"
                    return @{ State = "Installed"; Version = $version }
                }
            }
        } catch { }
        Write-Log "Pre-existing claude-auto detected in our uv tool dir (version unknown)"
        return @{ State = "Installed"; Version = "unknown" }
    }

    # Also check uv tool list in our dedicated environment
    try {
        $output = & "uv" tool list 2>$null
        if ($output -and $output -match "claude-auto") {
            $match = [regex]::Match($output, "claude-auto\s+(\S+)")
            if ($match.Success) {
                $version = $match.Groups[1].Value
                Write-Log "Pre-existing claude-auto detected via uv tool list (version: $version)"
                return @{ State = "Installed"; Version = $version }
            }
        }
    } catch { }

    Write-Log "claude-auto not detected in our uv tool environment"
    return @{ State = "NotInstalled"; Version = $null }
}
function Find-Python {
    # 1) Check CLAUDE_AUTO_PYTHON env var
    if ($env:CLAUDE_AUTO_PYTHON -and (Test-Path -LiteralPath $env:CLAUDE_AUTO_PYTHON)) {
        $pyPath = $env:CLAUDE_AUTO_PYTHON
        $version = & $pyPath --version 2>$null
        if ($version -and $version -match 'Python (\d+)\.(\d+)') {
            $major = [int]$matches[1]
            $minor = [int]$matches[2]
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 11)) {
                Write-Log "Found Python $version via CLAUDE_AUTO_PYTHON: $pyPath"
                return $pyPath
            }
        }
    }

    # 2) Try Get-Command python (Source)
    try {
        $cmd = Get-Command "python" -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            $pyPath = $cmd.Source
            $version = & $pyPath --version 2>$null
            if ($version -and $version -match 'Python (\d+)\.(\d+)') {
                $major = [int]$matches[1]
                $minor = [int]$matches[2]
                if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 11)) {
                    Write-Log "Found Python $version via Get-Command: $pyPath"
                    return $pyPath
                }
            }
        }
    } catch { }

    # 3) Common install locations: %LOCALAPPDATA%\Programs\Python\Python3*\python.exe и %LOCALAPPDATA%\Python\bin\python.exe
    $candidates = @()
    $programsRoot = Join-Path $env:LOCALAPPDATA "Programs\Python"
    if (Test-Path -LiteralPath $programsRoot) {
        $candidates += Get-ChildItem -Path $programsRoot -Directory -Filter "Python3*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "python.exe" }
    }
    $candidates += Join-Path $env:LOCALAPPDATA "Python\bin\python.exe"
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $verText = & $candidate --version 2>$null
        if ($verText -match 'Python (\d+)\.(\d+)') {
            $pyMajor = [int]$Matches[1]
            $pyMinor = [int]$Matches[2]
            if ($pyMajor -gt 3 -or ($pyMajor -eq 3 -and $pyMinor -ge 11)) {
                Write-Log "Found Python $verText via common path: $candidate"
                return $candidate
            }
        }
    }

    Write-Log "Python 3.11+ not found"
    return $null
}

function Ensure-Uv {
    $ProgressPreference = 'SilentlyContinue'
    if (Get-Command "uv" -ErrorAction SilentlyContinue) {
        Write-Log "uv already available"
        return $true
    }
    Write-Log "Installing uv (pinned version) from GitHub release"
    try {
        $uvVersionFile = Join-Path $scriptDir "uv.version"
        $uvShaFile     = Join-Path $scriptDir "uv.sha256"
        if (-not (Test-Path $uvVersionFile)) { Write-ErrorLog "uv.version not found: $uvVersionFile"; return $false }
        if (-not (Test-Path $uvShaFile))     { Write-ErrorLog "uv.sha256 not found: $uvShaFile";     return $false }
        $uvVersion = (Get-Content $uvVersionFile -Raw).Trim()
        $uvSha     = (Get-Content $uvShaFile     -Raw).Trim()
        if (-not $uvVersion -or -not $uvSha) {
            Write-ErrorLog "uv.version or uv.sha256 is empty"
            return $false
        }
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
        $zipUrl  = "https://github.com/astral-sh/uv/releases/download/$uvVersion/uv-$arch-pc-windows-msvc.zip"
        $zipPath = Join-Path $env:TEMP "uv-$uvVersion-$arch.zip"
        Write-Log "Downloading uv $uvVersion ($arch): $zipUrl"
        Write-Log "Downloading zip (timeout 120 s): $zipUrl"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
        Write-Log ("Downloaded zip: {0} bytes" -f (Get-Item $zipPath).Length)
        $actual   = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToUpper()
        $expected = $uvSha.ToUpper()
        if ($actual -ne $expected) {
            Write-ErrorLog "uv SHA256 mismatch: expected $expected, got $actual"
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        $localBin = Join-Path $env:USERPROFILE ".local\bin"
        if (-not (Test-Path $localBin)) { New-Item -ItemType Directory -Path $localBin -Force | Out-Null }
        Expand-Archive -Path $zipPath -DestinationPath $localBin -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        $env:PATH = "$localBin;$env:PATH"
        if (Get-Command "uv" -ErrorAction SilentlyContinue) {
            Write-Log "uv installed successfully (pinned $uvVersion, SHA256 verified)"
            return $true
        }
        Write-ErrorLog "uv installed but not found in PATH"
        return $false
    }
    catch {
        Write-ErrorLog "Exception during uv install: $($_.Exception.Message)"
        return $false
    }
}

function Install-Fcc {
    param([string]$Version)
    Write-Log "Installing FCC version $Version via uv (tool dir: $UvToolDir)"

    $pyPath = $null

    # a) Check CLAUDE_AUTO_PYTHON env var
    if ($env:CLAUDE_AUTO_PYTHON -and (Test-Path -LiteralPath $env:CLAUDE_AUTO_PYTHON)) {
        $pyPath = $env:CLAUDE_AUTO_PYTHON
        Write-Log "Using Python from CLAUDE_AUTO_PYTHON: $pyPath"
    }
    else {
        # b) Try uv python find 3.14.10
        $found = & "uv" python find 3.14.10 2>$null
        if ($LASTEXITCODE -eq 0 -and $found -and (Test-Path -LiteralPath $found.Trim())) {
            $pyPath = $found.Trim()
            Write-Log "Found existing Python 3.14.10 via uv python find: $pyPath"
        }
    }

    if (-not $pyPath) {
        Write-Log "Python 3.14.10 not found; FCC skipped (install claude-auto only)"
        $script:fccInstalledByUs = $false
        return $true
    }

    # c) Install FCC using found Python
    try {
        $output = & "uv" tool install --python $pyPath "free-claude-code==$Version" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorLog "FCC installation failed: $output"
            return $false
        }
        $script:fccInstalledByUs = $true
        $script:fccInstalledThisRun = $true
        Write-Log "FCC installed successfully"
        return $true
    }
    catch {
        Write-ErrorLog "Exception during FCC install: $($_.Exception.Message)"
        return $false
    }
}

function Backup-ExistingFile {
    param([string]$FilePath)
    if (Test-Path -LiteralPath $FilePath) {
        $backupPath = "$FilePath.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item -LiteralPath $FilePath -Destination $backupPath -Force
        $script:filesBackedUp[$FilePath] = $backupPath
        Write-Log "Backed up existing file: $FilePath -> $backupPath"
        return $true
    }
    return $false
}

function Copy-ProgramFiles {
    Write-Log "Copying program files from $SourceDir to $InstallDir"
    try {
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            $script:installDirCreated = $true
            Write-Log "Created InstallDir: $InstallDir"
        }

        $files = @(
            "claude_auto.py",
            "claude_filter.py",
            "scanner.py",
            "scanner_config.py",
            "pyproject.toml",
            "README.md"
        )

        foreach ($file in $files) {
            $src = Join-Path $SourceDir $file
            $dst = Join-Path $InstallDir $file
            if (Test-Path -LiteralPath $src) {
                # Backup existing file before overwriting
                Backup-ExistingFile -FilePath $dst
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Write-Log "Copied: $file"
            }
            else {
                Write-Log "Source file not found (skipped): $file" "WARN"
            }
        }

        $modelLimitsSrc = Join-Path $SourceDir "model_limits"
        $modelLimitsDst = Join-Path $InstallDir "model_limits"
        if (Test-Path -LiteralPath $modelLimitsSrc) {
            # Backup existing model_limits directory
            if (Test-Path -LiteralPath $modelLimitsDst) {
                $backupPath = "$modelLimitsDst.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
                Copy-Item -LiteralPath $modelLimitsDst -Destination $backupPath -Recurse -Force
                $script:filesBackedUp[$modelLimitsDst] = $backupPath
                Write-Log "Backed up existing model_limits directory"
            }
            Copy-Item -LiteralPath $modelLimitsSrc -Destination $modelLimitsDst -Recurse -Force
            Write-Log "Copied model_limits directory"
        }

        return $true
    }
    catch {
        Write-ErrorLog "Failed to copy program files: $($_.Exception.Message)"
        return $false
    }
}

function Restore-BackedUpFiles {
    Write-Log "Restoring backed up files"
    foreach ($original in $script:filesBackedUp.Keys) {
        $backup = $script:filesBackedUp[$original]
        if (Test-Path -LiteralPath $backup) {
            try {
                if (Test-Path -LiteralPath $original) {
                    Remove-Item -LiteralPath $original -Recurse -Force -ErrorAction Stop
                }
                Copy-Item -LiteralPath $backup -Destination $original -Recurse -Force
                Remove-Item -LiteralPath $backup -Force
                Write-Log "Restored: $original"
            }
            catch {
                Write-ErrorLog ("Failed to restore {0} from {1}: {2}" -f $original, $backup, $_.Exception.Message)
            }
        }
    }
}

function Install-ClaudeAuto {
    Write-Log "Installing claude-auto from $InstallDir via uv (tool dir: $UvToolDir) using Python: $script:pyPath"
    try {
        $output = & "uv" tool install --python $script:pyPath --force $InstallDir 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorLog "claude-auto installation failed: $output"
            return $false
        }
        $script:claudeAutoInstalled = $true
        $script:claudeAutoInstalledThisRun = $true
        Write-Log "claude-auto installed successfully"
        return $true
    }
    catch {
        Write-ErrorLog "Exception during claude-auto install: $($_.Exception.Message)"
        return $false
    }
}

function Verify-Installation {
    Write-Log "Verifying installation"
    try {
        $claudeExe = Join-Path $UvToolBinDir "claude-auto.exe"
        if (-not (Test-Path -LiteralPath $claudeExe)) {
            Write-ErrorLog "claude-auto.exe not found: $claudeExe"
            return $false
        }
        $output = & $claudeExe --help 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorLog "claude-auto --help failed: $output"
            return $false
        }
        Write-Log "claude-auto --help OK"

        if ($script:fccPreexisting -or $script:fccInstalledByUs) {
            $output = & "fcc-server.exe" --version 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "fcc-server --version check failed (non-fatal): $output" "WARN"
            }
            else {
                Write-Log "fcc-server --version OK: $output"
            }
        }

        return $true
    }
    catch {
        Write-ErrorLog "Exception during verification: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Rollback {
    Write-Log "Starting rollback"
    Write-Manifest -Status "failed"

    # Uninstall claude-auto ONLY if we installed it in THIS run
    if ($script:claudeAutoInstalledThisRun) {
        try {
            $output = & "uv" tool uninstall "claude-auto" 2>&1
            $result = if ($LASTEXITCODE -eq 0) { "OK" } else { "Failed: " + $output }
            Write-Log ("Rollback: uv tool uninstall claude-auto - {0}" -f $result)
        }
        catch {
            Write-ErrorLog "Rollback error uninstalling claude-auto: $($_.Exception.Message)"
        }
    }
    elseif ($script:claudeAutoPreexisting) {
        Write-Log "Rollback: preserving pre-existing claude-auto installation"
    }
    elseif ($script:claudeAutoUpgradeFromOurPrevious) {
        Write-Log "Rollback: preserving our previous claude-auto installation (upgrade failed)"
    }

    # Uninstall FCC ONLY if we installed it in THIS run
    if ($script:fccInstalledThisRun) {
        try {
            $output = & "uv" tool uninstall "free-claude-code" 2>&1
            $result = if ($LASTEXITCODE -eq 0) { "OK" } else { "Failed: " + $output }
            Write-Log ("Rollback: uv tool uninstall free-claude-code - {0}" -f $result)
        }
        catch {
            Write-ErrorLog "Rollback error uninstalling FCC: $($_.Exception.Message)"
        }
    }
    elseif ($script:fccPreexisting) {
        Write-Log "Rollback: preserving pre-existing FCC installation"
    }
    elseif ($script:fccUpgradeFromOurPrevious) {
        Write-Log "Rollback: preserving our previous FCC installation (upgrade failed)"
    }

    # Remove InstallDir if we created it
    if ($script:installDirCreated -and (Test-Path -LiteralPath $InstallDir)) {
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
            Write-Log "Rollback: removed InstallDir"
        }
        catch {
            Write-ErrorLog "Rollback error removing InstallDir: $($_.Exception.Message)"
        }
    }
    else {
        # Restore backed up files if we didn't create the directory
        Restore-BackedUpFiles
    }

    Write-Log "Rollback completed"
}

function Add-UvBinToUserPath {
    param([string]$BinDir)

    if (-not (Test-Path -LiteralPath $BinDir)) {
        throw "BinDir does not exist: $BinDir"
    }
    $exePath = Join-Path $BinDir "claude-auto.exe"
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "claude-auto.exe not found in BinDir: $BinDir"
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }

    $paths = $userPath -split ';' | Where-Object { $_ -ne '' }
    $normalizedBinDir = $BinDir.TrimEnd('\')
    $found = $paths | Where-Object { $_.TrimEnd('\') -eq $normalizedBinDir }

    if ($found) {
        Write-Log "PATH already contains uv tool bin dir: $BinDir"
    }
    else {
        $newPath = if ($userPath -and $userPath -notmatch ';$') { $userPath + ';' + $BinDir } elseif ($userPath) { $userPath + $BinDir } else { $BinDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Log "Added uv tool bin dir to user PATH: $BinDir"
    }

    # Update current process PATH
    $env:Path = $env:Path + ";" + $BinDir
}

# ========== MAIN ==========
function Main {
    try {
        # Step -1: Find Python 3.11+ BEFORE any logging or file operations
        $script:pyPath = Find-Python
        if (-not $script:pyPath) {
            Write-ErrorLog "Python 3.11+ not found. Install Python 3.11+ from python.org and run setup again."
            # Clean up files copied by Inno Setup
            if (Test-Path -LiteralPath $InstallDir) {
                try {
                    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
                    Write-Log "Cleaned up InstallDir after Python check failure"
                } catch {
                    Write-ErrorLog "Failed to clean up InstallDir: $($_.Exception.Message)"
                }
            }
            # Write manifest with error field directly
            $version = Get-ProjectVersion -InstallDir $InstallDir
            $manifest = @{
                repo_path                      = $InstallDir
                install_dir                    = $InstallDir
                data_dir                       = $DataDir
                uv_tool_dir                    = $UvToolDir
                uv_tool_bin_dir                = $UvToolBinDir
                status                         = "failed"
                updated                        = (Get-Date).ToString("o")
                fcc_preexisting                = $false
                fcc_installed_by_us            = $false
                fcc_upgrade_from_our_previous  = $false
                claude_auto_preexisting        = $false
                claude_auto_installed_by_us    = $false
                claude_auto_upgrade_from_our_previous = $false
                version                        = $version
                error                          = "python_not_found"
            }
            $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8
            Write-Log "Manifest written: failed (python_not_found)"
            exit 1
        }

        Write-Log "=== claude-auto installation started ==="
        Write-Log "InstallDir: $InstallDir"
        Write-Log "DataDir: $DataDir"
        Write-Log "UvToolDir: $UvToolDir"
        Write-Log "InstallFcc: $InstallFcc"
        Write-Log "Silent: $Silent"
        Write-Log "Using Python: $script:pyPath"

        # Step 0: Read existing manifest to detect upgrade from our previous install
        $existingManifest = $null
        if (Test-Path -LiteralPath $ManifestPath) {
            try {
                $json = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
                $existingManifest = $json | ConvertFrom-Json
                Write-Log "Existing manifest found (status: $($existingManifest.status), version: $($existingManifest.version))"
            }
            catch {
                Write-Log "Existing manifest found but failed to parse: $($_.Exception.Message)" "WARN"
            }
        }

        # Determine if this is an upgrade of OUR previous installation
        $isUpgradeFromOurInstall = $false
        if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.claude_auto_installed_by_us -eq $true) {
            $isUpgradeFromOurInstall = $true
            $script:claudeAutoUpgradeFromOurPrevious = $true
            Write-Log "Detected upgrade from our previous installation (version: $($existingManifest.version))"
        }

        # Determine if FCC was installed by us in previous run
        $fccWasInstalledByUs = $false
        if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.fcc_installed_by_us -eq $true) {
            $fccWasInstalledByUs = $true
            $script:fccUpgradeFromOurPrevious = $true
            Write-Log "FCC was installed by us in previous run"
        }

        # Step 1: Read FCC version
        $fccVersion = Read-FccVersion -Path $FccVersionFile
        if (-not $fccVersion) {
            Write-ErrorLog "Exiting due to version error (no changes made)"
            exit 1
        }
        Write-Log "FCC version: $fccVersion"

        # Step 2: Write manifest in_progress (with upgrade flags)
        Write-Manifest -Status "in_progress" -FccVersion $fccVersion

        # Step 3: Detect FCC
        $fccResult = Detect-Fcc
        $fccDetected = ($fccResult.State -eq "Installed")

        # If upgrade from our previous install and we installed FCC before, it's NOT foreign pre-existing
        if ($fccDetected -and $script:fccUpgradeFromOurPrevious) {
            $script:fccPreexisting = $false
            # fccInstalledByUs stays false until this run installs it
            Write-Log "FCC detected - upgrade from our previous installation (version: $($fccResult.Version))"
        }
        elseif ($fccDetected) {
            $script:fccPreexisting = $true
            $script:fccInstalledByUs = $false
            Write-Log "FCC pre-existing (version: $($fccResult.Version)), skipping install"
        }
        else {
            Write-Log "FCC not found"
        }
        Write-Manifest -Status "in_progress" -FccVersion $fccVersion  # Update fcc_preexisting, fcc_installed_by_us

        # Step 3b: Detect pre-existing claude-auto
        $claudeAutoResult = Detect-ClaudeAuto
        $claudeAutoDetected = ($claudeAutoResult.State -eq "Installed")

        # If upgrade from our previous install, it's NOT foreign pre-existing
        if ($claudeAutoDetected -and $script:claudeAutoUpgradeFromOurPrevious) {
            $script:claudeAutoPreexisting = $false
            # claudeAutoInstalled stays false until this run installs it
            Write-Log "claude-auto detected - upgrade from our previous installation (version: $($claudeAutoResult.Version))"
        }
        elseif ($claudeAutoDetected) {
            $script:claudeAutoPreexisting = $true
            $script:claudeAutoInstalled = $false
            Write-Log "Pre-existing claude-auto detected (version: $($claudeAutoResult.Version)), will preserve"
        }
        else {
            Write-Log "No pre-existing claude-auto found"
        }
        Write-Manifest -Status "in_progress" -FccVersion $fccVersion  # Update claude_auto_preexisting, claude_auto_installed_by_us

        # Step 4: Ensure uv
        if (-not (Ensure-Uv)) {
            Write-ErrorLog "uv not available, rolling back"
            Invoke-Rollback
            exit 1
        }

        # Step 5: Install FCC if needed
        if (-not $script:fccPreexisting -and $InstallFcc) {
            if (-not (Install-Fcc -Version $fccVersion)) {
                Write-ErrorLog "FCC installation failed, rolling back"
                Invoke-Rollback
                exit 1
            }
            Write-Manifest -Status "in_progress" -FccVersion $fccVersion  # Update fcc_installed_by_us
        }
        elseif ($script:fccPreexisting -and $InstallFcc) {
            Write-Log "FCC already installed, -InstallFcc ignored"
        }

        # Step 6: Copy program files
        if (-not (Copy-ProgramFiles)) {
            Write-ErrorLog "File copy failed, rolling back"
            Invoke-Rollback
            exit 1
        }

        # Step 7: Install claude-auto (only if not pre-existing)
        if (-not $script:claudeAutoPreexisting) {
            if (-not (Install-ClaudeAuto)) {
                Write-ErrorLog "claude-auto installation failed, rolling back"
                Invoke-Rollback
                exit 1
            }
        }
        else {
            Write-Log "Skipping claude-auto installation (pre-existing)"
        }

        # Step 8: Verify
        if (-not (Verify-Installation)) {
            Write-ErrorLog "Verification failed, rolling back"
            Invoke-Rollback
            exit 1
        }

        # Step 9: Add uv tool bin dir to user PATH
        Add-UvBinToUserPath -BinDir $UvToolBinDir

        # Step 10: Final manifest
        Write-Manifest -Status "installed" -FccVersion $fccVersion
        Write-Log "=== Installation completed successfully ==="
        exit 0
    }
    catch {
        Write-ErrorLog "Unexpected error: $($_.Exception.Message)"
        Invoke-Rollback
        exit 1
    }
}

# Only run Main when executed directly, not when dot-sourced for testing
# InvocationName is '.' when dot-sourced, script path or '&' when run directly
if ($MyInvocation.InvocationName -ne '.') {
    Main
}
