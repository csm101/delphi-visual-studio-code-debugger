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
  end;

implementation

uses
  System.SysUtils, System.JSON;

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
// Wow64Get/SetThreadContext pair, and GetRegisters zero-extends whatever that
// pair actually holds into the 64-bit row DAP displays.
procedure TRegisterWriteDapTests.Win32_SetVariable_Register_WritesAndReadsBack;
const
  SENTINEL = '0x11223344';
begin
  OpenSampleAt('Win32', MARKER);
  var RegistersRef := FindRegistersRef;

  var SetResp := FClient.SetVariable(RegistersRef, 'RAX', SENTINEL);
  SetResp.Free;

  var Value := RegisterValue(RegistersRef, 'RAX');
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

initialization
  TDUnitX.RegisterTestFixture(TRegisterWriteDapTests);

end.
