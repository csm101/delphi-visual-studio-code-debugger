program Td32AliasProbe;

{$APPTYPE CONSOLE}

// Answers: does TD32 carry named float aliases (TDateTime / Real / Extended),
// or does it really flatten them onto the Double primitive ($0041)?
//
// Usage:
//   Td32AliasProbe.exe <exe-or-bpl> [name1 name2 ...]
//
// Section 1 -- named type-table lookup for each requested name (defaults to the
// float aliases). A hit means the TYPES table has a record carrying that name.
// Section 2 -- every distinct local TypeId in the binary that resolves to a
// float-family name, with the type chain and one sample local. If a local
// declared `TDateTime` reports TypeId $0041 the name is genuinely absent from
// the VARIABLE record, whatever section 1 says.

uses
  System.SysUtils,
  System.Generics.Collections,
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  RsmFileReader in '..\DebuggerCore\RsmFileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';

const
  DefaultNames: array[0..7] of string = (
    'TDateTime', 'TDate', 'TTime', 'Real', 'Extended', 'Double', 'Currency', 'Single');

procedure ReportNamedTypes(Reader: TTD32FileReader; const Names: TArray<string>);
begin
  Writeln('== named type-table lookup ==');
  for var Nm in Names do begin
    var Rec: TTD32TypeRecord;
    if Reader.FindTypeByName(Nm, Rec) then
      Writeln(Format('  %-12s FOUND  idx=$%x leaf=$%.4x kind=%d size=%d base=$%x  chain=%s',
        [Nm, Rec.Index, Rec.LeafCode, Ord(Rec.Kind), Rec.Size, Rec.BaseTypeId,
         Reader.DescribeTypeChain(Cardinal(Rec.Index))]))
    else
      Writeln(Format('  %-12s not in the TYPES table', [Nm]));
  end;
end;

function LooksFloaty(const S: string): Boolean;
begin
  for var Frag in ['double', 'single', 'extended', 'real', 'currency', 'date', 'time'] do
    if Pos(Frag, LowerCase(S)) > 0 then
      Exit(True);
  Result := False;
end;

procedure ReportLocalTypeIds(Reader: TTD32FileReader);
begin
  Writeln('== distinct float-family TypeIds seen on locals/params ==');
  Reader.ExposeLocals := True;
  var Seen := TDictionary<Integer, string>.Create;
  try
    for var Proc in Reader.AllProcedureNames do begin
      var Locals: TArray<TLocalSymbol>;
      if not Reader.GetLocalsForFunction(Proc, Locals) then
        Continue;
      for var L in Locals do begin
        if Seen.ContainsKey(L.TypeId) then
          Continue;
        var Nm := Reader.GetTypeName(Cardinal(L.TypeId));
        if not (LooksFloaty(Nm) or LooksFloaty(L.TypeHint)) then
          Continue;
        Seen.Add(L.TypeId, '');
        Writeln(Format('  TypeId=$%.4x  GetTypeName=%-16s TypeHint=%-16s chain=%-28s sample=%s.%s',
          [L.TypeId, Nm, L.TypeHint, Reader.DescribeTypeChain(Cardinal(L.TypeId)), Proc, L.Name]));
      end;
    end;
    if Seen.Count = 0 then
      Writeln('  (none -- no float-family local found; is ExposeLocals data present?)');
  finally
    Seen.Free;
  end;
end;

procedure ReportProcLocals(Reader: TTD32FileReader; const ProcName: string);
begin
  Reader.ExposeLocals := True;
  var Locals: TArray<TLocalSymbol>;
  if not Reader.GetLocalsForFunction(ProcName, Locals) then begin
    Writeln('  no locals for ' + ProcName);
    Exit;
  end;
  Writeln('== locals of ' + ProcName + ' ==');
  for var L in Locals do begin
    var KindText := 'local';
    if L.Kind = lkVarParam then
      KindText := 'varParam';
    Writeln(Format('  %-20s kind=%-10s TypeId=$%.4x  name=%-20s hint=%s',
      [L.Name, KindText, L.TypeId,
       Reader.GetTypeName(Cardinal(L.TypeId)), L.TypeHint]));
  end;
end;

procedure ReportClassMembers(Reader: TTD32FileReader; const ClassName: string);
begin
  var Members: TArray<TClassMember>;
  if not Reader.GetClassMembers(ClassName, Members) then begin
    Writeln('  class not found: ' + ClassName);
    Exit;
  end;
  Writeln('== members of ' + ClassName + ' ==');
  for var M in Members do
    Writeln(Format('  %-24s off=%-5d TypeId=$%.4x  TypeName=%-20s resolved=%-20s chain=%s',
      [M.Name, M.FieldOffset, M.TypeId, M.TypeName, Reader.GetTypeName(Cardinal(M.TypeId)),
       Reader.DescribeTypeChain(Cardinal(M.TypeId))]));
end;

