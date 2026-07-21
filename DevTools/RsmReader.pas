unit RsmReader;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.StrUtils;

type
  TStringRun = record
    Offset: Int64;
    Length: Integer;
    Value:  string;
  end;

  TRegion = record
    StartOff: Int64;
    EndOff:   Int64;
    Kind:     string;   // 'zero', 'ascii', 'binary', 'mixed'
    Notes:    string;
  end;

  TRsmAnalyzer = class
  private
    FData:     TBytes;
    FSize:     Int64;
    FSummary:  TStringList;
    FStrings:  TStringList;
    FHex:      TStringList;
    FRegions:  TList<TRegion>;
    FRuns:     TList<TStringRun>;

    procedure EmitS(const S: string); overload;
    procedure EmitS(const Fmt: string; const Args: array of const); overload;
    procedure Section(const Title: string);

    function  U16(Offset: Int64): Word;
    function  U32(Offset: Int64): Cardinal;
    function  U64(Offset: Int64): UInt64;
    function  ReadCStringAt(Offset: Int64; out NextOffset: Int64;
                MaxLen: Integer = 4096): string;
    function  IsPrintable(B: Byte): Boolean;
    function  HexByte(B: Byte): string;
    function  AsciiSlice(StartOff, EndOff: Int64): string;

    procedure PassMagicAndHeader;
    procedure PassByteHistogram;
    procedure PassExtractStrings;
    procedure PassRegionClassification;
    procedure PassFullHexDump;
    procedure PassRecordScanHeuristic;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Analyze(const RsmPath, SummaryPath, StringsPath, HexPath: string);
  end;

implementation

uses
  System.Math;

{ TRsmAnalyzer }

constructor TRsmAnalyzer.Create;
begin
  inherited;
  FSummary := TStringList.Create;
  FStrings := TStringList.Create;
  FHex     := TStringList.Create;
  FRegions := TList<TRegion>.Create;
  FRuns    := TList<TStringRun>.Create;
end;

destructor TRsmAnalyzer.Destroy;
begin
  FSummary.Free;
  FStrings.Free;
  FHex.Free;
  FRegions.Free;
  FRuns.Free;
  inherited;
end;

procedure TRsmAnalyzer.EmitS(const S: string);
begin
  FSummary.Add(S);
end;

procedure TRsmAnalyzer.EmitS(const Fmt: string; const Args: array of const);
begin
  FSummary.Add(Format(Fmt, Args));
end;

procedure TRsmAnalyzer.Section(const Title: string);
begin
  EmitS('');
  EmitS('=== ' + Title + ' ===');
end;

function TRsmAnalyzer.U16(Offset: Int64): Word;
begin
  Result := PWord(@FData[Offset])^;
end;

function TRsmAnalyzer.U32(Offset: Int64): Cardinal;
begin
  Result := PCardinal(@FData[Offset])^;
end;

function TRsmAnalyzer.U64(Offset: Int64): UInt64;
begin
  Result := PUInt64(@FData[Offset])^;
end;

function TRsmAnalyzer.IsPrintable(B: Byte): Boolean;
begin
  Result := (B >= 32) and (B < 127);
end;

function TRsmAnalyzer.HexByte(B: Byte): string;
const
  Hex: array[0..15] of Char = '0123456789abcdef';
begin
  Result := Hex[B shr 4] + Hex[B and $0F];
end;

function TRsmAnalyzer.ReadCStringAt(Offset: Int64; out NextOffset: Int64;
  MaxLen: Integer): string;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, 0);
  var I := 0;
  while (Offset + I < FSize) and (I < MaxLen) do begin
    var B := FData[Offset + I];
    if B = 0 then
      Break;
    SetLength(Bytes, I + 1);
    Bytes[I] := B;
    Inc(I);
  end;
  NextOffset := Offset + I + 1;
  Result := TEncoding.ANSI.GetString(Bytes);
end;

