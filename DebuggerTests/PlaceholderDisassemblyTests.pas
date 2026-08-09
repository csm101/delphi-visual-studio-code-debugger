unit PlaceholderDisassemblyTests;

// ASSEMBLY_LEVEL_DEBUGGING.md increment 5: the placeholder document a
// sourceless frame gets now carries real disassembly around the frame's PC,
// not just a paragraph explaining why there is no source. Measured 2026-08-09
// in VS Code: selecting a sourceless frame opens the ADAPTER'S placeholder
// document, not the client's own Disassembly View -- the placeholder does not
// compete with disassembly, it precludes it, so its content has to carry the
// weight on its own.
//
// Fixture: the SAME mechanism `Test_SourcelessFrame_HasPlaceholderDocument`
// (DebuggerTests.pas) already proves reaches a genuinely sourceless frame --
// TestTarget.exe launched with `--run-threads`, breakpoint at THREADS_READY
// on the main thread, then a `stackTrace` on the spawned worker thread, which
// is parked in Sleep(INFINITE) and therefore bottoms out inside ntdll/kernel32
// (Symbols = saNoSymbols: no Delphi debug info of any kind for that module).
// Deliberately NOT the NoSourceStop.dpr `-rtl`/`-os` fixture: measured (both
// via this DAP wire and independently via DevTools\LiveSessionProbe, so not a
// harness artifact) that an EXCEPTION stop's reported frame 0 does not land on
// the true faulting address in code with no debug info -- it resolves to the
// CALLING Delphi frame instead (e.g. `FaultInsideRtl` at the `Move(...)` call
// line, WITH real source), so that path never reaches the placeholder at all.
// That is a pre-existing stack-walk behaviour independent of this increment
// (TWinDebugger.GetStackFrames/WalkRawFrames for an exception-stopped thread);
// flagged for separate investigation rather than routed around silently. See
// the increment-5 report for the full comparison.

interface

uses
  DUnitX.TestFramework, DapClient;

type
  [TestFixture]
  TPlaceholderDisassemblyTests = class
  private
    FClient: TDapClient;
    // Launches TestTarget.exe --run-threads, stops the MAIN thread at
    // THREADS_READY, finds the spawned worker thread (parked in
    // Sleep(INFINITE), so it is reliably still running --unlike the main
    // thread's own frame, which is a real breakpoint stop with real source),
    // and returns the placeholder text for the first sourceless frame on the
    // WORKER's own stack.
    function StopAndGetWorkerPlaceholderText: string;
  public
    [TearDown] procedure TearDown;

    // The disassembly section, the current-instruction marker and the safe
    // (non-instructing) Disassembly View wording must all be present, and the
    // saNoSymbols reason (no Delphi debug info of any kind) must still show.
    [Test] procedure Win64_WorkerParkedInNtdll_PlaceholderShowsDisassemblyWithCurrentMarker;
    // A regression guard on the ALREADY-PASSING assertions
    // Test_SourcelessFrame_HasPlaceholderDocument makes, run again here so a
    // change to SyntheticSourceText that broke the header would fail two
    // independent tests, not one.
    [Test] procedure Win64_WorkerParkedInNtdll_HeaderStillNamesAddressAndStoppedState;
  end;

implementation

uses
  System.SysUtils, System.JSON;

const
  // THREADS_READY lives in TestTargetCore.pas (spawns the worker threads),
  // not in TestTarget.dpr's own program body -- see TDebuggerTests.Bp's
  // marker search order in DebuggerTests.pas.
  SAMPLE_SOURCE = 'TestTargetCore.pas';
  MARKER        = 'THREADS_READY';

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

function TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

function TargetMap: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

function TargetRsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

{ ------------------------------------------------------------------ setup -- }

