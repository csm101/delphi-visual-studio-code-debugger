program MapSegBaseProbe;

// Determines how a Delphi MAP file's segment table must be converted into
// image RVAs, and checks the result against the PE section table of the
// matching executable.
//
// The MAP lists every address as `SSSS:offset`, where the offset is relative
// to the start of segment SSSS. Turning that into an RVA needs the segment's
// own base RVA, which the MAP states only in its first block:
//
//     Start         Length     Name       Class          (PE32)
//     0001:00401000 000F18D8H .text       CODE
//
//     Start                 Length     Name   Class      (PE32+)
//     0001:0000000000401000 0016C7B0H .text  CODE
//
// The hex width of the Start column differs between the two. This probe does
// not assume a width: it reads however many hex digits precede the next
// space, derives `LinearStart - ImageBase`, and then VERIFIES the derived
// value by looking for a PE section whose VirtualAddress equals it and whose
// name equals the MAP's Name column. That identity check is what makes the
// answer trustworthy on a platform whose constants are not known in advance.
//
// It also replays the fixed-16-hex-digit parse used by
// DebuggerCore\MapFileReader.pas (ParseSegmentTableEager) so the two can be
// compared side by side.
//
// Usage:
//   MapSegBaseProbe <image.exe|dll> <file.map> [seg:offset ...]
//
// Every input comes from the command line; nothing is hardcoded.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Generics.Collections;

type
  TPeSection = record
    Name:        string;
    VirtualAddr: UInt64;
    VirtualSize: UInt64;
  end;

  TPeInfo = record
    IsPe32Plus:  Boolean;
    ImageBase:   UInt64;
    SizeOfImage: UInt64;
    Sections:    TArray<TPeSection>;
  end;

  TMapSegment = record
    Number:      Integer;
    LinearStart: UInt64;   // as printed in the Start column
    HexDigits:   Integer;  // width of the Start column for this line
    Name:        string;   // .text / .data / ...
    SegClass:    string;   // CODE / DATA / BSS / ...
    GenericBase: UInt64;   // LinearStart - ImageBase  (width-agnostic parse)
    LegacyOk:    Boolean;  // fixed-16-digit parse accepted the line
    LegacyBase:  UInt64;   // base RVA that parse would have produced
  end;

function ReadPeInfo(const ImagePath: string): TPeInfo;
var
  Stream: TFileStream;
begin
  Result := Default(TPeInfo);
  Stream := TFileStream.Create(ImagePath, fmOpenRead or fmShareDenyNone);
  try
    var DosHeader: array[0..63] of Byte;
    if Stream.Size < 64 then
      raise Exception.Create('image too small');
    Stream.ReadBuffer(DosHeader, SizeOf(DosHeader));
    if (DosHeader[0] <> Ord('M')) or (DosHeader[1] <> Ord('Z')) then
      raise Exception.Create('not an MZ image');

    var PeOffset := PCardinal(@DosHeader[$3C])^;
    Stream.Position := PeOffset;
    var Signature: UInt32 := 0;
    Stream.ReadBuffer(Signature, 4);
    if Signature <> $00004550 then
      raise Exception.Create('missing PE signature');

    var Machine: UInt16 := 0;
    Stream.ReadBuffer(Machine, 2);
    var SectionCount: UInt16 := 0;
    Stream.ReadBuffer(SectionCount, 2);
    Stream.Position := PeOffset + 4 + 16;
    var OptionalHeaderSize: UInt16 := 0;
    Stream.ReadBuffer(OptionalHeaderSize, 2);

    var OptionalHeaderPos := Int64(PeOffset) + 4 + 20;
    Stream.Position := OptionalHeaderPos;
    var Magic: UInt16 := 0;
    Stream.ReadBuffer(Magic, 2);
    Result.IsPe32Plus := Magic = $020B;

    // ImageBase: offset $1C in PE32 (4 bytes), offset $18 in PE32+ (8 bytes).
    if Result.IsPe32Plus then begin
      Stream.Position := OptionalHeaderPos + $18;
      var Base64: UInt64 := 0;
      Stream.ReadBuffer(Base64, 8);
      Result.ImageBase := Base64;
    end else begin
      Stream.Position := OptionalHeaderPos + $1C;
      var Base32: UInt32 := 0;
      Stream.ReadBuffer(Base32, 4);
      Result.ImageBase := Base32;
    end;

    // SizeOfImage sits at optional-header offset $38 in BOTH variants.
    Stream.Position := OptionalHeaderPos + $38;
    var ImageSize: UInt32 := 0;
    Stream.ReadBuffer(ImageSize, 4);
    Result.SizeOfImage := ImageSize;

    Stream.Position := OptionalHeaderPos + OptionalHeaderSize;
    SetLength(Result.Sections, SectionCount);
    for var I := 0 to SectionCount - 1 do begin
      var Raw: array[0..39] of Byte;
      Stream.ReadBuffer(Raw, SizeOf(Raw));
      var NameBytes := '';
      for var C := 0 to 7 do begin
        if Raw[C] = 0 then Break;
        NameBytes := NameBytes + Chr(Raw[C]);
      end;
      Result.Sections[I].Name        := NameBytes;
      Result.Sections[I].VirtualSize := PCardinal(@Raw[8])^;
      Result.Sections[I].VirtualAddr := PCardinal(@Raw[12])^;
    end;
  finally
    Stream.Free;
  end;
