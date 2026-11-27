program BreakpointHitCost;

{$APPTYPE CONSOLE}

// What a breakpoint that does NOT stop costs per pass, measured through the
// engine as a session drives it. Written to show that a change to the engine
// leaves the breakpoint path's cost where it was (docs/PROFILER_COVERAGE_PLAN.md,
// increment 5: "with no probes armed the engine must behave exactly as
// before"), so it uses nothing a released DebuggerCore lacks: build it against
// two versions of DebuggerCore and compare.
//
//   BreakpointHitCost -count <passes> [-n <reps>] [-timeout <s>]
//                     <source-file>:<line|MARKER> <exe> [args...]
//
// Runs <exe> to its end under a TDebugSession, alternately with no breakpoint
// and with one breakpoint on the line whose hit condition never holds
// (">= 2000000000"). Every pass through the line is then a debug event, the
// host's decision, the restore, and the single step that plants the byte
// again -- and no stop. (median with - median without) / passes is the cost of
// one pass. MARKER is the text inside a `{BP:...}` tag of the source file.
//
// Set DAP_LOG=0 before measuring: the engine's log costs more than a pass.

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Generics.Collections,
  DebugTarget,
  DebugSessionTypes,
  DebugSession;

const
  NEVER = '>= 2000000000';

type
  TOptions = record
    SourcePath: string;
    Line:       Integer;
    ExePath:    string;
    Args:       string;
    Passes:     Integer;
    Reps:       Integer;
    TimeoutSec: Integer;
  end;

procedure PrintUsage;
begin
  Writeln('Usage: BreakpointHitCost -count <passes> [-n <reps>] [-timeout <s>]');
  Writeln('                         <source-file>:<line|MARKER> <exe> [args...]');
end;

function LineOf(const SourcePath, LineOrMarker: string): Integer;
begin
  if TryStrToInt(LineOrMarker, Result) then
    Exit;
  Result := 0;
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains('{BP:' + LineOrMarker + '}') then
        Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

function QuoteArg(const Arg: string): string;
begin
  Result := Arg;
  if Arg.Contains(' ') then
    Result := '"' + Arg + '"';
end;

function ParseOptions(out Options: TOptions): Boolean;
begin
  Options := Default(TOptions);
  Options.Reps       := 5;
  Options.TimeoutSec := 120;
  var Location := '';
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    var HasValue := I < ParamCount;
    if Options.ExePath <> '' then begin
      Options.Args := (Options.Args + ' ' + QuoteArg(Arg)).Trim;
      Inc(I);
      Continue;
    end;
    if SameText(Arg, '-count') and HasValue then begin
      if not TryStrToInt(ParamStr(I + 1), Options.Passes) then
        Exit(False);
      Inc(I);
    end else if SameText(Arg, '-n') and HasValue then begin
      if not TryStrToInt(ParamStr(I + 1), Options.Reps) or (Options.Reps < 1) then
        Exit(False);
      Inc(I);
    end else if SameText(Arg, '-timeout') and HasValue then begin
      if not TryStrToInt(ParamStr(I + 1), Options.TimeoutSec) or (Options.TimeoutSec < 1) then
        Exit(False);
      Inc(I);
    end else if Arg.StartsWith('-') then
      Exit(False)
    else if Location = '' then
      Location := Arg
    else
      Options.ExePath := ExpandFileName(Arg);
    Inc(I);
  end;
  var Colon := Location.LastIndexOf(':');
  if (Colon <= 1) or (Options.ExePath = '') or (Options.Passes < 1) then
    Exit(False);
  Options.SourcePath := ExpandFileName(Location.Substring(0, Colon));
  Options.Line := LineOf(Options.SourcePath, Location.Substring(Colon + 1));
  Result := Options.Line > 0;
end;

function Median(Values: TArray<Double>): Double;
begin
  TArray.Sort<Double>(Values);
  var Mid := Length(Values) div 2;
  if Odd(Length(Values)) then
    Result := Values[Mid]
  else
    Result := (Values[Mid - 1] + Values[Mid]) / 2;
end;

// One run to the end; the time from leaving the entry stop to the exit.
function TimedRun(const Options: TOptions; WithBreakpoint: Boolean): Double;
begin
  var Session := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath             := Options.ExePath;
    Opts.Args                := Options.Args;
    Opts.SourceRoot          := ExtractFilePath(Options.SourcePath);
    Opts.StopAtEntry         := True;
    Opts.ExceptionFilters    := Default(TExceptionFilters);
    Opts.ExceptionFiltersSet := True;
    if not Session.Launch(Opts) then
      raise Exception.Create('Launch returned False');
    var Deadline := GetTickCount64 + UInt64(Options.TimeoutSec) * 1000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and (GetTickCount64 < Deadline) do
      Session.Pump;
    if Session.State <> dsStopped then
      raise Exception.Create('the program did not stop at its entry point');
    if WithBreakpoint then begin
      var Spec := Default(TBpLineSpec);
      Spec.Line         := Options.Line;
      Spec.HitCondition := NEVER;
      Session.SetBreakpoints(ExtractFileName(Options.SourcePath), [Spec]);
      Session.Pump;
    end;
    var Clock := TStopwatch.StartNew;
    Session.ContinueExecution;
    while (not Session.HasExited) and (GetTickCount64 < Deadline) do begin
      Session.Pump;
      if Session.State = dsStopped then
        raise Exception.Create('the program stopped: the hit condition held, or something else stopped it');
    end;
    Result := Clock.Elapsed.TotalMilliseconds;
    if not Session.HasExited then
      raise Exception.Create('the program did not end within the timeout');
  finally
    if not Session.HasExited then
      Session.Terminate;
    Session.Free;
  end;
end;

procedure Run(const Options: TOptions);
begin
  Writeln(Format('%s %s', [Options.ExePath, Options.Args]));
  Writeln(Format('  breakpoint on %s:%d, hit condition "%s", %d passes, %d repetitions',
    [ExtractFileName(Options.SourcePath), Options.Line, NEVER, Options.Passes, Options.Reps]));
  if GetEnvironmentVariable('DAP_LOG') = '1' then
    Writeln('  warning: DAP_LOG=1, the engine logs every event; set DAP_LOG=0 to measure');
  var Plain: TArray<Double>;
  var Broken: TArray<Double>;
  for var Rep := 1 to Options.Reps do begin
    Plain  := Plain + [TimedRun(Options, False)];
    Broken := Broken + [TimedRun(Options, True)];
  end;
  var WithoutMs := Median(Plain);
  var WithMs    := Median(Broken);
  var MinWith := Broken[0];
  for var Value in Broken do
    if Value < MinWith then
      MinWith := Value;
  Writeln(Format('  run without the breakpoint        %10.1f ms  (median)', [WithoutMs]));
  Writeln(Format('  run with it                       %10.1f ms  (median; fastest %.1f ms)', [WithMs, MinWith]));
  Writeln(Format('  one pass through the breakpoint   %10.2f us  (median)', [1000 * (WithMs - WithoutMs) / Options.Passes]));
end;

begin
  // A target that crashes must not produce a window.
  SetErrorMode(GetErrorMode or SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX);
  // Figures for the record read the same on every machine.
  FormatSettings := TFormatSettings.Invariant;
  try
    var Options: TOptions;
    if not ParseOptions(Options) then begin
      PrintUsage;
      Halt(2);
    end;
    if not FileExists(Options.ExePath) then begin
      Writeln('File not found: ', Options.ExePath);
      Halt(2);
    end;
    Run(Options);
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
