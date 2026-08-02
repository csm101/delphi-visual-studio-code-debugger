unit DelphiValueReaders;

// Leaf value readers / formatters extracted from DapServer.pas. These depend
// only on an IDebugTarget (for ReadProcessMemory) and, for interface-reference
// recovery, a TDelphiRtti -- never on the DAP server state. Keeping them here
// shrinks the DapServer god-class and makes the readers reusable + testable.
//
// What stays in DapServer: FormatLocalValue / FormatTyped / FormatLocalType
// (they drive the variables view and depend on more server context) and
// SlotSizeAt (needs the current frame's locals). Those call into this unit.

interface

uses
  System.SysUtils, System.Classes, System.Math,
  Winapi.Windows,
  DebugTarget, DelphiRtti, DebugInfoTypes, DebugInfoSet;

// Number of meaningful bytes to read from a value's slot in the TARGET.
// Narrow primitives leave the upper bytes of a UInt64 destination untouched,
// so without this a 4-byte Integer folds stack garbage into an Int64 display;
// and everything pointer-shaped is 4 bytes wide on a 32-bit target, where
// reading 8 splices the neighbouring slot into the high half.
function LocalReadSize(const TypeName: string; PointerSize: Integer): Integer;

type
  // How a caller reads Size bytes of target memory into Dest. Every read site
  // already has a method of exactly this shape, so ReadValueSlotRaw below can be
  // shared without any of them knowing about the others.
  TSlotReader = reference to function(Addr: UInt64; Dest: Pointer;
    Size: Integer): Boolean;

// Byte width of the float types whose representation in the TARGET does not fit
// the 8-byte RawValue slot every formatter decodes from -- or 0 for every other
// type, which LocalReadSize handles. Measured with DevTools\Win32FloatAbiProbe,
// both columns:
//
//   Extended     10 bytes on Win32; 8 on Win64, where it truly aliases Double
//   Extended80   10 bytes on BOTH architectures
//   Real48        6 bytes on both -- the pre-8087 Borland software float
function WideFloatByteSize(const TypeName: string; PointerSize: Integer): Integer;

// Converts an x87 80-bit extended to the bit pattern of the nearest Double,
// which is the encoding the value formatters expect. Precision beyond a Double
// is lost; that is the price of the 8-byte slot, and it beats the alternative by
// a wide margin -- reading 8 of the 10 bytes keeps the MANTISSA and discards the
// EXPONENT, which reported an Extended holding 2.75 as -1.7E-77.
function ExtendedBytesToDoubleBits(const Bytes: array of Byte): UInt64;

// Same, for the 6-byte Real48: 8-bit exponent (bias 129), 39-bit fraction,
// 1 sign bit, with the exponent in the LOWEST byte. Layout follows the RTL's
// own _Real2Ext (System.pas), not a reconstruction.
function Real48BytesToDoubleBits(const Bytes: array of Byte): UInt64;

// Reads one value slot into the 8-byte RawValue the formatters decode from,
// narrowing the wide float types on the way. Use this rather than calling
// LocalReadSize and reading into a UInt64 directly: that pattern silently
// truncates any type WideFloatByteSize knows about.
function ReadValueSlotRaw(const Read: TSlotReader; Addr: UInt64;
  const TypeName: string; PointerSize: Integer; out Raw: UInt64): Boolean;

// The WRITE direction of the two conversions above: build the target's own
// representation from a Double. Writing 8 bytes of IEEE double into a 10-byte
// x87 slot is not a rounding error -- it leaves the top two bytes, the sign and
// exponent, holding whatever the variable contained before.
procedure DoubleToExtendedBytes(Value: Double; out Bytes: array of Byte);
procedure DoubleToReal48Bytes(Value: Double; out Bytes: array of Byte);

// True when a type's Delphi TTypeKind makes it a candidate for the
// structured-value formatting path (class / record / interface).
function IsExpandableTKind(K: Byte): Boolean;

// Delphi VType constants (subset). See System.Variants.pas. Public so the
// VarArray element formatter in DapServer can share them.
const
  varEmpty    = $0000;
  varNull     = $0001;
  varSmallint = $0002;
  varInteger  = $0003;
  varSingle   = $0004;
  varDouble   = $0005;
  varCurrency = $0006;
  varDate     = $0007;
  varOleStr   = $0008;
  varDispatch = $0009;
  varError    = $000A;
  varBoolean  = $000B;
  varVariant  = $000C;
  varUnknown  = $000D;
  varShortInt = $0010;
  varByte     = $0011;
  varWord     = $0012;
  varLongWord = $0013;
  varInt64    = $0014;
  varUInt64   = $0015;
  varString   = $0100;  // AnsiString
  varUString  = $0102;  // UnicodeString
  varTypeMask = $0FFF;
  varArray    = $2000;  // OR'd in for VarArray Variants
  varByRef    = $4000;  // OR'd in for pointer-to-Variant

// Format a floating-point value in fixed notation when its magnitude is in a
// human-readable range, otherwise switch to scientific. Trailing zeros and
// dangling decimal points are trimmed.
function FormatFloatNicely(V: Extended): string;

// Format a Delphi TDateTime / TDate / TTime value as the genuine date+time it
// represents, independent of the underlying Double encoding.
function FormatDelphiDateTime(V: Double): string;

// Render a byte buffer as "XX(c) XX(c) ..." (RawByteString display).
function FormatHexAscii(const Bytes: TBytes): string;

type
  TDelphiValueReader = class
  public
    // Set by the owner as they become available. Rtti may stay nil early.
    Debugger:  IDebugTarget;
    Rtti:      TDelphiRtti;
    DebugInfo: TDebugInfoSet;   // type kind / enum / size lookups (formatting)

    constructor Create(ADebugInfo: TDebugInfoSet; ADebugger: IDebugTarget;
      ARtti: TDelphiRtti);

    // Top-level local value / type formatting (variables view + watch).
    function FormatLocalValue(const V: TLocalValue): string;
    function FormatLocalType(const V: TLocalValue): string;

    // Delphi long-string readers given a pointer to the character buffer.
    function ReadDelphiUnicodeString(Ptr: UInt64; out S: string): Boolean;
    // WideString is a COM BSTR, not a Delphi long string: the 4 bytes below the
    // data are a length in BYTES, where UnicodeString's are a length in
    // ELEMENTS. Reading one with the other's rule returns twice the characters.
    function ReadDelphiWideString(Ptr: UInt64; out S: string): Boolean;
    function ReadUtf16Prefixed(Ptr: UInt64; LengthIsBytes: Boolean;
               out S: string): Boolean;
    function ReadDelphiAnsiString(Ptr: UInt64; out S: string): Boolean;
    function ReadDelphiAnsiBytes(Ptr: UInt64; out Bytes: TBytes): Boolean;
    // Encoding recorded in the string's own header (TStrRec.codePage, a Word at
    // Ptr-12) -- NOT the machine's system ANSI code page. Caller must Free the
    // result when it is not a standard singleton (TEncoding.IsStandardEncoding).
    function AnsiEncodingFor(Ptr: UInt64): TEncoding;
    // C-style null-terminated readers.
    function ReadNullTerminatedAnsi(Ptr: UInt64; out S: string): Boolean;
    function ReadNullTerminatedUtf16(Ptr: UInt64; out S: string): Boolean;

    // Decode a Delphi TVarData at Address into a display string.
    function FormatVariantAt(Address: UInt64): string;
    // Decode a set value into `[a, b, ...]`, reading the WHOLE storage width
    // (a Delphi set is 1..32 bytes, one bit per member) instead of only the
    // low 8 bytes. Bytes come from Address when the set is wider than the
    // RawValue register can hold, else from RawValue. Single home for set
    // decoding so the formatter, field reads and returns cannot disagree.
    function DecodeSetMembers(RawValue, Address: UInt64; ByteWidth: Integer;
      const Names: TArray<string>; MinValue: Integer): string;
    // Heuristic: does memory at Address look like a meaningful TVarData?
    function LooksLikeVariantAt(Address: UInt64): Boolean;

    // Recover the implementing object from a Delphi interface reference via the
    // IMT adjustor thunk. Returns 0 when the slot is not a resolvable interface.
    function RecoverObjectFromInterface(IfacePtr: UInt64): UInt64;
  private
    // Stack-slot byte size of the local at Address (gap to the next-higher
    // RbpOffset in the current frame). Used by the Variant auto-recovery in
    // FormatLocalValue. Needs the stopped frame's locals via Debugger.
    function SlotSizeAt(Address: UInt64): Cardinal;
  end;

implementation

uses
  System.DateUtils, DapProtocol;

function LocalReadSize(const TypeName: string; PointerSize: Integer): Integer;
begin
  if (TypeName = 'Byte') or (TypeName = 'ShortInt') or
     (TypeName = 'AnsiChar') or (TypeName = 'UTF8Char') or
     (TypeName = 'Boolean') or (TypeName = 'ByteBool') then
    Exit(1);
  if (TypeName = 'Word') or (TypeName = 'SmallInt') or
     (TypeName = 'WideChar') or (TypeName = 'Char') or
     (TypeName = 'UCS2Char') or (TypeName = 'WordBool') then
    Exit(2);
  if (TypeName = 'Integer') or (TypeName = 'Cardinal') or
     (TypeName = 'LongInt') or (TypeName = 'LongWord') or
     (TypeName = 'FixedInt') or (TypeName = 'FixedUInt') or
     (TypeName = 'Int32') or (TypeName = 'UInt32') or
     (TypeName = 'Single') or (TypeName = 'HRESULT') or
     (TypeName = 'LongBool') then
    Exit(4);
  // tkInt64 and tkFloat are genuinely 8 bytes on both architectures. `Extended`
  // is the exception and is listed here only for the Win64 case where it truly
  // aliases Double -- on Win32 it is 10 bytes and never reaches this function,
  // because ReadValueSlotRaw diverts it via WideFloatByteSize first.
  if (TypeName = 'Int64') or (TypeName = 'UInt64') or (TypeName = 'QWord') or
     (TypeName = 'Double') or (TypeName = 'Currency') or (TypeName = 'Comp') or
     (TypeName = 'TDateTime') or (TypeName = 'TDate') or (TypeName = 'TTime') or
     (TypeName = 'Extended') or (TypeName = 'Real') then
    Exit(8);
  // Everything else that reaches here -- class, interface, string, dynamic
  // array, record address, Variant address, pointer, and any type we could not
  // identify -- occupies one POINTER-SIZED slot in the target, which is 4 bytes
  // on a 32-bit target. Reading 8 there splices the neighbouring slot into the
  // high half and produces a plausible wrong value rather than an error.
  Result := PointerSize;
