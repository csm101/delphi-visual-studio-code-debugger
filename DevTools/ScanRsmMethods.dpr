program ScanRsmMethods;

// Searches for a string inside a .rsm file and dumps the surrounding bytes
// with tag context.  Use this to locate where a method or class name appears
// in the RSM and understand the surrounding record structure.
//
// Usage: ScanRsmMethods.exe <rsmfile> [searchterm]
// Default search term: "Create"

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, Winapi.Windows;

procedure DumpHex(Data: PByte; DataSize: Int64; From, Count: Int64);
var
  I: Int64;
begin
  for I := From to From + Count - 1 do begin
    if (I < 0) or (I >= DataSize) then
      Write('?? ')
    else
      Write(IntToHex(Data[I], 2) + ' ');
    if (I - From + 1) mod 16 = 0 then Writeln;
  end;
  Writeln;
end;

procedure ScanForString(Data: PByte; DataSize: Int64; const Search: AnsiString);
var
  SLen: Integer;
  Off, Hit: Int64;
  B: Byte;
begin
  SLen := Length(Search);
  if SLen = 0 then Exit;

  Writeln('=== Searching for "', Search, '" (', SLen, ' bytes) ===');
  Hit := 0;
  Off := 0;
  while Off + SLen <= DataSize do begin
    if Data[Off] = Ord(Search[1]) then begin
      var Match := True;
      for var I := 1 to SLen - 1 do
        if Data[Off + I] <> Ord(Search[I + 1]) then begin
          Match := False;
          Break;
        end;
      if Match then begin
        Inc(Hit);
        Writeln('  Hit #', Hit, ' at offset 0x', IntToHex(Off, 8), ' (', Off, ')');
        var From := Off - 8;
        var Count := SLen + 24;
        Write('  [-8..+', SLen + 16 - 1, ']: ');
        DumpHex(Data, DataSize, From, Count);

        if Off >= 2 then begin
          B := Data[Off - 2];
          Writeln('  Byte[-2] = 0x', IntToHex(B, 2), ' (', B, ')');
          B := Data[Off - 1];
          Writeln('  Byte[-1] (len?) = 0x', IntToHex(B, 2), ' (', B, ')');
        end;
        if Off >= 3 then begin
          B := Data[Off - 3];
          Writeln('  Byte[-3] = 0x', IntToHex(B, 2), ' (', B, ')');
        end;
        if Off >= 4 then begin
          B := Data[Off - 4];
          Writeln('  Byte[-4] = 0x', IntToHex(B, 2), ' (', B, ')');
        end;
        Writeln;
      end;
    end;
    Inc(Off);
  end;
  if Hit = 0 then
    Writeln('  Not found.');
  Writeln;
end;

procedure ShowProcRecordsNearOffset(Data: PByte; DataSize: Int64; Center: Int64);
var
  Off: Int64;
begin
  Off := Center - 512;
  if Off < 0 then Off := 0;
  var Limit := Center + 512;
  if Limit > DataSize - 2 then Limit := DataSize - 2;
  Writeln('  Procedure/global records in [0x', IntToHex(Off, 8), ' .. 0x', IntToHex(Limit, 8), ']:');
  while Off < Limit do begin
    if Data[Off] = $63 then begin
      var Sub := Data[Off + 1];
      if (Sub = $28) or (Sub = $20) or (Sub = $29) or (Sub = $2A) then begin
        var NL := Data[Off + 2];
        if (NL >= 1) and (NL <= 63) and (Off + 3 + NL <= DataSize) then begin
          var Name: string;
          SetString(Name, PAnsiChar(Data + Off + 3), NL);
          Writeln('  0x', IntToHex(Off, 8), ': $63 $', IntToHex(Sub, 2),
            ' len=', NL, ' name="', Name, '"');
        end;
      end;
    end;
    Inc(Off);
  end;
end;

var
  RsmPath, SearchTerm: string;
  FH: THandle;
  MH: THandle;
  Data: PByte;
  DataSize: Int64;
begin
  if ParamCount < 1 then begin
    Writeln('Usage: ScanRsmMethods.exe <rsmfile> [searchterm]');
    Writeln('Default search: "Create"');
    Halt(1);
  end;

  RsmPath    := ParamStr(1);
  SearchTerm := 'Create';
  if ParamCount >= 2 then
    SearchTerm := ParamStr(2);

  if not FileExists(RsmPath) then begin
    Writeln('File not found: ', RsmPath);
    Halt(1);
  end;

  FH := CreateFile(PChar(RsmPath), GENERIC_READ, FILE_SHARE_READ, nil,
                   OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FH = INVALID_HANDLE_VALUE then begin
    Writeln('Cannot open: ', RsmPath);
    Halt(1);
  end;

  var SizeLow, SizeHigh: DWORD;
  SizeLow  := GetFileSize(FH, @SizeHigh);
  DataSize := Int64(SizeHigh) shl 32 or SizeLow;

  MH   := CreateFileMapping(FH, nil, PAGE_READONLY, 0, 0, nil);
  Data := MapViewOfFile(MH, FILE_MAP_READ, 0, 0, 0);

  Writeln('RSM: ', RsmPath);
  Writeln('Size: ', DataSize, ' bytes');
  Writeln;

  ScanForString(Data, DataSize, AnsiString(SearchTerm));

  UnmapViewOfFile(Data);
  CloseHandle(MH);
  CloseHandle(FH);
end.
