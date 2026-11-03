<#
.SYNOPSIS
    claude-auto uninstaller - removes claude-auto and optionally FCC based on manifest ownership.
.DESCRIPTION
    Reads installation manifest to determine ownership of resources.
    Only removes resources created by this installation.
    Preserves pre-existing global installations.
.PARAMETER ManifestPath
    Path to installation manifest JSON. Default: %LOCALAPPDATA%\claude-auto\install.json
.PARAMETER DeleteFcc
    Switch: request FCC removal. Only honored if manifest confirms this installation created FCC.
.PARAMETER Silent
    Switch: suppress console output, only write to log file.
.PARAMETER LogPath
    Path to log file. Default: %LOCALAPPDATA%\claude-auto\uninstall.log
.PARAMETER Force
    Switch: skip confirmation prompts (for automated use).
#>

[CmdletBinding()]
param(
    [string]$ManifestPath = "$env:LOCALAPPDATA\claude-auto\install.json",
    [switch]$DeleteFcc,
    [switch]$Silent,
    [string]$LogPath = "$env:LOCALAPPDATA\claude-auto\uninstall.log",
    [switch]$Force
)

# State
$script:exitCode = 0

# Resolve uv executable path
function Resolve-UvExe {
    # Check user profile local bin
    $userUv = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path -LiteralPath $userUv) {
        Write-Log "Resolved uv from user profile: $userUv"
        return $userUv
    }
    # Check via Get-Command (PATH)
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -ne "Alias") {
        Write-Log "Resolved uv from PATH: $($cmd.Source)"
        return $cmd.Source
    }
    Write-Log "uv not found in USERPROFILE\.local\bin or PATH"
    return $null
}

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
    $script:exitCode = 1
}

# ========== PURE FUNCTION: ShouldRemoveFcc ==========
# Determines whether FCC should be removed based on user request and manifest state.
# This function has no side effects and is fully testable.
function ShouldRemoveFcc {
    param(
        [bool]$DeleteFccRequested,
        [string]$FccPreexisting,      # "true", "false", or null/missing
        [string]$FccInstalledByUs     # "true", "false", or null/missing
    )

    # Rule 1: No delete request -> never remove
    if (-not $DeleteFccRequested) {
        return $false
    }

    # Rule 2: FCC was pre-existing -> never remove (preserve user's global FCC)
    if ($FccPreexisting -eq "true") {
        return $false
    }

    # Rule 3: FCC was installed by this application -> remove
    if ($FccInstalledByUs -eq "true") {
        return $true
    }

    # Rule 4: Unknown state (missing manifest, missing fields, parse error) -> conservative: do not remove
    return $false
}

# ========== PURE FUNCTION: ShouldRemoveClaudeAuto ==========
# Determines whether claude-auto should be removed based on manifest state.
# This function has no side effects and is fully testable.
function ShouldRemoveClaudeAuto {
    param(
        [string]$ClaudeAutoPreexisting,           # "true", "false", or null/missing
        [string]$ClaudeAutoInstalledByUs,         # "true", "false", or null/missing
        [string]$ClaudeAutoUpgradeFromOurPrevious # "true", "false", or null/missing
    )

    # Rule 1: Was pre-existing (foreign) -> never remove
    if ($ClaudeAutoPreexisting -eq "true") {
        return $false
    }

    # Rule 2: Was installed by this application -> remove
    if ($ClaudeAutoInstalledByUs -eq "true") {
        return $true
    }

    # Rule 3: Was upgrade from our previous installation -> remove (we own it)
    if ($ClaudeAutoUpgradeFromOurPrevious -eq "true") {
        return $true
    }

    # Rule 4: Unknown state -> conservative: do not remove
    return $false
}

# Manifest reading
function Read-Manifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ErrorLog "Manifest not found: $Path"
        return $null
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $manifest = $json | ConvertFrom-Json
        Write-Log "Manifest read successfully"
        return $manifest
    }
    catch {
        Write-ErrorLog "Failed to parse manifest: $($_.Exception.Message)"
        return $null
    }
}

