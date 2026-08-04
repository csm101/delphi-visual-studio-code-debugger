unit RsmDecoders;

// Pure helpers extracted from RsmFileReader.pas. Each function works on a
// raw `PByte + DataSize` buffer and has no dependency on TRsmFile state, so
// they're easy to unit-test and reuse across the parse pipeline.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  DebugInfoTypes;

// ----- Class-member ($2C/$2E/$31) record helpers -----

function ClassMember_IsMemberTag(B: Byte): Boolean; inline;

// Scan forward for the $FF record terminator. RecLen counts the tag byte
// through (and including) the $FF. Cap at 512 bytes -- generous enough for
// the longest property records observed on real RSMs.
function ClassMember_FindRecordEnd(Data: PByte; DataSize: Int64;
  StartOff: Int64; out RecLen: Integer): Boolean;

// LSB-VLE TypeId at At. LSB=0 -> 1-byte typeId. LSB=1 -> 2-byte typeId.
function ClassMember_ReadTypeIdVLE(Data: PByte; DataSize, At: Int64;
  out TypeId, BytesUsed: Integer): Boolean;

// LSB-VLE field offset at At (same encoding as local-var RBP offsets):
//   byte0 LSB = 0 -> 1 byte,  value = byte0 shr 1            (offset <= 127)
//   byte0 LSB = 1 -> 2 bytes, value = (byte0|byte1 shl 8) shr 2
// Field offsets are non-negative, so the SAR collapses to a logical shift.
// The old single-byte `div 2` truncated any field past offset 127 (which
// the compiler emits in the 2-byte form) to garbage.
function ClassMember_ReadOffsetVLE(Data: PByte; DataSize, At: Int64;
  out Offset, BytesUsed: Integer): Boolean;

// Decode one $2C/$2E/$31 record at Off. Returns False on shape mismatch.
function ClassMember_TryDecode(Data: PByte; DataSize, Off: Int64;
  out M: TClassMember): Boolean;

// ----- Per-unit anchor lookup -----

// Sorted-by-offset list of (anchor offset, unit name). Binary search returns
// the unit whose section contains the given file offset.
function FindOwningUnit(Anchors: TList<TPair<Int64, string>>;
  Off: Int64): string;

// Decide whether a candidate member record belongs to a class, given the unit
// that owns the class declaration and the unit that owns the member record.
//
// Class-member records ($2C/$2E/$31) are grouped only by the LOW 16 BITS of
// the owning class's TypeId. On large targets (> 65536 RSM types) two unrelated
// classes can share those low 16 bits, so a hash-keyed lookup pulls in foreign
// members (e.g. TObjectList.FOwnsObjects leaking into TApplication). Members of
// a class are emitted inside that class's unit section, so the owning unit
// disambiguates the collision. When either unit is unknown the member is kept
// (conservative: incomplete anchor coverage must not hide real members).
function MemberMatchesClassUnit(const ClassUnit, MemberUnit: string): Boolean;

// Resolve TypeId against the owning unit's per-unit $66 imports list with
// the EXE-global FUserTypes as a fallback. Only even (table-indexed) typeIds
// are handled here; module-local odd typeIds go through TRsmFile.LookupTypeName.
function ResolveTypeNameForUnit(const UnitName: string; TypeId: Integer;
  const UnitImports, FallbackGlobal: TArray<string>): string;

// ----- Sidecar stream helpers (UTF-8 length-prefixed strings) -----

procedure SidecarWriteStr(F: TStream; const S: string);
function  SidecarReadStr(F: TStream): string;
procedure SidecarWriteStrArr(F: TStream; const Arr: TArray<string>);
function  SidecarReadStrArr(F: TStream): TArray<string>;
// Raises EReadError when a decoded element count exceeds what the remaining
// bytes could hold. Guards every SetLength/loop driven by a value read from the
// sidecar so a corrupt/stale file fails fast instead of allocating gigabytes.
procedure SidecarGuardCount(F: TStream; N: UInt64; MinBytesPerElem: UInt64 = 1);

implementation

function ClassMember_IsMemberTag(B: Byte): Boolean;
begin
  Result := (B = $2C) or (B = $2E) or (B = $31);
