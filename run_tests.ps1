# Test runner for claude-auto-install.ps1 Pester tests
# Does NOT modify system Pester modules. Checks for compatible version explicitly.

$WarningPreference = "SilentlyContinue"

# Check if Pester 5+ is available
$pesterModule = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1

if (-not $pesterModule) {
    Write-Error "Pester 5.0.0 or higher is required but not found."
    Write-Error "Install with: Install-Module -Name Pester -MinimumVersion 5.0.0 -Force"
    exit 1
}

Write-Host "Found Pester $($pesterModule.Version)"

# Import the compatible version
try {
    Import-Module Pester -MinimumVersion 5.0 -Force -ErrorAction Stop
}
catch {
    Write-Error "Failed to import Pester 5+: $($_.Exception.Message)"
    exit 1
}

$WarningPreference = "Continue"

# Dot-source the script to make functions available BEFORE Invoke-Pester
# (Pester 6 runs tests in a child scope)
$scriptPath = "C:\gags\claude-auto\claude-auto-install.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Error "Installer script not found: $scriptPath"
    exit 1
}

. $scriptPath

# Run tests
$testPath = "C:\gags\claude-auto\tests\claude-auto-install.Tests.ps1"
if (-not (Test-Path -LiteralPath $testPath)) {
    Write-Error "Test file not found: $testPath"
    exit 1
}

$res = Invoke-Pester -Path $testPath -Output Detailed -PassThru

Write-Host "Failed: $($res.FailedCount), Passed: $($res.PassedCount)"

if ($res.FailedCount -gt 0) {
    $res.TestResult | Where-Object { $_.FailedCount -gt 0 } | ForEach-Object {
        Write-Host "FAIL: $($_.Name) - $($_.FailureMessage)"
    }
    exit 1
}

exit 0

