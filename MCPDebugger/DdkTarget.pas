unit DdkTarget;

// delphi-devkit (DDK) as the source of a launch or attach request.
//
// DDK describes a project's DEBUG TARGET in a debugger-agnostic JSON
// (`ddk.exe debug-target <id|name|path> --json`): the executable to launch (the
// program, or the Host Application of a package / DLL), its .map / .rsm, the
// project's own .bpl / .dll with their symbol files, the source root and the
// search paths (dproj + IDE library and browsing paths), the run arguments, and
// warnings about missing or stale artefacts. This unit parses that reply and
// maps it onto the same TLaunchOptions / TAttachOptions the launch.json reader
// (LaunchConfig.pas) produces, so the MCP tools `launch_project` and
// `attach_to_project` reuse the existing launch / attach path unchanged.
//
// The mapping is a pure function of the JSON text (ParseDebugTarget +
// LaunchOptionsFromTarget / AttachOptionsFromTarget), unit-tested against a
// fixture; locating and running ddk.exe is kept apart from it.

interface

uses
  System.SysUtils, System.JSON, DebugSessionTypes;

type
  TDdkModule = record
    Name:    string;
    Binary:  string;   // '' when DDK found no built binary
    MapPath: string;
    RsmPath: string;
    DcpPath: string;
  end;

  TDdkDebugTarget = record
    ProjectId:         Integer;   // -1 for an ad-hoc (unmanaged) path
    Project:           string;
    ProjectFile:       string;
    MainSource:        string;
    Kind:              string;    // program | package | library
    Executable:        string;    // the program, or the host application
    HostApplication:   string;
    Compiler:          string;
    Config:            string;
    Platform:          string;
    Bitness:           Integer;   // 32 / 64; 0 when DDK reports null (non-Windows)
    MapPath:           string;
    RsmPath:           string;
    SourceRoot:        string;
    SourceSearchPaths: TArray<string>;
    Modules:           TArray<TDdkModule>;
    Args:              TArray<string>;
    Warnings:          TArray<string>;
  end;

// Parses `ddk.exe debug-target --json` output. False + ErrMsg when the text is
// not a debug target at all.
function ParseDebugTarget(const Json: string; out Target: TDdkDebugTarget;
  out ErrMsg: string): Boolean;

// The launch request for a target: executable, symbols, sources, the modules
// that have a binary, the arguments. False + ErrMsg (DDK's own warning text
// when there is one) for a target this debugger cannot run: no Windows
// bitness, or no executable.
function LaunchOptionsFromTarget(const Target: TDdkDebugTarget;
  out Opts: TLaunchOptions; out ErrMsg: string): Boolean;

// The attach request for a target, plus the executable's basename as the
// process selector (the existing single-instance / ambiguity semantics of
// attach_to_process then apply).
function AttachOptionsFromTarget(const Target: TDdkDebugTarget;
  out Opts: TAttachOptions; out ProcessName: string; out ErrMsg: string): Boolean;

// DDK's argument list as the single command-line tail TLaunchOptions.Args
// carries: an argument with a space or a quote is quoted, as CreateProcess
// expects.
function JoinCommandLineArgs(const Args: TArray<string>): string;

// The modules DDK found on disk, in the session's own record.
function SessionModulesFromTarget(const Target: TDdkDebugTarget): TArray<TSessionModuleConfig>;

// Where ddk.exe is, in this order: the explicit override (the `--ddk-exe`
// switch), the DDK_EXE environment variable, PATH, the packaged DDK extension's
// bundled copy under %USERPROFILE%\.vscode\extensions (newest version).
// '' when none of them exists.
function LocateDdkExe(const OverridePath: string = ''): string;

// Runs `<DdkExe> debug-target <ProjectRef> --json [--compiler <Compiler>]` and
// returns its stdout. A non-zero exit comes back as False with ddk's own text
// (stderr) as ErrMsg - an ambiguous reference lists the candidates, an unknown
// project says so - never a generic failure. A `.cmd` / `.bat` is run through
// cmd.exe, so a wrapper script can stand in for the exe.
function RunDdkDebugTarget(const DdkExe, ProjectRef, Compiler: string;
  out Json, ErrMsg: string): Boolean;