# Validate manifest belongs to claude-auto
function Validate-Manifest {
    param($Manifest)
    if ($null -eq $Manifest) { return $false }

    # Check required fields
    $requiredFields = @("install_dir", "data_dir", "uv_tool_dir", "status", "version")
    foreach ($field in $requiredFields) {
        if (-not $Manifest.$field) {
            Write-ErrorLog "Manifest missing required field: $field"
            return $false
        }
    }

    # Check ownership fields exist (at least one should be present)
    $ownershipFields = @("claude_auto_installed_by_us", "claude_auto_preexisting", "fcc_installed_by_us", "fcc_preexisting")
    $hasOwnership = $false
    foreach ($field in $ownershipFields) {
        if ($Manifest.$field -ne $null) { $hasOwnership = $true; break }
    }
    if (-not $hasOwnership) {
        Write-ErrorLog "Manifest missing ownership fields"
        return $false
    }

    # Check version compatibility
    if ($Manifest.version -and $Manifest.version -notmatch '^1\.\d+\.\d+$') {
        Write-Log "Manifest version $($Manifest.version) may be incompatible" "WARN"
    }

    # Verify status is expected value
    $validStatuses = @("installed", "in_progress", "failed")
    if ($Manifest.status -and $validStatuses -notcontains $Manifest.status) {
        Write-ErrorLog "Manifest has unexpected status: $($Manifest.status)"
        return $false
    }
    if ($Manifest.status -ne "installed") {
        Write-Log "Manifest status is '$($Manifest.status)', not 'installed'. Uninstall may be incomplete." "WARN"
    }

    # Verify install_dir contains pyproject.toml with claude-auto
    $pyprojectPath = Join-Path $Manifest.install_dir "pyproject.toml"
    if (Test-Path -LiteralPath $pyprojectPath) {
        $content = Get-Content -LiteralPath $pyprojectPath -Raw -Encoding UTF8
        $pattern = 'name\s*=\s*["'']claude-auto["'']'
        if (-not ($content -match $pattern)) {
            Write-ErrorLog "Install directory does not contain claude-auto project"
            return $false
        }
    }
    else {
        Write-ErrorLog "Install directory missing pyproject.toml"
        return $false
    }

    # Verify data_dir matches expected location (under LOCALAPPDATA\claude-auto)
    $expectedDataRoot = Join-Path $env:LOCALAPPDATA "claude-auto"
    if ($Manifest.data_dir -and -not ($Manifest.data_dir -like "$expectedDataRoot*")) {
        Write-ErrorLog "Data directory path mismatch: $($Manifest.data_dir) not under $expectedDataRoot"
        return $false
    }

    # Verify uv_tool_dir is under data_dir
    if ($Manifest.uv_tool_dir -and $Manifest.data_dir) {
        if (-not ($Manifest.uv_tool_dir -like "$($Manifest.data_dir)*")) {
            Write-ErrorLog "UV tool directory not under data directory"
            return $false
        }
    }

    # Verify uv_tool_bin_dir is under uv_tool_dir or data_dir
    if ($Manifest.uv_tool_bin_dir -and $Manifest.uv_tool_dir) {
        if (-not ($Manifest.uv_tool_bin_dir -like "$($Manifest.uv_tool_dir)*" -or $Manifest.uv_tool_bin_dir -like "$($Manifest.data_dir)*")) {
            Write-ErrorLog "UV tool bin directory path mismatch"
            return $false
        }
    }

    Write-Log "Manifest validation passed"
    return $true
}

