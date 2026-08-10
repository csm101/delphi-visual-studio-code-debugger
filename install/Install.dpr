program Install;

// Interactive installer for the Delphi Debugger (Win32/Win64) VS Code extension.
// Resolves the repository root from its own location, ensures the DAP adapter
// executable is built, stages it next to the extension manifest, then packages
// the extension into a .vsix and installs it into every detected VS Code-family
// editor (VS Code, Insiders, Cursor, Windsurf, VSCodium, Trae) through that
// editor's CLI (<cli> --install-extension). Recent builds (1.96+) no longer load
// extensions merely copied into the extensions directory, so a real VSIX install
// is preferred; a folder copy is used only when an editor is present but its CLI
// is not on PATH. When no editor is detected the installer prints download links
// and the manual install command instead of blocking on a prompt.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  System.Zip,
  System.JSON,
  Winapi.Windows;

type
  TVsixInfo = record
    Name: string;
    Publisher: string;
    Version: string;
    DisplayName: string;
    Description: string;
    Engine: string;
  end;

  // One VS Code-family editor the VSIX can be installed into. All of these
  // accept the same VSIX format via "<Cli> --install-extension". ExtSubdir is
  // the per-editor profile directory under %USERPROFILE% (best-effort, used
  // only for detection and the legacy folder-copy fallback).
  TEditorTarget = record
    DisplayName: string;
    Cli: string;
    ExtSubdir: string;
    DownloadUrl: string;
  end;

const
  FamilyEditors: array[0..5] of TEditorTarget = (
    (DisplayName: 'Visual Studio Code'; Cli: 'code';          ExtSubdir: '.vscode';          DownloadUrl: 'https://code.visualstudio.com/'),
    (DisplayName: 'VS Code Insiders';   Cli: 'code-insiders';  ExtSubdir: '.vscode-insiders'; DownloadUrl: 'https://code.visualstudio.com/insiders/'),
    (DisplayName: 'Cursor';             Cli: 'cursor';         ExtSubdir: '.cursor';          DownloadUrl: 'https://cursor.com/'),
    (DisplayName: 'Windsurf';           Cli: 'windsurf';       ExtSubdir: '.windsurf';        DownloadUrl: 'https://windsurf.com/'),
    (DisplayName: 'VSCodium';           Cli: 'codium';         ExtSubdir: '.vscode-oss';      DownloadUrl: 'https://vscodium.com/'),
    (DisplayName: 'Trae';               Cli: 'trae';           ExtSubdir: '.trae';            DownloadUrl: 'https://www.trae.ai/')
  );

function ExeDir: string;
begin
  Result := TPath.GetDirectoryName(ParamStr(0));
end;

function RepoRoot: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExeDir, '..'));
end;

function StageDir: string;
begin
  Result := TPath.Combine(ExeDir, 'local.delphi-win64-debug');
end;

function AdapterExePath: string;
begin
  Result := TPath.Combine(RepoRoot,
    'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe');
end;

function AdapterSourcePath: string;
begin
  Result := TPath.Combine(RepoRoot,
    'VisualStudioCodeDelphiDebugger\VisualStudioCodeDelphiDebugger.dpr');
end;

// Portable (distributed zip) layout: the adapter is bundled next to the
// installer and there is no repository to build from. Repository layout: the
// adapter is copied from the build output on every run.
//
// The test is the adapter's SOURCE, never the staged executable. Staging writes
// that executable into the repository, so a repository that had been installed
// from once looked portable from then on, and every later install shipped the
// executable staged by the FIRST one - silently, since nothing else about the
// install differs. That is how an adapter predating `--list-processes` reached
// an extension whose process picker needs it: the picker ran it, the old binary
// saw an argument it did not know, fell through to its stdio DAP loop, and hung
// until the picker's timeout.
function IsPortable: Boolean;
begin
  Result := not TFile.Exists(AdapterSourcePath)
        and TFile.Exists(TPath.Combine(StageDir, 'VisualStudioCodeDelphiDebugger.exe'))
        and TFile.Exists(TPath.Combine(StageDir, 'package.json'));
end;

function UserProfile: string;
begin
  Result := GetEnvironmentVariable('USERPROFILE');
end;

function AskYesNo(const Prompt: string; DefaultYes: Boolean): Boolean;
begin
  var Hint := 'y/N';
  if DefaultYes then
    Hint := 'Y/n';
  Write(Prompt + ' [' + Hint + '] ');
  var Line := '';
  Readln(Line);
  Line := Line.Trim.ToLower;
  if Line = '' then
    Exit(DefaultYes);
  Result := (Line = 'y') or (Line = 'yes');
