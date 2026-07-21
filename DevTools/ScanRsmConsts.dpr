program ScanRsmConsts;

// Scans a .rsm file for named-constant records (tag 0x25) and reports the name
// together with the trailing bytes, so the value/type encoding can be
// reverse-engineered across many constants at once.
//
// The record finder is heuristic and deliberately independent of the adapter's
// RSM reader: a 0x25 byte followed by a plausible name length and that many
// printable identifier characters is treated as a candidate record.
//
// Usage: ScanRsmConsts.exe <rsmfile> [name-substring-filter]
// Example: ScanRsmConsts.exe Debugme.rsm Version

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.StrUtils;

const
  ConstantRecordTag = $25;
  MinNameLength     = 2;
  MaxNameLength     = 40;
  TrailingByteCount = 28;

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

function IsIdentifierByte(B: Byte): Boolean;
begin
  if (B >= Ord('A')) and (B <= Ord('Z')) then
    Exit(True);
  if (B >= Ord('a')) and (B <= Ord('z')) then
    Exit(True);
  if (B >= Ord('0')) and (B <= Ord('9')) then
    Exit(True);
  Result := (B = Ord('_')) or (B = Ord('.'));
end;

function LooksLikeConstantRecord(const Data: TBytes; Offset: Integer; out Name: string): Boolean;
begin
  Name := '';
  if Data[Offset] <> ConstantRecordTag then
    Exit(False);

  var NameLength := Data[Offset + 1];
  if (NameLength < MinNameLength) or (NameLength > MaxNameLength) then
    Exit(False);

  var NameStart := Offset + 2;
  if NameStart + NameLength > Length(Data) then
    Exit(False);

  for var I := 0 to NameLength - 1 do
    if not IsIdentifierByte(Data[NameStart + I]) then
      Exit(False);

  SetString(Name, PAnsiChar(@Data[NameStart]), NameLength);
  Result := True;
end;

function FormatHexBytes(const Data: TBytes; Offset, Count: Integer): string;
begin
  Result := '';
  for var I := Offset to Offset + Count - 1 do begin
    if (I < 0) or (I >= Length(Data)) then
      Break;
    Result := Result + Format('%.2x ', [Data[I]]);
  end;
end;

function FormatAsciiBytes(const Data: TBytes; Offset, Count: Integer): string;
begin
  Result := '';
  for var I := Offset to Offset + Count - 1 do begin
    if (I < 0) or (I >= Length(Data)) then
      Break;
    if (Data[I] >= 32) and (Data[I] < 127) then
      Result := Result + Chr(Data[I])
    else
      Result := Result + '.';
  end;
end;

procedure ReportConstantRecord(const Data: TBytes; Offset: Integer; const Name: string);
begin
  var NameLength := Data[Offset + 1];
  var TrailingStart := Offset + 2 + NameLength;
  Writeln(Format('@%d (0x%.8x)  tag=%.2x len=%d name="%s"',
    [Offset, Offset, ConstantRecordTag, NameLength, Name]));
  Writeln('  bytes: ', FormatHexBytes(Data, TrailingStart, TrailingByteCount));
  Writeln('  ascii: ', FormatAsciiBytes(Data, TrailingStart, TrailingByteCount));
end;

function ScanConstantRecords(const Data: TBytes; const NameFilter: string): Integer;
begin
  Result := 0;
  for var Offset := 0 to Length(Data) - 3 do begin
    var Name: string;
    if not LooksLikeConstantRecord(Data, Offset, Name) then
      Continue;
    if (NameFilter <> '') and not ContainsText(Name, NameFilter) then
      Continue;
    Inc(Result);
    ReportConstantRecord(Data, Offset, Name);
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: ScanRsmConsts.exe <rsmfile> [name-substring-filter]');
      Halt(1);
    end;

    var RsmPath := ParamStr(1);
    if not FileExists(RsmPath) then begin
      Writeln('File not found: ', RsmPath);
      Halt(1);
    end;

    var NameFilter := '';
    if ParamCount >= 2 then
      NameFilter := ParamStr(2);

    var Data := LoadFileBytes(RsmPath);
    Writeln('RSM: ', RsmPath);
    Writeln('Size: ', Length(Data), ' bytes');
    if NameFilter <> '' then
      Writeln('Filter: ', NameFilter);
    Writeln;

    var Found := ScanConstantRecords(Data, NameFilter);
    Writeln('--- ', Found, ' candidate 0x25 records ---');
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
