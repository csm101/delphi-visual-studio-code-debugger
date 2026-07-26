program Win32FloatArgProbe;

// Where does a Win32 Delphi routine actually receive each parameter?
//
// The synthetic-call path refuses floating-point ARGUMENTS on 32-bit targets.
// Implementing them needs two facts that must be measured rather than recalled:
//
//   1. Do floating-point parameters consume one of the three `register` slots
//      (EAX/EDX/ECX), or are they always passed on the stack while the integer
//      parameters keep taking registers past them?
//   2. How much stack does each float width occupy?
//
// Method: under -$O- every parameter has a memory home, and Delphi spills the
// register three to NEGATIVE offsets from EBP while genuine stack parameters sit
// at POSITIVE ones (above the saved EBP and the return address). So the SIGN of
// `@Param - EBP` says which class a parameter belongs to, and the spacing
// between consecutive positive offsets gives the stack width.
//
// Build (32-bit only -- it reads EBP):
//   DevTools\build_one32.bat Win32FloatArgProbe.dpr
// Run:
//   DevTools\Win32\Debug\Win32FloatArgProbe.exe

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

type
  TParamReport = record
    Name:   string;
    Offset: Integer;   // signed, relative to EBP
  end;

procedure Show(const Signature: string; const Params: array of TParamReport);
begin
  Writeln(Signature);
  for var P in Params do begin
    // Delphi's Format has no '+' flag, so the sign is built by hand.
    var Sign := '+';
    if P.Offset < 0 then
      Sign := '-';
    var Where := 'stack';
    if P.Offset < 0 then
      Where := 'REGISTER (spilled)';
    Writeln(Format('    %-4s EBP%s%d   %s',
      [P.Name, Sign, Abs(P.Offset), Where]));
  end;
  Writeln;
end;

function At(const Name: string; Addr: Pointer; FrameBase: NativeUInt): TParamReport;
begin
  Result.Name   := Name;
  Result.Offset := Integer(NativeInt(Addr) - NativeInt(FrameBase));
end;

{ Baseline: five integers. The first three should be register-spilled. }
procedure AllIntegers(A, B, C, D, E: Integer);
var
  FrameBase: NativeUInt;
begin
  asm mov FrameBase, ebp end;   // NOT named Ebp: the assembler would read that as the register and emit a no-op
  Show('AllIntegers(A, B, C, D, E: Integer)',
    [At('A', @A, FrameBase), At('B', @B, FrameBase), At('C', @C, FrameBase),
     At('D', @D, FrameBase), At('E', @E, FrameBase)]);
end;

{ The decisive one: does the Double in the middle eat a register slot, or do the
  integers after it keep taking registers? }
procedure IntDoubleInt(A: Integer; B: Double; C: Integer);
var
  FrameBase: NativeUInt;
begin
  asm mov FrameBase, ebp end;   // NOT named Ebp: the assembler would read that as the register and emit a no-op
  Show('IntDoubleInt(A: Integer; B: Double; C: Integer)',
    [At('A', @A, FrameBase), At('B', @B, FrameBase), At('C', @C, FrameBase)]);
end;

{ A float first, to see whether it displaces the integers at all. }
procedure DoubleIntInt(A: Double; B, C: Integer);
var
  FrameBase: NativeUInt;
begin
  asm mov FrameBase, ebp end;   // NOT named Ebp: the assembler would read that as the register and emit a no-op
  Show('DoubleIntInt(A: Double; B, C: Integer)',
    [At('A', @A, FrameBase), At('B', @B, FrameBase), At('C', @C, FrameBase)]);
end;

{ Stack widths: consecutive positive offsets give each type's footprint. }
procedure FloatWidths(A, B, C: Integer; S: Single; D: Double; E: Extended; U: Currency);
var
  FrameBase: NativeUInt;
begin
  asm mov FrameBase, ebp end;   // NOT named Ebp: the assembler would read that as the register and emit a no-op
  Show('FloatWidths(A, B, C: Integer; S: Single; D: Double; E: Extended; U: Currency)',
    [At('A', @A, FrameBase), At('B', @B, FrameBase), At('C', @C, FrameBase),
     At('S', @S, FrameBase), At('D', @D, FrameBase), At('E', @E, FrameBase), At('U', @U, FrameBase)]);
end;

{ Four floats and nothing else: are ALL of them on the stack? }
procedure AllFloats(A, B, C, D: Double);
var
  FrameBase: NativeUInt;
begin
  asm mov FrameBase, ebp end;   // NOT named Ebp: the assembler would read that as the register and emit a no-op
  Show('AllFloats(A, B, C, D: Double)',
    [At('A', @A, FrameBase), At('B', @B, FrameBase), At('C', @C, FrameBase), At('D', @D, FrameBase)]);
end;

begin
  try
    Writeln('Win32 parameter placement under -$O-, as actually emitted.');
    Writeln('Negative EBP offset = spilled from a register; positive = passed on the stack.');
    Writeln;
    AllIntegers(1, 2, 3, 4, 5);
    IntDoubleInt(1, 2.5, 3);
    DoubleIntInt(2.5, 1, 3);
    FloatWidths(1, 2, 3, 1.5, 2.5, 3.5, 4.5);
    AllFloats(1.5, 2.5, 3.5, 4.5);
  except
    on E: Exception do begin
      Writeln('FAILED: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
