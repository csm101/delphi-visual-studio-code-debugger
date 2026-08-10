unit RegisterWriteDapTests;

// DAP-layer proof for ASSEMBLY_LEVEL_DEBUGGING.md increment 6: `setVariable`
// on the `Registers` scope shares the exact engine path MCP's `set_register`
// does (DapServer.HandleSetVariable -> TDebugSession.SetRegister ->
// IDebugTarget.SetRegisterByName), so whatever the fix does at the engine
// level applies here identically -- and does, per these tests. No DAP-level
// test of writing the Registers scope existed before this file, on either
// bitness.
//
// The write side of that path had no WOW64 override, unlike the read side.
// Measured (DevTools\Wow64RegWriteProbe.dpr): at a REAL breakpoint the native
// GetThreadContext/SetThreadContext pair the unfixed base class used actually
// aliases correctly with Wow64Get/SetThreadContext on this Windows build, for
// every general-purpose AND control register (RIP/RSP/RBP included) -- so the
// round-trip tests below are regression guards, not RED controls; they pass
// with or without the fix. R8..R15 do not exist on x86 at any width, though,
// and THAT is a real, reachable, RED-without-the-fix defect: the unfixed base
// class accepted the name and reported success while writing a register that
// means nothing on x86.

interface

uses
  DUnitX.TestFramework, DapClient;

type
  [TestFixture]
  TRegisterWriteDapTests = class
  private
    FClient: TDapClient;
    procedure OpenSampleAt(const Bitness, Marker: string);
    function  FindRegistersRef: Integer;
    function  RegisterValue(RegistersRef: Integer; const Name: string): string;
  public
    [TearDown] procedure TearDown;

    // Control: the same round trip already proven at the MCP layer
    // (SetRegister_WritesAndReadsBack), driven through the DAP wire instead.
    [Test] procedure X64_SetVariable_Register_WritesAndReadsBack;
    // Regression guard, not a RED control on its own -- see the header
    // comment. Proves the round trip still holds through the DAP wire with
    // the WOW64 override in place.
    [Test] procedure Win32_SetVariable_Register_WritesAndReadsBack;
    // R8..R15 do not exist on x86 at any width. Before the fix this SUCCEEDED
    // (the unmodified base name-matching accepted "R8" and wrote a native
    // context field that reaches nothing) -- a silent no-op reported as a
    // successful edit. Must be a real DAP error response instead. The real
    // RED control for this increment.
    [Test] procedure Win32_SetVariable_Register_ExtendedRegister_Refused;
    // The write reached the register, but the RESPONSE carried an empty body.
    // DAP says a successful setVariable answers with the new `value`, and VS
    // Code takes that literally: it replaces the row it is showing with the
    // response, so an absent `value` blanks the register in the Variables view
    // -- the name is left standing with nothing after it. Reported from the
    // GUI; neither bitness had a test that looked at the response at all.
    [Test] procedure X64_SetVariable_Register_ResponseCarriesNewValue;
    [Test] procedure Win32_SetVariable_Register_ResponseCarriesNewValue;
    // Register names follow the TARGET's bitness. The Registers scope used to
    // report the 64-bit superset the snapshot record is built on, whatever the
    // target was, so a 32-bit session showed RAX (zero-extended, 16 hex digits)
    // and eight R8..R15 rows reading 0 for registers the CPU does not have.
    [Test] procedure Win32_Registers_UseX86Names;
    // ...and the rename does not strand a caller holding the other spelling.
    [Test] procedure Win32_SetVariable_Register_AcceptsEitherSpelling;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.JSON;

const
  SAMPLE_SOURCE = 'InstructionStepSample.dpr';
  MARKER        = 'INSTR_MULTI';

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

procedure TRegisterWriteDapTests.OpenSampleAt(const Bitness, Marker: string);
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

procedure TRegisterWriteDapTests.TearDown;
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

function TRegisterWriteDapTests.FindRegistersRef: Integer;
begin
  var FrameId := FClient.GetFrameId;
  var ScopesResp := FClient.Scopes(FrameId);
  try
    var Arr := ScopesResp.GetValue('scopes') as TJSONArray;
    Assert.IsTrue(Arr <> nil, 'no scopes array');
    Result := 0;
    for var I := 0 to Arr.Count - 1 do begin
      var S := Arr[I] as TJSONObject;
      if SameText(S.GetValue<string>('name', ''), 'Registers') then
        Result := S.GetValue<Integer>('variablesReference', 0);
    end;
    Assert.IsTrue(Result > 0, 'no Registers scope');
  finally
    ScopesResp.Free;
  end;
