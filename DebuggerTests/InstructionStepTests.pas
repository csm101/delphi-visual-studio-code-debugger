unit InstructionStepTests;

// Instruction-granularity stepping, at the ENGINE level
// (ASSEMBLY_LEVEL_DEBUGGING.md increment 1). No DAP and no MCP: these drive
// TDebugSession.StepInstruction directly, against a fixture built for exactly
// this (DebuggerTests\TestTarget\InstructionStepSample.dpr).
//
// Every test runs on BOTH bitnesses, as its own test case rather than as one
// case that collects failures: instruction stepping is where x86 and x64 differ
// most (register file, calling convention, and above all the return address --
// .pdata on x64, [EBP+4] on x86), and a failure must name which one broke.
//
// What each test would look like if its rule were removed:
//
//   Into_AdvancesOneInstruction...  -- with granularity ignored the step runs
//     to the next SOURCE LINE, so the stop line changes and the PC is far past
//     PC+length.
//   Over_StaysInTheCallerFrame      -- without the call rule the trap-flag step
//     executes the `call` and lands at the callee's entry.
//   Over_RecursiveCallee_...        -- without the stack-pointer guard the
//     one-shot fires for the INNERMOST incarnation returning to the same
//     address: right instruction, wrong frame, so the stack pointer is lower.
//   Over_/Into_RepPrefixed_...      -- without the rep rule the trap-flag step
//     retires ONE iteration and leaves the PC unchanged (and a caller looping
//     until it moves would take 65536 stops -- the hang this rule prevents).
//   Out_LandsInTheCaller            -- without a proven return address there is
//     nothing to run to.
//   Refused_WhenDisassemblerUnavailable -- the fail-closed contract: no
//     fallback decoder exists in this project, so a missing backend must refuse
//     rather than guess a length.
//   WatchpointHitDuringStepOver_... -- a hardware watchpoint hit arrives as the
//     same single-step exception a step does; only DR6 separates them.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TInstructionStepTests = class
  public
    // TRAPS.md: ZydisTryLoad is a process-wide ONE-SHOT latch, so a test that
    // deliberately drove it at a missing DLL poisons every later test in the
    // same process. Reset before every test that wants a real decode.
    [Setup] procedure ResetDisassemblerLoadLatch;

    [Test] procedure X64_Into_AdvancesOneInstructionAndEntersTheCallee;
    [Test] procedure Win32_Into_AdvancesOneInstructionAndEntersTheCallee;
    [Test] procedure X64_Over_StaysInTheCallerFrame;
    [Test] procedure Win32_Over_StaysInTheCallerFrame;
    [Test] procedure X64_Over_RecursiveCallee_StaysInTheOuterFrame;
    [Test] procedure Win32_Over_RecursiveCallee_StaysInTheOuterFrame;
    [Test] procedure X64_Over_RepPrefixed_CompletesTheWholeStringOperation;
    [Test] procedure Win32_Over_RepPrefixed_CompletesTheWholeStringOperation;
    [Test] procedure X64_Into_RepPrefixed_CompletesTheWholeStringOperation;
    [Test] procedure Win32_Into_RepPrefixed_CompletesTheWholeStringOperation;
    [Test] procedure X64_Out_LandsInTheCaller;
    [Test] procedure Win32_Out_LandsInTheCaller;
    [Test] procedure X64_Refused_WhenDisassemblerUnavailable;
    [Test] procedure Win32_Refused_WhenDisassemblerUnavailable;
    [Test] procedure X64_WatchpointHitDuringStepOver_IsNotAStepCompletion;
    [Test] procedure Win32_WatchpointHitDuringStepOver_IsNotAStepCompletion;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.StrUtils, Winapi.Windows,
  DebugTarget, DebugSession, DebugSessionTypes,
  Disassembler, ZydisApi, ZydisDisassembler;

const
  SAMPLE_SOURCE  = 'InstructionStepSample.dpr';
  REP_BLOCK_SIZE = 65536;   // must match the fixture's own constant
  // Generous, because the point of the rep rule is that ONE step is not
  // 65536 stops; a run that needs longer than this has already failed.
  STEP_TIMEOUT_MS = 30000;

