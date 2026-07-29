unit DebugSessionTests;

// Protocol-free tests for the TDebugSession core facade. These construct a
// TDebugSession directly (NO DAP client, NO JSON) and drive it against the same
// TestTarget.exe fixture the DAP suite uses. They are the primary regression net
// for the reusable core that both the DAP and MCP frontends sit on.

interface

uses
  DUnitX.TestFramework;

type
  // Win32 target support. Deliberately a SEPARATE fixture rather than a
  // bitness subclass of TDebugSessionTests: most of those 49 tests inspect
  // variables, which a 32-bit target cannot do yet, so subclassing would land a
  // large block of red that says nothing. This fixture covers exactly what x86
  // run control claims to do, and grows as capability lands.
  //
  // The 32-bit target is the SAME sources built with dcc32 (see
  // build_target.bat), so any behavioural difference is the debugger's, not the
  // fixture's.
  [TestFixture]
  TWin32RunControlTests = class
  private
    function RepoRoot: string;
    function TargetDir: string;
    function Win32Exe: string;
    function Win32Map: string;
    function Win32Rsm: string;
    function Win64Exe: string;
    function Win64Map: string;
    function Win64Rsm: string;
    function MarkerLine(const SourceBaseName, Marker: string): Integer;
    function MarkerLineInFile(const SourcePath, Marker: string): Integer;
  public
    // A breakpoint on a 32-bit target must bind and fire, and report the line
    // the user asked for.
    [Test] procedure Win32_Breakpoint_BindsAndFires;
    // The call stack must unwind past the recursion into the caller chain --
    // this is what StackWalk64 with IMAGE_FILE_MACHINE_I386 buys.
    [Test] procedure Win32_CallStack_UnwindsPastRecursion;
    // The strongest of the three: the SAME marker on both bitnesses must give
    // the same function names in the same order. It catches a demangler
    // regression, a stack-walk regression and a symbol-resolution regression
    // without asserting any hardcoded name.
    [Test] procedure Win32_StackFrameNames_MatchWin64;
    // Structural invariants of the walk itself: a frame's PC is CODE and a
    // caller's frame sits at a HIGHER address than its callee's. dbghelp's i386
    // unwind broke both in the field, returning a stack address as the caller's
    // PC and losing the real caller with it.
    [Test] procedure Win32_CallStack_FramesAreCodeAndFramePointersAscend;
    // A breakpoint placed on a routine's `begin` line resolves to the routine's
    // ENTRY, where the prologue has not spilled Self or the by-register
    // parameters yet, so every local reads the CALLER's frame. Both bitnesses
    // must report the values actually passed.
    [Test] procedure BreakpointOnBeginLine_ReportsPassedParameters;
    // Stack locals. Covers the x86 prologue decoder (`add esp,-N` rather than
    // `sub esp,N`, `mov ebp,esp` before the allocation) and the zero offset
    // bases that follow from it. Compared against x64 rather than asserted
    // literally, for the same reason as the frame names.
    [Test] procedure Win32_Locals_MatchWin64;
    // Object expansion: the VMT header (is this a class instance, what class),
    // the field table, and the width of every pointer-shaped field read. A
    // 32-bit target reading those 8 bytes wide splices the neighbouring field
    // into the high half and yields an address outside its own range, so a
    // string field renders as a read failure rather than an error.
    [Test] procedure Win32_ObjectFields_MatchWin64;
    // Expression evaluation, including a getter-backed property. That last one
    // is the sharpest test of the calling convention available: it hijacks the
    // stopped thread, runs real code in the debuggee with arguments placed the
    // way Delphi's 32-bit `register` convention expects, and reads the result
    // back out of EAX.
    [Test] procedure Win32_Evaluate_MatchesWin64;
    // The whole float family, because Win32 returns ALL of it on the x87 stack
    // -- Currency included, which Win64 instead returns as a scaled Int64 in an
    // integer register (measured: DevTools\Win32FloatAbiProbe). The debugger
    // converts the 80-bit register to Double bits on the way out, and two types
    // need that undone again: a Single otherwise reads as the low half of a
    // Double (i.e. 0), and a Currency as a nonsense trillions figure. Both
    // failure modes produce a plausible wrong NUMBER rather than an error,
    // which is why the values are asserted against the literals the getters
    // return rather than merely compared across bitnesses.
    [Test] procedure Win32_FloatFamilyReturns_MatchTheDeclaredValues;
    // The x87 stack is only eight registers deep, and a float-returning callee
    // leaves its result on it -- popping that is the CALLER's job, and the
    // capture stub is not the caller. What discards it is the synthetic-call
    // pump restoring a thread context saved with CONTEXT_FLOATING_POINT. Drop
    // that one flag and every float evaluation leaks a slot, with nothing going
    // wrong until the eighth. Ten evaluations in a single session is past the
    // wrap point, so this fails if that restore is ever weakened.
    [Test] procedure Win32_RepeatedFloatEvaluations_DoNotExhaustTheX87Stack;
    // Two float types do not fit the 8-byte slot every value is decoded into:
    // Extended is 10 bytes of x87 on Win32 (though a plain Double on Win64), and
    // Real48 is the 6-byte pre-8087 software float on both. Reading either at
    // the wrong width fails silently and spectacularly -- taking 8 of an
    // Extended's 10 bytes keeps the mantissa and drops the exponent, which
    // reported 2.75 as -1.7E-77.
    [Test] procedure Win32_WideFloatLocals_ReadTheirFullWidth;
    // Records and dynamic arrays are expanded by walking the DEBUGGEE's own
    // RTTI tables, whose every entry is pointer-width: TRecordTypeField is
    // 2*ptr+1 bytes, not a constant 17, and tkDynArray's elType2 sits at
    // 8+ptr, not a constant 16. Object-field expansion did not catch this
    // because it takes a different table, so these two shapes need their own
    // cross-bitness check.
    [Test] procedure Win32_RecordAndDynArrayExpansion_MatchWin64;
    // The write direction of the same problem. Setting a variable encodes the
    // new value into the TARGET's representation, and the generic encoder emits
    // 8 bytes of IEEE double for anything it calls a float -- which for a
    // 10-byte Win32 Extended leaves the sign and exponent bytes holding the
    // variable's PREVIOUS contents, and for a 6-byte Real48 is not even the
    // same format. The readback here goes through target memory, so it is a
    // genuine round trip rather than an echo of what was requested.
    [Test] procedure Win32_SetWideFloatLocals_RoundTrip;
    // Passing arguments INTO a call the debugger injects. Delphi's 32-bit
    // `register` convention treats argument classes very differently -- only a
    // non-float that fits 32 bits competes for EAX/EDX/ECX, everything else
    // goes on the stack at 4, 8 or 12 bytes and consumes no register slot --
    // so a single test method takes one of each, interleaved with ordinals, and
    // weights them by distinct powers of two. Any argument landing in the wrong
    // place changes the total, and the deficit names it.
    [Test] procedure Win32_SyntheticCallArguments_MatchWin64;
    // A Delphi exception stop must name the class and carry the message on both
    // architectures. Reading either means walking the raised object's VMT, and
    // the VMT slot offsets plus the pointer width are bitness-specific -- a
    // 64-bit read on a 32-bit target lands nowhere, and the whole stop degrades
    // to a bare "Delphi exception at ...": no class, no message, no $exception
    // pseudo-local (it is only published once the class read succeeds), and
    // therefore no working exception-type filters.
    [Test] procedure Win32_ExceptionStop_NamesClassAndMessage;
    // Stepping. Inherited from the architecture-neutral base, but it rides on
    // SetThreadTrapFlag and the WOW64 single-step status code, both of which
    // are 32-bit specific -- and STATUS_WX86_SINGLE_STEP was measured rather
    // than assumed, so it deserves a test that actually steps.
    [Test] procedure Win32_StepInto_LandsInTheCallee;
    [Test] procedure Win32_StepOver_AdvancesWithinTheSameFrame;
    // Step over a call whose FOURTH argument goes on the stack, i.e. directly
    // above the return address the CALL pushes. Reading that return address at
    // host width splices the argument into its high half and the run-to-return
    // breakpoint is planted nowhere, so the step never completes.
    [Test] procedure Win32_StepOverCallWithStackArgument_LandsOnTheNextLine;
    // An application split across runtime packages is this project's core use
    // case and the shape where debugger bugs have historically surfaced, so it
    // has to hold on both bitnesses rather than only x64. The breakpoint is
    // deferred here -- the package is not loaded when it is set -- so this also
    // covers binding a breakpoint to a module that arrives later.
    [Test] procedure Win32_Bpl_BreakpointInPackage_FiresWithLocals;
  end;

  [TestFixture]
  TDebugSessionTests = class
  private
    function RepoRoot: string;
    function TargetDir: string;
    function TargetExe: string;
    function TargetMap: string;
    function TargetRsm: string;
    function NoDebugExe: string;
    function TdsSampleExe: string;
    function HostExe: string;
    function HostMap: string;
    function HostRsm: string;
    function PackageSrc: string;
    function MarkerLineInFile(const SourcePath, Marker: string): Integer;
    function MarkerLine(const SourceBaseName, Marker: string): Integer;
  public
    [Test] procedure Launch_StopsAtBreakpoint;
    [Test] procedure Locals_AtEvalBody_ExposeCaption;
    [Test] procedure Evaluate_FieldAccess_ReturnsValue;
    [Test] procedure Snapshot_HasLocationAndLocals;
    [Test] procedure ExpandVariable_Widget_ExposesFields;
    [Test] procedure ExpandVariable_NestedRecord;
    [Test] procedure Breakpoint_Condition_True_Stops;
    [Test] procedure Breakpoint_Condition_False_RunsToExit;
    [Test] procedure Breakpoint_Logpoint_EmitsAndContinues;
    [Test] procedure Breakpoint_HitCount_SkipsEarlyHits;
    [Test] procedure ExpandVariable_DynArray_Elements;
    [Test] procedure ExpandVariable_Widget_GroupsProperties;
    [Test] procedure ExpandVariable_PropertyGetter_RunsGetter;
    [Test] procedure ExpandVariable_IndexedProperty_IsLeaf;
    [Test] procedure ExpandVariable_VariantArray1D_Elements;
    [Test] procedure ExpandVariable_VariantArray2D_Elements;
    [Test] procedure Bpl_Breakpoint_InPackageUnit_Stops;
    // F22: ListBreakpoints (what the MCP frontend serialises) reported a
    // breakpoint as unverified even after the owning package had loaded and the
    // breakpoint had actually FIRED.
    [Test] procedure Bpl_ListBreakpoints_ReportsVerified_AfterPackageLoads;
    [Test] procedure Bpl_CallStack_ResolvesDeeperFrames;
    [Test] procedure Bpl_StackWalk_AfterEarlyWalk_ResolvesFramesAndStepsOut;
    [Test] procedure GetVariable_LocalAndExpression;
    [Test] procedure Attach_ToRunningTarget_Stops;
    [Test] procedure AttachConfig_ParsesSelectorAndPaths;
    // Step-0 superset additions (frontend-neutral core superset of the DAP needs).
    [Test] procedure Threads_StoppedThreadIsCurrent;
    [Test] procedure PerThreadStep_StepsOnlySelectedThread;
    // F19: a step-into used to report at the callee's ENTRY address, before the
    // prologue had spilled the register arguments into their home slots, so Self
    // and every by-register parameter read as the CALLER's leftover frame bytes
    // -- with a correct-looking type and no warning.
    [Test] procedure StepInto_Method_ReportsSpilledSelfAndParams;
    // Wrong-place audit (2026-07-19): a frame INDEX is only meaningful together
    // with its thread. Selecting a frame the client took from ANOTHER thread's
    // stackTrace used to pair that index with the STOPPED thread's cached frames,
    // so the Variables panel showed a complete, plausible set of locals belonging
    // to a different thread.
    [Test] procedure SelectFrame_OnOtherThread_ReadsThatThreadsLocals;
    [Test] procedure Frames_RichFieldsPopulated;
    [Test] procedure SelectFrame_CallerLocalsDiffer;
    [Test] procedure Registers_HaveRipAndRsp;
    [Test] procedure ResolveSourcePath_ResolvesCoreUnit;
    [Test] procedure RemoveAllBreakpoints_ClearsPlantedInt3;
    [Test] procedure EvaluateForFrame_ClassIsExpandable_ScalarIsLeaf;
    // Step-5 write path (setVariable delegated onto the session core).
    [Test] procedure SetLocalVariable_Integer_ReadsBackChanged;
    [Test] procedure SetLocalVariable_EnumByName_ReadsBackChanged;
    [Test] procedure SetLocalVariable_String_ReadsBackChanged;
    [Test] procedure SetFieldVariable_ViaClassHandle_WritesField;
    [Test] procedure Terminate_ReapsDebuggeeProcess;
    [Test] procedure Terminate_ReleasesSymbolFileLock;
    [Test] procedure Pause_RetargetsToUserThread;
    [Test] procedure ExceptionFilters_ParseNames;
    [Test] procedure DeepNested_LocalsResolveAtDepth2;
    [Test] procedure DeepNested_LocalsResolveAtExceptionStop;
    [Test] procedure MainModule_NoDebugInfo_ReportsDiagnostic;
    // F23: a nameless frame used to be reported blank, so "unknown address",
    // "module without debug info" and "index still building" were the same
    // rendering. A frame in a module with no debug info must still name the
    // module and say WHY it has no symbols.
    [Test] procedure Frames_NoDebugInfoModule_ReportModuleAndSymbolState;
    [Test] procedure Tds_MainModule_LoadsExternalTds;
    [Test] procedure Tds_StaleTds_Ignored;
    // Background symbol prefetch: with NO breakpoint anywhere -- the state a
    // debugger is in right after attaching -- a runtime-loaded package used to be
    // parsed for the first time at the stop that needed it, which is where the
    // nameless frames and the multi-second pause came from. Its symbols must now
    // already be there.
    [Test] procedure Prefetch_NoBreakpoints_LoadsRuntimePackageSymbols;
    // The prefetch worker must never parse a module the dispatch thread is also
    // parsing: a second reader for the same module would register a duplicate
    // provider (every local reported twice) or be built against a module record
    // that has already moved on.
    [Test] procedure Prefetch_ModuleLoadedSynchronously_IsNotParsedAgain;
  end;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  DebugSession, DebugSessionTypes, DebugInfoTypes, DebugTarget, LaunchConfig,
  ModuleSymbolLoader;

const
  EVAL_MARKER = 'EVAL_BODY';
  EVAL_SOURCE = 'TestTargetCore.pas';

function TDebugSessionTests.RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TDebugSessionTests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function TDebugSessionTests.TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

function TDebugSessionTests.TargetMap: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

function TDebugSessionTests.TargetRsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

