#define AppVersion Trim(FileRead(FileOpen("..\VERSION")))
[Setup]
AppId=SlavatorInstaller
AppName=Slavator
AppVersion={#AppVersion}
AppPublisher=Slavator
DefaultDirName={localappdata}\Programs\Slavator
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
OutputDir=..\dist
OutputBaseFilename=Slavator-{#AppVersion}-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=ui\slavator.ico
[Files]
Source: "..\core\*"; DestDir: "{tmp}\slavator-payload\core"; Flags: recursesubdirs createallsubdirs; Excludes: "__pycache__\*,*.pyc,tests\*"
Source: "..\windows\*"; DestDir: "{tmp}\slavator-payload\windows"; Flags: recursesubdirs createallsubdirs; Excludes: "__pycache__\*,*.pyc,setup.iss,test_*.py"
Source: "..\packaging\requirements*.txt"; DestDir: "{tmp}\slavator-payload\packaging"
Source: "..\VERSION"; DestDir: "{tmp}\slavator-payload"
[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  Args: String;
begin
  if CurStep = ssPostInstall then
  begin
    Args := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\slavator-payload\windows\install.ps1') + '" -NoLaunch';
    if ExpandConstant('{param:SkipOllama|0}') = '1' then
      Args := Args + ' -SkipOllama';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_SHOW, ewWaitUntilTerminated, ExitCode) then
      RaiseException('Cannot start PowerShell installer.');
    if ExitCode <> 0 then
      RaiseException('Installation failed. PowerShell exit code: ' + IntToStr(ExitCode));
  end;
end;