# Uninstall claude-auto from dedicated uv tool environment
function Uninstall-ClaudeAuto {
    param($Manifest)
    Write-Log "Uninstalling claude-auto from dedicated uv tool environment"
    try {
        # Use the same UV_TOOL_DIR and UV_TOOL_BIN_DIR as the installation
        $uvToolDir = if ($Manifest.uv_tool_dir) { $Manifest.uv_tool_dir } else { Join-Path $Manifest.data_dir "uv-tools" }
        $uvToolBinDir = if ($Manifest.uv_tool_bin_dir) { $Manifest.uv_tool_bin_dir } else { Join-Path $uvToolDir "bin" }
        $env:UV_TOOL_DIR = $uvToolDir
        $env:UV_TOOL_BIN_DIR = $uvToolBinDir
        Write-Log "Using UV_TOOL_DIR: $uvToolDir"
        Write-Log "Using UV_TOOL_BIN_DIR: $uvToolBinDir"

        $uvExe = Resolve-UvExe
        if (-not $uvExe) {
            # uv not found - check if claude-auto.exe already gone from bin dir
            $claudeAutoExe = Join-Path $uvToolBinDir "claude-auto.exe"
            if (-not (Test-Path -LiteralPath $claudeAutoExe)) {
                Write-Log "uv not found; claude-auto is removed from uv-tools by directory cleanup"
                return $true
            }
            Write-ErrorLog "uv not found; claude-auto.exe still present at $claudeAutoExe"
            return $false
        }
        $output = & $uvExe tool uninstall "claude-auto" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "claude-auto uninstalled successfully"
            return $true
        }
        else {
            # Check if it was already uninstalled
            if ($output -match "not installed|cannot find") {
                Write-Log "claude-auto already uninstalled or not found"
                return $true
            }
            Write-ErrorLog "claude-auto uninstall failed: $output"
            return $false
        }
    }
    catch {
        Write-ErrorLog "Exception during claude-auto uninstall: $($_.Exception.Message)"
        return $false
    }
}

# Uninstall FCC from dedicated uv tool environment
function Uninstall-Fcc {
    param($Manifest)
    Write-Log "Uninstalling FCC from dedicated uv tool environment"
    try {
        $uvToolDir = if ($Manifest.uv_tool_dir) { $Manifest.uv_tool_dir } else { Join-Path $Manifest.data_dir "uv-tools" }
        $uvToolBinDir = if ($Manifest.uv_tool_bin_dir) { $Manifest.uv_tool_bin_dir } else { Join-Path $uvToolDir "bin" }
        $env:UV_TOOL_DIR = $uvToolDir
        $env:UV_TOOL_BIN_DIR = $uvToolBinDir

        $uvExe = Resolve-UvExe
        if (-not $uvExe) {
            # uv not found - check if free-claude-code.exe already gone from bin dir
            $fccExe = Join-Path $uvToolBinDir "free-claude-code.exe"
            if (-not (Test-Path -LiteralPath $fccExe)) {
                Write-Log "uv not found; FCC is removed from uv-tools by directory cleanup"
                return $true
            }
            Write-ErrorLog "uv not found; free-claude-code.exe still present at $fccExe"
            return $false
        }
        $output = & $uvExe tool uninstall "free-claude-code" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "FCC uninstalled successfully"
            return $true
        }
        else {
            if ($output -match "not installed|cannot find") {
                Write-Log "FCC already uninstalled or not found"
                return $true
            }
            Write-ErrorLog "FCC uninstall failed: $output"
            return $false
        }
    }
    catch {
        Write-ErrorLog "Exception during FCC uninstall: $($_.Exception.Message)"
        return $false
    }
}