// Same question asked of an RSM-format file (.rsm or the RSM-format .dcp that
// ships beside a BPL). If the alias survives here, a package's types do not need
// a DCU reader -- the sidecar we already load carries them.
procedure ReportRsmProcLocals(const RsmPath, ProcName: string);
begin
  var R := TRsmFile.Create;
  try
    R.LoadFromFile(RsmPath);
    if not R.Loaded then begin
      Writeln('  RSM/DCP not loaded: ' + RsmPath);
      Exit;
    end;
    var Locals: TArray<TLocalSymbol>;
    if not R.GetLocalsForFunction(ProcName, Locals) then begin
      Writeln('  no locals for ' + ProcName + ' in ' + RsmPath);
      Exit;
    end;
    Writeln('== RSM/DCP locals of ' + ProcName + ' (' + RsmPath + ') ==');
    for var L in Locals do
      Writeln(Format('  %-20s TypeId=$%.4x  hint=%s', [L.Name, L.TypeId, L.TypeHint]));
  finally
    R.Free;
  end;
end;

// Lists every proc in an RSM/DCP whose locals carry a type hint matching Filter.
// Used to FIND a subject in a real package instead of guessing a routine name.
procedure ScanRsmForTypeHint(const RsmPath, Filter: string; MaxHits: Integer);
begin
  var R := TRsmFile.Create;
  try
    R.LoadFromFile(RsmPath);
    if not R.Loaded then begin
      Writeln('  RSM/DCP not loaded: ' + RsmPath);
      Exit;
    end;
    Writeln(Format('== procs in %s with a local typed like "%s" ==', [RsmPath, Filter]));
    var Hits := 0;
    for var Proc in R.AllProcedureNames do begin
      var Locals: TArray<TLocalSymbol>;
      if not R.GetLocalsForFunction(Proc, Locals) then
        Continue;
      for var L in Locals do begin
        if Pos(LowerCase(Filter), LowerCase(L.TypeHint)) = 0 then
          Continue;
        Writeln(Format('  %-50s %-20s hint=%s', [Proc, L.Name, L.TypeHint]));
        Inc(Hits);
        Break;
      end;
      if Hits >= MaxHits then
        Break;
    end;
    if Hits = 0 then
      Writeln('  (no local carries that type hint)');
  finally
    R.Free;
  end;
end;

// Which name does each provider give for ONE module RVA? Reproduces exactly what
// a stack frame shows, so "why is this frame named X" is answered by the provider
// that returned X rather than by reading the chain and guessing.
procedure ReportNameAtRva(const BinPath, RsmPath: string; Rva: UInt64);
begin
  var T := TTD32FileReader.Create;
  try
    T.LoadFromFile(BinPath);
    var Nm: string;
    if T.Loaded and T.RvaToFunctionName(Rva, Nm) then
      Writeln(Format('  TD32 : %s', [Nm]))
    else
      Writeln('  TD32 : (no name)');
  finally
    T.Free;
  end;
  if RsmPath = '' then
    Exit;
  var R := TRsmFile.Create;
  try
    R.LoadFromFile(RsmPath);
    if not R.Loaded then begin
      Writeln('  RSM  : (not loaded) ' + RsmPath);
      Exit;
    end;
    var Locals: TArray<TLocalSymbol>;
    Writeln(Format('  RSM  : locals-by-rva hit=%s (%s)',
      [BoolToStr(R.GetLocalsForFunctionByRva(Rva, Locals), True), RsmPath]));
  finally
    R.Free;
  end;
end;

// Walks the line table and reports every DISTINCT function name containing
// Fragment. Unlike AllProcedureNames this goes through the same
// RvaToFunctionName the call stack uses, so it shows what a frame would display.
procedure ReportNamesViaRva(const BinPath, Fragment: string; MaxHits: Integer);
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(BinPath);
    if not R.Loaded then begin
      Writeln('No TD32 in ' + BinPath);
      Exit;
    end;
    var Seen := TDictionary<string, Boolean>.Create;
    try
      var Total := 0;
      for var Rva in R.SortedRvas do begin
        var Nm: string;
        if not R.RvaToFunctionName(Rva, Nm) then
          Continue;
        if Seen.ContainsKey(Nm) then
          Continue;
        Seen.Add(Nm, True);
        Inc(Total);
        if Pos(LowerCase(Fragment), LowerCase(Nm)) = 0 then
          Continue;
        if Seen.Count <= MaxHits + Total then
          Writeln('  ' + Nm);
      end;
      Writeln(Format('  [%d distinct function names walked]', [Total]));
    finally
      Seen.Free;
    end;
  finally
    R.Free;
  end;
end;