function TDebugSessionTests.NoDebugExe: string;
begin
  Result := TargetDir + 'Win64\Debug\NoDebugExe.exe';
end;

function TDebugSessionTests.TdsSampleExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TdsSample.exe';
end;

function TDebugSessionTests.HostExe: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.exe';
end;

function TDebugSessionTests.HostMap: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.map';
end;

function TDebugSessionTests.HostRsm: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.rsm';
end;

function TDebugSessionTests.PackageSrc: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage\TestPkgUnit.pas';
end;

function TDebugSessionTests.MarkerLineInFile(const SourcePath, Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then
        Exit(I + 1);  // 1-based
  finally
    Lines.Free;
  end;
end;

function TDebugSessionTests.MarkerLine(const SourceBaseName, Marker: string): Integer;
begin
  Result := MarkerLineInFile(TargetDir + SourceBaseName, Marker);
end;

// Launches the target, plants a breakpoint at the marker, and pumps until the
// session reports a stop (event-driven; the per-event 10 ms wait paces it -- no
// arbitrary sleeps). Bounded by a wall-clock deadline so a hang fails the test
// rather than blocking forever. The caller owns Session.Free.
function OpenSessionAtMarker(const ExePath, MapPath, RsmPath, SourceRoot,
  SourceBaseName: string; Line: Integer): TDebugSession;
begin
  Result := TDebugSession.Create;
  var Opts: TLaunchOptions;
  Opts             := Default(TLaunchOptions);
  Opts.ExePath     := ExePath;
  Opts.MapPath     := MapPath;
  Opts.RsmPath     := RsmPath;
  Opts.SourceRoot  := SourceRoot;
  Opts.StopAtEntry := False;

  Assert.IsTrue(Result.Launch(Opts), 'Launch returned False');

  var LineSpec: TBpLineSpec;
  LineSpec      := Default(TBpLineSpec);
  LineSpec.Line := Line;
  Result.SetBreakpoints(SourceBaseName, [LineSpec]);

  var Deadline := GetTickCount64 + 60000;
  while (Result.State <> dsStopped) and (not Result.HasExited) and
        (GetTickCount64 < Deadline) do
    Result.Pump;
end;

procedure TDebugSessionTests.Launch_StopsAtBreakpoint;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'session did not stop');

    var FnName, SrcFile: string;
    var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnName, SrcFile, StopLine),
      'no current location');
    Assert.AreEqual(EVAL_SOURCE, ExtractFileName(SrcFile), 'wrong source file');
    Assert.AreEqual(Line, StopLine, 'stopped at wrong line');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// Regression for the zombie-debuggee handle leak: after Terminate the debuggee
// must be fully reaped -- not left as a zombie held by our still-open debug port
// (which kept the .exe locked and blocked rebuilds). Asserts the process id is no
// longer a live process shortly after Terminate.
procedure TDebugSessionTests.Terminate_ReapsDebuggeeProcess;

  function ProcessIsAlive(Pid: Cardinal): Boolean;
  begin
    Result := False;
    if Pid = 0 then Exit;
    var H := OpenProcess(PROCESS_QUERY_INFORMATION, False, Pid);
    if H = 0 then Exit;   // gone (or access denied -- treated as not-our-live-zombie)
    try
      var Code: DWORD := 0;
      if GetExitCodeProcess(H, Code) then
        Result := (Code = STILL_ACTIVE);
    finally
      CloseHandle(H);
    end;
  end;

begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Pid := Session.DebuggeeProcessId;
    Assert.IsTrue(Pid <> 0, 'no debuggee pid while stopped');
    Assert.IsTrue(ProcessIsAlive(Pid), 'debuggee should be alive before Terminate');

    Session.Terminate;

    // Terminate drains the exit event synchronously, so the process should be
    // gone immediately; allow a short grace window against scheduler latency.
    var Deadline := GetTickCount64 + 3000;
    while ProcessIsAlive(Pid) and (GetTickCount64 < Deadline) do
      Sleep(20);
    Assert.IsFalse(ProcessIsAlive(Pid),
      Format('debuggee pid %d survived Terminate as a zombie', [Pid]));
  finally
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Locals_AtEvalBody_ExposeCaption;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Locals := Session.GetLocals;
    Assert.IsTrue(Length(Locals) > 0, 'no locals returned');

    var FoundCaption := False;
    for var V in Locals do
      if SameText(V.Name, 'Caption') then begin
        FoundCaption := True;
        Assert.IsTrue(V.Value.Contains('Hello'),
          'Caption value mismatch: ' + V.Value);
      end;
    Assert.IsTrue(FoundCaption, 'local Caption not found');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Evaluate_FieldAccess_ReturnsValue;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var R := Session.Evaluate('W.FValue');
    Assert.IsTrue(R.Success, 'evaluate failed: ' + R.ErrorText);
    Assert.IsTrue(R.Value.Contains('42'), 'W.FValue mismatch: ' + R.Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Snapshot_HasLocationAndLocals;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Snap := Session.Snapshot;
    Assert.AreEqual(Ord(dsStopped), Ord(Snap.State), 'snapshot state not stopped');
    Assert.AreEqual(EVAL_SOURCE, ExtractFileName(Snap.CurrentFile),
      'snapshot current file mismatch');
    Assert.AreEqual(Line, Snap.CurrentLine, 'snapshot current line mismatch');
    Assert.IsTrue(Length(Snap.TopFrames) > 0, 'snapshot has no frames');
    Assert.IsTrue(Length(Snap.Locals) > 0, 'snapshot has no locals');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// Launches, plants ONE conditional/hit/logpoint breakpoint at a marker, and pumps
// until the session stops or the target exits (event-driven, bounded). Caller owns
// Session.Free.
function OpenSessionWithBp(const ExePath, MapPath, RsmPath, SourceRoot,
  SourceBaseName: string; Line: Integer;
  const Cond, HitCond, LogMsg: string): TDebugSession;
begin
  Result := TDebugSession.Create;
  var Opts: TLaunchOptions;
  Opts             := Default(TLaunchOptions);
  Opts.ExePath     := ExePath;
  Opts.MapPath     := MapPath;
  Opts.RsmPath     := RsmPath;
  Opts.SourceRoot  := SourceRoot;
  Opts.StopAtEntry := False;
  Result.Launch(Opts);

  var Spec: TBpLineSpec;
  Spec              := Default(TBpLineSpec);
  Spec.Line         := Line;
  Spec.Condition    := Cond;
  Spec.HitCondition := HitCond;
  Spec.LogMessage   := LogMsg;
  Result.SetBreakpoints(SourceBaseName, [Spec]);

  var Deadline := GetTickCount64 + 60000;
  while (Result.State <> dsStopped) and (not Result.HasExited) and
        (GetTickCount64 < Deadline) do
    Result.Pump;
end;

// True when the runner holds SeDebugPrivilege. DebugActiveProcess needs it on a
// standard account, so the attach test skips (rather than fails) when absent.
function HaveDebugPrivilege: Boolean;
var
  Tok: THandle;
  Luid: TLargeInteger;
  Got: DWORD;
  Buf: array[0..1023] of Byte;
  Privs: ^TTokenPrivileges;
begin
  Result := False;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Tok) then
    Exit;
  try
    if not LookupPrivilegeValue(nil, 'SeDebugPrivilege', Luid) then
      Exit;
    Got := 0;
    GetTokenInformation(Tok, TokenPrivileges, @Buf[0], SizeOf(Buf), Got);
    if Got = 0 then
      Exit;
    Privs := @Buf[0];
    for var I := 0 to Privs.PrivilegeCount - 1 do
      if Int64(Privs.Privileges[I].Luid) = Int64(Luid) then
        Exit(True);
  finally
    CloseHandle(Tok);
  end;
end;

function FindVar(const Vars: TArray<TSessionVariable>; const Name: string;
  out V: TSessionVariable): Boolean;
begin
  for var Each in Vars do
    if SameText(Each.Name, Name) then begin
      V := Each;
      Exit(True);
    end;
  Result := False;
end;

// Returns the children of a named category ('properties'/'event handlers'/
// 'fields') among a class node's expansion rows, or nil when absent.
function GroupChildren(Session: TDebugSession;
  const Rows: TArray<TSessionVariable>; const GroupName: string): TArray<TSessionVariable>;
var G: TSessionVariable;
begin
  Result := nil;
  if FindVar(Rows, GroupName, G) and (G.Kind = vkGroup) and G.Expandable then
    Result := Session.GetChildren(G.Handle);
end;

// Finds a backing FIELD row of a class node regardless of whether the class
// expands flat (no properties) or into groups (a 'fields' category).
function FindMemberField(Session: TDebugSession; const Parent: TSessionVariable;
  const FieldName: string; out V: TSessionVariable): Boolean;
begin
  var Rows := Session.GetChildren(Parent.Handle);
  var Fields := GroupChildren(Session, Rows, 'fields');
  if Length(Fields) > 0 then
    Rows := Fields;
  Result := FindVar(Rows, FieldName, V);
end;

