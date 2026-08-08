unit DisassemblerTests;

// Tests for the IDisassembler seam (DISASSEMBLY_PLAN.md increment 2).
//
// Two independent groups, deliberately kept apart:
//
//   TDisassemblerBackendTests -- the "unavailable" path, which needs NO copy
//   of Zydis.dll anywhere. This is the path every user without the VC++
//   runtime hits, and it is the only Zydis-related coverage that belongs in
//   this suite: ZydisApi.ZydisTryLoad is a ONE-SHOT, process-wide latch (see
//   ZydisApi.pas) -- the first call in the process decides the outcome for
//   its whole lifetime. A test that deliberately points it at a missing DLL
//   would poison every later test in the same process that wanted a REAL
//   decode, so this suite does not attempt one; DevTools\Disasm.exe is where
//   the positive (DLL-present) path is exercised, against real binaries, with
//   real symbolication (see DevTools\README.md).
//
//   TReadCodeMemoryAtTests / TReadCodeMemoryAtWin32Tests -- prove trap 1 at
//   the ENGINE level (IDebugTarget.ReadCodeMemoryAt), independent of Zydis
//   entirely: a planted breakpoint the debugger itself owns must read back as
//   the original opcode, not the $CC it actually wrote. This is what
//   ZydisDisassembler's byte reader is fed in a live session, so proving the
//   engine primitive is correct proves the fix it depends on.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TDisassemblerBackendTests = class
  public
    // The DLL-missing case: Available must be False, StatusText must explain
    // why, Disassemble must return an EMPTY array (never fabricate a `db`
    // stream by reading memory anyway), and the byte reader must never be
    // invoked at all -- fail closed BEFORE touching memory, not after a
    // failed attempt.
    [Test] procedure Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads;
  end;

  [TestFixture]
  TReadCodeMemoryAtTests = class
  private
    function RepoRoot: string;
    function TargetDir: string;
    function TargetExe: string;
    function TargetMap: string;
    function TargetRsm: string;
  public
    // Two breakpoints on consecutive lines of the same routine; stop at the
    // FIRST. The SECOND has not fired yet, so it is still a live planted
    // INT3 while we are stopped -- raw process memory there must show $CC,
    // and ReadCodeMemoryAt (what a live disassembly is fed) must show the
    // real opcode Zydis would need to decode correctly.
    [Test] procedure ReadCodeMemoryAt_RestoresAnotherStillPlantedBreakpoint;
  end;

  [TestFixture]
  TReadCodeMemoryAtWin32Tests = class
  private
    function RepoRoot: string;
    function TargetDir: string;
    function TargetExe: string;
    function TargetMap: string;
    function TargetRsm: string;
  public
    [Test] procedure ReadCodeMemoryAt_RestoresAnotherStillPlantedBreakpoint;
  end;

implementation

uses
  System.SysUtils, System.Classes, Winapi.Windows,
  Disassembler, ZydisDisassembler,
  DebugSession, DebugSessionTypes, DebugTarget;

{ TDisassemblerBackendTests }

procedure TDisassemblerBackendTests.Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads;
begin
  var ReaderCalled := False;
  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      ReaderCalled := True;
      Result := 0;
    end;

  // A path guaranteed not to exist, so the outcome does not depend on what
  // happens to be sitting next to RunTests.exe or on PATH.
  var Disasm: IDisassembler := TZydisDisassembler.Create(dmmLong64, Reader, nil, 0,
    'X:\does-not-exist\DisassemblerTests\NotReallyZydis.dll');

  Assert.IsFalse(Disasm.Available, 'a missing DLL must report Available=False');
  Assert.IsTrue(Disasm.StatusText <> '', 'StatusText must explain why, never be empty');

  var Insns := Disasm.Disassemble($1000, 5);
  Assert.AreEqual<Integer>(0, Length(Insns),
    'Disassemble must return an EMPTY array when unavailable, never a guessed decode');
  Assert.IsFalse(ReaderCalled,
    'the byte reader must never be invoked when the backend is unavailable -- ' +
    'fail closed before touching memory, not fail after an attempt');
end;

{ shared marker/path helpers -- duplicated (not shared) deliberately: each
  fixture below targets a different bitness's TestTarget.exe, and this keeps
  every helper trivially inspectable without reaching into DebugSessionTests.pas. }