function TRsmAnalyzer.AsciiSlice(StartOff, EndOff: Int64): string;
begin
  var Len := EndOff - StartOff;
  if Len <= 0 then
    Exit('');
  var SB := TStringBuilder.Create;
  try
    for var I := 0 to Len - 1 do begin
      var B := FData[StartOff + I];
      if IsPrintable(B) then
        SB.Append(Char(B))
      else
        SB.Append('.');
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TRsmAnalyzer.PassMagicAndHeader;
begin
  Section('MAGIC AND FIRST 128 BYTES');
  if FSize < 8 then begin
    EmitS('File too small.');
    Exit;
  end;

  var Magic: array[0..3] of AnsiChar;
  Move(FData[0], Magic, 4);
  EmitS('Magic bytes [0..3]: %s %s %s %s  = "%s%s%s%s"',
    [HexByte(FData[0]), HexByte(FData[1]), HexByte(FData[2]), HexByte(FData[3]),
     Char(FData[0]), Char(FData[1]), Char(FData[2]), Char(FData[3])]);

  if (FData[0] = Ord('C')) and (FData[1] = Ord('S')) and
     (FData[2] = Ord('H')) and (FData[3] = Ord('7')) then
    EmitS('Magic check: CSH7 OK')
  else
    EmitS('Magic check: FAIL (expected CSH7)');

  EmitS('');
  EmitS('Interpreted fields (hypothesis, to be verified):');
  EmitS('  [0x000] U32  "CSH7" magic       = 0x%.8x', [U32(0)]);
  if FSize >= $10 then
    EmitS('  [0x004] U32  ?                  = 0x%.8x (%d)', [U32(4), U32(4)]);
  if FSize >= $20 then
    EmitS('  [0x008] U32  ?                  = 0x%.8x (%d)', [U32(8), U32(8)]);
  if FSize >= $20 then
    EmitS('  [0x00C] U32  ?                  = 0x%.8x (%d)', [U32($C), U32($C)]);
  if FSize >= $20 then
    EmitS('  [0x010] U32  ?                  = 0x%.8x (%d)', [U32($10), U32($10)]);
  if FSize >= $20 then
    EmitS('  [0x014] U32  ?                  = 0x%.8x (%d)', [U32($14), U32($14)]);
  if FSize >= $20 then
    EmitS('  [0x018] U64  PreferredBase?     = 0x%.16x', [U64($18)]);
  if FSize >= $120 then begin
    var NextOff: Int64;
    var ExeName := ReadCStringAt($20, NextOff, 256);
    EmitS('  [0x020] CSTR ExePath?            = "%s" (len=%d, next=0x%.x)',
      [ExeName, Length(ExeName), NextOff]);
  end;

  EmitS('');
  EmitS('First 256 bytes (hex + ascii):');
  var LineLen := 16;
  var Limit := Min(Int64(256), FSize);
  var Off: Int64 := 0;
  while Off < Limit do begin
    var Take := Min(Int64(LineLen), Limit - Off);
    var HexPart := '';
    for var I := 0 to Take - 1 do begin
      HexPart := HexPart + HexByte(FData[Off + I]);
      if I < Take - 1 then
        HexPart := HexPart + ' ';
    end;
    while Length(HexPart) < LineLen * 3 - 1 do
      HexPart := HexPart + ' ';
    var AsciiPart := AsciiSlice(Off, Off + Take);
    EmitS('  %.8x  %s  |%s|', [Off, HexPart, AsciiPart]);
    Inc(Off, Take);
  end;
end;

procedure TRsmAnalyzer.PassByteHistogram;
var
  Counts: array[0..255] of Int64;
begin
  Section('BYTE HISTOGRAM');
  FillChar(Counts, SizeOf(Counts), 0);
  for var I: Int64 := 0 to FSize - 1 do
    Inc(Counts[FData[I]]);

  EmitS('Top 20 most frequent bytes:');
  var Used: array[0..255] of Boolean;
  FillChar(Used, SizeOf(Used), 0);
  for var Rank := 1 to 20 do begin
    var BestVal: Int64 := -1;
    var BestIdx := -1;
    for var I := 0 to 255 do
      if (not Used[I]) and (Counts[I] > BestVal) then begin
        BestVal := Counts[I];
        BestIdx := I;
      end;
    if BestIdx < 0 then
      Break;
    Used[BestIdx] := True;
    EmitS('  %2d.  0x%.2x (%3d ''%s'')  %12d  %6.2f%%',
      [Rank, BestIdx, BestIdx,
       IfThen(IsPrintable(BestIdx), Char(BestIdx), '.'),
       BestVal, BestVal * 100.0 / FSize]);
  end;
end;

procedure TRsmAnalyzer.PassExtractStrings;
const
  MinRunLen = 4;
