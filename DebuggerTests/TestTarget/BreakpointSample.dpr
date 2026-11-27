program BreakpointSample;

// Fixture for WHERE a source breakpoint is planted (DebuggerCore\
// WinDebuggerBase.pas, PlantInt3 / DoSetBreakpoints, and DebuggerCore\
// LiveCodeAnalysis.pas; docs/DAP_DEBUGGER_ARCHITECTURE.md, "Breakpoints").
// Each routine is a shape where "one address per line" is the wrong answer or
// where two breakpoint records end up on one address:
//
//   * FinallyBothWays    -- a `finally` block the program runs twice: by
//                           falling into it, and because an exception passes
//                           through. dcc64 emits the block twice (inline, and
//                           as a funclet the exception dispatch calls); dcc32
//                           emits it once;
//   * ImplicitFinally    -- the same for the cleanup of a managed local, whose
//                           source line is the routine's `end;`;
//   * ForLoop            -- a `for` line has two records as well (the
//                           initialisation and the loop-back test) and must
//                           stop ONCE per entry into the loop;
//   * ForInFinally       -- both at once: a loop inside a finally block;
//   * ExitThroughFinally -- a finally block left by `Exit`;
//   * NestedFinally      -- a try..finally inside the try of another;
//   * FinallyInFinally   -- a try..finally inside the finally of another;
//   * WithAnonymous      -- an anonymous method, whose body has NO procedure
//                           record in TD32: on x86 only a MAP names it;
//   * TwoLinesOneAddress -- a breakpoint on `begin` is moved to the first
//                           statement, so both lines resolve to one address.
//
// The main block runs each of them a known number of times, so a test can
// count its stops.
//
// With a command-line switch the program runs ONE other scenario instead, and
// checks its own arithmetic: it exits with code 3 when a sum is wrong. Those
// are about what happens to the breakpoint BYTE while threads run through it
// (docs/DAP_DEBUGGER_ARCHITECTURE.md, "Persistent breakpoint re-arming"):
//
//   -loop      a loop of two lines, for a breakpoint set on the line the
//              thread is resumed from;
//   -recurse   a recursion whose return address is the start of a line, for a
//              step-out to the address the thread is already at;
//   -two       two threads, each through a line of its own;
//   -race      four threads through ONE line, released together;
//   -spin      the main thread through a line while a second thread spins in a
//              two-line loop that can be stepped;
//   -fault     a line whose instruction raises an access violation, which
//              the program catches: a breakpoint on an instruction that never
//              completes;
//   -lib       loads BreakpointSampleLib.dll after reserving its preferred
//              base, so that the loader has to relocate it;
//   -wait-debugger   first wait for a debugger to attach.
//
// Every instruction under a breakpoint in those scenarios starts by loading the
// global GStep. That is on purpose: resumed from its second byte, a `mov` from
// a frame slot can compute the right value by luck (measured on x86, where the
// register still held it); the bytes of an absolute address cannot.
//
// Separate target on purpose. Adding scenarios to TestTarget shifts RSM
// per-unit import indices and perturbs first-hit marker ordering, which has
// broken unrelated tests before (docs/TRAPS.md, "Fixture design").
//
// GUI subsystem and deliberately silent: it is launched by the test runner,
// which drives TDebugSession directly, and nothing here should reach a console.

{$O-}

uses
  FixtureQuiet, System.SysUtils, Winapi.Windows;

const
  // The tests count on these numbers.
  TWO_PASSES   = 150;
  RACE_THREADS = 4;
  RACE_PASSES  = 100;
  SPIN_PASSES  = 5;
  LOOP_PASSES  = 5;
  FAULT_PASSES = 4;
  RECURSE_DEPTH = 3;
  // BreakpointSampleLib's fixed image base, and what its LibRun returns.
  LIB_PREFERRED_BASE = $3A000000;
  LIB_EXPECTED       = 437;
  EXIT_WRONG_SUM     = 3;
  EXIT_NO_LIBRARY    = 4;

var
  GSink: Integer = 0;
  // The scenarios behind a switch.
  GStep:     Integer = 3;
  GAcc:      Integer = 0;
  GBad:      Integer = 0;
  GGo:       Boolean = False;
  GStopSpin: Boolean = False;

{ ------------------------------------------------------- finally blocks -- }

procedure FinallyBothWays(Fail: Boolean);
begin
  Inc(GSink);                                // {BP:BS_FINALLY_BEFORE}
  try
    if Fail then
      raise EAbort.Create('through');        // {BP:BS_FINALLY_RAISE}
    Inc(GSink, 2);
  finally
    GSink := GSink * 3;                      // {BP:BS_FINALLY_BLOCK}
  end;
