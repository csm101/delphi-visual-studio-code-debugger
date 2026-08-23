program DapSessionTiming;
// Measures the fixed cost of ONE integration-test debug session, phase by phase.
//
// The DebuggerTests suite creates ~1200 sessions, each of which spawns an
// adapter process, spawns a debuggee, loads symbols, stops at a breakpoint and
// tears everything down. This probe reproduces exactly that sequence with the
// SAME client code the suite uses (DebuggerTests\DapClient.pas) and reports
// where the milliseconds go.
//
// Usage:
//   DapSessionTiming.exe [iterations] [bp-marker]
//
// Defaults: 10 iterations, marker EVAL_BODY.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Math,
  System.Generics.Collections,
  Winapi.Windows,
  DapClient in '..\DebuggerTests\DapClient.pas',
  // DapClient stages its exception rules into a scratch directory, and that
  // directory's lifetime rules live here rather than in five copies.
  TestTempDirs in '..\DebuggerTests\TestTempDirs.pas';

type
  TPhase = (phAdapterSpawn, phInitialize, phSetBreakpoints, phSetExcBreakpoints,
            phLaunch, phConfigDone, phWaitStopped, phStackTrace, phScopes,
            phVariables, phDisconnect, phStopProcess);

const
  PhaseName: array[TPhase] of string = (
    'adapter spawn (CreateProcess)',
    'initialize + initialized event',
    'setBreakpoints',
    'setExceptionBreakpoints',
    'launch (debuggee spawn + symbol load)',
    'configurationDone',
    'wait stopped event (run to BP)',
    'stackTrace',
    'scopes',
    'variables (locals)',
    'disconnect',
    'terminate adapter + join reader');

var
  Totals: array[TPhase] of Double;

function UpDirs(const APath: string; Levels: Integer): string;
begin
  Result := ExcludeTrailingPathDelimiter(APath);
  for var I := 1 to Levels do
    Result := ExtractFileDir(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

var
  Root:      string;
  AdapterExe:string;
  TargetDir: string;
  TargetExe: string;
  TargetMap: string;
  TargetRsm: string;
  Iterations:Integer;
  Marker:    string;
  Freq:      Int64;

function NowMs: Double;
var C: Int64;
begin
  QueryPerformanceCounter(C);
  Result := C * 1000.0 / Freq;
end;

procedure RunOne;
var
  C:   TDapClient;
  T0:  Double;

  procedure Mark(P: TPhase);
  var T1: Double;
  begin
    T1 := NowMs;
    Totals[P] := Totals[P] + (T1 - T0);
    T0 := T1;
  end;

var
  BpLine:    Integer;
  Stopped:   TJSONObject;
  FrameId:   Integer;
  LocalsRef: Integer;
begin
  BpLine := FindBpLine(TargetDir + 'TestTargetCore.pas', Marker);
  if BpLine = 0 then begin
    BpLine := FindBpLine(TargetDir + 'TestTarget.dpr', Marker);
    if BpLine = 0 then
      raise Exception.Create('marker not found: ' + Marker);
  end;

  C := TDapClient.Create;
  try
    T0 := NowMs;
    C.Start(AdapterExe);
    Mark(phAdapterSpawn);

    C.Initialize.Free;
    if not C.WaitForInitialized then
      raise Exception.Create('no initialized event');
    Mark(phInitialize);

    C.SetBreakpoints(TargetDir + 'TestTargetCore.pas', [BpLine]).Free;
    Mark(phSetBreakpoints);

    C.SetExceptionBreakpoints([]).Free;
    Mark(phSetExcBreakpoints);

    C.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False).Free;
    Mark(phLaunch);

    C.ConfigDone.Free;
    Mark(phConfigDone);

    Stopped := C.WaitForStopped;
    Stopped.Free;
    Mark(phWaitStopped);

    FrameId := C.GetFrameId;
    Mark(phStackTrace);

    LocalsRef := C.GetLocalsRef(FrameId);
    Mark(phScopes);

    C.Variables(LocalsRef).Free;
    Mark(phVariables);

    try
      C.Disconnect.Free;
    except
    end;
    Mark(phDisconnect);
  finally
    T0 := NowMs;
    C.Stop;
    C.Free;
    Mark(phStopProcess);
  end;
end;

var
  Total: Double;
begin
  try
    QueryPerformanceFrequency(Freq);

    Root       := UpDirs(ExtractFilePath(ParamStr(0)), 3);   // ...\DevTools\Win64\Debug -> repo
    AdapterExe := Root + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
    TargetDir  := Root + 'DebuggerTests\TestTarget\';
    TargetExe  := TargetDir + 'Win64\Debug\TestTarget.exe';
    TargetMap  := TargetDir + 'Win64\Debug\TestTarget.map';
    TargetRsm  := TargetDir + 'Win64\Debug\TestTarget.rsm';

    Iterations := StrToIntDef(ParamStr(1), 10);
    Marker     := ParamStr(2);
    if Marker = '' then Marker := 'EVAL_BODY';

    if not FileExists(AdapterExe) then begin
      Writeln('adapter not found: ', AdapterExe);
      Halt(2);
    end;
    if not FileExists(TargetExe) then begin
      Writeln('target not found: ', TargetExe);
      Halt(2);
    end;

    Writeln('adapter : ', AdapterExe);
    Writeln('target  : ', TargetExe);
    Writeln('marker  : ', Marker);
    Writeln('iters   : ', Iterations);
    Writeln;

    // One warm-up run so file-cache effects don't land in the average.
    RunOne;
    for var P := Low(TPhase) to High(TPhase) do Totals[P] := 0;

    var WallStart := NowMs;
    for var I := 1 to Iterations do
      RunOne;
    var Wall := NowMs - WallStart;

    Total := 0;
    for var P := Low(TPhase) to High(TPhase) do Total := Total + Totals[P];

    Writeln(Format('%-42s %9s %7s', ['phase', 'ms/iter', '%']));
    Writeln(StringOfChar('-', 62));
    for var P := Low(TPhase) to High(TPhase) do
      Writeln(Format('%-42s %9.1f %6.1f%%',
        [PhaseName[P], Totals[P] / Iterations, 100 * Totals[P] / Total]));
    Writeln(StringOfChar('-', 62));
    Writeln(Format('%-42s %9.1f', ['TOTAL per session', Total / Iterations]));
    Writeln(Format('%-42s %9.1f', ['wall per session', Wall / Iterations]));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