end;

function IsHexRun(const S: string): Boolean;
begin
  if S = '' then Exit(False);
  for var C in S do
    if not CharInSet(C, ['0'..'9', 'A'..'F', 'a'..'f']) then
      Exit(False);
  Result := True;
end;

// Replays DebuggerCore\MapFileReader.pas ParseSegmentTableEager exactly:
// a fixed 16-hex-digit Start column.
function LegacyParse(const Trimmed: string; ImageBase: UInt64;
  out BaseRva: UInt64): Boolean;
begin
  BaseRva := 0;
  Result  := False;
  if Trimmed.Length < 21 then Exit;
  var ColonPos := Trimmed.IndexOf(':');
  if (ColonPos < 1) or (ColonPos > 4) then Exit;
  var SegNum := StrToIntDef('$' + Trimmed.Substring(0, ColonPos), -1);
  if SegNum <= 0 then Exit;
  if Trimmed.Length < ColonPos + 1 + 16 then Exit;
  var AddrPart := Trimmed.Substring(ColonPos + 1, 16);
  if not IsHexRun(AddrPart) then Exit;
  var NextIdx := ColonPos + 1 + 16;
  if (NextIdx < Trimmed.Length) and (Trimmed.Chars[NextIdx] <> ' ') then Exit;
  var LinearAddr := StrToInt64Def('$' + AddrPart, 0);
  if (LinearAddr = 0) or (LinearAddr < ImageBase) then Exit;
  BaseRva := LinearAddr - ImageBase;
  Result  := True;
end;

// Width-agnostic parse: read as many hex digits as actually precede the space.
function GenericParse(const Trimmed: string; out SegNum: Integer;
  out LinearStart: UInt64; out HexDigits: Integer): Boolean;
begin
  SegNum      := 0;
  LinearStart := 0;
  HexDigits   := 0;
  Result      := False;
  var ColonPos := Trimmed.IndexOf(':');
  if (ColonPos < 1) or (ColonPos > 4) then Exit;
  var SegPart := Trimmed.Substring(0, ColonPos);
  if not IsHexRun(SegPart) then Exit;
  SegNum := StrToIntDef('$' + SegPart, -1);
  if SegNum <= 0 then Exit;
  var Rest := Trimmed.Substring(ColonPos + 1);
  var Stop := 0;
  while (Stop < Rest.Length) and CharInSet(Rest.Chars[Stop], ['0'..'9', 'A'..'F', 'a'..'f']) do
    Inc(Stop);
  if Stop = 0 then Exit;
  HexDigits   := Stop;
  LinearStart := StrToInt64Def('$' + Rest.Substring(0, Stop), 0);
  Result      := True;
end;

function ReadSegmentTable(const MapPath: string; ImageBase: UInt64): TArray<TMapSegment>;
var
  Lines: TStringList;
begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(MapPath);
    for var I := 0 to Lines.Count - 1 do begin
      var Trimmed := Lines[I].Trim;
      // The first block ends at "Detailed map of segments"; stop there so the
      // per-unit detail lines (which are segment-RELATIVE) are never mistaken
      // for segment starts.
      if Trimmed.StartsWith('Detailed map of segments') then Break;
      if Trimmed.StartsWith('Line numbers for ') then Break;
      if Trimmed = '' then Continue;

      var Seg: TMapSegment;
      if not GenericParse(Trimmed, Seg.Number, Seg.LinearStart, Seg.HexDigits) then
        Continue;
      var Tokens := Trimmed.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      if Length(Tokens) < 4 then Continue;
      Seg.Name     := Tokens[High(Tokens) - 1];
      Seg.SegClass := Tokens[High(Tokens)];
      if Seg.LinearStart >= ImageBase then
        Seg.GenericBase := Seg.LinearStart - ImageBase
      else
        Seg.GenericBase := 0;
      Seg.LegacyOk := LegacyParse(Trimmed, ImageBase, Seg.LegacyBase);
      Result := Result + [Seg];
    end;
  finally
    Lines.Free;
  end;
end;

function SectionVaForName(const Pe: TPeInfo; const SectionName: string;
  out Va: UInt64): Boolean;
begin
  Va     := 0;
  Result := False;
  for var S in Pe.Sections do
    if SameText(S.Name, SectionName) then begin
      Va     := S.VirtualAddr;
      Exit(True);
    end;