end;

// Twice through the block: once the plain way, once on an exception.
procedure RunFinallyBothWays;
begin
  FinallyBothWays(False);                    // {BP:BS_FINALLY_PLAIN_CALL}
  try
    FinallyBothWays(True);
  except
    on E: EAbort do
      Inc(GSink);                            // {BP:BS_FINALLY_CAUGHT}
  end;
end;

// The cleanup of S is a finally block the compiler writes; its line is `end;`.
function ImplicitFinally(Fail: Boolean): Integer;
var
  S: string;
begin
  S := IntToStr(GSink);
  if Fail then
    raise EAbort.Create(S);
  Result := Length(S);                       // {BP:BS_IMPLICIT_LAST}
end;                                         // {BP:BS_IMPLICIT_END}

procedure RunImplicitFinally;
begin
  GSink := GSink + ImplicitFinally(False);
  try
    GSink := GSink + ImplicitFinally(True);
  except
    on E: EAbort do
      Inc(GSink);
  end;
end;

procedure ExitThroughFinally(Early: Boolean);
begin
  try
    if Early then
      Exit;                                  // {BP:BS_EXIT_EARLY}
    Inc(GSink);
  finally
    Inc(GSink, 5);                           // {BP:BS_EXIT_FINALLY}
  end;
end;

procedure NestedFinally(Fail: Boolean);
begin
  try
    try
      if Fail then
        raise EAbort.Create('nested');
    finally
      Inc(GSink, 7);                         // {BP:BS_NESTED_INNER}
    end;
  finally
    Inc(GSink, 11);                          // {BP:BS_NESTED_OUTER}
  end;
end;

procedure RunNestedFinally;
begin
  NestedFinally(False);
  try
    NestedFinally(True);
  except
    on E: EAbort do
      Inc(GSink);
  end;
end;

procedure FinallyInFinally(Fail: Boolean);
begin
  try
    if Fail then
      raise EAbort.Create('outer');
  finally
    try
      Inc(GSink);
    finally
      Inc(GSink, 13);                        // {BP:BS_FINALLY_IN_FINALLY}
    end;
  end;
end;

procedure RunFinallyInFinally;
begin
  FinallyInFinally(False);
  try
    FinallyInFinally(True);
  except
    on E: EAbort do
      Inc(GSink);
  end;
end;

{ ------------------------------------------------------------------ loops -- }

procedure ForLoop(Count: Integer);
var
  I: Integer;
begin
  Inc(GSink);                                // {BP:BS_FOR_BEFORE}
  for I := 1 to Count do                     // {BP:BS_FOR_LINE}
    Inc(GSink, I);                           // {BP:BS_FOR_BODY}
  Inc(GSink);                                // {BP:BS_FOR_AFTER}
end;

procedure ForInFinally(Fail: Boolean);
var
  I: Integer;
begin
  try
    if Fail then
      raise EAbort.Create('loop');
  finally
    for I := 1 to 3 do                       // {BP:BS_FOR_IN_FINALLY}
      Inc(GSink, I);
  end;
end;

procedure RunForInFinally;
begin
  ForInFinally(False);
  try
    ForInFinally(True);
  except
    on E: EAbort do
      Inc(GSink);
  end;
end;

{ ------------------------------------------------------- anonymous method -- }

// A capturing closure lives in its OWN routine: inside another one it would
// relocate that routine's frame (docs/TRAPS.md, "Fixture design").
function WithAnonymous(Value: Integer): Integer;
var
  Triple: TFunc<Integer, Integer>;
begin
  Triple := function(X: Integer): Integer
    begin
      Result := X * 3 + Value;               // {BP:BS_ANON_BODY}
    end;
  Result := Triple(7) + Triple(8);           // {BP:BS_ANON_CALL}
end;

{ --------------------------------------------- two lines, one address -- }

procedure TwoLinesOneAddress(Value: Integer);
begin                                        // {BP:BS_SHARED_BEGIN}
  GSink := GSink + Value;                    // {BP:BS_SHARED_FIRST}
  GSink := GSink xor 1;                      // {BP:BS_SHARED_SECOND}
end;

procedure RunShared;
var
  K: Integer;
begin
  for K := 1 to 6 do begin
    TwoLinesOneAddress(K);                   // {BP:BS_SHARED_CALL}
    Inc(GSink);                              // {BP:BS_SHARED_BETWEEN}
  end;
end;

{ ------------------------------------- the byte under a running thread -- }

