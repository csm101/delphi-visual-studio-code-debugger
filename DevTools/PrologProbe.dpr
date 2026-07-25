program PrologProbe;

{ Prologue-shape probe.

  Purpose: establish, empirically and for BOTH bitnesses, what a Delphi
  compiler actually emits at the entry point of a routine, so that a
  byte-pattern prologue decoder can be written for Win32 (where there is no
  .pdata / UNWIND_INFO to fall back on).

  The program is deliberately standalone (no DebuggerCore dependency) so it
  dual-compiles with dcc32 and dcc64 without changes.

  It has two independent halves:

    Family A -- "shape" routines. Written naturally, never introspected, only
    their entry bytes are dumped. Nothing in them forces a stack frame that a
    real user routine of the same shape would not have, so the -$O+ columns
    are representative of real optimised user code.

    Family B -- "measure" routines. These report, at run time, the address of
    one of their own locals, the value of their return address and the address
    of each parameter. From those measurements the harness LOCATES the return
    address slot on the stack by searching for it, and then checks the
    candidate decoder's predictions against reality instead of asserting them.

  Usage:  PrologProbe.exe [-q]
            -q   quiet: omit the raw 32-byte hexdumps, print decodes only. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

const
  DumpLen = 32;

type
  TShapeInfo = record
    Name: string;
    Addr: Pointer;
  end;

  TFrameReport = record
    RoutineName: string;
    EntryAddr: Pointer;
    RetAddrValue: NativeUInt;
    AnchorLocalAddr: NativeUInt;
    SelfValue: NativeUInt;
    HasSelf: Boolean;
    ParamNames: TArray<string>;
    ParamAddrs: TArray<NativeUInt>;
    // Filled in by FinishReport, while the frame is still alive.
    RetSlots: TArray<NativeUInt>;
    SlotAboveRet: NativeUInt;   // machine word stored just past the return slot
    ScanFailed: Boolean;
  end;

var
  Sink: NativeInt;
  NestedProcAddr: Pointer;
  LastReport: TFrameReport;
  QuietMode: Boolean;

{ ==========================================================================
  Family A -- shape-only routines
  ========================================================================== }

procedure ShapeParameterless;
begin
  Inc(Sink);
end;

procedure ShapeEightIntParams(A, B, C, D, E, F, G, H: Integer);
begin
  Sink := Sink + A + B + C + D + E + F + G + H;
end;

procedure ShapeLargeLocalArray;
var
  Buffer: array[0..4095] of NativeInt;
begin
  for var I := Low(Buffer) to High(Buffer) do
    Buffer[I] := Sink + I;
  Sink := Buffer[Sink and 4095];
end;

procedure ShapeRegisterPressure(A, B, C: Integer);
begin
  var W := A * 3 + 1;
  var X := B xor $5A5A;
  var Y := C + A * B;
  var Z := A - B + C * 7;
  ShapeParameterless;                 // clobbers volatile registers
  var V := W * X;
  ShapeParameterless;
  Sink := Sink + W + X + Y + Z + V + (Y * Z);
end;

type
  TShapeClass = class
    procedure ShapeMethod(A, B: Integer);
    function ShapeStringResultMethod(A: Integer): string;
  end;

procedure TShapeClass.ShapeMethod(A, B: Integer);
begin
  Sink := Sink + A + B + NativeInt(Self);
end;

function TShapeClass.ShapeStringResultMethod(A: Integer): string;
begin
  Result := IntToStr(A + Sink + NativeInt(Self));
end;

procedure ShapeOuterWithNested(A: Integer);
var
  OuterLocal: Integer;

  procedure ShapeNestedInner(B: Integer);
  begin
    OuterLocal := OuterLocal + B + A;
    Inc(Sink, OuterLocal);
  end;

begin
  OuterLocal := A;
  NestedProcAddr := @ShapeNestedInner;
  ShapeNestedInner(A + 1);
  Sink := Sink + OuterLocal;
end;

procedure ShapeTryFinally(A: Integer);
begin
  try
    Sink := Sink + A;
  finally
    Dec(Sink);
  end;
end;

procedure ShapeTryExcept(A: Integer);
begin
  try
    Sink := Sink + A;
  except
    Inc(Sink);
  end;
end;

function ShapeStringResult(A: Integer): string;
begin
  Result := IntToStr(A + Sink);
end;

type
  TBigRecord = record
    Cells: array[0..7] of NativeInt;
  end;

function ShapeRecordResult(A: Integer): TBigRecord;
begin
  for var I := Low(Result.Cells) to High(Result.Cells) do
    Result.Cells[I] := A + I + Sink;
end;

function ShapeLeafFunction(A, B: Integer): Integer;
begin
  Result := A * B + 1;
end;

{ ==========================================================================
  Family B -- measured routines
  ========================================================================== }

procedure StartReport(const AName: string; AEntry: Pointer; ALocal: Pointer);
begin
  LastReport := Default(TFrameReport);
  LastReport.RoutineName := AName;
  LastReport.EntryAddr := AEntry;
  LastReport.AnchorLocalAddr := NativeUInt(ALocal);
end;

// MUST be called from inside the measured routine, while its frame is still
// live: once the routine returns, the reporting code reuses the same stack
// bytes and the return-address slot is gone.
//
// This is the identity predicate of the whole probe. We do not assume where the
// return address lives; we search upward from a known local for the machine
// word whose value equals it.
procedure FinishReport;
const
  MaxScanWords = 16384;
begin
  var Base := LastReport.AnchorLocalAddr and not NativeUInt(SizeOf(Pointer) - 1);
  try
    for var I := 0 to MaxScanWords - 1 do begin
      var Slot := Base + NativeUInt(I) * SizeOf(Pointer);
      if PNativeUInt(Slot)^ = LastReport.RetAddrValue then begin
        SetLength(LastReport.RetSlots, Length(LastReport.RetSlots) + 1);
        LastReport.RetSlots[High(LastReport.RetSlots)] := Slot;
        if Length(LastReport.RetSlots) = 1 then
          LastReport.SlotAboveRet := PNativeUInt(Slot + SizeOf(Pointer))^;
        if Length(LastReport.RetSlots) >= 4 then Break;
      end;
    end;
  except
    LastReport.ScanFailed := Length(LastReport.RetSlots) = 0;
  end;
end;

procedure MeasureNoParams;
var
  AnchorLocal: NativeInt;
begin
  AnchorLocal := Sink + 1;
  StartReport('MeasureNoParams', @MeasureNoParams, @AnchorLocal);
  LastReport.RetAddrValue := NativeUInt(ReturnAddress);
  FinishReport;
  Sink := Sink + AnchorLocal;
end;

procedure MeasureEightIntParams(A, B, C, D, E, F, G, H: Integer);
var
  AnchorLocal: NativeInt;
begin
  AnchorLocal := Sink + 1;
  StartReport('MeasureEightIntParams', @MeasureEightIntParams, @AnchorLocal);
  LastReport.RetAddrValue := NativeUInt(ReturnAddress);
  LastReport.ParamNames := ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
  LastReport.ParamAddrs := [NativeUInt(@A), NativeUInt(@B), NativeUInt(@C),
                            NativeUInt(@D), NativeUInt(@E), NativeUInt(@F),
                            NativeUInt(@G), NativeUInt(@H)];
  FinishReport;
  Sink := Sink + AnchorLocal + A + B + C + D + E + F + G + H;
end;

type
  TMeasureClass = class
    procedure MeasureMethod(A, B, C, D, E: Integer);
  end;

procedure TMeasureClass.MeasureMethod(A, B, C, D, E: Integer);
var
  AnchorLocal: NativeInt;
begin
  AnchorLocal := Sink + 1;
  StartReport('TMeasureClass.MeasureMethod', @TMeasureClass.MeasureMethod, @AnchorLocal);
  LastReport.RetAddrValue := NativeUInt(ReturnAddress);
  LastReport.HasSelf := True;
  LastReport.SelfValue := NativeUInt(Self);
  LastReport.ParamNames := ['A', 'B', 'C', 'D', 'E'];
  LastReport.ParamAddrs := [NativeUInt(@A), NativeUInt(@B), NativeUInt(@C),
                            NativeUInt(@D), NativeUInt(@E)];
  FinishReport;
  Sink := Sink + AnchorLocal + A + B + C + D + E;
end;

procedure MeasureBigLocals(A, B: Integer);
var
  Buffer: array[0..2047] of NativeInt;
  AnchorLocal: NativeInt;
begin
  Buffer[0] := Sink;
  Buffer[High(Buffer)] := Sink;
  AnchorLocal := Buffer[0] + 1;
  StartReport('MeasureBigLocals', @MeasureBigLocals, @AnchorLocal);
  LastReport.RetAddrValue := NativeUInt(ReturnAddress);
  LastReport.ParamNames := ['A', 'B'];
  LastReport.ParamAddrs := [NativeUInt(@A), NativeUInt(@B)];
  FinishReport;
  Sink := Sink + AnchorLocal + Buffer[High(Buffer)] + A + B;
end;

{ ==========================================================================
  Prologue decoders
  ========================================================================== }

type
  TPrologDecode = record
    Matched: Boolean;
    FrameSize: UInt32;
    ExtraPushBytes: UInt32;
    PrologLen: Integer;
    Notes: string;
  end;

function HexB(B: Byte): string;
begin
  Result := IntToHex(B, 2);
end;

function SignedStr(Value: Int64): string;
begin
  if Value >= 0 then
    Result := '+' + IntToStr(Value)
  else
    Result := IntToStr(Value);
end;

// Verbatim port of TWinDebugger.ReadPrologInfo strategy 2
// (Win64Debugger.pas, byte-pattern matcher). Kept byte-for-byte identical in
// logic so the dcc64 columns of this probe validate the shipping code.
function DecodeX64ShippingMatcher(const Bytes: array of Byte; R: Integer;
  out ExtraPushBytes: UInt32): UInt32;
begin
  Result := 0;
  ExtraPushBytes := 0;
  if R < 5 then Exit;
  if Bytes[0] <> $55 then Exit;                       // push rbp
  var Off: Integer := 1;
  while Off < R - 4 do begin
    if (Bytes[Off] >= $50) and (Bytes[Off] <= $57) then begin
      Inc(Off);
      Inc(ExtraPushBytes, 8);
    end else if (Bytes[Off] = $41) and (Bytes[Off + 1] >= $50) and (Bytes[Off + 1] <= $57) then begin
      Inc(Off, 2);
      Inc(ExtraPushBytes, 8);
    end else
      Break;
  end;
  if (Off + 3 < R) and (Bytes[Off] = $48) and (Bytes[Off + 1] = $83) and (Bytes[Off + 2] = $EC) then
    Result := Bytes[Off + 3]
  else if (Off + 6 < R) and (Bytes[Off] = $48) and (Bytes[Off + 1] = $81) and (Bytes[Off + 2] = $EC) then
    Result := PUInt32(@Bytes[Off + 3])^;
end;

// Candidate x86 decoder. Recognises the shapes a 32-bit Delphi prologue can
// take. Reports the byte length of the recognised prologue, the number of
// bytes reserved below EBP by pushes, and the explicit `sub esp` / `add esp`
// allocation, keeping them separate so the caller can see which mechanism the
// compiler chose.
function DecodeX86Candidate(const Bytes: array of Byte; R: Integer): TPrologDecode;

  function CanRead(Off, Need: Integer): Boolean;
  begin
    Result := Off + Need <= R;
  end;

  // Any mix of pushes and stack allocations, in whatever order the compiler
  // chose. `push ecx`-as-allocation and `push ebx`-as-register-save are the
  // same instruction, so both simply move the stack pointer down 4 bytes.
  //
  // Delphi's large-frame stack-probe loop, emitted instead of a single
  // `sub esp,imm32` when the frame crosses page boundaries:
  //     50                 push eax                  (save eax)
  //     B8 nn nn nn nn     mov eax, <page count>
  //  L: 81 C4 04 F0 FF FF  add esp,-0FFCh
  //     50                 push eax                  (touch the new page)
  //     48                 dec eax
  //     75 F6              jnz L
  // Net effect: eax*4096 bytes allocated, plus the 4 bytes of the initial push.
  function IsStackProbeLoop(At: Integer; out PageCount: UInt32; out Len: Integer): Boolean;
  begin
    Result := False;
    Len := 16;
    if not CanRead(At, Len) then Exit;
    if (Bytes[At] <> $50) or (Bytes[At + 1] <> $B8) then Exit;
    if (Bytes[At + 6] <> $81) or (Bytes[At + 7] <> $C4) or
       (Bytes[At + 8] <> $04) or (Bytes[At + 9] <> $F0) or
       (Bytes[At + 10] <> $FF) or (Bytes[At + 11] <> $FF) then Exit;
    if (Bytes[At + 12] <> $50) or (Bytes[At + 13] <> $48) or
       (Bytes[At + 14] <> $75) then Exit;
    PageCount := PCardinal(@Bytes[At + 2])^;
    Result := True;
  end;

begin
  Result := Default(TPrologDecode);
  if R < 3 then Exit;

  var Off := 0;
  if Bytes[0] = $C8 then begin
    // enter imm16, imm8
    if not CanRead(0, 4) then Exit;
    Result.Matched := True;
    Result.FrameSize := PWord(@Bytes[1])^;
    Result.PrologLen := 4;
    Result.Notes := 'enter ' + IntToStr(PWord(@Bytes[1])^) + ',' + IntToStr(Bytes[3]);
    Exit;
  end;

  if Bytes[0] <> $55 then begin
    Result.Notes := 'no `push ebp` at entry (first byte ' + HexB(Bytes[0]) + ')';
    Exit;
  end;
  Off := 1;
  Result.Notes := 'push ebp';

  // mov ebp,esp -- 8B EC (mod/rm form) or 89 E5 (alternate encoding)
  if CanRead(Off, 2) and (Bytes[Off] = $8B) and (Bytes[Off + 1] = $EC) then begin
    Inc(Off, 2);
    Result.Notes := Result.Notes + '; mov ebp,esp (8B EC)';
  end else if CanRead(Off, 2) and (Bytes[Off] = $89) and (Bytes[Off + 1] = $E5) then begin
    Inc(Off, 2);
    Result.Notes := Result.Notes + '; mov ebp,esp (89 E5)';
  end else begin
    Result.Notes := Result.Notes + '; NO mov ebp,esp (next ' + HexB(Bytes[Off]) + ')';
    Exit;
  end;

  Result.Matched := True;

  var Done := False;
  while (not Done) and CanRead(Off, 1) do begin
    var PageCount: UInt32;
    var ProbeLen: Integer;
    if IsStackProbeLoop(Off, PageCount, ProbeLen) then begin
      Inc(Result.ExtraPushBytes, 4);                   // the initial `push eax`
      Inc(Result.FrameSize, PageCount * 4096);
      Result.Notes := Result.Notes + '; stack-probe loop x' + IntToStr(PageCount) +
                      ' pages (' + IntToStr(PageCount * 4096) + ' bytes)';
      Inc(Off, ProbeLen);
      // The saved eax is reloaded straight afterwards: 8B 45 disp8 (mov eax,[ebp+d]).
      if CanRead(Off, 3) and (Bytes[Off] = $8B) and (Bytes[Off + 1] = $45) then begin
        Inc(Off, 3);
        Result.Notes := Result.Notes + '; mov eax,[ebp' + IntToStr(ShortInt(Bytes[Off - 1])) + ']';
      end;
      Continue;
    end;
    case Bytes[Off] of
      $50..$57: begin
        Inc(Result.ExtraPushBytes, 4);
        Result.Notes := Result.Notes + '; push r32(' + HexB(Bytes[Off]) + ')';
        Inc(Off);
      end;
      $83: begin
        if not CanRead(Off, 3) then begin Done := True; Break; end;
        if Bytes[Off + 1] = $EC then begin
          Inc(Result.FrameSize, Bytes[Off + 2]);
          Result.Notes := Result.Notes + '; sub esp,' + IntToStr(Bytes[Off + 2]);
          Inc(Off, 3);
        end else if Bytes[Off + 1] = $C4 then begin
          var Imm := ShortInt(Bytes[Off + 2]);
          Inc(Result.FrameSize, UInt32(-Imm));
          Result.Notes := Result.Notes + '; add esp,' + IntToStr(Imm);
          Inc(Off, 3);
        end else
          Done := True;
      end;
      $81: begin
        if not CanRead(Off, 6) then begin Done := True; Break; end;
        if Bytes[Off + 1] = $EC then begin
          Inc(Result.FrameSize, PUInt32(@Bytes[Off + 2])^);
          Result.Notes := Result.Notes + '; sub esp,' + IntToStr(PUInt32(@Bytes[Off + 2])^);
          Inc(Off, 6);
        end else if Bytes[Off + 1] = $C4 then begin
          var Imm32 := PInteger(@Bytes[Off + 2])^;
          Inc(Result.FrameSize, UInt32(-Imm32));
          Result.Notes := Result.Notes + '; add esp,' + IntToStr(Imm32);
          Inc(Off, 6);
        end else
          Done := True;
      end;
    else
      Done := True;
    end;
  end;
  Result.PrologLen := Off;
end;

{ ==========================================================================
  Reporting
  ========================================================================== }

procedure HexDumpEntry(const Name: string; Addr: Pointer);
begin
  if Addr = nil then begin
    Writeln(Format('%-30s <nil>', [Name]));
    Exit;
  end;
  var P := PByte(Addr);
  var Bytes: array[0..DumpLen - 1] of Byte;
  for var I := 0 to DumpLen - 1 do
    Bytes[I] := (P + I)^;

  Writeln('--- ', Name);
  Writeln('    addr  : ', IntToHex(NativeUInt(Addr), SizeOf(Pointer) * 2));
  if not QuietMode then begin
    var S := '';
    for var I := 0 to DumpLen - 1 do
      S := S + HexB(Bytes[I]) + ' ';
    Writeln('    bytes : ', TrimRight(S));
  end;

{$IFDEF CPUX64}
  var Extra: UInt32;
  var FS := DecodeX64ShippingMatcher(Bytes, DumpLen, Extra);
  if (Bytes[0] = $55) then
    Writeln(Format('    x64ship: matched=yes subRsp=%d extraPush=%d', [FS, Extra]))
  else
    Writeln(Format('    x64ship: matched=NO  (first byte %s) subRsp=%d extraPush=%d',
      [HexB(Bytes[0]), FS, Extra]));
{$ELSE}
  var D := DecodeX86Candidate(Bytes, DumpLen);
  Writeln(Format('    x86cand: matched=%s frameSize=%d extraPush=%d prologLen=%d',
    [BoolToStr(D.Matched, True), D.FrameSize, D.ExtraPushBytes, D.PrologLen]));
  Writeln('    decode : ', D.Notes);
{$ENDIF}
end;

function IfThenStr(Cond: Boolean; const A, B: string): string;
begin
  if Cond then
    Result := A
  else
    Result := B;
end;

procedure ReportMeasured(const Rep: TFrameReport);
begin
  Writeln('--- MEASURED: ', Rep.RoutineName);
  Writeln('    entry     : ', IntToHex(NativeUInt(Rep.EntryAddr), SizeOf(Pointer) * 2));
  Writeln('    retAddrVal: ', IntToHex(Rep.RetAddrValue, SizeOf(Pointer) * 2));
  Writeln('    anchorLcl : ', IntToHex(Rep.AnchorLocalAddr, SizeOf(Pointer) * 2));

  if Length(Rep.RetSlots) = 0 then begin
    Writeln('    RET SLOT  : NOT FOUND - measurement failed for this routine');
    Exit;
  end;
  var Base := Rep.AnchorLocalAddr and not NativeUInt(SizeOf(Pointer) - 1);
  for var I := 0 to High(Rep.RetSlots) do
    Writeln(Format('    retSlot[%d]: %s  (anchor + %d)',
      [I, IntToHex(Rep.RetSlots[I], SizeOf(Pointer) * 2),
       Int64(Rep.RetSlots[I]) - Int64(Base)]));

  var RetSlot := Rep.RetSlots[0];

  // Decode the prologue of this very routine and cross-check.
  var P := PByte(Rep.EntryAddr);
  var Bytes: array[0..DumpLen - 1] of Byte;
  for var I := 0 to DumpLen - 1 do
    Bytes[I] := (P + I)^;

{$IFDEF CPUX64}
  var Extra: UInt32;
  var FS := DecodeX64ShippingMatcher(Bytes, DumpLen, Extra);
  // Shipping model: RBP = RSPatEntry - 8 - extraPush - subRsp, so the return
  // address slot sits at RBP + subRsp + extraPush + 8, and the ABI home slot of
  // parameter i is at RBP + subRsp + extraPush + 16 + 8*i = retSlot + 8 + 8*i.
  var PredictedRbp := RetSlot - 8 - NativeUInt(Extra) - NativeUInt(FS);
  Writeln(Format('    decoded   : subRsp=%d extraPush=%d -> predicted RBP=%s',
    [FS, Extra, IntToHex(PredictedRbp, 16)]));
  Writeln(Format('    localInFrame: %s (anchor %s RBP, delta %d)',
    [BoolToStr(Rep.AnchorLocalAddr >= PredictedRbp, True),
     IfThenStr(Rep.AnchorLocalAddr >= PredictedRbp, '>=', '<'),
     Int64(Rep.AnchorLocalAddr) - Int64(PredictedRbp)]));
  // A local below the predicted RBP is impossible for a Delphi x64 frame
  // (RBP is set to RSP, i.e. the bottom), so it proves the decode is wrong.
  if Rep.AnchorLocalAddr < PredictedRbp then
    Writeln(Format('    *** DECODER FAILED: subRsp under-reported by at least %d bytes; ' +
      'the shipping formula RBP+subRsp+extraPush+16+8*i would miss every parameter ' +
      'home by that much when .pdata is unavailable.',
      [Int64(PredictedRbp) - Int64(Rep.AnchorLocalAddr)]));
  if Rep.HasSelf then
    Writeln(Format('    selfHome  : predicted %s -> value (captured live) %s ; actual Self %s ; MATCH=%s',
      [IntToHex(RetSlot + 8, 16), IntToHex(Rep.SlotAboveRet, 16),
       IntToHex(Rep.SelfValue, 16),
       BoolToStr(Rep.SlotAboveRet = Rep.SelfValue, True)]));
  var AbiBase := 0;
  if Rep.HasSelf then AbiBase := 1;
  for var I := 0 to High(Rep.ParamAddrs) do begin
    var Predicted := RetSlot + 8 + NativeUInt(AbiBase + I) * 8;
    Writeln(Format('    param %-2s  : actual %s  predictedHome %s  MATCH=%-5s  (actual - RBP = %d)',
      [Rep.ParamNames[I], IntToHex(Rep.ParamAddrs[I], 16), IntToHex(Predicted, 16),
       BoolToStr(Rep.ParamAddrs[I] = Predicted, True),
       Int64(Rep.ParamAddrs[I]) - Int64(PredictedRbp)]));
  end;
{$ELSE}
  var D := DecodeX86Candidate(Bytes, DumpLen);
  // x86 model under test: EBP = retSlot - 4; locals at EBP-k; stack params at
  // EBP+8+4*k. Nothing needs the frame size to reach either.
  var PredictedEbp := RetSlot - 4;
  Writeln(Format('    decoded   : matched=%s frameSize=%d extraPush=%d -> predicted EBP=%s',
    [BoolToStr(D.Matched, True), D.FrameSize, D.ExtraPushBytes, IntToHex(PredictedEbp, 8)]));
  Writeln(Format('    anchorLcl - EBP = %d  (negative => local below EBP as expected)',
    [Int64(Rep.AnchorLocalAddr) - Int64(PredictedEbp)]));
  Writeln(Format('    frameBottomPredicted = EBP - %d = %s ; anchor inside frame = %s',
    [D.FrameSize + D.ExtraPushBytes,
     IntToHex(PredictedEbp - NativeUInt(D.FrameSize) - NativeUInt(D.ExtraPushBytes), 8),
     BoolToStr(Rep.AnchorLocalAddr >= PredictedEbp - NativeUInt(D.FrameSize) - NativeUInt(D.ExtraPushBytes), True)]));
  if Rep.HasSelf then
    Writeln(Format('    Self value: %s  ; [EBP+8] (captured live) = %s ; MATCH=%s',
      [IntToHex(Rep.SelfValue, 8), IntToHex(Rep.SlotAboveRet, 8),
       BoolToStr(Rep.SlotAboveRet = Rep.SelfValue, True)]));
  for var I := 0 to High(Rep.ParamAddrs) do begin
    var Delta := Int64(Rep.ParamAddrs[I]) - Int64(PredictedEbp);
    var Kind := 'REGISTER PARAM spilled to a LOCAL slot (no stack home)';
    if Delta >= 8 then
      Kind := Format('STACK PARAM, stack-arg index %d counting from EBP+8', [(Delta - 8) div 4]);
    Writeln(Format('    param %-2s  : actual %s  EBP%s   %s',
      [Rep.ParamNames[I], IntToHex(Rep.ParamAddrs[I], 8), SignedStr(Delta), Kind]));
  end;
{$ENDIF}
end;

procedure Run;
begin
  QuietMode := FindCmdLineSwitch('q', ['-'], True);

  Writeln('PrologProbe');
{$IFDEF CPUX64}
  Writeln('  target       : Win64 (dcc64)');
{$ELSE}
  Writeln('  target       : Win32 (dcc32)');
{$ENDIF}
{$IFOPT O+}
  Writeln('  optimization : $O+  (optimizations ON)');
{$ELSE}
  Writeln('  optimization : $O-  (optimizations OFF)');
{$ENDIF}
{$IFOPT W+}
  Writeln('  stackframes  : $W+  (frames FORCED)');
{$ELSE}
  Writeln('  stackframes  : $W-  (frames NOT forced - compiler decides)');
{$ENDIF}
  Writeln('  pointer size : ', SizeOf(Pointer));
  Writeln;

  // Force every shape routine to exist and to run at least once.
  var Obj := TShapeClass.Create;
  try
    ShapeParameterless;
    ShapeEightIntParams(1, 2, 3, 4, 5, 6, 7, 8);
    ShapeLargeLocalArray;
    ShapeRegisterPressure(3, 5, 7);
    Obj.ShapeMethod(11, 13);
    Sink := Sink + Length(Obj.ShapeStringResultMethod(17));
    ShapeOuterWithNested(19);
    ShapeTryFinally(23);
    ShapeTryExcept(29);
    Sink := Sink + Length(ShapeStringResult(31));
    Sink := Sink + ShapeRecordResult(37).Cells[0];
    Sink := Sink + ShapeLeafFunction(41, 43);
  finally
    Obj.Free;
  end;

  Writeln('== FAMILY A: entry bytes of shape routines ==');
  Writeln;
  HexDumpEntry('ShapeParameterless',            @ShapeParameterless);
  HexDumpEntry('ShapeLeafFunction',             @ShapeLeafFunction);
  HexDumpEntry('ShapeEightIntParams',           @ShapeEightIntParams);
  HexDumpEntry('ShapeLargeLocalArray',          @ShapeLargeLocalArray);
  HexDumpEntry('ShapeRegisterPressure',         @ShapeRegisterPressure);
  HexDumpEntry('TShapeClass.ShapeMethod',       @TShapeClass.ShapeMethod);
  HexDumpEntry('TShapeClass.StringResultMethod',@TShapeClass.ShapeStringResultMethod);
  HexDumpEntry('ShapeOuterWithNested',          @ShapeOuterWithNested);
  HexDumpEntry('ShapeNestedInner (nested)',     NestedProcAddr);
  HexDumpEntry('ShapeTryFinally',               @ShapeTryFinally);
  HexDumpEntry('ShapeTryExcept',                @ShapeTryExcept);
  HexDumpEntry('ShapeStringResult',             @ShapeStringResult);
  HexDumpEntry('ShapeRecordResult',             @ShapeRecordResult);
  Writeln;

  Writeln('== FAMILY B: measured frames (return slot located by search) ==');
  Writeln;
  MeasureNoParams;
  ReportMeasured(LastReport);
  Writeln;

  MeasureEightIntParams(101, 102, 103, 104, 105, 106, 107, 108);
  ReportMeasured(LastReport);
  Writeln;

  var M := TMeasureClass.Create;
  try
    M.MeasureMethod(201, 202, 203, 204, 205);
  finally
    ReportMeasured(LastReport);
    M.Free;
  end;
  Writeln;

  MeasureBigLocals(301, 302);
  ReportMeasured(LastReport);
  Writeln;

  Writeln('== Entry bytes of the measured routines ==');
  Writeln;
  HexDumpEntry('MeasureNoParams',             @MeasureNoParams);
  HexDumpEntry('MeasureEightIntParams',       @MeasureEightIntParams);
  HexDumpEntry('TMeasureClass.MeasureMethod', @TMeasureClass.MeasureMethod);
  HexDumpEntry('MeasureBigLocals',            @MeasureBigLocals);

  Writeln;
  Writeln('sink=', Sink);
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('EXCEPTION: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
