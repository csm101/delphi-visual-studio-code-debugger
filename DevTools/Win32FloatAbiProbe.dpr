program Win32FloatAbiProbe;

// What each float-family type actually IS, and where a function returning one
// actually leaves it.
//
// Two questions, both of which the debugger's synthetic-call return path
// depends on and neither of which should be answered from memory:
//
//   1. Which of these names are distinct types and which are aliases? Delphi's
//      float family has accumulated history -- the 6-byte software float from
//      before the 8087, an 80-bit x87 type that is 80-bit on one architecture
//      and not the other, and a scaled integer that reads as a float.
//   2. On Win32, does a result come back in EDX:EAX or on the x87 stack? The
//      adapter has to undo the wire encoding before handing a value to the
//      formatters in ExprEval, which expect the Win64 encoding. Getting it
//      wrong produces a plausible wrong number rather than an error.
//
// Question 1 is answered on BOTH architectures, so the columns can be compared;
// question 2 needs x86 asm and is skipped when built for Win64.
//
// Build:
//   DevTools\build_one32.bat Win32FloatAbiProbe.dpr   -> Win32\Debug\
//   DevTools\build_all.bat                            -> Win64\Debug\

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

type
  // 32-bit FNSAVE image: control 0, status 4, tag 8, fip 12, fcs/op 16,
  // fdp 20, fds 24, then the register area from offset 28.
  TFpuImage = array[0..107] of Byte;

const
  FPU_STATUS_OFFSET = 4;
  FPU_TAG_OFFSET    = 8;
  FPU_ST0_OFFSET    = 28;
  TAG_EMPTY         = 3;

function CalcSingle:    Single;     begin Result := 1.5;     end;
function CalcDouble:    Double;     begin Result := 3.25;    end;
function CalcExtended:  Extended;   begin Result := 2.5;     end;
function CalcReal:      Real;       begin Result := 6.75;    end;
function CalcReal48:    Real48;     begin Result := 7.5;     end;
function CalcExtended80: Extended80; begin Result := 8.25;   end;
function CalcComp:      Comp;       begin Result := 4242;    end;
function CalcDate:      TDateTime;  begin Result := 45000.5; end;
function CalcCurrency:  Currency;   begin Result := 19.95;   end;

{ ------------------------------------------------ 1. sizes and distinctness -- }

procedure ReportSizes;

  // Two names denote the same type when a var of one can be passed where the
  // other is expected -- which the compiler decides, not this program. The
  // observable proxy available at runtime is the size, so the report states
  // sizes and lets the reader draw the alias conclusion from a matching pair
  // plus the compiler's own acceptance of the assignments below.
  procedure Line(const Name: string; Size: Integer);
  begin
    Writeln(Format('  %-12s %2d bytes', [Name, Size]));
  end;

begin
  Writeln('Sizes as compiled for ', {$IFDEF CPUX86}'Win32'{$ELSE}'Win64'{$ENDIF}, ':');
  Writeln;
  Line('Single',     SizeOf(Single));
  Line('Double',     SizeOf(Double));
  Line('Real',       SizeOf(Real));
  Line('Real48',     SizeOf(Real48));
  Line('Extended',   SizeOf(Extended));
  Line('Extended80', SizeOf(Extended80));
  Line('Comp',       SizeOf(Comp));
  Line('Currency',   SizeOf(Currency));
  Line('TDateTime',  SizeOf(TDateTime));
  Writeln;

  // Assignment compatibility, checked by the compiler accepting this at all.
  var R: Real     := 1.25;
  var D: Double   := R;
  var E: Extended := D;
  Writeln(Format('  Real -> Double -> Extended round-trip: %g', [Double(E)]));
  Writeln(Format('  Real and Double same size: %s',
    [BoolToStr(SizeOf(Real) = SizeOf(Double), True)]));
  Writeln(Format('  Extended is 80-bit here:   %s',
    [BoolToStr(SizeOf(Extended) = 10, True)]));
  Writeln;
end;

{ ------------------------------------------------------ 2. Win32 return ABI -- }

{$IFDEF CPUX86}

// The 80-bit x87 register as a Double, so the reported number can be compared
// against the literal the function returned.
function St0AsDouble(const Image: TFpuImage): Double;
begin
  var Reg: array[0..9] of Byte;
  Move(Image[FPU_ST0_OFFSET], Reg[0], SizeOf(Reg));
  Result := PExtended(@Reg[0])^;
end;

// A register is empty when both its tag bits are set. The tag word is indexed
// by PHYSICAL register, so ST(0)'s tag sits at bit offset TOP*2 -- while the
// saved register AREA is in STACK order with ST(0) always first. Mixing those
// two up reads ST(7) and is the single easiest mistake to make here.
function St0IsOccupied(const Image: TFpuImage): Boolean;
begin
  var Status := PWord(@Image[FPU_STATUS_OFFSET])^;
  var Tag    := PWord(@Image[FPU_TAG_OFFSET])^;
  var Top    := (Status shr 11) and 7;
  Result := ((Tag shr (Top * 2)) and 3) <> TAG_EMPTY;
end;

procedure ReportReturn(const TypeName: string; Proc: Pointer);
var
  SavedEax, SavedEdx: Cardinal;
  Image: TFpuImage;
begin
  asm
    mov  eax, Proc
    call eax
    mov  SavedEax, eax
    mov  SavedEdx, edx
    lea  eax, Image
    fnsave [eax]        // snapshot; leaves the FPU reinitialised, i.e. stack empty
  end;
  // Deliberately NOT followed by `frstor [eax]`. By the x87 ABI the CALLER pops
  // the returned value, so restoring the callee's state would leave it on the
  // stack: nine calls in a row then overflow it, and every reading past the
  // eighth is garbage. This was observed here before it was noticed in the
  // adapter's own capture stub, which had exactly the same shape.

  var Carrier := 'EDX:EAX';
  var Shown   := Format('%d', [Int64(UInt64(SavedEdx) shl 32) or SavedEax]);
  if St0IsOccupied(Image) then begin
    Carrier := 'ST(0)  ';
    Shown   := Format('%g', [St0AsDouble(Image)]);
  end;

  Writeln(Format('  %-12s -> %s  %-22s  [eax=%.8x edx=%.8x sw=%.4x tw=%.4x]',
    [TypeName, Carrier, Shown, SavedEax, SavedEdx,
     PWord(@Image[FPU_STATUS_OFFSET])^, PWord(@Image[FPU_TAG_OFFSET])^]));
end;

procedure ReportReturnAbi;
begin
  Writeln('Win32 return ABI, as actually emitted:');
  Writeln;
  ReportReturn('Single',     @CalcSingle);
  ReportReturn('Double',     @CalcDouble);
  ReportReturn('Real',       @CalcReal);
  ReportReturn('Real48',     @CalcReal48);
  ReportReturn('Extended',   @CalcExtended);
  ReportReturn('Extended80', @CalcExtended80);
  ReportReturn('Comp',       @CalcComp);
  ReportReturn('TDateTime',  @CalcDate);
  ReportReturn('Currency',   @CalcCurrency);
  Writeln;
  Writeln('A Currency shown via ST(0) is the SCALED value if it reads 199500,');
  Writeln('and the nominal value if it reads 19.95.');
end;

{$ELSE}

procedure ReportReturnAbi;
begin
  Writeln('Return-ABI measurement needs x86 asm; skipped on this architecture.');
end;

{$ENDIF}

begin
  try
    ReportSizes;
    ReportReturnAbi;
  except
    on E: Exception do begin
      Writeln('FAILED: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
