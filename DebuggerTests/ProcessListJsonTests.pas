unit ProcessListJsonTests;

// Unit tests for the adapter's `--list-processes` mode, the source the VS Code
// extension's attach picker reads instead of parsing localized `tasklist`
// output. What matters to the picker is the contract: one line, one JSON array,
// every field it needs on every entry.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TProcessListJsonTests = class
  public
    [Test] procedure Args_SwitchAlone_RequestsListingWithoutFilter;
    [Test] procedure Args_SwitchWithName_CarriesTheFilter;
    [Test] procedure Args_SwitchFollowedByAnotherSwitch_HasNoFilter;
    [Test] procedure Args_WithoutSwitch_IsNotAListing;
    [Test] procedure Json_IsASingleLineArray;
    [Test] procedure Json_CarriesEveryFieldThePickerReads;
    [Test] procedure Json_ArchMismatch_ReportsCanDebugFalseWithReason;
    [Test] procedure Json_Wow64Target_IsAttachableFromAnX64Debugger;
    [Test] procedure Json_EscapesQuotesAndControlCharacters;
    [Test] procedure Json_EmptyListIsAnEmptyArray;
    [Test] procedure Json_WindowTitleIsCarriedAndEmptyForAWindowlessProcess;
    [Test] procedure Enumerate_FindsThisProcessAndSaysItIsDebuggable;
    [Test] procedure WindowTitles_LeaveAConsoleProcessAlone;
    [Test] procedure WindowTitles_FindTheCaptionOfAVisibleWindow;
  end;

implementation

uses
  System.SysUtils, System.JSON, Winapi.Windows,
  ProcessEnum, ProcessListJson;

function SampleProcess: TProcessInfo;
begin
  Result := Default(TProcessInfo);
  Result.Pid := 7788;
  Result.ParentPid := 16692;
  Result.SessionId := 1;
  Result.ExeName := 'SampleApp.exe';
  Result.ExePath := 'C:\Apps\SampleApp.exe';
  Result.CommandLine := 'C:\Apps\SampleApp.exe /project=Customers';
  Result.Arch := HostDebuggerArch;
end;

function ParseSingleObject(const Json: string): TJSONObject;
begin
  var Items := TJSONObject.ParseJSONValue(Json) as TJSONArray;
  Assert.IsNotNull(Items, 'the listing must be a JSON array');
  try
    Assert.AreEqual(1, Items.Count);
    Result := Items.Items[0].Clone as TJSONObject;
  finally
    Items.Free;
  end;
end;

procedure TProcessListJsonTests.Args_SwitchAlone_RequestsListingWithoutFilter;
begin
  var NameFilter: string;
  Assert.IsTrue(ParseProcessListArgs(['--list-processes'], NameFilter));
  Assert.AreEqual('', NameFilter);
end;

procedure TProcessListJsonTests.Args_SwitchWithName_CarriesTheFilter;
begin
  var NameFilter: string;
  Assert.IsTrue(ParseProcessListArgs(['--list-processes', 'SampleApp.exe'], NameFilter));
  Assert.AreEqual('SampleApp.exe', NameFilter);
end;

procedure TProcessListJsonTests.Args_SwitchFollowedByAnotherSwitch_HasNoFilter;
begin
  var NameFilter: string;
  Assert.IsTrue(ParseProcessListArgs(['--list-processes', '--verbose'], NameFilter));
  Assert.AreEqual('', NameFilter);
end;

procedure TProcessListJsonTests.Args_WithoutSwitch_IsNotAListing;
begin
  var NameFilter: string;
  Assert.IsFalse(ParseProcessListArgs([], NameFilter));
  Assert.IsFalse(ParseProcessListArgs(['--something-else', 'x'], NameFilter));
end;

