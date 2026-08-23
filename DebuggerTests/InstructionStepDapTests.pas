unit InstructionStepDapTests;

// DAP-layer plumbing for instruction-granularity stepping
// (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 2). InstructionStepTests.pas already
// proves the ENGINE primitive exhaustively, on both bitnesses, including every
// refusal path (unavailable disassembler, unprovable return address) and the
// call/rep/recursion rules. This file proves the THIN layer on top: does
// `granularity: "instruction"` on next/stepIn/stepOut actually reach
// TDebugSession.StepInstruction with the right TInstructionStepKind, does a
// refusal reach the client as a FAILED request rather than a silent success,
// and does granularity being absent (or "statement") leave the existing
// source-level behaviour untouched.
//
// Scope note: two of the three engine-level refusal reasons are UNREACHABLE
// through the DAP wire protocol by construction, not by the tests' choice.
// `StepThreadFromArgs` (DapServer.pas) folds any threadId that does not match
// a live thread back to 0 ("the stopped thread"), the same defensive fallback
// `stackTrace` uses -- so a bogus DAP threadId can never reach the engine's
// "thread is not live" refusal. There is also no launch-config knob to force
// the Zydis backend unavailable from outside the process (it is injected only
// via `IDebugTarget.SetInstructionDisassembler`, an in-process seam). The one
// refusal reliably reachable from a real DAP client is "not running" (before
// launch), which is what `Refused_WhenNotLaunched_...` exercises; that is
// enough to prove the ROUTING (refusal -> failed response), since the engine
// side of every refusal is already covered by InstructionStepTests.pas.
//
// Bitness scope: the instruction-level POSITIVE scenarios run on both
// bitnesses, because that is where increment 1 found real differences
// (CallerReturnAddress via .pdata vs [EBP+4], WOW64's
// STATUS_WX86_SINGLE_STEP). The granularity STRING PARSING
// (`WantsInstructionGranularity`) and the refusal-routing test are plain JSON
// glue with no bitness-sensitive content, so they run once, on Win64 -- the
// same scoping call already recorded for `setInstructionBreakpoints`' DAP
// layer (docs/TEST_CATALOG.md, "DAP-layer Win32 coverage ... not written this
// increment ... DAP is JSON glue over the same already-bitness-proven session
// code").

interface

uses
  DUnitX.TestFramework, DapClient;

type
  [TestFixture]
  TInstructionStepDapTests = class
  private
    FClient: TDapClient;
    procedure OpenSampleAt(const Bitness, Marker: string);
    function  CurrentLine: Integer;
  public
    [TearDown] procedure TearDown;

    [Test] procedure Capability_SupportsSteppingGranularity_IsAdvertised;

    [Test] procedure X64_StepIn_Instruction_AdvancesOneInstructionSameLine;
    [Test] procedure Win32_StepIn_Instruction_AdvancesOneInstructionSameLine;
    [Test] procedure X64_Next_Instruction_AdvancesOneInstructionSameLine;
    [Test] procedure Win32_Next_Instruction_AdvancesOneInstructionSameLine;
    [Test] procedure X64_StepOut_Instruction_LandsInTheCaller;
    [Test] procedure Win32_StepOut_Instruction_LandsInTheCaller;

    [Test] procedure X64_StepIn_GranularityAbsent_StillAdvancesToNewLine;
    [Test] procedure X64_StepIn_GranularityStatement_StillAdvancesToNewLine;
    [Test] procedure X64_Next_GranularityAbsent_StillAdvancesToNewLine;

    [Test] procedure Refused_WhenNotLaunched_ReachesClientAsFailedRequest;
  end;

implementation

uses
  System.SysUtils, System.StrUtils, System.JSON;

const
  SAMPLE_SOURCE = 'InstructionStepSample.dpr';

function RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function SamplePath: string;
begin
  Result := TargetDir + SAMPLE_SOURCE;
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

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

{ ------------------------------------------------------------------ setup -- }

procedure TInstructionStepDapTests.OpenSampleAt(const Bitness, Marker: string);
begin
  var Line := FindBpLine(SamplePath, Marker);
  Assert.IsTrue(Line > 0, 'marker ' + Marker + ' not found in ' + SAMPLE_SOURCE);
  Assert.IsTrue(FileExists(SampleExe(Bitness)),
    'fixture not built: ' + SampleExe(Bitness));

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  FClient.SetBreakpoints(SamplePath, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(SampleExe(Bitness), SampleMap(Bitness), SampleRsm(Bitness), TargetDir).Free;
  FClient.ConfigDone.Free;

  var Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      Format('%s: did not stop at %s (line %d)', [Bitness, Marker, Line]));
  finally
    Stopped.Free;
  end;
end;

procedure TInstructionStepDapTests.TearDown;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect.Free;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

