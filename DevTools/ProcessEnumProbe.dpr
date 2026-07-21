program ProcessEnumProbe;

// Smoke probe for the debugger's process-enumeration unit (DebuggerCore\ProcessEnum.pas).
// Lists every running process (or only those whose executable name matches an
// optional substring filter) with pid / parent pid / session / architecture /
// image path / command line, then resolves the current process and prints its
// CanDebug verdict. CanDebug(self) must be True: same process, same architecture.
// This is the end-to-end proof that the architecture decode and the PEB
// command-line walk work at runtime.
//
// Usage: ProcessEnumProbe.exe [name-substring]
// With no argument every process is listed.

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  ProcessEnum in '..\DebuggerCore\ProcessEnum.pas';

const
  UsageLine = 'Usage: ProcessEnumProbe.exe [name-substring]';

function Truncated(const S: string; MaxLength: Integer): string;
begin
  if Length(S) <= MaxLength then
    Exit(S);
  Result := Copy(S, 1, MaxLength - 3) + '...';
end;

procedure DumpProcesses(const NameFilter: string);
begin
  var Processes := EnumerateProcesses(NameFilter);

  if NameFilter = '' then
    Writeln(Format('Enumerated %d processes. Host debugger arch: %s',
      [Length(Processes), ArchToStr(HostDebuggerArch)]))
  else
    Writeln(Format('Enumerated %d processes matching "%s". Host debugger arch: %s',
      [Length(Processes), NameFilter, ArchToStr(HostDebuggerArch)]));

  Writeln(StringOfChar('-', 100));
  for var Info in Processes do begin
    Writeln(Format('pid=%-6d ppid=%-6d sess=%-2d arch=%-7s %s',
      [Info.Pid, Info.ParentPid, Info.SessionId, ArchToStr(Info.Arch), Info.ExeName]));
    if Info.ExePath <> '' then
      Writeln('    path: ' + Truncated(Info.ExePath, 90));
    if Info.CommandLine <> '' then
      Writeln('    cmd:  ' + Truncated(Info.CommandLine, 90));
  end;
end;

procedure ProbeSelf;
begin
  Writeln(StringOfChar('=', 100));

  var Info: TProcessInfo;
  if not GetProcessInfo(GetCurrentProcessId, Info) then begin
    Writeln('GetProcessInfo(self) FAILED');
    Exit;
  end;

  Writeln(Format('self pid=%d exe=%s arch=%s', [Info.Pid, Info.ExeName, ArchToStr(Info.Arch)]));
  if Info.StartTime <> 0 then
    Writeln('self start: ' + DateTimeToStr(Info.StartTime));
  Writeln('self cmd:   ' + Info.CommandLine);

  var Reason: string;
  var CanDebugSelf := CanDebug(Info, Reason);
  Writeln(Format('CanDebug(self) = %s  %s', [BoolToStr(CanDebugSelf, True), Reason]));
  if not CanDebugSelf then
    Writeln('UNEXPECTED: CanDebug(self) should be True (same process, same arch)');
end;

begin
  try
    Writeln(UsageLine);
    Writeln('Lists debuggable processes; the optional argument filters by executable name.');
    Writeln;

    if ParamCount > 1 then
      Halt(1);

    DumpProcesses(ParamStr(1));
    ProbeSelf;
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