procedure TProcessListJsonTests.Json_IsASingleLineArray;
begin
  // The reader picks the JSON out of stdout line by line, so no value may ever
  // introduce a line break.
  var Info := SampleProcess;
  Info.CommandLine := 'app.exe --a' + #13#10 + '--b';
  var Json := BuildProcessListJson([Info]);
  Assert.AreEqual(0, Pos(#10, Json), 'the listing must stay on one line');
  Assert.AreEqual(0, Pos(#13, Json), 'the listing must stay on one line');
  Assert.IsTrue(Json.StartsWith('[') and Json.EndsWith(']'));
end;

procedure TProcessListJsonTests.Json_CarriesEveryFieldThePickerReads;
begin
  var Item := ParseSingleObject(BuildProcessListJson([SampleProcess]));
  try
    Assert.AreEqual(7788, Item.GetValue<Integer>('pid'));
    Assert.AreEqual(16692, Item.GetValue<Integer>('parentPid'));
    Assert.AreEqual(1, Item.GetValue<Integer>('sessionId'));
    Assert.AreEqual('SampleApp.exe', Item.GetValue<string>('name'));
    Assert.AreEqual('C:\Apps\SampleApp.exe', Item.GetValue<string>('path'));
    Assert.AreEqual('C:\Apps\SampleApp.exe /project=Customers', Item.GetValue<string>('commandLine'));
    Assert.AreEqual(ArchToStr(HostDebuggerArch), Item.GetValue<string>('arch'));
    Assert.IsTrue(Item.GetValue<Boolean>('canDebug'), 'a same-architecture target is debuggable');
    Assert.AreEqual('', Item.GetValue<string>('reason'));
  finally
    Item.Free;
  end;
end;

procedure TProcessListJsonTests.Json_ArchMismatch_ReportsCanDebugFalseWithReason;
begin
  var Info := SampleProcess;
  // ARM64, not x86: an x64 debugger DOES debug a WOW64 x86 target, and this
  // test used to assert the opposite by picking "any architecture that is not
  // the host". That is how a stale refusal survives a green suite.
  Info.Arch := paArm64;

  var Item := ParseSingleObject(BuildProcessListJson([Info]));
  try
    Assert.IsFalse(Item.GetValue<Boolean>('canDebug'));
    // The picker shows this text verbatim, so it must be a sentence a user can
    // act on rather than an empty string or a code.
    Assert.IsTrue(Item.GetValue<string>('reason').Contains('x64 and x86'),
      'the reason must explain the refusal: ' + Item.GetValue<string>('reason'));
  finally
    Item.Free;
  end;
end;

// The defect this pins shipped: `CanDebug` demanded the target match the
// debugger's own architecture, so every 32-bit process was listed as not
// attachable and the picker refused it -- while `Attach_ToRunningTarget_
// StopsWithLocalsOnBothBitnesses` proved the engine attaches to one just fine.
// A gate that contradicts the engine is worse than no gate: it makes a working
// feature look unimplemented.
procedure TProcessListJsonTests.Json_Wow64Target_IsAttachableFromAnX64Debugger;
begin
  if HostDebuggerArch <> paX64 then begin
    Assert.Pass('this assertion is about an x64 debugger; the host is not one');
    Exit;
  end;

  var Info := SampleProcess;
  Info.Arch := paX86;

  var Item := ParseSingleObject(BuildProcessListJson([Info]));
  try
    Assert.IsTrue(Item.GetValue<Boolean>('canDebug'),
      'a 32-bit process must be offered for attach: ' + Item.GetValue<string>('reason'));
    Assert.AreEqual('', Item.GetValue<string>('reason'),
      'an attachable process must carry no refusal reason');
  finally
    Item.Free;
  end;
end;

procedure TProcessListJsonTests.Json_EscapesQuotesAndControlCharacters;
begin
  var Info := SampleProcess;
  Info.CommandLine := '"C:\Program Files\A B\app.exe" --flag' + #9 + 'x';
  var Item := ParseSingleObject(BuildProcessListJson([Info]));
  try
    Assert.AreEqual(Info.CommandLine, Item.GetValue<string>('commandLine'),
      'a quoted command line must round-trip through the JSON');
  finally
    Item.Free;
  end;
end;

procedure TProcessListJsonTests.Json_EmptyListIsAnEmptyArray;
begin
  // No match is a valid answer: the picker distinguishes it from a failure.
  Assert.AreEqual('[]', BuildProcessListJson(nil));
end;

procedure TProcessListJsonTests.Enumerate_FindsThisProcessAndSaysItIsDebuggable;
begin
  var Own := ExtractFileName(ParamStr(0));
  var Json := BuildProcessListJson(EnumerateProcesses(Own));
  Assert.IsTrue(Json.Contains('"pid":' + IntToStr(GetCurrentProcessId)),
    'the running test process must appear in a listing filtered by its own name');
  Assert.IsTrue(Json.Contains('"canDebug":true'),
    'the test runner is the same architecture as the debugger and must be debuggable');
end;

procedure TProcessListJsonTests.Json_WindowTitleIsCarriedAndEmptyForAWindowlessProcess;
begin
  var WithWindow := SampleProcess;
  WithWindow.MainWindowTitle := 'SampleApp - Customers';
  WithWindow.StartTime := EncodeDate(2026, 7, 21) + EncodeTime(17, 5, 44, 0);
  var Item := ParseSingleObject(BuildProcessListJson([WithWindow]));
  try
    Assert.AreEqual('SampleApp - Customers', Item.GetValue<string>('windowTitle'));
    Assert.AreEqual('2026-07-21T17:05:44', Item.GetValue<string>('startTime'),
      'the picker shows this verbatim, so it must be locale-independent');
  finally
    Item.Free;
  end;

  // The field must still be present, and empty rather than absent: the picker
  // reads it unconditionally and shows the command line when it is blank.
  var Windowless := ParseSingleObject(BuildProcessListJson([SampleProcess]));
  try
    Assert.AreEqual('', Windowless.GetValue<string>('windowTitle'));
    Assert.AreEqual('', Windowless.GetValue<string>('startTime'),
      'an unknown start time is empty, never a 1899 placeholder');
  finally
    Windowless.Free;
  end;
end;

procedure TProcessListJsonTests.WindowTitles_LeaveAConsoleProcessAlone;
begin
  // A process with no top-level window of its own must come back blank, not
  // borrow another process's caption. (On current Windows the console window
  // belongs to conhost, not to the program printing into it.)
  var Processes: TArray<TProcessInfo> := [SampleProcess]; // a pid that owns no window here
  AttachMainWindowTitles(Processes);
  Assert.AreEqual('', Processes[0].MainWindowTitle);
end;

procedure TProcessListJsonTests.WindowTitles_FindTheCaptionOfAVisibleWindow;
const
  Caption = 'Win64Debugger window-title probe';
begin
  // Positioned off-screen so the suite does not flash a window at the user; it
  // still has to be genuinely visible, since that is what the enumeration filters on.
  var Wnd := CreateWindowEx(0, 'STATIC', Caption, WS_OVERLAPPEDWINDOW or WS_VISIBLE,
    -32000, -32000, 120, 40, 0, 0, HInstance, nil);
  Assert.IsTrue(Wnd <> 0, 'could not create the probe window');
  try
    var Own: TProcessInfo;
    Assert.IsTrue(GetProcessInfo(GetCurrentProcessId, Own), 'own process info');
    var Processes: TArray<TProcessInfo> := [Own];
    AttachMainWindowTitles(Processes);
    Assert.AreEqual(Caption, Processes[0].MainWindowTitle);
  finally
    DestroyWindow(Wnd);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessListJsonTests);

end.
