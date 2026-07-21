program RsmDiff;

// Differential comparison of two .rsm files (or any two binary files).
//
// Differential compilation is the standard method for decoding an unknown RSM
// record: compile the same project twice with one small source change, diff the
// two .rsm files, and observe which bytes moved.  This tool reports the shape of
// that difference.
//
// Usage: RsmDiff.exe <a.rsm> <b.rsm> [prefix|suffix|insertion|all]
//
//   prefix     length of the identical leading run, plus a hex window around the
//              first differing byte
//   suffix     length of the identical trailing run, plus a hex window around the
//              last differing byte
//   insertion  locate the inserted / removed byte range implied by the size
//              delta; when the sizes are equal, enumerate every differing range
//   all        run every mode (default)

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections;

type
  TDiffMode = (dmPrefix, dmSuffix, dmInsertion);

  TDiffRange = record
    StartOff: Int64;
    Length: Int64;
  end;

const
  BytesPerLine = 16;
  MergeGap = 16;          // equal bytes shorter than this do not split a range
  MaxRangesPrinted = 30;
  ContextBytes = 64;      // hex window printed around a boundary
  MaxDeltaDumpBytes = 256;
  ToleratedMismatches = 16;   // volatile bytes allowed when locating a split point

function LoadFile(const Path: string): TBytes;
begin
  if not FileExists(Path) then
    raise EFileNotFoundException.CreateFmt('File not found: %s', [Path]);

  var Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function IsPrintable(Value: Byte): Boolean;
begin
  Result := (Value >= 32) and (Value < 127);
end;

function CommonPrefixLen(const A, B: TBytes): Int64;
begin
  var Limit: Int64 := Min(Int64(Length(A)), Int64(Length(B)));
  Result := 0;
  while (Result < Limit) and (A[Result] = B[Result]) do
    Inc(Result);
end;

function CommonSuffixLen(const A, B: TBytes): Int64;
begin
  var LenA: Int64 := Length(A);
  var LenB: Int64 := Length(B);
  var Limit: Int64 := Min(LenA, LenB);
  Result := 0;
  while (Result < Limit) and (A[LenA - 1 - Result] = B[LenB - 1 - Result]) do
    Inc(Result);
end;

function HexDumpLine(const Data: TBytes; Offset: Int64; Count: Integer): string;
begin
  var Hex := '';
  var Ascii := '';
  for var I := 0 to BytesPerLine - 1 do begin
    if I < Count then begin
      var Value := Data[Offset + I];
      Hex := Hex + IntToHex(Value, 2) + ' ';
      if IsPrintable(Value) then
        Ascii := Ascii + Char(Value)
      else
        Ascii := Ascii + '.';
    end else begin
      Hex := Hex + '   ';
      Ascii := Ascii + ' ';
    end;
  end;
  Result := Format('%.8x  %s|%s|', [Offset, Hex, Ascii]);
end;

procedure DumpWindow(const Caption: string; const Data: TBytes; StartOff, Count: Int64);
begin
  if Count <= 0 then
    Exit;

  Writeln('  ', Caption);
  var Offset := Max(Int64(0), StartOff);
  var LastOff := Min(Int64(Length(Data)), StartOff + Count);
  while Offset < LastOff do begin
    var Take := Min(Int64(BytesPerLine), LastOff - Offset);
    Writeln('    ', HexDumpLine(Data, Offset, Take));
    Inc(Offset, Take);
  end;
end;

procedure DumpDelta(const Data: TBytes; const Name: string; StartOff, Count: Int64);
begin
  DumpWindow(Format('%s bytes at 0x%x (the delta, %d bytes):', [Name, StartOff, Count]),
    Data, StartOff, Min(Int64(MaxDeltaDumpBytes), Count));
  if Count > MaxDeltaDumpBytes then
    Writeln(Format('    ... %d further byte(s) not printed.', [Count - MaxDeltaDumpBytes]));
end;

procedure CollectDiffRanges(const A, B: TBytes; Ranges: TList<TDiffRange>; out TotalDiffBytes: Int64);
begin
  TotalDiffBytes := 0;
  var Limit: Int64 := Min(Int64(Length(A)), Int64(Length(B)));
  var InDiff := False;
  var DiffStart: Int64 := 0;

  var I: Int64 := 0;
  while I < Limit do begin
    if A[I] <> B[I] then begin
      Inc(TotalDiffBytes);
      if not InDiff then begin
        DiffStart := I;
        InDiff := True;
      end;
    end else if InDiff then begin
      var EqualRun: Int64 := 0;
      var J := I;
      while (J < Limit) and (A[J] = B[J]) and (EqualRun < MergeGap) do begin
        Inc(J);
        Inc(EqualRun);
      end;
      if (EqualRun >= MergeGap) or (J >= Limit) then begin
        var Range: TDiffRange;
        Range.StartOff := DiffStart;
        Range.Length := I - DiffStart;
        Ranges.Add(Range);
        InDiff := False;
      end;
    end;
    Inc(I);
  end;

  if not InDiff then
    Exit;

  var TailRange: TDiffRange;
  TailRange.StartOff := DiffStart;
  TailRange.Length := Limit - DiffStart;
  Ranges.Add(TailRange);
