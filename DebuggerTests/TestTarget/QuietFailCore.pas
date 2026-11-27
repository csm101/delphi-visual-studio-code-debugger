unit QuietFailCore;

// The scenario of the QuietFail* fixtures (FixtureQuietTests): a program that
// fails on purpose, in the way its first argument names, and is run WITHOUT a
// debugger, so a test can prove that each kind of failure ends the process by
// itself and in writing -- never with a dialog waiting for a click.
//
//   -raise      an unhandled Delphi exception (raised by the program, which
//               knows whether System.SysUtils is linked)
//   -runerror   a run-time error, RunError(QUIET_FAIL_RUNTIME_ERROR)
//   -fault      an access violation on a thread with no handler at all: the
//               fault reaches the operating system's unhandled-exception path,
//               the one that shows the Windows Error Reporting dialog
//
// Deliberately free of System.SysUtils, so the fixtures built on
// FixtureQuietNoSysUtils do not link it.

interface

type
  /// <summary>Raises the program's unhandled exception.</summary>
  TRaiseProcedure = procedure;

const
  /// <summary>Run-time error number of the -runerror scenario.</summary>
  QUIET_FAIL_RUNTIME_ERROR = 204;
  /// <summary>Message of the exception the -raise scenario raises, where the
  /// exception class has one.</summary>
  QUIET_FAIL_MESSAGE = 'quiet-fail-raise';

/// <summary>Runs the scenario the first command-line argument names; with no
/// known argument the program just ends.</summary>
/// <param name="RaiseUnhandled">Raises the -raise scenario's exception.</param>
procedure RunQuietFailScenario(RaiseUnhandled: TRaiseProcedure);

implementation

uses
  Winapi.Windows;

function FaultWithoutAnyHandler(Parameter: Pointer): DWORD; stdcall;
begin
  var Target: PInteger := nil;
  Target^ := 1;
  Result := 0;
end;

procedure FaultOnAThreadWithoutHandlers;
begin
  // CreateThread, not BeginThread: the RTL's thread wrapper would catch the
  // fault, and the point is a fault nothing in the program handles.
  var ThreadId: DWORD := 0;
  var Thread := CreateThread(nil, 0, @FaultWithoutAnyHandler, nil, 0, ThreadId);
  if Thread = 0 then
    Exit;
  WaitForSingleObject(Thread, INFINITE);
end;

procedure RunQuietFailScenario(RaiseUnhandled: TRaiseProcedure);
begin
  var Scenario := ParamStr(1);
  if Scenario = '-raise' then
    RaiseUnhandled
  else if Scenario = '-runerror' then
    RunError(QUIET_FAIL_RUNTIME_ERROR)
  else if Scenario = '-fault' then
    FaultOnAThreadWithoutHandlers;
end;

end.
