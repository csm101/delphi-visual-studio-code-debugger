program ProfilerSample;

// Fixture for the one-shot line probes (DebuggerCore\CodePatchMap.pas,
// DebuggerCore\LineProbes.pas; docs/DAP_DEBUGGER_ARCHITECTURE.md, "Code
// patches"). A probe is a $CC the debugger writes on the first byte of a line
// record, takes away at its first hit and records: which lines of a program
// ran.
//
// THE PROGRAM KEEPS ITS OWN RECORD. Every statement `Ran(n)` stands alone on
// its line and sets GRan[n], so a test can compare what the probes recorded
// with what the program says it executed, line for line -- the lines that ran
// AND the ones that did not. Ran also folds n into GSink, which the program
// writes out with the record: a probe that makes an instruction run twice, not
// at all, or from its second byte changes that number even when the program
// then ends normally (docs/TRAPS.md, "An instruction resumed from its second
// byte can run without a trace").
//
// The default run goes through the shapes a line table gets interesting on
// (branches, a `case`, the three loops, `finally` blocks run plainly, by an
// exception and only by an exception, an `except` block that is never entered,
// recursion, a nested routine, an anonymous method, a virtual method, a
// routine nothing calls, the program's OWN `int 3`), then through the routines
// the stepping and layering tests stop in, and writes the record to the file
// named by `-out <path>`.
//
// With a switch it runs ONE other scenario instead and checks its own
// arithmetic, exiting with code 3 when a sum is wrong:
//
//   -race [n]     n threads (default 4), released together, each through
//                 LongRun: a long run of lines that have never executed, so
//                 that two threads meet at every one of its probes;
//   -pkg          loads TestPackage.bpl, unloads it, loads it again and calls
//                 one routine of it that the first load did not run;
//   -lib          loads BreakpointSampleLib.dll after reserving its preferred
//                 base, so that the loader relocates it after its load event;
//   -steprace     a call the debugger steps over on the main thread while a
//                 second thread runs through a line that carries a logpoint;
//   -spin <n>     one line run n times (default 1000), for timing what a
//                 breakpoint that does not stop costs per pass
//                 (DevTools\BreakpointHitCost);
//   -hot          four threads round one line until no debugger is attached
//                 (a detach at a pause stop with traps queued behind it);
//   -softbreak    a thread that raises EXCEPTION_BREAKPOINT through
//                 RaiseException and catches it, until no debugger is
//                 attached; every one raised must have been caught;
//   -rewrite      the program writes over two bytes of its own code, as a
//                 hooking library does, then runs them;
//   -pkgeval      loads TestPackage.bpl, waits at a line where the debugger
//                 unloads it by evaluating DropPackageForEval, then loads it
//                 again and calls one routine of it; with -pkgmove as well,
//                 the address of the first mapping is reserved first, so that
//                 the second one is mapped elsewhere.
//
// Two more switches change WHEN things run and combine with the others:
//
//   -wait-debugger   first wait for a debugger to attach;
//   -wait-detach     in the default run, wait in the middle until no debugger
//                    is attached any more: the second half then runs through
//                    lines whose probes a clean detach must have taken back.
//
// Separate target on purpose: adding scenarios to TestTarget shifts RSM
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
  MAX_MARK       = 127;
  LONG_RUN_LINES = 160;
  LAYER_PASSES   = 5;
  STEP_RACE_TICKS = 20;
  DEFAULT_RACE_THREADS = 4;
  MAX_RACE_THREADS     = 16;
  // BreakpointSampleLib's fixed image base, and what its LibRun returns.
  LIB_PREFERRED_BASE = $3A000000;
  LIB_EXPECTED       = 437;
  EXIT_WRONG_SUM     = 3;
  EXIT_NO_LIBRARY    = 4;
  EXIT_NO_OUTPUT     = 5;

var
  // The program's own record: GRan[n] is 1 once `Ran(n)` has executed.
  GRan:  array[0..MAX_MARK] of Byte;
  GSink: Integer = 1;
  GStep: Integer = 3;
  GEval: Integer = 0;
  GNone: Integer = 0;
  GBad:  Integer = 0;
  GGo:   Boolean = False;
  GWorkerGo: Boolean = False;
  // Keeps a routine nothing calls in the image.
  GKeep: Pointer = nil;