procedure TDebugSessionTests.ExpandVariable_Widget_ExposesFields;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Locals := Session.GetLocals;
    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Locals, 'W', W), 'local W not found');
    Assert.IsTrue(W.Expandable, 'W should be expandable');
    Assert.IsTrue(W.Handle <> 0, 'W has no expansion handle');

    var FName, FValue: TSessionVariable;
    Assert.IsTrue(FindMemberField(Session, W, 'FName', FName), 'field FName not found');
    Assert.IsTrue(FName.Value.Contains('hello'), 'FName mismatch: ' + FName.Value);
    Assert.IsTrue(FindMemberField(Session, W, 'FValue', FValue), 'field FValue not found');
    Assert.IsTrue(FValue.Value.Contains('42'), 'FValue mismatch: ' + FValue.Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_NestedRecord;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'W', W), 'local W not found');

    var FPt: TSessionVariable;
    Assert.IsTrue(FindMemberField(Session, W, 'FPt', FPt), 'record field FPt not found');
    Assert.IsTrue(FPt.Expandable and (FPt.Handle <> 0), 'FPt should be an expandable record');

    var PtFields := Session.GetChildren(FPt.Handle);
    Assert.IsTrue(Length(PtFields) >= 3, 'FPt should expose >= 3 coordinate fields');

    var AnyCoord := False;
    for var C in PtFields do
      if C.Value.Contains('1.5') or C.Value.Contains('2.5') or C.Value.Contains('3.5') then
        AnyCoord := True;
    Assert.IsTrue(AnyCoord, 'no expected coordinate value in FPt fields');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Breakpoint_Condition_True_Stops;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionWithBp(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line, 'W.FValue = 42', '', '');
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'condition true should have stopped');
    var Fn, Src: string; var StopLine: Integer;
    Session.GetCurrentLocation(Fn, Src, StopLine);
    Assert.AreEqual(Line, StopLine, 'stopped at wrong line');
  finally
    if Session.State = dsStopped then Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Breakpoint_Condition_False_RunsToExit;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionWithBp(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line, 'W.FValue = 99', '', '');
  try
    Assert.IsTrue(Session.HasExited, 'condition false should NOT have stopped (target should exit)');
    Assert.AreNotEqual(Ord(dsStopped), Ord(Session.State), 'must not be stopped');
  finally
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Breakpoint_Logpoint_EmitsAndContinues;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionWithBp(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line, '', '', 'widget-value={W.FValue}');
  try
    Assert.IsTrue(Session.HasExited, 'logpoint must not stop; target should run to exit');
    var Logs := Session.DrainDebuggerOutput;
    var Joined := '';
    for var L in Logs do
      Joined := Joined + L + '|';
    Assert.IsTrue(Joined.Contains('widget-value=42'), 'logpoint message not emitted: ' + Joined);
  finally
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Breakpoint_HitCount_SkipsEarlyHits;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'CTOR_BODY');
  Assert.IsTrue(Line > 0, 'CTOR_BODY marker not found');
  // CTOR_BODY (TWidget.Create) is hit more than once per run. hitCondition ">=2"
  // must skip the first hit and stop on the second.
  var Session := OpenSessionWithBp(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line, '', '>=2', '');
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'hit-count >=2 should have stopped on a later hit');
    var Fn, Src: string; var StopLine: Integer;
    Session.GetCurrentLocation(Fn, Src, StopLine);
    Assert.AreEqual(Line, StopLine, 'stopped at wrong line');
  finally
    if Session.State = dsStopped then Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_DynArray_Elements;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Scores: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'Scores', Scores), 'local Scores not found');
    Assert.IsTrue(Scores.Expandable and (Scores.Handle <> 0),
      'Scores (TArray<Integer>) should be expandable');

    var Elems := Session.GetChildren(Scores.Handle);
    Assert.AreEqual<Integer>(3, Length(Elems), 'expected 3 array elements');
    Assert.AreEqual('[0]', Elems[0].Name, 'element name');
    Assert.IsTrue(Elems[0].Value.Contains('10'), 'Scores[0] mismatch: ' + Elems[0].Value);
    Assert.IsTrue(Elems[1].Value.Contains('20'), 'Scores[1] mismatch: ' + Elems[1].Value);
    Assert.IsTrue(Elems[2].Value.Contains('30'), 'Scores[2] mismatch: ' + Elems[2].Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_Widget_GroupsProperties;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'W', W), 'local W not found');

    // A property-bearing class expands into category rows, not a flat field list.
    var Rows := Session.GetChildren(W.Handle);
    var G: TSessionVariable;
    Assert.IsTrue(FindVar(Rows, 'properties', G), 'no "properties" group');
    Assert.AreEqual(Ord(vkGroup), Ord(G.Kind), 'properties row is not a group');
    Assert.IsTrue(G.Expandable and (G.Handle <> 0), 'properties group not expandable');
    Assert.IsTrue(FindVar(Rows, 'event handlers', G), 'no "event handlers" group');
    Assert.IsTrue(FindVar(Rows, 'fields', G), 'no "fields" group');

    // The event group carries the method-pointer property; fields carry backing.
    var Events := GroupChildren(Session, Rows, 'event handlers');
    var Dummy: TSessionVariable;
    Assert.IsTrue(FindVar(Events, 'OnNotify', Dummy), 'OnNotify not in event handlers');
    var Fields := GroupChildren(Session, Rows, 'fields');
    Assert.IsTrue(FindVar(Fields, 'FValue', Dummy), 'FValue not in fields group');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_PropertyGetter_RunsGetter;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'W', W), 'local W not found');
    var Props := GroupChildren(Session, Session.GetChildren(W.Handle), 'properties');
    Assert.IsTrue(Length(Props) > 0, 'no properties enumerated');

    // Field-backed property reads inline.
    var PValue: TSessionVariable;
    Assert.IsTrue(FindVar(Props, 'Value', PValue), 'property Value not found');
    Assert.IsTrue(PValue.Value.Contains('42'), 'Value property mismatch: ' + PValue.Value);

    // Getter-backed property defers, then runs the getter on expand.
    // TWidget.Score = DoCalcScore = FValue*2 = 84.
    var PScore: TSessionVariable;
    Assert.IsTrue(FindVar(Props, 'Score', PScore), 'property Score not found');
    Assert.IsTrue(PScore.Expandable and (PScore.Handle <> 0),
      'Score getter should defer (be expandable)');
    Assert.AreEqual('(expand to evaluate)', PScore.Value, 'Score placeholder mismatch');

    var GetterRows := Session.GetChildren(PScore.Handle);
    Assert.AreEqual<Integer>(1, Length(GetterRows), 'getter should yield one value leaf');
    Assert.AreEqual('(value)', GetterRows[0].Name, 'getter leaf name');
    Assert.IsTrue(GetterRows[0].Value.Contains('84'),
      'Score getter value mismatch: ' + GetterRows[0].Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_IndexedProperty_IsLeaf;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'W', W), 'local W not found');
    var Props := GroupChildren(Session, Session.GetChildren(W.Handle), 'properties');

    var Slot: TSessionVariable;
    Assert.IsTrue(FindVar(Props, 'Slot', Slot), 'indexed property Slot not found');
    Assert.IsFalse(Slot.Expandable, 'indexed property must be a leaf');
    Assert.AreEqual('(indexed property)', Slot.Value, 'indexed property placeholder mismatch');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_VariantArray1D_Elements;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'VARIANT_BODY');
  Assert.IsTrue(Line > 0, 'VARIANT_BODY marker not found');
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Arr: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'Arr1D', Arr), 'local Arr1D not found');
    Assert.IsTrue(Arr.Expandable and (Arr.Handle <> 0), 'Arr1D should be expandable');

    var Elems := Session.GetChildren(Arr.Handle);
    Assert.AreEqual<Integer>(5, Length(Elems), 'expected 5 variant-array elements');
    Assert.AreEqual('[0]', Elems[0].Name, 'element name');
    var Expected: TArray<string> := ['10', '20', '30', '40', '50'];
    for var I := 0 to 4 do
      Assert.IsTrue(Elems[I].Value.Contains(Expected[I]),
        Format('Arr1D[%d] mismatch: %s', [I, Elems[I].Value]));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ExpandVariable_VariantArray2D_Elements;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'VARIANT_BODY');
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Mat: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'Mat', Mat), 'local Mat not found');
    Assert.IsTrue(Mat.Expandable and (Mat.Handle <> 0), 'Mat should be expandable');

    // varDouble[1..3, 1..4] -> 12 cells named [r,c]; Mat[1,1]=1.5, Mat[2,3]=7.25.
    var Elems := Session.GetChildren(Mat.Handle);
    Assert.AreEqual<Integer>(12, Length(Elems), 'expected 12 matrix elements');
    Assert.AreEqual('[1,1]', Elems[0].Name, 'first cell name');
    var C11, C23: TSessionVariable;
    Assert.IsTrue(FindVar(Elems, '[1,1]', C11), 'cell [1,1] not found');
    Assert.IsTrue(C11.Value.Contains('1.5'), 'Mat[1,1] mismatch: ' + C11.Value);
    Assert.IsTrue(FindVar(Elems, '[2,3]', C23), 'cell [2,3] not found');
    Assert.IsTrue(C23.Value.Contains('7.25'), 'Mat[2,3] mismatch: ' + C23.Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Bpl_CallStack_ResolvesDeeperFrames;
begin
  // At a stop inside a runtime-loaded BPL unit, the call stack crosses module
  // boundaries. Its symbols are loaded ON DEMAND (GetCallStack detects unresolved
  // frames, EnsureModuleForPC's their module, then re-walks). This proves the
  // resolution is NOT limited to the top/stop frame -- deeper frames resolve too,
  // so expanding the stack does not give partial (address-only) results for a
  // module that has debug info.
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(HostExe, HostMap, HostRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop inside the BPL unit');
    var Frames := Session.GetCallStack;
    Assert.IsTrue(Length(Frames) >= 2, 'expected a multi-frame call stack');

    // Top frame = the BPL unit at the stop line (BPL symbols loaded on demand).
    Assert.AreEqual(EVAL_SOURCE, ExtractFileName(Frames[0].SourceFile), 'top frame source (BPL)');
    Assert.AreEqual(Line, Frames[0].SourceLine, 'top frame line');

    // At least one DEEPER frame must also carry a resolved source + line -- the
    // whole visible chain resolves, not just the stop point.
    var ResolvedBeyondTop := 0;
    for var I := 1 to High(Frames) do
      if (Frames[I].SourceFile <> '') and (Frames[I].SourceLine > 0) then
        Inc(ResolvedBeyondTop);
    Assert.IsTrue(ResolvedBeyondTop >= 1,
      Format('no caller frame resolved a source line (of %d frames)', [Length(Frames)]));
  finally
    if Session.State = dsStopped then Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Bpl_Breakpoint_InPackageUnit_Stops;
begin
  // TestHost.exe statically references NO subject unit; it LoadPackage's
  // TestSubject.bpl (which contains TestTargetCore) at runtime. A breakpoint set
  // in a BPL-only unit must plant once the BPL loads and its symbols resolve.
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(HostExe, HostMap, HostRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'did not stop at a breakpoint inside the BPL unit');
    var Fn, Src: string; var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(Fn, Src, StopLine), 'no location in BPL frame');
    Assert.AreEqual(EVAL_SOURCE, ExtractFileName(Src), 'wrong source file (BPL)');
    Assert.AreEqual(Line, StopLine, 'stopped at wrong line');

    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'W', W), 'W local not visible in the BPL frame');
    Assert.IsTrue(W.Expandable, 'W should be expandable (BPL TD32/DCP loaded)');
    var FV: TSessionVariable;
    Assert.IsTrue(FindMemberField(Session, W, 'FValue', FV) and FV.Value.Contains('42'),
      'FValue=42 not readable in the BPL object');
  finally
    if Session.State = dsStopped then Session.Terminate;
    Session.Free;
  end;
end;

// Regression: dbghelp must learn about modules mapped AFTER its initialisation.
// SymInitialize(fInvadeProcess=True) enumerates only the modules present at that
// instant, and it used to run lazily on the FIRST stack walk. A client that walks
// the stack at the entry stop (VS Code does: the entry stop is a stop like any
// other) therefore froze dbghelp's module list before any runtime-loaded package
// existed. StackWalk64 then had no .pdata unwind info inside the BPL and fell back
// to the AMD64 leaf convention (return address := [RSP]); just past a Delphi
// prologue RSP == RBP == the bottom of the frame, so it read an uninitialised local
// and the walk stopped after ONE frame. The same nil function table broke
// CallerReturnAddress, so step-out silently degenerated into a single-instruction
// step inside the SAME function and still reported success.
procedure TDebugSessionTests.Bpl_StackWalk_AfterEarlyWalk_ResolvesFramesAndStepsOut;

  procedure PumpUntilStopped(Session: TDebugSession; TimeoutMs: Cardinal);
  begin
    var Deadline := GetTickCount64 + TimeoutMs;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
  end;

  function CurrentRsp(Session: TDebugSession): UInt64;
  begin
    Result := 0;
    for var R in Session.GetRegisters do
      if SameText(R.Name, 'RSP') then
        Exit(R.Value);
  end;

begin
  var Line := MarkerLineInFile(PackageSrc, 'PKG_INNER_BODY');
  Assert.IsTrue(Line > 0, 'marker PKG_INNER_BODY not found in TestPkgUnit.pas');

  var Session := TDebugSession.Create;
  try
    var Opts         := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := True;
    Opts.Args        := '--load-package';
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');
    PumpUntilStopped(Session, 30000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at entry');

    // THE TRIGGER: one stack walk while only the exe (and the system DLLs) is
    // mapped. Everything below must behave exactly as if it had never run.
    Session.GetCallStack;

    var LineSpec  := Default(TBpLineSpec);
    LineSpec.Line := Line;
    Session.SetBreakpoints('TestPkgUnit.pas', [LineSpec]);
    Session.ContinueExecution;
    PumpUntilStopped(Session, 60000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'did not stop at PKG_INNER_BODY inside the runtime-loaded package');

    // PkgInner is call-free, so at its first statement RSP still equals RBP: the
    // leaf-convention fallback reads a local here and truncates the walk to 1.
    var Frames := Session.GetCallStack;
    Assert.IsTrue(Length(Frames) >= 3,
      Format('expected >= 3 frames inside the BPL, got %d (dbghelp has no unwind ' +
        'info for a module mapped after SymInitialize)', [Length(Frames)]));
    Assert.IsTrue(Frames[1].FunctionName.Contains('PkgAdd'),
      'frame 1 must be the BPL caller PkgAdd, got: ' + Frames[1].FunctionName);

    var FuncEntryBefore := Frames[0].FuncEntryVA;
    var RspBefore       := CurrentRsp(Session);
    Assert.IsTrue(RspBefore <> 0, 'no RSP before step-out');

    Session.StepOut;
    PumpUntilStopped(Session, 30000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'step-out produced no stop');

    var After := Session.GetCallStack;
    Assert.IsTrue(Length(After) > 0, 'no frames after step-out');
    Assert.IsFalse(After[0].FunctionName.Contains('PkgInner'),
      'step-out must leave PkgInner, but stopped in: ' + After[0].FunctionName);
    Assert.AreNotEqual(FuncEntryBefore, After[0].FuncEntryVA,
      'step-out stayed inside the same function (it single-stepped a few bytes)');
    Assert.IsTrue(CurrentRsp(Session) > RspBefore,
      Format('step-out must unwind to a HIGHER RSP; before=$%x after=$%x',
        [RspBefore, CurrentRsp(Session)]));
  finally
    if Session.State = dsStopped then
      Session.Terminate;
    Session.Free;
  end;
end;

// F22 regression: the state a CLIENT is told must track reality.
//
// A breakpoint set in a unit that lives in a not-yet-loaded package is correctly
// reported unverified at set time. When the package loads, the session re-posts the
// spec, the line resolves, the INT3 is planted and the breakpoint fires -- but
// ListBreakpoints (the array the MCP `list_breakpoints` tool serialises, and the
// only thing a non-DAP client can see) kept returning the stale set-time value.
// Observed live twice: two breakpoints reported unverified and then both hit.
//
// This asserts on the client-visible answer, not on any internal flip dictionary.
procedure TDebugSessionTests.Bpl_ListBreakpoints_ReportsVerified_AfterPackageLoads;

  procedure PumpUntilStopped(Session: TDebugSession; TimeoutMs: Cardinal);
  begin
    var Deadline := GetTickCount64 + TimeoutMs;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
  end;

  function ReportedVerified(Session: TDebugSession; Line: Integer): Boolean;
  begin
    Result := False;
    for var Bp in Session.ListBreakpoints do
      if (Bp.Line = Line) and SameText(ExtractFileName(Bp.SourceFile), 'TestPkgUnit.pas') then
        Exit(Bp.Verified);
  end;

begin
  var Line := MarkerLineInFile(PackageSrc, 'PKG_BP');
  Assert.IsTrue(Line > 0, 'marker PKG_BP not found in TestPkgUnit.pas');

  var Session := TDebugSession.Create;
  try
    var Opts         := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := True;   // stop BEFORE TestPackage.bpl is loaded
    Opts.Args        := '--load-package';
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');
    PumpUntilStopped(Session, 30000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at entry');

    var LineSpec  := Default(TBpLineSpec);
    LineSpec.Line := Line;
    var Initial := Session.SetBreakpoints('TestPkgUnit.pas', [LineSpec]);
    Assert.AreEqual<Integer>(1, Length(Initial), 'expected one breakpoint back');
    Assert.IsFalse(Initial[0].Verified,
      'precondition: the package is not loaded yet, so the breakpoint cannot be verified');
    Assert.IsFalse(ReportedVerified(Session, Line),
      'precondition: ListBreakpoints must agree it is unverified before the package loads');

    // Run on: LoadPackage maps TestPackage.bpl, its symbols load, the spec is
    // re-posted and the breakpoint plants -- and then HITS.
    Session.ContinueExecution;
    PumpUntilStopped(Session, 60000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'did not stop at PKG_BP inside the runtime-loaded package');

    var Fn, Src: string;
    var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(Fn, Src, StopLine), 'no location at the BPL stop');
    Assert.AreEqual('TestPkgUnit.pas', ExtractFileName(Src), 'stopped in the wrong file');
    Assert.AreEqual(Line, StopLine, 'stopped at the wrong line');

    // The breakpoint just fired, so any client asking for its state must be told
    // it is verified.
    Assert.IsTrue(ReportedVerified(Session, Line),
      'ListBreakpoints still reports the breakpoint unverified after it actually fired');
  finally
    if Session.State = dsStopped then
      Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.GetVariable_LocalAndExpression;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    // A local by name -> carries an expansion handle.
    var W := Session.GetVariable('W');
    Assert.AreEqual('W', W.Name, 'name');
    Assert.IsTrue(W.Expandable and (W.Handle <> 0), 'W local should be expandable with a handle');

    // An expression (not a bare local) -> evaluated.
    var FV := Session.GetVariable('W.FValue');
    Assert.IsTrue(FV.Value.Contains('42'), 'W.FValue mismatch: ' + FV.Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// F1 regression: pausing a running target uses DebugBreakProcess, which injects a
// transient thread that runs the INT3 -- so the stop lands on a thread with no user
// stack. The engine must retarget the report to a real user thread (the main
// thread), so the pause shows a usable location/stack instead of empty frames.
// F17: while debugging, the session memory-maps the target .exe (TD32 symbols), so it
// is locked. After Terminate the session must RELEASE those mappings, otherwise the
// .exe stays locked (blocking a rebuild) until the next launch.
procedure TDebugSessionTests.Terminate_ReleasesSymbolFileLock;

  function CanOpenExclusive(const Path: string): Boolean;
  begin
    Result := False;
    try
      var FS := TFileStream.Create(Path, fmOpenReadWrite or fmShareExclusive);
      FS.Free;
      Result := True;
    except
      // still locked
    end;
  end;

begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'session did not stop');
    // While stopped, the target is both running and symbol-mapped -> locked.
    Assert.IsFalse(CanOpenExclusive(TargetExe),
      'exe should be locked while a debug session holds its symbols');

    Session.Terminate;

    // The debuggee is reaped AND the symbol mappings released -> the exe unlocks.
    // Allow a short window for the OS to drop the terminated process' image lock.
    var Deadline := GetTickCount64 + 3000;
    while (not CanOpenExclusive(TargetExe)) and (GetTickCount64 < Deadline) do
      Sleep(30);
    Assert.IsTrue(CanOpenExclusive(TargetExe),
      'exe still locked after Terminate -- the session did not release its symbol files (F17)');
  finally
    Session.Free;
  end;
end;

// F11 repro attempt: a breakpoint inside a TWO-level nested proc (Inner in Middle in
// Outer) -- the shape of SampleApp's ParseLiteralDate. The innermost frame must expose
// its OWN local and, via the scope chain, the enclosing procs' locals.
procedure TDebugSessionTests.DeepNested_LocalsResolveAtDepth2;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'DEEP_NESTED_BODY');
  Assert.IsTrue(Line > 0, 'DEEP_NESTED_BODY marker not found');
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at DEEP_NESTED_BODY');

    var Locals := Session.GetLocals;
    var HasInner := False;
    for var L in Locals do
      if SameText(L.Name, 'InnerVal') then
        HasInner := True;
    Assert.IsTrue(HasInner,
      'InnerVal (own local of a 2-level nested proc) missing from get_locals (F11)');

    var ROuter := Session.Evaluate('OuterVal');
    Assert.IsTrue(ROuter.Success and ROuter.Value.Contains('314'),
      'OuterVal (enclosing scope) not resolved: ' + ROuter.Value + ' / ' + ROuter.ErrorText);
    var RMid := Session.Evaluate('MiddleStr');
    Assert.IsTrue(RMid.Success and RMid.Value.Contains('middle'),
      'MiddleStr (enclosing scope) not resolved: ' + RMid.Value + ' / ' + RMid.ErrorText);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// F11 exception-stop variant: SampleApp's failing case stopped on a FIRST-CHANCE
