; Установщик Windows — Inno Setup 6.3+ (на раннерах GitHub уже есть).
; Собирает .github/workflows/app-desktop.yml:
;   iscc /DAppVersion=1.0.23 /DAppBuild=24 /DBuildDir=<…\Release> /O<папка> tools\windows\starty.iss
; Итог — starty-setup-<версия>.exe.
;
; Ставится одному пользователю, без прав администратора, в %LOCALAPPDATA%\Programs\Figure Skating;
; ярлык в «Пуске» (по желанию — и на рабочем столе), удаление — в «Приложениях» Windows.
; Самообновление (app/lib/desktop_updater.dart) запускает тот же файл тихо:
;   starty-setup-<версия>.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1
; /RELAUNCH=1 — открыть приложение после тихой установки («Обновить сейчас»), 0 — нет (при закрытии).
;
; Файл в UTF-8 с BOM — так компилятор прочтёт кириллицу наверняка; BOM не убирать.

#ifndef AppVersion
  #error Нужен номер версии: iscc /DAppVersion=x.y.z /DAppBuild=n starty.iss
#endif
#ifndef AppBuild
  #define AppBuild "0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\app\build\windows\x64\runner\Release"
#endif

#define AppName "Фигурное катание"
#define AppExe "starty.exe"
; тот же идентификатор, что у уведомлений (app/lib/reminders.dart) и у процесса (app/windows/runner/main.cpp):
; по нему панель задач связывает окно приложения с ярлыком
#define AppAumid "ru.furya.starty"
; мьютекс держит app/windows/runner/main.cpp, пока приложение запущено
#define AppMutexName "ru.furya.starty.app"

[Setup]
; AppId не менять никогда: по нему установщик находит прежнюю установку и обновляет её, а не ставит вторую
AppId={{2BB26A06-BAF8-4A2F-BD3B-91B4A5A1D3F4}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Furya
AppPublisherURL=https://xfurya.github.io/Starty/
AppSupportURL=https://xfurya.github.io/Starty/
AppUpdatesURL=https://xfurya.github.io/Starty/
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} — установка
; одному пользователю, без запроса прав администратора; {userpf} = %LOCALAPPDATA%\Programs
PrivilegesRequired=lowest
DefaultDirName={userpf}\Figure Skating
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; запущенное приложение: обычная установка и удаление просят закрыть, тихая — отказывается без изменений
AppMutex={#AppMutexName}
SetupMutex=ru.furya.starty.setup
CloseApplications=yes
; заново открывает [Run] ниже, а не Restart Manager
RestartApplications=no
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
WizardStyle=modern
OutputDir=..\..\app\build\windows\installer
OutputBaseFilename=starty-setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; вся папка сборки: starty.exe, библиотеки Flutter и плагинов, data\, среда Visual C++ (её кладёт воркфлоу)
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; AppUserModelID: "{#AppAumid}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; AppUserModelID: "{#AppAumid}"; Tasks: desktopicon

[Registry]
; ключи, которые приложение само заводит для уведомлений: при установке не создавать, при удалении убрать
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\{#AppAumid}"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\{#AppAumid}"; Flags: uninsdeletekey dontcreatekey

[Run]
; обычная установка — галочка «Запустить» на последней странице
Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; тихая установка из приложения — открыть снова, только если попросили (/RELAUNCH=1)
Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Flags: nowait skipifnotsilent; Check: Relaunch

[Code]
{ Приложение запускает установщик и сразу закрывается. При тихой установке подождать до 30 с,
  пока оно выйдет: иначе проверка AppMutex застанет его ещё запущенным и установка откажется. }
function InitializeSetup: Boolean;
var
  I: Integer;
begin
  I := 0;
  while WizardSilent and CheckForMutexes('{#AppMutexName}') and (I < 60) do
  begin
    Sleep(500);
    I := I + 1;
  end;
  Result := True;
end;

function Relaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;
