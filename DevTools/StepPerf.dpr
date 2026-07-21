program StepPerf;

// Measures where step time actually goes in the DAP adapter.
//
// Replicates the burst of requests VS Code issues when the user presses F10:
// the step itself (request + wait for the `stopped` event), then stackTrace,
// then scopes, then the locals `variables` request, then one `evaluate` per
// watch expression. Every phase is timed separately, so it is visible whether
// the cost sits in the debug engine or in the post-stop variable evaluation.
//
// The step burst is repeated N times and reported as min / avg / max, so a
// single outlier (for example a one-time symbol load) does not hide behind an
// average.
//
// Usage: StepPerf.exe <adapter.exe> <target.exe> <source-file> <line>
//                     [-n<count>] [watch-expr ...]
//
//   <adapter.exe>  DAP adapter executable to drive
//   <target.exe>   debuggee to launch (its .map/.rsm are used when present)
//   <source-file>  source file holding the initial breakpoint
//   <line>         1-based line number of the initial breakpoint
//   -n<count>      number of step iterations to measure (default 5)
//   watch-expr     zero or more expressions evaluated after every step

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,
  System.JSON,
  System.Diagnostics,
  DapClient in '..\DebuggerTests\DapClient.pas';

const
  DefaultIterations = 5;
  StopTimeoutMs     = 120000;

type
  TPhaseSamples = record
    Name: string;
    Count: Integer;
    Min, Max, Sum: Double;
    procedure Init(const APhaseName: string);
    procedure Add(Ms: Double);
    function Avg: Double;
  end;

procedure TPhaseSamples.Init(const APhaseName: string);
begin
  Name  := APhaseName;
  Count := 0;
  Min   := 0;
  Max   := 0;
  Sum   := 0;
end;

procedure TPhaseSamples.Add(Ms: Double);
begin
  if (Count = 0) or (Ms < Min) then
    Min := Ms;
  if (Count = 0) or (Ms > Max) then
    Max := Ms;
  Sum := Sum + Ms;
  Inc(Count);
end;

function TPhaseSamples.Avg: Double;
begin
  if Count = 0 then
    Exit(0);
  Result := Sum / Count;
end;

procedure PrintLine(const S: string);
begin
  Writeln(S);
  Flush(Output);
end;

procedure PrintUsage;
begin
  PrintLine('Usage: StepPerf.exe <adapter.exe> <target.exe> <source-file> <line> [-n<count>] [watch-expr ...]');
  PrintLine('  Measures per-phase step latency: step, stackTrace, scopes, variables, one evaluate per watch.');
  PrintLine('  -n<count>  number of measured step iterations (default 5)');
end;

function DerivedFileOrEmpty(const TargetExe, Ext: string): string;
begin
  Result := ChangeFileExt(TargetExe, Ext);
  if not FileExists(Result) then
    Result := '';
end;

function CurrentLine(Client: TDapClient; out SourceName: string): Integer;
begin
  Result     := 0;
  SourceName := '';
  var Response := Client.StackTrace(1);
  try
    var Frames := Response.GetValue('stackFrames') as TJSONArray;
    if (Frames = nil) or (Frames.Count = 0) then
      Exit;
    var Frame := Frames[0] as TJSONObject;
    Result := Frame.GetValue<Integer>('line', 0);
    var Source := Frame.GetValue('source') as TJSONObject;
    if Source <> nil then
      SourceName := Source.GetValue<string>('name', '');
  finally
    Response.Free;
  end;
end;

function EvaluateWatch(Client: TDapClient; const Expr: string; FrameId: Integer): string;
begin
  try
    var Response := Client.Evaluate(Expr, FrameId, 'watch');
    try
      Result := Response.GetValue<string>('result', '');
    finally
      Response.Free;
    end;
  except
    on E: Exception do
      Result := '<' + E.ClassName + ': ' + E.Message + '>';
  end;
end;

procedure PrintPhaseTable(const Phases: TArray<TPhaseSamples>);
begin
  PrintLine(Format('%-28s %8s %8s %8s %6s', ['phase', 'min ms', 'avg ms', 'max ms', 'n']));
  PrintLine(StringOfChar('-', 62));
  var TotalMin := 0.0;
  var TotalAvg := 0.0;
  var TotalMax := 0.0;
  for var Phase in Phases do begin
    PrintLine(Format('%-28s %8.1f %8.1f %8.1f %6d',
      [Phase.Name, Phase.Min, Phase.Avg, Phase.Max, Phase.Count]));
    TotalMin := TotalMin + Phase.Min;
    TotalAvg := TotalAvg + Phase.Avg;
    TotalMax := TotalMax + Phase.Max;
  end;
  PrintLine(StringOfChar('-', 62));
  PrintLine(Format('%-28s %8.1f %8.1f %8.1f', ['TOTAL (sum of phases)', TotalMin, TotalAvg, TotalMax]));
end;

var
  GAdapterExe: string;
  GTargetExe: string;
  GSourceFile: string;
  GBreakLine: Integer;
  GIterations: Integer;
  GWatches: TArray<string>;

function ParseCommandLine: Boolean;
begin
  if ParamCount < 4 then
    Exit(False);

  GAdapterExe := ParamStr(1);
  GTargetExe  := ParamStr(2);
  GSourceFile := ParamStr(3);
  GIterations := DefaultIterations;
  GWatches    := [];

  if not TryStrToInt(ParamStr(4), GBreakLine) or (GBreakLine <= 0) then begin
    PrintLine('Invalid line number: ' + ParamStr(4));
    Exit(False);
  end;

  for var I := 5 to ParamCount do begin
    var Arg := ParamStr(I);
    if Arg.StartsWith('-n') then begin
      if not TryStrToInt(Arg.Substring(2), GIterations) or (GIterations <= 0) then begin
        PrintLine('Invalid iteration count: ' + Arg);
        Exit(False);
      end;
      Continue;
    end;
    GWatches := GWatches + [Arg];
  end;

  Result := True;
