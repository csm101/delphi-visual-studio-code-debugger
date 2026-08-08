unit DisassemblerTests;

// Tests for the IDisassembler seam (DISASSEMBLY_PLAN.md increments 2 and 3).
//
// Increment 2 shipped with the negative (DLL-missing) path proven here and
// the positive (real decode) path proven only manually, via DevTools\
// Disasm.exe -- because ZydisApi.ZydisTryLoad is a ONE-SHOT, process-wide
// latch (see ZydisApi.pas): the first call in the process decided the
// outcome for the WHOLE process lifetime, so a negative-DLL test and a
// positive-decode test could never safely share RunTests.exe.
//
// Increment 3 removed that constraint at the root: ZydisApi.ZydisResetForTests
// (test-only) clears the latch, so every test below that cares about a
// specific outcome calls it FIRST, regardless of what any earlier test in the
// same process left behind. That makes the whole file order-independent --
// proven by running the suite with DUnitX's default (effectively arbitrary)
// ordering, not by controlling it.
//
// Four independent groups:
//
//   TDisassemblerBackendTests -- the "unavailable" path: Available=False,
//   Disassemble returns empty, the byte reader is never invoked at all.
//
//   TZydisPositiveDecodeTests -- the REAL decode path, both machine modes,
//   against the actual Zydis.dll and hand-picked byte sequences whose
//   correct decode was already measured and documented in increment 1
//   (DevTools\README.md's DisasmProbe entry) -- known bytes in, known
//   mnemonics out.
//
//   TCallTargetWhitelistTests -- regression guard for the bug increment 2
//   found by hand: the FIRST call-target annotator matched any
//   `<word> 0x<hex>` and mislabelled `push 0x2A` (an immediate push, same
//   text shape as a resolved branch) as a call into whatever symbol sits at
//   $2A. Fixed with a closed mnemonic whitelist in ZydisDisassembler.pas;
//   this test is the automated guard that never existed for it before.
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
    // failed attempt. Calls ZydisResetForTests first so the outcome does not
    // depend on whether a positive-decode test already ran in this process.
    [Test] procedure Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads;
  end;

  [TestFixture]
  TZydisPositiveDecodeTests = class
  public
    // Real bytes in, expected Zydis mnemonics out -- the path increment 2
    // proved only by hand (DevTools\Disasm.exe). Calls ZydisResetForTests
    // first so this passes regardless of whether the negative-DLL test
    // already ran in this process.
    [Test] procedure Long64_KnownPrologueBytes_DecodeToExpectedMnemonics;
    [Test] procedure Legacy32_KnownPrologueBytes_DecodeToExpectedMnemonics;
  end;

  [TestFixture]
  TCallTargetWhitelistTests = class
  public
    // The exact bug found by hand during increment 2: `push 0x2A` has the
    // same 'mnemonic 0x<hex>' text shape a resolved call/jmp target does.
    // With a symbol provider that answers EVERY address, an open
    // `[A-Za-z]+ 0x<hex>` match would append a fabricated "; <name>"
    // comment; the closed whitelist must not.
    [Test] procedure PushImmediate_NeverAnnotatedAsCallTarget;
  end;

  [TestFixture]
  TDisassembleBackwardTests = class
  public
    // A known 12-byte x64 prologue (push rbp/push rbx/sub rsp,0x98/mov
    // rbp,rsp) fed through DisassembleBackward with the TRUE function-start
    // VA as the boundary: forward decode from it lands EXACTLY on the
    // target, so the result must be the exact preceding instructions, most
    // recent last.
    [Test] procedure ProvenBoundary_LandsExactly_ReturnsExactPrecedingInstructions;
    // The same bytes, but TargetVA points MID-INSTRUCTION (inside the 7-byte
    // `sub rsp, 0x98`), so forward decode from the boundary overshoots it.
    // DISASSEMBLY_PLAN.md "before": this must refuse (empty result), never
    // hand back a misaligned guess.
    [Test] procedure Misalignment_DoesNotLandExactly_RefusesWithEmptyResult;
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
  Disassembler, ZydisDisassembler, ZydisApi,
  DebugInfoSet, DebugInfoTypes,
  DebugSession, DebugSessionTypes, DebugTarget;

