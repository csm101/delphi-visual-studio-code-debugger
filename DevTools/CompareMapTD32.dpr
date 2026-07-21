program CompareMapTD32;
{$APPTYPE CONSOLE}

// Cross-validates TD32FileReader output against MapFileReader output on
// the same EXE. For every (RVA -> line, file) pair produced by MAP, asks
// TD32 the same question and reports divergences.
//
// Usage: CompareMapTD32.exe <exe-path>

uses
  System.SysUtils,
  System.StrUtils,
  System.Math,
  System.Generics.Collections,
  MapFileReader  in '..\DebuggerCore\MapFileReader.pas',
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';

procedure CompareLineTables(const ExePath, MapPath: string);
begin
  var TD32 := TTD32FileReader.Create;
  var Map  := TMapFile.Create;
  try
    var PBase := ReadPEPreferredBase(ExePath);
    Map.LoadFromFile(MapPath, PBase);
    TD32.LoadFromFile(ExePath);

    var TD32Rvas := TD32.SortedRvas;
    Writeln(Format('TD32 entries: %d', [Length(TD32Rvas)]));

    // Cross-validate: drive by TD32 list. For each TD32 entry, ask MAP
    // for the same RVA + same (file,line) reverse lookup.
    var Matched     := 0;
    var DivergeRva  := 0;
    var MapMissRva  := 0;
    var ReverseOk   := 0;
    var ReverseFail := 0;
    for var Rva in TD32Rvas do begin
      var TD32Loc: TSourceLocation;
      if not TD32.RvaToSourceLine(Rva, TD32Loc) then Continue;
      // MAP forward
      var MapLoc: TSourceLocation;
      if not Map.RvaToSourceLine(Rva, MapLoc) then begin
        Inc(MapMissRva);
        if MapMissRva <= 5 then
          Writeln(Format('  MAP miss for RVA $%x  TD32=%s:%d',
            [Rva, TD32Loc.SourceFile, TD32Loc.Line]));
      end else if (SameText(MapLoc.SourceFile, TD32Loc.SourceFile))
                 and (MapLoc.Line = TD32Loc.Line) then
        Inc(Matched)
      else begin
        Inc(DivergeRva);
        if DivergeRva <= 10 then
          Writeln(Format('  DIVERGE RVA $%x  MAP=%s:%d  TD32=%s:%d',
            [Rva, MapLoc.SourceFile, MapLoc.Line, TD32Loc.SourceFile, TD32Loc.Line]));
      end;
      // Reverse via TD32 file/line: does MAP agree?
      var MapRva: UInt64;
      if Map.SourceLineToRva(TD32Loc.SourceFile, TD32Loc.Line, MapRva) then begin
        if MapRva = Rva then
          Inc(ReverseOk)
        else begin
          Inc(ReverseFail);
          if ReverseFail <= 10 then
            Writeln(Format('  REV DIVERGE %s:%d  MAP=$%x  TD32=$%x',
              [TD32Loc.SourceFile, TD32Loc.Line, MapRva, Rva]));
        end;
      end else begin
        Inc(ReverseFail);
        if ReverseFail <= 5 then
          Writeln(Format('  REV MAP miss %s:%d  TD32=$%x',
            [TD32Loc.SourceFile, TD32Loc.Line, Rva]));
      end;
    end;
    Writeln(Format('Forward MAP=TD32 matched=%d  diverge=%d  MAPmiss=%d',
      [Matched, DivergeRva, MapMissRva]));
    Writeln(Format('Reverse MAP=TD32 matched=%d  failed/diverge=%d',
      [ReverseOk, ReverseFail]));

    // Compare function names. Pick a few representative RVAs from TD32
    // line table and ask both readers for the function name there.
    Writeln;
    Writeln('Function-name spot check (MAP publics forced):');
    // Touch MAP to force background publics indexing to complete.
    var WarmRva: UInt64;
    Map.NameToRva('z_does_not_exist_warm', WarmRva);
    var Step := Length(TD32Rvas) div 10;
    if Step < 1 then Step := 1;
    var I := 0;
    while I < Length(TD32Rvas) do begin
      var Rva := TD32Rvas[I];
      var MapName, TD32Name: string;
      var MapOk  := Map.RvaToFunctionName(Rva, MapName);
      var TD32Ok := TD32.RvaToFunctionName(Rva, TD32Name);
      Writeln(Format('  $%x  MAP=%-40s  TD32=%s',
        [Rva,
         IfThen(MapOk,  MapName,  '<MISS>'),
         IfThen(TD32Ok, TD32Name, '<MISS>')]));
      Inc(I, Step);
    end;
  finally
    Map.Free;
    TD32.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: CompareMapTD32.exe <exe-path>');
      Halt(1);
    end;
    var ExePath := ParamStr(1);
    var MapPath := ChangeFileExt(ExePath, '.map');
    if not FileExists(MapPath) then begin
      Writeln('No MAP at ' + MapPath); Halt(2);
    end;
    CompareLineTables(ExePath, MapPath);
  except
    on E: Exception do begin
      Writeln('ERR: ', E.Message);
      Halt(99);
    end;
  end;
end.
