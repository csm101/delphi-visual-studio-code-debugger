program WindowWatch;

{$APPTYPE CONSOLE}

// Lists every top-level window that is SHOWN, and every change of the
// foreground window, on the desktop it runs on, for as long as it runs: the
// evidence for "a test never opens a dialog and never takes the focus"
// (CLAUDE.md). Start it, run the suite or a probe beside it, then read which
// processes showed a window or took the foreground.
//
// It sees windows the moment they are shown (SetWinEventHook, out of context),
// so a console window or a message box that exists for a few milliseconds is
// listed too -- polling the window list would miss it. It does not see other
// desktops: a fixture started on a private desktop (FixtureQuietTests) is out
// of its view by design, because it is out of the user's view as well.
//
// Usage:
//   WindowWatch.exe [-seconds <n>] [-pid <process id>] [-root <dir>]
//
//   -seconds <n>   stop after n seconds (default 600)
//   -pid <id>      stop as soon as that process has ended
//   -root <dir>    mark with '*' the windows of processes whose executable lies
//                  under <dir> (typically the repository)
//
// One line per event: seconds since start, SHOW or FOREGROUND, process id,
// executable, window class, title. A console window belongs to conhost.exe,
// OpenConsole.exe or WindowsTerminal.exe, not to the console program; Windows
// Error Reporting shows its dialogs from WerFault.exe.

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils;

function QueryFullProcessImageNameW(Process: THandle; Flags: DWORD; ExeName: PWideChar;
  var Size: DWORD): BOOL; stdcall; external kernel32;

const
  // Not declared by Winapi.Windows. Enough to read the image name of any
  // process, elevated ones included.
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

var
  GStart: UInt64;
  GRoot: string;

function ImageOf(ProcessId: DWORD): string;
begin
  Result := '?';
  var Process := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, ProcessId);
  if Process = 0 then
    Exit;
  try
    var Buffer: array[0..MAX_PATH * 2] of Char;
    var Size: DWORD := Length(Buffer);
    if QueryFullProcessImageNameW(Process, 0, Buffer, Size) then
      SetString(Result, PChar(@Buffer[0]), Size);
  finally
    CloseHandle(Process);
  end;
end;

function IsTopLevel(Wnd: HWND): Boolean;
begin
  Result := GetAncestor(Wnd, GA_ROOT) = Wnd;
end;

procedure Report(const Kind: string; Wnd: HWND);
begin
  var ProcessId: DWORD := 0;
  GetWindowThreadProcessId(Wnd, ProcessId);
  var ClassName: array[0..255] of Char;
  var Title: array[0..511] of Char;
  GetClassName(Wnd, ClassName, Length(ClassName));
  GetWindowText(Wnd, Title, Length(Title));
  var Image := ImageOf(ProcessId);
  var Mark := ' ';
  if (GRoot <> '') and Image.StartsWith(GRoot, True) then
    Mark := '*';
  Writeln(Format('%s %8.3f %-10s pid %-6d %s  class=%s  title="%s"',
    [Mark, (GetTickCount64 - GStart) / 1000, Kind, ProcessId, Image, string(ClassName), string(Title)]));
  Flush(Output);
end;

procedure OnWinEvent(Hook: THandle; Event: DWORD; Wnd: HWND; IdObject, IdChild: Longint;
  EventThread, EventTime: DWORD); stdcall;
begin
  if (Wnd = 0) or (IdObject <> OBJID_WINDOW) or (IdChild <> CHILDID_SELF) then
    Exit;
  if not IsTopLevel(Wnd) then
    Exit;
  if Event = EVENT_SYSTEM_FOREGROUND then
    Report('FOREGROUND', Wnd)
  else
    Report('SHOW', Wnd);
end;

function ArgValue(const Name, Default: string): string;
begin
  Result := Default;
  for var I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), Name) then
      Exit(ParamStr(I + 1));
end;

begin
  try
    var Seconds := StrToIntDef(ArgValue('-seconds', '600'), 600);
    var WatchedPid := StrToIntDef(ArgValue('-pid', '0'), 0);
    GRoot := ArgValue('-root', '');
    if GRoot <> '' then
      GRoot := IncludeTrailingPathDelimiter(ExpandFileName(GRoot));
    var Watched: THandle := 0;
    if WatchedPid <> 0 then
      Watched := OpenProcess(SYNCHRONIZE, False, WatchedPid);

    GStart := GetTickCount64;
    var Flags := WINEVENT_OUTOFCONTEXT or WINEVENT_SKIPOWNPROCESS;
    var ShowHook := SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, 0, @OnWinEvent, 0, 0, Flags);
    var ForegroundHook := SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, 0, @OnWinEvent, 0, 0, Flags);
    if (ShowHook = 0) or (ForegroundHook = 0) then
      raise Exception.Create('SetWinEventHook failed: ' + SysErrorMessage(GetLastError));
    var StopNote := '';
    if WatchedPid <> 0 then
      StopNote := Format(' or until pid %d ends', [WatchedPid]);
    Writeln(Format('WindowWatch: watching for %d s%s', [Seconds, StopNote]));
    Flush(Output);

    var Deadline := GStart + UInt64(Seconds) * 1000;
    while GetTickCount64 < Deadline do begin
      // Out-of-context hooks are delivered through this thread's message queue.
      var Handles: array[0..0] of THandle;
      var HandleCount: DWORD := 0;
      if Watched <> 0 then begin
        Handles[0] := Watched;
        HandleCount := 1;
      end;
      var Woken := MsgWaitForMultipleObjects(HandleCount, Handles, False, 200, QS_ALLINPUT);
      if (Watched <> 0) and (Woken = WAIT_OBJECT_0) then
        Break;
      var Msg: TMsg;
      while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
        DispatchMessage(Msg);
    end;
    UnhookWinEvent(ShowHook);
    UnhookWinEvent(ForegroundHook);
    Writeln(Format('WindowWatch: stopped after %.1f s', [(GetTickCount64 - GStart) / 1000]));
  except
    on E: Exception do begin
      Writeln('WindowWatch: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