// Shared by every fixture below that needs the real Zydis.dll: RunTests.exe
// lives at DebuggerTests\Win64\Debug\RunTests.exe, three levels below the
// repo root -- same convention TReadCodeMemoryAtTests.RepoRoot uses below,
// pulled out here once because it is bitness-independent (Zydis.dll is a
// single x64 DLL that decodes both machine modes).
function RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function RealZydisDllPath: string;
begin
  Result := RepoRoot + 'ThirdParty\Zydis\bin\x64\Zydis.dll';
end;

// Feeds bytes out of a fixed in-memory buffer, VA-addressed from BaseVA --
// what both TZydisPositiveDecodeTests and TCallTargetWhitelistTests need
// instead of a live process or a file on disk.
function MakeFixedBytesReader(BaseVA: UInt64; const Data: TBytes): TDisasmByteReader;
begin
  Result :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      var Offset := Int64(VA) - Int64(BaseVA);
      if (Offset < 0) or (Offset >= Length(Data)) then
        Exit(0);
      var Avail := Int64(Length(Data)) - Offset;
      if Avail > Size then
        Avail := Size;
      Move(Data[Offset], Buf^, Avail);
      Result := Integer(Avail);
    end;
end;

{ TDisassemblerBackendTests }

procedure TDisassemblerBackendTests.Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads;
begin
  // Order-independence: a positive-decode test earlier in this process left
  // the one-shot latch pointed at the REAL DLL. Reset it so this test's
  // outcome depends only on the bad path it passes below, not on run order.
  ZydisResetForTests;

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

{ TZydisPositiveDecodeTests }

procedure TZydisPositiveDecodeTests.Long64_KnownPrologueBytes_DecodeToExpectedMnemonics;
begin
  // Order-independence: reset the latch first so this passes whether or not
  // the negative-DLL test already ran (and poisoned Available=False) in this
  // process. Real Zydis.dll from here on.
  ZydisResetForTests;

  // The standard Delphi x64 prologue, measured byte-for-byte and text-for-text
  // in increment 1 (DevTools\README.md, DisasmProbe entry, TestTarget.exe
  // entry point): push rbp / push rbx / sub rsp,0x98 / mov rbp,rsp.
  const BaseVA = UInt64($140001000);
  var Bytes: TBytes := [$55, $53, $48, $81, $EC, $98, $00, $00, $00, $48, $8B, $EC];
  var Reader := MakeFixedBytesReader(BaseVA, Bytes);

  var Disasm: IDisassembler := TZydisDisassembler.Create(dmmLong64, Reader, nil, 0, RealZydisDllPath);
  Assert.IsTrue(Disasm.Available, 'real Zydis.dll must load: ' + Disasm.StatusText);

  var Insns := Disasm.Disassemble(BaseVA, 4);
  Assert.AreEqual<Integer>(4, Length(Insns), 'expected exactly 4 instructions from the known prologue bytes');
  Assert.IsTrue(Insns[0].Decoded, 'push rbp must decode');
  Assert.AreEqual('push rbp', Insns[0].Text);
  Assert.IsTrue(Insns[1].Decoded, 'push rbx must decode');
  Assert.AreEqual('push rbx', Insns[1].Text);
  Assert.IsTrue(Insns[2].Decoded, 'sub rsp, 0x98 must decode');
  Assert.AreEqual('sub rsp, 0x98', Insns[2].Text);
  Assert.IsTrue(Insns[3].Decoded, 'mov rbp, rsp must decode');
  Assert.AreEqual('mov rbp, rsp', Insns[3].Text);
end;

procedure TZydisPositiveDecodeTests.Legacy32_KnownPrologueBytes_DecodeToExpectedMnemonics;
begin
  ZydisResetForTests;

  // The standard Delphi x86 prologue, measured in increment 1 (same source as
  // above, TestTarget.exe Win32 entry point): push ebp / mov ebp,esp /
  // add esp,0xFFFFFFC8 / push ebx.
  const BaseVA = UInt64($00401000);
  var Bytes: TBytes := [$55, $8B, $EC, $83, $C4, $C8, $53];
  var Reader := MakeFixedBytesReader(BaseVA, Bytes);

  var Disasm: IDisassembler := TZydisDisassembler.Create(dmmLegacy32, Reader, nil, 0, RealZydisDllPath);
  Assert.IsTrue(Disasm.Available, 'real Zydis.dll must load: ' + Disasm.StatusText);

  var Insns := Disasm.Disassemble(BaseVA, 4);
  Assert.AreEqual<Integer>(4, Length(Insns), 'expected exactly 4 instructions from the known prologue bytes');
  Assert.IsTrue(Insns[0].Decoded, 'push ebp must decode');
  Assert.AreEqual('push ebp', Insns[0].Text);
  Assert.IsTrue(Insns[1].Decoded, 'mov ebp, esp must decode');
  Assert.AreEqual('mov ebp, esp', Insns[1].Text);
  Assert.IsTrue(Insns[2].Decoded, 'add esp, 0xFFFFFFC8 must decode');
  Assert.AreEqual('add esp, 0xFFFFFFC8', Insns[2].Text);
  Assert.IsTrue(Insns[3].Decoded, 'push ebx must decode');
  Assert.AreEqual('push ebx', Insns[3].Text);
