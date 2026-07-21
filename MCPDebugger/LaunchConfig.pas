unit LaunchConfig;

// Reads a VS Code launch.json (the same file the DAP debugger is driven from) and
// turns a `delphi-win64` configuration into TLaunchOptions, so an agent working in
// a repo that already has a launch config need not re-specify program / map / rsm
// / source paths. Handles JSONC (// and /* */ comments, trailing commas) and the
// common ${workspaceFolder} / ${workspaceFolderBasename} / ${env:VAR} variables.
//
// Also exposes the source-search-path expansion used by the launch/attach tools so
// a multi-root `sourceSearchPaths` array is honoured everywhere.

interface

uses
  System.JSON, DebugSessionTypes;

// Strip // and /* */ comments and trailing commas from JSONC text.
function StripJsonc(const S: string): string;

// Resolve ${workspaceFolder(Basename)} / ${workspaceRoot} / ${env:VAR} in S.
function ResolveVars(const S, WorkspaceFolder: string): string;

// Resolve variables in each entry, split on ';', drop empties -> flat root list.
function ExpandSearchPaths(const Items: TArray<string>;
  const WorkspaceFolder: string): TArray<string>;

// Load a LAUNCH config (request "launch"). ConfigName selects by "name"; empty
// picks the first "delphi-win64" launch entry. WorkspaceFolder defaults to the
// parent of the launch.json's directory. Returns False + ErrMsg on failure.
function LoadLaunchConfig(const ConfigFile, ConfigName, WorkspaceFolder: string;
  out Opts: TLaunchOptions; out ErrMsg: string): Boolean;

// Load an ATTACH config (request "attach"): the source-path options plus the
// process selector (processId or processName) from the same launch.json.
function LoadAttachConfig(const ConfigFile, ConfigName, WorkspaceFolder: string;
  out Opts: TAttachOptions; out ProcessId: Cardinal; out ProcessName: string;
  out ErrMsg: string): Boolean;

implementation

uses
  System.SysUtils, System.Classes, System.StrUtils, System.IOUtils;

