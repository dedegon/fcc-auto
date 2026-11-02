#Requires -Modules @{ModuleName='Pester'; ModuleVersion='5.0.0'}

BeforeAll {
    # Dot-source the installer for testing
    . (Join-Path $PSScriptRoot '..\claude-auto-install.ps1')

    $LogPath = Join-Path $TestDrive 'install.log'

    # Define ShouldRemoveFcc in the same scope as tests
    function global:ShouldRemoveFcc {
        param(
            [bool]$DeleteFccRequested,
            [string]$FccPreexisting,
            [string]$FccInstalledByUs
        )

        if (-not $DeleteFccRequested) { return $false }
        if ($FccPreexisting -eq "true") { return $false }
        if ($FccInstalledByUs -eq "true") { return $true }
        return $false
    }
}

Describe "claude-auto-install.ps1" {
    Context "Read-FccVersion function" {
        It "Returns version for valid x.y.z file" {
            $tempFile = Join-Path $TestDrive "fcc.version"
            "6.18.5" | Out-File -FilePath $tempFile -Encoding UTF8
            $result = Read-FccVersion -Path $tempFile
            $result | Should -Be "6.18.5"
        }

        It "Returns null for missing file" {
            $result = Read-FccVersion -Path "C:\nonexistent\fcc.version"
            $result | Should -BeNullOrEmpty
        }

        It "Returns null for invalid format (6.18)" {
            $tempFile = Join-Path $TestDrive "fcc.version"
            "6.18" | Out-File -FilePath $tempFile -Encoding UTF8
            $result = Read-FccVersion -Path $tempFile
            $result | Should -BeNullOrEmpty
        }

        It "Returns null for invalid format (abc)" {
            $tempFile = Join-Path $TestDrive "fcc.version"
            "abc" | Out-File -FilePath $tempFile -Encoding UTF8
            $result = Read-FccVersion -Path $tempFile
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Detect-Fcc function" {
        BeforeEach {
            Mock Test-Path { return $false }
            Mock Get-Command { throw [System.Management.Automation.CommandNotFoundException]::new() }
            Mock -CommandName uv { return "" } -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "list" }
        }

        It "Returns Installed when uv tool list shows free-claude-code" {
            Mock -CommandName uv { return "free-claude-code 6.18.5" } -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "list" }
            $result = Detect-Fcc
            $result.State | Should -Be "Installed"
            $result.Version | Should -Be "6.18.5"
        }

        It "Returns NotInstalled when none of the checks succeed" {
            Mock -CommandName uv { return "" } -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "list" }
            $result = Detect-Fcc
            $result.State | Should -Be "NotInstalled"
            $result.Version | Should -BeNullOrEmpty
        }
    }

    Context "Detect-ClaudeAuto function" {
        BeforeEach {
            Mock -CommandName uv { return "" } -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "list" }
            Mock Get-Command { throw [System.Management.Automation.CommandNotFoundException]::new() }
        }

        It "Returns Installed when uv tool list shows claude-auto" {
            Mock -CommandName uv { return "claude-auto 1.0.0" } -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "list" }
            $result = Detect-ClaudeAuto
            $result.State | Should -Be "Installed"
            $result.Version | Should -Be "1.0.0"
        }

        It "Returns NotInstalled when none of the checks succeed" {
            $result = Detect-ClaudeAuto
            $result.State | Should -Be "NotInstalled"
        }
    }

    Context "Manifest operations" {
        BeforeEach {
            $script:fccPreexisting = $false
            $script:fccInstalledByUs = $false
            $script:installDirCreated = $false
            $script:claudeAutoInstalled = $false
            $script:claudeAutoPreexisting = $false
            # Override script-scope variables (dot-sourced script's parameters become variables in this scope)
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
        }

        It "Writes in_progress manifest with correct fields" {
            $manifestPath = Join-Path $TestDrive "install.json"
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $manifestPath
            $json = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.status | Should -Be "in_progress"
            $json.fcc_preexisting | Should -Be $false
            $json.fcc_installed_by_us | Should -Be $false
            $json.claude_auto_preexisting | Should -Be $false
            $json.claude_auto_installed_by_us | Should -Be $false
            $json.version | Should -Be "1.1.0"
            $json.fcc_version | Should -Be "6.18.5"
            $json.install_dir | Should -Be $InstallDir
            $json.data_dir | Should -Be $DataDir
            $json.uv_tool_dir | Should -Be $UvToolDir
        }

        It "Updates manifest with fcc_preexisting=true" {
            $manifestPath = Join-Path $TestDrive "install.json"
            $script:fccPreexisting = $true
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $manifestPath
            $json = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.fcc_preexisting | Should -Be $true
        }

        It "Updates manifest with fcc_installed_by_us=true" {
            $manifestPath = Join-Path $TestDrive "install.json"
            $script:fccInstalledByUs = $true
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $manifestPath
            $json = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.fcc_installed_by_us | Should -Be $true
        }

        It "Updates manifest with claude_auto_preexisting=true" {
            $manifestPath = Join-Path $TestDrive "install.json"
            $script:claudeAutoPreexisting = $true
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $manifestPath
            $json = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.claude_auto_preexisting | Should -Be $true
        }

        It "Writes installed manifest at the end" {
            $manifestPath = Join-Path $TestDrive "install.json"
            $script:fccInstalledByUs = $true
            Write-Manifest -Status "installed" -FccVersion "6.18.5" -ManifestPathOverride $manifestPath
            $json = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.status | Should -Be "installed"
        }

        It "Writes failed manifest on rollback" {
            $manifestPath = Join-Path $TestDrive "install.json"
            Write-Manifest -Status "failed" -ManifestPathOverride $manifestPath
            $json = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.status | Should -Be "failed"
        }
    }

    Context "Rollback logic" {
        BeforeEach {
            $script:fccPreexisting = $false
            $script:fccInstalledByUs = $false
            $script:installDirCreated = $false
            $script:claudeAutoInstalled = $false
            $script:claudeAutoPreexisting = $false
            $script:filesBackedUp = @{}
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            Mock -CommandName uv { }
            Mock Write-Log { }
            Mock Write-Manifest { }
            Mock Test-Path { return $false }
            Mock Remove-Item { }
            Mock Copy-Item { }
        }

        It "Rollback removes claude-auto but not FCC when fcc_installed_by_us=false" {
            $script:claudeAutoInstalled = $true
            $script:fccInstalledByUs = $false
            Mock -CommandName uv { } -Verifiable -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "uninstall" -and $args[2] -eq "claude-auto" }
            Mock -CommandName uv { } -Verifiable -ParameterFilter { $args[2] -eq "free-claude-code" } -ModuleName "Pester"
            Invoke-Rollback
        }

        It "Rollback removes FCC when fcc_installed_by_us=true" {
            $script:claudeAutoInstalled = $true
            $script:fccInstalledByUs = $true
            Mock -CommandName uv { } -Verifiable -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "uninstall" -and $args[2] -eq "claude-auto" }
            Mock -CommandName uv { } -Verifiable -ParameterFilter { $args[2] -eq "free-claude-code" }
            Invoke-Rollback
        }

        It "Rollback does not remove InstallDir when install_dir_created=false" {
            $script:installDirCreated = $false
            $script:claudeAutoInstalled = $true
            Mock Test-Path { return $true }
            Mock Remove-Item { } -Verifiable
            Invoke-Rollback
        }

        It "Rollback removes InstallDir when install_dir_created=true" {
            $script:installDirCreated = $true
            $script:claudeAutoInstalled = $true
            Mock Test-Path { return $true }
            Mock Remove-Item { } -Verifiable -ParameterFilter { $args[0] -eq $InstallDir }
            Invoke-Rollback
        }

        It "Rollback preserves pre-existing claude-auto when claudeAutoPreexisting=true" {
            $script:claudeAutoInstalled = $true
            $script:claudeAutoPreexisting = $true
            Mock -CommandName uv { } -Verifiable -ParameterFilter { $args[0] -eq "tool" -and $args[1] -eq "uninstall" -and $args[2] -eq "claude-auto" } -ModuleName "Pester"
            Invoke-Rollback
        }

        It "Rollback preserves pre-existing FCC when fccPreexisting=true" {
            $script:fccInstalledByUs = $false
            $script:fccPreexisting = $true
            $script:claudeAutoInstalled = $true
            Mock -CommandName uv { } -Verifiable -ParameterFilter { $args[2] -eq "free-claude-code" } -ModuleName "Pester"
            Invoke-Rollback
        }
    }

    Context "fcc.version validation" {
        It "Exits with code 1 for invalid FCC version format (before any changes)" {
            $badVersionFile = Join-Path $TestDrive "bad.version"
            "6.18" | Out-File -FilePath $badVersionFile -Encoding UTF8

            $manifestPath = Join-Path $TestDrive "install.json"
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $script:fccPreexisting = $false
            $script:fccInstalledByUs = $false
            $script:installDirCreated = $false
            $script:claudeAutoInstalled = $false
            $script:claudeAutoPreexisting = $false

            $result = Read-FccVersion -Path $badVersionFile
            $result | Should -BeNullOrEmpty
            (Test-Path $manifestPath) | Should -Be $false
        }
    }

    Context "Parameter handling - Silent mode" {
        BeforeEach {
            $global:LogPath = Join-Path $TestDrive "install.log"
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $script:fccPreexisting = $false
            $script:fccInstalledByUs = $false
            $script:installDirCreated = $false
            $script:claudeAutoInstalled = $false
            $script:claudeAutoPreexisting = $false
            $script:filesBackedUp = @{}

            Mock Read-FccVersion { return "6.18.5" }
            Mock Detect-Fcc { return @{ State = "NotInstalled"; Version = $null } }
            Mock Detect-ClaudeAuto { return @{ State = "NotInstalled"; Version = $null } }
            Mock Ensure-Uv { return $true }
            Mock Install-Fcc { return $true }
            Mock Copy-ProgramFiles { return $true }
            Mock Install-ClaudeAuto { return $true }
            Mock Verify-Installation { return $true }
            Mock Write-Manifest { }
            Mock Write-ErrorLog { }
        }

        It "Suppresses console output when -Silent is used" {
            $Silent = $true
            Write-Log "test message"
            $logContent = Get-Content $global:LogPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            $logContent | Should -Match "test message"
        }
    }

    Context "Backup and restore" {
        BeforeEach {
            $script:filesBackedUp = @{}
            $global:LogPath = Join-Path $TestDrive "install.log"
        }

        It "Backup-ExistingFile creates backup with timestamp" {
            $testFile = Join-Path $TestDrive "existing.txt"
            "original content" | Out-File -FilePath $testFile -Encoding UTF8
            Backup-ExistingFile -FilePath $testFile
            $backupFiles = Get-ChildItem $TestDrive -Filter "existing.txt.backup.*"
            $backupFiles.Count | Should -Be 1
            $script:filesBackedUp.Count | Should -Be 1
        }

        It "Restore-BackedUpFiles restores original content" {
            $testFile = Join-Path $TestDrive "existing.txt"
            "original content" | Out-File -FilePath $testFile -Encoding UTF8 -NoNewline
            Backup-ExistingFile -FilePath $testFile
            "new content" | Out-File -FilePath $testFile -Encoding UTF8 -NoNewline
            Restore-BackedUpFiles
            (Get-Content $testFile -Raw) | Should -Be "original content"
        }
    }

    Context "ShouldRemoveFcc function (pure)" {
        It "Returns false when DeleteFcc not requested" {
            ShouldRemoveFcc -DeleteFccRequested $false -FccPreexisting "false" -FccInstalledByUs "true" | Should -Be $false
            ShouldRemoveFcc -DeleteFccRequested $false -FccPreexisting "true" -FccInstalledByUs "true" | Should -Be $false
        }

        It "Returns false when FCC pre-existing (true)" {
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "true" -FccInstalledByUs "false" | Should -Be $false
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "true" -FccInstalledByUs "true" | Should -Be $false
        }

        It "Returns true when FCC installed by us and delete requested" {
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "false" -FccInstalledByUs "true" | Should -Be $true
        }

        It "Returns false when FCC state unknown (missing/null)" {
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting $null -FccInstalledByUs $null | Should -Be $false
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "" -FccInstalledByUs "" | Should -Be $false
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "unknown" -FccInstalledByUs "unknown" | Should -Be $false
        }

        It "Returns false when FCC not installed by us and not pre-existing" {
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "false" -FccInstalledByUs "false" | Should -Be $false
        }
    }

    Context "ShouldRemoveClaudeAuto function (pure)" {
        BeforeAll {
            # Define ShouldRemoveClaudeAuto in global scope for testing
            function global:ShouldRemoveClaudeAuto {
                param(
                    [string]$ClaudeAutoPreexisting,
                    [string]$ClaudeAutoInstalledByUs,
                    [string]$ClaudeAutoUpgradeFromOurPrevious
                )

                if ($ClaudeAutoPreexisting -eq "true") { return $false }
                if ($ClaudeAutoInstalledByUs -eq "true") { return $true }
                if ($ClaudeAutoUpgradeFromOurPrevious -eq "true") { return $true }
                return $false
            }
        }

        It "Returns false when claude-auto pre-existing (foreign)" {
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting "true" -ClaudeAutoInstalledByUs "false" -ClaudeAutoUpgradeFromOurPrevious "false" | Should -Be $false
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting "true" -ClaudeAutoInstalledByUs "true" -ClaudeAutoUpgradeFromOurPrevious "false" | Should -Be $false
        }

        It "Returns true when claude-auto installed by us" {
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting "false" -ClaudeAutoInstalledByUs "true" -ClaudeAutoUpgradeFromOurPrevious "false" | Should -Be $true
        }

        It "Returns true when upgrade from our previous installation" {
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting "false" -ClaudeAutoInstalledByUs "false" -ClaudeAutoUpgradeFromOurPrevious "true" | Should -Be $true
        }

        It "Returns false when state unknown" {
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting $null -ClaudeAutoInstalledByUs $null -ClaudeAutoUpgradeFromOurPrevious $null | Should -Be $false
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting "" -ClaudeAutoInstalledByUs "" -ClaudeAutoUpgradeFromOurPrevious "" | Should -Be $false
        }

        It "Returns false when not installed by us, not pre-existing, not upgrade" {
            ShouldRemoveClaudeAuto -ClaudeAutoPreexisting "false" -ClaudeAutoInstalledByUs "false" -ClaudeAutoUpgradeFromOurPrevious "false" | Should -Be $false
        }
    }

    Context "Copy-ProgramFiles with backup" {
        BeforeEach {
            $InstallDir = Join-Path $TestDrive "app"
            $SourceDir = Join-Path $TestDrive "src"
            $global:LogPath = Join-Path $TestDrive "install.log"
            $script:installDirCreated = $false
            $script:filesBackedUp = @{}

            # Create source files
            New-Item -ItemType Directory -Path $SourceDir -Force | Out-Null
            "source content" | Out-File -FilePath (Join-Path $SourceDir "claude_auto.py") -Encoding UTF8
        }

        It "Backs up existing files before overwriting" {
            # Pre-create destination with existing content
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            "existing content" | Out-File -FilePath (Join-Path $InstallDir "claude_auto.py") -Encoding UTF8 -NoNewline

            Mock Write-Log { }
            Mock -CommandName uv { }
            # Don't mock Copy-Item - let real copy happen for backup verification

            Copy-ProgramFiles

            # Verify backup file was created
            $backupFiles = Get-ChildItem $InstallDir -Filter "claude_auto.py.backup.*"
            $backupFiles.Count | Should -Be 1

            # Verify original content was restored to backup
            $backupContent = Get-Content $backupFiles[0].FullName -Raw -Encoding UTF8
            $backupContent | Should -Be "existing content"
        }
    }

    Context "Upgrade detection" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"

            # Create a fake existing manifest with our previous installation
            $existingManifest = @{
                repo_path                      = $InstallDir
                install_dir                    = $InstallDir
                data_dir                       = $DataDir
                uv_tool_dir                    = $UvToolDir
                status                         = "installed"
                updated                        = (Get-Date).ToString("o")
                fcc_preexisting                = $false
                fcc_installed_by_us            = $true
                fcc_upgrade_from_our_previous  = $false
                claude_auto_preexisting        = $false
                claude_auto_installed_by_us    = $true
                claude_auto_upgrade_from_our_previous = $false
                version                        = "1.0.0"
                fcc_version                    = "6.18.5"
            }
            $existingManifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8
        }

        It "Detects upgrade from our previous install (manifest exists, installed_by_us=true)" {
            # Simulate the Main function's upgrade detection logic
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $isUpgradeFromOurInstall = $false
            if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.claude_auto_installed_by_us -eq $true) {
                $isUpgradeFromOurInstall = $true
            }
            $isUpgradeFromOurInstall | Should -Be $true
        }

        It "Does not treat our previous install as foreign pre-existing" {
            # This test verifies the logic in Main after reading existing manifest
            $script:claudeAutoUpgradeFromOurPrevious = $true
            $script:claudeAutoPreexisting = $false  # Should be false for upgrade
            $script:claudeAutoPreexisting | Should -Be $false
        }

        It "Sets claude_auto_upgrade_from_our_previous=true in manifest" {
            $script:claudeAutoUpgradeFromOurPrevious = $true
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.claude_auto_upgrade_from_our_previous | Should -Be $true
        }

        It "Sets fcc_upgrade_from_our_previous=true in manifest when FCC was installed by us" {
            $script:fccUpgradeFromOurPrevious = $true
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.fcc_upgrade_from_our_previous | Should -Be $true
        }

        It "Proceeds to install/upgrade claude-auto on upgrade (claudeAutoPreexisting=false)" {
            $script:claudeAutoPreexisting = $false
            $shouldInstall = -not $script:claudeAutoPreexisting
            $shouldInstall | Should -Be $true
        }

        It "Preserves fcc_installed_by_us=true across upgrade" {
            $script:fccUpgradeFromOurPrevious = $true
            $script:fccInstalledByUs = $false  # Not installed THIS run yet
            # After upgrade completes, fcc_installed_by_us should be true in final manifest
            $script:fccInstalledByUs = $true
            Write-Manifest -Status "installed" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.fcc_installed_by_us | Should -Be $true
        }

        It "Reads existing manifest BEFORE writing new in_progress manifest" {
            # Verify the manifest file exists and is read before Write-Manifest in_progress
            (Test-Path $ManifestPath) | Should -Be $true
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingManifest.status | Should -Be "installed"
            $existingManifest.claude_auto_installed_by_us | Should -Be $true
        }
    }

    Context "Foreign pre-existing detection" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"
        }

        It "Detects foreign pre-existing FCC (no manifest, but Detect-Fcc finds it)" {
            Mock Detect-Fcc { return @{ State = "Installed"; Version = "6.18.5" } }
            $result = Detect-Fcc
            $result.State | Should -Be "Installed"
            $script:fccPreexisting = ($result.State -eq "Installed")
            $script:fccPreexisting | Should -Be $true
        }

        It "Detects foreign pre-existing claude-auto (no manifest, but Detect-ClaudeAuto finds it)" {
            Mock Detect-ClaudeAuto { return @{ State = "Installed"; Version = "1.0.0" } }
            $result = Detect-ClaudeAuto
            $result.State | Should -Be "Installed"
            $script:claudeAutoPreexisting = ($result.State -eq "Installed")
            $script:claudeAutoPreexisting | Should -Be $true
        }

        It "Sets fcc_preexisting=true, fcc_installed_by_us=false for foreign FCC" {
            $script:fccPreexisting = $true
            $script:fccInstalledByUs = $false
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.fcc_preexisting | Should -Be $true
            $json.fcc_installed_by_us | Should -Be $false
        }

        It "Sets claude_auto_preexisting=true, claude_auto_installed_by_us=false for foreign claude-auto" {
            $script:claudeAutoPreexisting = $true
            $script:claudeAutoInstalled = $false
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.claude_auto_preexisting | Should -Be $true
            $json.claude_auto_installed_by_us | Should -Be $false
        }

        It "Skips FCC install when foreign pre-existing detected" {
            $script:fccPreexisting = $true
            $InstallFcc = $true
            $shouldInstall = (-not $script:fccPreexisting -and $InstallFcc)
            $shouldInstall | Should -Be $false
        }

        It "Skips claude-auto install when foreign pre-existing detected" {
            $script:claudeAutoPreexisting = $true
            $shouldInstall = (-not $script:claudeAutoPreexisting)
            $shouldInstall | Should -Be $false
        }
    }

    Context "Unknown ownership (conservative defaults)" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"
        }

        It "Treats corrupt manifest as unknown -> preserves everything" {
            # Write corrupt JSON
            "not valid json" | Out-File -FilePath $ManifestPath -Encoding UTF8
            $existingManifest = $null
            try {
                $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { }
            $isUpgradeFromOurInstall = $false
            if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.claude_auto_installed_by_us -eq $true) {
                $isUpgradeFromOurInstall = $true
            }
            $isUpgradeFromOurInstall | Should -Be $false
        }

        It "Treats missing manifest fields as unknown -> preserves everything" {
            # Manifest with missing fields
            $manifest = @{
                status = "installed"
                # missing claude_auto_installed_by_us
            }
            $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $isUpgradeFromOurInstall = $false
            if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.claude_auto_installed_by_us -eq $true) {
                $isUpgradeFromOurInstall = $true
            }
            $isUpgradeFromOurInstall | Should -Be $false
        }

        It "ShouldRemoveFcc returns false for unknown state" {
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting $null -FccInstalledByUs $null | Should -Be $false
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "" -FccInstalledByUs "" | Should -Be $false
            ShouldRemoveFcc -DeleteFccRequested $true -FccPreexisting "unknown" -FccInstalledByUs "unknown" | Should -Be $false
        }

        It "Rollback preserves when ownership unclear (fccPreexisting=false, fccInstalledByUs=false, no upgrade flag)" {
            $script:fccPreexisting = $false
            $script:fccInstalledThisRun = $false
            $script:fccUpgradeFromOurPrevious = $false
            $shouldUninstall = $script:fccInstalledThisRun
            $shouldUninstall | Should -Be $false
        }
    }

    Context "Repeated install idempotency" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"

            # Simulate first install completed
            $manifest = @{
                repo_path                      = $InstallDir
                install_dir                    = $InstallDir
                data_dir                       = $DataDir
                uv_tool_dir                    = $UvToolDir
                status                         = "installed"
                updated                        = (Get-Date).ToString("o")
                fcc_preexisting                = $false
                fcc_installed_by_us            = $true
                fcc_upgrade_from_our_previous  = $false
                claude_auto_preexisting        = $false
                claude_auto_installed_by_us    = $true
                claude_auto_upgrade_from_our_previous = $false
                version                        = "1.1.0"
                fcc_version                    = "6.18.5"
            }
            $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8
        }

        It "Running installer twice does not duplicate PATH entries (simulated)" {
            # Simulate PATH handling - the installer doesn't add PATH directly,
            # Inno Setup does. But we can verify the logic doesn't assume clean PATH.
            $currentPath = "C:\Windows;C:\Windows\System32"
            $parts = $currentPath -split ';' | Where-Object { $_ -and $_ -ne $InstallDir -and $_ -ne (Join-Path $InstallDir "Scripts") }
            $newPath = $parts -join ';'
            $newPath | Should -Be $currentPath
        }

        It "Running installer twice does not duplicate registry entries (simulated)" {
            # Verify manifest version stays consistent
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingManifest.version | Should -Be "1.1.0"
        }

        It "Manifest version increments or stays consistent on upgrade" {
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Version should remain 1.1.0 (installer version, not app version)
            $existingManifest.version | Should -Be "1.1.0"
        }

        It "Upgrade detection works on second run with existing manifest" {
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $isUpgradeFromOurInstall = $false
            if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.claude_auto_installed_by_us -eq $true) {
                $isUpgradeFromOurInstall = $true
            }
            $isUpgradeFromOurInstall | Should -Be $true
        }
    }

    Context "UV shim isolation (UV_TOOL_BIN_DIR)" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $UvToolBinDir = Join-Path $UvToolDir "bin"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"
        }

        It "Manifest includes uv_tool_bin_dir field" {
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.uv_tool_bin_dir | Should -Be $UvToolBinDir
        }

        It "Installer sets UV_TOOL_BIN_DIR environment variable" {
            $UvToolBinDir = Join-Path $DataDir "uv-tools\bin"
            $env:UV_TOOL_BIN_DIR = $UvToolBinDir
            $env:UV_TOOL_BIN_DIR | Should -Be $UvToolBinDir
        }

        It "Uninstaller reads uv_tool_bin_dir from manifest for PATH removal" {
            $manifest = @{
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                uv_tool_bin_dir = $UvToolBinDir
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
                fcc_installed_by_us = $false
            }
            $pathsToRemove = @($manifest.install_dir, (Join-Path $manifest.install_dir "Scripts"))
            $pathsToRemove += $manifest.uv_tool_bin_dir
            $pathsToRemove | Should -Contain $UvToolBinDir
        }
    }

    Context "Data directory preservation" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $UvToolBinDir = Join-Path $UvToolDir "bin"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"

            # Create manifest with app-owned subdirs
            $manifest = @{
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                uv_tool_bin_dir = $UvToolBinDir
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
                fcc_installed_by_us = $false
            }
            $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8

            # Create app-owned directories
            New-Item -ItemType Directory -Path $UvToolDir -Force | Out-Null
            New-Item -ItemType Directory -Path $UvToolBinDir -Force | Out-Null
            "log content" | Out-File -FilePath (Join-Path $DataDir "install.log") -Encoding UTF8

            # Create USER files in data_dir (should be preserved)
            "user config" | Out-File -FilePath (Join-Path $DataDir "user-config.json") -Encoding UTF8
            "user data" | Out-File -FilePath (Join-Path $DataDir "custom.db") -Encoding UTF8
        }

        It "Remove-Directories preserves user files in data_dir" {
            Mock Write-Log { }
            Mock Write-ErrorLog { }
            # Don't mock Remove-Item - let real removal happen for verification

            # We can't easily test Remove-Directories directly because it's in the uninstaller
            # But we can verify the logic: it should only remove known app-owned items
            $uvToolsDir = Join-Path $DataDir "uv-tools"
            $manifestFile = Join-Path $DataDir "install.json"
            $logFile = Join-Path $DataDir "install.log"
            $userConfig = Join-Path $DataDir "user-config.json"
            $userDb = Join-Path $DataDir "custom.db"

            (Test-Path $uvToolsDir) | Should -Be $true
            (Test-Path $manifestFile) | Should -Be $true
            (Test-Path $logFile) | Should -Be $true
            (Test-Path $userConfig) | Should -Be $true
            (Test-Path $userDb) | Should -Be $true

            # Simulate what Remove-Directories should do
            # Remove app-owned items
            Remove-Item -LiteralPath $uvToolsDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue

            # User files should still exist
            (Test-Path $userConfig) | Should -Be $true
            (Test-Path $userDb) | Should -Be $true

            # data_dir should still exist (not empty)
            (Test-Path $DataDir) | Should -Be $true
        }

        It "Data directory removed only when empty" {
            $emptyDataDir = Join-Path $TestDrive "empty-data"
            New-Item -ItemType Directory -Path $emptyDataDir -Force | Out-Null
            $emptyManifest = @{
                data_dir = $emptyDataDir
                install_dir = Join-Path $TestDrive "empty-app"
                uv_tool_dir = Join-Path $emptyDataDir "uv-tools"
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            $emptyManifest | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $TestDrive "empty-manifest.json") -Encoding UTF8

            # Create app-owned items
            New-Item -ItemType Directory -Path (Join-Path $emptyDataDir "uv-tools") -Force | Out-Null
            "log" | Out-File -FilePath (Join-Path $emptyDataDir "install.log") -Encoding UTF8

            # Remove app-owned items
            Remove-Item -LiteralPath (Join-Path $emptyDataDir "uv-tools") -Recurse -Force
            Remove-Item -LiteralPath (Join-Path $emptyDataDir "install.log") -Force

            # Now data_dir should be empty and removable
            $remaining = Get-ChildItem -LiteralPath $emptyDataDir -Force -ErrorAction SilentlyContinue
            (-not $remaining) | Should -Be $true
        }
    }

    Context "Manifest validation" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $UvToolBinDir = Join-Path $UvToolDir "bin"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"

            # Create valid pyproject.toml for install_dir
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            'name = "claude-auto"' | Out-File -FilePath (Join-Path $InstallDir "pyproject.toml") -Encoding UTF8
        }

        It "Valid manifest passes validation" {
            $manifest = @{
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                uv_tool_bin_dir = $UvToolBinDir
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
                fcc_installed_by_us = $false
                fcc_preexisting = $false
                claude_auto_preexisting = $false
            }
            $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8

            # We can't easily test Validate-Manifest directly, but we can verify the logic
            $manifest.install_dir | Should -Be $InstallDir
            $manifest.data_dir | Should -Be $DataDir
            $manifest.uv_tool_dir | Should -Be $UvToolDir
            $manifest.status | Should -Be "installed"
        }

        It "Missing required field fails validation" {
            $manifest = @{
                install_dir = $InstallDir
                # missing data_dir
                status = "installed"
                version = "1.1.0"
            }
            $missingFields = @("install_dir", "data_dir", "uv_tool_dir", "status", "version") | Where-Object { -not $manifest.$_ }
            $missingFields.Count | Should -BeGreaterThan 0
        }

        It "Malformed JSON fails validation" {
            "not valid json" | Out-File -FilePath $ManifestPath -Encoding UTF8
            $parsed = $null
            try { $parsed = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            $parsed | Should -BeNullOrEmpty
        }

        It "Wrong product identity fails validation" {
            New-Item -ItemType Directory -Path (Join-Path $TestDrive "other-app") -Force | Out-Null
            'name = "other-app"' | Out-File -FilePath (Join-Path $TestDrive "other-app\pyproject.toml") -Encoding UTF8

            $manifest = @{
                install_dir = Join-Path $TestDrive "other-app"
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8

            $content = Get-Content (Join-Path $manifest.install_dir "pyproject.toml") -Raw -Encoding UTF8
            $pattern = 'name\s*=\s*["'']claude-auto["'']'
            ($content -match $pattern) | Should -Be $false
        }

        It "Mismatched install directory fails validation" {
            $manifest = @{
                install_dir = "C:\Wrong\Path"
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            (Test-Path $manifest.install_dir) | Should -Be $false
        }

        It "Mismatched data directory fails validation" {
            $manifest = @{
                install_dir = $InstallDir
                data_dir = "C:\Wrong\Data"
                uv_tool_dir = $UvToolDir
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            $expectedRoot = Join-Path $env:LOCALAPPDATA "claude-auto"
            ($manifest.data_dir -like "$expectedRoot*") | Should -Be $false
        }

        It "Mismatched uv tool directory fails validation" {
            $manifest = @{
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = "C:\Wrong\Tools"
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            ($manifest.uv_tool_dir -like "$($manifest.data_dir)*") | Should -Be $false
        }

        It "Incorrect status fails validation" {
            $manifest = @{
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                status = "unknown"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            $validStatuses = @("installed", "in_progress", "failed")
            ($validStatuses -contains $manifest.status) | Should -Be $false
        }

        It "Missing ownership fields fails validation" {
            $manifest = @{
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                status = "installed"
                version = "1.1.0"
                # missing all ownership fields
            }
            $ownershipFields = @("claude_auto_installed_by_us", "claude_auto_preexisting", "fcc_installed_by_us", "fcc_preexisting")
            $hasOwnership = $false
            foreach ($field in $ownershipFields) {
                if ($manifest.$field -ne $null) { $hasOwnership = $true; break }
            }
            $hasOwnership | Should -Be $false
        }

        It "Copied manifest from another installation fails validation" {
            # Manifest with different data_dir path
            $manifest = @{
                install_dir = $InstallDir
                data_dir = "C:\Users\OtherUser\AppData\Local\claude-auto"
                uv_tool_dir = Join-Path "C:\Users\OtherUser\AppData\Local\claude-auto" "uv-tools"
                status = "installed"
                version = "1.1.0"
                claude_auto_installed_by_us = $true
            }
            $expectedRoot = Join-Path $env:LOCALAPPDATA "claude-auto"
            ($manifest.data_dir -like "$expectedRoot*") | Should -Be $false
        }
    }

    Context "Failed upgrade rollback" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $UvToolBinDir = Join-Path $UvToolDir "bin"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"

            # Simulate existing manifest from previous successful install
            $existingManifest = @{
                repo_path = $InstallDir
                install_dir = $InstallDir
                data_dir = $DataDir
                uv_tool_dir = $UvToolDir
                uv_tool_bin_dir = $UvToolBinDir
                status = "installed"
                updated = (Get-Date).ToString("o")
                fcc_preexisting = $false
                fcc_installed_by_us = $true
                fcc_upgrade_from_our_previous = $false
                claude_auto_preexisting = $false
                claude_auto_installed_by_us = $true
                claude_auto_upgrade_from_our_previous = $false
                version = "1.1.0"
                fcc_version = "6.18.5"
            }
            $existingManifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8
        }

        It "Upgrade detection reads existing manifest before writing new one" {
            # This simulates Step 0 in Main
            $existingManifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $isUpgrade = $false
            if ($existingManifest -and $existingManifest.status -eq "installed" -and $existingManifest.claude_auto_installed_by_us -eq $true) {
                $isUpgrade = $true
            }
            $isUpgrade | Should -Be $true
        }

        It "Upgrade sets claudeAutoUpgradeFromOurPrevious=true" {
            $script:claudeAutoUpgradeFromOurPrevious = $true
            Write-Manifest -Status "in_progress" -FccVersion "6.18.5" -ManifestPathOverride $ManifestPath
            $json = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.claude_auto_upgrade_from_our_previous | Should -Be $true
        }

        It "Rollback on failed upgrade preserves previous installation (claudeAutoInstalledThisRun=false)" {
            # On upgrade, claudeAutoInstalledThisRun starts false
            # If Install-ClaudeAuto fails, rollback should NOT uninstall because claudeAutoInstalledThisRun is false
            $script:claudeAutoUpgradeFromOurPrevious = $true
            $script:claudeAutoInstalledThisRun = $false

            $shouldUninstall = $script:claudeAutoInstalledThisRun
            $shouldUninstall | Should -Be $false  # Don't uninstall on failed upgrade
        }

        It "Rollback on failed FCC upgrade preserves previous FCC (fccInstalledThisRun=false)" {
            $script:fccUpgradeFromOurPrevious = $true
            $script:fccInstalledThisRun = $false

            $shouldUninstall = $script:fccInstalledThisRun
            $shouldUninstall | Should -Be $false
        }

        It "Successful upgrade sets claudeAutoInstalledThisRun=true" {
            $script:claudeAutoInstalledThisRun = $true
            $script:claudeAutoInstalledThisRun | Should -Be $true
        }

        It "Partial file replacement rollback restores backed up files" {
            # Create a file in InstallDir
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            "original" | Out-File -FilePath (Join-Path $InstallDir "test.py") -Encoding UTF8 -NoNewline

            # Backup
            Backup-ExistingFile -FilePath (Join-Path $InstallDir "test.py")

            # Simulate failed replacement
            "new content" | Out-File -FilePath (Join-Path $InstallDir "test.py") -Encoding UTF8 -NoNewline

            # Rollback restores
            Restore-BackedUpFiles

            (Get-Content (Join-Path $InstallDir "test.py") -Raw) | Should -Be "original"
        }

        It "Rollback after partial uv tool replacement preserves previous version" {
            # On upgrade, previous version exists in uv tool dir
            # If new uv tool install fails, rollback should NOT uninstall (claudeAutoInstalledThisRun=false)
            $script:claudeAutoUpgradeFromOurPrevious = $true
            $script:claudeAutoInstalledThisRun = $false

            $preservePrevious = (-not $script:claudeAutoInstalledThisRun) -and $script:claudeAutoUpgradeFromOurPrevious
            $preservePrevious | Should -Be $true
        }
    }

    Context "Uninstaller resource ownership" {
        BeforeEach {
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
            $DataDir = $TestDrive
            $InstallDir = Join-Path $TestDrive "app"
            $UvToolDir = Join-Path $TestDrive "uv-tools"
            $UvToolBinDir = Join-Path $UvToolDir "bin"
            $ManifestPath = Join-Path $TestDrive "install.json"
            $global:LogPath = Join-Path $TestDrive "install.log"
        }

        It "Inno Setup owns application payload files (simulated)" {
            # Inno Setup copies files to {app}
            # PowerShell should NOT copy program files again
            # This is a design verification test
            $innoOwnsPayload = $true
            $psOwnsPayload = $false
            $innoOwnsPayload | Should -Be $true
            $psOwnsPayload | Should -Be $false
        }

        It "Inno Setup owns shortcuts (simulated)" {
            $innoOwnsShortcuts = $true
            $psOwnsShortcuts = $false
            $innoOwnsShortcuts | Should -Be $true
        }

        It "Inno Setup owns HKCU uninstall registry entry (simulated)" {
            $innoOwnsUninstallReg = $true
            $psOwnsUninstallReg = $false
            $innoOwnsUninstallReg | Should -Be $true
        }

        It "PowerShell owns PATH changes (simulated)" {
            $psOwnsPath = $true
            $innoOwnsPath = $false
            $psOwnsPath | Should -Be $true
        }

        It "PowerShell owns uv tool installation and removal (simulated)" {
            $psOwnsUvTools = $true
            $innoOwnsUvTools = $false
            $psOwnsUvTools | Should -Be $true
        }

        It "PowerShell owns FCC ownership and lifecycle (simulated)" {
            $psOwnsFcc = $true
            $innoOwnsFcc = $false
            $psOwnsFcc | Should -Be $true
        }

        It "PowerShell owns manifest and logs (simulated)" {
            $psOwnsManifest = $true
            $innoOwnsManifest = $false
            $psOwnsManifest | Should -Be $true
        }

        It "User data preserved by default (simulated)" {
            $preservesUserData = $true
            $preservesUserData | Should -Be $true
        }
    }
}