end;

function TRegisterWriteDapTests.RegisterValue(RegistersRef: Integer;
  const Name: string): string;
begin
  var RegsResp := FClient.Variables(RegistersRef);
  try
    var Arr := RegsResp.GetValue('variables') as TJSONArray;
    Assert.IsTrue((Arr <> nil) and (Arr.Count > 0), 'Registers scope returned no rows');
    Result := '';
    for var I := 0 to Arr.Count - 1 do begin
      var R := Arr[I] as TJSONObject;
      if SameText(R.GetValue<string>('name', ''), Name) then
        Result := R.GetValue<string>('value', '');
    end;
    Assert.IsTrue(Result <> '', 'no ' + Name + ' in Registers scope: ' + Arr.ToJSON);
  finally
    RegsResp.Free;
  end;
end;

{ ---------------------------------------------------------------- tests ---- }

procedure TRegisterWriteDapTests.X64_SetVariable_Register_WritesAndReadsBack;
const
  SENTINEL = '0x1122334455667788';
begin
  OpenSampleAt('Win64', MARKER);
  var RegistersRef := FindRegistersRef;

  var SetResp := FClient.SetVariable(RegistersRef, 'RAX', SENTINEL);
  SetResp.Free;

  var Value := RegisterValue(RegistersRef, 'RAX');
  Assert.IsTrue(Value.Contains('1122334455667788'),
    Format('Win64: a later, independent variables request does not see the write -- got "%s"',
      [Value]));
end;

// Same shape as the x64 control, but the sentinel fits the real 32-bit
// register width -- the write goes through TWin32Debugger.SetRegisterByName's
// Wow64Get/SetThreadContext pair. The row is named EAX here: register names
// follow the target's bitness. Writing it by its 64-bit spelling is the point
// of Win32_SetVariable_Register_AcceptsEitherSpelling below.
procedure TRegisterWriteDapTests.Win32_SetVariable_Register_WritesAndReadsBack;
const
  SENTINEL = '0x11223344';
begin
  OpenSampleAt('Win32', MARKER);
  var RegistersRef := FindRegistersRef;

  var SetResp := FClient.SetVariable(RegistersRef, 'EAX', SENTINEL);
  SetResp.Free;

  var Value := RegisterValue(RegistersRef, 'EAX');
  Assert.IsTrue(Value.Contains('11223344'),
    Format('Win32: a later, independent variables request does not see the write -- got "%s"',
      [Value]));
end;

procedure TRegisterWriteDapTests.Win32_SetVariable_Register_ExtendedRegister_Refused;
begin
  OpenSampleAt('Win32', MARKER);
  var RegistersRef := FindRegistersRef;

  var Resp := FClient.SetVariableRaw(RegistersRef, 'R8', '0x1');
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'Win32: writing R8 (no such x86 register) should be a failed DAP response, ' +
      'never a silently-accepted no-op: ' + Resp.ToJSON);
    var Body := Resp.GetValue('body') as TJSONObject;
    var ErrObj := (Body <> nil) and (Body.GetValue('error') <> nil);
    Assert.IsTrue(ErrObj, 'refusal carries no body.error: ' + Resp.ToJSON);
    var ErrFmt := (Body.GetValue('error') as TJSONObject).GetValue<string>('format', '');
    Assert.IsTrue(ErrFmt.Contains('R8'), 'refusal does not name the register: ' + ErrFmt);
  finally
    Resp.Free;
  end;
end;

// RED without the fix on both bitnesses: the response body was created empty
// and sent as-is. The assertion is not just "non-empty" but "identical to what
// the Registers scope reports for the same register", because the response is
// what the client displays until the next variables request -- if the two
// disagree the row shows one thing and means another.
procedure TRegisterWriteDapTests.X64_SetVariable_Register_ResponseCarriesNewValue;
const
  SENTINEL = '0x1122334455667788';