function StripJsonc(const S: string): string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    var I := 1;
    var InStr := False;
    while I <= Length(S) do begin
      var C := S[I];
      if InStr then begin
        SB.Append(C);
        if (C = '\') and (I < Length(S)) then begin
          SB.Append(S[I + 1]); Inc(I, 2); Continue;
        end;
        if C = '"' then
          InStr := False;
        Inc(I); Continue;
      end;
      if C = '"' then begin
        InStr := True; SB.Append(C); Inc(I); Continue;
      end;
      if (C = '/') and (I < Length(S)) and (S[I + 1] = '/') then begin
        Inc(I, 2);
        while (I <= Length(S)) and (S[I] <> #10) do Inc(I);
        Continue;
      end;
      if (C = '/') and (I < Length(S)) and (S[I + 1] = '*') then begin
        Inc(I, 2);
        while (I < Length(S)) and not ((S[I] = '*') and (S[I + 1] = '/')) do Inc(I);
        Inc(I, 2); Continue;
      end;
      SB.Append(C); Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;

  // Second pass: drop a comma that is followed (ignoring whitespace) by } or ].
  SB := TStringBuilder.Create;
  try
    var I := 1;
    var InStr := False;
    while I <= Length(Result) do begin
      var C := Result[I];
      if InStr then begin
        SB.Append(C);
        if (C = '\') and (I < Length(Result)) then begin
          SB.Append(Result[I + 1]); Inc(I, 2); Continue;
        end;
        if C = '"' then InStr := False;
        Inc(I); Continue;
      end;
      if C = '"' then begin InStr := True; SB.Append(C); Inc(I); Continue; end;
      if C = ',' then begin
        var J := I + 1;
        while (J <= Length(Result)) and CharInSet(Result[J], [' ', #9, #10, #13]) do Inc(J);
        if (J <= Length(Result)) and CharInSet(Result[J], ['}', ']']) then begin
          Inc(I); Continue;   // skip the trailing comma
        end;
      end;
      SB.Append(C); Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function ResolveVars(const S, WorkspaceFolder: string): string;
begin
  Result := S;
  if Result = '' then
    Exit;
  var WS := ExcludeTrailingPathDelimiter(WorkspaceFolder);
  Result := StringReplace(Result, '${workspaceFolder}', WS, [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '${workspaceRoot}',   WS, [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '${workspaceFolderBasename}',
    ExtractFileName(WS), [rfReplaceAll, rfIgnoreCase]);
  var P := Pos('${env:', Result);
  while P > 0 do begin
    var E := PosEx('}', Result, P);
    if E <= P then
      Break;
    var VarName := Copy(Result, P + 6, E - P - 6);
    Result := Copy(Result, 1, P - 1) + GetEnvironmentVariable(VarName) + Copy(Result, E + 1, MaxInt);
    P := Pos('${env:', Result);
  end;
end;

function ExpandSearchPaths(const Items: TArray<string>;
  const WorkspaceFolder: string): TArray<string>;
begin
  Result := nil;
  for var Raw in Items do begin
    var Expanded := ResolveVars(Raw, WorkspaceFolder);
    // Leave un-resolvable VS Code variables (e.g. $(...) macros) out.
    if (Pos('$(', Expanded) > 0) or (Pos('${', Expanded) > 0) then
      Continue;
    for var Part in SplitString(Expanded, ';') do begin
      var Entry := Trim(Part);
      if Entry <> '' then
        Result := Result + [Entry];
    end;
  end;
end;

type
  TCfgFields = record
    Request:     string;   // 'launch' | 'attach'
    Prog:        string;
    MapFile:     string;
    RsmFile:     string;
    SourceRoot:  string;
    Args:        string;
    Extra:       TArray<string>;
    ProcessId:   Cardinal;
    ProcessName: string;
  end;

// Shared reader: finds a delphi-win64 configuration (by name, or the first whose
// request matches WantRequest -- '' = any) and extracts all fields with variables
// resolved. No live TJSON escapes.
function ReadConfig(const ConfigFile, ConfigName, WorkspaceFolder, WantRequest: string;
  out F: TCfgFields; out ErrMsg: string): Boolean;
begin
  Result := False;
  F      := Default(TCfgFields);
  ErrMsg := '';
  if not FileExists(ConfigFile) then begin
    ErrMsg := 'launch config not found: ' + ConfigFile;
    Exit;
  end;
  var Root := TJSONObject.ParseJSONValue(StripJsonc(TFile.ReadAllText(ConfigFile)));
  if not (Root is TJSONObject) then begin
    ErrMsg := 'could not parse ' + ConfigFile + ' as JSON';
    Root.Free;
    Exit;
  end;
  try
    var Configs := TJSONObject(Root).GetValue('configurations') as TJSONArray;
    if Configs = nil then begin
      ErrMsg := 'launch config has no "configurations" array';
      Exit;
    end;
    var Cfg: TJSONObject := nil;
    for var Item in Configs do begin
      if not (Item is TJSONObject) then
        Continue;
      var O := TJSONObject(Item);
      if not SameText(O.GetValue<string>('type', ''), 'delphi-win64') then
        Continue;
      if ConfigName <> '' then begin
        if SameText(O.GetValue<string>('name', ''), ConfigName) then begin
          Cfg := O; Break;
        end;
      end
      else if (WantRequest = '') or
              SameText(O.GetValue<string>('request', 'launch'), WantRequest) then begin
        Cfg := O; Break;
      end;
    end;
    if Cfg = nil then begin
      if ConfigName <> '' then
        ErrMsg := Format('no configuration named "%s" in %s', [ConfigName, ConfigFile])
      else
        ErrMsg := Format('no "delphi-win64" %s configuration in %s (pass configName to pick one)',
          [WantRequest, ConfigFile]);
      Exit;
    end;

    var WS := WorkspaceFolder;
    if WS = '' then
      WS := ExtractFileDir(ExtractFileDir(ExpandFileName(ConfigFile)));  // .vscode's parent

    F.Request    := Cfg.GetValue<string>('request', 'launch');
    F.Prog       := ResolveVars(Cfg.GetValue<string>('program', ''), WS);
    F.MapFile    := ResolveVars(Cfg.GetValue<string>('mapFile', ''), WS);
    F.RsmFile    := ResolveVars(Cfg.GetValue<string>('rsmFile', ''), WS);
    F.SourceRoot := ResolveVars(Cfg.GetValue<string>('sourceRoot', ''), WS);

    var ArgsV := Cfg.GetValue('args');
    if ArgsV is TJSONArray then begin
      var A := '';
      for var Item in TJSONArray(ArgsV) do
        A := A + ' ' + ResolveVars(Item.Value, WS);
      F.Args := Trim(A);
    end;

    var SSP := Cfg.GetValue('sourceSearchPaths');
    if SSP is TJSONArray then begin
      var Items: TArray<string> := nil;
      for var Item in TJSONArray(SSP) do
        Items := Items + [Item.Value];
      F.Extra := ExpandSearchPaths(Items, WS);
    end;

    var PidV := Cfg.GetValue('processId');
    if PidV is TJSONNumber then
      F.ProcessId := Cardinal(TJSONNumber(PidV).AsInt);
    F.ProcessName := Cfg.GetValue<string>('processName', '');
    Result := True;
  finally
    Root.Free;
  end;
end;

function LoadLaunchConfig(const ConfigFile, ConfigName, WorkspaceFolder: string;
  out Opts: TLaunchOptions; out ErrMsg: string): Boolean;
var
  F: TCfgFields;
begin
  Result := False;
  Opts   := Default(TLaunchOptions);
  if not ReadConfig(ConfigFile, ConfigName, WorkspaceFolder, 'launch', F, ErrMsg) then
    Exit;
  Opts.ExePath          := F.Prog;
  Opts.Args             := F.Args;
  Opts.MapPath          := F.MapFile;
  Opts.RsmPath          := F.RsmFile;
  Opts.SourceRoot       := F.SourceRoot;
  Opts.ExtraSourcePaths := F.Extra;
  if Opts.ExePath = '' then begin
    ErrMsg := 'launch configuration has no "program"';
    Exit;
  end;
  if Opts.MapPath = '' then Opts.MapPath := ChangeFileExt(Opts.ExePath, '.map');
  if Opts.RsmPath = '' then Opts.RsmPath := ChangeFileExt(Opts.ExePath, '.rsm');
  Result := True;
end;

function LoadAttachConfig(const ConfigFile, ConfigName, WorkspaceFolder: string;
  out Opts: TAttachOptions; out ProcessId: Cardinal; out ProcessName: string;
  out ErrMsg: string): Boolean;
var
  F: TCfgFields;
begin
  Result      := False;
  Opts        := Default(TAttachOptions);
  ProcessId   := 0;
  ProcessName := '';
  if not ReadConfig(ConfigFile, ConfigName, WorkspaceFolder, 'attach', F, ErrMsg) then
    Exit;
  Opts.ProgramPath      := F.Prog;
  Opts.MapPath          := F.MapFile;
  Opts.RsmPath          := F.RsmFile;
  Opts.SourceRoot       := F.SourceRoot;
  Opts.ExtraSourcePaths := F.Extra;
  ProcessId   := F.ProcessId;
  ProcessName := F.ProcessName;
  if (ProcessId = 0) and (ProcessName = '') then begin
    ErrMsg := 'attach configuration has neither "processId" nor "processName"';
    Exit;
  end;
  Result := True;
end;

end.