// exception inside a 2-level nested proc, not a breakpoint. This drives the target's
// --run-deep-nested-raise scenario and asserts the nested frame's locals still
// resolve at the raise site.
procedure TDebugSessionTests.DeepNested_LocalsResolveAtExceptionStop;
begin
  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.Args        := '--run-deep-nested-raise';
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := True;
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    // Pump to the entry stop, then continue; the default filters break on the
    // first-chance raise inside InnerLevel.
    var D0 := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and (GetTickCount64 < D0) do
      Session.Pump;
    Session.ContinueExecution;
    var Deadline := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop on the first-chance raise');

    var Fn, Src: string; var Ln: Integer;
    Session.GetCurrentLocation(Fn, Src, Ln);
    Assert.AreEqual(EVAL_SOURCE, ExtractFileName(Src),
      'exception did not stop in the nested proc source: ' + Src);

    var Locals := Session.GetLocals;
    var HasInner := False;
    for var L in Locals do
      if SameText(L.Name, 'RnInnerVal') then
        HasInner := True;
    Assert.IsTrue(HasInner,
      'RnInnerVal missing at an EXCEPTION stop in a 2-level nested proc (F11)');
    var ROuter := Session.Evaluate('RnOuter');
    Assert.IsTrue(ROuter.Success and ROuter.Value.Contains('271'),
      'RnOuter (enclosing scope) not resolved at exception stop: ' + ROuter.Value + ' / ' + ROuter.ErrorText);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// F13: the MCP frontend can configure exception break filters (which it did not
// before). This covers the wire-name -> engine-filter mapping the launch arg and the
// set_exception_filters tool both use.
procedure TDebugSessionTests.ExceptionFilters_ParseNames;
begin
  Assert.IsTrue(TDebugSession.ParseExceptionFilters(['delphi', 'unhandled']) =
    [efDelphi, efUnhandled], 'delphi+unhandled');
  Assert.IsTrue(TDebugSession.ParseExceptionFilters(['av', 'all']) =
    [efAccessViolation, efAllFirstChance], 'av+all');
  Assert.IsTrue(TDebugSession.ParseExceptionFilters([]) = [],
    'empty -> never break on first-chance');
  Assert.IsTrue(TDebugSession.ParseExceptionFilters(['bogus']) = [],
    'unknown names are ignored');
end;

procedure TDebugSessionTests.Pause_RetargetsToUserThread;
begin
  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.Args        := '--attach-pause';   // main thread Sleep(5000)s at startup
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := False;
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    // Let the target start and settle into the Sleep before pausing.
    var Warm := GetTickCount64 + 1000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Warm) do
      Session.Pump;
    Assert.AreEqual(Ord(dsRunning), Ord(Session.State), 'target not running before pause');

    Session.Pause;
    var Deadline := GetTickCount64 + 8000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'pause did not stop the target');

    // The pause must report a real user thread (the main thread, in Sleep) -- its
    // stack resolves at least one user-code frame. The injected thread's stack is
    // all ntdll, so before the fix no frame carried a source file.
    var Frames := Session.GetCallStack;
    var HasUserFrame := False;
    for var F in Frames do
      if F.SourceFile <> '' then
        HasUserFrame := True;
    Assert.IsTrue(HasUserFrame,
      'pause reported a thread with no user frames -- the injected-thread bug (F1)');

    // get_threads must list threads and mark exactly one as current.
    var Threads := Session.GetThreads;
    Assert.IsTrue(Length(Threads) > 0, 'GetThreads returned no threads');
    var CurrentCount := 0;
    for var T in Threads do
      if T.IsCurrent then
        Inc(CurrentCount);
    Assert.AreEqual(1, CurrentCount, 'exactly one thread must be marked current');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Attach_ToRunningTarget_Stops;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  if not HaveDebugPrivilege then begin
    Assert.Pass('Skipped: SeDebugPrivilege not held; run elevated to exercise attach.');
    Exit;
  end;

  // Spawn the target with --attach-pause: it Sleep(5000)s at startup, giving us a
  // window to attach before it races through MAIN_GCOUNTER.
  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  var CmdLine := '"' + TargetExe + '" --attach-pause';
  Assert.IsTrue(CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI), 'CreateProcess for attach target failed');
  CloseHandle(PI.hThread);

  var Session := TDebugSession.Create;
  try
    var Opts: TAttachOptions;
    Opts             := Default(TAttachOptions);
    Opts.ProgramPath := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Session.Attach(PI.dwProcessId, True, Opts);   // killOnDetach = True (own the target)

    var Line := MarkerLine('TestTarget.dpr', 'MAIN_GCOUNTER');
    Assert.IsTrue(Line > 0, 'MAIN_GCOUNTER marker not found');
    var Spec: TBpLineSpec;
    Spec      := Default(TBpLineSpec);
    Spec.Line := Line;
    Session.SetBreakpoints('TestTarget.dpr', [Spec]);

    var Deadline := GetTickCount64 + 25000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;

    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'attach: did not stop at the breakpoint');
    var Fn, Src: string; var StopLine: Integer;
    Session.GetCurrentLocation(Fn, Src, StopLine);
    Assert.AreEqual(Line, StopLine, 'attach: stopped at the wrong line');
  finally
    Session.Terminate;   // killOnDetach=True -> terminates the target
    Session.Free;
  end;
end;

procedure TDebugSessionTests.AttachConfig_ParsesSelectorAndPaths;
begin
  // A VS Code launch.json "attach" configuration (JSONC): the config reader must
  // pull the process selector AND the source paths (this is how attach obtains its
  // source-path configuration when driven from a project's launch.json).
  var Content :=
    '{' + sLineBreak +
    '  // attach config' + sLineBreak +
    '  "configurations": [' + sLineBreak +
    '    {' + sLineBreak +
    '      "name": "Attach MyApp",' + sLineBreak +
    '      "type": "delphi-win64",' + sLineBreak +
    '      "request": "attach",' + sLineBreak +
    '      "processName": "MyApp.exe",' + sLineBreak +
    '      "sourceRoot": "${workspaceFolder}",' + sLineBreak +
    '      "sourceSearchPaths": [ "${workspaceFolder}\\lib", "${env:PUBLIC}" ],' + sLineBreak +
    '    },' + sLineBreak +
    '  ],' + sLineBreak +
    '}';
  var CfgPath := TPath.Combine(TPath.GetTempPath, 'mcp_test_attach.json');
  TFile.WriteAllText(CfgPath, Content);

  var Opts: TAttachOptions;
  var Pid: Cardinal;
  var PName, Err: string;
  Assert.IsTrue(LaunchConfig.LoadAttachConfig(CfgPath, '', 'C:\Proj\Root', Opts, Pid, PName, Err),
    'LoadAttachConfig failed: ' + Err);
  Assert.AreEqual('MyApp.exe', PName, 'processName not extracted');
  Assert.AreEqual('C:\Proj\Root', Opts.SourceRoot, '${workspaceFolder} not resolved for sourceRoot');
  Assert.IsTrue(Length(Opts.ExtraSourcePaths) >= 1, 'sourceSearchPaths not parsed');
  Assert.AreEqual('C:\Proj\Root\lib', Opts.ExtraSourcePaths[0], '${workspaceFolder} not resolved in a search path');
end;

procedure TDebugSessionTests.Threads_StoppedThreadIsCurrent;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Threads := Session.GetThreads;
    Assert.IsTrue(Length(Threads) >= 1, 'expected at least one thread');

    var StoppedTid := Session.GetStoppedThreadId;
    Assert.IsTrue(StoppedTid <> 0, 'GetStoppedThreadId returned 0');

    var FoundCurrent := False;
    for var T in Threads do
      if T.IsCurrent then begin
        FoundCurrent := True;
        Assert.AreEqual(StoppedTid, T.OsThreadId,
          'the current thread must be the stopped thread');
        Assert.IsTrue(T.IsStopped, 'the current thread should be marked stopped');
      end;
    Assert.IsTrue(FoundCurrent, 'no thread marked IsCurrent at a stop');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.SelectFrame_OnOtherThread_ReadsThatThreadsLocals;

  procedure PumpUntilStopped(Session: TDebugSession; TimeoutMs: Cardinal);
  begin
    var Deadline := GetTickCount64 + TimeoutMs;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
  end;

