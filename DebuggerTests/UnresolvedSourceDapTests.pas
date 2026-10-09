unit UnresolvedSourceDapTests;

// A frame whose unit and line ARE known, but whose .pas is not under any
// configured root.
//
// This is NOT the sourceless frame PlaceholderDisassemblyTests covers. There the
// symbols fall short; here they are complete and only the file is missing -- the
// everyday case of debugging a binary built on a machine whose source layout
// differs from this one, or of a project whose units live outside `sourceRoot`.
//
// THE BUG: the frame's `source` carried a `name` and nothing else -- no `path`,
// because none resolved, and no `sourceReference`, because that branch never
// minted one. VS Code does not read that as "no source". It issues a `source`
// request with the reference defaulted to 0, the adapter has no document under
// 0, and VS Code renders the error response AS THE FILE CONTENT: selecting a
// frame in your own code opened an editor reading
// `Could not load source 'Foo.pas': Unknown sourceReference 0`.
//
// Fixture: InstructionStepSample's exe/map/rsm copied into a scratch directory
// WITHOUT its .dpr, launched from there with `sourceRoot` pointing at that same
// directory. Every root the resolver probes -- sourceRoot, the debuggee
// directory, its parent and grandparent -- is then real and searched, and none
// of them holds the file. Copying rather than mis-pointing sourceRoot at the
// real tree matters: the exe's own directory is a root too, so a target left
// where it was built resolves no matter what sourceRoot says.

interface

uses
  DUnitX.TestFramework, DapClient;

type
  [TestFixture]
  TUnresolvedSourceDapTests = class
  private
    FClient:  TDapClient;
    FScratch: string;
    // Copies the sample's binaries into FScratch (no source), launches from
    // there, stops at MARKER, and returns frame 0 of the stopped thread. The
    // caller owns nothing: the frame belongs to the stackTrace response, which
    // is freed before returning, so the two values that matter come back as
    // out-parameters instead.
    procedure StopInUnresolvedUnit(out ASourceRef: Integer; out APath: string);
    function  PlaceholderText(ASourceRef: Integer): string;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // The defect itself: the Source must be openable. A `name` with neither
    // `path` nor `sourceReference` is the shape that made VS Code display an
    // error message as the file's text.
    [Test] procedure Win64_SourceFileMissing_FrameOffersAPlaceholderReference;
    // The document must describe THIS situation -- file missing -- and not the
    // stale-symbols reasons, which are all false here and would send the user
    // off to rebuild a module that is fine.
    [Test] procedure Win64_SourceFileMissing_DocumentNamesTheFileAndTheFix;
    // What was actually searched, so the fix is a directory the user can read
    // off the page rather than a guess.
    [Test] procedure Win64_SourceFileMissing_DocumentListsTheSearchedRoots;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.JSON,
  TestTempDirs;

const
  SAMPLE_SOURCE = 'InstructionStepSample.dpr';
  SAMPLE_STEM   = 'InstructionStepSample';
  MARKER        = 'INSTR_MULTI';
  SCRATCH_PREFIX = 'UnresolvedSrc_';

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

function BuiltDir: string;
begin
  Result := TargetDir + 'Win64\Debug\';
end;

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

{ ------------------------------------------------------------------ setup -- }

procedure TUnresolvedSourceDapTests.Setup;
begin
  PurgeLeftoverTempDirs(SCRATCH_PREFIX);
  FScratch := MakeTestScratchDir(SCRATCH_PREFIX);
end;

procedure TUnresolvedSourceDapTests.TearDown;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect.Free;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
  // After the session, never before: the debuggee runs from the copied exe.
  if FScratch <> '' then
    DeleteTempDirWithRetry(FScratch);
end;

procedure TUnresolvedSourceDapTests.StopInUnresolvedUnit(
  out ASourceRef: Integer; out APath: string);