# Remove installation directories
function Remove-Directories {
    param($Manifest)
    $dirsToRemove = @()

    # Add install_dir if it exists and belongs to us (has pyproject.toml with claude-auto)
    if ($Manifest.install_dir -and (Test-Path -LiteralPath $Manifest.install_dir)) {
        $pyprojectPath = Join-Path $Manifest.install_dir "pyproject.toml"
        if (Test-Path -LiteralPath $pyprojectPath) {
            $content = Get-Content -LiteralPath $pyprojectPath -Raw -Encoding UTF8
            $pattern = 'name\s*=\s*["'']claude-auto["'']'
            if ($content -match $pattern) {
                $dirsToRemove += $Manifest.install_dir
            }
        }
    }

    # Add known application-owned subdirectories under data_dir
    # We remove these individually, NOT the entire data_dir recursively
    $appOwnedSubDirs = @()
    if ($Manifest.data_dir -and (Test-Path -LiteralPath $Manifest.data_dir)) {
        # uv-tools directory (created by us)
        $uvToolsDir = if ($Manifest.uv_tool_dir) { $Manifest.uv_tool_dir } else { Join-Path $Manifest.data_dir "uv-tools" }
        if (Test-Path -LiteralPath $uvToolsDir) {
            $appOwnedSubDirs += $uvToolsDir
        }
        # manifest file
        $manifestFile = Join-Path $Manifest.data_dir "install.json"
        if (Test-Path -LiteralPath $manifestFile) {
            $appOwnedSubDirs += $manifestFile
        }
        # log files
        $logFiles = Get-ChildItem -LiteralPath $Manifest.data_dir -Filter "*.log" -ErrorAction SilentlyContinue
        $appOwnedSubDirs += $logFiles.FullName
    }

    # Remove application-owned directories
    foreach ($dir in $dirsToRemove) {
        Write-Log "Removing application directory: $dir"
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed: $dir"
            $script:removedCount++
        }
        catch {
            Write-ErrorLog ("Failed to remove {0}: {1}" -f $dir, $_.Exception.Message)
        }
    }

    # Remove application-owned subdirectories/files under data_dir
    foreach ($item in $appOwnedSubDirs) {
        Write-Log "Removing application-owned item: $item"
        try {
            if (Test-Path -LiteralPath $item) {
                Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $item"
            $script:removedCount++
            }
        }
        catch {
            Write-ErrorLog ("Failed to remove {0}: {1}" -f $item, $_.Exception.Message)
        }
    }

    # Only remove data_dir itself if it's now empty (no user files remain)
    if ($Manifest.data_dir -and (Test-Path -LiteralPath $Manifest.data_dir)) {
        $remaining = Get-ChildItem -LiteralPath $Manifest.data_dir -Force -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Write-Log "Data directory empty, removing: $($Manifest.data_dir)"
            try {
                Remove-Item -LiteralPath $Manifest.data_dir -Force -ErrorAction Stop
                Write-Log "Removed data directory: $($Manifest.data_dir)"
                $script:removedCount++
            }
            catch {
                Write-ErrorLog ("Failed to remove data directory {0}: {1}" -f $Manifest.data_dir, $_.Exception.Message)
            }
        }
        else {
            Write-Log "Data directory not empty, preserving user files: $($Manifest.data_dir)"
            $remaining | ForEach-Object { Write-Log "  Preserved: $($_.Name)" }
        }
    }
}