begin
  var Line := MarkerLine(EVAL_SOURCE, 'STEPISO_MAIN');
  Assert.IsTrue(Line > 0, 'marker STEPISO_MAIN not found');

  var Session := TDebugSession.Create;
  try
    var Opts         := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := False;
    Opts.Args        := '--run-per-thread-step';
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var LineSpec  := Default(TBpLineSpec);
    LineSpec.Line := Line;
    Session.SetBreakpoints(EVAL_SOURCE, [LineSpec]);
    PumpUntilStopped(Session, 60000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at STEPISO_MAIN');

    // The stop is on the MAIN thread; find the spinner thread B.
    var TidB: Cardinal := 0;
    for var T in Session.GetThreads do begin
      if T.Name.Contains('StepIsoSpinB') then begin TidB := T.OsThreadId; Break; end;
      for var F in Session.GetCallStack(T.OsThreadId) do
        if F.FunctionName.Contains('StepIsoSpinB') then begin TidB := T.OsThreadId; Break; end;
      if TidB <> 0 then Break;
    end;
    Assert.IsTrue(TidB <> 0, 'spinner StepIsoSpinB not found');
    Assert.AreNotEqual(Integer(Session.GetStoppedThreadId), Integer(TidB),
      'the spinner must not be the stopped thread for this test');

    // Walk B's stack (this deliberately does NOT clobber the stopped thread's
    // cache) and then select B's own top frame, exactly as the client does.
    var FramesB := Session.GetCallStack(TidB);
    Assert.IsTrue(Length(FramesB) > 0, 'no frames for the spinner thread');
    Session.SelectFrame(0, TidB);

    // The locals must be StepIsoSpinB's -- TagB=12345 lives only on THAT stack.
    var FoundTag := False;
    for var V in Session.GetLocals do
      if SameText(V.Name, 'TagB') then begin
        FoundTag := True;
        Assert.IsTrue(V.Value.Contains('12345'),
          'TagB should read 12345 on the spinner''s frame, got: ' + V.Value);
      end;
    Assert.IsTrue(FoundTag,
      'selecting a frame of another thread must read THAT thread''s locals ' +
      '(TagB); without the thread-qualified frame cache the stopped thread''s ' +
      'locals were returned under that frame');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// Per-thread stepping: two worker threads spin on their own counters; the main
// thread stops at STEPISO_MAIN with both live. Stepping the NON-stopped spinner
// must advance ONLY it -- the other spinner's counter must not move at all (proof
// every non-stepped thread was frozen) -- and run control must then target it.
procedure TDebugSessionTests.PerThreadStep_StepsOnlySelectedThread;

  procedure PumpUntilStopped(Session: TDebugSession; TimeoutMs: Cardinal);
  begin
    var Deadline := GetTickCount64 + TimeoutMs;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
  end;

  function EvalInt(Session: TDebugSession; const Expr: string): Int64;
  begin
    var R := Session.Evaluate(Expr);
    Assert.IsTrue(R.Success, Format('evaluate %s failed: %s', [Expr, R.ErrorText]));
    var Digits := '';
    for var Ch in R.Value do
      if CharInSet(Ch, ['0'..'9']) then
        Digits := Digits + Ch
      else if Digits <> '' then
        Break;
    Assert.IsTrue(Digits <> '', Format('no integer in %s value: %s', [Expr, R.Value]));
    Result := StrToInt64(Digits);
  end;

  // OS tid of the thread whose name or top frame identifies it as SpinName.
  function FindSpinnerTid(Session: TDebugSession; const SpinName: string): Cardinal;
  begin
    Result := 0;
    for var T in Session.GetThreads do begin
      if T.Name.Contains(SpinName) then
        Exit(T.OsThreadId);
      for var F in Session.GetCallStack(T.OsThreadId) do
        if F.FunctionName.Contains(SpinName) then
          Exit(T.OsThreadId);
    end;
  end;

begin
  var Line := MarkerLine(EVAL_SOURCE, 'STEPISO_MAIN');
  Assert.IsTrue(Line > 0, 'marker STEPISO_MAIN not found');

  var Session := TDebugSession.Create;
  try
    var Opts         := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := False;
    Opts.Args        := '--run-per-thread-step';
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var LineSpec  := Default(TBpLineSpec);
    LineSpec.Line := Line;
    Session.SetBreakpoints(EVAL_SOURCE, [LineSpec]);
    PumpUntilStopped(Session, 60000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at STEPISO_MAIN');

    // Identify the two spinner threads, frozen at the stop.
    var TidB := FindSpinnerTid(Session, 'StepIsoSpinB');
    var TidC := FindSpinnerTid(Session, 'StepIsoSpinC');
    Assert.IsTrue(TidB <> 0, 'spinner StepIsoSpinB not found');
    Assert.IsTrue(TidC <> 0, 'spinner StepIsoSpinC not found');
    Assert.AreNotEqual(Integer(TidB), Integer(TidC), 'spinners collapsed to one tid');

    // The stopped thread is the main thread -- distinct from the one we step.
    Assert.AreNotEqual(Integer(Session.GetStoppedThreadId), Integer(TidB),
      'stopped thread must differ from the stepped thread for this test');

    var B0 := EvalInt(Session, 'GStepIsoB');
    var C0 := EvalInt(Session, 'GStepIsoC');

    // Step the NON-stopped thread B repeatedly. With per-thread freezing only B
    // runs during each step, so C's counter must not advance at all.
    for var I := 1 to 6 do begin
      Session.StepOver(TidB);
      PumpUntilStopped(Session, 30000);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        Format('step %d did not land', [I]));
    end;

    var B1 := EvalInt(Session, 'GStepIsoB');
    var C1 := EvalInt(Session, 'GStepIsoC');

    Assert.AreEqual(C0, C1,
      Format('thread C advanced during B''s step (%d -> %d) -- freeze failed', [C0, C1]));
    Assert.IsTrue(B1 > B0,
      Format('stepped thread B did not advance (%d -> %d)', [B0, B1]));

    // Run control now targets the stepped thread.
    Assert.AreEqual(Integer(TidB), Integer(Session.GetStoppedThreadId),
      'stopped thread should be the stepped thread after a per-thread step');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// F19 regression. Stepping INTO a method stopped at the function's entry address,
// which already maps to the method's first source line -- so the naive "we are on
// a different source line" test was satisfied before a single prologue instruction
// had run. At that point [rbp+N] still holds the CALLER's frame, so Self and the
// by-register parameters are read out of stale bytes. A breakpoint on the same
// statement is unaffected (it binds to the line-table address, past the prologue),
// which is exactly what made this look like a value-decoding bug rather than a
// stop-location bug.
procedure TDebugSessionTests.StepInto_Method_ReportsSpilledSelfAndParams;

  procedure PumpUntilStopped(Session: TDebugSession; TimeoutMs: Cardinal);
  begin
    var Deadline := GetTickCount64 + TimeoutMs;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
  end;

  procedure AssertLocal(const Locals: TArray<TSessionVariable>;
    const Name, Expected: string);
  begin
    var V: TSessionVariable;
    Assert.IsTrue(FindVar(Locals, Name, V), 'parameter not visible after step-into: ' + Name);
    Assert.IsTrue(V.Value.Contains(Expected),
      Format('%s = %s (expected to contain %s) -- read from the caller''s frame?',
        [Name, V.Value, Expected]));
  end;

  procedure AssertSelfField(Session: TDebugSession; const Slf: TSessionVariable;
    const FieldName, Expected: string);
  begin
    var F: TSessionVariable;
    Assert.IsTrue(FindMemberField(Session, Slf, FieldName, F),
      'Self.' + FieldName + ' not readable after step-into');
    Assert.IsTrue(F.Value.Contains(Expected),
      Format('Self.%s = %s (expected to contain %s)', [FieldName, F.Value, Expected]));
  end;

begin
  var CallSite := MarkerLine(EVAL_SOURCE, 'STEPIN_CALLSITE');
  var BodyLine := MarkerLine(EVAL_SOURCE, 'STEPIN_PROBE_BODY');
  Assert.IsTrue(CallSite > 0, 'marker STEPIN_CALLSITE not found');
  Assert.IsTrue(BodyLine > 0, 'marker STEPIN_PROBE_BODY not found');

  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, CallSite);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at STEPIN_CALLSITE');

    Session.StepInto;
    PumpUntilStopped(Session, 30000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'step-into produced no stop');

    var FnName, SrcFile: string;
    var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnName, SrcFile, StopLine),
      'no location after step-into');
    Assert.IsTrue(FnName.Contains('StepIntoProbe'),
      'step-into did not land in StepIntoProbe, got: ' + FnName);

    var Locals := Session.GetLocals;

    // Self must be a real instance, not a stale stack value that merely carries
    // the right static type.
    var Slf: TSessionVariable;
    Assert.IsTrue(FindVar(Locals, 'Self', Slf), 'Self not visible after step-into');
    Assert.IsTrue(Slf.Expandable,
      'Self is not a live instance after step-into (value: ' + Slf.Value + ')');
    AssertSelfField(Session, Slf, 'FValue', '4242');
    AssertSelfField(Session, Slf, 'FName',  'stepin-owner');

    // Each by-register parameter must hold the value the caller passed.
    AssertLocal(Locals, 'AInt', '1234');
    AssertLocal(Locals, 'AStr', 'probe-str');
    AssertLocal(Locals, 'ADbl', '2.5');

    // Reported last: the entry address maps to the method's `begin` line, so a
    // stop before the prologue completes is off by one line as well as wrong in
    // its data.
    Assert.AreEqual(BodyLine, StopLine, 'step-into reported the wrong line');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Frames_RichFieldsPopulated;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Frames := Session.GetCallStack;
    Assert.IsTrue(Length(Frames) >= 2, 'expected a nested stop (>= 2 frames)');
    Assert.IsTrue(Frames[0].IP <> 0,          'top frame IP should be non-zero');
    Assert.IsTrue(Frames[0].FrameRBP <> 0,    'top frame FrameRBP should be non-zero');
    Assert.IsTrue(Frames[0].FuncEntryVA <> 0, 'top frame FuncEntryVA should be non-zero');
    // The caller frame must also carry selection data (SelectFrame relies on it).
    Assert.IsTrue(Frames[1].FrameRBP <> 0,    'caller frame FrameRBP should be non-zero');
    Assert.IsTrue(Frames[1].FuncEntryVA <> 0, 'caller frame FuncEntryVA should be non-zero');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.SelectFrame_CallerLocalsDiffer;
begin
  // At EVAL_BODY the top frame is RunEvalTests (which has a local `Caption`);
  // its caller RunAllScenarios has no such local. Selecting frame 1 must re-root
  // GetLocals on the caller, so `Caption` disappears -- and ClearFrame restores it.
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Frames := Session.GetCallStack;   // populates the frame cache SelectFrame uses
    Assert.IsTrue(Length(Frames) >= 2, 'need >= 2 frames to select a caller');

    var Dummy: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'Caption', Dummy),
      'top-frame local Caption not visible before frame selection');

    Session.SelectFrame(1);
    Assert.IsFalse(FindVar(Session.GetLocals, 'Caption', Dummy),
      'caller frame must not expose the top-frame local Caption');

    Session.ClearFrame;
    Assert.IsTrue(FindVar(Session.GetLocals, 'Caption', Dummy),
      'ClearFrame did not restore the stopped top-frame locals');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.Registers_HaveRipAndRsp;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Regs := Session.GetRegisters;
    Assert.IsTrue(Length(Regs) > 0, 'no registers returned');

    var FoundRip := False;
    var FoundRsp := False;
    for var R in Regs do begin
      if SameText(R.Name, 'RIP') then begin
        FoundRip := True;
        Assert.IsTrue(R.Value <> 0, 'RIP is zero');
      end;
      if SameText(R.Name, 'RSP') then begin
        FoundRsp := True;
        Assert.IsTrue(R.Value <> 0, 'RSP is zero');
      end;
    end;
    Assert.IsTrue(FoundRip, 'RIP not present in the register set');
    Assert.IsTrue(FoundRsp, 'RSP not present in the register set');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.ResolveSourcePath_ResolvesCoreUnit;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var Resolved := Session.ResolveSourcePath(EVAL_SOURCE);
    Assert.AreEqual(EVAL_SOURCE, ExtractFileName(Resolved),
      'resolved path is not the requested source unit');
    Assert.IsTrue(TFile.Exists(Resolved),
      'ResolveSourcePath did not resolve to an existing file: ' + Resolved);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

procedure TDebugSessionTests.RemoveAllBreakpoints_ClearsPlantedInt3;
begin
  // CTOR_BODY (TWidget.Create) is hit more than once per run. Stop on the first
  // hit, RemoveAllBreakpoints, then continue: if the INT3 is truly cleared the
  // target runs to exit; if RemoveAllBreakpoints failed to post the clear (the
  // old bug) the second hit stops again.
  var Line := MarkerLine(EVAL_SOURCE, 'CTOR_BODY');
  Assert.IsTrue(Line > 0, 'CTOR_BODY marker not found');
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'should stop on the first CTOR hit');

    Session.RemoveAllBreakpoints;
    Session.ContinueExecution;

    var Deadline := GetTickCount64 + 30000;
    while (not Session.HasExited) and (Session.State <> dsStopped) and
          (GetTickCount64 < Deadline) do
      Session.Pump;

    Assert.IsTrue(Session.HasExited,
      'after RemoveAllBreakpoints the target must run to exit (INT3 not cleared)');
  finally
    if Session.State = dsStopped then
      Session.Terminate;
    Session.Free;
  end;
end;

// Frame-scoped rich evaluate (the shared core the DAP evaluate handler now
// delegates to): a class-instance result is expandable with a live handle whose
// children expose the widget's members; a scalar result is a plain leaf value.
procedure TDebugSessionTests.EvaluateForFrame_ClassIsExpandable_ScalarIsLeaf;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    // Class instance: expandable + a non-zero handle; its children carry FValue=42.
    var R := Session.EvaluateForFrame('W', 0);
    Assert.IsTrue(R.Success, 'EvaluateForFrame(W) failed: ' + R.ErrorText);
    Assert.IsTrue(R.Expandable, 'W should be expandable');
    Assert.IsTrue(R.Handle <> 0, 'W has no expansion handle');

    var WNode := Default(TSessionVariable);
    WNode.Handle := R.Handle;
    var FValue: TSessionVariable;
    Assert.IsTrue(FindMemberField(Session, WNode, 'FValue', FValue),
      'FValue not reachable from the EvaluateForFrame handle');
    Assert.IsTrue(FValue.Value.Contains('42'), 'FValue mismatch: ' + FValue.Value);

    // Scalar: plain '42', not expandable.
    var S := Session.EvaluateForFrame('W.FValue', 0);
    Assert.IsTrue(S.Success, 'EvaluateForFrame(W.FValue) failed: ' + S.ErrorText);
    Assert.IsTrue(S.Value.Contains('42'), 'W.FValue mismatch: ' + S.Value);
    Assert.IsFalse(S.Expandable, 'W.FValue should not be expandable');
    Assert.AreEqual(UInt64(0), UInt64(S.Handle), 'scalar must not carry a handle');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// A plain Integer local written through the session: the refreshed NewValue
// reflects the write, and a follow-up Evaluate confirms it stuck in debuggee
// memory. EDGE2_BODY exposes `SetLocal: Integer` for exactly this purpose.
procedure TDebugSessionTests.SetLocalVariable_Integer_ReadsBackChanged;
begin
  var Line := MarkerLine('TestTargetEdge2.pas', 'EDGE2_BODY');
  Assert.IsTrue(Line > 0, 'EDGE2_BODY marker not found');
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    'TestTargetEdge2.pas', Line);
  try
    var NewValue, NewType: string;
    Assert.IsTrue(Session.SetLocalVariable('SetLocal', '99', NewValue, NewType),
      'SetLocalVariable(SetLocal:=99) failed: ' + NewValue);
    Assert.IsTrue(NewValue.Contains('99'),
      'refreshed SetLocal should read back 99, got: ' + NewValue);
    // Independent confirmation the bytes landed in the debuggee.
    var R := Session.Evaluate('SetLocal');
    Assert.IsTrue(R.Success and R.Value.Contains('99'),
      'SetLocal must evaluate to 99 after the write, got: ' + R.Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// An enum local set BY NAME (not ordinal): Mode:TWorkMode starts wmRunning and
// is rewritten to wmPaused. The refreshed render must show the new member.
procedure TDebugSessionTests.SetLocalVariable_EnumByName_ReadsBackChanged;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var NewValue, NewType: string;
    Assert.IsTrue(Session.SetLocalVariable('Mode', 'wmPaused', NewValue, NewType),
      'SetLocalVariable(Mode:=wmPaused) failed: ' + NewValue);
    Assert.IsTrue(NewValue.Contains('wmPaused') or NewValue.Contains('2'),
      'Mode should read back wmPaused/2, got: ' + NewValue);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// A managed string local written through the RTL-helper path: Caption starts
// 'Hello' and is rewritten to 'World'.
procedure TDebugSessionTests.SetLocalVariable_String_ReadsBackChanged;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var NewValue, NewType: string;
    Assert.IsTrue(Session.SetLocalVariable('Caption', 'World', NewValue, NewType),
      'SetLocalVariable(Caption:=World) failed: ' + NewValue);
    Assert.IsTrue(NewValue.Contains('World'),
      'Caption should read back World, got: ' + NewValue);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// Field write via a class expansion handle: W is a TWidget; its FValue:Integer
// and FName:string are writable backing fields. Set both, then re-expand W to
// confirm the change is visible through the normal read path too.
procedure TDebugSessionTests.SetFieldVariable_ViaClassHandle_WritesField;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Session := OpenSessionAtMarker(TargetExe, TargetMap, TargetRsm, TargetDir,
    EVAL_SOURCE, Line);
  try
    var W: TSessionVariable;
    Assert.IsTrue(FindVar(Session.GetLocals, 'W', W), 'local W not found');
    Assert.IsTrue(W.Handle <> 0, 'W has no expansion handle');

    var NewValue, NewType: string;
    Assert.IsTrue(Session.SetFieldVariable(W.Handle, 'FValue', '123', NewValue, NewType),
      'SetFieldVariable(FValue:=123) failed: ' + NewValue);
    Assert.IsTrue(NewValue.Contains('123'),
      'FValue should read back 123, got: ' + NewValue);

    Assert.IsTrue(Session.SetFieldVariable(W.Handle, 'FName', 'renamed', NewValue, NewType),
      'SetFieldVariable(FName:=renamed) failed: ' + NewValue);
    Assert.IsTrue(NewValue.Contains('renamed'),
      'FName should read back renamed, got: ' + NewValue);

    // Re-expand W through the normal read path: the field really changed.
    var FValue: TSessionVariable;
    Assert.IsTrue(FindMemberField(Session, W, 'FValue', FValue), 'FValue field not found');
    Assert.IsTrue(FValue.Value.Contains('123'),
      'FValue re-read after write should be 123, got: ' + FValue.Value);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// The "no debug info in any format" diagnostic: launching a module with no
// embedded TD32 / .map / .rsm / .jdbg must emit a clear one-time message instead
// of silently producing no lines/locals. NoDebugExe.exe is built without any debug
// switches specifically for this. Asserted through DrainDebuggerOutput -- the same
// buffer the MCP frontend surfaces via get_debugger_output -- so this also proves
// the loader console is routed to the session output when no frontend overrides it.
procedure TDebugSessionTests.MainModule_NoDebugInfo_ReportsDiagnostic;

  function DrainedContains(Session: TDebugSession; const Sub: string): Boolean;
  begin
    Result := False;
    for var Line in Session.DrainDebuggerOutput do
      if Line.Contains(Sub) then
        Exit(True);
  end;

begin
  if not TFile.Exists(NoDebugExe) then
    Assert.Fail('NoDebugExe.exe not found at ' + NoDebugExe +
      ' -- run build_target.bat first');
  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := NoDebugExe;
    Opts.StopAtEntry := True;   // hold at entry; the body never runs
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var Deadline := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;

    Assert.IsTrue(DrainedContains(Session, 'No debug info for'),
      'expected the no-debug-info diagnostic in the debugger output buffer');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// F23 regression: a frame whose address the providers cannot name must still
// carry its owning module and an explicit symbol state. NoDebugExe.exe is built
// without any debug switches, so every frame in it is unnameable -- previously
// it produced an empty function name and nothing else, which is also what an
// unmapped address and a still-indexing module produced.
procedure TDebugSessionTests.Frames_NoDebugInfoModule_ReportModuleAndSymbolState;
begin
  if not TFile.Exists(NoDebugExe) then
    Assert.Fail('NoDebugExe.exe not found at ' + NoDebugExe +
      ' -- run build_target.bat first');
  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := NoDebugExe;
    Opts.StopAtEntry := True;   // hold at the entry point, inside NoDebugExe itself
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var Deadline := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'expected a stop at the entry point');

    var Frames := Session.GetCallStack;
    Assert.IsTrue(Length(Frames) > 0, 'expected at least one frame');
    var Top := Frames[0];
    Assert.AreEqual('', Top.FunctionName,
      'a module with no debug info cannot name its frames');
    Assert.AreEqual('nodebugexe.exe', LowerCase(Top.ModuleName),
      'the owning module must be reported even when the frame cannot be named');
    Assert.AreEqual(Ord(saNoSymbols), Ord(Top.Symbols),
      'the frame must be marked as lacking symbols, not left indistinguishable ' +
      'from an unknown address');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// Loader integration for external `.tds` (dcc64 -VT): TdsSample.exe has no embedded