end;

procedure ReportPrefix(const A, B: TBytes);
begin
  Writeln('=== PREFIX ===');
  var PrefixLen := CommonPrefixLen(A, B);
  Writeln(Format('  Identical leading run: %d bytes (first difference at 0x%x)',
    [PrefixLen, PrefixLen]));

  if (PrefixLen >= Length(A)) and (PrefixLen >= Length(B)) then begin
    Writeln('  Files are identical.');
    Writeln;
    Exit;
  end;

  var WindowStart := Max(Int64(0), PrefixLen - ContextBytes div 4);
  DumpWindow(Format('A around 0x%x:', [PrefixLen]), A, WindowStart, ContextBytes);
  DumpWindow(Format('B around 0x%x:', [PrefixLen]), B, WindowStart, ContextBytes);
  Writeln;
end;

procedure ReportSuffix(const A, B: TBytes);
begin
  Writeln('=== SUFFIX ===');
  var SuffixLen := CommonSuffixLen(A, B);
  var LastDiffA: Int64 := Int64(Length(A)) - SuffixLen - 1;
  var LastDiffB: Int64 := Int64(Length(B)) - SuffixLen - 1;
  Writeln(Format('  Identical trailing run: %d bytes (starts at A 0x%x / B 0x%x)',
    [SuffixLen, LastDiffA + 1, LastDiffB + 1]));

  if (LastDiffA < 0) and (LastDiffB < 0) then begin
    Writeln('  Files are identical.');
    Writeln;
    Exit;
  end;

  Writeln(Format('  Last differing byte: A 0x%x / B 0x%x', [LastDiffA, LastDiffB]));
  DumpWindow(Format('A around 0x%x:', [LastDiffA]), A,
    Max(Int64(0), LastDiffA - ContextBytes + BytesPerLine), ContextBytes);
  DumpWindow(Format('B around 0x%x:', [LastDiffB]), B,
    Max(Int64(0), LastDiffB - ContextBytes + BytesPerLine), ContextBytes);
  Writeln;
end;

// Earliest offset P in [Lo..Hi] from which the rest of Small still lines up with
// Large shifted by Shift, allowing at most Tolerance mismatching bytes for
// volatile fields such as timestamps.  The mismatch count is monotonic in P, so
// a single backward walk finds the answer exactly; Hi always qualifies because
// the common suffix was computed under the same shift.
function EarliestSplitPoint(const Small, Large: TBytes; Lo, Hi, Shift, Tolerance: Int64): Int64;
begin
  Result := Hi;
  var Mismatches: Int64 := 0;
  var Candidate := Hi - 1;
  while Candidate >= Lo do begin
    if Small[Candidate] <> Large[Candidate + Shift] then
      Inc(Mismatches);
    if Mismatches > Tolerance then
      Exit;
    Result := Candidate;
    Dec(Candidate);
  end;
end;

function FormatSigned(Value: Int64): string;
begin
  if Value = 0 then
    Result := '0'
  else if Value > 0 then
    Result := '+' + IntToStr(Value)
  else
    Result := IntToStr(Value);
end;

procedure ReportSameSizeRanges(const A, B: TBytes);
begin
  Writeln('  Sizes are equal: no insertion. Enumerating modified ranges.');
  var Ranges := TList<TDiffRange>.Create;
  try
    var TotalDiffBytes: Int64;
    CollectDiffRanges(A, B, Ranges, TotalDiffBytes);
    Writeln(Format('  Differing bytes: %d (%.4f%%) in %d range(s), gaps < %d merged',
      [TotalDiffBytes, TotalDiffBytes * 100.0 / Max(Int64(1), Int64(Length(A))),
       Ranges.Count, MergeGap]));

    for var Index := 0 to Min(MaxRangesPrinted - 1, Ranges.Count - 1) do begin
      var Range := Ranges[Index];
      Writeln(Format('  Range %d: 0x%x .. 0x%x (%d bytes)',
        [Index + 1, Range.StartOff, Range.StartOff + Range.Length - 1, Range.Length]));
      DumpWindow('A:', A, Range.StartOff, Range.Length);
      DumpWindow('B:', B, Range.StartOff, Range.Length);
    end;
    if Ranges.Count > MaxRangesPrinted then
      Writeln(Format('  ... %d further range(s) not printed.', [Ranges.Count - MaxRangesPrinted]));
  finally
    Ranges.Free;
  end;
  Writeln;
end;