end;

procedure MeasureStepPerformance;
var
  StepPhase, StackPhase, ScopesPhase, VariablesPhase: TPhaseSamples;
  WatchPhases: TArray<TPhaseSamples>;
  WatchResults: TArray<string>;
begin
  var MapFile    := DerivedFileOrEmpty(GTargetExe, '.map');
  var RsmFile    := DerivedFileOrEmpty(GTargetExe, '.rsm');
  var SourceRoot := ExtractFileDir(GSourceFile);

  PrintLine('StepPerf');
  PrintLine('  adapter : ' + GAdapterExe);
  PrintLine('  target  : ' + GTargetExe);
  PrintLine('  map     : ' + IfThen(MapFile = '', '<none>', MapFile));
  PrintLine('  rsm     : ' + IfThen(RsmFile = '', '<none>', RsmFile));
  PrintLine(Format('  break   : %s:%d', [GSourceFile, GBreakLine]));
  PrintLine(Format('  steps   : %d', [GIterations]));
  if Length(GWatches) > 0 then
    PrintLine('  watches : ' + string.Join(', ', GWatches));
  PrintLine('');

  StepPhase.Init('step (to stopped event)');
  StackPhase.Init('stackTrace');
  ScopesPhase.Init('scopes');
  VariablesPhase.Init('variables (locals)');
  SetLength(WatchPhases, Length(GWatches));
  SetLength(WatchResults, Length(GWatches));
  for var I := 0 to High(GWatches) do
    WatchPhases[I].Init('evaluate ' + GWatches[I]);

  var Client := TDapClient.Create;
  try
    Client.Start(GAdapterExe);
    Client.Initialize.Free;
    if not Client.WaitForInitialized(StopTimeoutMs) then
      raise Exception.Create('initialize event not received');

    Client.Launch(GTargetExe, MapFile, RsmFile, SourceRoot, False, []).Free;
    Client.SetBreakpoints(GSourceFile, [GBreakLine]).Free;
    Client.ConfigDone.Free;

    PrintLine(Format('Waiting for breakpoint at %s:%d ...',
      [ExtractFileName(GSourceFile), GBreakLine]));
    Client.WaitForStopped(StopTimeoutMs).Free;

    var SourceName: string;
    var Line    := CurrentLine(Client, SourceName);
    var FrameId := Client.GetFrameId;
    PrintLine(Format('Stopped at %s:%d (frameId=%d)', [SourceName, Line, FrameId]));
    PrintLine('');

    var Completed := 0;
    for var Iteration := 1 to GIterations do begin
      var Watch := TStopwatch.StartNew;
      Client.StepOver(1).Free;
      Client.WaitForStopped(StopTimeoutMs).Free;
      var StepMs := Watch.Elapsed.TotalMilliseconds;

      Watch := TStopwatch.StartNew;
      Client.StackTrace(1).Free;
      var StackMs := Watch.Elapsed.TotalMilliseconds;

      FrameId := Client.GetFrameId;

      Watch := TStopwatch.StartNew;
      var LocalsRef := Client.GetLocalsRef(FrameId);
      var ScopesMs := Watch.Elapsed.TotalMilliseconds;

      Watch := TStopwatch.StartNew;
      if LocalsRef > 0 then
        Client.Variables(LocalsRef).Free;
      var VariablesMs := Watch.Elapsed.TotalMilliseconds;

      StepPhase.Add(StepMs);
      StackPhase.Add(StackMs);
      ScopesPhase.Add(ScopesMs);
      VariablesPhase.Add(VariablesMs);

      var WatchTotalMs := 0.0;
      for var I := 0 to High(GWatches) do begin
        Watch := TStopwatch.StartNew;
        WatchResults[I] := EvaluateWatch(Client, GWatches[I], FrameId);
        var WatchMs := Watch.Elapsed.TotalMilliseconds;
        WatchPhases[I].Add(WatchMs);
        WatchTotalMs := WatchTotalMs + WatchMs;
      end;

      Line := CurrentLine(Client, SourceName);
      Inc(Completed);

      PrintLine(Format('step #%d -> line %d | step=%.1f stack=%.1f scopes=%.1f vars=%.1f watches=%.1f | wall=%.1f ms',
        [Iteration, Line, StepMs, StackMs, ScopesMs, VariablesMs, WatchTotalMs,
         StepMs + StackMs + ScopesMs + VariablesMs + WatchTotalMs]));
      for var I := 0 to High(GWatches) do
        PrintLine(Format('    %-20s = %s', [GWatches[I], Copy(WatchResults[I], 1, 70)]));
    end;

    PrintLine('');
    PrintLine(Format('=== per-phase summary over %d step(s) ===', [Completed]));
    PrintPhaseTable([StepPhase, StackPhase, ScopesPhase, VariablesPhase] + WatchPhases);

    Client.Disconnect.Free;
  finally
    Client.Free;
  end;
end;

begin
  try
    if not ParseCommandLine then begin
      PrintUsage;
      Halt(1);
    end;
    MeasureStepPerformance;
    PrintLine('StepPerf done.');
  except
    on E: Exception do begin
      PrintLine('ERROR: ' + E.ClassName + ': ' + E.Message);
      Halt(1);
    end;
  end;
end.
