; claude-auto Inno Setup Script
; Variant B: User-level install, HKCU registry, HKCU\Environment PATH, asInvoker
; Requires Inno Setup 6.2+

#define MyAppName "claude-auto"
#define MyAppVersion "2.1.0"
#define MyAppPublisher "claude-auto"
#define MyAppURL "https://github.com/claude-auto/claude-auto"
#define MyAppExeName "claude-auto.exe"

; Build output directory
#define BuildOutputDir "dist"
#define SourceDir "."

[Setup]
AppId={{C3F8E9B2-7A4D-4F1E-9B6A-1D2E3F4A5B6C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\{#MyAppName}\app
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=
InfoBeforeFile=
InfoAfterFile=
OutputDir={#BuildOutputDir}
OutputBaseFilename=install-claude-auto-V{#MyAppVersion}
SetupIconFile={#SourceDir}\assets\icon.ico
WizardImageFile={#SourceDir}\assets\wizard.bmp
WizardSmallImageFile={#SourceDir}\assets\wizard_small.bmp
UninstallDisplayIcon={#SourceDir}\assets\icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
MinVersion=0,10.0.19041
DisableDirPage=no
UsePreviousAppDir=no
UsePreviousGroup=no
UsePreviousLanguage=no
UsePreviousTasks=no
AllowNoIcons=yes
WindowResizable=no
WindowShowCaption=yes
WindowStartMaximized=no
CreateAppDir=yes
AlwaysShowDirOnReadyPage=no
AlwaysShowGroupOnReadyPage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "installfcc"; Description: "Install Free Claude Code (FCC) via uv"; GroupDescription: "Optional components"; Flags: unchecked
Name: "uninstallfcc"; Description: "Remove Free Claude Code (FCC) on uninstall"; GroupDescription: "Uninstall options"; Flags: unchecked

[Files]
; Python source files
Source: "claude_auto.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "claude_filter.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "scanner.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "scanner_config.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "pyproject.toml"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion

; model_limits package
Source: "model_limits\__init__.py"; DestDir: "{app}\model_limits"; Flags: ignoreversion
Source: "model_limits\registry.py"; DestDir: "{app}\model_limits"; Flags: ignoreversion

; FCC version file (embedded in installer)
Source: "fcc.version"; DestDir: "{app}"; Flags: ignoreversion

; uv version and checksum (read by claude-auto-install.ps1 at install time)
Source: "uv.version"; DestDir: "{app}"; Flags: ignoreversion
Source: "uv.sha256";  DestDir: "{app}"; Flags: ignoreversion

; PowerShell installer and uninstaller scripts
Source: "claude-auto-install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "claude-auto-uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion

; C# Tray Launcher
Source: "dist\tray_launcher.exe"; DestDir: "{app}"; Flags: ignoreversion

; Offline wheels cache
Source: "dist\wheels\*"; DestDir: "{app}\wheels"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\tray_launcher.exe"; WorkingDir: "{app}"; Comment: "Run claude-auto tray launcher"; IconFilename: "{app}\tray_launcher.exe"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"; WorkingDir: "{app}"; Comment: "Uninstall claude-auto"
Name: "{code:GetRealDesktopPath}\{#MyAppName}"; Filename: "{app}\tray_launcher.exe"; WorkingDir: "{app}"; Comment: "Run claude-auto tray launcher"; Tasks: desktopicon; IconFilename: "{app}\tray_launcher.exe"

[Run]
; Run the PowerShell installer after file copy
; Parameters are built by GetInstallParams (see [Code]) and passed via {code:GetInstallParams}
Filename: "powershell.exe"; Parameters: "{code:GetInstallParams}"; StatusMsg: "Installing claude-auto and dependencies..."; Flags: runhidden waituntilterminated shellexec
Filename: "{app}\tray_launcher.exe"; Description: "Запустить claude-auto в трее"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Run the PowerShell uninstaller before file removal
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\claude-auto-uninstall.ps1"" -ManifestPath ""{localappdata}\{#MyAppName}\install.json"" -Force"; Flags: runhidden waituntilterminated shellexec

[InstallDelete]
; Remove old broken desktop shortcuts that might have been created with {autodesktop}
Type: files; Name: "{autodesktop}\{#MyAppName}.lnk"
Type: files; Name: "{commondesktop}\{#MyAppName}.lnk"

[Code]
var
  FCCDetected: Boolean;
  FCCVersionStr: String;
  FCCInstallPath: String;
  ClaudeAutoDetected: Boolean;
  ClaudeAutoVersionStr: String;
  IsUpgradeFromOurInstall: Boolean;
  FCCWasInstalledByUs: Boolean;

function GetRealDesktopPath(Param: String): String;
var
  RegKey: String;
begin
  RegKey := '';
  RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders', 'Desktop', RegKey);
  Result := ExpandConstant(RegKey);
end;

function GetFCCVersionFromExe(ExePath: String): String; forward;
function CheckFCCViaUvToolList(var Version: String): Boolean; forward;
function CheckClaudeAutoViaUvToolList(var Version: String): Boolean; forward;
function CheckManifestForOurInstall(): Boolean; forward;
function CheckManifestForFCCInstalledByUs(): Boolean; forward;
function BoolToStrLocal(B: Boolean; UseBoolStrs: Boolean): String;
begin
  if B then Result := 'True' else Result := 'False';
end;

function InitializeSetup(): Boolean;
begin
  // Detect existing FCC installation
  FCCDetected := False;
  FCCVersionStr := '';
  FCCInstallPath := '';

  // Check 1: file in %USERPROFILE%\.local\bin
  FCCInstallPath := ExpandConstant('{%USERPROFILE}\.local\bin\fcc-server.exe');
  if FileExists(FCCInstallPath) then begin
    FCCDetected := True;
    FCCVersionStr := GetFCCVersionFromExe(FCCInstallPath);
  end;

  // Check 2: uv tool list (if uv is available)
  if not FCCDetected then begin
    FCCDetected := CheckFCCViaUvToolList(FCCVersionStr);
  end;

  // Detect existing claude-auto installation
  ClaudeAutoDetected := False;
  ClaudeAutoVersionStr := '';

  // Check uv tool list for claude-auto
  ClaudeAutoDetected := CheckClaudeAutoViaUvToolList(ClaudeAutoVersionStr);

  // Check if this is an upgrade from our previous installation
  IsUpgradeFromOurInstall := False;
  FCCWasInstalledByUs := False;

  if FileExists(ExpandConstant('{localappdata}\{#MyAppName}\install.json')) then begin
    IsUpgradeFromOurInstall := CheckManifestForOurInstall;
    FCCWasInstalledByUs := CheckManifestForFCCInstalledByUs;
  end;

  Result := True;
end;

function GetFCCVersionFromExe(ExePath: String): String;
var
  ResultCode: Integer;
  VersionOutput: String;
begin
  Result := '';
  if Exec(ExePath, '--version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    // Note: Inno Setup can't easily capture stdout from Exec
    // We'll rely on uv tool list for version
  end;
end;

function CheckFCCViaUvToolList(var Version: String): Boolean;
var
  ResultCode: Integer;
  UvPath: String;
begin
  Result := False;
  Version := '';

  // Check if uv is in PATH
  UvPath := ExpandConstant('{%USERPROFILE}\.local\bin\uv.exe');
  if not FileExists(UvPath) then begin
    UvPath := 'uv';
  end;

  // We can't easily capture output in Inno Setup, so we'll let the PS installer handle detection
  // This function just returns False; the PS installer will do the real detection
end;

function CheckClaudeAutoViaUvToolList(var Version: String): Boolean;
var
  ResultCode: Integer;
  UvPath: String;
begin
  Result := False;
  Version := '';
  // Same as above - let PS installer handle real detection
end;

function CheckManifestForOurInstall(): Boolean;
var
  ManifestPath: String;
  JsonContent: String;
begin
  Result := False;
  ManifestPath := ExpandConstant('{localappdata}\{#MyAppName}\install.json');
  if FileExists(ManifestPath) then begin
    // We can't easily parse JSON in Inno Setup Pascal Script
    // The PS installer will do the real manifest parsing
    // This is just a hint for UI
    Result := True; // Assume it might be ours, PS will verify
  end;
end;

function CheckManifestForFCCInstalledByUs(): Boolean;
begin
  Result := False;
  // PS installer will do the real check
end;

procedure InitializeWizard();
var
  FCCLabel: TLabel;
  FCCStatusLabel: TLabel;
  ClaudeAutoLabel: TLabel;
  ClaudeAutoStatusLabel: TLabel;
  UpgradeLabel: TLabel;
begin
  // Add custom labels to show detection status on the welcome page
  // This runs after the welcome page is created

  // We'll add labels to the wpReady page instead (after directory selection)
  // For now, just log detection results
  Log('FCC Detected: ' + BoolToStrLocal(FCCDetected, True));
  if FCCDetected then Log('FCC Version: ' + FCCVersionStr);
  Log('claude-auto Detected: ' + BoolToStrLocal(ClaudeAutoDetected, True));
  if ClaudeAutoDetected then Log('claude-auto Version: ' + ClaudeAutoVersionStr);
  Log('Is Upgrade From Our Install: ' + BoolToStrLocal(IsUpgradeFromOurInstall, True));
  Log('FCC Was Installed By Us: ' + BoolToStrLocal(FCCWasInstalledByUs, True));
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // On the Ready page (wpReady), update task checkboxes based on detection
  if CurPageID = wpReady then begin
    // Disable "Install FCC" if FCC is already detected and not our upgrade
    if FCCDetected and not FCCWasInstalledByUs then begin
      WizardForm.TasksList.Checked[1] := False; // installfcc task (index 1)
      WizardForm.TasksList.ItemEnabled[1] := False;
    end;

    // Enable "Uninstall FCC" checkbox only if FCC was installed by us
    if FCCWasInstalledByUs then begin
      WizardForm.TasksList.ItemEnabled[2] := True; // uninstallfcc task (index 2)
    end else begin
      WizardForm.TasksList.ItemEnabled[2] := False;
    end;

    // Show upgrade info
    if IsUpgradeFromOurInstall then begin
      // Could add a label here showing upgrade info
    end;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  // Validate on Ready page
  if CurPageID = wpReady then begin
    // If this is an upgrade, confirm
    if IsUpgradeFromOurInstall then begin
      if MsgBox('An existing claude-auto installation was detected. This will upgrade it. Continue?', mbConfirmation, MB_YESNO) <> IDYES then begin
        Result := False;
      end;
    end;
  end;
end;

    function GetInstallParams(Param: String): String;
    var
      P: String;
      ActualInstallDir: String;
      ActualDataDir: String;
      ActualManifestPath: String;
    begin
      P := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\claude-auto-install.ps1') + '"';
      // Use the actual install directory chosen by user (respects /DIR parameter)
      ActualInstallDir := ExpandConstant('{app}');
      // DataDir is FIXED to %LOCALAPPDATA%\claude-auto regardless of /DIR
      ActualDataDir := ExpandConstant('{localappdata}\{#MyAppName}');
      // Manifest goes in DataDir
      ActualManifestPath := ActualDataDir + '\install.json';
      P := P + ' -InstallDir "' + ActualInstallDir + '"';
      P := P + ' -DataDir "' + ActualDataDir + '"';
      P := P + ' -ManifestPath "' + ActualManifestPath + '"';
      P := P + ' -FccVersionFile "' + ExpandConstant('{app}\fcc.version') + '"';
      P := P + ' -SourceDir "' + ExpandConstant('{app}') + '"';
      if WizardIsTaskSelected('installfcc') then
        P := P + ' -InstallFcc';
      if WizardSilent then
        P := P + ' -Silent';
      Result := P;
    end;

    function PrepareToInstall(var NeedsRestart: Boolean): String;
    begin
      Result := '';
    end;

    procedure CurStepChanged(CurStep: TSetupStep);
    begin
      if CurStep = ssPostInstall then begin
        // Installation completed successfully
        Log('Installation completed');
      end;
    end;

    procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
    begin
      if CurUninstallStep = usUninstall then begin
        // Uninstall started
        Log('Uninstall started');
      end;
    end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;

  // Skip license page (none defined)
  if PageID = wpLicense then Result := True;

  // Skip info pages (none defined)
  if PageID = wpInfoBefore then Result := True;
  if PageID = wpInfoAfter then Result := True;

  // Skip user info page
  if PageID = wpUserInfo then Result := True;
end;

procedure DeinitializeSetup();
begin
  // Cleanup if needed
end;

[CustomMessages]
english.FCCDetected=Free Claude Code (FCC) already installed
english.FCCNotDetected=Free Claude Code (FCC) not found
english.ClaudeAutoDetected=claude-auto already installed
english.ClaudeAutoNotDetected=claude-auto not found
english.UpgradeDetected=Upgrade from previous claude-auto installation detected
english.FCCInstalledByUs=FCC was installed by this application
english.FCCNotInstalledByUs=FCC was installed externally (will be preserved)

[UninstallDelete]
; Remove only Inno Setup-managed files (app directory with Python sources)
; The PS uninstaller handles uv-tools, manifest, logs, and PATH/registry
Type: filesandordirs; Name: "{app}"

[UninstallRegistry]
; Inno Setup manages its own uninstall registry entry in HKCU
; The PS uninstaller reads this for reference but doesn't delete it

[Registry]
; Inno Setup creates its own uninstall key in HKCU
; We don't need additional registry entries







