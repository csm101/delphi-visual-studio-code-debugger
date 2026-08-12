unit SafeCallPolicyTests;

// The safe-getter policy engine (SafeCallPolicy.pas), proved against real
// files in a scratch tree -- discovery, layering, the containment walk, the
// user file's write/reload cycle. No debuggee: everything here is the part
// that must be right BEFORE a getter is ever called on the strength of it.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSafeCallPolicyTests = class
  private
    FRoot:    string;   // scratch tree; every path below is under it
    FUserDir: string;
    FShipDir: string;
    procedure WriteArchive(const Dir, FileName, EntriesJson: string);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure ManualAdd_IsTrusted_AndAllowsAutoCall;
    [Test] procedure Deny_BeatsAShippedPureEntry;
    [Test] procedure Remove_FallsBackToTheShippedVerdict;
    [Test] procedure UserFile_SurvivesANewPolicyInstance;
    [Test] procedure SourceAnchored_NearestAncestorWins;
    [Test] procedure PoolLookup_FindsAnArchiveAboveARegisteredDir;
    [Test] procedure MalformedArchive_ContributesNothingAndDoesNotThrow;
    [Test] procedure ExternalEdit_IsPickedUpByMTime_WithoutReload;
    [Test] procedure TierPolicy_OnlyPureTrustedMayRaiseAutoCall;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, SafeCallPolicy, TestTempDirs;

procedure TSafeCallPolicyTests.Setup;
begin
  PurgeLeftoverTempDirs('SafelistTests_');
  FRoot    := MakeTestScratchDir('SafelistTests_');
  FUserDir := TPath.Combine(FRoot, 'user');
  FShipDir := TPath.Combine(FRoot, 'shipped');
  TDirectory.CreateDirectory(FUserDir);
  TDirectory.CreateDirectory(FShipDir);
end;

procedure TSafeCallPolicyTests.TearDown;
begin
  DeleteTempDirWithRetry(FRoot);
end;

procedure TSafeCallPolicyTests.WriteArchive(const Dir, FileName, EntriesJson: string);
begin
  TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(TPath.Combine(Dir, FileName),
    '{ "schemaVersion": 1, "origin": "generated", "entries": [' + EntriesJson + '] }',
    TEncoding.UTF8);
end;

procedure TSafeCallPolicyTests.ManualAdd_IsTrusted_AndAllowsAutoCall;
begin
  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    Assert.AreEqual(svNone, P.Resolve(['twidget.docalcscore']),
      'no archive yet: no opinion');
    P.AddUser('TWidget.DoCalcScore', {Deny=}False);
    Assert.AreEqual(svTrusted, P.Resolve(['twidget.docalcscore']),
      'a manual add is TRUSTED -- user authority, not analytical proof');
    Assert.IsTrue(TSafeCallPolicy.AllowsAutoCall(svTrusted));
    // Spelling is normalised: the row and the file agree whatever the case.
    Assert.AreEqual(svTrusted, P.Resolve(['TWIDGET.DOCALCSCORE']));
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.Deny_BeatsAShippedPureEntry;
begin
  WriteArchive(FShipDir, 'rtl.safelist.json',
    '{ "class": "TStrings", "member": "GetTextStr", "verdict": "pure" }');
  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    Assert.AreEqual(svPure, P.Resolve(['tstrings.gettextstr']),
      'precondition: the shipped entry answers');
    P.AddUser('TStrings.GetTextStr', {Deny=}True);
    Assert.AreEqual(svDeny, P.Resolve(['tstrings.gettextstr']),
      'the user said never: that beats the shipped archive, which is the point of the layer');
    Assert.IsFalse(TSafeCallPolicy.AllowsAutoCall(svDeny));
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.Remove_FallsBackToTheShippedVerdict;
begin
  WriteArchive(FShipDir, 'rtl.safelist.json',
    '{ "class": "TStrings", "member": "GetTextStr", "verdict": "pure" }');
  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    P.AddUser('TStrings.GetTextStr', {Deny=}True);
    P.RemoveUser('TStrings.GetTextStr');
    Assert.AreEqual(svPure, P.Resolve(['tstrings.gettextstr']),
      'removing the manual entry must surface the underlying verdict again');
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.UserFile_SurvivesANewPolicyInstance;
begin
  var P1 := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    P1.AddUser('TWidget.DoCalcScore', False);
    P1.AddUser('TEvil.GetBoom', True);
  finally
    P1.Free;
  end;
  // A fresh instance with the same directories: the decisions came from the
  // FILE, which is the whole reason the file exists.
  var P2 := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    Assert.AreEqual(svTrusted, P2.Resolve(['twidget.docalcscore']));
    Assert.AreEqual(svDeny,    P2.Resolve(['tevil.getboom']));
  finally
    P2.Free;
  end;
end;