procedure LoopTwoLines;
var
  I: Integer;
begin
  for I := 1 to LOOP_PASSES do begin
    GAcc := GStep + GAcc;                    // {BP:BS_LOOP_FIRST}
    GAcc := GAcc xor 1;                      // {BP:BS_LOOP_SECOND}
  end;
end;

procedure RunLoop;
begin
  GAcc := 0;
  LoopTwoLines;
  // The compiler works the expected value out: the same statements, untouched
  // by any breakpoint.
  var Expected := 0;
  for var I := 1 to LOOP_PASSES do begin
    Expected := GStep + Expected;
    Expected := Expected xor 1;
  end;
  if GAcc <> Expected then
    Halt(EXIT_WRONG_SUM);
end;

// The call is the last instruction of its line, so the address it returns to
// is the first instruction of the next one.
procedure Recurse(Depth: Integer);
begin
  if Depth > 0 then                          // {BP:BS_RECURSE_IF}
    Recurse(Depth - 1);                      // {BP:BS_RECURSE_CALL}
  GAcc := GStep + GAcc + Depth;              // {BP:BS_RECURSE_AFTER}
end;

procedure RunRecurse;
begin
  GAcc := 0;
  Recurse(RECURSE_DEPTH);
  var Expected := 0;
  for var Depth := 0 to RECURSE_DEPTH do
    Expected := GStep + Expected + Depth;
  if GAcc <> Expected then
    Halt(EXIT_WRONG_SUM);
end;

function BumpA(Value: Integer): Integer;
begin
  Result := GStep + Value;                   // {BP:BS_TWO_A}
end;

function BumpB(Value: Integer): Integer;
begin
  Result := GStep + Value;                   // {BP:BS_TWO_B}
end;

function WorkerA(Param: Pointer): Integer;
var
  I, Total: Integer;
begin
  while not GGo do
    ;
  Total := 0;
  for I := 1 to TWO_PASSES do
    Total := BumpA(Total);
  if Total <> TWO_PASSES * GStep then
    InterlockedIncrement(GBad);
  Result := 0;
end;

function WorkerB(Param: Pointer): Integer;
var
  I, Total: Integer;
begin
  while not GGo do
    ;
  Total := 0;
  for I := 1 to TWO_PASSES do
    Total := BumpB(Total);
  if Total <> TWO_PASSES * GStep then
    InterlockedIncrement(GBad);
  Result := 0;
end;

function RaceBump(Value: Integer): Integer;
begin
  Result := GStep + Value;                   // {BP:BS_RACE_LINE}
end;

// Called by the debugger at a stop, never by the program's own flow.
function RaceProbe: Integer;
begin
  Result := GStep * 2;
end;

function RaceWorker(Param: Pointer): Integer;
var
  I, Total: Integer;
begin
  while not GGo do
    ;
  Total := 0;
  for I := 1 to RACE_PASSES do
    Total := RaceBump(Total);
  if Total <> RACE_PASSES * GStep then
    InterlockedIncrement(GBad);
  Result := 0;
end;

// Starts the workers, releases them together and waits for them.
procedure RunWorkers(const Workers: array of TThreadFunc);
var
  Handles: array[0..15] of THandle;
  ThreadId: TThreadID;
begin
  GBad := 0;
  GGo  := False;
  for var I := 0 to High(Workers) do
    Handles[I] := BeginThread(nil, 0, Workers[I], nil, 0, ThreadId);
  Sleep(50);
  GGo := True;                               // {BP:BS_WORKERS_GO}
  WaitForMultipleObjects(Length(Workers), @Handles[0], True, INFINITE);
  for var I := 0 to High(Workers) do
    CloseHandle(Handles[I]);
  if GBad <> 0 then
    Halt(EXIT_WRONG_SUM);
end;

procedure RunTwo;
begin
  RunWorkers([WorkerA, WorkerB]);
end;

procedure RunRace;
begin
  // Referenced, so that the linker keeps what only the debugger calls.
  if RaceProbe <> GStep * 2 then
    Halt(EXIT_WRONG_SUM);
  RunWorkers([RaceWorker, RaceWorker, RaceWorker, RaceWorker]);
end;

procedure SpinTarget(Value: Integer);
begin
  GAcc := GStep + GAcc + Value;              // {BP:BS_SPIN_LINE}
end;

// Two lines, so that a source-level step of this thread lands at once.
function Spinner(Param: Pointer): Integer;
var
  Local: Integer;