end;

function RunAndWait(const CommandLine: string): Cardinal;
begin
  var Si: TStartupInfo;
  FillChar(Si, SizeOf(Si), 0);
  Si.cb := SizeOf(Si);
  var Pi: TProcessInformation;
  var Cmd := CommandLine;
  UniqueString(Cmd); // CreateProcess may write to the command-line buffer
  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, 0, nil, nil, Si, Pi) then
    RaiseLastOSError;
  try
    WaitForSingleObject(Pi.hProcess, INFINITE);
    GetExitCodeProcess(Pi.hProcess, Result);
  finally
    CloseHandle(Pi.hProcess);
    CloseHandle(Pi.hThread);
  end;
end;

procedure EnsureAdapterBuilt;
begin
  if TFile.Exists(AdapterExePath) then
    Exit;
  Writeln('Adapter executable not found:');
  Writeln('  ' + AdapterExePath);
  if not AskYesNo('Build it now (runs build_dap.bat)?', True) then
    raise Exception.Create('Adapter executable is required. Build it and re-run.');
  var ExitCode := RunAndWait('cmd.exe /c "' + TPath.Combine(RepoRoot, 'build_dap.bat') + '"');
  if (ExitCode <> 0) or not TFile.Exists(AdapterExePath) then
    raise Exception.Create('Build failed; adapter executable still missing.');
end;

procedure StageFiles;
begin
  if not TFile.Exists(TPath.Combine(StageDir, 'package.json')) then
    raise Exception.Create('Missing package.json in ' + StageDir);
  TFile.Copy(AdapterExePath,
    TPath.Combine(StageDir, 'VisualStudioCodeDelphiDebugger.exe'), True);
  Writeln('Staged adapter into ' + StageDir);
end;

// ------------------------------- Zydis DLL -----------------------------------
// Optional disassembly backend (DISASSEMBLY_PLAN.md increment 7). Both the
// adapter and the MCP server already look for it NEXT TO THEIR OWN exe first
// (DapServer.pas / McpServer.pas ResolveZydisDllPath), so staging only needs
// to place the DLL (and its MIT licence text, "ships alongside" per the plan)
// beside each installed executable. A missing DLL here is NOT an install
// failure -- ZydisTryLoad fails closed and the feature reports UNAVAILABLE,
// exactly like a missing DLL does inside the build tree.
function ZydisDllSourcePath: string;
begin
  Result := TPath.Combine(ExeDir, 'Zydis.dll');   // bundled (portable zip: next to Setup.exe)
  if TFile.Exists(Result) then
    Exit;
  Result := TPath.Combine(RepoRoot, 'ThirdParty\Zydis\bin\x64\Zydis.dll'); // repository
end;

function ZydisLicenseSourcePath: string;
begin
  Result := TPath.Combine(ExeDir, 'Zydis-LICENSE.txt');
  if TFile.Exists(Result) then
    Exit;
  Result := TPath.Combine(RepoRoot, 'ThirdParty\Zydis\LICENSE');
end;

procedure CopyZydisIfAvailable(const DestDir: string);
begin
  var Dll := ZydisDllSourcePath;
  if not TFile.Exists(Dll) then begin
    Writeln('NOTE: Zydis.dll not found; disassembly will report UNAVAILABLE in this install (' + DestDir + ').');
    Exit;
  end;
  TFile.Copy(Dll, TPath.Combine(DestDir, 'Zydis.dll'), True);
  var Lic := ZydisLicenseSourcePath;
  if TFile.Exists(Lic) then
    TFile.Copy(Lic, TPath.Combine(DestDir, 'Zydis-LICENSE.txt'), True);
end;

// ------------------------------- MCP server ---------------------------------
// The MCP server is a standalone stdio exe registered with Claude Code / VS Code
// by ABSOLUTE path, so it is copied to a stable per-user location (surviving
// deletion of the installer/zip) and register-mcp.ps1 does the registration.

// Portable (zip): bundled next to the installer. Repository: the build output.
function McpSourceExe: string;
begin
  Result := TPath.Combine(ExeDir, 'DelphiDebuggerMcp.exe');
  if TFile.Exists(Result) then
    Exit;
  Result := TPath.Combine(RepoRoot, 'MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe');
end;

function McpInstallDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'DelphiWin64Debugger');
end;