{ ------------------------------------------------------------- fixtures ---- }

function RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function SampleExe(const Bitness: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\InstructionStepSample.exe';
end;

function SampleMap(const Bitness: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\InstructionStepSample.map';
end;

function SampleRsm(const Bitness: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\InstructionStepSample.rsm';
end;

// 1-based line carrying `{BP:<Marker>}`, or 0.
function MarkerLine(const Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(TargetDir + SAMPLE_SOURCE);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then
        Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

procedure PumpUntilStop(Session: TDebugSession; TimeoutMs: Cardinal);
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while (Session.State <> dsStopped) and (not Session.HasExited) and
        (GetTickCount64 < Deadline) do
    Session.Pump;
end;

// Launches the sample and stops it at the given marker. Caller owns the result.
function OpenSampleAt(const Bitness, Marker: string): TDebugSession;
begin
  var Line := MarkerLine(Marker);
  Assert.IsTrue(Line > 0, 'marker ' + Marker + ' not found in ' + SAMPLE_SOURCE);
  Assert.IsTrue(FileExists(SampleExe(Bitness)),
    'fixture not built: ' + SampleExe(Bitness));

  Result := TDebugSession.Create;
  var Opts := Default(TLaunchOptions);
  Opts.ExePath     := SampleExe(Bitness);
  Opts.MapPath     := SampleMap(Bitness);
  Opts.RsmPath     := SampleRsm(Bitness);
  Opts.SourceRoot  := TargetDir;
  Opts.StopAtEntry := False;
  Assert.IsTrue(Result.Launch(Opts), 'Launch returned False');

  var Spec := Default(TBpLineSpec);
  Spec.Line := Line;
  Result.SetBreakpoints(SAMPLE_SOURCE, [Spec]);

  PumpUntilStop(Result, 60000);
  Assert.AreEqual(Ord(dsStopped), Ord(Result.State),
    Format('%s: did not stop at %s (line %d)', [Bitness, Marker, Line]));
end;

{ ------------------------------------------------- reading the debuggee ---- }

// The instruction about to execute, decoded through the SAME seam the engine
// uses. A test that asserted "the PC advanced by the instruction's length" from
// its own idea of that length would be asserting against itself.
function DecodeAtPc(Session: TDebugSession; VA: UInt64;
  out Text: string; out Len: Integer): Boolean;
var
  Dbg: IDebugTarget;
begin
  Text := '';
  Len  := 0;
  Dbg  := Session.Debugger;
  var Mode: TDisasmMachineMode;
  if Dbg.TargetLayout.PointerSize = 8 then
    Mode := dmmLong64
  else
    Mode := dmmLegacy32;
  var Reader: TDisasmByteReader :=
    function(A: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      Result := Integer(Dbg.ReadCodeMemoryAt(A, Buf, NativeUInt(Size)));
    end;
  var Disasm: IDisassembler := TZydisDisassembler.Create(Mode, Reader, nil, 0,
    ResolveZydisDllPathForThisExe);
  if not Disasm.Available then
    Exit(False);
  var Insns := Disasm.Disassemble(VA, 1);
  if (Length(Insns) = 0) or (not Insns[0].Decoded) then
    Exit(False);
  Text   := Insns[0].Text;
  Len    := Insns[0].Length;
  Result := True;
end;

function CurrentPc(Session: TDebugSession): UInt64;
begin
  Result := Session.Debugger.GetRegisters.Pc;
end;

function CurrentSp(Session: TDebugSession): UInt64;
begin
  Result := Session.Debugger.GetRegisters.StackPtr;
end;

function CurrentFunctionName(Session: TDebugSession; const Context: string): string;
var
  SrcFile: string;
  Line: Integer;
begin
  Assert.IsTrue(Session.GetCurrentLocation(Result, SrcFile, Line),
    'no current location ' + Context);
end;

function CurrentLine(Session: TDebugSession; const Context: string): Integer;
var
  FnName, SrcFile: string;
begin
  Assert.IsTrue(Session.GetCurrentLocation(FnName, SrcFile, Result),
    'no current location ' + Context);
end;

procedure TakeOneInstructionStep(Session: TDebugSession;
  Kind: TInstructionStepKind; const Context: string);
var
  Reason: string;
begin
  Assert.IsTrue(Session.StepInstruction(Kind, 0, Reason),
    Format('the instruction step was refused %s: %s', [Context, Reason]));
  PumpUntilStop(Session, STEP_TIMEOUT_MS);
  Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
    'the instruction step produced no stop ' + Context);
end;

// Single-steps INTO until the instruction about to execute starts with Want,
// and returns its address. Bounded on purpose: an unbounded search here would
// be indistinguishable from the hang this whole increment exists to avoid.
function StepUntilMnemonic(Session: TDebugSession; const Want: string;
  MaxSteps: Integer): UInt64;
begin
  for var I := 1 to MaxSteps do begin
    var Pc := CurrentPc(Session);
    var Text: string;
    var Len: Integer;
    Assert.IsTrue(DecodeAtPc(Session, Pc, Text, Len),
      Format('could not decode the instruction at $%x', [Pc]));
    if StartsText(Want, Text) then
      Exit(Pc);
    TakeOneInstructionStep(Session, iskInto,
      Format('while looking for `%s` (at $%x: %s)', [Want, Pc, Text]));
  end;
  Assert.Fail(Format('no `%s` instruction reached within %d instruction steps',
    [Want, MaxSteps]));
  Result := 0;
end;

{ ------------------------------------------- an unavailable backend double - }

// A real IDisassembler that is simply not available. Injected rather than
// produced by pointing the Zydis loader at a missing DLL: that loader is a
// process-wide one-shot latch (TRAPS.md), so a bad path is either ignored
// (already loaded) or poisons every later test.
type
  TUnavailableDisassembler = class(TInterfacedObject, IDisassembler)
  public
    function Available: Boolean;
    function StatusText: string;
    function Disassemble(VA: UInt64; Count: Integer): TArray<TDisasmInstruction>;
  end;

function TUnavailableDisassembler.Available: Boolean;
begin
  Result := False;
end;

function TUnavailableDisassembler.StatusText: string;
begin
  Result := 'Zydis unavailable: injected test double';
end;

function TUnavailableDisassembler.Disassemble(VA: UInt64;
  Count: Integer): TArray<TDisasmInstruction>;
begin
  Result := nil;
end;

{ ----------------------------------------------------- shared scenarios ---- }

procedure RunIntoAdvancesOneInstructionAndEntersTheCallee(const Bitness: string);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_MULTI');
  try
    // 1. One instruction, not one line. The marker line is several
    //    instructions long, so a step that lands on a NEW line ran too far.
    var PcBefore   := CurrentPc(Session);
    var LineBefore := CurrentLine(Session, 'before the first instruction step');
    var Text: string;
    var Len: Integer;
    Assert.IsTrue(DecodeAtPc(Session, PcBefore, Text, Len),
      Format('%s: could not decode the instruction at $%x', [Bitness, PcBefore]));
    Assert.IsFalse(StartsText('call', Text),
      Format('%s: the fixture line starts with a call (%s); this test needs a ' +
             'plain instruction there', [Bitness, Text]));

    TakeOneInstructionStep(Session, iskInto, 'at the multi-instruction line');

    Assert.AreEqual(PcBefore + UInt64(Len), CurrentPc(Session),
      Format('%s: step-into did not advance exactly one instruction from $%x ' +
             '(%s, %d bytes)', [Bitness, PcBefore, Text, Len]));
    Assert.AreEqual(LineBefore, CurrentLine(Session, 'after the instruction step'),
      Format('%s: one instruction step left the source line -- that is a ' +
             'source-granularity step, not an instruction one', [Bitness]));

    // 2. Step-into a call enters the callee, which is the whole difference
    //    between into and over at this granularity.
    var CallPc := StepUntilMnemonic(Session, 'call', 200);
    TakeOneInstructionStep(Session, iskInto, 'at the call instruction');
    var Landed := CurrentFunctionName(Session, 'after stepping into the call');
    Assert.IsTrue(ContainsText(Landed, 'InstrStepCallee'),
      Format('%s: step-into at the call at $%x landed in "%s", not in the callee',
        [Bitness, CallPc, Landed]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure RunOverStaysInTheCallerFrame(const Bitness: string);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_CALLSITE');
  try
    var CallPc := StepUntilMnemonic(Session, 'call', 200);
    var Text: string;
    var Len: Integer;
    Assert.IsTrue(DecodeAtPc(Session, CallPc, Text, Len),
      Format('%s: could not decode the call at $%x', [Bitness, CallPc]));
    var SpBefore := CurrentSp(Session);
    var FnBefore := CurrentFunctionName(Session, 'at the call site');

    TakeOneInstructionStep(Session, iskOver, 'at the call instruction');

    Assert.AreEqual(CallPc + UInt64(Len), CurrentPc(Session),
      Format('%s: step-over of `%s` at $%x did not land on the following ' +
             'instruction -- it single-stepped INTO the call', [Bitness, Text, CallPc]));
    Assert.AreEqual(SpBefore, CurrentSp(Session),
      Format('%s: the stack pointer changed across the step-over, so it did ' +
             'not land in the frame it started in', [Bitness]));
    Assert.AreEqual(FnBefore, CurrentFunctionName(Session, 'after the step-over'),
      Format('%s: step-over left the caller', [Bitness]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure RunOverRecursiveCalleeStaysInTheOuterFrame(const Bitness: string);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_RECURSE_ENTRY');
  try
    // Into the OUTERMOST InstrStepRecurse, then on to its recursive call.
    StepUntilMnemonic(Session, 'call', 200);
    TakeOneInstructionStep(Session, iskInto, 'entering InstrStepRecurse');
    var RecursePc := StepUntilMnemonic(Session, 'call', 300);
    var Text: string;
    var Len: Integer;
    Assert.IsTrue(DecodeAtPc(Session, RecursePc, Text, Len),
      Format('%s: could not decode the recursive call at $%x', [Bitness, RecursePc]));
    var SpBefore := CurrentSp(Session);

    TakeOneInstructionStep(Session, iskOver, 'at the recursive call');

    Assert.AreEqual(RecursePc + UInt64(Len), CurrentPc(Session),
      Format('%s: step-over of the recursive call at $%x did not land on the ' +
             'following instruction', [Bitness, RecursePc]));
    // THE assertion: the address alone cannot tell the outermost incarnation
    // from a deeper one, because every one of them returns to exactly here.
    Assert.AreEqual(SpBefore, CurrentSp(Session),
      Format('%s: the step-over landed at the right address in the WRONG frame ' +
             '(stack pointer $%x, expected $%x) -- a deeper recursive ' +
             'incarnation ended the step', [Bitness, CurrentSp(Session), SpBefore]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// A rep-prefixed instruction traps once per ITERATION. The proof that the step
// completed the WHOLE operation and not one iteration is the count register:
// REP_BLOCK_SIZE before, zero after.
procedure RunRepPrefixedCompletesTheWholeStringOperation(const Bitness: string;
  Kind: TInstructionStepKind);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_REP_CALL');
  try
    var RepPc := StepUntilMnemonic(Session, 'rep', 400);
    var Text: string;
    var Len: Integer;
    Assert.IsTrue(DecodeAtPc(Session, RepPc, Text, Len),
      Format('%s: could not decode the rep instruction at $%x', [Bitness, RepPc]));
    var CountBefore := Session.Debugger.GetRegisters.Rcx;
    Assert.AreEqual(UInt64(REP_BLOCK_SIZE), CountBefore,
      Format('%s: the count register held $%x at `%s`, so this is not the ' +
             'fixture''s own 64 KB move', [Bitness, CountBefore, Text]));

    var StartedAt := GetTickCount64;
    TakeOneInstructionStep(Session, Kind, 'at the rep instruction');
    var Elapsed := GetTickCount64 - StartedAt;

    Assert.AreEqual(RepPc + UInt64(Len), CurrentPc(Session),
      Format('%s: one step at `%s` ($%x) did not move past it -- a trap-flag ' +
             'step retires ONE iteration and leaves the PC where it was',
        [Bitness, Text, RepPc]));
    Assert.AreEqual(UInt64(0), Session.Debugger.GetRegisters.Rcx,
      Format('%s: the count register is not zero after the step, so the string ' +
             'operation did not complete', [Bitness]));
    Assert.IsTrue(Elapsed < STEP_TIMEOUT_MS,
      Format('%s: the step took %d ms', [Bitness, Elapsed]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure RunOutLandsInTheCaller(const Bitness: string);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_CALLEE_BODY');
  try
    var FnBefore := CurrentFunctionName(Session, 'inside the callee');
    Assert.IsTrue(ContainsText(FnBefore, 'InstrStepCallee'),
      Format('%s: did not stop inside the callee, got "%s"', [Bitness, FnBefore]));
    var SpBefore := CurrentSp(Session);

    TakeOneInstructionStep(Session, iskOut, 'inside the callee');

    var FnAfter := CurrentFunctionName(Session, 'after the step-out');
    Assert.IsTrue(ContainsText(FnAfter, 'InstrStepCallScenario'),
      Format('%s: instruction step-out landed in "%s", not in the caller',
        [Bitness, FnAfter]));
    Assert.IsTrue(CurrentSp(Session) > SpBefore,
      Format('%s: the stack pointer did not rise across the step-out ($%x -> $%x), ' +
             'so the frame was never left',
        [Bitness, SpBefore, CurrentSp(Session)]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure RunRefusedWhenDisassemblerUnavailable(const Bitness: string);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_MULTI');
  try
    Session.Debugger.SetInstructionDisassembler(TUnavailableDisassembler.Create);
    var PcBefore := CurrentPc(Session);

    for var Kind := Low(TInstructionStepKind) to High(TInstructionStepKind) do begin
      var Reason: string;
      Assert.IsFalse(Session.StepInstruction(Kind, 0, Reason),
        Format('%s: instruction step kind %d was ACCEPTED with no disassembler ' +
               'backend -- this project has no fallback decoder and must never ' +
               'guess an instruction length', [Bitness, Ord(Kind)]));
      Assert.IsTrue(ContainsText(Reason, 'disassembler'),
        Format('%s: the refusal for kind %d does not say what is missing: "%s"',
          [Bitness, Ord(Kind), Reason]));
      // A refusal must not have resumed anything.
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        Format('%s: the session left dsStopped on a refused step', [Bitness]));
      Assert.AreEqual(PcBefore, CurrentPc(Session),
        Format('%s: the program counter moved on a refused step', [Bitness]));
    end;
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// A hardware watchpoint hit is delivered as the same single-step exception a
// completed step is, and only DR6 separates them. Reported as the step
// completing, the user stops inside the callee at the write instead of after
// the call they stepped over.
procedure RunWatchpointHitDuringStepOverIsNotAStepCompletion(const Bitness: string);
begin
  var Session := OpenSampleAt(Bitness, 'INSTR_WATCH_CALL');
  try
    var Watched: TLocalValue;
    Assert.IsTrue(Session.Debugger.EvaluateGlobalName('GInstrWatched', Watched),
      Format('%s: GInstrWatched is not resolvable in the debuggee', [Bitness]));
    Assert.IsTrue(Watched.Address <> 0,
      Format('%s: GInstrWatched resolved to address 0', [Bitness]));
    var Slot: Integer;
    var Reason: string;
    Assert.IsTrue(Session.Debugger.SetDataWatchpoint(Watched.Address, 4, True,
        'GInstrWatched', Slot, Reason),
      Format('%s: arming a write watchpoint on GInstrWatched was refused: %s',
        [Bitness, Reason]));

    var Before: UInt32 := 0;
    Session.Debugger.ReadProcessMemoryAt(Watched.Address, @Before, SizeOf(Before));

    var CallPc := StepUntilMnemonic(Session, 'call', 200);
    var Text: string;
    var Len: Integer;
    Assert.IsTrue(DecodeAtPc(Session, CallPc, Text, Len),
      Format('%s: could not decode the call at $%x', [Bitness, CallPc]));

    TakeOneInstructionStep(Session, iskOver, 'over the call that writes the watched global');

    // Separates "the cell was never written" (a symbol problem) from "the
    // hardware never reported it" (a debug-register problem).
    var After: UInt32 := 0;
    Session.Debugger.ReadProcessMemoryAt(Watched.Address, @After, SizeOf(After));
    Assert.IsTrue(After <> Before,
      Format('%s: the watched cell at $%x did not change across the stepped-over ' +
             'call (%d -> %d)', [Bitness, Watched.Address, Before, After]));

    Assert.AreEqual(CallPc + UInt64(Len), CurrentPc(Session),
      Format('%s: the step-over ended at $%x rather than after the call at $%x -- ' +
             'the watchpoint hit was reported as the step completing',
        [Bitness, CurrentPc(Session), CallPc]));
    Assert.IsTrue(Session.Debugger.HardwareWatchpointHitCount > 0,
      Format('%s: the watched cell was written but no watchpoint hit was ' +
             'recorded, so the combined case was never produced', [Bitness]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

{ ---------------------------------------------------------------- tests ---- }

procedure TInstructionStepTests.ResetDisassemblerLoadLatch;
begin
  ZydisResetForTests;
end;

procedure TInstructionStepTests.X64_Into_AdvancesOneInstructionAndEntersTheCallee;
begin
  RunIntoAdvancesOneInstructionAndEntersTheCallee('Win64');
end;

procedure TInstructionStepTests.Win32_Into_AdvancesOneInstructionAndEntersTheCallee;
begin
  RunIntoAdvancesOneInstructionAndEntersTheCallee('Win32');
end;

procedure TInstructionStepTests.X64_Over_StaysInTheCallerFrame;
begin
  RunOverStaysInTheCallerFrame('Win64');
end;

procedure TInstructionStepTests.Win32_Over_StaysInTheCallerFrame;
begin
  RunOverStaysInTheCallerFrame('Win32');
end;

procedure TInstructionStepTests.X64_Over_RecursiveCallee_StaysInTheOuterFrame;
begin
  RunOverRecursiveCalleeStaysInTheOuterFrame('Win64');
end;

procedure TInstructionStepTests.Win32_Over_RecursiveCallee_StaysInTheOuterFrame;
begin
  RunOverRecursiveCalleeStaysInTheOuterFrame('Win32');
end;

procedure TInstructionStepTests.X64_Over_RepPrefixed_CompletesTheWholeStringOperation;
begin
  RunRepPrefixedCompletesTheWholeStringOperation('Win64', iskOver);
end;

procedure TInstructionStepTests.Win32_Over_RepPrefixed_CompletesTheWholeStringOperation;
begin
  RunRepPrefixedCompletesTheWholeStringOperation('Win32', iskOver);
end;

procedure TInstructionStepTests.X64_Into_RepPrefixed_CompletesTheWholeStringOperation;
begin
  RunRepPrefixedCompletesTheWholeStringOperation('Win64', iskInto);
end;

procedure TInstructionStepTests.Win32_Into_RepPrefixed_CompletesTheWholeStringOperation;
begin
  RunRepPrefixedCompletesTheWholeStringOperation('Win32', iskInto);
end;

procedure TInstructionStepTests.X64_Out_LandsInTheCaller;
begin
  RunOutLandsInTheCaller('Win64');
end;

procedure TInstructionStepTests.Win32_Out_LandsInTheCaller;
begin
  RunOutLandsInTheCaller('Win32');
end;

procedure TInstructionStepTests.X64_Refused_WhenDisassemblerUnavailable;
begin
  RunRefusedWhenDisassemblerUnavailable('Win64');
end;

procedure TInstructionStepTests.Win32_Refused_WhenDisassemblerUnavailable;
begin
  RunRefusedWhenDisassemblerUnavailable('Win32');
end;

procedure TInstructionStepTests.X64_WatchpointHitDuringStepOver_IsNotAStepCompletion;
begin
  RunWatchpointHitDuringStepOverIsNotAStepCompletion('Win64');
end;

procedure TInstructionStepTests.Win32_WatchpointHitDuringStepOver_IsNotAStepCompletion;
begin
  RunWatchpointHitDuringStepOverIsNotAStepCompletion('Win32');
end;

initialization
  // EXPLICIT registration: this project does not use RTTI auto-scan, and an
  // unregistered fixture silently never runs (TRAPS.md).
  TDUnitX.RegisterTestFixture(TInstructionStepTests);

end.