procedure Ran(Index: Integer);
begin
  GRan[Index] := 1;
  GSink := GSink * 31 + Index;
end;

// For lines a second thread runs: GSink belongs to the main thread.
procedure RanByAThread(Index: Integer);
begin
  GRan[Index] := 1;
end;

// Code the program rewrites (-rewrite, RunRewrite). Here, pages away from
// RunRewrite on purpose: a stop in RunRewrite reads the code around it (the
// stack walk), and the test needs this routine's bytes not to have been read
// when it plants a breakpoint here.
procedure Rewritable1;
{$IFDEF CPUX64}
asm
        .NOFRAME
        NOP
        CLC                                  // {BP:PS_REWRITE1_64}
        RET
end;
{$ELSE}
asm
        NOP
        CLC                                  // {BP:PS_REWRITE1_32}
        RET
end;
{$ENDIF}

{ ----------------------------------------------------------- the shapes -- }

procedure Branches(X: Integer);
begin
  Ran(1);
  if X > 0 then
    Ran(2)
  else
    Ran(3);
  case X of
    1:
      Ran(4);
    2:
      Ran(5);
    7:
      Ran(6);
  else
    Ran(7);
  end;
end;

procedure Loops(Count: Integer);
var
  I: Integer;
begin
  for I := 1 to Count do
    Ran(8);
  I := 0;
  while I < Count do begin
    Ran(9);
    Inc(I);
  end;
  repeat
    Ran(10);
    Dec(I);
  until I <= 0;
  // A loop whose body never runs (the bound is a variable, or the compiler
  // would delete the loop and the line would have no code at all).
  for I := 1 to GNone do
    Ran(11);
end;

procedure FinallyBlock(Fail: Boolean);
begin
  Ran(12);
  try
    if Fail then
      raise EAbort.Create('through');
    Ran(13);
  finally
    Ran(14);
  end;
  Ran(15);
end;

// Twice through the block: once the plain way, once on an exception.
procedure RunFinally;
begin
  FinallyBlock(False);
  try
    FinallyBlock(True);
  except
    on E: EAbort do
      Ran(16);
  end;
end;

// On x64 this block exists inline and as a funclet, and only the funclet runs.
procedure FinallyOnlyByException;
begin
  try
    Ran(17);
    raise EAbort.Create('only');
  finally
    Ran(18);
  end;
  Ran(19);
end;

procedure ExceptNotTaken;
begin
  try
    Ran(21);
  except
    Ran(22);
  end;
end;

procedure NeverCalled;
begin
  Ran(23);
end;

function Factorial(N: Integer): Integer;
begin
  if N <= 1 then begin
    Ran(24);
    Exit(1);
  end;
  Ran(25);
  Result := N * Factorial(N - 1);
end;

procedure Outer;

  procedure Inner(K: Integer);
  begin
    Ran(26);
    if K > 5 then
      Ran(27);
  end;

begin
  Inner(1);
  Ran(28);
end;

// A capturing closure lives in its OWN routine: inside another one it would
// relocate that routine's frame (docs/TRAPS.md, "Fixture design"). Its body
// has no procedure record in TD32: on x86 only a MAP names it.
function WithAnonymous(Value: Integer): Integer;
var
  Add: TFunc<Integer, Integer>;
begin
  Add := function(X: Integer): Integer
    begin
      Ran(29);
      Result := X + Value;
    end;
  Ran(30);
  Result := Add(1);
end;

type
  TShape = class
    function Area: Integer; virtual;
  end;

  TSquare = class(TShape)
    function Area: Integer; override;
  end;

function TShape.Area: Integer;
begin
  Ran(31);
  Result := 0;
end;

function TSquare.Area: Integer;
begin
  Ran(32);
  Result := 4;
end;

procedure RunShapes;
var
  Shape: TShape;
begin
  Shape := TSquare.Create;
  try
    Ran(33);
    GSink := GSink + Shape.Area;
  finally
    Shape.Free;
  end;
end;

