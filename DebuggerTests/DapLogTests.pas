unit DapLogTests;

// The diagnostic log's size cap.
//
// There WAS a cap before these tests, and it never fired once: it counted the
// bytes THIS PROCESS had written, while the file is opened for append. Every
// debug session started counting at zero on top of whatever was already on
// disk, so a cap of 256 MB per session produced a measured 1.5 GB file on an
// ordinary working machine. The cap is now a property of the FILE, checked when
// it is opened and again as it grows, and the log is rotated rather than
// silenced -- the lines just before you went looking are usually the ones that
// matter.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TDapLogTests = class
  private
    FDir:  string;
    FPath: string;
    procedure WriteLines(Count: Integer);
    function  SizeOf_(const Path: string): Int64;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure ExistingOversizeFile_IsRotatedWhenOpened;
    [Test] procedure GrowingPastTheCap_RollsOverInsteadOfGrowing;
    [Test] procedure UnderTheCap_KeepsAppendingToOneFile;
    [Test] procedure CapOfZero_DisablesRotation;
  end;

  // Where a package's .dcp is looked for. Not a log concern, but the same
  // shape of test -- a rule about paths, provable against files a test makes
  // itself, with no debuggee involved.
  [TestFixture]
  TDcpProbeTests = class
  private
    FRoot: string;
    function  Touch(const RelPath: string): string;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure BesideThePackage_IsFoundFirst;
    [Test] procedure DelphiInstalledLayout_FindsTheSiblingDcpTree;
    [Test] procedure NoDcpAnywhere_ReturnsTheBesideCandidate;
    [Test] procedure ADirectoryMerelyNamedLikeBpl_IsNotRewritten;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows, DapProtocol,
  ModuleSymbolLoader, TestTempDirs;

const
  // One megabyte, so a test writes its way past the cap in a fraction of a
  // second instead of writing 64 MB to prove the same thing.
  TEST_CAP_MB = '1';
  ONE_MB      = 1024 * 1024;

procedure TDapLogTests.Setup;
begin
  PurgeLeftoverTempDirs('DapLogTests_');
  FDir  := MakeTestScratchDir('DapLogTests_');
  FPath := TPath.Combine(FDir, 'dap_adapter.log');
  SetEnvironmentVariable('DAP_LOG_MAX_MB', TEST_CAP_MB);
  SetDapLogPath(FPath);
  SetDapLogEnabled(True);
end;

procedure TDapLogTests.TearDown;
begin
  SetDapLogEnabled(False);
  SetEnvironmentVariable('DAP_LOG_MAX_MB', nil);
  // Release the handle before deleting, and leave the shared log path as it
  // was: this unit reconfigures a process-global, and every other test in the
  // run shares it.
  SetDapLogPath(TPath.Combine(TPath.GetTempPath, 'dap_adapter.log'));
  DeleteTempDirWithRetry(FDir);
end;

function TDapLogTests.SizeOf_(const Path: string): Int64;
begin
  Result := 0;
  if not TFile.Exists(Path) then
    Exit;
  var S := TFile.Open(Path, TFileMode.fmOpen, TFileAccess.faRead, TFileShare.fsReadWrite);
  try
    Result := S.Size;
  finally
    S.Free;
  end;
end;

procedure TDapLogTests.WriteLines(Count: Integer);
begin
  // ~1 KB per line, so the line count is a readable proxy for kilobytes.
  var Filler := StringOfChar('x', 1000);
  for var I := 1 to Count do
    DapLog(Filler);
end;

// The 1.5 GB case, reproduced: a log that is ALREADY over the cap when the
// adapter starts. Counting only this process's writes let it grow forever.
procedure TDapLogTests.ExistingOversizeFile_IsRotatedWhenOpened;
begin
  SetDapLogPath('');            // release any handle before writing the file
  TFile.WriteAllBytes(FPath, TBytes(nil));
  var S := TFile.Create(FPath);
  try
    S.Size := 2 * ONE_MB;       // twice the 1 MB cap, before a single line is logged
  finally
    S.Free;
  end;
  SetDapLogPath(FPath);

  DapLog('first line of a new session');

  Assert.IsTrue(TFile.Exists(DapLogPreviousPath),
    'the oversize log should have been rotated aside, not appended to');
  Assert.IsTrue(SizeOf_(FPath) < ONE_MB,
    Format('the fresh log should start empty; it is %d bytes', [SizeOf_(FPath)]));
  Assert.IsTrue(SizeOf_(DapLogPreviousPath) >= 2 * ONE_MB,
    'the rotated file should still hold what was there before');
end;