end;

procedure ReportSegments(const Pe: TPeInfo; const Segments: TArray<TMapSegment>);
begin
  Writeln('MAP segment table -> RVA derivation');
  Writeln('  seg  startHex  linearStart       name      class   genericBase  peSectionVA  identity   legacy16');
  for var Seg in Segments do begin
    var SectionVa: UInt64;
    var Found   := SectionVaForName(Pe, Seg.Name, SectionVa);
    var Verdict := 'no-section';
    if Found then begin
      if SectionVa = Seg.GenericBase then
        Verdict := 'MATCH'
      else
        Verdict := 'MISMATCH';
    end;
    var LegacyText := 'SKIPPED';
    if Seg.LegacyOk then
      LegacyText := Format('$%x', [Seg.LegacyBase]);
    Writeln(Format('  %.4d %8d  %-16s  %-9s %-7s $%-10x $%-11x %-10s %s',
      [Seg.Number, Seg.HexDigits, Format('$%x', [Seg.LinearStart]), Seg.Name,
       Seg.SegClass, Seg.GenericBase, SectionVa, Verdict, LegacyText]));
  end;
end;

procedure ReportTokens(const Segments: TArray<TMapSegment>;
  const Tokens: TArray<string>);
begin
  if Length(Tokens) = 0 then Exit;
  Writeln;
  Writeln('Token resolution (`seg:offset` as printed in the MAP body)');
  for var Token in Tokens do begin
    var ColonPos := Token.IndexOf(':');
    if ColonPos < 1 then begin
      Writeln('  ', Token, ' : malformed');
      Continue;
    end;
    var SegNum := StrToIntDef('$' + Token.Substring(0, ColonPos), -1);
    var Offset := UInt64(StrToInt64Def('$' + Token.Substring(ColonPos + 1), 0));
    var GenericBase: UInt64 := 0;
    var LegacyBase:  UInt64 := 0;
    var LegacyKnown := False;
    for var Seg in Segments do
      if Seg.Number = SegNum then begin
        GenericBase := Seg.GenericBase;
        LegacyKnown := Seg.LegacyOk;
        if Seg.LegacyOk then
          LegacyBase := Seg.LegacyBase;
      end;
    var LegacyNote := '';
    if not LegacyKnown then
      LegacyNote := '  (segment base unknown to the 16-digit parse -> base 0)';
    Writeln(Format('  %-22s correct RVA=$%x   legacy RVA=$%x   delta=$%x%s',
      [Token, GenericBase + Offset, LegacyBase + Offset,
       (GenericBase + Offset) - (LegacyBase + Offset), LegacyNote]));
  end;
end;

procedure Run;
begin
  if ParamCount < 2 then begin
    Writeln('Usage: MapSegBaseProbe <image.exe|dll> <file.map> [seg:offset ...]');
    Writeln;
    Writeln('Derives each MAP segment''s base RVA width-agnostically, verifies it');
    Writeln('against the PE section table, and contrasts it with the fixed');
    Writeln('16-hex-digit parse used by MapFileReader.ParseSegmentTableEager.');
    Halt(2);
  end;

  var ImagePath := ParamStr(1);
  var MapPath   := ParamStr(2);
  var Pe := ReadPeInfo(ImagePath);

  Writeln('probe built as    : ', {$IFDEF WIN64}'dcc64 (Win64)'{$ELSE}'dcc32 (Win32)'{$ENDIF});
  Writeln('image             : ', ImagePath);
  Writeln('map               : ', MapPath);
  Writeln(Format('optional header   : %s', [IfThen(Pe.IsPe32Plus, 'PE32+ (magic $20B)', 'PE32 (magic $10B)')]));
  Writeln(Format('ImageBase         : $%x', [Pe.ImageBase]));
  Writeln(Format('SizeOfImage ($38) : $%x', [Pe.SizeOfImage]));
  Writeln;

  var Segments := ReadSegmentTable(MapPath, Pe.ImageBase);
  ReportSegments(Pe, Segments);

  var Tokens: TArray<string>;
  for var I := 3 to ParamCount do
    Tokens := Tokens + [ParamStr(I)];
  ReportTokens(Segments, Tokens);

  Writeln;
  var Parsed := 0;
  var Matched := 0;
  for var Seg in Segments do begin
    if Seg.LegacyOk then Inc(Parsed);
    var Va: UInt64;
    if SectionVaForName(Pe, Seg.Name, Va) and (Va = Seg.GenericBase) then
      Inc(Matched);
  end;
  Writeln(Format('SUMMARY: %d segment lines; generic parse verified against PE sections: %d; ' +
    'fixed-16-digit parse accepted: %d', [Length(Segments), Matched, Parsed]));
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln(ErrOutput, 'ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