end;

function WideFloatByteSize(const TypeName: string; PointerSize: Integer): Integer;
begin
  if SameText(TypeName, 'Real48') then
    Exit(6);
  if SameText(TypeName, 'Extended80') then
    Exit(10);
  // `Extended` is the only one whose width depends on the target: 10 bytes of
  // x87 on Win32, a plain Double on Win64.
  if SameText(TypeName, 'Extended') and (PointerSize = 4) then
    Exit(10);
  Result := 0;
end;

// The 80-bit layout is sign(1) | exponent(15, bias 16383) | mantissa(64, with an
// EXPLICIT leading integer bit). A Double is sign(1) | exponent(11, bias 1023) |
// mantissa(52, leading bit implicit), so the conversion re-biases the exponent
// and drops both the explicit integer bit and the 11 lowest mantissa bits.
function ExtendedBytesToDoubleBits(const Bytes: array of Byte): UInt64;
begin
  var Mantissa: UInt64 := PUInt64(@Bytes[0])^;
  var SignExp:  Word   := PWord(@Bytes[8])^;
  var Sign:     UInt64 := UInt64(SignExp shr 15) shl 63;
  var Exp80:    Integer := SignExp and $7FFF;

  if (Exp80 = 0) and (Mantissa = 0) then
    Exit(Sign);                        // +/- zero
  if Exp80 = $7FFF then                // infinity or NaN
    Exit(Sign or (UInt64($7FF) shl 52) or (Mantissa shr 11) and ((UInt64(1) shl 52) - 1));

  var Exp64 := Exp80 - 16383 + 1023;
  if Exp64 <= 0 then
    Exit(Sign);                        // underflows a Double: report zero
  if Exp64 >= $7FF then
    Exit(Sign or (UInt64($7FF) shl 52));  // overflows: report infinity

  // Drop the explicit integer bit (bit 63) and keep the next 52.
  var Frac := (Mantissa shr 11) and ((UInt64(1) shl 52) - 1);
  Result := Sign or (UInt64(Exp64) shl 52) or Frac;
end;

function Real48BytesToDoubleBits(const Bytes: array of Byte): UInt64;
const
  REAL48_BIAS = 129;
  DOUBLE_BIAS = 1023;
begin
  // A zero exponent means the whole number is zero, sign included.
  if Bytes[0] = 0 then
    Exit(0);
  var Sign:     UInt64 := (UInt64(Bytes[5]) and $80) shl 56;
  var Exponent: UInt64 := (UInt64(Bytes[0]) + DOUBLE_BIAS - REAL48_BIAS) shl 52;
  var Fraction: UInt64 :=
    ((UInt64(Bytes[5]) and $7F) shl 32) or
    (UInt64(Bytes[4]) shl 24) or
    (UInt64(Bytes[3]) shl 16) or
    (UInt64(Bytes[2]) shl 8)  or
     UInt64(Bytes[1]);
  Result := Sign or Exponent or (Fraction shl 13);
end;

// Inverse of ExtendedBytesToDoubleBits. The host is a 64-bit binary where
// `Extended` IS `Double`, so the 80-bit pattern has to be built by hand rather
// than by letting the FPU widen it.
procedure DoubleToExtendedBytes(Value: Double; out Bytes: array of Byte);
begin
  FillChar(Bytes[0], 10, 0);
  var Bits: UInt64 := PUInt64(@Value)^;
  var Sign: Word   := Word(Bits shr 63) shl 15;
  var Exp64        := Integer((Bits shr 52) and $7FF);
  var Frac: UInt64 := Bits and ((UInt64(1) shl 52) - 1);

  if (Exp64 = 0) and (Frac = 0) then begin
    PWord(@Bytes[8])^ := Sign;               // +/- zero
    Exit;
  end;
  if Exp64 = $7FF then begin                 // infinity or NaN
    PUInt64(@Bytes[0])^ := (UInt64(1) shl 63) or (Frac shl 11);
    PWord(@Bytes[8])^   := Sign or $7FFF;
    Exit;
  end;
  // A Double denormal is below the smallest normal Extended this builds; report
  // signed zero rather than a wrong magnitude.
  if Exp64 = 0 then begin
    PWord(@Bytes[8])^ := Sign;
    Exit;
  end;
  // Restore the integer bit the Double leaves implicit, and re-bias.
  PUInt64(@Bytes[0])^ := (UInt64(1) shl 63) or (Frac shl 11);
  PWord(@Bytes[8])^   := Sign or Word(Exp64 - 1023 + 16383);
end;

// Inverse of Real48BytesToDoubleBits. Real48's exponent is 8 bits biased by 129,
// so its range is far narrower than a Double's: anything outside it becomes zero
// or the largest representable value rather than a wrapped-around bit pattern.
procedure DoubleToReal48Bytes(Value: Double; out Bytes: array of Byte);
const
  REAL48_BIAS = 129;
  DOUBLE_BIAS = 1023;
begin
  FillChar(Bytes[0], 6, 0);
  var Bits: UInt64 := PUInt64(@Value)^;
  var Exp64        := Integer((Bits shr 52) and $7FF);
  var Frac: UInt64 := Bits and ((UInt64(1) shl 52) - 1);
  if (Exp64 = 0) or (Exp64 = $7FF) then
    Exit;                                    // zero, denormal, infinity or NaN

  var Exp48 := Exp64 - DOUBLE_BIAS + REAL48_BIAS;
  if Exp48 <= 0 then
    Exit;                                    // underflows Real48: zero
  if Exp48 > 255 then
    Exp48 := 255;                            // saturate rather than wrap

  var Fraction39: UInt64 := Frac shr 13;     // 52 significant bits -> 39
  Bytes[0] := Byte(Exp48);
  Bytes[1] := Byte(Fraction39);
  Bytes[2] := Byte(Fraction39 shr 8);
  Bytes[3] := Byte(Fraction39 shr 16);
  Bytes[4] := Byte(Fraction39 shr 24);
  Bytes[5] := Byte(((Fraction39 shr 32) and $7F) or (Byte(Bits shr 63) shl 7));
end;

function ReadValueSlotRaw(const Read: TSlotReader; Addr: UInt64;
  const TypeName: string; PointerSize: Integer; out Raw: UInt64): Boolean;
begin
  Raw := 0;
  var Wide := WideFloatByteSize(TypeName, PointerSize);
  if Wide = 0 then
    Exit(Read(Addr, @Raw, LocalReadSize(TypeName, PointerSize)));

  var Bytes: array[0..9] of Byte;
  FillChar(Bytes, SizeOf(Bytes), 0);
  if not Read(Addr, @Bytes[0], Wide) then
    Exit(False);
  if Wide = 6 then
    Raw := Real48BytesToDoubleBits(Bytes)
  else
    Raw := ExtendedBytesToDoubleBits(Bytes);
  Result := True;
end;

function FormatFloatNicely(V: Extended): string;
var
  FS: TFormatSettings;
begin
  if V = 0 then
    Exit('0');
  // Always emit with '.' as decimal separator (locale-independent),
  // so DAP consumers don't have to parse locale-formatted floats.
  FS := TFormatSettings.Create;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  if (Abs(V) >= 1e-4) and (Abs(V) < 1e15) then begin
    Result := FloatToStrF(V, ffFixed, 18, 6, FS);
    if Pos('.', Result) > 0 then begin
      while (Length(Result) > 1) and (Result[Length(Result)] = '0') do
        SetLength(Result, Length(Result) - 1);
      if (Length(Result) > 0) and (Result[Length(Result)] = '.') then
        SetLength(Result, Length(Result) - 1);
    end;
  end else
    Result := FloatToStrF(V, ffExponent, 15, 2, FS);
end;

function FormatDelphiDateTime(V: Double): string;
const
  MsPerDay = 24.0 * 60.0 * 60.0 * 1000.0;
var
  DT: TDateTime;
  MsOfDay: Int64;
  DatePart: string;
begin
  DT := V;
  DatePart := FormatDateTime('yyyy-mm-dd', DT);
  MsOfDay := Round(Frac(Abs(V)) * MsPerDay);
  if MsOfDay = 0 then
    Result := Format('%s (%s)', [DatePart, FormatFloatNicely(V)])
  else
    Result := Format('%s %s (%s)',
      [DatePart,
       FormatDateTime('hh:nn:ss.zzz', DT),
       FormatFloatNicely(V)]);
end;

function FormatHexAscii(const Bytes: TBytes): string;
var
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    for var I := 0 to High(Bytes) do begin
      if I > 0 then
        Sb.Append(' ');
      Sb.Append(IntToHex(Bytes[I], 2));
      if (Bytes[I] >= 32) and (Bytes[I] < 127) then begin
        Sb.Append('(');
        Sb.Append(Char(Bytes[I]));
        Sb.Append(')');
      end;
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

{ TDelphiValueReader }

