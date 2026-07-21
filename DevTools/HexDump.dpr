program HexDump;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes;

procedure Run;
begin
  if ParamCount < 3 then begin
    Writeln('Usage: HexDump.exe <file> <hex-offset> <byte-count>');
    Writeln('  Dumps <byte-count> bytes from <file> starting at <hex-offset>.');
    ExitCode := 1;
    Exit;
  end;

  var FilePath := ParamStr(1);
  var StartOff := StrToInt64('$' + ParamStr(2));
  var Count    := StrToInt(ParamStr(3));

  if not FileExists(FilePath) then begin
    Writeln('File not found: ', FilePath);
    ExitCode := 1;
    Exit;
  end;

  var FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    if StartOff >= FS.Size then begin
      Writeln('Offset 0x', ParamStr(2), ' beyond file size ', FS.Size);
      ExitCode := 1;
      Exit;
    end;
    if StartOff + Count > FS.Size then
      Count := FS.Size - StartOff;

    var Buf: TBytes;
    SetLength(Buf, Count);
    FS.Position := StartOff;
    FS.ReadBuffer(Buf[0], Count);

    var Off := StartOff;
    var I := 0;
    while I < Count do begin
      Write(Format('%08X  ', [Off]));
      var LineEnd := I + 16;
      if LineEnd > Count then LineEnd := Count;
      for var J := I to LineEnd - 1 do
        Write(Format('%02X ', [Buf[J]]));
      for var J := LineEnd to I + 15 do
        Write('   ');
      Write(' ');
      for var J := I to LineEnd - 1 do begin
        var C := Char(Buf[J]);
        if (Buf[J] >= 32) and (Buf[J] < 127) then Write(C)
        else Write('.');
      end;
      Writeln;
      Inc(Off, 16);
      I := LineEnd;
    end;
  finally
    FS.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('Error: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