begin
  FRuns.Clear;
  var Off: Int64 := 0;
  while Off < FSize do begin
    if IsPrintable(FData[Off]) then begin
      var Start := Off;
      while (Off < FSize) and IsPrintable(FData[Off]) do
        Inc(Off);
      var Len := Integer(Off - Start);
      if Len >= MinRunLen then begin
        var Run: TStringRun;
        Run.Offset := Start;
        Run.Length := Len;
        SetString(Run.Value, PAnsiChar(@FData[Start]), Len);
        FRuns.Add(Run);
      end;
    end else
      Inc(Off);
  end;

  FStrings.Add(Format('=== STRING RUNS (length >= %d, ASCII printable) ===', [MinRunLen]));
  FStrings.Add(Format('Total runs: %d', [FRuns.Count]));
  FStrings.Add('');
  FStrings.Add(Format('%-10s %-6s  %s', ['Offset', 'Len', 'Value']));
  for var I := 0 to FRuns.Count - 1 do begin
    var R := FRuns[I];
    FStrings.Add(Format('%.8x   %4d   %s', [R.Offset, R.Length, R.Value]));
  end;

  Section('STRING RUN SUMMARY');
  EmitS('Total printable runs (len >= %d): %d', [MinRunLen, FRuns.Count]);
  EmitS('(full list in .strings.txt)');

  EmitS('');
  EmitS('Length distribution:');
  var Buckets: array[0..10] of Integer;
  FillChar(Buckets, SizeOf(Buckets), 0);
  for var R in FRuns do
    if R.Length < 8 then
      Inc(Buckets[0])
    else if R.Length < 16 then
      Inc(Buckets[1])
    else if R.Length < 32 then
      Inc(Buckets[2])
    else if R.Length < 64 then
      Inc(Buckets[3])
    else if R.Length < 128 then
      Inc(Buckets[4])
    else
      Inc(Buckets[5]);
  EmitS('    4-7 chars: %d', [Buckets[0]]);
  EmitS('   8-15 chars: %d', [Buckets[1]]);
  EmitS('  16-31 chars: %d', [Buckets[2]]);
  EmitS('  32-63 chars: %d', [Buckets[3]]);
  EmitS(' 64-127 chars: %d', [Buckets[4]]);
  EmitS('  128+  chars: %d', [Buckets[5]]);
end;

procedure TRsmAnalyzer.PassRegionClassification;
const
  ChunkSize = 64;

  function ClassifyChunk(Off, Len: Int64): string;
  var
    Zeros, Printables, Highs: Integer;
  begin
    Zeros := 0; Printables := 0; Highs := 0;
    for var I := 0 to Len - 1 do begin
      var B := FData[Off + I];
      if B = 0 then
        Inc(Zeros)
      else if IsPrintable(B) then
        Inc(Printables)
      else
        Inc(Highs);
    end;
    if Zeros = Len then
      Exit('zero');
    if Zeros > (Len * 9) div 10 then
      Exit('mostly-zero');
    if Printables > (Len * 8) div 10 then
      Exit('ascii');
    if (Printables + Zeros) > (Len * 8) div 10 then
      Exit('ascii+zero');
    Result := 'binary';
  end;

begin
  Section('REGION CLASSIFICATION (64-byte chunks)');
  var CurKind := '';
  var RegionStart: Int64 := 0;
  var Off: Int64 := 0;
  while Off < FSize do begin
    var Len := Min(Int64(ChunkSize), FSize - Off);
    var Kind := ClassifyChunk(Off, Len);
    if Kind <> CurKind then begin
      if CurKind <> '' then
        EmitS('  [0x%.8x - 0x%.8x] %8d bytes  %s',
          [RegionStart, Off - 1, Off - RegionStart, CurKind]);
      CurKind := Kind;
      RegionStart := Off;
    end;
    Inc(Off, Len);
  end;
  if CurKind <> '' then
    EmitS('  [0x%.8x - 0x%.8x] %8d bytes  %s',
      [RegionStart, FSize - 1, FSize - RegionStart, CurKind]);
end;