constructor TDelphiValueReader.Create(ADebugInfo: TDebugInfoSet;
  ADebugger: IDebugTarget; ARtti: TDelphiRtti);
begin
  inherited Create;
  DebugInfo := ADebugInfo;
  Debugger  := ADebugger;
  Rtti      := ARtti;
end;

function TDelphiValueReader.ReadDelphiUnicodeString(Ptr: UInt64; out S: string): Boolean;
begin
  Result := ReadUtf16Prefixed(Ptr, False, S);
end;

// A WideString is an OLE BSTR. SysAllocStringLen stores the length in BYTES in
// the 4 bytes below the data, whereas a Delphi UnicodeString's TStrRec.length
// counts ELEMENTS. Decoding one with the other's rule reads twice as far:
// measured on TWidget.AsWStr, 'w_hello' (7 chars) came back as 14 characters --
// the string, its terminator, and six words of heap fill (`BAADF00D`).
function TDelphiValueReader.ReadDelphiWideString(Ptr: UInt64; out S: string): Boolean;
begin
  Result := ReadUtf16Prefixed(Ptr, True, S);
end;

function TDelphiValueReader.ReadUtf16Prefixed(Ptr: UInt64; LengthIsBytes: Boolean;
  out S: string): Boolean;
const
  MAX_LEN = 4096;
var
  StrLen: Integer;
  Buf: TBytes;
begin
  Result := False;
  S := '';
  if Ptr = 0 then begin
    S := '';
    Result := True;
    Exit;
  end;
  if not Debugger.ReadProcessMemoryAt(Ptr - 4, @StrLen, 4) then
    Exit;
  if LengthIsBytes then
    StrLen := StrLen div SizeOf(WideChar);
  if StrLen < 0 then begin
    S := '';
    Result := True;
    Exit;
  end;
  if StrLen = 0 then begin
    S := '';
    Result := True;
    Exit;
  end;
  // Cap the READ at MAX_LEN chars but surface the truncated content + a
  // marker, instead of dropping a long string to empty.
  var ReadChars := StrLen;
  var Truncated := False;
  if ReadChars > MAX_LEN then begin
    ReadChars := MAX_LEN;
    Truncated := True;
  end;
  SetLength(Buf, ReadChars * 2);
  if not Debugger.ReadProcessMemoryAt(Ptr, @Buf[0], ReadChars * 2) then
    Exit;
  S := TEncoding.Unicode.GetString(Buf);
  if Truncated then
    S := S + Format('…(%d chars total)', [StrLen]);
  Result := True;
end;

// Delphi Win64 TStrRec sits BELOW the char data:
//   Ptr-12 codePage:Word  Ptr-10 elemSize:Word  Ptr-8 refCnt  Ptr-4 length
// A UTF8String is AnsiString(CP_UTF8=65001); a plain AnsiString may carry any
// code page. Decoding everything with the machine's system ANSI page rendered
// those as mojibake ('citta`' -> 'cittA` '), i.e. wrong content AND wrong length,
// even though the right bytes were read.
function TDelphiValueReader.AnsiEncodingFor(Ptr: UInt64): TEncoding;
var
  CP: Word;
begin
  Result := TEncoding.ANSI;
  if (Ptr = 0) or (Debugger = nil) then Exit;
  if not Debugger.ReadProcessMemoryAt(Ptr - 12, @CP, SizeOf(CP)) then Exit;
  case CP of
    0, $FFFF: Exit;                    // CP_ACP / CP_NONE (RawByteString) -> system ANSI
    65001:    Exit(TEncoding.UTF8);
    1200:     Exit(TEncoding.Unicode);
  end;
  try
    Result := TEncoding.GetEncoding(CP);
  except
    Result := TEncoding.ANSI;          // code page not installed -> best effort
  end;
end;

function TDelphiValueReader.ReadDelphiAnsiString(Ptr: UInt64; out S: string): Boolean;
var
  Bytes: TBytes;
begin
  S := '';
  Result := ReadDelphiAnsiBytes(Ptr, Bytes);
  if not Result or (Length(Bytes) = 0) then Exit;
  var Enc := AnsiEncodingFor(Ptr);
  try
    S := Enc.GetString(Bytes);
  finally
    if not TEncoding.IsStandardEncoding(Enc) then
      Enc.Free;
  end;
end;

function TDelphiValueReader.ReadDelphiAnsiBytes(Ptr: UInt64; out Bytes: TBytes): Boolean;
const
  MAX_LEN = 4096;
var
  StrLen: Integer;
begin
  Result := False;
  SetLength(Bytes, 0);
  if Ptr = 0 then begin
    Result := True;
    Exit;
  end;
  if not Debugger.ReadProcessMemoryAt(Ptr - 4, @StrLen, 4) then
    Exit;
  if (StrLen <= 0) or (StrLen > MAX_LEN) then begin
    Result := True;
    Exit;
  end;
  SetLength(Bytes, StrLen);
  if not Debugger.ReadProcessMemoryAt(Ptr, @Bytes[0], StrLen) then
    Exit;
  Result := True;
end;

function TDelphiValueReader.ReadNullTerminatedAnsi(Ptr: UInt64; out S: string): Boolean;
const
  MAX_LEN = 4096;
  CHUNK   = 256;
var
  Buf: TBytes;
  Len, Read: Integer;
begin
  Result := False;
  S := '';
  if Ptr = 0 then
    Exit;
  SetLength(Buf, CHUNK);
  Len := 0;
  while Len < MAX_LEN do begin
    Read := CHUNK;
    if Len + Read > MAX_LEN then
      Read := MAX_LEN - Len;
    if not Debugger.ReadProcessMemoryAt(Ptr + UInt64(Len), @Buf[0], Read) then
      Exit;
    for var I := 0 to Read - 1 do begin
      if Buf[I] = 0 then begin
        S := TEncoding.ANSI.GetString(Buf, 0, I);
        Exit(True);
      end;
    end;
    Inc(Len, Read);
    S := S + TEncoding.ANSI.GetString(Buf, 0, Read);
  end;
  Result := True; // returned truncated at MAX_LEN
end;

function TDelphiValueReader.ReadNullTerminatedUtf16(Ptr: UInt64; out S: string): Boolean;
const
  MAX_CHARS = 4096;
  CHUNK     = 256;
var
  Buf: TBytes;
  Chars, Read: Integer;
begin
  Result := False;
  S := '';
  if Ptr = 0 then
    Exit;
  SetLength(Buf, CHUNK * 2);
  Chars := 0;
  while Chars < MAX_CHARS do begin
    Read := CHUNK;
    if Chars + Read > MAX_CHARS then
      Read := MAX_CHARS - Chars;
    if not Debugger.ReadProcessMemoryAt(Ptr + UInt64(Chars * 2), @Buf[0],
        Read * 2) then
      Exit;
    for var I := 0 to Read - 1 do begin
      if PWord(@Buf[I * 2])^ = 0 then begin
        S := TEncoding.Unicode.GetString(Buf, 0, I * 2);
        Exit(True);
      end;
    end;
    Inc(Chars, Read);
    S := S + TEncoding.Unicode.GetString(Buf, 0, Read * 2);
  end;
  Result := True; // truncated
end;

// Formatting routines below intentionally bit-reinterpret raw memory across
// signed/unsigned widths. Disable overflow/range checks for this section.
{$Q-}
{$R-}

function TDelphiValueReader.RecoverObjectFromInterface(IfacePtr: UInt64): UInt64;
// Recovers the object behind an interface reference by decoding the IMT
// adjustor thunk. The decoding itself lives on TDelphiRtti, because the closure
// expander needs the same answer and the mechanism must not exist twice.
//
// The alternative -- a bitness-independent backward search for an interface
// table -- was tried and REVERTED: reached from an arbitrary formatted value it
// walks into module data, where a stretch of bytes can pass the VMT identity
// check. Decoding the thunk asks the reference itself where its object is, and
// cannot wander.
begin
  Result := 0;
  if Rtti = nil then
    Exit;
  Result := Rtti.ObjectFromInterfaceThunk(IfacePtr);
end;

function TDelphiValueReader.DecodeSetMembers(RawValue, Address: UInt64;
  ByteWidth: Integer; const Names: TArray<string>; MinValue: Integer): string;
var
  Buf: array[0..31] of Byte;   // a Delphi set is at most 32 bytes (256 members)
begin
  if ByteWidth < 1 then
    ByteWidth := 1;
  if ByteWidth > 32 then
    ByteWidth := 32;
  FillChar(Buf, SizeOf(Buf), 0);
  // Up to 8 bytes fit in the value register; a wider set lives in memory.
  if ByteWidth <= 8 then
    Move(RawValue, Buf[0], ByteWidth)
  else if not ((Address <> 0) and Debugger.ReadProcessMemoryAt(Address, @Buf[0], ByteWidth)) then
    Move(RawValue, Buf[0], 8);   // best effort when there is no readable address

  Result := '';
  for var I := 0 to High(Names) do begin
    var BitIdx := MinValue + I;
    if (BitIdx >= 0) and (BitIdx < ByteWidth * 8) and
       ((Buf[BitIdx shr 3] and (Byte(1) shl (BitIdx and 7))) <> 0) then begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + Names[I];
    end;
  end;
  Result := '[' + Result + ']';
end;

function TDelphiValueReader.FormatVariantAt(Address: UInt64): string;
var
  Header: array[0..7] of Byte;
  Data:   UInt64;