end;

function ClassMember_FindRecordEnd(Data: PByte; DataSize: Int64;
  StartOff: Int64; out RecLen: Integer): Boolean;
begin
  Result := False;
  if StartOff + 1 >= DataSize then Exit;
  var Cur := StartOff + 2 + Data[StartOff + 1];
  var Limit := StartOff + 512;
  if Limit > DataSize then Limit := DataSize;
  while Cur < Limit do begin
    if Data[Cur] = $FF then begin
      RecLen := Integer(Cur - StartOff + 1);
      Exit(True);
    end;
    Inc(Cur);
  end;
end;

function ClassMember_ReadTypeIdVLE(Data: PByte; DataSize, At: Int64;
  out TypeId, BytesUsed: Integer): Boolean;
begin
  Result := False;
  if At >= DataSize then Exit;
  var B := Data[At];
  // Width is selected by the low bits of byte0 (confirmed against a controlled
  // target with 17000 named types so typeIds cross the 16-bit boundary):
  //   bit0 = 0            -> 1 byte,  typeId = B
  //   bit0 = 1, bit1 = 0  -> 2 bytes, typeId = B | B2<<8           (direct)
  //   bit0 = 1, bit1 = 1  -> 3 bytes, typeId = (B|B2<<8|B3<<16) shr 1
  // The 3-byte form holds (typeId*2+1); e.g. T16129 (typeId 65537) encodes as
  // `03 00 02` = $020003, >>1 = 65537. Reading only 2 bytes truncated it to 3,
  // which then collided in the global typeId->name map on large modules.
  // Returns the RAW little-endian VLE value (the caller derives the
  // import-table index as `raw shr 1`; the raw value is also the key for the
  // class-hash / FTypeIdToName fallback used by local class references).
  if (B and 1) = 0 then begin
    TypeId    := B;
    BytesUsed := 1;
  end else if (B and 2) = 0 then begin
    if At + 1 >= DataSize then Exit;
    TypeId    := B or (Integer(Data[At + 1]) shl 8);
    BytesUsed := 2;
  end else begin
    if At + 2 >= DataSize then Exit;
    TypeId    := B or (Integer(Data[At + 1]) shl 8) or
                 (Integer(Data[At + 2]) shl 16);
    BytesUsed := 3;
  end;
  Result := True;
end;

function ClassMember_ReadOffsetVLE(Data: PByte; DataSize, At: Int64;
  out Offset, BytesUsed: Integer): Boolean;
begin
  Result := False;
  if At >= DataSize then Exit;
  var B := Data[At];
  if (B and 1) = 0 then begin
    Offset    := B shr 1;
    BytesUsed := 1;
  end else begin
    if At + 1 >= DataSize then Exit;
    Offset    := (B or (Integer(Data[At + 1]) shl 8)) shr 2;
    BytesUsed := 2;
  end;
  Result := True;
end;

function ClassMember_TryDecode(Data: PByte; DataSize, Off: Int64;
  out M: TClassMember): Boolean;