// `.debug`, so LoadMainModule must fall back to LoadFromTdsFile and register a
// provider. Asserted via the debugger-output notice.
procedure TDebugSessionTests.Tds_MainModule_LoadsExternalTds;

  function DrainedContains(Session: TDebugSession; const Sub: string): Boolean;
  begin
    Result := False;
    for var Line in Session.DrainDebuggerOutput do
      if Line.Contains(Sub) then
        Exit(True);
  end;

begin
  if not TFile.Exists(TdsSampleExe) then
    Assert.Fail('TdsSample.exe not found -- run build_target.bat first');
  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := TdsSampleExe;
    Opts.StopAtEntry := True;
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');
    var Deadline := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.IsTrue(DrainedContains(Session, 'TDS (external'),
      'the external .tds must be loaded as the main provider');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// Staleness gate: a `.tds` older than the binary it describes must be IGNORED
// (it belongs to a previous build). Runs on an isolated copy so the real fixture
// is untouched; with the stale `.tds` skipped and no other debug info present, the
// "no debug info" diagnostic fires.
procedure TDebugSessionTests.Tds_StaleTds_Ignored;
begin
  if not TFile.Exists(TdsSampleExe) then
    Assert.Fail('TdsSample.exe not found -- run build_target.bat first');
  var Dir := TPath.Combine(TPath.GetTempPath, 'tdsstale_' + IntToStr(GetCurrentProcessId));
  TDirectory.CreateDirectory(Dir);
  var Exe := TPath.Combine(Dir, 'TdsSample.exe');
  var Tds := TPath.Combine(Dir, 'TdsSample.tds');
  try
    TFile.Copy(TdsSampleExe, Exe, True);
    TFile.Copy(ChangeFileExt(TdsSampleExe, '.tds'), Tds, True);
    // Backdate the .tds well before the exe (past the SymbolFileIsStale grace).
    TFile.SetLastWriteTime(Tds, TFile.GetLastWriteTime(Exe) - 1);  // 1 day earlier

    var Session := TDebugSession.Create;
    try
      var Opts: TLaunchOptions;
      Opts             := Default(TLaunchOptions);
      Opts.ExePath     := Exe;
      Opts.StopAtEntry := True;
      Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');
      var Deadline := GetTickCount64 + 30000;
      while (Session.State <> dsStopped) and (not Session.HasExited) and
            (GetTickCount64 < Deadline) do
        Session.Pump;
      var Drained := Session.DrainDebuggerOutput;
      var SawStale := False;
      for var Line in Drained do
        if Line.Contains('TDS is STALE') then
          SawStale := True;
      Assert.IsTrue(SawStale, 'a .tds older than the exe must be reported STALE and ignored');
    finally
      Session.Terminate;
      Session.Free;
    end;
  finally
    TDirectory.Delete(Dir, True);
  end;
end;

procedure TDebugSessionTests.Prefetch_NoBreakpoints_LoadsRuntimePackageSymbols;
// THE "when" REGRESSION TEST.
//
// With no breakpoints set, TDebugSession.HandleDllLoaded's eager gate never fires,
// so before the background prefetcher NOTHING was parsed for any runtime-loaded
// module: the first stop that touched one paid its whole TD32 parse synchronously,
// and until that finished its frames had no names. Here the target runtime-loads
// two packages and no breakpoint exists anywhere; both packages' symbols must
// still become available.
//
// DrainPrefetch is called explicitly because publication is deliberately confined
// to moments when the debuggee is not executing (see TDebugSession.Pump). In a
// real session that moment is the stop; here, where there is no breakpoint to stop
// at, the test provides it.
begin
  // The prefetcher ships DISABLED (see SetSymbolPrefetchEnabled); this test is
  // what exercises it, so it turns it on for its own scope.
  var WasEnabled := SymbolPrefetchEnabled;
  SetSymbolPrefetchEnabled(True);
  var Session := TDebugSession.Create;
  try
    var Opts         := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := True;
    Opts.Args        := '--load-package2';
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var Deadline := GetTickCount64 + 60000;
    var Pkg1 := saUnknownModule;
    var Pkg2 := saUnknownModule;

    // Entry stop first, then run on. No breakpoints are ever set.
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at entry');
    Assert.AreEqual(Ord(saUnknownModule), Ord(Session.ModuleSymbolState('testpackage.bpl')),
      'the package must not be loaded yet at the entry stop');
    Session.ContinueExecution;

    // The debuggee is short-lived, so keep draining for a grace period after it
    // exits: the point under test is that the prefetcher parses and publishes a
    // module nobody set a breakpoint in, not how fast it does so. The module
    // records survive process exit (no UNLOAD_DLL burst), so publication still
    // finds them.
    var Grace: UInt64 := 0;
    while GetTickCount64 < Deadline do begin
      if not Session.HasExited then
        Session.Pump
      else if Grace = 0 then
        Grace := GetTickCount64 + 10000;
      Session.Loader.DrainPrefetch;
      if Pkg1 = saUnknownModule then begin
        var S1 := Session.ModuleSymbolState('testpackage.bpl');
        if S1 in [saLoaded, saIndexing] then Pkg1 := S1;
      end;
      if Pkg2 = saUnknownModule then begin
        var S2 := Session.ModuleSymbolState('testpackage2.bpl');
        if S2 in [saLoaded, saIndexing] then Pkg2 := S2;
      end;
      if (Pkg1 <> saUnknownModule) and (Pkg2 <> saUnknownModule) then
        Break;
      if (Grace <> 0) and (GetTickCount64 > Grace) then
        Break;
      if Session.HasExited then
        Sleep(5);
    end;

    Assert.IsTrue(Pkg1 in [saLoaded, saIndexing],
      'TestPackage.bpl symbols were never loaded although the package was mapped ' +
      '(prefetch did not run: with no breakpoint set nothing else loads a module)');
    var Dump := '';
    for var M in Session.Loader.Modules do
      if M.PrefetchRequested then
        Dump := Dump + Format(' %s(avail=%d,inflight=%s)',
          [M.Name, Ord(M.SymbolAvailability), BoolToStr(M.PrefetchInFlight, True)]);
    Assert.IsTrue(Pkg2 in [saLoaded, saIndexing],
      'TestPackage2.bpl symbols were never loaded although the package was mapped.' +
      ' prefetched modules:' + Dump);
  finally
    if not Session.HasExited then Session.Terminate;
    Session.Free;
    SetSymbolPrefetchEnabled(WasEnabled);
  end;
end;

procedure TDebugSessionTests.Prefetch_ModuleLoadedSynchronously_IsNotParsedAgain;
// SINGLE-LOAD-PATH REGRESSION TEST.
//
// A breakpoint inside a package makes HandleDllLoaded load that module
// synchronously at its LOAD_DLL event. The prefetcher must then leave it alone --
// the previous background loader did not, so the worker and the dispatch thread
// parsed the same file at the same time and one of the two readers was thrown
// away after both had been built. The observable consequence of a double
// registration is duplicated providers, i.e. every local reported twice, so that
// is what is asserted here alongside the claim state.
begin
  var Line := MarkerLineInFile(PackageSrc, 'PKG_BP');
  Assert.IsTrue(Line > 0, 'marker PKG_BP not found in TestPkgUnit.pas');

  var Session := TDebugSession.Create;
  try
    var Opts         := Default(TLaunchOptions);
    Opts.ExePath     := TargetExe;
    Opts.MapPath     := TargetMap;
    Opts.RsmPath     := TargetRsm;
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := True;
    Opts.Args        := '--load-package';
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var Deadline := GetTickCount64 + 60000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at entry');

    var LineSpec  := Default(TBpLineSpec);
    LineSpec.Line := Line;
    Session.SetBreakpoints('TestPkgUnit.pas', [LineSpec]);
    Session.ContinueExecution;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'did not stop at PKG_BP inside the runtime-loaded package');

    // The synchronous gate owns this module, so no claim may be outstanding.
    for var M in Session.Loader.Modules do
      if M.Name = 'testpackage.bpl' then
        Assert.IsFalse(M.PrefetchInFlight,
          'the prefetcher claimed a module the dispatch thread had already loaded');

    var Seen := TStringList.Create;
    try
      Seen.Sorted := True;
      for var V in Session.GetLocals do begin
        Assert.AreEqual(-1, Seen.IndexOf(V.Name),
          'local "' + V.Name + '" reported twice -- the module registered its ' +
          'providers more than once (double load)');
        Seen.Add(V.Name);
      end;
      Assert.IsTrue(Seen.Count > 0, 'no locals at all in the BPL frame');
    finally
      Seen.Free;
    end;
  finally
    if Session.State = dsStopped then Session.Terminate;
    Session.Free;
  end;
end;

{ ------------------------------------------------------ Win32 run control -- }

function TWin32RunControlTests.RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TWin32RunControlTests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function TWin32RunControlTests.Win32Exe: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.exe';
end;

function TWin32RunControlTests.Win32Map: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.map';
end;

function TWin32RunControlTests.Win32Rsm: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.rsm';
end;

function TWin32RunControlTests.Win64Exe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

function TWin32RunControlTests.Win64Map: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

function TWin32RunControlTests.Win64Rsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

function TWin32RunControlTests.MarkerLine(const SourceBaseName,
  Marker: string): Integer;
begin
  Result := MarkerLineInFile(TargetDir + SourceBaseName, Marker);
end;

function TWin32RunControlTests.MarkerLineInFile(const SourcePath,
  Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then
        Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

const
  W32_SOURCE = 'TestTargetEdge.pas';
  W32_MARKER = 'RECURSION_BASE_BODY';

procedure TWin32RunControlTests.Win32_Breakpoint_BindsAndFires;
begin
  Assert.IsTrue(FileExists(Win32Exe),
    '32-bit target missing -- build_target.bat should have produced ' + Win32Exe);
  var Line := MarkerLine(W32_SOURCE, W32_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + W32_MARKER);

  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    W32_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'a 32-bit target did not stop at its breakpoint');
    var FnName, SrcFile: string;
    var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnName, SrcFile, StopLine),
      'stopped but no location resolved');
    Assert.AreEqual(W32_SOURCE, ExtractFileName(SrcFile), 'wrong source file');
    Assert.AreEqual(Line, StopLine, 'stopped on the wrong line');
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.Win32_CallStack_UnwindsPastRecursion;
begin
  var Line := MarkerLine(W32_SOURCE, W32_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + W32_MARKER);
  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    W32_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop');
    var Frames := Session.GetCallStack;
    // The marker sits in the base case of a recursive function, so a walk that
    // works reaches well past frame 0. A broken unwind yields one frame.
    Assert.IsTrue(Length(Frames) >= 5,
      Format('expected the recursion to unwind, got %d frame(s)', [Length(Frames)]));
    // At least one frame above the top must be a NAMED frame from the target
    // itself, not just ntdll padding.
    var NamedInTarget := 0;
    for var I := 1 to High(Frames) do
      if (Frames[I].FunctionName <> '') and
         SameText(ExtractFileExt(Frames[I].SourceFile), '.pas') then
        Inc(NamedInTarget);
    Assert.IsTrue(NamedInTarget >= 2,
      Format('expected named caller frames with Pascal sources, got %d', [NamedInTarget]));
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.BreakpointOnBeginLine_ReportsPassedParameters;
const
  STEP_SOURCE = 'TestTargetCore.pas';

  // Returns 'AInt=<value>' for the named marker, or a diagnostic string.
  function AIntAt(const Exe, Map, Rsm: string; Line: Integer): string;
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, STEP_SOURCE, Line);
    try
      if Session.State <> dsStopped then
        Exit('<did not stop>');
      for var L in Session.GetLocals do
        if SameText(L.Name, 'AInt') then
          // The display carries a hex echo ("1234  (0x4D2)"); compare the
          // decimal head only, which is the part the assertion is about.
          Exit(L.Value.Split([' '])[0]);
      Result := '<AInt not listed>';
    finally
      Session.Free;
    end;
  end;

begin
  var BeginLine := MarkerLineInFile(TargetDir + STEP_SOURCE, 'STEPIN_PROBE_BEGIN');
  Assert.IsTrue(BeginLine > 0, 'marker STEPIN_PROBE_BEGIN not found');
  Assert.IsTrue(FileExists(Win64Exe), '64-bit control target missing');

  // The caller passes 1234. Before the fix the breakpoint bound to the routine's
  // entry and this read whatever the CALLER's frame happened to hold at that
  // slot -- a plausible number, never flagged.
  // Collected rather than asserted per case: both executables are named
  // TestTarget.exe, so a message built from the file name cannot say WHICH
  // bitness failed, and stopping at the first failure hides the other.
  var Failures := '';
  var Got64 := AIntAt(Win64Exe, Win64Map, Win64Rsm, BeginLine);
  if Got64 <> '1234' then
    Failures := Failures + 'x64 AInt=' + Got64 + '; ';
  var Got32 := AIntAt(Win32Exe, Win32Map, Win32Rsm, BeginLine);
  if Got32 <> '1234' then
    Failures := Failures + 'x86 AInt=' + Got32 + '; ';
  Assert.AreEqual('', Failures,
    'a breakpoint on `begin` must report the parameter the caller passed -- ' + Failures);