begin
  if not Debugger.ReadProcessMemoryAt(Address, @Header, 8) then
    Exit('<read failed>');
  if not Debugger.ReadProcessMemoryAt(Address + 8, @Data, 8) then
    Exit('<read failed>');

  var VType := PWord(@Header[0])^;
  var BaseType := VType and varTypeMask;
  var ByRef    := (VType and varByRef) <> 0;

  // VarArray: Data field is a PVarArray pointer; display shape and element type.
  if ((VType and varArray) <> 0) and not ByRef then begin
    var VarArrPtr := Data;
    if VarArrPtr = 0 then
      Exit('VarArray (nil)');
    var DimWord: Word;
    if not Debugger.ReadProcessMemoryAt(VarArrPtr, @DimWord, 2) then
      Exit('<VarArray: read failed>');
    var DimCount := Integer(DimWord);
    if (DimCount < 1) or (DimCount > 16) then
      Exit(Format('<VarArray: invalid DimCount=%d>', [DimCount]));
    // Win64 TVarArray: +0 DimCount(W) +2 Flags(W) +4 ElementSize(I) +8 LockCount(I)
    //   +12 pad +16 Data(P) +24 Bounds[]: each 2 x Integer (ElementCount, LowBound)
    // Bounds stored in REVERSE user-declaration order.
    var BoundsBase := VarArrPtr + 24;
    var TotalElems: Int64 := 1;
    var Parts: TArray<string>;
    SetLength(Parts, DimCount);
    for var I := 0 to DimCount - 1 do begin
      var StorageK := DimCount - 1 - I;
      var ElemCountU: Cardinal;
      var LowBoundU:  Cardinal;
      if not Debugger.ReadProcessMemoryAt(BoundsBase + UInt64(StorageK * 8),     @ElemCountU, 4) or
         not Debugger.ReadProcessMemoryAt(BoundsBase + UInt64(StorageK * 8 + 4), @LowBoundU,  4) then
        Exit('<VarArray: read bound failed>');
      var LB := Int32(LowBoundU);
      var EC := Int32(ElemCountU);
      Parts[I]   := Format('%d..%d', [LB, LB + EC - 1]);
      TotalElems := TotalElems * EC;
    end;
    var ElemTypeName: string;
    case BaseType of
      varSmallint: ElemTypeName := 'SmallInt';
      varInteger:  ElemTypeName := 'Integer';
      varSingle:   ElemTypeName := 'Single';
      varDouble:   ElemTypeName := 'Double';
      varCurrency: ElemTypeName := 'Currency';
      varDate:     ElemTypeName := 'TDateTime';
      varBoolean:  ElemTypeName := 'Boolean';
      varVariant:  ElemTypeName := 'Variant';
      varShortInt: ElemTypeName := 'ShortInt';
      varByte:     ElemTypeName := 'Byte';
      varWord:     ElemTypeName := 'Word';
      varLongWord: ElemTypeName := 'Cardinal';
      varInt64:    ElemTypeName := 'Int64';
      varUInt64:   ElemTypeName := 'UInt64';
      varString:   ElemTypeName := 'AnsiString';
      varUString:  ElemTypeName := 'string';
      varOleStr:   ElemTypeName := 'WideString';
    else
      ElemTypeName := Format('vartype=$%.4x', [BaseType]);
    end;
    Exit(Format('VarArray[%s] of %s (%d elements)',
      [string.Join(', ', Parts), ElemTypeName, TotalElems]));
  end;

  // Decode the type label
  var Label_: string;
  case BaseType of
    varEmpty:    Exit('<empty>');
    varNull:     Exit('<null>');
    varSmallint: Label_ := 'varSmallint';
    varInteger:  Label_ := 'varInteger';
    varSingle:   Label_ := 'varSingle';
    varDouble:   Label_ := 'varDouble';
    varCurrency: Label_ := 'varCurrency';
    varDate:     Label_ := 'varDate';
    varOleStr:   Label_ := 'varOleStr';
    varDispatch: Label_ := 'varDispatch';
    varError:    Label_ := 'varError';
    varBoolean:  Label_ := 'varBoolean';
    varVariant:  Label_ := 'varVariant';
    varUnknown:  Label_ := 'varUnknown';
    varShortInt: Label_ := 'varShortInt';
    varByte:     Label_ := 'varByte';
    varWord:     Label_ := 'varWord';
    varLongWord: Label_ := 'varLongWord';
    varInt64:    Label_ := 'varInt64';
    varUInt64:   Label_ := 'varUInt64';
    varString:   Label_ := 'varString';
    varUString:  Label_ := 'varUString';
    $08D0:       Label_ := 'varSQLTimeStamp'; // Data.SqlTimSt custom
  else
    Exit(Format('vartype=0x%.4x (raw=0x%.16x)', [VType, Data]));
  end;
  if ByRef then
    Label_ := Label_ + ' (byRef)';

  // A byRef Variant's Data field is a POINTER to the value, not the value
  // itself. Dereference one level so the scalar decoders below read the real
  // payload (an integer, a double, ...) instead of the low bits of the address,
  // and so a byRef string subtype gets the string pointer it expects. VarArrays
  // took the `not ByRef` path above and never reach here.
  if ByRef and (Data <> 0) then begin
    var Deref: UInt64 := 0;
    if Debugger.ReadProcessMemoryAt(Data, @Deref, 8) then
      Data := Deref;
  end;

  // Decode the value
  var ValStr: string;
  case BaseType of
    varSmallint: ValStr := IntToStr(SmallInt(Data and $FFFF));
    varInteger:  ValStr := IntToStr(Int32(Data and $FFFFFFFF));
    varSingle:   ValStr := FormatFloatNicely(PSingle(@Data)^);
    varDouble:
      ValStr := FormatFloatNicely(PDouble(@Data)^);
    varCurrency: ValStr := FormatFloatNicely(Int64(Data) / 10000.0);
    varDate:     ValStr := FormatDelphiDateTime(PDouble(@Data)^);
    varBoolean:
      if (Data and $FFFF) <> 0 then ValStr := 'True' else ValStr := 'False';
    varShortInt: ValStr := IntToStr(ShortInt(Data and $FF));
    varByte:     ValStr := IntToStr(Data and $FF);
    varWord:     ValStr := IntToStr(Data and $FFFF);
    varLongWord: ValStr := IntToStr(Data and $FFFFFFFF);
    varInt64:    ValStr := IntToStr(Int64(Data));
    varUInt64:   ValStr := UIntToStr(Data);
    varOleStr,
    varUString:
      // Data is a pointer to a UTF-16 string buffer
      begin
        var S: string;
        if ReadDelphiUnicodeString(Data, S) then
          ValStr := QuotedStr(S)
        else
          ValStr := Format('@0x%x', [Data]);
      end;
    varString:
      // Data is a pointer to an AnsiString buffer
      begin
        var S: string;
        if ReadDelphiAnsiString(Data, S) then
          ValStr := QuotedStr(S)
        else
          ValStr := Format('@0x%x', [Data]);
      end;
    varError:
      ValStr := Format('HRESULT 0x%.8x', [Data and $FFFFFFFF]);
    varDispatch, varUnknown:
      ValStr := Format('@0x%x', [Data]);
    $08D0: // varSQLTimeStamp -- Data is a pointer to a TSQLTimeStamp record
      begin
        var TS: array[0..15] of Byte;
        if (Data <> 0) and Debugger.ReadProcessMemoryAt(Data, @TS, 16) then begin
          var YYear   := PWord(@TS[0])^;
          var Month   := PWord(@TS[2])^;
          var Day     := PWord(@TS[4])^;
          var Hour    := PWord(@TS[6])^;
          var Minute  := PWord(@TS[8])^;
          var Second  := PWord(@TS[10])^;
          var Fract   := PCardinal(@TS[12])^;
          if Fract = 0 then
            ValStr := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d',
              [YYear, Month, Day, Hour, Minute, Second])
          else
            ValStr := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d.%d',
              [YYear, Month, Day, Hour, Minute, Second, Fract]);
        end else
          ValStr := Format('@0x%x', [Data]);
      end;
  else
    ValStr := Format('0x%x', [Data]);
  end;

  Result := Format('%s: %s', [Label_, ValStr]);
end;

function TDelphiValueReader.LooksLikeVariantAt(Address: UInt64): Boolean;
var
  Buf: array[0..23] of Byte;
  VType, BaseType: Word;
begin
  Result := False;
  if Address = 0 then
    Exit;
  if not Debugger.ReadProcessMemoryAt(Address, @Buf, SizeOf(Buf)) then
    Exit;
  VType    := PWord(@Buf[0])^;
  BaseType := VType and varTypeMask;
  // Reserved1/2/3 must be zero in a real Variant.
  for var I := 2 to 7 do
    if Buf[I] <> 0 then
      Exit(False);
  // Skip varByRef for the auto-detect path.
  if (VType and varByRef) <> 0 then
    Exit(False);
  // varArray bit: the 8-byte payload at +8 is a pointer to a TVarArray header.
  if (VType and varArray) <> 0 then begin
    var VarArrPtr := PUInt64(@Buf[8])^;
    if VarArrPtr = 0 then
      Exit(True);
    var DimWord: Word;
    if not Debugger.ReadProcessMemoryAt(VarArrPtr, @DimWord, 2) then
      Exit(False);
    Exit((DimWord >= 1) and (DimWord <= 16));
  end;
  case BaseType of
    varNull: begin
      Result := True;
      for var I := 8 to 15 do
        if Buf[I] <> 0 then
          Exit(False);
    end;
    varDate: begin
      var D := PDouble(@Buf[8])^;
      Result := (D >= 1.0) and (D < 110000);
    end;
    varDouble: begin
      var D := PDouble(@Buf[8])^;
      Result := (not IsNan(D)) and (not IsInfinite(D)) and
                ((D = 0) or (Abs(D) >= 1e-30));
    end;
    varCurrency: begin
      var I64 := PInt64(@Buf[8])^;
      Result := (I64 = 0) or
                ((I64 > 0) and (I64 < Int64(1000000000000000))) or
                ((I64 < 0) and (I64 > -Int64(1000000000000000)));
    end;
    // varInt64 ($0014) / varUInt64 ($0015): DELIBERATELY NOT auto-detected, like
    // varSmallint / varInteger (which fall through to the default False above). A
    // real mis-typed varInt64 TVarData is byte-for-byte identical to a plain
    // integer local whose 8-byte value is exactly 20/21 followed by an unrelated
    // qword -- the +0..+7 region (VType + zero reserved) is the same in both, so
    // NO payload test can tell them apart. Accepting it (the old `Result := True`)
    // meant any untyped local equal to 20/21 was shown as a Variant whose value
    // was read from the NEIGHBOURING slot (bytes +8..+15) -- silently wrong type
    // AND value. A false negative (a real varInt64 renders as its raw integer) is
    // strictly safer than that false positive. A properly TYPED Variant local does
    // not use this auto-detect path, so real Variants are unaffected.
    varOleStr, varUString, varString: begin
      var Ptr := PUInt64(@Buf[8])^;
      if Ptr = 0 then
        Exit(True);
      var L: Integer;
      if not Debugger.ReadProcessMemoryAt(Ptr - 4, @L, 4) then
        Exit(False);
      Result := (L >= 0) and (L < 65536);
    end;
  end;
