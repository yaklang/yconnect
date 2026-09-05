#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef PayloadDirectory
  #error PayloadDirectory is required
#endif
#ifndef ReleaseDirectory
  #error ReleaseDirectory is required
#endif

[Setup]
AppId=io.yaklang.yconnect
AppName=YConnect
AppVersion={#AppVersion}
AppPublisher=YakLang
AppPublisherURL=https://github.com/yaklang/yconnect
AppSupportURL=https://github.com/yaklang/yconnect/issues
DefaultDirName={localappdata}\Programs\YConnect
DefaultGroupName=YConnect
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ReleaseDirectory}
OutputBaseFilename=YConnect-{#AppVersion}-windows-x64-setup
SetupIconFile=..\Assets\yconnect.ico
UninstallDisplayIcon={app}\YConnect.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#PayloadDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\YConnect"; Filename: "{app}\YConnect.exe"
Name: "{autodesktop}\YConnect"; Filename: "{app}\YConnect.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\YConnect.exe"; Description: "Launch YConnect"; Flags: nowait postinstall skipifsilent unchecked

[Code]
function InitializeSetup(): Boolean;
var
  FrameworkRelease: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', FrameworkRelease) and (FrameworkRelease >= 528040);
  if not Result then
    MsgBox('YConnect requires Microsoft .NET Framework 4.8 or later. Install it through Windows Update, then run this installer again.', mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command: String;
begin
  if CurUninstallStep = usUninstall then
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'YConnect', Command) then
      if CompareText(Command, '"' + ExpandConstant('{app}\YConnect.exe') + '" --background') = 0 then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'YConnect');
end;

// Uninstall removes only the installed payload and shortcuts.
// Account data and third-party client configurations are intentionally preserved.