// The whole step: locate, run, parse. ErrMsg names what to install when no
// ddk.exe could be found.
function FetchDebugTarget(const DdkExeOverride, ProjectRef, Compiler: string;
  out Target: TDdkDebugTarget; out ErrMsg: string): Boolean;

const
  DDK_NOT_FOUND_MESSAGE =
    'ddk.exe (delphi-devkit) was not found: install the "Delphi DevKit" VS Code extension ' +
    '(Snowcaloid.delphi-devkit), put ddk.exe on PATH, set the DDK_EXE environment variable, ' +
    'or start this server with --ddk-exe <path>.';

implementation

uses
  System.Classes, System.IOUtils, System.StrUtils, System.Generics.Collections,
  System.Generics.Defaults, Winapi.Windows;

// ---------------------------------------------------------------- parsing --

// DDK writes forward slashes; the engine and its readers compare and split on
// backslashes (ExtractFileName, module-name normalisation), so every path is
// turned into the native form once, here.
function NativePath(const S: string): string;
begin
  Result := StringReplace(S, '/', '\', [rfReplaceAll]);
end;

function StrField(Obj: TJSONObject; const Key: string): string;
begin
  var V := Obj.FindValue(Key);
  if (V = nil) or V.Null or not (V is TJSONString) then
    Exit('');
  Result := TJSONString(V).Value;
end;

function PathField(Obj: TJSONObject; const Key: string): string;
begin
  Result := NativePath(StrField(Obj, Key));
end;

function IntField(Obj: TJSONObject; const Key: string; Default: Integer): Integer;
begin
  var V := Obj.FindValue(Key);
  if V is TJSONNumber then
    Exit(TJSONNumber(V).AsInt);
  Result := Default;
end;

function StringArrayField(Obj: TJSONObject; const Key: string; AsPaths: Boolean): TArray<string>;
begin
  Result := nil;
  var V := Obj.FindValue(Key);
  if not (V is TJSONArray) then
    Exit;
  for var Item in TJSONArray(V) do begin
    if not (Item is TJSONString) then
      Continue;
    var S := TJSONString(Item).Value;
    if S.Trim = '' then
      Continue;
    if AsPaths then
      S := NativePath(S);
    Result := Result + [S];
  end;
end;

function ParseModules(Obj: TJSONObject): TArray<TDdkModule>;
begin
  Result := nil;
  var V := Obj.FindValue('modules');
  if not (V is TJSONArray) then
    Exit;
  for var Item in TJSONArray(V) do begin
    if not (Item is TJSONObject) then
      Continue;
    var M := TJSONObject(Item);
    var Module: TDdkModule;
    Module.Name    := StrField(M, 'name');
    Module.Binary  := PathField(M, 'binary');
    Module.MapPath := PathField(M, 'map');
    Module.RsmPath := PathField(M, 'rsm');
    Module.DcpPath := PathField(M, 'dcp');
    if (Module.Name = '') and (Module.Binary <> '') then
      Module.Name := ExtractFileName(Module.Binary);
    if Module.Name <> '' then
      Result := Result + [Module];
  end;
end;

function ParseDebugTarget(const Json: string; out Target: TDdkDebugTarget;
  out ErrMsg: string): Boolean;
begin
  Result := False;
  Target := Default(TDdkDebugTarget);
  ErrMsg := '';
  var Root := TJSONObject.ParseJSONValue(Json);
  if not (Root is TJSONObject) then begin
    Root.Free;
    ErrMsg := 'ddk.exe returned something that is not a debug target: ' + Copy(Json.Trim, 1, 200);
    Exit;
  end;
  try
    var Obj := TJSONObject(Root);
    if Obj.FindValue('executable') = nil then begin
      ErrMsg := 'ddk.exe returned JSON without an "executable" field: ' + Copy(Json.Trim, 1, 200);
      Exit;
    end;
    Target.ProjectId       := IntField(Obj, 'project_id', -1);
    Target.Project         := StrField(Obj, 'project');
    Target.ProjectFile     := PathField(Obj, 'project_file');
    Target.MainSource      := PathField(Obj, 'main_source');
    Target.Kind            := StrField(Obj, 'kind');
    Target.Executable      := PathField(Obj, 'executable');
    Target.HostApplication := PathField(Obj, 'host_application');
    Target.Compiler        := StrField(Obj, 'compiler');
    Target.Config          := StrField(Obj, 'config');
    Target.Platform        := StrField(Obj, 'platform');
    Target.Bitness         := IntField(Obj, 'bitness', 0);
    var Symbols := Obj.FindValue('symbols');
    if Symbols is TJSONObject then begin
      Target.MapPath := PathField(TJSONObject(Symbols), 'map');
      Target.RsmPath := PathField(TJSONObject(Symbols), 'rsm');
    end;
    Target.SourceRoot        := PathField(Obj, 'source_root');
    Target.SourceSearchPaths := StringArrayField(Obj, 'source_search_paths', True);
    Target.Modules           := ParseModules(Obj);
    Target.Args              := StringArrayField(Obj, 'args', False);
    Target.Warnings          := StringArrayField(Obj, 'warnings', False);
    Result := True;
  finally
    Root.Free;
  end;
end;

// ---------------------------------------------------------------- mapping --

function JoinCommandLineArgs(const Args: TArray<string>): string;

  function Quoted(const Arg: string): string;
  begin
    if (Arg <> '') and (Pos(' ', Arg) = 0) and (Pos(#9, Arg) = 0) and (Pos('"', Arg) = 0) then
      Exit(Arg);
    Result := '"' + StringReplace(Arg, '"', '\"', [rfReplaceAll]) + '"';
  end;

begin
  Result := '';
  for var Arg in Args do begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Quoted(Arg);
  end;
end;

function SessionModulesFromTarget(const Target: TDdkDebugTarget): TArray<TSessionModuleConfig>;
begin
  Result := nil;
  for var M in Target.Modules do begin
    // No binary on disk: nothing to bind symbols to. DDK already reports it as
    // a warning; passing it on would only make the session probe for a file
    // that is not there.
    if M.Binary = '' then
      Continue;
    var Cfg: TSessionModuleConfig;
    Cfg.Name    := M.Name;
    Cfg.MapPath := M.MapPath;
    Cfg.RsmPath := M.RsmPath;
    Cfg.DcpPath := M.DcpPath;
    Result := Result + [Cfg];
  end;
end;

function JoinedWarnings(const Target: TDdkDebugTarget): string;
begin
  Result := string.Join(' ', Target.Warnings);
end;

function TargetIsDebuggable(const Target: TDdkDebugTarget; out ErrMsg: string): Boolean;
begin
  ErrMsg := '';
  if not (Target.Bitness in [32, 64]) then begin
    ErrMsg := JoinedWarnings(Target);
    if ErrMsg = '' then
      ErrMsg := Format('DDK reports no Windows bitness for project "%s" (platform "%s"); ' +
        'this debugger runs Win32 and Win64 targets only.', [Target.Project, Target.Platform]);
    Exit(False);
  end;
  if Target.Executable = '' then begin
    ErrMsg := Format('DDK describes no executable for project "%s".', [Target.Project]);
    if Length(Target.Warnings) > 0 then
      ErrMsg := ErrMsg + ' ' + JoinedWarnings(Target);
    Exit(False);
  end;
  Result := True;
end;

function LaunchOptionsFromTarget(const Target: TDdkDebugTarget;
  out Opts: TLaunchOptions; out ErrMsg: string): Boolean;
begin
  Opts := Default(TLaunchOptions);
  if not TargetIsDebuggable(Target, ErrMsg) then
    Exit(False);
  Opts.ExePath          := Target.Executable;
  Opts.Args             := JoinCommandLineArgs(Target.Args);
  Opts.MapPath          := Target.MapPath;
  Opts.RsmPath          := Target.RsmPath;
  Opts.SourceRoot       := Target.SourceRoot;
  Opts.ExtraSourcePaths := Target.SourceSearchPaths;
  Opts.Modules          := SessionModulesFromTarget(Target);
  if Opts.MapPath = '' then
    Opts.MapPath := ChangeFileExt(Opts.ExePath, '.map');
  if Opts.RsmPath = '' then
    Opts.RsmPath := ChangeFileExt(Opts.ExePath, '.rsm');
  Result := True;
end;

function AttachOptionsFromTarget(const Target: TDdkDebugTarget;
  out Opts: TAttachOptions; out ProcessName: string; out ErrMsg: string): Boolean;
begin
  Opts := Default(TAttachOptions);
  ProcessName := '';
  if not TargetIsDebuggable(Target, ErrMsg) then
    Exit(False);
  Opts.ProgramPath      := Target.Executable;
  Opts.MapPath          := Target.MapPath;
  Opts.RsmPath          := Target.RsmPath;
  Opts.SourceRoot       := Target.SourceRoot;
  Opts.ExtraSourcePaths := Target.SourceSearchPaths;
  Opts.Modules          := SessionModulesFromTarget(Target);
  ProcessName := ExtractFileName(Target.Executable);
  Result := True;
end;

// --------------------------------------------------------------- locating --

function VersionOfFolder(const Name: string): TArray<Integer>;
begin
  Result := [0, 0, 0];
  var P := LastDelimiter('-', Name);
  if P = 0 then
    Exit;
  var Parts := SplitString(Copy(Name, P + 1, MaxInt), '.');
  for var I := 0 to 2 do
    if I < Length(Parts) then
      Result[I] := StrToIntDef(Parts[I], 0);
end;

function NewerFolder(const A, B: string): Integer;
begin
  var VA := VersionOfFolder(A);
  var VB := VersionOfFolder(B);
  for var I := 0 to 2 do
    if VA[I] <> VB[I] then
      Exit(VA[I] - VB[I]);
  Result := CompareText(A, B);
end;

function DdkExeFromPackagedExtension: string;
begin
  Result := '';
  var Home := GetEnvironmentVariable('USERPROFILE');
  if Home = '' then
    Exit;
  var ExtensionsDir := TPath.Combine(Home, '.vscode\extensions');
  if not TDirectory.Exists(ExtensionsDir) then
    Exit;
  var Folders := TDirectory.GetDirectories(ExtensionsDir, 'snowcaloid.delphi-devkit-*');
  TArray.Sort<string>(Folders, TComparer<string>.Construct(
    function(const L, R: string): Integer
    begin
      Result := NewerFolder(ExtractFileName(R), ExtractFileName(L));  // newest first
    end));
  for var Folder in Folders do begin
    var Candidate := TPath.Combine(Folder, 'server\ddk.exe');
    if TFile.Exists(Candidate) then
      Exit(Candidate);
  end;
end;

function LocateDdkExe(const OverridePath: string): string;
begin
  for var Candidate in [OverridePath, GetEnvironmentVariable('DDK_EXE')] do
    if (Candidate <> '') and TFile.Exists(Candidate) then
      Exit(Candidate);
  Result := FileSearch('ddk.exe', GetEnvironmentVariable('PATH'));
  if Result <> '' then
    Exit(ExpandFileName(Result));
  Result := DdkExeFromPackagedExtension;
end;

// ---------------------------------------------------------------- running --

function QuoteArg(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"';
end;

function DdkCommandLine(const DdkExe, ProjectRef, Compiler: string): string;
begin
  Result := QuoteArg(DdkExe) + ' debug-target ' + QuoteArg(ProjectRef) + ' --json';
  if Compiler <> '' then
    Result := Result + ' --compiler ' + QuoteArg(Compiler);
  // A batch wrapper needs the shell; cmd.exe strips the outermost quotes of a
  // /c argument that starts with one, hence the extra pair.
  var Ext := ExtractFileExt(DdkExe).ToLower;
  if (Ext = '.cmd') or (Ext = '.bat') then
    Result := 'cmd.exe /c "' + Result + '"';
end;

function ReadAllFromPipe(Pipe: THandle): TBytes;
begin
  Result := nil;
  var Buffer: array[0..8191] of Byte;
  while True do begin
    var Got: DWORD := 0;
    if not ReadFile(Pipe, Buffer, SizeOf(Buffer), Got, nil) or (Got = 0) then
      Break;
    var Offset := Length(Result);
    SetLength(Result, Offset + Integer(Got));
    Move(Buffer, Result[Offset], Got);
  end;
end;

// Stdout and stderr are drained on threads while the process runs: a pipe that
// nobody reads fills up, and a child writing 200 search paths would block on it
// forever, which this end would read as a hang.
function RunDdkDebugTarget(const DdkExe, ProjectRef, Compiler: string;
  out Json, ErrMsg: string): Boolean;
const
  TIMEOUT_MS = 120000;
begin
  Result := False;
  Json   := '';
  ErrMsg := '';

  var Sec: TSecurityAttributes;
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True;
  Sec.lpSecurityDescriptor := nil;
  var OutRead, OutWrite, ErrRead, ErrWrite: THandle;
  if not CreatePipe(OutRead, OutWrite, @Sec, 0) then
    RaiseLastOSError;
  if not CreatePipe(ErrRead, ErrWrite, @Sec, 0) then
    RaiseLastOSError;
  SetHandleInformation(OutRead, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(ErrRead, HANDLE_FLAG_INHERIT, 0);

  var SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput  := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := OutWrite;
  SI.hStdError  := ErrWrite;
  var PI: TProcessInformation;
  var Cmd := DdkCommandLine(DdkExe, ProjectRef, Compiler);
  UniqueString(Cmd);
  var Started := CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, nil, SI, PI);
  var StartError := GetLastError;
  CloseHandle(OutWrite);
  CloseHandle(ErrWrite);
  if not Started then begin
    CloseHandle(OutRead);
    CloseHandle(ErrRead);
    ErrMsg := Format('could not start %s: %s', [DdkExe, SysErrorMessage(StartError)]);
    Exit;
  end;

  var OutBytes, ErrBytes: TBytes;
  var OutThread := TThread.CreateAnonymousThread(procedure begin OutBytes := ReadAllFromPipe(OutRead); end);
  var ErrThread := TThread.CreateAnonymousThread(procedure begin ErrBytes := ReadAllFromPipe(ErrRead); end);
  OutThread.FreeOnTerminate := False;
  ErrThread.FreeOnTerminate := False;
  OutThread.Start;
  ErrThread.Start;
  try
    var Waited := WaitForSingleObject(PI.hProcess, TIMEOUT_MS);
    if Waited <> WAIT_OBJECT_0 then begin
      TerminateProcess(PI.hProcess, 1);
      ErrMsg := Format('ddk.exe did not answer within %d s', [TIMEOUT_MS div 1000]);
    end;
    var ExitCode: DWORD := 1;
    GetExitCodeProcess(PI.hProcess, ExitCode);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
    OutThread.WaitFor;
    ErrThread.WaitFor;
    CloseHandle(OutRead);
    CloseHandle(ErrRead);
    Json := TEncoding.UTF8.GetString(OutBytes);
    var Err := TEncoding.UTF8.GetString(ErrBytes).Trim;
    if ErrMsg <> '' then
      Exit;
    if ExitCode <> 0 then begin
      ErrMsg := Err;
      if ErrMsg = '' then
        ErrMsg := Json.Trim;
      if ErrMsg = '' then
        ErrMsg := Format('ddk.exe exited with code %d', [ExitCode]);
      Exit;
    end;
    Result := True;
  finally
    OutThread.Free;
    ErrThread.Free;
  end;
end;

function FetchDebugTarget(const DdkExeOverride, ProjectRef, Compiler: string;
  out Target: TDdkDebugTarget; out ErrMsg: string): Boolean;
begin
  Result := False;
  Target := Default(TDdkDebugTarget);
  var Exe := LocateDdkExe(DdkExeOverride);
  if Exe = '' then begin
    ErrMsg := DDK_NOT_FOUND_MESSAGE;
    Exit;
  end;
  var Json: string;
  if not RunDdkDebugTarget(Exe, ProjectRef, Compiler, Json, ErrMsg) then
    Exit;
  Result := ParseDebugTarget(Json, Target, ErrMsg);
end;

end.