# Remove PATH entries added by this installation
function Remove-From-Path {
    param($Manifest)
    if (-not $Manifest.install_dir) { return }

    Write-Log "Checking user PATH for claude-auto entries"
    try {
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if (-not $currentPath) { return }

        $pathsToRemove = @(
            $Manifest.install_dir,
            (Join-Path $Manifest.install_dir "Scripts")
        )
        if ($Manifest.uv_tool_bin_dir) {
            $pathsToRemove += $Manifest.uv_tool_bin_dir
        }

        $parts = $currentPath -split ';' | Where-Object {
            $path = $_
            $path -and (-not ($pathsToRemove | Where-Object { $_ -eq $path }))
        }
        $newPath = $parts -join ';'

        if ($newPath -ne $currentPath) {
            [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
            Write-Log "Removed claude-auto from user PATH"
        }
        else {
            Write-Log "No claude-auto entries found in user PATH"
        }
    }
    catch {
        Write-ErrorLog "Failed to update user PATH: $($_.Exception.Message)"
    }
}

# Remove HKCU uninstall registry entry
function Remove-UninstallRegistry {
    param($Manifest)
    $appName = "claude-auto"
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appName"
    if (Test-Path $regPath) {
        Write-Log "Removing uninstall registry entry"
        try {
            Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction Stop
            Write-Log "Registry entry removed"
        }
        catch {
            Write-ErrorLog "Failed to remove registry entry: $($_.Exception.Message)"
        }
    }
    else {
        Write-Log "No uninstall registry entry found"
    }
}

# Main uninstall logic
function Main {
    try {
        Write-Log "=== claude-auto uninstallation started ==="
        Write-Log "DeleteFcc requested: $DeleteFcc"

        # Read manifest
        $manifest = Read-Manifest -Path $ManifestPath
        if (-not (Validate-Manifest -Manifest $manifest)) {
            Write-ErrorLog "Manifest validation failed. Aborting for safety."
            $script:exitCode = 2
            return
        }

        # Determine FCC removal
        $fccPreexisting = if ($manifest.fcc_preexisting) { $manifest.fcc_preexisting.ToString().ToLower() } else { $null }
        $fccInstalledByUs = if ($manifest.fcc_installed_by_us) { $manifest.fcc_installed_by_us.ToString().ToLower() } else { $null }

        Write-Log "Manifest state: fcc_preexisting=$fccPreexisting, fcc_installed_by_us=$fccInstalledByUs"

        $shouldRemoveFcc = ShouldRemoveFcc -DeleteFccRequested $DeleteFcc -FccPreexisting $fccPreexisting -FccInstalledByUs $fccInstalledByUs
        Write-Log "ShouldRemoveFcc decision: $shouldRemoveFcc"

        # Determine claude-auto removal
        $claudeAutoPreexisting = if ($manifest.claude_auto_preexisting) { $manifest.claude_auto_preexisting.ToString().ToLower() } else { $null }
        $claudeAutoInstalledByUs = if ($manifest.claude_auto_installed_by_us) { $manifest.claude_auto_installed_by_us.ToString().ToLower() } else { $null }
        $claudeAutoUpgradeFromOurPrevious = if ($manifest.claude_auto_upgrade_from_our_previous) { $manifest.claude_auto_upgrade_from_our_previous.ToString().ToLower() } else { $null }

        Write-Log "Manifest state: claude_auto_preexisting=$claudeAutoPreexisting, claude_auto_installed_by_us=$claudeAutoInstalledByUs, claude_auto_upgrade_from_our_previous=$claudeAutoUpgradeFromOurPrevious"

        $shouldRemoveClaudeAuto = ShouldRemoveClaudeAuto -ClaudeAutoPreexisting $claudeAutoPreexisting -ClaudeAutoInstalledByUs $claudeAutoInstalledByUs -ClaudeAutoUpgradeFromOurPrevious $claudeAutoUpgradeFromOurPrevious
        Write-Log "ShouldRemoveClaudeAuto decision: $shouldRemoveClaudeAuto"

        # Confirm if not forced
        if (-not $Force -and -not $Silent) {
            $msg = "This will remove:"
            if ($shouldRemoveClaudeAuto) { $msg += "`n  - claude-auto installation" } else { $msg += "`n  - claude-auto will be PRESERVED" }
            $msg += "`n  - Application data directory"
            if ($shouldRemoveFcc) { $msg += "`n  - FCC (Free Claude Code)" } else { $msg += "`n  - FCC will be PRESERVED" }
            $msg += "`n`nContinue? (y/N) "
            $ans = Read-Host $msg
            if ($ans -notmatch '^(y|yes)$') {
                Write-Log "Uninstall cancelled by user"
                $script:exitCode = 0
                return
            }
        }

        # Execute uninstall steps
        $success = $true

        # 1. Uninstall claude-auto if authorized
        if ($shouldRemoveClaudeAuto) {
            if (-not (Uninstall-ClaudeAuto -Manifest $manifest)) { $success = $false }
        }
        else {
            Write-Log "claude-auto preservation: not removing claude-auto"
        }

        # 2. Uninstall FCC if authorized
        if ($shouldRemoveFcc) {
            if (-not (Uninstall-Fcc -Manifest $manifest)) { $success = $false }
        }
        else {
            Write-Log "FCC preservation: not removing FCC"
        }

        # 3. Remove directories
        $script:removedCount = 0
        Remove-Directories -Manifest $manifest

        # 4. Remove from PATH
        Remove-From-Path -Manifest $manifest

        # 5. Remove uninstall registry
        Remove-UninstallRegistry -Manifest $manifest

        if (-not $success) {
            Write-ErrorLog "=== Uninstallation completed with errors ==="
            $script:exitCode = 1
        }
        elseif ($script:removedCount -gt 0) {
            Write-Log "=== Uninstallation completed: $($script:removedCount) item(s) removed ==="
            $script:exitCode = 0
        }
        else {
            Write-Log "=== Nothing removed (ownership not confirmed or nothing to remove) ==="
            $script:exitCode = 0
        }
    }
    catch {
        Write-ErrorLog "Unexpected error: $($_.Exception.Message)"
        $script:exitCode = 1
    }
    finally {
        exit $script:exitCode
    }
}

# Only run Main when executed directly
if ($MyInvocation.InvocationName -ne '.') {
    Main
}