begin
  Result := False;
  M := Default(TClassMember);
  if (Off >= DataSize) or not ClassMember_IsMemberTag(Data[Off]) then Exit;
  if Off + 1 >= DataSize then Exit;
  var NameLen := Integer(Data[Off + 1]);
  if (NameLen < 1) or (NameLen > 63) then Exit;
  var RecLen: Integer;
  if not ClassMember_FindRecordEnd(Data, DataSize, Off, RecLen) then Exit;
  var After := Off + 2 + NameLen;
  if After + 1 >= DataSize then Exit;
  SetString(M.Name, PAnsiChar(Data + Off + 2), NameLen);
  M.Visibility := Data[After + 1];
  case Data[Off] of
    $2C: begin
      M.Kind := cmkField;
      if After + 7 > Off + RecLen then Exit;
      var TypeIdBytes: Integer;
      if not ClassMember_ReadTypeIdVLE(Data, DataSize, After + 3,
                                       M.TypeId, TypeIdBytes) then Exit;
      M.ImportTypeId := M.TypeId;
      if TypeIdBytes >= 2 then
        M.ImportTypeId := M.TypeId shr 1;
      var OffsetBytes: Integer;
      if not ClassMember_ReadOffsetVLE(Data, DataSize, After + 3 + TypeIdBytes,
                                       M.FieldOffset, OffsetBytes) then Exit;
      // Field hash marker: `9C <tag> hash16`. The tag byte after $9C varies
      // ($01 / $09 on small targets, but also $17 and others on real VCL --
      // e.g. TApplication.FHintColor is `9C 17 B9 8D`). Gating on a fixed tag
      // set silently dropped such fields, which then broke property binding
      // (HintColor read FHintColor could not find its backing field). Take the
      // first $9C after the offset bytes as the marker regardless of tag; the
      // hash is always the two bytes following the tag.
      for var I := After + 3 + TypeIdBytes + OffsetBytes to Off + RecLen - 4 do
        if Data[I] = $9C then begin
          M.Hash := Data[I + 2] or (Data[I + 3] shl 8);
          Exit(True);
        end;
    end;
    $2E: begin
      M.Kind := cmkMethod;
      if After + 6 > Off + RecLen then Exit;
      for var I := After + 3 to Off + RecLen - 3 do
        if Data[I] = $E2 then begin
          M.Hash := Data[I + 1] or (Data[I + 2] shl 8);
          Exit(True);
        end;
    end;
    $31: begin
      M.Kind := cmkProperty;
      // Byte before Visibility carries $40 for the class's `default` array
      // property -- the one `Obj[X]` means. Bit-tested rather than compared,
      // because the other bits of this byte are not understood and a future
      // one must not turn a `default` into a false negative.
      M.IsDefaultProperty := (Data[After] and $40) <> 0;
      if After + 7 > Off + RecLen then Exit;
      var TypeIdBytes: Integer;
      if not ClassMember_ReadTypeIdVLE(Data, DataSize, After + 3,
                                       M.TypeId, TypeIdBytes) then Exit;
      M.ImportTypeId := M.TypeId;
      if TypeIdBytes >= 2 then
        M.ImportTypeId := M.TypeId shr 1;
      for var I := After + 3 + TypeIdBytes to Off + RecLen - 3 do
        if Data[I] = $80 then begin
          M.GetterHash := Data[I + 1] or (Data[I + 2] shl 8);
          Exit(True);
        end;
    end;
  end;
end;

function FindOwningUnit(Anchors: TList<TPair<Int64, string>>;
  Off: Int64): string;
var
  Lo, Hi, Mid: Integer;
begin
  Result := '';
  if Anchors.Count = 0 then Exit;
  Lo := 0;
  Hi := Anchors.Count - 1;
  while Lo <= Hi do begin
    Mid := (Lo + Hi) div 2;
    if Anchors[Mid].Key <= Off then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  if Hi >= 0 then
    Result := Anchors[Hi].Value;
end;

function MemberMatchesClassUnit(const ClassUnit, MemberUnit: string): Boolean;
begin
  if ClassUnit = '' then Exit(True);
  if MemberUnit = '' then Exit(True);
  Result := SameText(ClassUnit, MemberUnit);
end;

function ResolveTypeNameForUnit(const UnitName: string; TypeId: Integer;
  const UnitImports, FallbackGlobal: TArray<string>): string;
begin
  Result := '';
  if TypeId <= 0 then Exit;
  if (TypeId and 1) <> 0 then Exit;
  var Idx: Integer := (TypeId div 2) - 1;
  if (Idx >= 0) and (Idx < Length(UnitImports)) and (UnitImports[Idx] <> '') then
    Exit(UnitImports[Idx]);
  // The index is meaningful ONLY inside the unit's own import list. Once it
  // runs past the end of that list, indexing ANOTHER table with the same
  // number yields an unrelated name -- and the reader has no way to notice,
  // because a name came back.
  //
  // This is the measured "past the import table everything is wrong" failure.
  // On a 797 MB RSM it produced `AOwner: ByteBool` for a `TComponent`
  // parameter and `iPostIt: IEnumerator<...>` for an interface, both plausible
  // and both fabricated. Returning '' lets a better provider answer, or lets
  // the caller say it does not know.
  //
  // The global table is still consulted when the unit HAS NO import list at
  // all: there the index was never a per-unit index, so there is nothing to
  // run past, and this is the pre-existing behaviour rather than the defect.
  if Length(UnitImports) > 0 then
    Exit;
  if (Idx >= 0) and (Idx < Length(FallbackGlobal)) and (FallbackGlobal[Idx] <> '') then
    Result := FallbackGlobal[Idx];