end;

{ TCallTargetWhitelistTests }

type
  // Answers EVERY RVA with a fabricated name, so a whitelist regression
  // (matching a non-branch mnemonic as a resolved call target) would have
  // something to wrongly annotate WITH. A provider that only answered real
  // addresses could pass even with the bug back, if it happened not to know
  // a name at the specific address under test.
  TAlwaysSymbolProvider = class(TInterfacedObject, IFunctionNameProvider)
  public
    function RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
    function RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
    function NameToRva(const Name: string; out Rva: UInt64): Boolean;
    function GetEnclosingProcedure(const Inner: string; out Parent: string): Boolean;
    function GetEnclosingProcedureByRva(InnerRva: UInt64; out Parent: string): Boolean;
    function GetEnclosingProcedureRvaByRva(InnerRva: UInt64; out ParentRva: UInt64): Boolean;
  end;

function TAlwaysSymbolProvider.RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
begin
  Name := Format('FakeSym_%x', [Rva]);
  Result := True;
end;

function TAlwaysSymbolProvider.RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
begin
  FuncRva := Rva;   // offset 0 -- keeps SymbolAt's output simple to assert against
  Result := True;
end;

function TAlwaysSymbolProvider.NameToRva(const Name: string; out Rva: UInt64): Boolean;
begin
  Result := False;
end;

function TAlwaysSymbolProvider.GetEnclosingProcedure(const Inner: string; out Parent: string): Boolean;
begin
  Result := False;
end;

function TAlwaysSymbolProvider.GetEnclosingProcedureByRva(InnerRva: UInt64; out Parent: string): Boolean;
begin
  Result := False;
end;

function TAlwaysSymbolProvider.GetEnclosingProcedureRvaByRva(InnerRva: UInt64; out ParentRva: UInt64): Boolean;
begin
  Result := False;
end;

