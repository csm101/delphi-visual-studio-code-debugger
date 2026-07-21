program DumpRsmUses;

// Dumps the unit-dependency ("uses") information recorded in a .rsm symbol
// file.  Uses entries are stored as `$63 $35 <len> <name>` records; the records
// belonging to one unit's uses clause sit close together, so consecutive
// records are grouped into a cluster whenever the gap between them stays below
// MaxIntraClusterGap.  Dotted unit names are stored as separate segments
// (for example "Winapi" followed by "ImageHlp" for Winapi.ImageHlp).
//
// Usage: DumpRsmUses.exe <rsmfile> [unitnamefilter]
//
// With a filter, only clusters containing a unit name that contains the filter
// (case-insensitive) are printed.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.IOUtils;

const
  UsesRecordTag0 = $63;
  UsesRecordTag1 = $35;
  MaxIntraClusterGap = 1024;

function IsIdentifierStart(Value: Byte): Boolean;
begin
  Result := CharInSet(Char(Value), ['A'..'Z', 'a'..'z', '_']);
end;

function IsIdentifierChar(Value: Byte): Boolean;
begin
  Result := IsIdentifierStart(Value) or CharInSet(Char(Value), ['0'..'9', '.']);
end;

// Returns the unit name at Offset, or an empty string when the bytes are not a
// plausible unit identifier (the two-byte tag also occurs by coincidence inside
// unrelated payload).
function ReadUnitName(const Data: TBytes; Offset, NameLength: Integer): string;
begin
  if Offset + NameLength > Length(Data) then
    Exit('');
  if not IsIdentifierStart(Data[Offset]) then
    Exit('');
  Result := '';
  for var Index := 0 to NameLength - 1 do begin
    var Value := Data[Offset + Index];
    if not IsIdentifierChar(Value) then
      Exit('');
    Result := Result + Char(Value);
  end;
end;

procedure DumpUsesClusters(const Data: TBytes; const Filter: string);
var
  ClusterNames: TArray<string>;
  ClusterOffsets: TArray<Int64>;
  ClusterStart: Int64;
  ClusterCount: Integer;
  PrintedCount: Integer;
  RecordCount: Integer;

  function ClusterMatchesFilter: Boolean;
  begin
    if Filter = '' then
      Exit(True);
    for var Name in ClusterNames do
      if Name.ToLower.Contains(Filter) then
        Exit(True);
    Result := False;
  end;

  procedure FlushCluster;
  begin
    if Length(ClusterNames) = 0 then
      Exit;
    Inc(ClusterCount);
    if ClusterMatchesFilter then begin
      Inc(PrintedCount);
      var EntryWord := 'entries';
      if Length(ClusterNames) = 1 then
        EntryWord := 'entry';
      Writeln(Format('cluster #%d @ 0x%.8x  (%d %s): %s',
        [ClusterCount, ClusterStart, Length(ClusterNames), EntryWord, string.Join(', ', ClusterNames)]));
      for var Index := 0 to High(ClusterNames) do
        Writeln(Format('    0x%.8x  %s', [ClusterOffsets[Index], ClusterNames[Index]]));
      Writeln;
    end;
    ClusterNames := nil;
    ClusterOffsets := nil;
    ClusterStart := -1;
  end;

begin
  ClusterStart := -1;
  ClusterCount := 0;
  PrintedCount := 0;
  RecordCount := 0;

  var PreviousRecordEnd: Int64 := -1;
  var Offset: Int64 := 0;
  while Offset < Int64(Length(Data)) - 3 do begin
    if (Data[Offset] <> UsesRecordTag0) or (Data[Offset + 1] <> UsesRecordTag1) then begin
      Inc(Offset);
      Continue;
    end;

    var NameLength := Data[Offset + 2];
    var Name := ReadUnitName(Data, Offset + 3, NameLength);
    if (NameLength = 0) or (Name = '') then begin
      Inc(Offset);
      Continue;
    end;

    if (PreviousRecordEnd < 0) or (Offset - PreviousRecordEnd > MaxIntraClusterGap) then
      FlushCluster;
    if Length(ClusterNames) = 0 then
      ClusterStart := Offset;
    ClusterNames := ClusterNames + [Name];
    ClusterOffsets := ClusterOffsets + [Offset];
    Inc(RecordCount);

    Inc(Offset, 3 + NameLength);
    PreviousRecordEnd := Offset;
  end;
  FlushCluster;

  Writeln(Format('uses records: %d', [RecordCount]));
  Writeln(Format('clusters: %d printed, %d total', [PrintedCount, ClusterCount]));
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: DumpRsmUses.exe <rsmfile> [unitnamefilter]');
      Halt(1);
    end;

    var RsmPath := ParamStr(1);
    if not TFile.Exists(RsmPath) then begin
      Writeln('File not found: ', RsmPath);
      Halt(1);
    end;

    var Filter := ParamStr(2).ToLower;
    var Data := TFile.ReadAllBytes(RsmPath);

    Writeln('RSM: ', RsmPath);
    Writeln('Size: ', Length(Data), ' bytes');
    if Filter <> '' then
      Writeln('Filter: ', Filter);
    Writeln;

    DumpUsesClusters(Data, Filter);
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
