unit ValueEncoders;

// Frontend-neutral value encoders for setVariable / write-back. Take a textual
// value plus the target Delphi type and produce the raw bytes (at the type's
// TRUE storage width) ready to write into the variable's slot. Shared by the
// TDebugSession core write path and any frontend that needs the same encoding.
//
// CRITICAL: the enum/set encoders preserve the exact storage width (1/2/4 bytes)
// of the target type. A wrong width clobbers the fields that follow a 1- or
// 2-byte enum/set slot, so the width derivation here must never be "guessed"
// larger than the type actually occupies.

interface

uses
  System.SysUtils, DebugInfoSet, DebugInfoTypes;

// Parses a numeric literal (decimal, 0xHEX or $HEX) into a 64-bit value.
function TryStrToUInt64Lit(const S: string; out V: UInt64): Boolean;

// Returns True if TypeHint is one of the Delphi string types we know how to
// allocate in the debuggee.
function IsStringType(const TypeHint: string): Boolean;

// Removes a single layer of surrounding quotes (single or double) from S.
function StripStringQuotes(const S: string): string;

// Type-aware encoder: takes a textual value plus the target Delphi type and
// produces (Bytes, Size) ready to write into the variable's slot. Returns
// False with ErrMsg set when the value can't be encoded. ErrMsg = the sentinel
// '__STRING_PATH__' signals the caller to use the string-allocation write path
// instead (strings need allocation in the debuggee, not just byte encoding).
function EncodeValueForType(const ValStr, TypeHint: string;
  out Buf: array of Byte; out Size: Integer; out ErrMsg: string): Boolean;

// Resolves an enum value name (e.g. `geC`) against a target enum type and
// encodes the ordinal at the enum's storage width. Returns False when the
// literal is not a member of TypeHint's enum type.
function TryEncodeEnumByName(DebugInfo: TDebugInfoSet;
  const ValStr, TypeHint: string;
  out Buf: array of Byte; out Size: Integer): Boolean;

// Numeric assignment to an enum- or set-typed target, encoded at the type's
// TRUE storage width (set value = raw bitmask). The generic EncodeValueForType
// unknown-type fallback writes 8 bytes, which clobbers whatever follows a
// 1/2-byte enum/set slot.
function TryEncodeEnumOrdinal(DebugInfo: TDebugInfoSet;
  const ValStr, TypeHint: string;
  out Buf: array of Byte; out Size: Integer): Boolean;

implementation

function TryStrToUInt64Lit(const S: string; out V: UInt64): Boolean;
var
  Code: Integer;
  Int: UInt64;
begin
  Result := False;
  V := 0;
  if S = '' then
    Exit;
  if (Length(S) > 2) and (S[1] = '0') and ((S[2] = 'x') or (S[2] = 'X')) then begin
    Val('$' + Copy(S, 3, MaxInt), Int, Code);
    if Code <> 0 then Exit;
    V := Int;
    Exit(True);
  end;
  if S[1] = '$' then begin
    Val(S, Int, Code);
    if Code <> 0 then Exit;
    V := Int;
    Exit(True);
  end;
  Val(S, Int, Code);
  if Code <> 0 then Exit;
  V := Int;
  Result := True;
end;

function IsStringType(const TypeHint: string): Boolean;
begin
  Result := (TypeHint = 'UnicodeString') or (TypeHint = 'string') or
            (TypeHint = 'WideString')    or (TypeHint = 'AnsiString') or
            (TypeHint = 'RawByteString') or (TypeHint = 'UTF8String');
end;