begin
  OpenSampleAt('Win64', MARKER);
  var RegistersRef := FindRegistersRef;

  var Echoed: string;
  var SetResp := FClient.SetVariable(RegistersRef, 'RAX', SENTINEL);
  try
    Echoed := SetResp.GetValue<string>('value', '');
    Assert.IsTrue(Echoed <> '',
      'Win64: setVariable answered without a `value`; VS Code blanks the row: ' + SetResp.ToJSON);
  finally
    SetResp.Free;
  end;

  Assert.AreEqual(RegisterValue(RegistersRef, 'RAX'), Echoed,
    'Win64: the setVariable response and the Registers scope disagree about RAX');
end;

procedure TRegisterWriteDapTests.Win32_SetVariable_Register_ResponseCarriesNewValue;
const
  SENTINEL = '0x11223344';
begin
  OpenSampleAt('Win32', MARKER);
  var RegistersRef := FindRegistersRef;

  var Echoed: string;
  var SetResp := FClient.SetVariable(RegistersRef, 'EAX', SENTINEL);
  try
    Echoed := SetResp.GetValue<string>('value', '');
    Assert.IsTrue(Echoed <> '',
      'Win32: setVariable answered without a `value`; VS Code blanks the row: ' + SetResp.ToJSON);
  finally
    SetResp.Free;
  end;

  Assert.AreEqual(RegisterValue(RegistersRef, 'EAX'), Echoed,
    'Win32: the setVariable response and the Registers scope disagree about EAX');
end;

// The Registers scope on a 32-bit target must describe a 32-bit machine: E-named
// rows, 8 hex digits, and no R8..R15 at all. Before this, every target reported
// the 64-bit superset the register SNAPSHOT is built on -- so a WOW64 session
// showed "RAX" holding a zero-extended EAX in 16 hex digits, and eight extended
// registers reading 0 that the CPU does not have at that width.
procedure TRegisterWriteDapTests.Win32_Registers_UseX86Names;
begin
  OpenSampleAt('Win32', MARKER);
  var RegistersRef := FindRegistersRef;

  var Names := TStringList.Create;
  try
    var RegsResp := FClient.Variables(RegistersRef);
    try
      var Arr := RegsResp.GetValue('variables') as TJSONArray;
      Assert.IsTrue((Arr <> nil) and (Arr.Count > 0), 'Registers scope returned no rows');
      for var I := 0 to Arr.Count - 1 do
        Names.Add((Arr[I] as TJSONObject).GetValue<string>('name', ''));
    finally
      RegsResp.Free;
    end;

    for var Expected in ['EIP', 'ESP', 'EBP', 'EAX', 'EBX', 'ECX', 'EDX', 'ESI', 'EDI'] do
      Assert.IsTrue(Names.IndexOf(Expected) >= 0,
        Format('Win32: no %s row; got %s', [Expected, Names.CommaText]));
    for var Absent in ['RIP', 'RAX', 'R8', 'R15'] do
      Assert.IsTrue(Names.IndexOf(Absent) < 0,
        Format('Win32: %s is not a register of a 32-bit target; got %s',
          [Absent, Names.CommaText]));
  finally
    Names.Free;
  end;

  // Width follows the name. The 64-bit rendering is '0x' + 16 hex digits with
  // the decimal in parentheses after it; the 32-bit one is '0x' + 8 and nothing
  // else, so the length alone separates them without depending on the value.
  var Eax := RegisterValue(RegistersRef, 'EAX');
  Assert.AreEqual(10, Length(Eax),
    'Win32: EAX is not rendered at 32-bit width: ' + Eax);
end;

// The rename must not break a caller that learnt the 64-bit spelling: "RAX"
// still reaches EAX on a 32-bit target. What is REPORTED back is the name the
// target owns, so the response says EAX even though the request said RAX.
procedure TRegisterWriteDapTests.Win32_SetVariable_Register_AcceptsEitherSpelling;
const
  SENTINEL = '0x55667788';
begin
  OpenSampleAt('Win32', MARKER);
  var RegistersRef := FindRegistersRef;

  var Resp := FClient.SetVariableRaw(RegistersRef, 'RAX', SENTINEL);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False),
      'Win32: the 64-bit spelling of a register the target has should still be writable: '
      + Resp.ToJSON);
  finally
    Resp.Free;
  end;

  var Value := RegisterValue(RegistersRef, 'EAX');
  Assert.IsTrue(Value.Contains('55667788'),
    Format('Win32: a write named RAX did not reach EAX -- got "%s"', [Value]));
end;

initialization
  TDUnitX.RegisterTestFixture(TRegisterWriteDapTests);

end.
