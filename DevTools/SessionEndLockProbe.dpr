program SessionEndLockProbe;

// Finds WHAT keeps a debuggee's files locked after its debug session ended.
//
// The MCP server keeps an ended TDebugSession until the next launch, so any
// file the session still holds stays locked, and rebuilding the target fails
// with F2039. This probe debugs a COPY of the given exe (with its .map/.rsm) in
// a fresh folder, ends the session -- the program runs to its end, or is
// terminated at its entry stop -- and then, with the session object still
// alive, reports:
//
//   locks    which of the files cannot be opened for exclusive writing;
//   views    every view of those files mapped into THIS process, as an image
//            (MEM_IMAGE: loaded by the loader or dbghelp) or as a plain file
//            mapping (MEM_MAPPED: a symbol reader);
//   handles  this process's open handles on those files and on the debuggee's
//            process object (via Sysinternals handle.exe, when on the PATH).
//
// It repeats the report after freeing the session, which separates what the
// session holds from what outlives it (a process-wide cache).
//
// Usage:
//   SessionEndLockProbe <fixture.exe> [end|terminate]

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.StrUtils, System.Diagnostics,
  Winapi.Windows, Winapi.PsAPI,
  DebugSessionTypes, DebugSession;

function CopyToFreshFolder(const ExePath: string): string;
begin
  var Folder := TPath.Combine(TPath.GetTempPath, 'SessionEndLockProbe-' + TGUID.NewGuid.ToString);
  TDirectory.CreateDirectory(Folder);
  for var Ext in ['.exe', '.map', '.rsm'] do
    if TFile.Exists(ChangeFileExt(ExePath, Ext)) then
      TFile.Copy(ChangeFileExt(ExePath, Ext), TPath.Combine(Folder, ChangeFileExt(ExtractFileName(ExePath), Ext)));
  Result := TPath.Combine(Folder, ExtractFileName(ExePath));
end;