{ ------------------------------------------------- reading the debuggee ---- }

// Free functions, parametrized by Client, rather than instance methods: the
// shared Run* scenarios below need to pass "how to read the frame" around
// without relying on Delphi's method-reference-to-TFunc conversion.
function FirstFrame(Client: TDapClient): TJSONObject;
begin
  var ST := Client.StackTrace(1);
  try
    var Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'stackTrace returned no frames');
    Result := (Frames.Items[0] as TJSONObject).Clone as TJSONObject;
  finally
    ST.Free;
  end;
end;

function LineOf(Client: TDapClient): Integer;
begin
  var F := FirstFrame(Client);
  try
    Result := F.GetValue<Integer>('line', 0);
  finally
    F.Free;
  end;
end;

function IpOf(Client: TDapClient): string;
begin
  var F := FirstFrame(Client);
  try
    Result := F.GetValue<string>('instructionPointerReference', '');
  finally
    F.Free;
  end;
end;

function NameOf(Client: TDapClient): string;
begin
  var F := FirstFrame(Client);
  try
    Result := F.GetValue<string>('name', '');
  finally
    F.Free;
  end;
end;

function TInstructionStepDapTests.CurrentLine: Integer;
begin
  Result := LineOf(FClient);
end;

{ ---------------------------------------------------------------- tests ---- }

procedure TInstructionStepDapTests.Capability_SupportsSteppingGranularity_IsAdvertised;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  var InitResp := FClient.Initialize;
  try
    Assert.IsTrue(InitResp.GetValue<Boolean>('supportsSteppingGranularity', False),
      'initialize response did not advertise supportsSteppingGranularity');
  finally
    InitResp.Free;
  end;
end;

// One instruction, not one line -- the DAP twin of InstructionStepTests'
// Into_AdvancesOneInstructionAndEntersTheCallee, minus the "enters the
// callee" half (already proven at the engine level; this file only proves
// the field reaches the engine at all).
procedure RunStepInInstructionAdvancesOneInstructionSameLine(const Bitness: string;
  Client: TDapClient);
begin
  var LineBefore := LineOf(Client);
  var IpBefore    := IpOf(Client);

  var Resp := Client.StepIn(1, 'instruction');
  Resp.Free;
  var Stopped := Client.WaitForStopped;
  try
    Assert.AreEqual('step', Stopped.GetValue<string>('reason', ''),
      Format('%s: stepIn/instruction reason', [Bitness]));
  finally
    Stopped.Free;
  end;

  Assert.AreEqual(LineBefore, LineOf(Client),
    Format('%s: an instruction-granularity stepIn left the source line -- ' +
           'that is a statement-granularity step, not an instruction one', [Bitness]));
  Assert.AreNotEqual(IpBefore, IpOf(Client),
    Format('%s: the instruction pointer did not move at all', [Bitness]));
end;

procedure TInstructionStepDapTests.X64_StepIn_Instruction_AdvancesOneInstructionSameLine;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  RunStepInInstructionAdvancesOneInstructionSameLine('Win64', FClient);
end;

procedure TInstructionStepDapTests.Win32_StepIn_Instruction_AdvancesOneInstructionSameLine;
begin
  OpenSampleAt('Win32', 'INSTR_MULTI');
  RunStepInInstructionAdvancesOneInstructionSameLine('Win32', FClient);
end;

procedure RunNextInstructionAdvancesOneInstructionSameLine(const Bitness: string;
  Client: TDapClient);
begin
  var LineBefore := LineOf(Client);
  var IpBefore    := IpOf(Client);

  var Resp := Client.StepOver(1, 'instruction');
  Resp.Free;
  var Stopped := Client.WaitForStopped;
  try
    Assert.AreEqual('step', Stopped.GetValue<string>('reason', ''),
      Format('%s: next/instruction reason', [Bitness]));
  finally
    Stopped.Free;
  end;

  Assert.AreEqual(LineBefore, LineOf(Client),
    Format('%s: an instruction-granularity next left the source line -- ' +
           'that is a statement-granularity step, not an instruction one', [Bitness]));
  Assert.AreNotEqual(IpBefore, IpOf(Client),
    Format('%s: the instruction pointer did not move at all', [Bitness]));
end;

procedure TInstructionStepDapTests.X64_Next_Instruction_AdvancesOneInstructionSameLine;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  RunNextInstructionAdvancesOneInstructionSameLine('Win64', FClient);
end;

procedure TInstructionStepDapTests.Win32_Next_Instruction_AdvancesOneInstructionSameLine;
begin
  OpenSampleAt('Win32', 'INSTR_MULTI');
  RunNextInstructionAdvancesOneInstructionSameLine('Win32', FClient);
end;