end;

procedure TWin32RunControlTests.Win32_CallStack_FramesAreCodeAndFramePointersAscend;
begin
  var Line := MarkerLine(W32_SOURCE, W32_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + W32_MARKER);
  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    W32_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop');
    var Frames := Session.GetCallStack;
    Assert.IsTrue(Length(Frames) >= 5,
      Format('expected the recursion to unwind, got %d frame(s)', [Length(Frames)]));

    // The stack region, taken from the frame pointers themselves. A PC that
    // lands inside it is the walker having read a stack slot and called it a
    // return address -- exactly the field failure, where a caller came back as
    // 0x14FF318 while the frame pointers around it were 0x14FF3xx.
    var LoFp := High(UInt64);
    var HiFp: UInt64 := 0;
    for var F in Frames do
      if F.FrameRBP <> 0 then begin
        if F.FrameRBP < LoFp then LoFp := F.FrameRBP;
        if F.FrameRBP > HiFp then HiFp := F.FrameRBP;
      end;
    Assert.IsTrue(HiFp > 0, 'no frame reported a frame pointer');

    for var I := 0 to High(Frames) do
      Assert.IsFalse((Frames[I].IP >= LoFp) and (Frames[I].IP <= HiFp),
        Format('frame %d PC $%x lies inside the stack region [$%x..$%x] -- ' +
               'the walker took a stack slot for a return address',
               [I, Frames[I].IP, LoFp, HiFp]));

    // The stack grows DOWN, so each caller's frame pointer must be strictly
    // above its callee's. Frames with no frame pointer (frameless system code)
    // are skipped rather than treated as a violation.
    var Prev: UInt64 := 0;
    for var I := 0 to High(Frames) do begin
      if Frames[I].FrameRBP = 0 then
        Continue;
      if Prev <> 0 then
        Assert.IsTrue(Frames[I].FrameRBP > Prev,
          Format('frame %d frame pointer $%x is not above its callee''s $%x',
                 [I, Frames[I].FrameRBP, Prev]));
      Prev := Frames[I].FrameRBP;
    end;
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.Win32_StackFrameNames_MatchWin64;

  function NamesAt(const Exe, Map, Rsm: string; Line: Integer): TArray<string>;
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, W32_SOURCE, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      Result := [];
      for var F in Session.GetCallStack do
        // Compare only the frames that belong to the target: the OS frames
        // below differ legitimately between a native and a WOW64 process.
        if SameText(ExtractFileExt(F.SourceFile), '.pas') or
           SameText(ExtractFileExt(F.SourceFile), '.dpr') then
          Result := Result + [F.FunctionName];
    finally
      Session.Free;
    end;
  end;

begin
  Assert.IsTrue(FileExists(Win64Exe), '64-bit control target missing');
  var Line := MarkerLine(W32_SOURCE, W32_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + W32_MARKER);

  var Names64 := NamesAt(Win64Exe, Win64Map, Win64Rsm, Line);
  var Names32 := NamesAt(Win32Exe, Win32Map, Win32Rsm, Line);

  Assert.IsTrue(Length(Names64) > 0, 'the 64-bit control produced no named frames');
  Assert.AreEqual(Length(Names64), Length(Names32),
    Format('frame counts differ: x64 %d vs x86 %d', [Length(Names64), Length(Names32)]));
  for var I := 0 to High(Names64) do
    Assert.AreEqual(Names64[I], Names32[I],
      Format('frame %d name differs between bitnesses', [I]));
end;

procedure TWin32RunControlTests.Win32_Locals_MatchWin64;

  function LocalsAt(const Exe, Map, Rsm: string; Line: Integer): TArray<string>;
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, W32_SOURCE, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      Result := [];
      for var L in Session.GetLocals do
        Result := Result + [L.Name + '=' + L.Value + ' [' + L.TypeName + ']'];
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLine(W32_SOURCE, W32_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + W32_MARKER);

  var Locals64 := LocalsAt(Win64Exe, Win64Map, Win64Rsm, Line);
  var Locals32 := LocalsAt(Win32Exe, Win32Map, Win32Rsm, Line);

  Assert.IsTrue(Length(Locals64) > 0, 'the 64-bit control reported no locals');
  Assert.AreEqual(Length(Locals64), Length(Locals32),
    Format('local counts differ: x64 %d vs x86 %d',
      [Length(Locals64), Length(Locals32)]));
  for var I := 0 to High(Locals64) do
    Assert.AreEqual(Locals64[I], Locals32[I],
      Format('local %d differs between bitnesses', [I]));
end;

// Addresses legitimately differ between two processes, so blank any hex run
// before comparing. What must match is the SHAPE of the value.
function WithoutAddresses(const S: string): string;
begin
  Result := '';
  var I := 1;
  while I <= Length(S) do begin
    var IsHexIntro := ((S[I] = '$') and (I < Length(S))) or
                      ((S[I] = '0') and (I < Length(S)) and (S[I + 1] = 'x'));
    if not IsHexIntro then begin
      Result := Result + S[I];
      Inc(I);
      Continue;
    end;
    Result := Result + '<addr>';
    if S[I] = '0' then Inc(I, 2) else Inc(I);
    while (I <= Length(S)) and CharInSet(S[I], ['0'..'9', 'A'..'F', 'a'..'f']) do
      Inc(I);
  end;
end;

procedure TWin32RunControlTests.Win32_ObjectFields_MatchWin64;
const
  OBJ_SOURCE = 'TestTargetCore.pas';
  OBJ_MARKER = 'COMPUTE_BODY';
  // Columns of DIVERGENT below.
  PREFIX     = 0;
  TYPE_ON_64 = 1;
  TYPE_ON_32 = 2;
  // Properties of TWidget that CANNOT report the same type on both
  // architectures -- reporting one type on both would itself be the bug:
  //
  //   AsPtr: NativeUInt -- a different concrete type per bitness.
  //   AsExt: Extended   -- a TRUE ALIAS of Double on Win64 (same TypeInfo, so
  //                        the name reported really is 'Double'), but a distinct
  //                        10-byte x87 type on Win32.
  //
  // Each is asserted explicitly and excluded from the blanket comparison; the
  // guard at the end fails if either stops appearing, so a rename in TWidget
  // cannot silently retire the check.
  // TWidget exposes the Extended twice -- as the field FArgE and as the
  // field-backed property ArgE -- and the expansion lists both.
  DIVERGENT: array[0..3, PREFIX..TYPE_ON_32] of string =
    (('AsPtr=', '[UInt64]', '[Cardinal]'),
     ('AsExt=', '[Double]', '[Extended]'),
     ('ArgE=',  '[Double]', '[Extended]'),
     ('FArgE=', '[Double]', '[Extended]'));

  function FieldsAt(const Exe, Map, Rsm: string; Line: Integer): TArray<string>;
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, OBJ_SOURCE, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      Result := [];
      for var L in Session.GetLocals do begin
        if not (L.Expandable and (L.Handle <> 0)) then Continue;
        // The members are grouped, so the field rows are one level below.
        for var G in Session.GetChildren(L.Handle) do
          if G.Expandable and (G.Handle <> 0) then
            for var F in Session.GetChildren(G.Handle) do
              Result := Result + [F.Name + '=' + WithoutAddresses(F.Value) +
                                  ' [' + F.TypeName + ']'];
        Break;
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + OBJ_SOURCE, OBJ_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + OBJ_MARKER);

  var Fields64 := FieldsAt(Win64Exe, Win64Map, Win64Rsm, Line);
  var Fields32 := FieldsAt(Win32Exe, Win32Map, Win32Rsm, Line);

  Assert.IsTrue(Length(Fields64) > 0, 'the 64-bit control expanded no fields');
  Assert.AreEqual(Length(Fields64), Length(Fields32),
    Format('field counts differ: x64 %d vs x86 %d',
      [Length(Fields64), Length(Fields32)]));

  var Seen: array[Low(DIVERGENT)..High(DIVERGENT)] of Boolean;
  for var D := Low(DIVERGENT) to High(DIVERGENT) do
    Seen[D] := False;

  for var I := 0 to High(Fields64) do begin
    var Matched := False;
    for var D := Low(DIVERGENT) to High(DIVERGENT) do
      if Fields64[I].StartsWith(DIVERGENT[D, PREFIX]) then begin
        Seen[D] := True;
        Matched := True;
        Assert.IsTrue(Fields64[I].EndsWith(DIVERGENT[D, TYPE_ON_64]),
          Format('x64 should report %s as %s, got %s',
            [DIVERGENT[D, PREFIX], DIVERGENT[D, TYPE_ON_64], Fields64[I]]));
        Assert.IsTrue(Fields32[I].EndsWith(DIVERGENT[D, TYPE_ON_32]),
          Format('x86 should report %s as %s, got %s',
            [DIVERGENT[D, PREFIX], DIVERGENT[D, TYPE_ON_32], Fields32[I]]));
      end;
    if Matched then
      Continue;
    Assert.AreEqual(Fields64[I], Fields32[I],
      Format('object field %d differs between bitnesses', [I]));
  end;

  for var D := Low(DIVERGENT) to High(DIVERGENT) do
    Assert.IsTrue(Seen[D],
      Format('expected a %s member in the expansion -- if TWidget changed, the ' +
             'bitness-dependent-type check above is no longer being exercised',
             [DIVERGENT[D, PREFIX]]));
end;

procedure TWin32RunControlTests.Win32_Evaluate_MatchesWin64;
const
  OBJ_SOURCE = 'TestTargetCore.pas';
  OBJ_MARKER = 'COMPUTE_BODY';
  EXPRS: array[0..3] of string =
    ('Self.Value',      // plain field
     'Self.Name',       // string handle: a pointer-width read
     'Self.Active',     // narrow ordinal
     'Self.Score');     // getter-backed: runs a synthetic call in the debuggee

  function EvalAll(const Exe, Map, Rsm: string; Line: Integer): TArray<string>;
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, OBJ_SOURCE, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      Result := [];
      for var E in EXPRS do begin
        var R := Session.Evaluate(E);
        Result := Result + [E + ' => ' + WithoutAddresses(R.Value) +
                            ' [' + R.TypeName + ']'];
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + OBJ_SOURCE, OBJ_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + OBJ_MARKER);

  var Eval64 := EvalAll(Win64Exe, Win64Map, Win64Rsm, Line);
  var Eval32 := EvalAll(Win32Exe, Win32Map, Win32Rsm, Line);

  for var I := 0 to High(Eval64) do
    Assert.AreEqual(Eval64[I], Eval32[I],
      'expression result differs between bitnesses');
  // Guard against the whole comparison passing because BOTH sides failed the
  // same way: the getter must actually have produced a number.
  Assert.IsTrue(Eval64[High(Eval64)].Contains('84'),
    'the getter-backed property should evaluate to 84, got ' + Eval64[High(Eval64)]);
end;

procedure TWin32RunControlTests.Win32_FloatFamilyReturns_MatchTheDeclaredValues;
const
  OBJ_SOURCE = 'TestTargetCore.pas';
  OBJ_MARKER = 'COMPUTE_BODY';
  // Expression, and the literal its getter in TestTargetCore returns. Int64 is
  // in the list because it shares the x86 return path's other half: EDX:EAX.
  EXPRS: array[0..6] of string =
    ('Self.AsSingle', 'Self.AsDouble', 'Self.AsReal',  'Self.AsExt',
     'Self.AsDate',   'Self.AsCurr',   'Self.AsInt64');
  EXPECTED: array[0..6] of string =
    ('1.5',           '3.25',          '6.75',         '2.5',
     '45000.5',       '19.95',         '1234605616436508552');

  // A formatted value either IS the number or leads with it, except that a
  // recognised TDateTime is rendered as a date with the raw number in trailing
  // parentheses. Accepting both shapes keeps the assertion strict without
  // making it depend on whether the alias name survived the debug info.
  function ReportsValue(const Formatted, Expected: string): Boolean;
  begin
    Result := Formatted.StartsWith(Expected) or
              Formatted.Contains('(' + Expected + ')');
  end;

  procedure CheckAll(const Exe, Map, Rsm: string; Line: Integer);
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, OBJ_SOURCE, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      for var I := Low(EXPRS) to High(EXPRS) do begin
        var R := Session.Evaluate(EXPRS[I]);
        Assert.IsTrue(ReportsValue(R.Value, EXPECTED[I]),
          Format('%s in %s: expected %s, got "%s" [%s]',
            [EXPRS[I], ExtractFileName(Exe), EXPECTED[I], R.Value, R.TypeName]));
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + OBJ_SOURCE, OBJ_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + OBJ_MARKER);
  CheckAll(Win64Exe, Win64Map, Win64Rsm, Line);
  CheckAll(Win32Exe, Win32Map, Win32Rsm, Line);
end;

procedure TWin32RunControlTests.Win32_RepeatedFloatEvaluations_DoNotExhaustTheX87Stack;
const
  OBJ_SOURCE = 'TestTargetCore.pas';
  OBJ_MARKER = 'COMPUTE_BODY';
  // Eight x87 registers, so ten calls is comfortably past a wrap.
  EVALUATIONS = 10;
begin
  var Line := MarkerLineInFile(TargetDir + OBJ_SOURCE, OBJ_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + OBJ_MARKER);

  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    OBJ_SOURCE, Line);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop');
    for var I := 1 to EVALUATIONS do begin
      var R := Session.Evaluate('Self.AsDouble');
      Assert.IsTrue(R.Value.StartsWith('3.25'),
        Format('float evaluation %d of %d returned "%s" -- an x87 stack that ' +
               'is not being unwound between synthetic calls shows up here first',
               [I, EVALUATIONS, R.Value]));
    end;
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.Win32_WideFloatLocals_ReadTheirFullWidth;
const
  SRC    = 'TestTargetCore.pas';
  MARKER = 'NESTED_INC';
  NAMES:    array[0..1] of string = ('Ext1',  'R48');
  EXPECTED: array[0..1] of string = ('2.75',  '3.5');

  procedure CheckAll(const Exe, Map, Rsm: string; Line: Integer);
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, SRC, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      for var I := Low(NAMES) to High(NAMES) do begin
        var Found := False;
        for var L in Session.GetLocals do
          if SameText(L.Name, NAMES[I]) then begin
            Found := True;
            Assert.IsTrue(L.Value.StartsWith(EXPECTED[I]),
              Format('%s in %s: expected %s, got "%s" [%s]',
                [NAMES[I], ExtractFileName(Exe), EXPECTED[I], L.Value, L.TypeName]));
          end;
        Assert.IsTrue(Found,
          Format('%s missing from the locals of ComputeNested in %s',
            [NAMES[I], ExtractFileName(Exe)]));
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + SRC, MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + MARKER);
  CheckAll(Win64Exe, Win64Map, Win64Rsm, Line);
  CheckAll(Win32Exe, Win32Map, Win32Rsm, Line);