// The second line of this routine IS a breakpoint instruction: a line record
// whose first byte is $CC in the program itself. Never a place for a probe.
procedure OwnBreakpoint;
{$IFDEF CPUX64}
asm
        .NOFRAME
        NOP
        INT     3                            // {BP:PS_OWN_INT3_64}
        RET
end;
{$ELSE}
asm
        NOP
        INT     3                            // {BP:PS_OWN_INT3_32}
        RET
end;
{$ENDIF}

procedure RunOwnBreakpoint;
begin
  try
    OwnBreakpoint;
    Ran(34);
  except
    on E: Exception do
      Ran(35);
  end;
end;

{ ------------------------------------------- what the tests stop and step in -- }

// Called by the debugger at a stop (an evaluation) BEFORE the program calls it
// itself. No Ran here: the record of the program must not depend on what a
// debugger evaluated.
function Twice: Integer;
begin
  Inc(GEval);                                // {BP:PS_TWICE_BODY}
  Result := GStep * 2;
end;

function StepCallee(X: Integer): Integer;
begin
  Ran(40);                                   // {BP:PS_STEP_CALLEE}
  Result := X + GStep;
end;

procedure StepArea;
var
  A: Integer;
begin
  Ran(41);                                   // {BP:PS_STEP_FIRST}
  GWorkerGo := True;                         // {BP:PS_STEP_RELEASE}
  A := GStep * 2;                            // {BP:PS_STEP_SECOND}
  A := StepCallee(A);                        // {BP:PS_STEP_CALL}
  GSink := GSink + A;                        // {BP:PS_STEP_AFTER}
  Ran(42);                                   // {BP:PS_STEP_LAST}
end;

procedure LayerLoop;
var
  I: Integer;
begin
  for I := 1 to LAYER_PASSES do begin
    Ran(43);                                 // {BP:PS_LAYER_A}
    Ran(44);                                 // {BP:PS_LAYER_B}
  end;
end;

procedure RaiseForStep;
begin
  try
    Ran(46);
    raise EProgrammerNotFound.Create('step'); // {BP:PS_EXC_RAISE}
  except
    on E: EProgrammerNotFound do
      Ran(47);                               // {BP:PS_EXC_HANDLER}
  end;
end;

{ --------------------------------------- a long run of lines, never executed -- }

function LongRunExpected(Seed: Integer): Integer;
var
  I: Integer;
begin
  Result := Seed;
  for I := 1 to LONG_RUN_LINES do
    Result := Result * 3 + 1;
end;

// LONG_RUN_LINES statements, one per line, each a line record of its own.
// Every thread keeps its total in a local: a statement that ran twice, or not
// at all, shows in that thread's result.
function LongRun(Seed: Integer): Integer;
begin
  Result := Seed;                            // {BP:PS_LONG_FIRST}
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
  Result := Result * 3 + 1;
end;

function Worker(Param: Pointer): Integer;
begin
  while not GWorkerGo do
    Sleep(1);
  RanByAThread(50);
  if LongRun(7) <> LongRunExpected(7) then
    InterlockedIncrement(GBad);
  RanByAThread(51);
  Result := 0;
end;

function RaceWorker(Param: Pointer): Integer;
begin
  while not GGo do
    ;
  var Seed := Integer(NativeUInt(Param));
  if LongRun(Seed) <> LongRunExpected(Seed) then
    InterlockedIncrement(GBad);
  Result := 0;
end;

procedure RunRace(ThreadCount: Integer);
var
  Handles: array[0..MAX_RACE_THREADS - 1] of THandle;
  ThreadId: TThreadID;
begin
  GBad := 0;
  GGo  := False;
  for var I := 0 to ThreadCount - 1 do
    Handles[I] := BeginThread(nil, 0, RaceWorker, Pointer(NativeUInt(I + 2)), 0, ThreadId);
  Sleep(50);
  GGo := True;                               // {BP:PS_RACE_GO}
  WaitForMultipleObjects(ThreadCount, @Handles[0], True, INFINITE);
  for var I := 0 to ThreadCount - 1 do
    CloseHandle(Handles[I]);
  if GBad <> 0 then
    Halt(EXIT_WRONG_SUM);