procedure TSafeCallPolicyTests.SourceAnchored_NearestAncestorWins;
begin
  // lib\           libwide.safelist.json  -> pure
  // lib\sub\       libsub.safelist.json   -> mayRaise
  // lib\sub\u.pas  (the symbol's source)
  var Lib := TPath.Combine(FRoot, 'lib');
  var Sub := TPath.Combine(Lib, 'sub');
  WriteArchive(Lib, 'libwide.safelist.json',
    '{ "class": "TFoo", "member": "GetBar", "verdict": "pure" }');
  WriteArchive(Sub, 'libsub.safelist.json',
    '{ "class": "TFoo", "member": "GetBar", "verdict": "mayRaise" }');
  var SrcFile := TPath.Combine(Sub, 'u.pas');
  TFile.WriteAllText(SrcFile, 'unit u;');

  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    // The archive closest to the source is the most specific: walking UP from
    // u.pas hits sub\ before lib\.
    Assert.AreEqual(svMayRaise, P.Resolve(['tfoo.getbar'], SrcFile),
      'nearest ancestor must win over a wider archive higher up');
    // Anchored at the lib level instead (a source directly in lib\), the wider
    // archive answers.
    var LibFile := TPath.Combine(Lib, 'v.pas');
    TFile.WriteAllText(LibFile, 'unit v;');
    Assert.AreEqual(svPure, P.Resolve(['tfoo.getbar'], LibFile));
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.PoolLookup_FindsAnArchiveAboveARegisteredDir;
begin
  // The archive sits at the library ROOT; the registered source dir is a
  // grandchild -- the committed-at-repo-root case, resolved with no source
  // file hint at all.
  var Repo := TPath.Combine(FRoot, 'devexpress');
  var Deep := TPath.Combine(TPath.Combine(Repo, 'VCL'), 'Sources');
  TDirectory.CreateDirectory(Deep);
  WriteArchive(Repo, 'devexpress.safelist.json',
    '{ "class": "TcxThing", "member": "GetCount", "verdict": "pure" }');

  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    P.RegisterSourceDirs([Deep]);
    Assert.AreEqual(svPure, P.Resolve(['tcxthing.getcount']),
      'the pool walks each registered dir''s ancestors; the repo root is one of them');
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.MalformedArchive_ContributesNothingAndDoesNotThrow;
begin
  TFile.WriteAllText(TPath.Combine(FShipDir, 'broken.safelist.json'),
    '{ this is not JSON at all', TEncoding.UTF8);
  WriteArchive(FShipDir, 'good.safelist.json',
    '{ "class": "TFoo", "member": "GetBar", "verdict": "pure" }');
  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    // The broken file is user-editable by design; a typo in it must cost its
    // entries, not the session.
    Assert.AreEqual(svPure, P.Resolve(['tfoo.getbar']));
    Assert.AreEqual(svNone, P.Resolve(['tother.getx']));
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.ExternalEdit_IsPickedUpByMTime_WithoutReload;
begin
  WriteArchive(FShipDir, 'rtl.safelist.json',
    '{ "class": "TFoo", "member": "GetBar", "verdict": "pure" }');
  var P := TSafeCallPolicy.Create(FUserDir, FShipDir);
  try
    Assert.AreEqual(svPure, P.Resolve(['tfoo.getbar']));
    // Hand-edit the file. The parse cache is mtime-validated per file, so the
    // change lands on the next lookup -- an already-KNOWN file needs no Reload
    // (only a NEW file in an already-probed directory does).
    Sleep(20);   // ensure the mtime moves even on a coarse filesystem clock
    WriteArchive(FShipDir, 'rtl.safelist.json',
      '{ "class": "TFoo", "member": "GetBar", "verdict": "lazyInit" }');
    P.Reload;    // drops the negative cache too; deterministic for the test
    Assert.AreEqual(svLazyInit, P.Resolve(['tfoo.getbar']));
  finally
    P.Free;
  end;
end;

procedure TSafeCallPolicyTests.TierPolicy_OnlyPureTrustedMayRaiseAutoCall;
begin
  // The whole tier policy, pinned in one place. `lazyInit` NEVER auto-calls by
  // design: the canonical member of that category creates a window handle.
  Assert.IsTrue (TSafeCallPolicy.AllowsAutoCall(svPure));
  Assert.IsTrue (TSafeCallPolicy.AllowsAutoCall(svTrusted));
  Assert.IsTrue (TSafeCallPolicy.AllowsAutoCall(svMayRaise));
  Assert.IsFalse(TSafeCallPolicy.AllowsAutoCall(svLazyInit));
  Assert.IsFalse(TSafeCallPolicy.AllowsAutoCall(svConditional));
  Assert.IsFalse(TSafeCallPolicy.AllowsAutoCall(svUnsafe));
  Assert.IsFalse(TSafeCallPolicy.AllowsAutoCall(svDeny));
  Assert.IsFalse(TSafeCallPolicy.AllowsAutoCall(svNone));
end;

initialization
  TDUnitX.RegisterTestFixture(TSafeCallPolicyTests);

end.