function RegisterScriptPath: string;
begin
  Result := TPath.Combine(ExeDir, 'register-mcp.ps1');   // bundled (portable)
  if TFile.Exists(Result) then
    Exit;
  Result := TPath.Combine(RepoRoot, 'register-mcp.ps1'); // repository
end;

procedure EnsureMcpBuilt;
begin
  if TFile.Exists(McpSourceExe) then
    Exit;
  Writeln('MCP server executable not found:');
  Writeln('  ' + McpSourceExe);
  if not AskYesNo('Build it now (runs build_mcp.bat)?', True) then
    raise Exception.Create('MCP server executable is required. Build it and re-run.');
  var ExitCode := RunAndWait('cmd.exe /c "' + TPath.Combine(RepoRoot, 'build_mcp.bat') + '"');
  if (ExitCode <> 0) or not TFile.Exists(McpSourceExe) then
    raise Exception.Create('Build failed; MCP server executable still missing.');
end;

// Copies through the Win32 CopyFile, which opens the source with the sharing a
// RUNNING executable already has. TFile.Copy asks to deny writers and is
// refused, so installing while the MCP server is connected to Claude Code or
// VS Code failed with "the file is used by another process" - naming the source,
// which is the confusing half: nobody expects reading a running exe to be the
// problem.
//
// A locked DESTINATION is a different matter and still fails: that is the
// server itself, and it has to be stopped.
procedure CopyOverExecutable(const Source, Dest: string);
begin
  if CopyFile(PChar(Source), PChar(Dest), False) then
    Exit;
  var Error := GetLastError;
  if Error = ERROR_SHARING_VIOLATION then
    raise Exception.CreateFmt(
      '%s is running and holds %s. Disconnect it (in Claude Code: /mcp, then reconnect ' +
      'after this finishes) and re-run the installer.',
      [TPath.GetFileName(Dest), Dest]);
  raise Exception.CreateFmt('Cannot copy %s to %s: %s', [Source, Dest, SysErrorMessage(Error)]);
end;

procedure RegisterMcp;
begin
  EnsureMcpBuilt;
  TDirectory.CreateDirectory(McpInstallDir);
  var Dest := TPath.Combine(McpInstallDir, 'DelphiDebuggerMcp.exe');
  CopyOverExecutable(McpSourceExe, Dest);
  Writeln('Installed MCP server: ' + Dest);
  CopyZydisIfAvailable(McpInstallDir);

  var Script := RegisterScriptPath;
  if not TFile.Exists(Script) then begin
    Writeln('register-mcp.ps1 not found; skipping automatic registration.');
    Writeln('Register manually:  claude mcp add delphi-win64-debugger -s user -- "' + Dest + '"');
    Exit;
  end;
  RunAndWait(Format('cmd.exe /c powershell -NoProfile -ExecutionPolicy Bypass -File "%s" "%s"',
    [Script, Dest]));
end;

function ReadVsixInfo: TVsixInfo;
begin
  var ManifestPath := TPath.Combine(StageDir, 'package.json');
  if not TFile.Exists(ManifestPath) then
    raise Exception.Create('Missing package.json in ' + StageDir);

  var Json := TJSONObject.ParseJSONValue(TFile.ReadAllText(ManifestPath, TEncoding.UTF8)) as TJSONObject;
  if Json = nil then
    raise Exception.Create('Invalid package.json in ' + StageDir);
  try
    Result.Name := Json.GetValue<string>('name', '');
    Result.Publisher := Json.GetValue<string>('publisher', '');
    Result.Version := Json.GetValue<string>('version', '');
    Result.DisplayName := Json.GetValue<string>('displayName', Result.Name);
    Result.Description := Json.GetValue<string>('description', Result.DisplayName);
    Result.Engine := '^1.80.0';
    var Engines := Json.GetValue('engines') as TJSONObject;
    if Engines <> nil then
      Result.Engine := Engines.GetValue<string>('vscode', Result.Engine);
  finally
    Json.Free;
  end;

  if (Result.Name = '') or (Result.Publisher = '') or (Result.Version = '') then
    raise Exception.Create('package.json is missing name, publisher or version.');
end;