procedure TRsmAnalyzer.PassRecordScanHeuristic;
begin
  Section('RECORD SCAN HEURISTIC (looking for "tag + length + payload" patterns)');
  EmitS('Scanning for short-length-prefixed ASCII strings: "TAG LEN STR" where');
  EmitS('TAG is one byte, LEN is one byte, next LEN bytes are printable ASCII.');
  EmitS('');

  var TagStats := TDictionary<Byte, Integer>.Create;
  try
    var Off: Int64 := 0;
    var Samples := TStringList.Create;
    try
      while Off + 2 < FSize do begin
        var Tag := FData[Off];
        var Len := FData[Off + 1];
        if (Len >= 4) and (Len <= 80) and (Off + 2 + Len <= FSize) then begin
          var AllPrintable := True;
          for var I := 0 to Len - 1 do
            if not IsPrintable(FData[Off + 2 + I]) then begin
              AllPrintable := False;
              Break;
            end;
          if AllPrintable then begin
            var Cnt: Integer;
            if TagStats.TryGetValue(Tag, Cnt) then
              TagStats[Tag] := Cnt + 1
            else
              TagStats.Add(Tag, 1);
            if Samples.Count < 40 then begin
              var S: string;
              SetString(S, PAnsiChar(@FData[Off + 2]), Len);
              Samples.Add(Format('  [0x%.8x] tag=0x%.2x len=%d "%s"', [Off, Tag, Len, S]));
            end;
            Inc(Off, 2 + Len);
            Continue;
          end;
        end;
        Inc(Off);
      end;

      EmitS('Tag frequency (pattern: byte + length-prefixed ASCII):');
      var Tags := TList<Byte>.Create;
      try
        for var Pair in TagStats do
          Tags.Add(Pair.Key);
        Tags.Sort(TComparer<Byte>.Construct(
          function(const L, R: Byte): Integer
          begin
            Result := TagStats[R] - TagStats[L];
          end));
        for var T in Tags do
          EmitS('  tag 0x%.2x (%3d ''%s'')  %d occurrences',
            [T, T, IfThen(IsPrintable(T), Char(T), '.'), TagStats[T]]);
      finally
        Tags.Free;
      end;

      EmitS('');
      EmitS('First 40 matches:');
      for var S in Samples do
        EmitS(S);
    finally
      Samples.Free;
    end;
  finally
    TagStats.Free;
  end;
end;

procedure TRsmAnalyzer.PassFullHexDump;
const
  LineLen = 16;
begin
  FHex.Add(Format('=== FULL HEX DUMP OF %d BYTES ===', [FSize]));
  FHex.Add('Offset     Hex                                              ASCII');
  FHex.Add(StringOfChar('-', 80));
  var Off: Int64 := 0;
  var SB := TStringBuilder.Create;
  try
    while Off < FSize do begin
      var Take := Min(Int64(LineLen), FSize - Off);
      SB.Clear;
      SB.Append(IntToHex(Off, 8));
      SB.Append('  ');
      for var I := 0 to LineLen - 1 do begin
        if I < Take then
          SB.Append(HexByte(FData[Off + I]))
        else
          SB.Append('  ');
        SB.Append(' ');
      end;
      SB.Append(' |');
      for var I := 0 to Take - 1 do begin
        var B := FData[Off + I];
        if IsPrintable(B) then
          SB.Append(Char(B))
        else
          SB.Append('.');
      end;
      SB.Append('|');
      FHex.Add(SB.ToString);
      Inc(Off, Take);
    end;
  finally
    SB.Free;
  end;
end;

procedure TRsmAnalyzer.Analyze(const RsmPath, SummaryPath, StringsPath,
  HexPath: string);
begin
  var F := TFileStream.Create(RsmPath, fmOpenRead or fmShareDenyWrite);
  try
    FSize := F.Size;
    SetLength(FData, FSize);
    if FSize > 0 then
      F.ReadBuffer(FData[0], FSize);
  finally
    F.Free;
  end;

  Writeln(Format('Loaded %d bytes from %s', [FSize, RsmPath]));

  EmitS('RSM FILE ANALYSIS');
  EmitS('Input:  %s', [RsmPath]);
  EmitS('Size:   %d bytes (0x%x)', [FSize, FSize]);
  EmitS('Date:   %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]);

  PassMagicAndHeader;
  PassByteHistogram;
  PassRegionClassification;
  PassExtractStrings;
  PassRecordScanHeuristic;
  PassFullHexDump;

  FSummary.SaveToFile(SummaryPath);
  FStrings.SaveToFile(StringsPath);
  FHex.SaveToFile(HexPath);
end;

end.