procedure ReportInsertion(const A, B: TBytes);
begin
  Writeln('=== INSERTION ===');
  var Delta: Int64 := Int64(Length(B)) - Int64(Length(A));
  Writeln(Format('  A = %d bytes, B = %d bytes, delta = %s',
    [Length(A), Length(B), FormatSigned(Delta)]));

  if Delta = 0 then begin
    ReportSameSizeRanges(A, B);
    Exit;
  end;

  // Work with Small -> Large so the same logic covers insertion and removal.
  var Small := A;
  var Large := B;
  var SmallName := 'A';
  var LargeName := 'B';
  if Delta < 0 then begin
    Small := B;
    Large := A;
    SmallName := 'B';
    LargeName := 'A';
  end;

  var InsertedCount: Int64 := Abs(Delta);
  if Delta < 0 then
    Writeln(Format('  %s is larger: %d byte(s) were removed to obtain %s.',
      [LargeName, InsertedCount, SmallName]))
  else
    Writeln(Format('  %s is larger: %d byte(s) were inserted into %s.',
      [LargeName, InsertedCount, SmallName]));

  var PrefixLen := CommonPrefixLen(Small, Large);
  var SuffixLen := CommonSuffixLen(Small, Large);
  var Lo := PrefixLen;
  var Hi: Int64 := Int64(Length(Small)) - SuffixLen;
  if Hi < Lo then
    Hi := Lo;

  Writeln(Format('  Common prefix: %d bytes; common suffix: %d bytes', [PrefixLen, SuffixLen]));
  Writeln(Format('  Insertion window in %s: [0x%x .. 0x%x] (%d bytes)',
    [SmallName, Lo, Hi, Hi - Lo]));

  if Lo >= Hi then begin
    Writeln(Format('  Pure insertion: everything outside 0x%x is identical.', [Lo]));
    Writeln(Format('  %s[0..0x%x] + %d byte(s) at 0x%x + %s[0x%x..end] reproduces %s',
      [SmallName, Lo - 1, InsertedCount, Lo, SmallName, Lo, LargeName]));
    DumpDelta(Large, LargeName, Lo, InsertedCount);
    Writeln;
    Exit;
  end;

  var SplitPoint := EarliestSplitPoint(Small, Large, Lo, Hi, InsertedCount, ToleratedMismatches);
  Writeln(Format('  Latest possible split point: 0x%x (tail aligns exactly from here)', [Hi]));
  Writeln(Format('  Earliest split point tolerating %d mismatch(es): 0x%x',
    [ToleratedMismatches, SplitPoint]));
  Writeln(Format('  %s[0..0x%x] + %d byte(s) at 0x%x + %s[0x%x..end] reproduces %s',
    [SmallName, SplitPoint - 1, InsertedCount, SplitPoint, SmallName, SplitPoint, LargeName]));

  if SplitPoint > Lo then begin
    Writeln('  The files also differ before that point, so the size delta is not a');
    Writeln('  single clean insertion. Both changed regions follow.');
    DumpWindow(Format('%s changed region 0x%x .. 0x%x (truncated):',
      [SmallName, Lo, SplitPoint - 1]), Small, Lo, Min(Int64(MaxDeltaDumpBytes), SplitPoint - Lo));
    DumpWindow(Format('%s changed region 0x%x .. 0x%x (truncated):',
      [LargeName, Lo, SplitPoint - 1]), Large, Lo, Min(Int64(MaxDeltaDumpBytes), SplitPoint - Lo));
  end;

  DumpDelta(Large, LargeName, SplitPoint, InsertedCount);
  Writeln;
end;

function ParseMode(const Text: string; out Modes: TArray<TDiffMode>): Boolean;
begin
  if SameText(Text, 'prefix') then
    Modes := [dmPrefix]
  else if SameText(Text, 'suffix') then
    Modes := [dmSuffix]
  else if SameText(Text, 'insertion') then
    Modes := [dmInsertion]
  else if SameText(Text, 'all') then
    Modes := [dmPrefix, dmSuffix, dmInsertion]
  else
    Exit(False);
  Result := True;
end;

procedure PrintUsage;
begin
  Writeln('Usage: RsmDiff.exe <a.rsm> <b.rsm> [prefix|suffix|insertion|all]');
  Writeln('  prefix     length of the identical leading run');
  Writeln('  suffix     length of the identical trailing run');
  Writeln('  insertion  inserted/removed byte range implied by the size delta');
  Writeln('  all        run every mode (default)');
end;

procedure Run;
begin
  if ParamCount < 2 then begin
    PrintUsage;
    Halt(1);
  end;

  var ModeText := 'all';
  if ParamCount >= 3 then
    ModeText := ParamStr(3);

  var Modes: TArray<TDiffMode>;
  if not ParseMode(ModeText, Modes) then begin
    Writeln('Unknown mode: ', ModeText);
    PrintUsage;
    Halt(1);
  end;

  var PathA := ParamStr(1);
  var PathB := ParamStr(2);
  var A := LoadFile(PathA);
  var B := LoadFile(PathB);

  Writeln('A: ', PathA, ' (', Length(A), ' bytes)');
  Writeln('B: ', PathB, ' (', Length(B), ' bytes)');
  Writeln('Mode: ', LowerCase(ModeText));
  Writeln;

  for var Mode in Modes do begin
    case Mode of
      dmPrefix: ReportPrefix(A, B);
      dmSuffix: ReportSuffix(A, B);
      dmInsertion: ReportInsertion(A, B);
    end;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