function MarkerLineInSource(const SourcePath, Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

const
  EVAL_SOURCE = 'TestTargetCore.pas';
  EVAL_MARKER = 'EVAL_BODY';

procedure RunBothBreakpointsAndAssertTrap1(const ExePath, MapPath, RsmPath,
  SourceRoot: string);
begin
  var SourcePath := IncludeTrailingPathDelimiter(SourceRoot) + EVAL_SOURCE;
  var Line1 := MarkerLineInSource(SourcePath, EVAL_MARKER);
  Assert.IsTrue(Line1 > 0, 'marker not found: ' + EVAL_MARKER);
  // The very next source line in the same routine (GSink.Use(...) that keeps
  // the free functions linked) -- it has not executed yet when Line1 stops,
  // so its breakpoint is still armed.
  var Line2 := Line1 + 1;

  var Session := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath     := ExePath;
    Opts.MapPath     := MapPath;
    Opts.RsmPath     := RsmPath;
    Opts.SourceRoot  := SourceRoot;
    Opts.StopAtEntry := False;
    Assert.IsTrue(Session.Launch(Opts), 'Launch returned False');

    var Spec1 := Default(TBpLineSpec); Spec1.Line := Line1;
    var Spec2 := Default(TBpLineSpec); Spec2.Line := Line2;
    Session.SetBreakpoints(EVAL_SOURCE, [Spec1, Spec2]);

    var Deadline := GetTickCount64 + 60000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at either breakpoint');

    var FnName, SrcFile: string;
    var StopLine: Integer;
    Assert.IsTrue(Session.GetCurrentLocation(FnName, SrcFile, StopLine), 'no current location');
    Assert.AreEqual(Line1, StopLine,
      'expected to stop at the FIRST breakpoint -- fixture assumption (Line2 ' +
      'executes strictly after Line1 in the same routine) broke');

    var Rva: UInt64;
    Assert.IsTrue(Session.DebugInfo.SourceLineToRva(EVAL_SOURCE, Line2, Rva),
      'no RVA for the second breakpoint''s line -- fixture assumption broke');
    var VA2 := Session.Debugger.RvaToVA(Rva);

    var RawByte: Byte := 0;
    Assert.IsTrue(Session.Debugger.ReadProcessMemoryAt(VA2, @RawByte, 1),
      'raw read at the second breakpoint failed');
    Assert.AreEqual(Byte($CC), RawByte,
      'the SECOND breakpoint must still be a planted INT3 in raw process memory ' +
      'while stopped at the first one');

    var FixedByte: Byte := 0;
    var N := Session.Debugger.ReadCodeMemoryAt(VA2, @FixedByte, 1);
    Assert.AreEqual(NativeUInt(1), N, 'ReadCodeMemoryAt must return exactly 1 byte here');
    Assert.AreNotEqual(Byte($CC), FixedByte,
      'ReadCodeMemoryAt must restore the ORIGINAL opcode, not the planted INT3 -- ' +
      'a disassembly fed this memory would otherwise show `int3` where the ' +
      'user''s own code is (DISASSEMBLY_PLAN.md trap 1)');
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

{ TReadCodeMemoryAtTests (x64) }

function TReadCodeMemoryAtTests.RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TReadCodeMemoryAtTests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function TReadCodeMemoryAtTests.TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

function TReadCodeMemoryAtTests.TargetMap: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

function TReadCodeMemoryAtTests.TargetRsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

procedure TReadCodeMemoryAtTests.ReadCodeMemoryAt_RestoresAnotherStillPlantedBreakpoint;
begin
  RunBothBreakpointsAndAssertTrap1(TargetExe, TargetMap, TargetRsm, TargetDir);
end;

{ TReadCodeMemoryAtWin32Tests (x86) }

function TReadCodeMemoryAtWin32Tests.RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TReadCodeMemoryAtWin32Tests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function TReadCodeMemoryAtWin32Tests.TargetExe: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.exe';
end;

function TReadCodeMemoryAtWin32Tests.TargetMap: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.map';
end;

function TReadCodeMemoryAtWin32Tests.TargetRsm: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.rsm';
end;

procedure TReadCodeMemoryAtWin32Tests.ReadCodeMemoryAt_RestoresAnotherStillPlantedBreakpoint;
begin
  Assert.IsTrue(FileExists(TargetExe),
    '32-bit target missing -- build_target.bat should have produced ' + TargetExe);
  RunBothBreakpointsAndAssertTrap1(TargetExe, TargetMap, TargetRsm, TargetDir);
end;

initialization
  TDUnitX.RegisterTestFixture(TDisassemblerBackendTests);
  TDUnitX.RegisterTestFixture(TReadCodeMemoryAtTests);
  TDUnitX.RegisterTestFixture(TReadCodeMemoryAtWin32Tests);

end.
