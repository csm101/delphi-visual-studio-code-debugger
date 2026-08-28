program Td32LoadBench;

{$APPTYPE CONSOLE}

// Measures what a TD32 load costs, so a change to the loader can be judged on
// numbers rather than on plausibility.
//
// Usage:
//   Td32LoadBench.exe <exe-or-bpl-path> [more paths...] [-n <iterations>]
//
// For each file it reports, per load, the wall time and the process working-set
// growth caused by that load, plus the size of the NAMES table (how many names
// the container holds) so the two can be related. Working set is sampled after
// the reader is destroyed as well, which is what exposes memory the loader
// allocated and kept rather than merely touched.
//
// Load time is dominated by parsing; the point of the memory column is the
// difference between "names materialised eagerly" and "names resolved on
// demand", so run it before and after such a change on the SAME binaries.

uses
  System.SysUtils,
  System.Diagnostics,
  Winapi.Windows,
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';

type
  TProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: SIZE_T;
    WorkingSetSize: SIZE_T;
    QuotaPeakPagedPoolUsage: SIZE_T;
    QuotaPagedPoolUsage: SIZE_T;
    QuotaPeakNonPagedPoolUsage: SIZE_T;
    QuotaNonPagedPoolUsage: SIZE_T;
    PagefileUsage: SIZE_T;
    PeakPagefileUsage: SIZE_T;
  end;

function GetProcessMemoryInfo(Process: THandle; var Counters: TProcessMemoryCounters;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll';

function WorkingSetKB: Int64;
begin
  var Counters: TProcessMemoryCounters;
  FillChar(Counters, SizeOf(Counters), 0);
  Counters.cb := SizeOf(Counters);
  if GetProcessMemoryInfo(GetCurrentProcess, Counters, SizeOf(Counters)) then
    Result := Int64(Counters.WorkingSetSize) div 1024
  else
    Result := -1;
end;

procedure Bench(const Path: string; Iterations: Integer);
begin
  Writeln;
  Writeln(Path);
  if not FileExists(Path) then begin
    Writeln('  MISSING');
    Exit;
  end;

  var TotalMs: Double := 0;
  var NamesCount: Integer := 0;
  var HeldKB: Int64 := 0;
  var Failure := '';

  for var Iteration := 1 to Iterations do begin
    var BeforeKB := WorkingSetKB;
    var Clock := TStopwatch.StartNew;
    var Reader := TTD32FileReader.Create;
    try
      try
        Reader.LoadFromFile(Path);
        Clock.Stop;
        TotalMs   := TotalMs + Clock.Elapsed.TotalMilliseconds;
        NamesCount := Reader.NamesCount;
        HeldKB     := WorkingSetKB - BeforeKB;
      except
        on E: Exception do begin
          Failure := E.Message;
          Break;
        end;
      end;
    finally
      Reader.Free;
    end;
  end;

  if Failure <> '' then begin
    Writeln('  FAILED: ', Failure);
    Exit;
  end;
  Writeln(Format('  names in container : %d', [NamesCount]));
  Writeln(Format('  load time          : %.1f ms (mean of %d)', [TotalMs / Iterations, Iterations]));
  Writeln(Format('  working set growth : %d KB while loaded', [HeldKB]));

  // Where that memory went. The total above says whether there is a problem;
  // this says which table to attack, which is the only actionable half.
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(Path);
    Writeln('  load phases:');
    for var L in Reader.DiagLoadPhases do
      Writeln(L);
    Writeln('  held by structure:');
    for var L in Reader.DiagMemoryReport do
      Writeln(L);
  finally
    Reader.Free;
  end;
end;

procedure Run;
begin
  var Paths: TArray<string>;
  var Iterations := 3;
  var I := 1;
  while I <= ParamCount do begin
    if SameText(ParamStr(I), '-n') and (I < ParamCount) then begin
      Iterations := StrToIntDef(ParamStr(I + 1), Iterations);
      Inc(I, 2);
      Continue;
    end;
    Paths := Paths + [ParamStr(I)];
    Inc(I);
  end;

  if Length(Paths) = 0 then begin
    Writeln('Usage: Td32LoadBench.exe <exe-or-bpl-path> [more paths...] [-n <iterations>]');
    Exit;
  end;
  if Iterations < 1 then
    Iterations := 1;

  for var Path in Paths do
    Bench(Path, Iterations);
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