procedure RunStepOutInstructionLandsInTheCaller(const Bitness: string;
  Client: TDapClient);
begin
  var NameBefore := NameOf(Client);
  Assert.IsTrue(ContainsText(NameBefore, 'InstrStepCallee'),
    Format('%s: did not stop inside the callee, got "%s"', [Bitness, NameBefore]));

  var Resp := Client.StepOut(1, 'instruction');
  Resp.Free;
  var Stopped := Client.WaitForStopped;
  try
    Assert.AreEqual('step', Stopped.GetValue<string>('reason', ''),
      Format('%s: stepOut/instruction reason', [Bitness]));
  finally
    Stopped.Free;
  end;

  var NameAfter := NameOf(Client);
  Assert.IsTrue(ContainsText(NameAfter, 'InstrStepCallScenario'),
    Format('%s: instruction-granularity stepOut landed in "%s", not in the caller',
      [Bitness, NameAfter]));
end;

procedure TInstructionStepDapTests.X64_StepOut_Instruction_LandsInTheCaller;
begin
  OpenSampleAt('Win64', 'INSTR_CALLEE_BODY');
  RunStepOutInstructionLandsInTheCaller('Win64', FClient);
end;

procedure TInstructionStepDapTests.Win32_StepOut_Instruction_LandsInTheCaller;
begin
  OpenSampleAt('Win32', 'INSTR_CALLEE_BODY');
  RunStepOutInstructionLandsInTheCaller('Win32', FClient);
end;

// Regression controls: granularity absent, or explicitly "statement", must be
// BYTE-IDENTICAL to pre-increment-2 behaviour -- the source-level step runs
// until the SOURCE LINE changes, unlike the instruction-granularity tests
// above which stay on the same line. A break here is worse than the missing
// feature, because it would regress ordinary stepping for every user.
procedure TInstructionStepDapTests.X64_StepIn_GranularityAbsent_StillAdvancesToNewLine;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var LineBefore := CurrentLine;
  FClient.StepIn.Free;                      // no granularity argument at all
  var Stopped := FClient.WaitForStopped;
  Stopped.Free;
  Assert.AreNotEqual(LineBefore, CurrentLine,
    'granularity-absent stepIn did not advance to a new source line -- ' +
    'this is a regression in the EXISTING (statement-level) behaviour');
end;

procedure TInstructionStepDapTests.X64_StepIn_GranularityStatement_StillAdvancesToNewLine;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var LineBefore := CurrentLine;
  FClient.StepIn(1, 'statement').Free;
  var Stopped := FClient.WaitForStopped;
  Stopped.Free;
  Assert.AreNotEqual(LineBefore, CurrentLine,
    'granularity:"statement" stepIn did not advance to a new source line -- ' +
    'this is a regression in the EXISTING (statement-level) behaviour');
end;

procedure TInstructionStepDapTests.X64_Next_GranularityAbsent_StillAdvancesToNewLine;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var LineBefore := CurrentLine;
  FClient.StepOver.Free;                    // no granularity argument at all
  var Stopped := FClient.WaitForStopped;
  Stopped.Free;
  Assert.AreNotEqual(LineBefore, CurrentLine,
    'granularity-absent next did not advance to a new source line -- ' +
    'this is a regression in the EXISTING (statement-level) behaviour');
end;

// The one engine-level refusal reliably reachable from outside the process:
// there is nothing to step before a target is launched. Proves the ROUTING --
// a refused instruction step must come back as success:false with a reason,
// never a silent success (the pre-existing next/stepIn/stepOut handlers all
// answer success unconditionally, before even checking FLaunched).
procedure TInstructionStepDapTests.Refused_WhenNotLaunched_ReachesClientAsFailedRequest;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  var Resp := FClient.StepInRaw(1, 'instruction');
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'an instruction-granularity stepIn before launch was accepted -- ' +
      'there is nothing to step');
    // TDapIO.SendErrorResponse (DapProtocol.pas) carries the reason at
    // body.error.format, the DAP ErrorResponse shape -- there is no
    // top-level `message` field on this path.
    var Msg := '';
    var BodyObj := Resp.GetValue<TJSONObject>('body', nil);
    if BodyObj <> nil then begin
      var ErrObj := BodyObj.GetValue<TJSONObject>('error', nil);
      if ErrObj <> nil then
        Msg := ErrObj.GetValue<string>('format', '');
    end;
    Assert.IsTrue(Msg <> '', 'the failed response carries no reason: ' + Resp.ToJSON);
  finally
    Resp.Free;
  end;
end;

initialization
  // EXPLICIT registration: this project does not use RTTI auto-scan, and an
  // unregistered fixture silently never runs (docs/TRAPS.md).
  TDUnitX.RegisterTestFixture(TInstructionStepDapTests);

end.
