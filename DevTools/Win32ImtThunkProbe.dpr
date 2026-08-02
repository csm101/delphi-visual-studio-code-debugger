program Win32ImtThunkProbe;

// Measures how dcc32 encodes the IMT ADJUSTOR THUNK, so the debugger can label
// an interface reference with the concrete class it points into on a 32-bit
// target the same way it already does on a 64-bit one.
//
// The mechanism the adapter uses (DelphiValueReaders.RecoverObjectFromInterface)
// is deliberately bounded -- three reads at addresses the reference itself
// supplies, no search:
//
//   IfacePtr -> [IfacePtr]      = the interface method table (IMT)
//            -> [IMT]           = the first method, which is the adjustor thunk
//            -> thunk's first bytes hold `-IOffset` as an immediate
//
// so `Obj = IfacePtr + immediate`. Only the x64 encodings are recognised today
// (`add rcx,imm` / `lea rcx,[rcx+imm]`), which is why a 32-bit target shows an
// interface as a bare pointer. This probe prints the bytes dcc32 actually emits
// instead of guessing at the x86 equivalents.
//
// 32-bit only: it must be COMPILED BY dcc32 to observe dcc32 output.
//   DevTools\build_one32.bat Win32ImtThunkProbe.dpr
//   DevTools\Win32\Debug\Win32ImtThunkProbe.exe
//
// Several shapes are emitted on purpose, because the immediate's width and the
// instruction chosen both depend on how far into the object the interface sits:
// a class with one interface and no fields has IOffset = 4, while padding the
// class out forces a large offset.

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

type
  IProbeOne = interface
    ['{0B3A9E10-0001-4E4E-9F2A-6C1B7D2A0001}']
    procedure DoIt;
  end;

  IProbeTwo = interface
    ['{0B3A9E10-0002-4E4E-9F2A-6C1B7D2A0002}']
    procedure DoIt2;
  end;

  // IOffset small: the interface table sits right after the object header.
  TSmallOffset = class(TInterfacedObject, IProbeOne)
  public
    procedure DoIt;
  end;

  // TWO interfaces, so the second one's IOffset is one pointer further in.
  TTwoInterfaces = class(TInterfacedObject, IProbeOne, IProbeTwo)
  public
    procedure DoIt;
    procedure DoIt2;
  end;

  // A large field block in front pushes the interface far into the instance,
  // which is what forces a 32-bit immediate rather than an 8-bit one.
  TLargeOffset = class(TInterfacedObject, IProbeOne)
  private
    FPad: array[0..300] of Byte;
  public
    procedure DoIt;
  end;

procedure TSmallOffset.DoIt;   begin end;
procedure TTwoInterfaces.DoIt; begin end;
procedure TTwoInterfaces.DoIt2;begin end;
procedure TLargeOffset.DoIt;   begin end;

function HexBytes(P: PByte; Count: Integer): string;
begin
  Result := '';
  for var I := 0 to Count - 1 do
    Result := Result + IntToHex(P[I], 2) + ' ';
  Result := Trim(Result);
end;

// Walks exactly the chain the adapter walks, and reports each link so a broken
// assumption is visible at the step where it breaks rather than at the end.
procedure Report(const Caption: string; const Intf: IInterface; Obj: TObject);
begin
  Writeln('--- ', Caption, ' ---');
  var IfacePtr := NativeUInt(Pointer(Intf));
  var ObjAddr  := NativeUInt(Pointer(Obj));
  Writeln(Format('  object    = $%.8x  (%s, InstanceSize=%d)',
    [ObjAddr, Obj.ClassName, Obj.InstanceSize]));
  Writeln(Format('  interface = $%.8x', [IfacePtr]));
  if IfacePtr = 0 then begin
    Writeln('  (nil reference)');
    Exit;
  end;
  Writeln(Format('  IOffset   = %d  (interface - object)', [IfacePtr - ObjAddr]));

  var Imt := PNativeUInt(IfacePtr)^;
  Writeln(Format('  IMT       = $%.8x', [Imt]));
  if Imt = 0 then
    Exit;
  var M0 := PNativeUInt(Imt)^;
  Writeln(Format('  method[0] = $%.8x', [M0]));
  if M0 = 0 then
    Exit;
  Writeln('  thunk     = ', HexBytes(PByte(M0), 16));
  Writeln('  expected  : an instruction adding -IOffset (', -Integer(IfacePtr - ObjAddr),
          ') to the Self register, then a jump to the real method');
end;

begin
  Writeln('dcc32 IMT adjustor thunk encodings');
  Writeln('pointer size = ', SizeOf(Pointer));
  Writeln;

  var A := TSmallOffset.Create;
  Report('one interface, no fields', IProbeOne(A), A);
  Writeln;

  var B := TTwoInterfaces.Create;
  Report('two interfaces, first', IProbeOne(B), B);
  Report('two interfaces, second', IProbeTwo(B), B);
  Writeln;

  var C := TLargeOffset.Create;
  Report('one interface, 301 bytes of fields', IProbeOne(C), C);
  Writeln;

  Writeln('done.');
end.