procedure TCallTargetWhitelistTests.PushImmediate_NeverAnnotatedAsCallTarget;
begin
  ZydisResetForTests;

  // PUSH imm8 (0x2A), sign-extended -- Zydis's own formatter prints this as
  // 'push 0x2a', the EXACT 'mnemonic 0x<hex>' shape a resolved direct
  // call/jmp/jcc target also has (DISASSEMBLY_PLAN.md "Verified in increment
  // 2"). ImageBase=0 so the instruction's own VA IS the RVA a symbol lookup
  // would use, and the fake provider below answers a name for literal
  // address $2A -- exactly the operand this instruction pushes -- so an open
  // mnemonic match has something concrete to wrongly annotate with.
  const BaseVA = UInt64($1000);
  var Bytes: TBytes := [$6A, $2A];
  var Reader := MakeFixedBytesReader(BaseVA, Bytes);

  var Symbols := TDebugInfoSet.Create;
  try
    var Fake: IFunctionNameProvider := TAlwaysSymbolProvider.Create;
    Symbols.AddProvider(Fake);

    var Disasm: IDisassembler := TZydisDisassembler.Create(dmmLong64, Reader, Symbols, 0, RealZydisDllPath);
    Assert.IsTrue(Disasm.Available, 'real Zydis.dll must load: ' + Disasm.StatusText);

    var Insns := Disasm.Disassemble(BaseVA, 1);
    Assert.AreEqual<Integer>(1, Length(Insns));
    Assert.IsTrue(Insns[0].Decoded, 'push 0x2A must decode');
    Assert.IsTrue(Insns[0].Text.StartsWith('push', True),
      'expected a push mnemonic, got: ' + Insns[0].Text);
    Assert.IsFalse(Insns[0].Text.Contains(';'),
      'a plain immediate push must NEVER be annotated as a resolved call/jmp target -- ' +
      '''push 0x2A'' has the exact ''mnemonic 0x<hex>'' shape a direct branch target does, ' +
      'and an open [A-Za-z]+ 0x<hex> match mislabelled it during increment 2 development ' +
      '(fixed with the closed control-transfer whitelist in ZydisDisassembler.pas)');
  finally
    Symbols.Free;
  end;
end;

{ TDisassembleBackwardTests }

procedure TDisassembleBackwardTests.ProvenBoundary_LandsExactly_ReturnsExactPrecedingInstructions;
begin
  ZydisResetForTests;

  // Same known x64 prologue as Long64_KnownPrologueBytes_DecodeToExpectedMnemonics:
  // push rbp(1) / push rbx(1) / sub rsp,0x98(7) / mov rbp,rsp(3) -- 12 bytes,
  // instruction boundaries at $1000/$1001/$1002/$1009/$100C.
  const BaseVA = UInt64($1000);
  var Bytes: TBytes := [$55, $53, $48, $81, $EC, $98, $00, $00, $00, $48, $8B, $EC];
  var Reader := MakeFixedBytesReader(BaseVA, Bytes);
  var Disasm: IDisassembler := TZydisDisassembler.Create(dmmLong64, Reader, nil, 0, RealZydisDllPath);
  Assert.IsTrue(Disasm.Available, 'real Zydis.dll must load: ' + Disasm.StatusText);

  // BoundaryVA = the true function start ($1000): a hand-supplied stand-in
  // for what IDebugTarget.NearestInstructionBoundaryBefore would have found.
  // This test is about DisassembleBackward's own forward-decode-and-verify
  // logic, not about boundary discovery.
  var TargetVA := BaseVA + 9;   // $1009, right after "sub rsp, 0x98" (before "mov rbp, rsp")
  var Result3 := DisassembleBackward(Disasm, BaseVA, TargetVA, 3);
  Assert.AreEqual<Integer>(3, Length(Result3), 'expected all 3 preceding instructions');
  Assert.AreEqual('push rbp', Result3[0].Text);
  Assert.AreEqual('push rbx', Result3[1].Text);
  Assert.AreEqual('sub rsp, 0x98', Result3[2].Text);
  Assert.AreEqual<UInt64>(TargetVA, Result3[2].VA + UInt64(Result3[2].Length),
    'the last returned instruction must end EXACTLY at the requested address');

  // Asking for fewer than the whole chain keeps the MOST RECENT ones (closest
  // to the target), not the earliest.
  var Result2 := DisassembleBackward(Disasm, BaseVA, TargetVA, 2);
  Assert.AreEqual<Integer>(2, Length(Result2));
  Assert.AreEqual('push rbx', Result2[0].Text);
  Assert.AreEqual('sub rsp, 0x98', Result2[1].Text);
end;

procedure TDisassembleBackwardTests.Misalignment_DoesNotLandExactly_RefusesWithEmptyResult;
begin
  ZydisResetForTests;

  const BaseVA = UInt64($1000);
  var Bytes: TBytes := [$55, $53, $48, $81, $EC, $98, $00, $00, $00, $48, $8B, $EC];
  var Reader := MakeFixedBytesReader(BaseVA, Bytes);
  var Disasm: IDisassembler := TZydisDisassembler.Create(dmmLong64, Reader, nil, 0, RealZydisDllPath);
  Assert.IsTrue(Disasm.Available, 'real Zydis.dll must load: ' + Disasm.StatusText);

  // $1003 sits in the MIDDLE of the 7-byte "sub rsp, 0x98" (which starts at
  // $1002): decoding forward from the true boundary $1000 necessarily
  // overshoots it (push rbp -> $1001, push rbx -> $1002, sub rsp,0x98 ->
  // $1009, which is already past $1003). No real instruction stream can
  // land here, so this must refuse rather than return a truncated guess.
  var TargetVA := BaseVA + 3;   // $1003
  var Result := DisassembleBackward(Disasm, BaseVA, TargetVA, 3);
  Assert.AreEqual<Integer>(0, Length(Result),
    'a forward decode that does not land EXACTLY on the target must refuse (empty), never guess');
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
  TDUnitX.RegisterTestFixture(TZydisPositiveDecodeTests);
  TDUnitX.RegisterTestFixture(TCallTargetWhitelistTests);
  TDUnitX.RegisterTestFixture(TDisassembleBackwardTests);
  TDUnitX.RegisterTestFixture(TReadCodeMemoryAtTests);
  TDUnitX.RegisterTestFixture(TReadCodeMemoryAtWin32Tests);

end.