end;

{ ------------------------------------------------- a package, loaded twice -- }

type
  TPkgMake = function: NativeUInt;

procedure RunPkg;
begin
  var Path := ExtractFilePath(ParamStr(0)) + 'TestPackage.bpl';
  var Handle := LoadPackage(Path);
  Ran(70);                                   // {BP:PS_PKG_LOADED}
  UnloadPackage(Handle);
  Ran(71);                                   // {BP:PS_PKG_UNLOADED}
  Handle := LoadPackage(Path);
  // A routine of the package that its initialization does not run: executed
  // for the first time in the SECOND mapping.
  var Make: TPkgMake;
  @Make := GetProcAddress(Handle, 'PkgMakePersistentWidget');
  if not Assigned(Make) then
    Halt(EXIT_NO_LIBRARY);
  if Make() = 0 then
    Halt(EXIT_WRONG_SUM);
  Ran(72);                                   // {BP:PS_PKG_RELOADED}
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
  if LibRun() <> LIB_EXPECTED then           // {BP:PS_LIB_CALL}
    Halt(EXIT_WRONG_SUM);
end;

{ --------------------- a step over a call while another thread logs -- }

var
  GStepRaceGo:   THandle;
  GStepRaceDone: THandle;
  GTicks:        Integer = 0;

function StepRaceWorker(Param: Pointer): Integer;
var
  I: Integer;
begin
  WaitForSingleObject(GStepRaceGo, INFINITE);
  for I := 1 to STEP_RACE_TICKS do
    GTicks := GStep + GTicks;                // {BP:PS_SR_TICK}
  SetEvent(GStepRaceDone);
  Result := 0;
end;

// The call the debugger steps over: it cannot return before the other thread
// has run, and the other thread cannot run while the step holds it frozen.
procedure HandOver;
begin
  SetEvent(GStepRaceGo);
  WaitForSingleObject(GStepRaceDone, INFINITE);
end;

procedure RunStepRace;
var
  ThreadId: TThreadID;
begin
  GStepRaceGo   := CreateEvent(nil, True, False, nil);
  GStepRaceDone := CreateEvent(nil, True, False, nil);
  var Handle := BeginThread(nil, 0, StepRaceWorker, nil, 0, ThreadId);
  Sleep(50);
  HandOver;                                  // {BP:PS_SR_CALL}
  GSink := GSink + GTicks;                   // {BP:PS_SR_AFTER}
  WaitForSingleObject(Handle, INFINITE);
  CloseHandle(Handle);
  if GTicks <> STEP_RACE_TICKS * GStep then
    Halt(EXIT_WRONG_SUM);
end;

{ ------------------------------------------------ one line, many passes -- }

procedure RunSpin(Count: Integer);
var
  I: Integer;
begin
  for I := 1 to Count do
    GTicks := GTicks + I;                    // {BP:PS_SPIN_BODY}
end;

{ ------------------------------------------------------------ plumbing -- }

procedure WaitForADebugger;
begin
  for var Round := 1 to 2000 do begin
    if IsDebuggerPresent then
      Break;
    Sleep(10);
  end;
  // Long enough for what the debugger sets up right after attaching: the
  // tests arm every line of the executable before anything else runs.
  Sleep(1000);
end;

procedure WaitUntilNoDebuggerIsAttached;
begin
  for var Round := 1 to 3000 do begin
    if not IsDebuggerPresent then
      Break;
    Sleep(10);
  end;
end;

// The value that follows a switch, or ''.
function SwitchValue(const Name: string): string;
begin
  Result := '';
  for var I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), '-' + Name) then
      Exit(ParamStr(I + 1));
end;

