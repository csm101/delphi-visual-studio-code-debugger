program LocalsLookupProbe;

// What do the symbol readers return when asked for the locals of a named
// routine -- and, optionally, of an RVA?
//
// Written for a specific wrong answer: stopped in a program's MAIN BLOCK on a
// real 505 MB single-exe build, `get_locals` returned 23 variables belonging to
// some JSON/RTTI marshalling routine elsewhere in the program, nearly all of
// them reporting frame offset 0. The main block's "function name" is the
// program name, so the suspicion is a by-name lookup collapsing onto a
// unit-wide bucket. This asks each reader directly, so the answer comes from
// the file rather than from the debug session.
//
//   LocalsLookupProbe.exe <exe-or-bpl> <FunctionName> [rvaHex]
//
// Prints, per reader: the by-name result, and the by-RVA result when an RVA is
// given. Offset 0 is called out, because a whole set of locals sharing offset 0
// is the signature of the defect rather than a plausible frame layout.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.StrUtils,
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  RsmFileReader in '..\DebuggerCore\RsmFileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';

procedure Report(const Tag: string; Ok: Boolean; const Locals: TArray<TLocalSymbol>);
begin
  if not Ok then begin
    Writeln(Format('  %-14s -> (no answer)', [Tag]));
    Exit;
  end;
  var Locationless := 0;
  for var L in Locals do
    if (L.RbpOffset = 0) and (L.RegId = 0) then
      Inc(Locationless);
  Writeln(Format('  %-14s -> %d local(s), %d with NO LOCATION (offset 0 and no register)',
    [Tag, Length(Locals), Locationless]));
  var Shown := 0;
  for var L in Locals do begin
    // RegId matters: a REGISTER-allocated local legitimately has frame offset 0
    // (its value is not on the frame at all), so offset 0 alone does not mean
    // "no location". Only offset 0 AND RegId 0 does.
    Writeln(Format('      %-26s off=%-6d reg=%-4d typeId=%-6d hint="%s"',
      [L.Name, L.RbpOffset, L.RegId, L.TypeId, L.TypeHint]));
    Inc(Shown);
    if Shown >= 30 then begin
      Writeln(Format('      ... (%d more)', [Length(Locals) - Shown]));
      Break;
    end;
  end;
end;

begin
  if ParamCount < 2 then begin
    Writeln('usage: LocalsLookupProbe.exe <exe-or-bpl> <FunctionName> [rvaHex]');
    Halt(1);
  end;
  var Path := ParamStr(1);
  var Name := ParamStr(2);
  var Rva: UInt64 := 0;
  if ParamCount >= 3 then
    Rva := StrToInt64Def('$' + ParamStr(3), 0);

  if not FileExists(Path) then begin
    Writeln('not found: ', Path);
    Halt(2);
  end;

  Writeln(Format('%s  function="%s"%s',
    [ExtractFileName(Path), Name,
     IfThen(Rva <> 0, Format('  rva=$%x', [Rva]), '')]));

  Writeln('TD32:');
  var Td := TTD32FileReader.Create;
  try
    try
      Td.LoadFromFile(Path);
      // Without this the reader withholds locals by design (RSM is the default
      // provider), and the probe would measure its own silence -- which is
      // exactly what happened on the first run of this tool.
      Td.ExposeLocals := True;
      var L: TArray<TLocalSymbol>;
      Report('by name', Td.GetLocalsForFunction(Name, L), L);
      // The session tries the RVA-keyed lookup FIRST, so a by-name miss says
      // nothing on its own. Resolve the address from the name when the caller
      // did not supply one, and ask that way too.
      var UseRva := Rva;
      if UseRva = 0 then begin
        var R: UInt64;
        if Td.NameToRva(Name, R) then begin
          UseRva := R;
          Writeln(Format('  (resolved "%s" -> rva $%x via TD32)', [Name, R]));
        end;
      end;
      if UseRva <> 0 then begin
        var L2: TArray<TLocalSymbol>;
        Report('by rva', Td.GetLocalsForFunctionByRva(UseRva, L2), L2);
      end
      else
        Writeln('  (no rva: TD32 could not resolve the name to an address)');
    except
      on E: Exception do Writeln('  load failed: ', E.Message);
    end;
  finally
    Td.Free;
  end;

  Writeln('RSM:');
  var RsmPath := ChangeFileExt(Path, '.rsm');
  if not FileExists(RsmPath) then begin
    Writeln('  (no .rsm beside the binary)');
    Exit;
  end;
  var Rsm := TRsmFile.Create;
  try
    try
      Rsm.LoadFromFile(RsmPath);
      Rsm.WaitForIndex;
      var L: TArray<TLocalSymbol>;
      Report('by name', Rsm.GetLocalsForFunction(Name, L), L);
      if Rva <> 0 then begin
        var L2: TArray<TLocalSymbol>;
        Report('by rva', Rsm.GetLocalsForFunctionByRva(Rva, L2), L2);
      end;
    except
      on E: Exception do Writeln('  load failed: ', E.Message);
    end;
  finally
    Rsm.Free;
  end;
end.