// Raw symbol-record scan: shows the name as STORED, before any demangling, so a
// frame label that looks wrong can be traced to the record it came from.
procedure ReportSymbolRecords(const BinPath, Filter: string; MaxHits: Integer);
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(BinPath);
    if not R.Loaded then begin
      Writeln('No TD32 in ' + BinPath);
      Exit;
    end;
    var Hits := 0;
    for var L in R.DiagFindSymbolRecords(Filter) do begin
      Writeln('  ' + L);
      Inc(Hits);
      if Hits >= MaxHits then
        Break;
    end;
    if Hits = 0 then
      Writeln('  (no record matched)');
  finally
    R.Free;
  end;
end;

// What proc names does TD32 actually EXPOSE for this binary? Answers "why does
// the call stack read `TFoo@Bar` instead of `TFoo.Bar`" -- the demangler either
// ran or it did not, and this shows which.
procedure ReportProcNames(const BinPath, Fragment: string; MaxHits: Integer);
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(BinPath);
    if not R.Loaded then begin
      Writeln('No TD32 in ' + BinPath);
      Exit;
    end;
    Writeln(Format('== TD32 proc names matching "%s" in %s ==', [Fragment, BinPath]));
    var Hits := 0;
    for var N in R.AllProcedureNames do begin
      if Pos(LowerCase(Fragment), LowerCase(N)) = 0 then
        Continue;
      Writeln('  ' + N);
      Inc(Hits);
      if Hits >= MaxHits then
        Break;
    end;
    if Hits = 0 then
      Writeln('  (no match)');
  finally
    R.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: Td32AliasProbe.exe <exe-or-bpl> [typename ...]');
      Writeln('       Td32AliasProbe.exe <exe-or-bpl> -proc <fully.qualified.procname>');
      Writeln('       Td32AliasProbe.exe <exe-or-bpl> -class <ClassName>');
      Writeln('       Td32AliasProbe.exe <rsm-or-dcp> -rsmproc <fully.qualified.procname>');
      Writeln('       Td32AliasProbe.exe <rsm-or-dcp> -rsmscan <TypeNameFragment> [maxHits]');
      Halt(1);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-namescan') then begin
      var MaxHits := 40;
      if ParamCount >= 4 then
        MaxHits := StrToIntDef(ParamStr(4), 40);
      Writeln(Format('== function names containing "%s" in %s ==', [ParamStr(3), ParamStr(1)]));
      ReportNamesViaRva(ParamStr(1), ParamStr(3), MaxHits);
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-symscan') then begin
      var MaxHits := 25;
      if ParamCount >= 4 then
        MaxHits := StrToIntDef(ParamStr(4), 25);
      ReportSymbolRecords(ParamStr(1), ParamStr(3), MaxHits);
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-rvaname') then begin
      var RvaTxt := ParamStr(3);
      if RvaTxt.StartsWith('$') then
        RvaTxt := RvaTxt.Substring(1);
      Writeln(Format('== name at RVA $%s in %s ==', [RvaTxt, ParamStr(1)]));
      ReportNameAtRva(ParamStr(1), ParamStr(4), StrToInt64('$' + RvaTxt));
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-procscan') then begin
      var MaxHits := 20;
      if ParamCount >= 4 then
        MaxHits := StrToIntDef(ParamStr(4), 20);
      ReportProcNames(ParamStr(1), ParamStr(3), MaxHits);
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-rsmproc') then begin
      ReportRsmProcLocals(ParamStr(1), ParamStr(3));
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-rsmscan') then begin
      var MaxHits := 20;
      if ParamCount >= 4 then
        MaxHits := StrToIntDef(ParamStr(4), 20);
      ScanRsmForTypeHint(ParamStr(1), ParamStr(3), MaxHits);
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-proc') then begin
      var R1 := TTD32FileReader.Create;
      try
        R1.LoadFromFile(ParamStr(1));
        ReportProcLocals(R1, ParamStr(3));
      finally
        R1.Free;
      end;
      Halt(0);
    end;
    if (ParamCount >= 3) and SameText(ParamStr(2), '-class') then begin
      var R2 := TTD32FileReader.Create;
      try
        R2.LoadFromFile(ParamStr(1));
        ReportClassMembers(R2, ParamStr(3));
      finally
        R2.Free;
      end;
      Halt(0);
    end;
    var Names: TArray<string>;
    if ParamCount >= 2 then begin
      for var I := 2 to ParamCount do
        Names := Names + [ParamStr(I)];
    end
    else
      for var Nm in DefaultNames do
        Names := Names + [Nm];

    var Reader := TTD32FileReader.Create;
    try
      Reader.LoadFromFile(ParamStr(1));
      if not Reader.Loaded then begin
        Writeln('No TD32 debug info in ' + ParamStr(1));
        Halt(2);
      end;
      Writeln('TD32 loaded: ' + ParamStr(1));
      ReportNamedTypes(Reader, Names);
      Writeln;
      ReportLocalTypeIds(Reader);
    finally
      Reader.Free;
    end;
  except
    on E: Exception do begin
      Writeln('ERROR: ' + E.ClassName + ': ' + E.Message);
      Halt(3);
    end;
  end;
end.