end;

procedure TWin32RunControlTests.Win32_RecordAndDynArrayExpansion_MatchWin64;
const
  SRC    = 'TestTargetTypes.pas';
  MARKER = 'TYPES_BODY';
  // MRec is a managed record (a string plus a dynamic array of Integer), so one
  // expansion covers the record field table AND, one level down, the dyn-array
  // header and element stride.
  SUBJECT = 'MRec';

  function ChildrenOf(const Exe, Map, Rsm: string; Line: Integer): TArray<string>;
  begin
    Result := [];
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, SRC, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'did not stop in ' + ExtractFileName(Exe));
      for var L in Session.GetLocals do begin
        if not SameText(L.Name, SUBJECT) then Continue;
        Assert.IsTrue(L.Expandable and (L.Handle <> 0),
          SUBJECT + ' should be expandable in ' + ExtractFileName(Exe));
        for var F in Session.GetChildren(L.Handle) do begin
          Result := Result + [F.Name + '=' + WithoutAddresses(F.Value) +
                              ' [' + F.TypeName + ']'];
          // One level deeper, which is where the dynamic array lives.
          if F.Expandable and (F.Handle <> 0) then
            for var G in Session.GetChildren(F.Handle) do
              Result := Result + ['  ' + G.Name + '=' + WithoutAddresses(G.Value) +
                                  ' [' + G.TypeName + ']'];
        end;
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + SRC, MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + MARKER);

  var Rows64 := ChildrenOf(Win64Exe, Win64Map, Win64Rsm, Line);
  var Rows32 := ChildrenOf(Win32Exe, Win32Map, Win32Rsm, Line);

  Assert.IsTrue(Length(Rows64) > 0, 'the 64-bit control expanded nothing');
  Assert.AreEqual(Length(Rows64), Length(Rows32),
    Format('child counts differ: x64 %d vs x86 %d', [Length(Rows64), Length(Rows32)]));
  for var I := 0 to High(Rows64) do
    Assert.AreEqual(Rows64[I], Rows32[I],
      Format('%s child %d differs between bitnesses', [SUBJECT, I]));
  // Guard against both sides agreeing on an empty-looking expansion: the record
  // really does hold 'managed' and a three-element array.
  var Joined := string.Join('|', Rows64);
  Assert.IsTrue(Joined.Contains('managed'),
    'expected the record''s string field to read "managed", got: ' + Joined);
end;

procedure TWin32RunControlTests.Win32_SetWideFloatLocals_RoundTrip;
const
  SRC    = 'TestTargetCore.pas';
  MARKER = 'NESTED_INC';
  NAMES:     array[0..1] of string = ('Ext1', 'R48');
  NEW_VALUE: array[0..1] of string = ('9.5',  '6.25');

  // Failures are COLLECTED, not asserted per case. Both architectures and both
  // types have to be reported: stopping at the first one hides whether the
  // other three also broke, and the two executables share a file name so a
  // message built from it cannot say which bitness failed.
  procedure CollectFailures(const Bitness, Exe, Map, Rsm: string; Line: Integer;
    var Failures: TArray<string>);
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, SRC, Line);
    try
      if Ord(Session.State) <> Ord(dsStopped) then begin
        Failures := Failures + [Bitness + ': did not stop'];
        Exit;
      end;
      for var I := Low(NAMES) to High(NAMES) do begin
        var NewValue, NewType: string;
        if not Session.SetLocalVariable(NAMES[I], NEW_VALUE[I], NewValue, NewType) then
          Failures := Failures + [Format('%s %s: set rejected (%s)',
            [Bitness, NAMES[I], NewValue])]
        else if not NewValue.StartsWith(NEW_VALUE[I]) then
          Failures := Failures + [Format('%s %s: wrote %s, read back "%s"',
            [Bitness, NAMES[I], NEW_VALUE[I], NewValue])];
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + SRC, MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + MARKER);

  var Failures: TArray<string> := [];
  CollectFailures('x64', Win64Exe, Win64Map, Win64Rsm, Line, Failures);
  CollectFailures('x86', Win32Exe, Win32Map, Win32Rsm, Line, Failures);
  Assert.IsTrue(Length(Failures) = 0, string.Join(' | ', Failures));
end;

procedure TWin32RunControlTests.Win32_SyntheticCallArguments_MatchWin64;
const
  SRC    = 'TestTargetCore.pas';
  MARKER = 'COMPUTE_BODY';
  // Ordinals in registers, ordinals overflowing to the stack, a plain Double,
  // and finally one argument of every class at once.
  EXPRS: array[0..3] of string =
    ('Self.Mult(3, 4)',
     'Self.Sum5(1, 2, 3, 4, 5)',
     'Self.Scale(2.5)',
     'Self.SumArgs(1, Self.ArgD, 2, Self.ArgS, Self.ArgE, Self.ArgI64, Self.ArgCur)');
  EXPECTED: array[0..3] of string = ('54', '12345', '5.5', '127');

  procedure CollectFailures(const Bitness, Exe, Map, Rsm: string; Line: Integer;
    var Failures: TArray<string>);
  begin
    var Session := OpenSessionAtMarker(Exe, Map, Rsm, TargetDir, SRC, Line);
    try
      if Ord(Session.State) <> Ord(dsStopped) then begin
        Failures := Failures + [Bitness + ': did not stop'];
        Exit;
      end;
      for var I := Low(EXPRS) to High(EXPRS) do begin
        var R := Session.Evaluate(EXPRS[I]);
        if not R.Value.StartsWith(EXPECTED[I]) then
          Failures := Failures + [Format('%s %s: expected %s, got "%s"',
            [Bitness, EXPRS[I], EXPECTED[I], R.Value])];
      end;
    finally
      Session.Free;
    end;
  end;

begin
  var Line := MarkerLineInFile(TargetDir + SRC, MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + MARKER);

  var Failures: TArray<string> := [];
  CollectFailures('x64', Win64Exe, Win64Map, Win64Rsm, Line, Failures);
  CollectFailures('x86', Win32Exe, Win32Map, Win32Rsm, Line, Failures);
  Assert.IsTrue(Length(Failures) = 0, string.Join(' | ', Failures));
end;

procedure TWin32RunControlTests.Win32_ExceptionStop_NamesClassAndMessage;

  // Launches with NO breakpoint and lets the first-chance Delphi filter stop the
  // target at whatever it raises first, which is what a real session does.
  function FirstExceptionStop(const Exe, Map, Rsm: string): TSessionExceptionInfo;
  begin
    Result := Default(TSessionExceptionInfo);
    var Session := TDebugSession.Create;
    try
      var Opts: TLaunchOptions;
      Opts             := Default(TLaunchOptions);
      Opts.ExePath     := Exe;
      Opts.MapPath     := Map;
      Opts.RsmPath     := Rsm;
      Opts.SourceRoot  := TargetDir;
      Opts.StopAtEntry := False;
      // RunExceptionTest is switch-gated, so the default run raises nothing and
      // the target would simply exit.
      Opts.Args        := '-run-exception-test';
      Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

      var Deadline := GetTickCount64 + 60000;
      while (Session.State <> dsStopped) and (not Session.HasExited) and
            (GetTickCount64 < Deadline) do
        Session.Pump;
      if Session.State = dsStopped then
        Result := Session.GetExceptionDetails;
    finally
      Session.Free;
    end;
  end;

begin
  var Exc64 := FirstExceptionStop(Win64Exe, Win64Map, Win64Rsm);
  var Exc32 := FirstExceptionStop(Win32Exe, Win32Map, Win32Rsm);

  // The 64-bit control first: if it stops naming nothing, the target changed and
  // the comparison below would pass by agreeing on emptiness.
  Assert.AreEqual('Exception', Exc64.ExceptionClass,
    'x64 control did not name the raised class');
  Assert.IsTrue(Exc64.Message <> '', 'x64 control carried no message');
  Assert.IsTrue(Exc64.ObjectVA <> 0, 'x64 control published no $exception object');

  Assert.AreEqual(Exc64.ExceptionClass, Exc32.ExceptionClass,
    Format('exception class differs: x64 "%s" vs x86 "%s"',
      [Exc64.ExceptionClass, Exc32.ExceptionClass]));
  Assert.AreEqual(Exc64.Message, Exc32.Message,
    Format('exception message differs: x64 "%s" vs x86 "%s"',
      [Exc64.Message, Exc32.Message]));
  Assert.IsTrue(Exc32.ObjectVA <> 0,
    'x86 published no $exception object -- the class read must have failed');
end;

procedure PumpUntilStop(Session: TDebugSession; TimeoutMs: Cardinal);
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while (Session.State <> dsStopped) and (not Session.HasExited) and
        (GetTickCount64 < Deadline) do
    Session.Pump;
end;

procedure TWin32RunControlTests.Win32_StepInto_LandsInTheCallee;
const
  STEP_SOURCE = 'TestTargetCore.pas';
begin
  var CallSite := MarkerLineInFile(TargetDir + STEP_SOURCE, 'STEPIN_CALLSITE');
  Assert.IsTrue(CallSite > 0, 'marker STEPIN_CALLSITE not found');

  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    STEP_SOURCE, CallSite);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at the call site');
    Session.StepInto;
    PumpUntilStop(Session, 30000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'step-into produced no stop on a 32-bit target');

    var FnName, SrcFile: string;
    var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnName, SrcFile, StopLine),
      'no location after step-into');
    Assert.IsTrue(FnName.Contains('StepIntoProbe'),
      'step-into did not land in the callee, got: ' + FnName);
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.Win32_StepOver_AdvancesWithinTheSameFrame;
const
  STEP_SOURCE = 'TestTargetCore.pas';
begin
  var CallSite := MarkerLineInFile(TargetDir + STEP_SOURCE, 'STEPIN_CALLSITE');
  Assert.IsTrue(CallSite > 0, 'marker STEPIN_CALLSITE not found');

  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    STEP_SOURCE, CallSite);
  try
    var FnBefore, SrcBefore: string;
    var LineBefore: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnBefore, SrcBefore, LineBefore),
      'no location before the step');

    Session.StepOver;
    PumpUntilStop(Session, 30000);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'step-over produced no stop on a 32-bit target');

    var FnAfter, SrcAfter: string;
    var LineAfter: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnAfter, SrcAfter, LineAfter),
      'no location after the step');
    // Stepping OVER a call must stay in the caller and move on.
    Assert.AreEqual(FnBefore, FnAfter,
      'step-over left the frame it started in');
    Assert.IsTrue(LineAfter <> LineBefore,
      Format('step-over did not advance: still on line %d', [LineAfter]));
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.Win32_StepOverCallWithStackArgument_LandsOnTheNextLine;
const
  STEP_SOURCE = 'TestTargetCore.pas';
begin
  var CallSite := MarkerLineInFile(TargetDir + STEP_SOURCE, 'STEPOVER_STACKARG');
  var NextLine := MarkerLineInFile(TargetDir + STEP_SOURCE, 'STEPOVER_STACKARG_NEXT');
  Assert.IsTrue(CallSite > 0, 'marker STEPOVER_STACKARG not found');
  Assert.IsTrue(NextLine > 0, 'marker STEPOVER_STACKARG_NEXT not found');

  var Session := OpenSessionAtMarker(Win32Exe, Win32Map, Win32Rsm, TargetDir,
    STEP_SOURCE, CallSite);
  try
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at the call site');
    Session.StepOver;
    PumpUntilStop(Session, 30000);
    // The failure mode is a RUNAWAY, not a wrong line: the run-to-return
    // breakpoint is planted at a spliced 64-bit address, fails to plant, and
    // nothing stops the target again -- so this assertion is the real one.
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
      'step-over over a call with a stack argument never stopped again');

    var FnAfter, SrcAfter: string;
    var LineAfter: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnAfter, SrcAfter, LineAfter),
      'no location after the step');
    Assert.AreEqual(NextLine, LineAfter,
      Format('step-over landed on line %d, expected %d', [LineAfter, NextLine]));
  finally
    Session.Free;
  end;
end;

procedure TWin32RunControlTests.Win32_Bpl_BreakpointInPackage_FiresWithLocals;

  function HostDir(const Bitness: string): string;
  begin
    Result := RepoRoot + 'DebuggerTests\TestHost\' + Bitness + '\Debug\';
  end;

  // Returns 'module|function|line|locals' so one comparison covers module
  // attribution, symbol resolution and the frame read together.
  function StopShape(const Bitness: string; Line: Integer): string;
  begin
    var Dir := HostDir(Bitness);
    var Session := OpenSessionAtMarker(Dir + 'TestHost.exe', Dir + 'TestHost.map',
      Dir + 'TestHost.rsm', TargetDir, W32_SOURCE, Line);
    try
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State),
        'the ' + Bitness + ' BPL host did not stop');
      var Frames := Session.GetCallStack;
      Assert.IsTrue(Length(Frames) > 0, 'no frames');
      var FnName, SrcFile: string;
      var StopLine: Integer;
      Session.GetCurrentLocation(FnName, SrcFile, StopLine);
      Result := LowerCase(Frames[0].ModuleName) + '|' + FnName + '|' +
                IntToStr(StopLine);
      for var L in Session.GetLocals do
        Result := Result + '|' + L.Name + '=' + L.Value;
    finally
      Session.Free;
    end;
  end;

begin
  Assert.IsTrue(FileExists(HostDir('Win32') + 'TestHost.exe'),
    '32-bit BPL host missing -- build_host.bat should have produced it');
  var Line := MarkerLine(W32_SOURCE, W32_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found: ' + W32_MARKER);

  var Shape64 := StopShape('Win64', Line);
  var Shape32 := StopShape('Win32', Line);

  // The frame must belong to the PACKAGE, not the host -- otherwise the test
  // would pass on a debugger that never resolved the module at all.
  Assert.IsTrue(Shape64.StartsWith('testsubject.bpl|'),
    'the x64 control did not stop inside the package: ' + Shape64);
  Assert.AreEqual(Shape64, Shape32,
    'the 32-bit BPL stop differs from the 64-bit one');
end;

initialization
  TDUnitX.RegisterTestFixture(TDebugSessionTests);
  TDUnitX.RegisterTestFixture(TWin32RunControlTests);

end.
