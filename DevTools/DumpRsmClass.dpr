program DumpRsmClass;
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  RsmFileReader  in '..\DebuggerCore\RsmFileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';
begin
  if ParamCount < 2 then begin Writeln('Usage: <rsm> <classname>'); Halt(1); end;
  var R := TRsmFile.Create;
  try
    R.LoadFromFile(ParamStr(1));
    Writeln('SysUtils imports list (selected idx around 364..366):');
    var Imports := R.DiagUnitImports('SysUtils');
    Writeln(Format('  total length: %d', [Length(Imports)]));
    for var I := 360 to 370 do
      if (I >= 0) and (I < Length(Imports)) then
        Writeln(Format('  [%d] = %s', [I, Imports[I]]));
    // Try the hypothesis: ODD TypeId $2DD -> idx = (TypeId-1)/2 - 1 = 365
    Writeln(Format('  hypothesis idx for $2DD: (($2DD-1)/2)-1 = %d  -> %s',
      [(($2DD - 1) div 2) - 1, Imports[(($2DD - 1) div 2) - 1]]));
    Writeln;
    Writeln('FClassHashCandidates[$2DD]:');
    for var C in R.DiagClassHashCandidates($2DD) do
      Writeln('  ', C);
    Writeln;
    Writeln('FTypeIdToName containing "Exception":');
    for var P in R.DiagTypeIdsForName('Exception') do
      Writeln(Format('  $%x -> %s', [P.Key, P.Value]));
    Writeln;
    Writeln('LookupTypeName probes:');
    for var Tid in [Integer($2DD), Integer($12), Integer($1C), Integer($14)] do
      Writeln(Format('  TypeId $%x -> "%s"', [Tid, R.DiagLookupTypeName(Tid)]));
    Writeln;
    var Members: TArray<TClassMember>;
    if not R.GetClassMembers(ParamStr(2), Members) then begin
      Writeln('Class not found: ', ParamStr(2)); Halt(2);
    end;
    Writeln(Format('Class %s -- %d members:', [ParamStr(2), Length(Members)]));
    for var M in Members do begin
      var Kind: string;
      case M.Kind of
        cmkField:    Kind := 'field';
        cmkMethod:   Kind := 'method';
        cmkProperty: Kind := 'prop';
      end;
      Writeln(Format('  %-7s %-24s  TypeId=$%x  TypeName="%s"  Offset=%d Hash=$%x',
        [Kind, M.Name, M.TypeId, M.TypeName, M.FieldOffset, M.Hash]));
    end;
  finally R.Free; end;
end.