function ExeIsLocked(const ExePath: string): Boolean;
begin
  var Handle := CreateFile(PChar(ExePath), GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  Result := Handle = INVALID_HANDLE_VALUE;
  if not Result then
    CloseHandle(Handle);
end;

// The kernel tears an exited process down -- and releases its image section --
// asynchronously, a moment after the last debug event. A lock seen right at the
// end of a session may be that, and not a holder in this process.
procedure ReportUnlockDelay(const ExePath: string);
const
  POLL_LIMIT_MS = 5000;
begin
  var Watch := TStopwatch.StartNew;
  while ExeIsLocked(ExePath) and (Watch.ElapsedMilliseconds < POLL_LIMIT_MS) do
    Sleep(10);
  if ExeIsLocked(ExePath) then
    Writeln(Format('  delay  .exe still locked after %d ms', [POLL_LIMIT_MS]))
  else
    Writeln(Format('  delay  .exe free after %d ms, session still alive', [Watch.ElapsedMilliseconds]));
end;

procedure ReportLocks(const ExePath: string);
begin
  for var Ext in ['.exe', '.map', '.rsm'] do begin
    var Path := ChangeFileExt(ExePath, Ext);
    if not TFile.Exists(Path) then
      Continue;
    var Handle := CreateFile(PChar(Path), GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
    var Locked := Handle = INVALID_HANDLE_VALUE;
    if not Locked then
      CloseHandle(Handle);
    Writeln(Format('  lock   %-24s %s', [ExtractFileName(Path), IfThen(Locked, 'LOCKED', 'free')]));
  end;
end;

procedure ReportMappedViews(const FolderLeaf: string);
begin
  var Address: NativeUInt := 0;
  var LastBase: Pointer := nil;
  var Info: TMemoryBasicInformation;
  while VirtualQuery(Pointer(Address), Info, SizeOf(Info)) = SizeOf(Info) do begin
    Address := NativeUInt(Info.BaseAddress) + Info.RegionSize;
    if (Info.Type_9 <> MEM_IMAGE) and (Info.Type_9 <> MEM_MAPPED) then
      Continue;
    if Info.AllocationBase = LastBase then
      Continue;
    LastBase := Info.AllocationBase;
    var Name: array[0..MAX_PATH] of Char;
    if GetMappedFileName(GetCurrentProcess, Info.AllocationBase, Name, MAX_PATH) = 0 then
      Continue;
    if not ContainsText(Name, FolderLeaf) then
      Continue;
    Writeln(Format('  view   %s at $%p  %s', [IfThen(Info.Type_9 = MEM_IMAGE, 'IMAGE ', 'MAPPED'),
      Info.AllocationBase, ExtractFileName(string(Name))]));
  end;
end;

// A handle to the debuggee's process or thread keeps the process OBJECT alive
// after it exits, and with it the image section: the .exe stays locked with no
// file handle and no view anywhere in this process. handle.exe shows such a
// handle as "<Non-existent Process>(pid)" once the process has exited.
function IsDebuggeeObjectLine(const Line, ProcessName: string; DebuggeePid: Cardinal): Boolean;
begin
  if ContainsText(Line, ProcessName + '(') then
    Exit(True);
  if not (ContainsText(Line, ' Process ') or ContainsText(Line, ' Thread ')) then
    Exit(False);
  if ContainsText(Line, 'Non-existent') then
    Exit(True);
  Result := (DebuggeePid <> 0) and ContainsText(Line, Format('(%d', [DebuggeePid]));
end;

var
  GDebuggeePid: Cardinal;
  GReportNumber: Integer;

procedure ReportHandles(const FolderLeaf, ProcessName: string);
begin
  var Output := TStringList.Create;
  try
    Inc(GReportNumber);
    var HandlesFile := TPath.Combine(TPath.GetTempPath, Format('SessionEndLockProbe.handles%d.txt', [GReportNumber]));
    var Command := Format('cmd /c handle.exe -accepteula -nobanner -a -p %d > "%s" 2>&1', [GetCurrentProcessId, HandlesFile]);
    var StartInfo := Default(TStartupInfo);
    StartInfo.cb := SizeOf(StartInfo);
    var ProcInfo: TProcessInformation;
    if not CreateProcess(nil, PChar(Command), nil, nil, False, CREATE_NO_WINDOW, nil, nil, StartInfo, ProcInfo) then begin
      Writeln('  handle (handle.exe not runnable)');
      Exit;
    end;
    WaitForSingleObject(ProcInfo.hProcess, 60000);
    CloseHandle(ProcInfo.hProcess);
    CloseHandle(ProcInfo.hThread);
    Output.LoadFromFile(HandlesFile);
    Writeln('  (all handles: ', HandlesFile, ')');
    for var Line in Output do
      if ContainsText(Line, FolderLeaf) or IsDebuggeeObjectLine(Line, ProcessName, GDebuggeePid) then
        Writeln('  handle ', Line.Trim);
  finally
    Output.Free;
  end;
end;

procedure Report(const Title, ExePath: string);
begin
  var FolderLeaf := ExtractFileName(ExtractFileDir(ExePath));
  Writeln(Title);
  ReportLocks(ExePath);
  ReportMappedViews(FolderLeaf);
  ReportHandles(FolderLeaf, ExtractFileName(ExePath));
end;

function EndSession(Session: TDebugSession; Terminate: Boolean): Boolean;
begin
  var Deadline := GetTickCount64 + 30000;
  while (Session.State <> dsStopped) and not Session.HasExited and (GetTickCount64 < Deadline) do begin
    Session.Pump;
    if GDebuggeePid = 0 then
      GDebuggeePid := Session.DebuggeeProcessId;
  end;
  if not Terminate then
    Exit(Session.HasExited);
  if Session.State <> dsStopped then
    Exit(False);
  Session.Terminate;
  Result := True;
end;

procedure Run(const SourceExe: string; Terminate: Boolean);
begin
  var ExePath := CopyToFreshFolder(SourceExe);
  Writeln('Debuggee copy: ', ExePath);
  var Session := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath     := ExePath;
    Opts.MapPath     := ChangeFileExt(ExePath, '.map');
    if TFile.Exists(ChangeFileExt(ExePath, '.rsm')) then
      Opts.RsmPath   := ChangeFileExt(ExePath, '.rsm');
    Opts.SourceRoot  := ExtractFileDir(SourceExe);
    Opts.StopAtEntry := Terminate;
    if not Session.Launch(Opts) then
      raise Exception.Create('Launch returned False');
    if not EndSession(Session, Terminate) then
      raise Exception.Create('the session did not end as asked');
    Writeln('Debuggee pid: ', GDebuggeePid);
    Report(Format('After the session ended (%s), session still alive:', [IfThen(Terminate, 'terminated', 'ran to its end')]), ExePath);
    ReportUnlockDelay(ExePath);
  finally
    Session.Free;
  end;
  Report('After the session was freed:', ExePath);
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: SessionEndLockProbe <fixture.exe> [end|terminate]');
      ExitCode := 2;
      Exit;
    end;
    Run(ExpandFileName(ParamStr(1)), SameText(ParamStr(2), 'terminate'));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