function TPlaceholderDisassemblyTests.StopAndGetWorkerPlaceholderText: string;
begin
  var Line := FindBpLine(SamplePath, MARKER);
  Assert.IsTrue(Line > 0, 'marker ' + MARKER + ' not found in ' + SAMPLE_SOURCE);
  Assert.IsTrue(FileExists(TargetExe), 'fixture not built: ' + TargetExe);

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  FClient.SetBreakpoints(SamplePath, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False, ['--run-threads']).Free;
  FClient.ConfigDone.Free;

  var Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      Format('did not stop at %s (line %d); got reason: %s',
        [MARKER, Line, Stopped.GetValue<string>('reason', '')]));
  finally
    Stopped.Free;
  end;

  var WorkerTid := 0;
  var ThResp := FClient.Threads;
  try
    var Arr := ThResp.GetValue<TJSONArray>('threads');
    Assert.IsNotNull(Arr, 'threads request returned no array');
    for var I := 0 to Arr.Count - 1 do begin
      var T := Arr.Items[I] as TJSONObject;
      if T.GetValue<string>('name', '').Contains('TestWorker') then begin
        WorkerTid := T.GetValue<Integer>('id', 0);
        Break;
      end;
    end;
  finally
    ThResp.Free;
  end;
  Assert.IsTrue(WorkerTid > 0, 'no worker thread found in the threads list');

  var Ref := 0;
  var ST := FClient.StackTrace(WorkerTid);
  try
    var Frames := ST.GetValue<TJSONArray>('stackFrames');
    Assert.IsNotNull(Frames, 'stackTrace for the worker returned no frames array');
    for var I := 0 to Frames.Count - 1 do begin
      var F   := Frames.Items[I] as TJSONObject;
      var Src := F.GetValue<TJSONObject>('source', nil);
      if Src = nil then
        Continue;
      if Src.GetValue<string>('path', '') <> '' then
        Continue;   // a real file: not the sourceless case under test
      Ref := Src.GetValue<Integer>('sourceReference', 0);
      if Ref > 0 then
        Break;
    end;
  finally
    ST.Free;
  end;
  Assert.IsTrue(Ref > 0,
    'no frame on the parked worker''s stack offered a placeholder sourceReference ' +
    '(the bottom of that stack is ntdll/kernel32 and cannot have source)');

  var Resp := FClient.SourceContent(Ref);
  try
    Result := Resp.GetValue<string>('content', '');
  finally
    Resp.Free;
  end;
end;

procedure TPlaceholderDisassemblyTests.TearDown;
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

{ ---------------------------------------------------------------- tests ---- }

procedure TPlaceholderDisassemblyTests.Win64_WorkerParkedInNtdll_PlaceholderShowsDisassemblyWithCurrentMarker;
begin
  var Content := StopAndGetWorkerPlaceholderText;
  Assert.IsTrue(Content.Contains('no debug information of any kind was found'),
    'ntdll/kernel32 have no Delphi debug info at all -- the saNoSymbols reason must show; got: ' + Content);
  // The actual new behaviour: a disassembly section with the current
  // instruction clearly marked. RED without the fix -- SyntheticSourceText
  // used to stop after the explanatory paragraph.
  Assert.IsTrue(Content.Contains('Disassembly around the current instruction'),
    'placeholder must carry a disassembly section; got: ' + Content);
  Assert.IsTrue(Content.Contains('=> 0x'),
    'the current instruction must be clearly marked (=>); got: ' + Content);
  Assert.IsTrue(Content.Contains('<-- current instruction'),
    'the current-instruction line must say so in words, not just an arrow; got: ' + Content);
  // No Delphi provider covers ntdll/kernel32, so every annotated line must say
  // so explicitly rather than leave a blank column.
  Assert.IsTrue(Content.Contains('(no symbol)'),
    'an instruction with no known symbol must say so, not render blank; got: ' + Content);
  // Constraint: never claim the Call Stack context menu offers "Open
  // Disassembly View" -- that was never confirmed to exist.
  Assert.IsFalse(Content.Contains('Open Disassembly View'),
    'must not instruct the reader to click a menu item nobody confirmed exists; got: ' + Content);
  Assert.IsTrue(Content.Contains('where it offers one'),
    'the Disassembly View reference must be phrased conditionally; got: ' + Content);
end;

procedure TPlaceholderDisassemblyTests.Win64_WorkerParkedInNtdll_HeaderStillNamesAddressAndStoppedState;
begin
  var Content := StopAndGetWorkerPlaceholderText;
  Assert.IsTrue(Content.Contains('No source available'),
    'placeholder must still say there is no source; got: ' + Content);
  Assert.IsTrue(Content.Contains('The debugger IS stopped here'),
    'placeholder must still state the target IS stopped; got: ' + Content);
end;

initialization
  TDUnitX.RegisterTestFixture(TPlaceholderDisassemblyTests);

end.