function XmlEscape(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

// Every part of an OPC package must have a declared content type, so a file
// whose extension is missing here is dropped or makes the .vsix invalid. The
// list is therefore DERIVED from what is actually staged rather than written by
// hand: a hand-kept list silently stops covering the package the first time
// someone adds a file type to it, and the failure surfaces only at install time
// on the user's machine.
function BuildContentTypesXml: string;

  function ContentTypeFor(const Ext: string): string;
  begin
    if Ext = 'json' then Exit('application/json');
    if Ext = 'js'   then Exit('text/javascript');
    if Ext = 'css'  then Exit('text/css');
    if Ext = 'html' then Exit('text/html');
    if Ext = 'md'   then Exit('text/markdown');
    if Ext = 'txt'  then Exit('text/plain');
    if Ext = 'svg'  then Exit('image/svg+xml');
    if Ext = 'png'  then Exit('image/png');
    Result := 'application/octet-stream';
  end;

begin
  var Seen := TStringList.Create;
  try
    Seen.Sorted     := True;
    Seen.Duplicates := dupIgnore;
    Seen.CaseSensitive := False;
    Seen.Add('vsixmanifest');
    for var FilePath in TDirectory.GetFiles(StageDir, '*', TSearchOption.soAllDirectories) do begin
      var Ext := TPath.GetExtension(FilePath).TrimLeft(['.']).ToLower;
      if Ext <> '' then
        Seen.Add(Ext);
    end;

    Result :=
      '<?xml version="1.0" encoding="utf-8"?>'#13#10 +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'#13#10;
    for var Ext in Seen do
      Result := Result + Format('  <Default Extension="%s" ContentType="%s" />'#13#10,
        [XmlEscape(Ext), ContentTypeFor(Ext)]);
    Result := Result + '</Types>'#13#10;
  finally
    Seen.Free;
  end;
end;

function BuildVsixManifestXml(const Info: TVsixInfo): string;
begin
  Result :=
    '<?xml version="1.0" encoding="utf-8"?>'#13#10 +
    '<PackageManifest Version="2.0.0" ' +
      'xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" ' +
      'xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">'#13#10 +
    '  <Metadata>'#13#10 +
    Format('    <Identity Language="en-US" Id="%s" Version="%s" Publisher="%s" />'#13#10,
      [XmlEscape(Info.Name), XmlEscape(Info.Version), XmlEscape(Info.Publisher)]) +
    Format('    <DisplayName>%s</DisplayName>'#13#10, [XmlEscape(Info.DisplayName)]) +
    Format('    <Description xml:space="preserve">%s</Description>'#13#10, [XmlEscape(Info.Description)]) +
    '    <Tags></Tags>'#13#10 +
    '    <Categories>Debuggers</Categories>'#13#10 +
    '    <Properties>'#13#10 +
    Format('      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="%s" />'#13#10,
      [XmlEscape(Info.Engine)]) +
    '    </Properties>'#13#10 +
    '  </Metadata>'#13#10 +
    '  <Installation>'#13#10 +
    '    <InstallationTarget Id="Microsoft.VisualStudio.Code" />'#13#10 +
    '  </Installation>'#13#10 +
    '  <Dependencies/>'#13#10 +
    '  <Assets>'#13#10 +
    '    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />'#13#10 +
    '  </Assets>'#13#10 +
    '</PackageManifest>'#13#10;
end;

// Packages the staged extension folder into an OPC/VSIX zip:
//   [Content_Types].xml          (root)
//   extension.vsixmanifest       (root)
//   extension/<staged files>     (whatever is in StageDir, recursively:
//                                 manifest, adapter exe, extension scripts,
//                                 webview assets)
// Returns the path to the generated .vsix in the temp directory.
function BuildVsix(const Info: TVsixInfo): string;
begin
  var VsixPath := TPath.Combine(TPath.GetTempPath,
    Format('%s.%s-%s.vsix', [Info.Publisher, Info.Name, Info.Version]));
  if TFile.Exists(VsixPath) then
    TFile.Delete(VsixPath);

  var Zip := TZipFile.Create;
  try
    Zip.Open(VsixPath, zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes(BuildContentTypesXml), '[Content_Types].xml');
    Zip.Add(TEncoding.UTF8.GetBytes(BuildVsixManifestXml(Info)), 'extension.vsixmanifest');
    for var FilePath in TDirectory.GetFiles(StageDir, '*', TSearchOption.soAllDirectories) do begin
      var Rel := FilePath.Substring(StageDir.Length).TrimLeft(['\', '/']);
      Rel := StringReplace(Rel, '\', '/', [rfReplaceAll]);
      Zip.Add(FilePath, 'extension/' + Rel);
    end;
    Zip.Close;
  finally
    Zip.Free;
  end;
  Result := VsixPath;
end;

// True if ACommand resolves on PATH (used to detect an editor's CLI launcher).
function CommandOnPath(const ACommand: string): Boolean;
begin
  Result := RunAndWait(Format('cmd.exe /c where %s >nul 2>nul', [ACommand])) = 0;
end;

function EditorParentDir(const Target: TEditorTarget): string;
begin
  Result := TPath.Combine(UserProfile, Target.ExtSubdir);
end;

function EditorExtensionsDir(const Target: TEditorTarget): string;
begin
  Result := TPath.Combine(EditorParentDir(Target), 'extensions');
end;

// An editor counts as present if its CLI is on PATH or its profile directory
// exists (the CLI is not always added to PATH by the editor's own installer).
function EditorDetected(const Target: TEditorTarget): Boolean;
begin
  Result := CommandOnPath(Target.Cli) or TDirectory.Exists(EditorParentDir(Target));
end;

function DetectedEditors: TArray<TEditorTarget>;
begin
  Result := [];
  for var Target in FamilyEditors do
    if EditorDetected(Target) then
      Result := Result + [Target];
end;

// Installs the VSIX through one editor's command-line launcher
// (<Cli> --install-extension). Returns True on success.
function InstallViaCli(const ACli, AVsixPath: string): Boolean;
begin
  Writeln(Format('Installing via %s --install-extension ...', [ACli]));
  Result := RunAndWait(Format('cmd.exe /c %s --install-extension "%s" --force', [ACli, AVsixPath])) = 0;
  if Result then
    Writeln(Format('Installed via %s CLI.', [ACli]));
end;

// VS Code's memory inspector -- the "View Binary Data" entry on a variable, and
// the hex view behind it -- is not part of the editor: it is contributed by the
// Hex Editor extension. Without it the adapter's readMemory / writeMemory and
// every variable's memoryReference are answered by nobody, and the feature looks
// missing rather than uninstalled.
//
// Installed best-effort, never fatally: it is an ADDITION to what this debugger
// does, not a prerequisite for it, and an editor with no marketplace reachable
// must still end up with a working debugger. Deliberately NOT declared as an
// `extensionDependencies` entry in package.json for the same reason -- that
// would make a failed marketplace lookup block the whole extension over an
// optional view.
procedure InstallMemoryInspector(const ACli: string);
begin
  Writeln('Installing the Hex Editor extension (memory inspection)...');
  if RunAndWait(Format('cmd.exe /c %s --install-extension ms-vscode.hexeditor --force',
       [ACli])) = 0 then
    Writeln('Hex Editor present.')
  else begin
    Writeln('Could not install ms-vscode.hexeditor. Everything else works;');
    Writeln('"View Binary Data" on a variable will be missing until you run:');
    Writeln(Format('  %s --install-extension ms-vscode.hexeditor', [ACli]));
  end;
end;

// Removes a legacy folder-copy install (an un-versioned
// "local.delphi-win64-debug" directory) from one editor's extensions dir. A
// real VSIX install creates a version-suffixed folder instead, and a leftover
// un-versioned copy would contribute the same debug type twice.
procedure RemoveStaleFolderInstall(const AExtensionsDir: string);
begin
  var Stale := TPath.Combine(AExtensionsDir, 'local.delphi-win64-debug');
  if TDirectory.Exists(Stale) then begin
    TDirectory.Delete(Stale, True);
    Writeln('Removed stale folder install: ' + Stale);
  end;
end;

// Printed when no VS Code-family editor is found: list download links and the
// manual install command instead of blocking on a folder prompt.
procedure PrintNoEditorInstructions(const AVsixPath: string);
begin
  Writeln('No VS Code-family editor was detected on this system.');
  Writeln('');
  Writeln('The extension package has been built here:');
  Writeln('  ' + AVsixPath);
  Writeln('');
  Writeln('Install one of these editors, then re-run this installer:');
  for var Target in FamilyEditors do
    Writeln(Format('  %-20s %s', [Target.DisplayName, Target.DownloadUrl]));
  Writeln('');
  Writeln('Or install the VSIX manually once an editor CLI is on PATH, e.g.:');
  Writeln(Format('  code --install-extension "%s" --force', [AVsixPath]));
end;

function ChooseEditors(const Detected: TArray<TEditorTarget>): TArray<TEditorTarget>;
begin
  if Length(Detected) = 1 then begin
    Writeln('Target editor: ' + Detected[0].DisplayName);
    Exit(Detected);
  end;
  Writeln('Detected editors:');
  for var I := 0 to High(Detected) do
    Writeln(Format('  %d) %s', [I + 1, Detected[I].DisplayName]));
  Writeln('  a) all');
  Write('Choose [a]: ');
  var Sel := '';
  Readln(Sel);
  Sel := Sel.Trim.ToLower;
  if (Sel = '') or (Sel = 'a') then
    Exit(Detected);
  var Idx := StrToIntDef(Sel, 0);
  if (Idx < 1) or (Idx > Length(Detected)) then
    raise Exception.Create('Invalid selection.');
  Result := [Detected[Idx - 1]];
end;

procedure InstallInto(const ExtensionsDir: string);
begin
  TDirectory.CreateDirectory(ExtensionsDir);
  var Target := TPath.Combine(ExtensionsDir, 'local.delphi-win64-debug');
  var Updating := TDirectory.Exists(Target);
  if Updating then begin
    if not AskYesNo('Update existing installation at ' + Target + '?', True) then begin
      Writeln('Skipped ' + Target);
      Exit;
    end;
    TDirectory.Delete(Target, True);
  end;
  TDirectory.Copy(StageDir, Target);
  if Updating then
    Writeln('Updated: ' + Target)
  else
    Writeln('Installed: ' + Target);
end;

// Installs the extension into one detected editor. Prefers the editor's CLI
// (works on current builds); falls back to a folder copy only when the CLI is
// not on PATH.
procedure InstallForEditor(const Target: TEditorTarget; const AVsixPath: string);
begin
  Writeln('--- ' + Target.DisplayName + ' ---');
  if CommandOnPath(Target.Cli) then begin
    if InstallViaCli(Target.Cli, AVsixPath) then begin
      RemoveStaleFolderInstall(EditorExtensionsDir(Target));
      InstallMemoryInspector(Target.Cli);
    end
    else
      Writeln('CLI install failed for ' + Target.DisplayName + '.');
    Exit;
  end;

  Writeln(Format('%s CLI not on PATH; falling back to folder copy.', [Target.Cli]));
  Writeln('Recent builds may ignore folder-copied extensions. If the debug type');
  Writeln('"delphi-win64" is still reported as unsupported, put the editor CLI on');
  Writeln('PATH and run:');
  Writeln(Format('  %s --install-extension "%s" --force', [Target.Cli, AVsixPath]));
  InstallInto(EditorExtensionsDir(Target));
end;

begin
  try
    Writeln('Delphi Debugger (Win32/Win64) - installer');
    if IsPortable then begin
      Writeln('Mode: portable (bundled adapter)');
    end
    else begin
      Writeln('Mode: repository (' + RepoRoot + ')');
      EnsureAdapterBuilt;
      StageFiles;
    end;
    // Idempotent either way: portable mode's StageDir already carries
    // Zydis.dll from the zip (build_setup_zip.bat stages it into
    // local.delphi-win64-debug before zipping); repository mode needs it
    // copied here since StageFiles above only staged the adapter exe.
    CopyZydisIfAvailable(StageDir);
    Writeln('');

    var Info := ReadVsixInfo;
    var VsixPath := BuildVsix(Info);
    Writeln('Built VSIX: ' + VsixPath);
    Writeln('');

    var Detected := DetectedEditors;
    if Length(Detected) = 0 then
      PrintNoEditorInstructions(VsixPath)
    else
      for var Target in ChooseEditors(Detected) do
        InstallForEditor(Target, VsixPath);

    Writeln('');
    Writeln('--- MCP debug server (Claude Code + VS Code) ---');
    // Its own failure domain: the extension is installed by this point, and
    // reporting the whole install as failed - skipping the "reload the editor"
    // instruction with it - is worse than reporting the part that did fail.
    if AskYesNo('Also install and register the MCP debug server?', True) then begin
      try
        RegisterMcp;
      except
        on E: Exception do begin
          Writeln('MCP server NOT installed: ' + E.Message);
          Writeln('The VS Code extension is installed and usable; re-run the installer for the MCP server.');
        end;
      end;
    end;

    Writeln('');
    Writeln('Done. Reload the editor (Ctrl+Shift+P -> Developer: Reload Window).');
  except
    on E: Exception do begin
      Writeln('ERROR: ' + E.Message);
      ExitCode := 1;
    end;
  end;
  Writeln('');
  Write('Press Enter to exit...');
  Readln;
end.