end;

// Rejects a count/length that can't possibly fit in the bytes left in the
// stream. A misaligned read (stale/corrupt sidecar) otherwise yields a garbage
// count that drives a multi-gigabyte SetLength -> minutes of paging before the
// inevitable read failure. Each element consumes at least one byte, so a valid
// count never exceeds the remaining byte span. Raising here fails the whole
// sidecar load fast and falls back to the (sub-second) cold parse.
procedure SidecarGuardCount(F: TStream; N: UInt64; MinBytesPerElem: UInt64 = 1);
begin
  if N > UInt64(F.Size - F.Position) div MinBytesPerElem then
    raise EReadError.Create('sidecar count out of range');
end;

// Sentinel in the 16-bit length slot: the real byte count follows as a UInt32.
//
// The length used to be a plain `Len: UInt16 := Length(Bytes)`, which TRUNCATES
// silently at 64 KB: the writer then emitted more bytes than the length it had
// just written, the reader resynchronised at the wrong offset, and every later
// field of the sidecar decoded as garbage -- with nothing to detect it, because
// the file still parsed and the magic still matched. The escape below makes the
// truncation impossible instead of merely unlikely.
//
// The on-disk format is deliberately NOT versioned for this: any string shorter
// than 64 KB is encoded exactly as before, and no sidecar written by the old
// code can contain the sentinel except for a string of exactly 65535 bytes,
// which no symbol name, type name or unit name in an .rsm/.dcp comes near. So
// RSM_SIDECAR_MAGIC is unchanged and existing .idx files stay valid.
const
  SIDECAR_LONG_STR_MARK = High(UInt16);

procedure SidecarWriteStr(F: TStream; const S: string);
begin
  var Bytes := TEncoding.UTF8.GetBytes(S);
  var ByteCount: UInt32 := Length(Bytes);
  if ByteCount >= SIDECAR_LONG_STR_MARK then begin
    var Mark: UInt16 := SIDECAR_LONG_STR_MARK;
    F.WriteBuffer(Mark, 2);
    F.WriteBuffer(ByteCount, 4);
  end
  else begin
    var ShortLen: UInt16 := UInt16(ByteCount);
    F.WriteBuffer(ShortLen, 2);
  end;
  if ByteCount > 0 then
    F.WriteBuffer(Bytes[0], ByteCount);
end;

function SidecarReadStr(F: TStream): string;
begin
  var ShortLen: UInt16;
  F.ReadBuffer(ShortLen, 2);
  var ByteCount: UInt32 := ShortLen;
  if ShortLen = SIDECAR_LONG_STR_MARK then
    F.ReadBuffer(ByteCount, 4);
  if ByteCount = 0 then Exit('');
  SidecarGuardCount(F, ByteCount);
  var Bytes: TBytes;
  SetLength(Bytes, ByteCount);
  F.ReadBuffer(Bytes[0], ByteCount);
  Result := TEncoding.UTF8.GetString(Bytes);
end;

procedure SidecarWriteStrArr(F: TStream; const Arr: TArray<string>);
var N: UInt32;
begin
  N := Length(Arr);
  F.WriteBuffer(N, 4);
  for var I := 0 to High(Arr) do
    SidecarWriteStr(F, Arr[I]);
end;

function SidecarReadStrArr(F: TStream): TArray<string>;
var N: UInt32;
begin
  F.ReadBuffer(N, 4);
  SidecarGuardCount(F, N, 2); // each element is at least a 2-byte length prefix
  SetLength(Result, N);
  for var I := 0 to Integer(N) - 1 do
    Result[I] := SidecarReadStr(F);
end;

end.
