program FindBytes;

// Scans any binary file for a raw byte pattern given as hex digits and reports
// every offset where the pattern occurs.  Useful to locate signatures, opcode
// sequences or magic numbers inside an EXE/DLL/BPL/RSM/MAP or any other file.
//
// The pattern may be written with or without separating spaces, so
// "4889E5" and "48 89 E5" are equivalent.
//
// Usage: FindBytes.exe <file> <hexpattern> [maxhits]
// Example: FindBytes.exe Debugme.exe "4D 5A"
//          FindBytes.exe Debugme.exe 4889E5 100

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes;

function StripSeparators(const Text: string): string;
begin
  Result := '';
  for var Ch in Text do begin
    if CharInSet(Ch, [' ', #9, ',', '-', ':']) then
      Continue;
    Result := Result + Ch;
  end;
end;

function IsHexDigit(Ch: Char): Boolean;
begin
  Result := CharInSet(Ch, ['0'..'9', 'a'..'f', 'A'..'F']);
end;

function ParseHexPattern(const Text: string): TBytes;
begin
  var Digits := StripSeparators(Text);
  if Digits = '' then
    raise Exception.Create('Empty hex pattern.');
  if Odd(Length(Digits)) then
    raise Exception.CreateFmt(
      'Hex pattern has an odd number of digits (%d): "%s". Each byte needs exactly two hex digits.',
      [Length(Digits), Digits]);
  for var I := 1 to Length(Digits) do
    if not IsHexDigit(Digits[I]) then
      raise Exception.CreateFmt('Invalid hex digit "%s" at position %d in pattern "%s".',
        [Digits[I], I, Digits]);

  SetLength(Result, Length(Digits) div 2);
  for var I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Copy(Digits, 1 + I * 2, 2));
end;

function FormatPattern(const Pattern: TBytes): string;
begin
  Result := '';
  for var B in Pattern do begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + IntToHex(B, 2);
  end;
end;

function LoadFileBytes(const Path: string): TBytes;
begin
  var Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function MatchesAt(const Data, Pattern: TBytes; Offset: Int64): Boolean;
begin
  for var I := 0 to High(Pattern) do
    if Data[Offset + I] <> Pattern[I] then
      Exit(False);
  Result := True;
end;

procedure ReportHits(const Data, Pattern: TBytes; MaxHits: Integer);
begin
  var Hits: Int64 := 0;
  var Printed: Int64 := 0;
  var Last := Int64(Length(Data)) - Int64(Length(Pattern));
  var Offset: Int64 := 0;
  while Offset <= Last do begin
    if MatchesAt(Data, Pattern, Offset) then begin
      Inc(Hits);
      if (MaxHits <= 0) or (Printed < MaxHits) then begin
        Writeln(Format('  0x%.8x  (%d)', [Offset, Offset]));
        Inc(Printed);
      end;
    end;
    Inc(Offset);
  end;

  if Hits = 0 then
    Writeln('  Not found.');
  if (MaxHits > 0) and (Hits > Printed) then
    Writeln(Format('  ... %d further hit(s) not shown (maxhits=%d).', [Hits - Printed, MaxHits]));
  Writeln;
  Writeln(Format('Total hits: %d', [Hits]));
end;

begin
  try
    if ParamCount < 2 then begin
      Writeln('Usage: FindBytes.exe <file> <hexpattern> [maxhits]');
      Writeln('       hexpattern accepts "4889E5" or "48 89 E5"; maxhits 0 = unlimited (default)');
      Halt(1);
    end;

    var FilePath := ParamStr(1);
    if not FileExists(FilePath) then begin
      Writeln('File not found: ', FilePath);
      Halt(1);
    end;

    var Pattern := ParseHexPattern(ParamStr(2));
    var MaxHits := 0;
    if ParamCount >= 3 then
      MaxHits := StrToInt(ParamStr(3));

    var Data := LoadFileBytes(FilePath);
    Writeln('File: ', FilePath);
    Writeln('Size: ', Length(Data), ' bytes');
    Writeln('Pattern: ', FormatPattern(Pattern), ' (', Length(Pattern), ' bytes)');
    Writeln;

    if Length(Pattern) > Length(Data) then begin
      Writeln('  Pattern is longer than the file.');
      Writeln;
      Writeln('Total hits: 0');
      Exit;
    end;

    ReportHits(Data, Pattern, MaxHits);
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.Message);
      Halt(1);
    end;
  end;
end.