// And the cap holds WITHIN a session: the file rolls over as it grows rather
// than either growing without bound or going silent.
procedure TDapLogTests.GrowingPastTheCap_RollsOverInsteadOfGrowing;
begin
  WriteLines(1500);   // ~1.5 MB against a 1 MB cap

  Assert.IsTrue(SizeOf_(FPath) < ONE_MB,
    Format('the live log passed the cap: %d bytes', [SizeOf_(FPath)]));
  Assert.IsTrue(TFile.Exists(DapLogPreviousPath),
    'rolling over must keep one previous generation, not delete the history');
  Assert.IsTrue(SizeOf_(FPath) > 0,
    'logging must CONTINUE after the roll-over, not stop');
  // Total on disk is bounded by two generations, which is the promise the
  // rotation makes.
  Assert.IsTrue(SizeOf_(FPath) + SizeOf_(DapLogPreviousPath) < 3 * ONE_MB,
    'two generations of a 1 MB cap must not exceed ~2 MB');
end;

// Nothing rotates until the cap is reached: a short session keeps one file.
procedure TDapLogTests.UnderTheCap_KeepsAppendingToOneFile;
begin
  WriteLines(100);    // ~100 KB, well under 1 MB

  Assert.IsTrue(SizeOf_(FPath) > 50 * 1024, 'the lines should be in the file');
  Assert.IsFalse(TFile.Exists(DapLogPreviousPath),
    'a log under the cap must not be rotated');
end;

// The escape hatch, for someone chasing a rare event who has the disk for it.
procedure TDapLogTests.CapOfZero_DisablesRotation;
begin
  SetEnvironmentVariable('DAP_LOG_MAX_MB', '0');
  SetDapLogPath(FPath);   // re-reads the cap; it is cached, not read per line
  WriteLines(1500);       // would have rotated twice at the 1 MB cap

  Assert.IsTrue(SizeOf_(FPath) > ONE_MB,
    'with the cap disabled the file must be allowed to grow');
  Assert.IsFalse(TFile.Exists(DapLogPreviousPath),
    'with the cap disabled nothing should be rotated');
end;

{ TDcpProbeTests }

procedure TDcpProbeTests.Setup;
begin
  PurgeLeftoverTempDirs('DcpProbe_');
  FRoot := MakeTestScratchDir('DcpProbe_');
end;

procedure TDcpProbeTests.TearDown;
begin
  DeleteTempDirWithRetry(FRoot);
end;

function TDcpProbeTests.Touch(const RelPath: string): string;
begin
  Result := TPath.Combine(FRoot, RelPath);
  TDirectory.CreateDirectory(ExtractFilePath(Result));
  TFile.WriteAllText(Result, 'not a real package');
end;

// A project's own output: everything in one directory.
procedure TDcpProbeTests.BesideThePackage_IsFoundFirst;
begin
  var Bpl := Touch('out\libFoo.bpl');
  var Dcp := Touch('out\libFoo.dcp');
  Assert.AreEqual(Dcp, ProbeDcpPath(Bpl));
end;

// Delphi's INSTALLED layout, which is where a real application's packages live:
// Bpl and Dcp are sibling trees under the same platform folder. Probing only
// beside the package meant the .dcp was never found for any of them -- and with
// it went every capability only the RSM format carries (a TDateTime local read
// as a bare Double, measured on Hydra2).
procedure TDcpProbeTests.DelphiInstalledLayout_FindsTheSiblingDcpTree;
begin
  var Bpl := Touch('Studio\23.0\Bpl\Win64\libFoo.bpl');
  var Dcp := Touch('Studio\23.0\Dcp\Win64\libFoo.dcp');
  Assert.AreEqual(Dcp, ProbeDcpPath(Bpl));
end;

// Nothing to find: the beside-the-package candidate comes back, so the caller's
// existing FileExists check does the refusing. Never an empty string, which a
// caller would have to special-case.
procedure TDcpProbeTests.NoDcpAnywhere_ReturnsTheBesideCandidate;
begin
  var Bpl := Touch('Studio\23.0\Bpl\Win64\libFoo.bpl');
  Assert.AreEqual(ChangeFileExt(Bpl, '.dcp'), ProbeDcpPath(Bpl));
end;

// The rewrite matches a whole path SEGMENT. A directory that merely starts with
// "bpl" is not one, and rewriting it would point at a directory that has
// nothing to do with this package.
procedure TDcpProbeTests.ADirectoryMerelyNamedLikeBpl_IsNotRewritten;
begin
  var Bpl := Touch('Studio\23.0\BplArchive\Win64\libFoo.bpl');
  Touch('Studio\23.0\DcpArchive\Win64\libFoo.dcp');
  Assert.AreEqual(ChangeFileExt(Bpl, '.dcp'), ProbeDcpPath(Bpl));
end;

initialization
  TDUnitX.RegisterTestFixture(TDapLogTests);
  TDUnitX.RegisterTestFixture(TDcpProbeTests);

end.