function StripStringQuotes(const S: string): string;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and
     (((Result[1] = '''') and (Result[Length(Result)] = '''')) or
      ((Result[1] = '"')  and (Result[Length(Result)] = '"'))) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

// Tries the standard "yyyy-mm-dd[ hh:nn:ss[.zzz]]" form (and time-only /
// date-only variants) with an invariant (period-decimal) locale.
function TryParseDateTime(const S: string; out DT: TDateTime): Boolean;
var
  FS: TFormatSettings;
begin
  // Use ISO-style settings independent of locale.
  FS := TFormatSettings.Create;
  FS.DateSeparator   := '-';
  FS.TimeSeparator   := ':';
  FS.ShortDateFormat := 'yyyy-mm-dd';
  FS.LongTimeFormat  := 'hh:nn:ss.zzz';
  FS.DecimalSeparator := '.';
  Result := TryStrToDateTime(Trim(S), DT, FS);
  if not Result then
    Result := TryStrToDate(Trim(S), DT, FS);
  if not Result then
    Result := TryStrToTime(Trim(S), DT, FS);
end;

function TryParseFloat(const S: string; out V: Double): Boolean;
var
  FS: TFormatSettings;
begin
  FS := TFormatSettings.Create;
  FS.DecimalSeparator := '.';
  Result := TryStrToFloat(Trim(S), V, FS);
  if not Result then begin
    // Also accept comma-decimal forms (locale-tolerant).
    FS.DecimalSeparator := ',';
    Result := TryStrToFloat(Trim(S), V, FS);
  end;
end;

function EncodeValueForType(const ValStr, TypeHint: string;
  out Buf: array of Byte; out Size: Integer; out ErrMsg: string): Boolean;
var
  U: UInt64;
  D: Double;
  DT: TDateTime;
  Trimmed: string;
begin
  Result  := False;
  ErrMsg  := '';
  Size    := 0;
  FillChar(Buf[0], Length(Buf), 0);
  Trimmed := Trim(ValStr);

  // Strings are handled by the caller via AllocateRemoteString /
  // SetStringVariable -- they need allocation in the debuggee process, not
  // just byte encoding.
  if IsStringType(TypeHint) then begin
    ErrMsg := '__STRING_PATH__';
    Exit;
  end;

  // Booleans.
  if (TypeHint = 'Boolean') or (TypeHint = 'ByteBool') then begin
    if SameText(Trimmed, 'true') then U := 1
    else if SameText(Trimmed, 'false') then U := 0
    else if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not a Boolean (use true/false or 0/1)', [ValStr]);
      Exit;
    end;
    Buf[0] := Byte(U);
    Size   := 1;
    Exit(True);
  end;
  if TypeHint = 'WordBool' then begin
    if SameText(Trimmed, 'true') then U := UInt64(-1) and $FFFF
    else if SameText(Trimmed, 'false') then U := 0
    else if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not a WordBool', [ValStr]);
      Exit;
    end;
    PWord(@Buf[0])^ := Word(U);
    Size := 2;
    Exit(True);
  end;
  if TypeHint = 'LongBool' then begin
    if SameText(Trimmed, 'true') then U := UInt64(-1) and $FFFFFFFF
    else if SameText(Trimmed, 'false') then U := 0
    else if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not a LongBool', [ValStr]);
      Exit;
    end;
    PCardinal(@Buf[0])^ := Cardinal(U);
    Size := 4;
    Exit(True);
  end;

  // Date/time types: accept ISO-style date/time/datetime literals or a raw
  // float (for direct manipulation). Stored as 8-byte Double.
  if (TypeHint = 'TDateTime') or (TypeHint = 'TDate') or (TypeHint = 'TTime') then begin
    if TryParseDateTime(Trimmed, DT) then
      D := DT
    else if not TryParseFloat(Trimmed, D) then begin
      ErrMsg := Format('"%s" is not a date/time (try yyyy-mm-dd hh:nn:ss.zzz) ' +
                       'or a numeric value', [ValStr]);
      Exit;
    end;
    PDouble(@Buf[0])^ := D;
    Size := 8;
    Exit(True);
  end;

  // Floating-point types.
  if TypeHint = 'Single' then begin
    if not TryParseFloat(Trimmed, D) then begin
      ErrMsg := Format('"%s" is not a number', [ValStr]); Exit;
    end;
    PSingle(@Buf[0])^ := D;
    Size := 4;
    Exit(True);
  end;
  if (TypeHint = 'Double') or (TypeHint = 'Real') or (TypeHint = 'Extended') then begin
    if not TryParseFloat(Trimmed, D) then begin
      ErrMsg := Format('"%s" is not a number', [ValStr]); Exit;
    end;
    PDouble(@Buf[0])^ := D;
    Size := 8;
    Exit(True);
  end;
  if TypeHint = 'Currency' then begin
    if not TryParseFloat(Trimmed, D) then begin
      ErrMsg := Format('"%s" is not a number', [ValStr]); Exit;
    end;
    PInt64(@Buf[0])^ := Round(D * 10000.0);
    Size := 8;
    Exit(True);
  end;

  // Char/AnsiChar -- accept 'x' or numeric.
  if (TypeHint = 'AnsiChar') or (TypeHint = 'Byte') or (TypeHint = 'ShortInt') then begin
    if (Length(Trimmed) = 3) and (Trimmed[1] = '''') and (Trimmed[3] = '''') then
      U := Byte(Trimmed[2])
    else if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not a byte/char value', [ValStr]); Exit;
    end;
    Buf[0] := Byte(U);
    Size := 1;
    Exit(True);
  end;
  if (TypeHint = 'Char') or (TypeHint = 'WideChar') or (TypeHint = 'Word') or
     (TypeHint = 'SmallInt') then begin
    if (Length(Trimmed) = 3) and (Trimmed[1] = '''') and (Trimmed[3] = '''') then
      U := Word(Trimmed[2])
    else if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not a 16-bit value', [ValStr]); Exit;
    end;
    PWord(@Buf[0])^ := Word(U);
    Size := 2;
    Exit(True);
  end;

  // Integer family.
  if (TypeHint = 'Integer') or (TypeHint = 'LongInt') or
     (TypeHint = 'Cardinal') or (TypeHint = 'LongWord') then begin
    if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not an integer', [ValStr]); Exit;
    end;
    PCardinal(@Buf[0])^ := Cardinal(U);
    Size := 4;
    Exit(True);
  end;
  if (TypeHint = 'Int64') or (TypeHint = 'UInt64') or
     (TypeHint = 'NativeInt') or (TypeHint = 'NativeUInt') or
     (TypeHint = 'Pointer') or (TypeHint = 'THandle') or
     (TypeHint = 'HWND') or (TypeHint = 'HDC') then begin
    if not TryStrToUInt64Lit(Trimmed, U) then begin
      ErrMsg := Format('"%s" is not a 64-bit value', [ValStr]); Exit;
    end;
    PUInt64(@Buf[0])^ := U;
    Size := 8;
    Exit(True);
  end;

  // Unknown type -- accept any 64-bit numeric value, write 8 bytes.
  if not TryStrToUInt64Lit(Trimmed, U) then begin
    ErrMsg := Format('Cannot encode "%s" for type "%s"', [ValStr, TypeHint]);
    Exit;
  end;
  PUInt64(@Buf[0])^ := U;
  Size := 8;
  Result := True;
end;

function TryEncodeEnumByName(DebugInfo: TDebugInfoSet;
  const ValStr, TypeHint: string;
  out Buf: array of Byte; out Size: Integer): Boolean;
var
  Info: TRsmEnumInfo;
  Sz, Ordinal: Integer;
  Lit: string;
begin
  Result := False;
  Size   := 0;
  if (DebugInfo = nil) or (TypeHint = '') then Exit;
  // Resolve the literal WITHIN the target type (type-scoped, so an unrelated
  // enum sharing a member name can't satisfy a mismatched write). Reuses the
  // same enum metadata the variables view decodes on read, so gapped enums
  // map correctly (ordinal = MinValue + index in Names).
  if not DebugInfo.LookupEnumInfo(TypeHint, Info) then Exit;
  if (not Info.IsValid) or (Info.Kind <> 3) then Exit;  // 3 = tkEnumeration
  Lit := Trim(StripStringQuotes(ValStr));
  Ordinal := -1;
  for var I := 0 to High(Info.Names) do
    if SameText(Info.Names[I], Lit) then begin
      Ordinal := Info.MinValue + I;
      Break;
    end;
  if Ordinal < 0 then Exit;
  // Storage width: prefer the exact size from a type provider (honours
  // {$MINENUMSIZE}/{$Zn}); fall back to Delphi's default packing rule
  // (smallest of 1/2/4 bytes that holds the value range).
  // TODO PROTOTYPE: the fallback assumes default packing; a {$Zn}-forced enum
  // whose provider reports no size would be under-sized. Real fix is to record
  // the enum's underlying-type width in TD32 LF_ENUM decode.
  if DebugInfo.GetTypeSize(TypeHint, Sz) and (Sz in [1, 2, 4]) then
    Size := Sz
  else if Info.MaxValue > 65535 then Size := 4
  else if Info.MaxValue > 255 then Size := 2
  else Size := 1;
  FillChar(Buf[0], Length(Buf), 0);
  case Size of
    1: Buf[0] := Byte(Ordinal);
    2: PWord(@Buf[0])^ := Word(Ordinal);
    4: PCardinal(@Buf[0])^ := Cardinal(Ordinal);
  end;
  Result := True;
end;

function TryEncodeEnumOrdinal(DebugInfo: TDebugInfoSet;
  const ValStr, TypeHint: string;
  out Buf: array of Byte; out Size: Integer): Boolean;
var
  Info: TRsmEnumInfo;
  Sz:   Integer;
  U:    UInt64;

  // Storage width of the enum/set target. Exact provider size when known;
  // else the Delphi default packing derived from the highest member ordinal;
  // else 0 (unknown -- caller must REFUSE rather than guess and clobber the
  // neighbouring fields).
  function StorageWidth(HighOrd: Integer): Integer;
  begin
    if Info.Kind = 6 then begin
      // SET: the slot is BYTE-GRANULAR -- exactly ceil((highOrd+1)/8) -- and is
      // NOT rounded up to 1/2/4. `set of (c0..c19)` is 3 bytes; the old rule
      // rounded that to 4 and the write then zeroed the first byte of the
      // physically ADJACENT variable (silent neighbour corruption, DAP success).
      // Any positive provider size is authoritative here, including 3/5/6/7.
      if DebugInfo.GetTypeSize(TypeHint, Sz) and (Sz > 0) and (Sz <= 8) then
        Exit(Sz);
      if HighOrd < 0  then Exit(0);
      if HighOrd > 63 then Exit(0);   // wider than a UInt64 bitmask -- refuse
      Exit((HighOrd div 8) + 1);
    end;
    // ENUM: Delphi packs an enum in 1/2/4 bytes only, so a provider size outside
    // that set is not trustworthy for an enum.
    if DebugInfo.GetTypeSize(TypeHint, Sz) and (Sz in [1, 2, 4]) then
      Exit(Sz);
    if HighOrd < 0 then
      Exit(0);
    if HighOrd > 65535 then Exit(4);
    if HighOrd > 255 then Exit(2);
    Exit(1);
  end;

begin
  Result := False;
  Size   := 0;
  if (DebugInfo = nil) or (TypeHint = '') then Exit;
  if not DebugInfo.LookupEnumInfo(TypeHint, Info) then Exit;
  if (not Info.IsValid) or not (Info.Kind in [3, 6]) then Exit; // tkEnumeration / tkSet
  if not TryStrToUInt64Lit(Trim(ValStr), U) then Exit;

  // Highest meaningful ordinal: MaxValue when the provider filled it, else
  // derived from the member-name list (set infos often carry the base enum's
  // Names but no MaxValue).
  var HighOrd := Info.MaxValue;
  if (HighOrd < Info.MinValue) or ((HighOrd = 0) and (Length(Info.Names) > 1)) then
    HighOrd := Info.MinValue + Length(Info.Names) - 1;

  if Info.Kind = 3 then begin
    // Reject ordinals outside the declared range -- mirrors the invalid-write
    // contract (DAP success:false) instead of storing a meaningless value.
    if (Int64(U) < Info.MinValue) or (Int64(U) > HighOrd) then Exit;
  end;
  Size := StorageWidth(HighOrd);
  if Size = 0 then Exit;
  // The numeric value must fit the slot (relevant for set bitmasks).
  if (Size < 8) and (U shr (Size * 8) <> 0) then begin
    Size := 0;
    Exit;
  end;
  if Size > Length(Buf) then begin
    Size := 0;
    Exit;
  end;
  FillChar(Buf[0], Length(Buf), 0);
  // Little-endian store of EXACTLY Size bytes. A `case Size of 1,2,4` could not
  // emit the 3/5/6/7-byte widths a set genuinely has -- it fell through and wrote
  // all zeros (or, with the old rounded width, 4 bytes over a 3-byte slot).
  for var I := 0 to Size - 1 do
    Buf[I] := Byte(U shr (I * 8));
  Result := True;
end;

end.
