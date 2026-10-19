[Setup]
AppId={{8F9E7A2B-3C4D-4E5F-9A1B-2C3D4E5F6A7B}
AppName=Тризуб МС
AppVersion=2.4
AppPublisher=Тризуб МС
AppPublisherURL=https://tryzubmc-official.top
DefaultDirName={autopf}\TryzubPlayer
DefaultGroupName=Тризуб МС
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..
OutputBaseFilename=TryzubPlayerSetup
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Створити ярлик на Робочому столі"; GroupDescription: "Додаткові значки:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Тризуб МС"; Filename: "{app}\tryzub_app.exe"
Name: "{autodesktop}\Тризуб МС"; Filename: "{app}\tryzub_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\tryzub_app.exe"; Description: "Запустити Тризуб МС"; Flags: nowait postinstall skipifsilent