end;

{$Q+}
{$R+}


// Delphi TVarData layout (16 bytes, x64):
//   [00]   VType    : Word
//   [02]   Reserved1: Word
//   [04]   Reserved2: Word
//   [06]   Reserved3: Word
//   [08]   data     : 8 bytes (interpreted by VType)
// Formatting routines below intentionally bit-reinterpret raw memory across
// signed/unsigned widths (Int32(Raw and $FFFFFFFF), Int64(UInt64), etc.).
// Under {$Q+}{$R+} those casts raise EIntOverflow / ERangeError when the
// high bits happen to be set (very common for stack garbage and pointers).
// Disable the checks for this section -- the casts are the desired semantics.
{$Q-}
{$R-}



// Returns the stack-slot byte size for the local whose address is `Address`,
// derived from the gap to the next-higher RbpOffset in the current frame's
// locals list. The top local's slot extends up to RBP (offset 0). Returns 0
// when the address doesn't match a local in the current frame, or for
// positive-offset parameters (which live in caller shadow space and are
// not slot-allocated by the prologue).
//
// Reason: in big projects (SampleApp CheckCalendarDates) the RSM type
// table is systematically shifted for some procedures -- every local's
// TypeId points six slots too far in the user-type table, so a Variant
// (TypeId=8) shows up as Word (TypeId=14), an Integer (10) as Cardinal
// (16), etc. Memory-pattern heuristics cannot distinguish a
// freshly-initialised <empty> Variant (24 zero bytes) from a zeroed
// integer local. The slot SIZE allocated by the compiler is the only
// authoritative signal: a 24-byte slot tagged as a 2-byte Word
// definitively belongs to a Variant.
function TDelphiValueReader.SlotSizeAt(Address: UInt64): Cardinal;
var
  Locals: TArray<TLocalValue>;
  FoundIdx: Integer;
  CurAddr, NextAddr: UInt64;
begin
  Result := 0;
  if (Debugger = nil) or (Address = 0) then
    Exit;
  Locals := Debugger.GetLocalValues;
  FoundIdx := -1;
  for var I := 0 to High(Locals) do
    if Locals[I].Address = Address then begin
      FoundIdx := I;
      Break;
    end;
  if FoundIdx < 0 then
    Exit;
  if Locals[FoundIdx].RbpOffset >= 0 then
    Exit; // parameter -- no compiler-allocated slot
  CurAddr  := Locals[FoundIdx].Address;
  NextAddr := 0;
  for var I := 0 to High(Locals) do
    if (Locals[I].RbpOffset < 0) and (Locals[I].Address > CurAddr) and
       ((NextAddr = 0) or (Locals[I].Address < NextAddr)) then
      NextAddr := Locals[I].Address;
  if NextAddr = 0 then
    // Top local: slot extends from its address up to RBP.
    Result := Cardinal(-Locals[FoundIdx].RbpOffset)
  else
    Result := Cardinal(NextAddr - CurAddr);
end;

// Heuristic: does memory at Address look like a Delphi TVarData carrying a
// meaningful payload? Whitelisted base types only -- the small-int variants
// (varSmallint, varInteger, varBoolean, ...) are intentionally excluded
// because their stack-slot pattern is indistinguishable from a plain
// integer field of the same byte values. Recovery target: SampleApp-style
// projects where the RSM mis-tags nested-procedure `var X: variant` locals
// with TypeId pointing at a primitive (Word), so without recovery the
// formatter shows only the raw VType word ("7" for varDate).


// Returns True when a type's Delphi TTypeKind makes it a candidate for
// the structured-value formatting path (`$<addr> (<TypeName>)` + RSM
// member expansion). Anything else falls through to the primitive
// formatters. Uses TKind constants from DelphiRtti.
function IsExpandableTKind(K: Byte): Boolean;
begin
  Result := (K = TK_CLASS) or (K = TK_RECORD) or (K = TK_MRECORD) or
            (K = TK_INTERFACE);
end;

function TDelphiValueReader.FormatLocalType(const V: TLocalValue): string;
var
  Sign: string;
  KindStr: string;
begin
  if V.RbpOffset >= 0 then Sign := '+' else Sign := '-';
  case V.Kind of
    lkVarParam: KindStr := 'var ';
  else          KindStr := '';
  end;
  if V.TypeHint <> '' then
    Result := KindStr + V.TypeHint
  else
    Result := KindStr + Format('@[rbp%s%d]', [Sign, Abs(V.RbpOffset)]);
end;

