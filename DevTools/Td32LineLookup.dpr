program Td32LineLookup;

// Resolves a source file + line to the RVA(s) the debugger would plant a
// breakpoint at, using the module's TD32 line table. This is the fastest
// triage for "my breakpoint never binds":
//
//   * no candidate at all      -> the unit is not in this module's TD32
//   * candidate on a later line -> the requested line emitted no code
//   * several candidates        -> the base name is ambiguous (the same file
//                                  name compiled into more than one routine
//                                  or more than one module)
//
// Usage: Td32LineLookup.exe <exe-or-bpl> <source-file> <line>
// All three arguments are required.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader  in '..\DebuggerCore\TD32FileReader.pas';

type
  TLineEntry = record
    Rva:  UInt64;
    Line: Integer;
  end;

procedure PrintUsage;
begin
  Writeln('Usage: Td32LineLookup.exe <exe-or-bpl> <source-file> <line>');
  Writeln('  <exe-or-bpl>   module carrying TD32 debug info');
  Writeln('  <source-file>  source file name (path is ignored, base name is matched)');
  Writeln('  <line>         1-based source line number');
end;

function EntriesForSourceFile(Reader: TTD32FileReader;
  const BaseName: string): TArray<TLineEntry>;
begin
  var List := TList<TLineEntry>.Create;
  try
    for var Rva in Reader.SortedRvas do begin
      var Loc: TSourceLocation;
      if not Reader.RvaToSourceLine(Rva, Loc) then
        Continue;
      if not SameText(ExtractFileName(Loc.SourceFile), BaseName) then
        Continue;
      var Entry: TLineEntry;
      Entry.Rva  := Rva;
      Entry.Line := Loc.Line;
      List.Add(Entry);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
  TArray.Sort<TLineEntry>(Result, TComparer<TLineEntry>.Construct(
    function(const A, B: TLineEntry): Integer
    begin
      Result := A.Line - B.Line;
      if Result <> 0 then
        Exit;
      if A.Rva < B.Rva then
        Result := -1
      else if A.Rva > B.Rva then
        Result := 1;
    end));
end;

function DescribeRva(Reader: TTD32FileReader; Rva: UInt64): string;
begin
  var FuncName: string;
  if not Reader.RvaToFunctionName(Rva, FuncName) then
    FuncName := '<unknown function>';
  Result := Format('rva=$%x  func=%s', [Rva, FuncName]);
  var FuncRva: UInt64;
  if Reader.RvaToFunctionStart(Rva, FuncRva) then
    Result := Result + Format('  funcStart=$%x  +%d', [FuncRva, Rva - FuncRva]);
end;

procedure ReportCandidates(Reader: TTD32FileReader;
  const Entries: TArray<TLineEntry>; Line: Integer);
begin
  var Count := 0;
  for var Entry in Entries do begin
    if Entry.Line <> Line then
      Continue;
    Writeln('   ', DescribeRva(Reader, Entry.Rva));
    Inc(Count);
  end;
  Writeln('  candidates = ', Count);
  if Count > 1 then
    Writeln('  NOTE: several candidates -- the base name is ambiguous; the ' +
            'debugger binds only the first one.');
end;

function FirstLineWithCodeAtOrAfter(const Entries: TArray<TLineEntry>;
  Line: Integer; out Found: Integer): Boolean;
begin
  for var Entry in Entries do
    if Entry.Line >= Line then begin
      Found := Entry.Line;
      Exit(True);
    end;
  Found := 0;
  Result := False;
end;

procedure ListSimilarSourceFiles(Reader: TTD32FileReader; const BaseName: string);
begin
  var Stem := LowerCase(ChangeFileExt(BaseName, ''));
  Writeln('  source files in this module whose name resembles "', BaseName, '":');
  var Shown := 0;
  for var SrcFile in Reader.GetSourceFiles do begin
    if Pos(Stem, LowerCase(SrcFile)) = 0 then
      Continue;
    Writeln('   * ', SrcFile);
    Inc(Shown);
  end;
  if Shown = 0 then
    Writeln('   (none -- this unit contributed no line table to this module)');
end;

procedure Run(const ModulePath, SourceFile: string; Line: Integer);
begin
  var BaseName := ExtractFileName(SourceFile);
  Writeln('Module: ', ModulePath);
  Writeln('Query : ', BaseName, ':', Line);
  Writeln;

  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ModulePath);
    if not Reader.Loaded then begin
      Writeln('ERROR: no TD32 debug info found in ', ModulePath);
      Halt(1);
    end;
    Writeln('TD32 loaded: ', Length(Reader.SortedRvas), ' line-table entries, ',
      Length(Reader.GetSourceFiles), ' source files.');
    Writeln;

    var Entries := EntriesForSourceFile(Reader, BaseName);
    Writeln('--- line-table entries for "', BaseName, '" ---');
    Writeln('  entries = ', Length(Entries));
    if Length(Entries) = 0 then begin
      Writeln('  The requested source file has NO line table in this module.');
      Writeln('  A breakpoint here can never bind against this module.');
      Writeln;
      ListSimilarSourceFiles(Reader, BaseName);
      Exit;
    end;
    Writeln(Format('  line range = %d .. %d',
      [Entries[0].Line, Entries[High(Entries)].Line]));
    Writeln;

    Writeln('--- what the debugger resolves ---');
    var BoundRva: UInt64;
    if Reader.SourceLineToRva(BaseName, Line, BoundRva) then
      Writeln('  SourceLineToRva -> ', DescribeRva(Reader, BoundRva))
    else
      Writeln('  SourceLineToRva -> <no direct hit at line ', Line, '>');
    Writeln;

    Writeln('--- all candidate RVAs at line ', Line, ' ---');
    ReportCandidates(Reader, Entries, Line);
    Writeln;

    var NearestLine: Integer;
    if not FirstLineWithCodeAtOrAfter(Entries, Line, NearestLine) then begin
      Writeln('  No line at or after ', Line, ' emitted code in this file.');
      Exit;
    end;
    if NearestLine = Line then begin
      Writeln('  Line ', Line, ' emits code -- the breakpoint lands on the requested line.');
      Exit;
    end;
    Writeln('  Line ', Line, ' emits no code. Nearest following line with code = ',
      NearestLine, ':');
    ReportCandidates(Reader, Entries, NearestLine);
  finally
    Reader.Free;
  end;
end;

begin
  try
    if ParamCount < 3 then begin
      PrintUsage;
      Halt(1);
    end;

    var ModulePath := ParamStr(1);
    var SourceFile := ParamStr(2);
    var Line := StrToIntDef(ParamStr(3), 0);
    if Line <= 0 then begin
      Writeln('ERROR: <line> must be a positive integer, got "', ParamStr(3), '"');
      PrintUsage;
      Halt(1);
    end;
    if not FileExists(ModulePath) then begin
      Writeln('ERROR: module not found: ', ModulePath);
      Halt(1);
    end;

    Run(ModulePath, SourceFile, Line);
    Writeln;
    Writeln('done.');
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