// The program's own record: `sink=<GSink>`, then one `n=0|1` line per mark.
procedure WriteRecord;
begin
  var Path := SwitchValue('out');
  if Path = '' then
    Exit;
  var Text: AnsiString := AnsiString('sink=' + IntToStr(GSink) + #13#10);
  for var I := 0 to MAX_MARK do
    Text := Text + AnsiString(IntToStr(I) + '=' + IntToStr(GRan[I]) + #13#10);
  var Handle := CreateFile(PChar(Path), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then
    Halt(EXIT_NO_OUTPUT);
  var Written: DWORD := 0;
  WriteFile(Handle, PAnsiChar(Text)^, Length(Text), Written, nil);
  CloseHandle(Handle);
  if Written <> DWORD(Length(Text)) then
    Halt(EXIT_NO_OUTPUT);
end;

{ ----------------------------------------------------- one line, hot -- }

const
  HOT_THREADS = 4;

var
  GHotStop: Boolean = False;

// Round one line until told to stop: a breakpoint there traps on every pass,
// so that at any moment some of these threads have a trap queued.
function HotWorker(Param: Pointer): Integer;
var
  Passes: Integer;
begin
  Passes := 0;
  while not GHotStop do
    Passes := Passes + 1;                    // {BP:PS_HOT_LINE}
  Result := Passes and 0;
end;

procedure RunHot;
var
  Handles: array[0..HOT_THREADS - 1] of THandle;
  ThreadId: TThreadID;
begin
  for var I := 0 to HOT_THREADS - 1 do
    Handles[I] := BeginThread(nil, 0, HotWorker, nil, 0, ThreadId);
  WaitUntilNoDebuggerIsAttached;
  Sleep(100);
  GHotStop := True;
  WaitForMultipleObjects(HOT_THREADS, @Handles[0], True, INFINITE);
  for var I := 0 to HOT_THREADS - 1 do
    CloseHandle(Handles[I]);
end;

{ -------------------------------------- a breakpoint exception of its own -- }

var
  GSoftStop:   Boolean = False;
  GSoftRaised: Integer = 0;
  GSoftCaught: Integer = 0;

// Raises EXCEPTION_BREAKPOINT through RaiseException and catches it, until
// told to stop. Under a debugger each one is a debug event the debugger hands
// back; at a detach one of them is queued, and it must still reach this
// handler.
function SoftBreakWorker(Param: Pointer): Integer;
begin
  while not GSoftStop do begin
    Inc(GSoftRaised);
    try
      RaiseException(EXCEPTION_BREAKPOINT, 0, 0, nil);
    except
      Inc(GSoftCaught);
    end;
  end;
  Result := 0;
end;

procedure RunSoftBreak;
var
  ThreadId: TThreadID;
begin
  var Handle := BeginThread(nil, 0, SoftBreakWorker, nil, 0, ThreadId);
  WaitUntilNoDebuggerIsAttached;
  Sleep(100);
  GSoftStop := True;
  WaitForSingleObject(Handle, INFINITE);
  CloseHandle(Handle);
  if (GSoftRaised = 0) or (GSoftRaised <> GSoftCaught) then
    Halt(EXIT_WRONG_SUM);
end;

{ ------------------------------------------ code the program rewrites -- }

// The second line of Rewritable1 (at the top of this file) and of Rewritable2
// is CLC: one byte, harmless, and a line record of its own. RunRewrite turns
// each into an STC ($F8 -> $F9), the way a hooking library writes over the
// first bytes of a routine.
procedure Rewritable2;
{$IFDEF CPUX64}
asm
        .NOFRAME
        NOP
        CLC                                  // {BP:PS_REWRITE2_64}
        RET
end;
{$ELSE}
asm
        NOP
        CLC                                  // {BP:PS_REWRITE2_32}
        RET
end;
{$ENDIF}

procedure RewriteOneByte(At: PByte; Value: Byte);
var
  Old: DWORD;
begin
  VirtualProtect(At, 1, PAGE_EXECUTE_READWRITE, Old);
  At^ := Value;
  VirtualProtect(At, 1, Old, Old);
  FlushInstructionCache(GetCurrentProcess, At, 1);
end;

procedure RunRewrite;
begin
  RewriteOneByte(PByte(@Rewritable1) + 1, $F9);
  RewriteOneByte(PByte(@Rewritable2) + 1, $F9);
  Ran(75);                                   // {BP:PS_REWRITE_DONE}
  Rewritable1;
  Rewritable2;
  Ran(76);
end;

{ -------------------------------- a package an evaluation unloads -- }

var
  GEvalPkg: HMODULE = 0;

// Called by the debugger at a stop: the package goes away inside a synthetic
// call, whose pump sees the unload, not the main loop.
function DropPackageForEval: Integer;
begin
  UnloadPackage(GEvalPkg);
  GEvalPkg := 0;
  Result := 7;
end;

procedure RunPkgEval;
begin
  var Path := ExtractFilePath(ParamStr(0)) + 'TestPackage.bpl';
  GEvalPkg := LoadPackage(Path);
  var FirstBase := GEvalPkg;
  GKeep := @DropPackageForEval;
  Ran(73);                                   // {BP:PS_PKGEVAL_LOADED}
  // Without the debugger's evaluation, the program does the same.
  if GEvalPkg <> 0 then
    UnloadPackage(GEvalPkg);
  // With -pkgmove the address of the first mapping is taken first, so the
  // second one is mapped somewhere else. Without it the loader usually maps it
  // at the same address -- usually: which address an image gets depends on
  // what else on the machine has it mapped.
  if FindCmdLineSwitch('pkgmove') then
    VirtualAlloc(Pointer(FirstBase), $10000, MEM_RESERVE, PAGE_NOACCESS);
  GEvalPkg := LoadPackage(Path);
  var Make: TPkgMake;
  @Make := GetProcAddress(GEvalPkg, 'PkgMakePersistentWidget');
  if (not Assigned(Make)) or (Make() = 0) then
    Halt(EXIT_WRONG_SUM);
  Ran(74);                                   // {BP:PS_PKGEVAL_DONE}
end;

// True when a scenario behind a switch ran: the default run is skipped then.
function RunSwitchedScenario: Boolean;
begin
  Result := True;
  if FindCmdLineSwitch('race') then begin
    var Threads := StrToIntDef(SwitchValue('race'), DEFAULT_RACE_THREADS);
    if (Threads < 1) or (Threads > MAX_RACE_THREADS) then
      Threads := DEFAULT_RACE_THREADS;
    RunRace(Threads);
  end
  else if FindCmdLineSwitch('pkg') then
    RunPkg
  else if FindCmdLineSwitch('lib') then
    RunLib
  else if FindCmdLineSwitch('steprace') then
    RunStepRace
  else if FindCmdLineSwitch('spin') then
    RunSpin(StrToIntDef(SwitchValue('spin'), 1000))
  else if FindCmdLineSwitch('hot') then
    RunHot
  else if FindCmdLineSwitch('softbreak') then
    RunSoftBreak
  else if FindCmdLineSwitch('rewrite') then
    RunRewrite
  else if FindCmdLineSwitch('pkgeval') then
    RunPkgEval
  else
    Result := False;
end;

var
  WorkerHandle: THandle;
  WorkerId:     TThreadID;

begin
  if FindCmdLineSwitch('wait-debugger') then
    WaitForADebugger;
  GKeep := @NeverCalled;
  if RunSwitchedScenario then begin
    WriteRecord;
    Exit;
  end;
  Ran(60);                                   // {BP:PS_MAIN_FIRST}
  Branches(1);
  Loops(3);
  RunFinally;
  try
    FinallyOnlyByException;
  except
    on E: EAbort do
      Ran(61);
  end;
  ExceptNotTaken;
  GSink := GSink + Factorial(4);
  Outer;
  GSink := GSink + WithAnonymous(4);
  RunShapes;
  RunOwnBreakpoint;
  if FindCmdLineSwitch('wait-detach') then
    WaitUntilNoDebuggerIsAttached;
  Ran(45);                                   // {BP:PS_LAYER_BEFORE}
  LayerLoop;
  GSink := GSink + Twice;                    // {BP:PS_BEFORE_TWICE}
  WorkerHandle := BeginThread(nil, 0, Worker, nil, 0, WorkerId);
  StepArea;
  RaiseForStep;
  WaitForSingleObject(WorkerHandle, INFINITE);
  CloseHandle(WorkerHandle);
  if GBad <> 0 then
    Halt(EXIT_WRONG_SUM);
  Ran(62);
  WriteRecord;                               // {BP:PS_MAIN_LAST}
end.