begin
  var Line := FindBpLine(SamplePath, MARKER);
  Assert.IsTrue(Line > 0, 'marker ' + MARKER + ' not found in ' + SAMPLE_SOURCE);
  Assert.IsTrue(FileExists(BuiltDir + SAMPLE_STEM + '.exe'),
    'fixture not built: ' + BuiltDir + SAMPLE_STEM + '.exe');

  for var Ext in ['.exe', '.map', '.rsm'] do
    TFile.Copy(BuiltDir + SAMPLE_STEM + Ext,
      TPath.Combine(FScratch, SAMPLE_STEM + Ext), True);
  Assert.IsFalse(TFile.Exists(TPath.Combine(FScratch, SAMPLE_SOURCE)),
    'the fixture only works while the scratch copy has NO source beside it');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  // The breakpoint is still set through the REAL path: a user whose source the
  // adapter cannot find still has it open in the editor, and that is where the
  // breakpoint comes from. Binding goes through the MAP line table by file name,
  // so it does not depend on the file resolving.
  FClient.SetBreakpoints(SamplePath, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TPath.Combine(FScratch, SAMPLE_STEM + '.exe'),
                 TPath.Combine(FScratch, SAMPLE_STEM + '.map'),
                 TPath.Combine(FScratch, SAMPLE_STEM + '.rsm'),
                 FScratch).Free;
  FClient.ConfigDone.Free;

  var Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      Format('did not stop at %s (line %d); got reason: %s',
        [MARKER, Line, Stopped.GetValue<string>('reason', '')]));
  finally
    Stopped.Free;
  end;

  ASourceRef := 0;
  APath      := '';
  var ST := FClient.StackTrace;
  try
    var Frames := ST.GetValue<TJSONArray>('stackFrames');
    Assert.IsNotNull(Frames, 'stackTrace returned no frames array');
    Assert.IsTrue(Frames.Count > 0, 'stackTrace returned an empty stack');
    var F0  := Frames.Items[0] as TJSONObject;
    var Src := F0.GetValue<TJSONObject>('source', nil);
    Assert.IsNotNull(Src,
      'frame 0 carried no source at all -- the breakpoint line IS known, so a ' +
      'document explaining the missing file is owed here');
    APath      := Src.GetValue<string>('path', '');
    ASourceRef := Src.GetValue<Integer>('sourceReference', 0);
  finally
    ST.Free;
  end;
end;

function TUnresolvedSourceDapTests.PlaceholderText(ASourceRef: Integer): string;
begin
  var Resp := FClient.SourceContent(ASourceRef);
  try
    Result := Resp.GetValue<string>('content', '');
  finally
    Resp.Free;
  end;
end;

{ ---------------------------------------------------------------- tests ---- }

procedure TUnresolvedSourceDapTests.Win64_SourceFileMissing_FrameOffersAPlaceholderReference;
begin
  var Ref: Integer;
  var Path: string;
  StopInUnresolvedUnit(Ref, Path);

  Assert.AreEqual('', Path,
    'the fixture is wrong, not the adapter: the source resolved after all, to ' + Path);
  // RED before the fix: the branch emitted a name-only Source and left the
  // reference at 0, which is what VS Code then asked for.
  Assert.IsTrue(Ref > 0,
    'a source with neither a path nor a sourceReference makes VS Code request ' +
    'reference 0 and render the error as the file content');
  Assert.IsTrue(PlaceholderText(Ref) <> '',
    'the reference the frame offered returned no document');
end;

procedure TUnresolvedSourceDapTests.Win64_SourceFileMissing_DocumentNamesTheFileAndTheFix;
begin
  var Ref: Integer;
  var Path: string;
  StopInUnresolvedUnit(Ref, Path);
  var Content := PlaceholderText(Ref);

  Assert.IsTrue(Content.Contains('Source file not found on disk'),
    'the document must say what is actually wrong; got: ' + Content);
  Assert.IsTrue(Content.Contains(SAMPLE_SOURCE),
    'the document must name the file that was looked for; got: ' + Content);
  Assert.IsTrue(Content.Contains('sourceRoot') and Content.Contains('sourceSearchPaths'),
    'the document must name the two settings that fix it; got: ' + Content);
  // The symbols are complete here. Offering the stale-symbol advice would send
  // the user to rebuild a module that is in perfect order.
  Assert.IsFalse(Content.Contains('does not cover this address'),
    'this is not a symbol-coverage failure and must not be described as one; got: ' + Content);
  Assert.IsFalse(Content.Contains('No source available for this stack frame'),
    'the sourceless-frame document is the wrong one for a frame that HAS a line; got: ' + Content);
end;

procedure TUnresolvedSourceDapTests.Win64_SourceFileMissing_DocumentListsTheSearchedRoots;
begin
  var Ref: Integer;
  var Path: string;
  StopInUnresolvedUnit(Ref, Path);
  var Content := PlaceholderText(Ref);

  Assert.IsTrue(Content.Contains('Searched, in this order:'),
    'the document must list what was searched; got: ' + Content);
  Assert.IsTrue(Content.Contains(FScratch),
    'the configured sourceRoot must appear in that list; got: ' + Content);
end;

initialization
  TDUnitX.RegisterTestFixture(TUnresolvedSourceDapTests);

end.