begin
  Local := 0;
  while not GStopSpin do begin
    Inc(Local);                              // {BP:BS_SPINNER_FIRST}
    Dec(Local);                              // {BP:BS_SPINNER_SECOND}
  end;
  Result := Local;
end;

procedure RunSpin;
var
  ThreadId: TThreadID;
begin
  GAcc := 0;
  GStopSpin := False;
  var Handle := BeginThread(nil, 0, Spinner, nil, 0, ThreadId);
  Sleep(50);
  for var K := 1 to SPIN_PASSES do
    SpinTarget(K);
  GStopSpin := True;                         // {BP:BS_SPIN_DONE}
  WaitForSingleObject(Handle, INFINITE);
  CloseHandle(Handle);
  var Expected := 0;
  for var K := 1 to SPIN_PASSES do
    Expected := GStep + Expected + K;
  if GAcc <> Expected then
    Halt(EXIT_WRONG_SUM);
end;

{ ----------------------------------- an instruction that never completes -- }

// The second line reads through a nil pointer: the FIRST instruction of the
// line is the one that faults, which no Pascal statement guarantees.
procedure FaultOnItsSecondLine;
{$IFDEF CPUX64}
asm
        .NOFRAME
        XOR     EAX, EAX
        MOV     EAX, DWORD PTR [RAX]         // {BP:BS_FAULT_LINE_64}
        RET
end;
{$ELSE}
asm
        XOR     EAX, EAX
        MOV     EAX, DWORD PTR [EAX]         // {BP:BS_FAULT_LINE_32}
        RET
end;
{$ENDIF}

procedure RunFault;
begin
  GAcc := 0;
  for var K := 1 to FAULT_PASSES do
    try
      FaultOnItsSecondLine;
    except
      on E: EAccessViolation do
        GAcc := GStep + GAcc;
    end;
  if GAcc <> FAULT_PASSES * GStep then
    Halt(EXIT_WRONG_SUM);
end;

{ ---------------------------------------- a module the loader relocates -- }

type
  TLibRun = function: Integer; stdcall;

procedure RunLib;
begin
  // The DLL has a fixed base and no dynamic base. With that address taken the
  // loader maps it elsewhere and relocates it -- after the load event a
  // debugger sees, and before the DLL's entry point.
  VirtualAlloc(Pointer(LIB_PREFERRED_BASE), $10000, MEM_RESERVE, PAGE_NOACCESS);
  var Handle := LoadLibrary(PChar(ExtractFilePath(ParamStr(0)) + 'BreakpointSampleLib.dll'));
  if Handle = 0 then
    Halt(EXIT_NO_LIBRARY);
  var LibRun: TLibRun;
  @LibRun := GetProcAddress(Handle, 'LibRun');
  if not Assigned(LibRun) then
    Halt(EXIT_NO_LIBRARY);
  if LibRun() <> LIB_EXPECTED then           // {BP:BS_LIB_CALL}
    Halt(EXIT_WRONG_SUM);
end;

procedure WaitForADebugger;
begin
  for var Round := 1 to 2000 do begin
    if IsDebuggerPresent then
      Break;
    Sleep(10);
  end;
  // Long enough for the breakpoints it sets right after attaching.
  Sleep(300);
end;

// True when a scenario behind a switch ran: the default run is skipped then.
function RunSwitchedScenario: Boolean;
begin
  Result := True;
  if FindCmdLineSwitch('wait-debugger') then
    WaitForADebugger;
  if FindCmdLineSwitch('loop') then
    RunLoop
  else if FindCmdLineSwitch('recurse') then
    RunRecurse
  else if FindCmdLineSwitch('two') then
    RunTwo
  else if FindCmdLineSwitch('race') then
    RunRace
  else if FindCmdLineSwitch('spin') then
    RunSpin
  else if FindCmdLineSwitch('fault') then
    RunFault
  else if FindCmdLineSwitch('lib') then
    RunLib
  else
    Result := False;
end;

begin
  if RunSwitchedScenario then
    Exit;
  GSink := 1;                                // {BP:BS_MAIN_FIRST}
  RunShared;
  RunFinallyBothWays;
  RunImplicitFinally;
  ExitThroughFinally(False);
  ExitThroughFinally(True);
  RunNestedFinally;
  RunFinallyInFinally;
  ForLoop(3);
  ForLoop(2);
  RunForInFinally;
  GSink := GSink + WithAnonymous(4);
  // Keeps the global live so no store above is elided (docs/TRAPS.md: "a local
  // nothing ever reads gets its store ELIDED even under -$O-").
  if GSink = MaxInt then                     // {BP:BS_MAIN_LAST}
    Halt(1);
end.