function TDelphiValueReader.FormatLocalValue(const V: TLocalValue): string;

  function FormatCharRepr(CodePoint: UInt32): string;
  begin
    if (CodePoint >= 32) and (CodePoint < 127) then
      Result := Format('''%s'' (0x%x)', [Char(CodePoint), CodePoint])
    else
      Result := Format('#%d (0x%x)', [CodePoint, CodePoint]);
  end;

  // For a stack slot or dereferenced value, format according to known type.
  // TKind-first dispatch: ask the type's TTypeInfo what TKind it is, then
  // refine display by TypeName within each kind branch. Falls back to a
  // by-name table for types whose TTypeInfo wasn't parsed (big VCL VMTs).
  function FormatTyped(Raw: UInt64; const TypeName: string): string;
  var
    Kind: Byte;
  begin
    Kind := 0;
    if (TypeName <> '') and (DebugInfo <> nil) then
      Kind := DebugInfo.LookupTypeKind(TypeName);
    // The name lookup cannot answer for every type. An INTERFACE in particular
    // is emitted with no entry in the type tables at all -- `ICounter` appears
    // in neither TD32's class table nor the RSM type table -- so it resolves to
    // nothing, and gating anything on the name alone silently never fires. The
    // symbol carries the kind ITS OWN provider resolved from the type id, which
    // is the authority whenever the name is silent.
    if (Kind = 0) and SameText(TypeName, V.TypeHint) then
      Kind := V.TypeKind;

    // TD32 sometimes surfaces a class-typed local as `^TFoo` (raw pointer
    // to the class instance) instead of `TFoo` directly. Unwrap so the
    // class formatting / nil display below kicks in.
    if (Kind = 0) and (Length(TypeName) >= 2) and (TypeName[1] = '^') and
       (DebugInfo <> nil) then begin
      var Inner := Copy(TypeName, 2, MaxInt);
      var InnerKind := DebugInfo.LookupTypeKind(Inner);
      if InnerKind = TK_CLASS then
        Exit(FormatTyped(Raw, Inner));
    end;

    // Null class / interface / method-pointer reference: a slot that
    // holds 0 must surface as `nil`. SampleApp saw class refs print as
    // `0 (0x0)`; same regression existed on interface and method-pointer
    // slots.
    if (Raw = 0) and
       ((Kind = TK_CLASS) or (Kind = TK_INTERFACE) or (Kind = TK_METHOD) or
        // TD32 surfaces `procedure(...) of object` as this generic label.
        SameText(TypeName, 'procedure of object') or
        // TD32 may surface user interface aliases / method pointers
        // without a TKind tag. Treat any unknown-Kind type whose name
        // begins with `I<UpperCase>` as an interface.
        ((Kind = 0) and (Length(TypeName) >= 2) and (TypeName[1] = 'I') and
         CharInSet(TypeName[2], ['A'..'Z']))) then
      Exit('nil');

    // Interface reference: the slot points INTO the implementing object
    // (Obj + IOffset), so IsClassInstance(Raw) is False. Recover the object via
    // the IMT adjustor thunk -- bounded, both bitnesses -- and label the slot
    // with its CONCRETE class.
    if (Raw >= 65536) and (Rtti <> nil) and not Rtti.IsClassInstance(Raw) and
       ((Kind = TK_INTERFACE) or
        ((Length(TypeName) >= 2) and (TypeName[1] = 'I') and
         CharInSet(TypeName[2], ['A'..'Z']))) then begin
      var IObj := RecoverObjectFromInterface(Raw);
      if (IObj <> 0) then begin
        var ICls := Rtti.GetInstanceClassName(IObj);
        if ICls = '' then ICls := '<class>';
        DapLog(Format('FormatTyped interface Raw=$%x DeclaredType="%s" Obj=$%x Class="%s"',
          [Raw, TypeName, IObj, ICls]));
        Exit(Format('$%x (%s)', [Raw, ICls]));
      end;
    end;

    // Class instance label (gated on runtime VMT + expandable TKind).
    if (Raw >= 65536) and (Rtti <> nil) and Rtti.IsClassInstance(Raw) and
       ((Kind = 0) or IsExpandableTKind(Kind)) then begin
      var DisplayName := TypeName;
      var Runtime := Rtti.GetInstanceClassName(Raw);
      DapLog(Format('FormatTyped class Raw=$%x DeclaredType="%s" RuntimeVmtClass="%s"',
        [Raw, TypeName, Runtime]));
      if Runtime <> '' then DisplayName := Runtime;
      if DisplayName = '' then DisplayName := '<class>';
      Exit(Format('$%x (%s)', [Raw, DisplayName]));
    end;

    case Kind of
      TK_INTEGER: begin
        if (TypeName = 'Byte') then
          Exit(Format('%d  (0x%x)', [Raw and $FF, Raw and $FF]));
        if TypeName = 'ShortInt' then
          Exit(Format('%d  (0x%x)', [ShortInt(Raw and $FF), Raw and $FF]));
        if (TypeName = 'Word') or (TypeName = 'UInt16') then
          Exit(Format('%d  (0x%x)', [Raw and $FFFF, Raw and $FFFF]));
        if (TypeName = 'SmallInt') or (TypeName = 'Int16') then
          Exit(Format('%d  (0x%x)', [SmallInt(Raw and $FFFF), Raw and $FFFF]));
        if (TypeName = 'Cardinal') or (TypeName = 'LongWord') or
           (TypeName = 'UInt32')  or (TypeName = 'FixedUInt') then
          Exit(Format('%u  (0x%x)', [Raw and $FFFFFFFF, Raw and $FFFFFFFF]));
        // Integer / LongInt / Int32 / FixedInt / aliases -- signed 32-bit
        Exit(Format('%d  (0x%x)', [Int32(Raw and $FFFFFFFF), Raw and $FFFFFFFF]));
      end;
      TK_INT64: begin
        if (TypeName = 'UInt64') or (TypeName = 'NativeUInt') then
          Exit(Format('%u  (0x%x)', [Raw, Raw]));
        Exit(Format('%d  (0x%x)', [Int64(Raw), Raw]));
      end;
      TK_CHAR:
        Exit(FormatCharRepr(Raw and $FF));
      TK_WCHAR:
        Exit(FormatCharRepr(Raw and $FFFF));
      TK_ENUM: begin
        if (TypeName = 'Boolean') or (TypeName = 'ByteBool') then begin
          if (Raw and $FF) = 0 then Exit('False') else Exit('True');
        end;
        if (TypeName = 'WordBool') or (TypeName = 'LongBool') then begin
          if Raw = 0 then Exit('False') else Exit('True');
        end;
        // Generic enumeration -- ordinal display, masked to the enum's REAL
        // storage width. Caller hits the enum-name resolution path elsewhere when
        // the kind is tkEnum and the value is in MinValue..MaxValue; this branch
        // renders the raw ordinal (notably an UNINITIALISED enum, which Delphi
        // does not zero-init). The local is read as 8 bytes, so masking a fixed
        // 4 bytes folded the ADJACENT stack local into the displayed number.
        var ESz := 1;   // Delphi default packing
        var ESize: Integer;
        if (DebugInfo <> nil) and DebugInfo.GetTypeSize(TypeName, ESize) and
           (ESize in [1, 2, 4]) then
          ESz := ESize
        else begin
          var EInfo: TRsmEnumInfo;
          if (DebugInfo <> nil) and DebugInfo.LookupEnumInfo(TypeName, EInfo) and
             EInfo.IsValid then begin
            if EInfo.MaxValue > 65535 then ESz := 4
            else if EInfo.MaxValue > 255 then ESz := 2;
          end;
        end;
        var EMasked: UInt64;
        case ESz of
          2: EMasked := Raw and $FFFF;
          4: EMasked := Raw and $FFFFFFFF;
        else
          EMasked := Raw and $FF;
        end;
        Exit(Format('%d  (0x%x)', [Int64(EMasked), EMasked]));
      end;
      TK_FLOAT: begin
        if TypeName = 'Single' then
          Exit(FormatFloatNicely(PSingle(@Raw)^));
        if TypeName = 'Currency' then
          Exit(FormatFloatNicely(Int64(Raw) / 10000.0));
        if (TypeName = 'TDateTime') or (TypeName = 'TDate') or (TypeName = 'TTime') then
          Exit(FormatDelphiDateTime(PDouble(@Raw)^));
        // Double / Real / Extended (Win64 = Double) / aliases.
        Exit(FormatFloatNicely(PDouble(@Raw)^));
      end;
      TK_POINTER:
        Exit(Format('0x%x', [Raw]));
    end;

    // Kind = 0 / unrecognized: fall back to the legacy by-name table for
    // types whose TTypeInfo wasn't parsed (large VCL classes, RTL types
    // that don't surface a TTypeInfo for the primitive aliases). The
    // explicit entries below are the ones the test suite + real-world
    // debugging actually exercise.
    if (TypeName = 'Integer') or (TypeName = 'LongInt') then
      Exit(Format('%d  (0x%x)', [Int32(Raw and $FFFFFFFF), Raw and $FFFFFFFF]));
    if (TypeName = 'Cardinal') or (TypeName = 'LongWord') then
      Exit(Format('%u  (0x%x)', [Raw and $FFFFFFFF, Raw and $FFFFFFFF]));
    if (TypeName = 'Int64') or (TypeName = 'NativeInt') then
      Exit(Format('%d  (0x%x)', [Int64(Raw), Raw]));
    if (TypeName = 'UInt64') or (TypeName = 'NativeUInt') then
      Exit(Format('%u  (0x%x)', [Raw, Raw]));
    if TypeName = 'Boolean' then begin
      if (Raw and $FF) = 0 then Exit('False') else Exit('True');
    end;
    if (TypeName = 'ByteBool') or (TypeName = 'WordBool') or
       (TypeName = 'LongBool') then begin
      if Raw = 0 then Exit('False') else Exit('True');
    end;
    if TypeName = 'Byte' then
      Exit(Format('%d  (0x%x)', [Raw and $FF, Raw and $FF]));
    if TypeName = 'AnsiChar' then
      Exit(FormatCharRepr(Raw and $FF));
    if TypeName = 'ShortInt' then
      Exit(Format('%d  (0x%x)', [ShortInt(Raw and $FF), Raw and $FF]));
    if TypeName = 'Word' then
      Exit(Format('%d  (0x%x)', [Raw and $FFFF, Raw and $FFFF]));
    if (TypeName = 'Char') or (TypeName = 'WideChar') then
      Exit(FormatCharRepr(Raw and $FFFF));
    if TypeName = 'SmallInt' then
      Exit(Format('%d  (0x%x)', [SmallInt(Raw and $FFFF), Raw and $FFFF]));
    if TypeName = 'Single' then
      Exit(FormatFloatNicely(PSingle(@Raw)^));
    // Real48 and Extended80 arrive here already narrowed to Double bits by
    // ReadValueSlotRaw, so they format exactly like the rest of the family.
    if (TypeName = 'Double') or (TypeName = 'Real') or (TypeName = 'Extended') or
       (TypeName = 'Real48') or (TypeName = 'Extended80') then
      Exit(FormatFloatNicely(PDouble(@Raw)^));
    if (TypeName = 'TDateTime') or (TypeName = 'TDate') or (TypeName = 'TTime') then
      Exit(FormatDelphiDateTime(PDouble(@Raw)^));
    if TypeName = 'Currency' then
      Exit(FormatFloatNicely(Int64(Raw) / 10000.0));
    if (TypeName = 'Pointer') or
       ((Length(TypeName) > 0) and (TypeName[1] = 'P') and
        ((TypeName = 'PByte') or (TypeName = 'PWord') or
         (TypeName = 'PCardinal') or (TypeName = 'PInteger') or
         (TypeName = 'PInt64') or (TypeName = 'PBoolean') or
         (TypeName = 'PDouble') or (TypeName = 'PSingle') or
         (TypeName = 'PAnsiChar') or (TypeName = 'PWideChar') or
         (TypeName = 'PChar') or (TypeName = 'PUTF8Char'))) or
       (TypeName = 'THandle') or (TypeName = 'HWND') or (TypeName = 'HDC') then
      Exit(Format('0x%x', [Raw]));

    // Unknown-Kind ordinal alias / subrange (e.g. TBorderWidth = 0..MaxInt).
    // The 8 bytes read into Raw for a member field include the NEXT field's low
    // bytes when this field is smaller. Mask to the type's real storage width so
    // the value is not corrupted (F4: TBorderWidth showed 0x3DAADA6000000000,
    // the high dword being the adjacent FPadding pointer). Every genuine 8-byte
    // type is matched by name above, so an unresolved type reaching here is a
    // sub-8-byte ordinal -> default to a 4-byte signed read when the size is
    // unknown.
    var Sz: Integer;
    if not ((DebugInfo <> nil) and DebugInfo.GetTypeSize(TypeName, Sz)) then
      Sz := 4;   // size unknown -> assume a 4-byte ordinal (not the raw 8 bytes)
    case Sz of
      1: Result := Format('%d  (0x%x)', [Int8(Raw and $FF), Raw and $FF]);
      2: Result := Format('%d  (0x%x)', [Int16(Raw and $FFFF), Raw and $FFFF]);
      8: Result := Format('%d  (0x%x)', [Int64(Raw), Raw]);
    else
      Result := Format('%d  (0x%x)', [Int32(Raw and $FFFFFFFF), Raw and $FFFFFFFF]);
    end;
  end;

  // TKind-first dispatch with by-name refinement and a by-name fallback for
  // types whose TTypeInfo wasn't parsed. Handles UnicodeString / AnsiString /
  // WideString / RawByteString / UTF8String / user-declared aliases of any
  // of the above.
  function FormatStringByPointer(Ptr: UInt64; const TypeName: string): string;
  var
    Decoded: string;
    Bytes:   TBytes;
    Kind:    Byte;
  begin
    Result := '';
    Kind := 0;
    if (TypeName <> '') and (DebugInfo <> nil) then
      Kind := DebugInfo.LookupTypeKind(TypeName);

    case Kind of
      TK_USTRING: begin   // (string-by-pointer dispatch; see FormatTyped)
        if ReadDelphiUnicodeString(Ptr, Decoded) then
          Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
        Exit(Format('@0x%x (string read failed)', [Ptr]));
      end;
      TK_WSTRING: begin
        // BSTR: the prefix is a byte count, not an element count.
        if ReadDelphiWideString(Ptr, Decoded) then
          Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
        Exit(Format('@0x%x (string read failed)', [Ptr]));
      end;
      TK_LSTRING: begin
        // AnsiString family. RawByteString needs the hex/ascii view; other
        // AnsiString aliases get the decoded-with-codepage rendering.
        if SameText(TypeName, 'RawByteString') then begin
          if ReadDelphiAnsiBytes(Ptr, Bytes) then begin
            var AsciiText := '';
            for var B in Bytes do
              if (B >= 32) and (B < 127) then
                AsciiText := AsciiText + Char(B)
              else
                AsciiText := AsciiText + '.';
            Exit(Format('''%s''  [%s]  (@0x%x)',
              [AsciiText, FormatHexAscii(Bytes), Ptr]));
          end;
          Exit(Format('@0x%x (raw read failed)', [Ptr]));
        end;
        if ReadDelphiAnsiString(Ptr, Decoded) then
          Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
        Exit(Format('@0x%x (string read failed)', [Ptr]));
      end;
      TK_POINTER: begin
        // PChar / PAnsiChar / PWideChar are pointers but display as
        // null-terminated character strings. Other tkPointer types are
        // handled by FormatTyped as raw hex.
        if (TypeName = 'PChar') or (TypeName = 'PWideChar') then begin
          if ReadNullTerminatedUtf16(Ptr, Decoded) then
            Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
          Exit(Format('@0x%x', [Ptr]));
        end;
        if (TypeName = 'PAnsiChar') or (TypeName = 'PUTF8Char') or
           (TypeName = 'MarshaledAString') then begin
          if ReadNullTerminatedAnsi(Ptr, Decoded) then
            Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
          Exit(Format('@0x%x', [Ptr]));
        end;
      end;
    end;

    // Kind = 0 / unrecognised: fall back to the by-name table for types
    // whose TTypeInfo wasn't parsed.
    if (TypeName = 'UnicodeString') or (TypeName = 'string') or
       (TypeName = 'WideString') then begin
      if ReadDelphiUnicodeString(Ptr, Decoded) then
        Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
      Exit(Format('@0x%x (string read failed)', [Ptr]));
    end;
    if TypeName = 'RawByteString' then begin
      if ReadDelphiAnsiBytes(Ptr, Bytes) then begin
        var AsciiText := '';
        for var B in Bytes do
          if (B >= 32) and (B < 127) then
            AsciiText := AsciiText + Char(B)
          else
            AsciiText := AsciiText + '.';
        Exit(Format('''%s''  [%s]  (@0x%x)',
          [AsciiText, FormatHexAscii(Bytes), Ptr]));
      end;
      Exit(Format('@0x%x (raw read failed)', [Ptr]));
    end;
    if (TypeName = 'AnsiString') or (TypeName = 'UTF8String') then begin
      if ReadDelphiAnsiString(Ptr, Decoded) then
        Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
      Exit(Format('@0x%x (string read failed)', [Ptr]));
    end;
    if (TypeName = 'PChar') or (TypeName = 'PWideChar') or
       SameText(TypeName, '^Char') or SameText(TypeName, '^WideChar') then begin
      if ReadNullTerminatedUtf16(Ptr, Decoded) then
        Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
      Exit(Format('@0x%x', [Ptr]));
    end;
    if (TypeName = 'PAnsiChar') or SameText(TypeName, '^AnsiChar') then begin
      if ReadNullTerminatedAnsi(Ptr, Decoded) then
        Exit(Format('''%s''  (@0x%x)', [Decoded, Ptr]));
      Exit(Format('@0x%x', [Ptr]));
    end;
  end;

  // Element type name of a dynamic-array TypeHint, or '' when the hint is not
  // a dyn-array shape. TD32 flattens `array of T` / `TArray<T>` locals to
  // `^T`; RSM may keep the source form. The char-pointer families (`^Char`
  // etc.) are string pointers, handled by FormatStringByPointer -- not arrays.
  function DynArrayElemType(const TypeHint: string): string;
  begin
    Result := '';
    if TypeHint = '' then Exit;
    if TypeHint.StartsWith('TArray<') and TypeHint.EndsWith('>') then
      Exit(Copy(TypeHint, 8, Length(TypeHint) - 8).Trim);
    if TypeHint.StartsWith('array of ', True) then
      Exit(Copy(TypeHint, 10, MaxInt).Trim);
    if (Length(TypeHint) >= 2) and (TypeHint[1] = '^') then begin
      var Inner := Copy(TypeHint, 2, MaxInt);
      if SameText(Inner, 'Char') or SameText(Inner, 'WideChar') or
         SameText(Inner, 'AnsiChar') or SameText(Inner, 'UTF8Char') then
        Exit('');   // string pointer, not a dyn array
      Result := Inner;
    end;
  end;

  // Renders a dynamic-array LOCAL value in Pascal `[...]` notation. Returns
  // '[]' for nil/empty, a bounded element preview for a live array, or '' when
  // the slot does not carry a valid dyn-array header (a genuine pointer the
  // caller should format the normal way). DataPtr is the slot value (the array
  // data pointer); the length lives at DataPtr-8, the refcount at DataPtr-12.
  function FormatDynArrayLocal(DataPtr: UInt64; const ElemType: string): string;
  const
    MAX_PREVIEW = 50;
  begin
    Result := '';
    if Debugger = nil then Exit;
    if DataPtr = 0 then Exit('[]');           // nil dyn array = empty
    if DataPtr < 65536 then Exit;
    var Len: Int64 := 0;
    var RefCnt: Int32 := 0;
    var Layout := Debugger.TargetLayout;
    if not Debugger.ReadProcessMemoryAt(Layout.DynArrayLengthAddr(DataPtr),
             @Len, Layout.DynArrayLengthSize) then Exit;
    if not Debugger.ReadProcessMemoryAt(Layout.DynArrayRefCountAddr(DataPtr),
             @RefCnt, 4) then Exit;
    // Header sanity: a genuine non-array pointer fails this (length reads huge
    // or the refcount is not a live dyn-array refcount).
    if (Len < 0) or (Len > (1 shl 24)) then Exit;
    if not ((RefCnt = -1) or ((RefCnt >= 1) and (RefCnt <= (1 shl 24)))) then Exit;
    if Len = 0 then Exit('[]');
    var ElemSize: Integer;
    if not DebugInfo.GetTypeSize(ElemType, ElemSize) or (ElemSize <= 0) then
      Exit(Format('%s[%d]', [ElemType, Len]));   // unknown stride: shape only
    var Shown := Len;
    if Shown > MAX_PREVIEW then Shown := MAX_PREVIEW;
    var Parts: TArray<string>;
    SetLength(Parts, Shown);
    for var I := 0 to Shown - 1 do begin
      var Elem := Default(TLocalValue);
      Elem.TypeHint := ElemType;
      Elem.Kind     := lkLocal;
      Elem.Address  := DataPtr + UInt64(I) * UInt64(ElemSize);
      Elem.RawValue := 0;
      Elem.ValueValid := Debugger.ReadProcessMemoryAt(Elem.Address,
        @Elem.RawValue, Min(ElemSize, 8));
      var ES := FormatLocalValue(Elem);
      // Drop the `  (0xNN)` hex annotation so the preview stays compact.
      var Cut := Pos('  (', ES);
      if Cut > 0 then ES := Copy(ES, 1, Cut - 1);
      Parts[I] := ES;
    end;
    Result := '[' + string.Join(', ', Parts);
    if Len > Shown then
      Result := Result + Format(', …(%d total)', [Len]);
    Result := Result + ']';
  end;

begin
  // Register-allocated local. The value lives in a CPU register at
  // the current PC; we don't yet read the per-thread context register
  // table (Borland's RegId mapping needs verification), so just
  // surface the register tag plus the declared type so the user sees
  // the symbol exists even when its concrete value is unavailable.
  if V.RegId > 0 then begin
    if V.TypeHint <> '' then
      Exit(Format('<register $%x of %s>', [V.RegId, V.TypeHint]));
    Exit(Format('<register $%x>', [V.RegId]));
  end;
  if not V.ValueValid then
    Exit('<read failed>');

  // Variant is a 24-byte TVarData record. On Win64 the ABI passes
  // every variant parameter by reference (the slot holds a pointer to
  // the caller's TVarData); in-body Variant locals live inline at the
  // negative RBP offset. CollectLocalsForFrame promotes Variant
  // parameters to lkVarParam so the dispatch here stays simple:
  //   lkVarParam  -> indirect (slot is a pointer to TVarData).
  //   lkLocal     -> direct (slot IS the 24-byte TVarData).
  // Variant, OleVariant, TVarData, AND any distinct alias (`type NX = type
  // Variant`). Resolve the KIND so an alias is decoded, not rendered as the raw
  // TVarData VType word (258 for a varUString). TVarData is matched by name
  // because it is a record, not a variant kind.
  if (V.TypeHint = 'TVarData') or
     ((DebugInfo <> nil) and (DebugInfo.LookupTypeKind(V.TypeHint) = TK_VARIANT)) or
     SameText(V.TypeHint, 'Variant') or SameText(V.TypeHint, 'OleVariant') then begin
    if V.Kind = lkVarParam then
      Exit(FormatVariantAt(V.RawValue))
    else
      Exit(FormatVariantAt(V.Address));
  end;
  // Auto-recovery for Variant locals mis-typed by the RSM compiler as a
  // primitive. Two complementary signals are used:
  //
  //   (a) Stack-slot size. The compiler reserves 24 bytes for a Variant
  //       on Win64 and 2/4/8 bytes for the small integer types the RSM
  //       might claim. When TypeHint is one of the small-int aliases
  //       but the slot is at least 24 bytes, treat the local as a
  //       Variant unconditionally -- there is no integer family that
  //       gets a 24-byte slot. This is the only signal that recovers
  //       a freshly-initialised <empty> Variant (24 zero bytes look
  //       identical to a zeroed integer in memory, so a byte-pattern
  //       check cannot distinguish them).
  //
  //   (b) Strict memory pattern (LooksLikeVariantAt). Used when slot
  //       size is unavailable (top-of-stack frames, address not in the
  //       locals list) or smaller than 24. Whitelists only the base
  //       types whose payload is strong enough to distinguish from a
  //       same-named integer field.
  if (V.Address <> 0) and (V.Kind = lkLocal) and
     ((V.TypeHint = '') or
      SameText(V.TypeHint, 'Byte')     or SameText(V.TypeHint, 'ShortInt') or
      SameText(V.TypeHint, 'Word')     or SameText(V.TypeHint, 'SmallInt') or
      SameText(V.TypeHint, 'Cardinal') or SameText(V.TypeHint, 'LongWord') or
      SameText(V.TypeHint, 'Integer')  or SameText(V.TypeHint, 'LongInt')  or
      SameText(V.TypeHint, 'UInt16')   or SameText(V.TypeHint, 'Int16')    or
      SameText(V.TypeHint, 'UInt32')   or SameText(V.TypeHint, 'Int32')) then begin
    // Parameter slot (positive RbpOffset): the 8-byte slot contains
    // a POINTER to the caller's TVarData -- SampleApp-style RSM mis-tag
    // surfaces variants as SmallInt / Integer / etc. The narrow
    // TypeHint caused LocalReadSize() to truncate V.RawValue to 2 or
    // 4 bytes, so re-read the full 8-byte slot here before treating
    // it as a pointer.
    if V.RbpOffset > 0 then begin
      var Ptr: UInt64 := 0;
      if Debugger.ReadProcessMemoryAt(V.Address, @Ptr, 8) and
         (Ptr >= 65536) and LooksLikeVariantAt(Ptr) then
        Exit(FormatVariantAt(Ptr));
    end;
    // In-body local: slot IS the TVarData (24 bytes at slot address).
    //
    // Size alone is not enough. A big local is not necessarily a Variant, and
    // an INDEXED element inherits the address of the local it starts in: the
    // first element of `MStatic: array[0..2, 0..2] of Integer` shares its
    // address with the whole 36-byte array, so `MStatic[0,0]` -- a plain zero --
    // was converted and displayed as `<empty>`. Require the bytes to actually
    // look like a TVarData as well. A genuinely mis-tagged EMPTY Variant is 24
    // zero bytes, which still passes; an array of 0,1,2,10,11,... does not,
    // because its reserved words are non-zero.
    if (SlotSizeAt(V.Address) >= 24) and LooksLikeVariantAt(V.Address) then
      Exit(FormatVariantAt(V.Address));
    // Strict pattern recovery, used ONLY when slot size is genuinely
    // unknown (SlotSizeAt = 0) AND the local has no concrete type hint.
    // With a non-empty narrow integer hint, trust the type -- otherwise
    // an Integer value of 1 in a frame with zeroed neighbour locals
    // matches the varNull TVarData signature ($0001 + zero reserved +
    // zero payload) and surfaces as `<null>`. Observed in SampleApp nested
    // CreateNodes (CurrentLevel := 1 next to uninitialised pointers).
    if (V.TypeHint = '') and (SlotSizeAt(V.Address) = 0) and
       LooksLikeVariantAt(V.Address) then
      Exit(FormatVariantAt(V.Address));
  end;

  // ShortString is an INLINE value type: byte[0] is the length, followed
  // by that many AnsiChars, all living at the slot address (not a pointer
  // to a heap buffer like long strings). Read it straight from V.Address.
  if SameText(V.TypeHint, 'ShortString') and (V.Address <> 0) and
     (Debugger <> nil) then begin
    var LenByte: Byte := 0;
    if Debugger.ReadProcessMemoryAt(V.Address, @LenByte, 1) then begin
      if LenByte = 0 then
        Exit('''''');
      var Buf: TBytes;
      SetLength(Buf, LenByte);
      if Debugger.ReadProcessMemoryAt(V.Address + 1, @Buf[0], LenByte) then begin
        var S := '';
        for var B in Buf do
          S := S + Char(B);   // ShortString is single-byte ANSI
        Exit(Format('''%s''', [S]));
      end;
    end;
  end;

  // Strings in Delphi are pointer-sized handles to their character buffer.
  // The stack slot holds the pointer directly (not a pointer-to-pointer).
  var StrFmt := FormatStringByPointer(V.RawValue, V.TypeHint);
  if (V.Kind = lkLocal) and (StrFmt <> '') then
    Exit(StrFmt);

  if V.Kind = lkVarParam then begin
    if V.DerefValid then begin
      // The stack slot is a pointer to the real value. Format the deref'd value.
      var Inner := FormatStringByPointer(V.DerefValue, V.TypeHint);
      if Inner <> '' then
        Exit(Format('%s  (param via 0x%x)', [Inner, V.RawValue]));
      // `out X: T` / `var X: T` parameters arrive tagged `^T` by TD32.
      // Strip the leading `^` so FormatTyped sees the inner primitive
      // (Integer, Boolean, ...) and renders the deref'd value with the
      // right width / sign instead of falling through to the generic
      // Int64 fallback.
      var InnerType := V.TypeHint;
      if (Length(InnerType) >= 2) and (InnerType[1] = '^') then
        InnerType := Copy(InnerType, 2, MaxInt);
      Exit(Format('%s  (param via 0x%x)',
        [FormatTyped(V.DerefValue, InnerType), V.RawValue]));
    end;
    Exit(Format('@0x%x (deref failed)', [V.RawValue]));
  end;

  // Dynamic-array local: render in Pascal `[...]` notation. An empty (nil)
  // array shows `[]` instead of `0  (0x0)`; a live one previews its elements
  // instead of surfacing the raw data pointer as a giant integer. Restricted
  // to body locals (lkLocal): var/out `^T` parameters were handled above.
  if V.Kind = lkLocal then begin
    var ElemType := DynArrayElemType(V.TypeHint);
    if ElemType <> '' then begin
      var DynStr := FormatDynArrayLocal(V.RawValue, ElemType);
      if DynStr <> '' then
        Exit(DynStr);
      // Empty string => not a live dyn-array header; fall through to the
      // normal pointer formatting (genuine typed pointer).
    end;
  end;

  // Enum / set display via RSM TypeInfo metadata.
  if (V.TypeHint <> '') and (Debugger <> nil) then begin
    var EnumInfo: TRsmEnumInfo;
    if Debugger.LookupEnumInfo(V.TypeHint, EnumInfo) then begin
      if EnumInfo.Kind = 3 then begin // tkEnumeration
        // Mask to the enum's REAL storage width (Delphi packs 1 byte unless a
        // member ordinal exceeds 255, then 2, then 4). A fixed $FF aliased every
        // ordinal 256..511 down by 256 and returned a WRONG member name -- e260
        // was displayed as e4, a plausible but different member.
        var Mask: UInt64 := $FF;
        if EnumInfo.MaxValue > 65535 then Mask := $FFFFFFFF
        else if EnumInfo.MaxValue > 255 then Mask := $FFFF;
        var Ord_ := Integer(V.RawValue and Mask) - EnumInfo.MinValue;
        if (Ord_ >= 0) and (Ord_ < Length(EnumInfo.Names)) then
          Exit(EnumInfo.Names[Ord_]);
      end else if EnumInfo.Kind = 6 then begin // tkSet
        // Member names + MinValue may come inline with the set info (TD32
        // populates them from the base enum) or via a second lookup on
        // BaseTypeName (RSM). Prefer inline.
        var Names:    TArray<string> := EnumInfo.Names;
        var MinV:     Integer        := EnumInfo.MinValue;
        if Length(Names) = 0 then begin
          var BaseInfo: TRsmEnumInfo;
          if (EnumInfo.BaseTypeName <> '') and
             Debugger.LookupEnumInfo(EnumInfo.BaseTypeName, BaseInfo) and
             (BaseInfo.Kind = 3) then begin
            Names := BaseInfo.Names;
            MinV  := BaseInfo.MinValue;
          end;
        end;
        if Length(Names) > 0 then begin
          // The set's real storage width: 1..32 bytes. Declared type size is
          // authoritative; else derive it from the highest member ordinal. A
          // fixed 8 lost every member past bit 63 (e.g. `set of AnsiChar`, 32
          // bytes). For a wider-than-8 set the bytes are read from V.Address.
          var ByteWidth: Integer := 0;
          var DeclSz: Integer;
          if (DebugInfo <> nil) and DebugInfo.GetTypeSize(V.TypeHint, DeclSz) and (DeclSz > 0) then
            ByteWidth := DeclSz
          else
            ByteWidth := (EnumInfo.MaxValue div 8) + 1;
          Exit(DecodeSetMembers(V.RawValue, V.Address, ByteWidth, Names, MinV));
        end;
      end;
    end;
  end;

  Result := FormatTyped(V.RawValue, V.TypeHint);
end;

{$Q+}
{$R+}

end.
