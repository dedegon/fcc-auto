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

# JSON helper for manifest (simple, no dependencies)
function Get-ProjectVersion {
    param([string]$InstallDir)
    $pyproject = Join-Path $InstallDir "pyproject.toml"
    if (Test-Path -LiteralPath $pyproject) {
        $content = Get-Content -LiteralPath $pyproject -Raw
        if ($content -match 'version\s*=\s*"([^"]+)"') {
            return $matches[1]
        }
    }
    # Fallback to old behavior
    if ($script:manifest -and $script:manifest.version) { return $script:manifest.version }
    return "0.0.0"
}

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
        if ($FccVersion) { $manifest.fcc_version = $FccVersion }
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
        try {
            $version = & $claudeExe --version 2>$null
            if ($version) {
                Write-Log "Pre-existing claude-auto detected in our uv tool dir (version: $version)"
                return @{ State = "Installed"; Version = $version.Trim() }
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

function Find-SystemPython {
    <#
    .SYNOPSIS
        Finds a system Python 3.11+ that is NOT a uv-managed Python.
    .DESCRIPTION
        Searches for Python in known system locations, avoiding uv-managed
        Python installations (which can cause os error 448 on Windows 11 24H2+).
    .OUTPUTS
        System.String - Path to python.exe, or $null if not found.
    #>
    # 1. Check CLAUDE_AUTO_PYTHON env var (explicit override)
    if ($env:CLAUDE_AUTO_PYTHON -and (Test-Path -LiteralPath $env:CLAUDE_AUTO_PYTHON)) {
        $candidate = $env:CLAUDE_AUTO_PYTHON
        if (Test-PythonVersion -Path $candidate -MinVersion "3.11") {
            Write-Log "Find-SystemPython: using CLAUDE_AUTO_PYTHON: $candidate"
            return $candidate
        }
    }

    # 2. uv python list --only-installed, filter out managed Python paths
    try {
        $uvPythonOutput = & "uv" python list --only-installed 2>$null
        if ($LASTEXITCODE -eq 0 -and $uvPythonOutput) {
            $lines = $uvPythonOutput -split "`r?`n" | Where-Object { $_ -match '^\s*cpython-' }
            foreach ($line in $lines) {
                # Format: "cpython-3.11.9-windows-x86_64-none  C:\Users\...\uv\python\cpython-3.11.9-windows-x86_64-none\python.exe"
                $parts = $line -split '\s+'
                if ($parts.Count -ge 2) {
                    $path = $parts[-1].Trim()
                    # Skip uv-managed Python (contains \AppData\Roaming\uv\python\ or \.local\share\uv\python\)
                    if ($path -notmatch '\\AppData\\Roaming\\uv\\python\\' -and $path -notmatch '\\.local\\share\\uv\\python\\') {
                        if (Test-PythonVersion -Path $path -MinVersion "3.11") {
                            Write-Log "Find-SystemPython: found via uv python list (non-managed): $path"
                            return $path
                        }
                    }
                }
            }
        }
    } catch { }

    # 3. Known system Python paths
    $knownPaths = @(
        "$env:LOCALAPPDATA\Python\bin\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "C:\Python3*\python.exe"
    )

    foreach ($pattern in $knownPaths) {
        $matches = @()
        if ($pattern -match '\*') {
            $dir = Split-Path -Parent $pattern
            $file = Split-Path -Leaf $pattern
            if (Test-Path -LiteralPath $dir) {
                $matches = Get-ChildItem -Path $dir -Filter $file -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
            }
        } else {
            if (Test-Path -LiteralPath $pattern) {
                $matches = @($pattern)
            }
        }
        foreach ($path in $matches) {
            if (Test-PythonVersion -Path $path -MinVersion "3.11") {
                Write-Log "Find-SystemPython: found at known path: $path"
                return $path
            }
        }
    }

    # 4. Get-Command python (if in PATH)
    try {
        $pythonCmd = Get-Command "python" -ErrorAction SilentlyContinue
        if ($pythonCmd -and $pythonCmd.Source -eq "Application") {
            $path = $pythonCmd.Source
            if (Test-PythonVersion -Path $path -MinVersion "3.11") {
                Write-Log "Find-SystemPython: found via Get-Command: $path"
                return $path
            }
        }
    } catch { }

    Write-Log "Find-SystemPython: no system Python 3.11+ found"
    return $null
}

function Test-PythonVersion {
    param(
        [string]$Path,
        [string]$MinVersion
    )
    try {
        $output = & $Path --version 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return $false
        }
        # Output format: "Python 3.14.2" or "Python 3.11.9"
        if ($output -match 'Python\s+(\d+)\.(\d+)\.(\d+)') {
            $major = [int]$matches[1]
            $minor = [int]$matches[2]
            $patch = [int]$matches[3]
            $minParts = $MinVersion -split '\.'
            $minMajor = [int]$minParts[0]
            $minMinor = [int]$minParts[1]
            if ($major -gt $minMajor -or ($major -eq $minMajor -and $minor -ge $minMinor)) {
                return $true
            }
        }
        return $false
    } catch {
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
        # b) Try uv python find 3.14.10 (FCC requires 3.14.10)
        $found = & "uv" python find 3.14.10 2>$null
        if ($LASTEXITCODE -eq 0 -and $found -and (Test-Path -LiteralPath $found.Trim())) {
            $pyPath = $found.Trim()
            Write-Log "Found existing Python 3.14.10 via uv python find: $pyPath"
        }
        else {
            # c) Fallback: try Find-SystemPython (for consistency with claude-auto install)
            $systemPython = Find-SystemPython
            if ($systemPython) {
                $pyPath = $systemPython
                Write-Log "Using system Python (found via Find-SystemPython) for FCC: $pyPath"
            }
        }
    }

    if (-not $pyPath) {
        Write-Log "Python 3.14.10 not found; FCC skipped (install claude-auto only)"
        $script:fccInstalledByUs = $false
        return $true
    }

    # d) Install FCC using found Python
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
        # Skip copy if SourceDir == InstallDir (resolved paths)
        $srcResolved = (Resolve-Path -LiteralPath $SourceDir -ErrorAction SilentlyContinue).Path
        $dstResolved = (Resolve-Path -LiteralPath $InstallDir -ErrorAction SilentlyContinue).Path
        if ($srcResolved -and $dstResolved) {
            $srcResolved = $srcResolved.TrimEnd('\')
            $dstResolved = $dstResolved.TrimEnd('\')
            if ($srcResolved -eq $dstResolved) {
                Write-Log "SourceDir == InstallDir ($srcResolved), skip copy"
                return $true
            }
        }

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
    Write-Log "Installing claude-auto from $InstallDir via uv (tool dir: $UvToolDir)"
    try {
        # Find system Python to avoid os error 448 on Windows 11 24H2+
        $systemPython = Find-SystemPython
        $uvArgs = @("tool", "install", "--from", $SourceDir, "--force", "claude-auto")
        if ($systemPython) {
            $uvArgs = @("tool", "install", "--from", $SourceDir, "--python", $systemPython, "--force", "claude-auto")
            Write-Log "Using system Python for uv tool install: $systemPython"
        } else {
            Write-Log "[WARN] System Python 3.11+ not found, falling back to managed Python (may fail on Windows 11 24H2+ with os error 448)"
        }
        $output = & "uv" $uvArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorLog "claude-auto installation failed: $output"
            return $false
        }

        # Cleanup build artifacts left by uv's PEP 517 build
        $artifactsToClean = @("$InstallDir\build", "$InstallDir\claude_auto.egg-info")
        foreach ($dir in $artifactsToClean) {
            if (Test-Path -LiteralPath $dir) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Cleaned up build artifact: $dir"
            }
        }
        Get-ChildItem $InstallDir -Directory -Filter "*.egg-info" -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Cleaned up build artifact: $($_.FullName)"
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
        Write-Log "=== claude-auto installation started ==="
        Write-Log "InstallDir: $InstallDir"
        Write-Log "DataDir: $DataDir"
        Write-Log "UvToolDir: $UvToolDir"
        Write-Log "InstallFcc: $InstallFcc"
        Write-Log "Silent: $Silent"

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
