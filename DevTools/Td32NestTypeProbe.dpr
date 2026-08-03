program Td32NestTypeProbe;

// Dumps the LF_NESTTYPE ($0409) relations a binary's embedded TD32 carries:
// which types are declared INSIDE a class or record.
//
// Why it exists: the LF_NESTTYPE field layout was read by analogy with the
// neighbouring leaves (LF_METHOD, LF_MEMBER), not from a specification. A wrong
// field offset would silently mark unrelated types as nested, and the debugger
// would then refuse to resolve identifiers that are perfectly legal. So the
// layout is CONFIRMED here against a real binary -- every line must name an
// owner and a nested type that actually exist -- before anything depends on it.
//
// The case that motivated it: DevExpress declares
//   TdxPopupMenuController = class ... strict protected type
//     TPopupMenuKind = (External, VCL, Application);
// so `Application` is an enum member of a CLASS-NESTED type. It is not reachable
// by a bare name from anywhere, yet a flat scan of every enum in every loaded
// module answered `Application` with it -- outranking the VCL global of the same
// name, whose own module carries no debug info.
//
//   Td32NestTypeProbe.exe <pe-file> [name-filter]
//
// <pe-file> is any exe/dll/bpl with an embedded `.debug` (TD32) section.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.StrUtils,
  TD32FileReader;

begin
  if ParamCount < 1 then begin
    Writeln('usage: Td32NestTypeProbe.exe <pe-file> [name-filter]');
    Halt(1);
  end;
  var Path   := ParamStr(1);
  var Filter := ParamStr(2);
  if not FileExists(Path) then begin
    Writeln('not found: ', Path);
    Halt(2);
  end;

  var Reader := TTD32FileReader.Create;
  try
    try
      Reader.LoadFromFile(Path);
    except
      on E: Exception do begin
        Writeln('load failed: ', E.ClassName, ': ', E.Message);
        Halt(3);
      end;
    end;

    // Control question first. "No nested types found" is only meaningful if the
    // type table was read at all -- otherwise the probe is measuring its own
    // silence. So report whether the filtered type EXISTS and what kind it is.
    if Filter <> '' then begin
      var Rec: TTD32TypeRecord;
      if Reader.FindTypeByName(Filter, Rec) then begin
        Writeln(Format('control: type "%s" IS in the table (kind=%d, typeId=$%x, %d member(s))',
          [Filter, Ord(Rec.Kind), Rec.Index, Length(Rec.Members)]));
        // The RAW name, before demangling. If the compiler qualifies a nested
        // type here, nesting is derivable from the name alone and no
        // LF_NESTTYPE is needed.
        Writeln(Format('control: raw NAMES entry (idx=%d) = "%s"',
          [Rec.NameIdx, Reader.DiagResolveName(Rec.NameIdx)]));
        for var M in Rec.Members do
          Writeln(Format('           member "%s" = %d', [M.Name, M.Offset]));
      end
      else
        Writeln(Format('control: type "%s" is NOT in the type table', [Filter]));
    end;

    var Lines := Reader.DiagNestedTypes(Filter);
    Writeln(Format('%s: %d nested-type relation(s)%s',
      [ExtractFileName(Path), Length(Lines),
       IfThen(Filter <> '', ' matching "' + Filter + '"', '')]));
    for var L in Lines do
      Writeln('  ', L);
    if Length(Lines) = 0 then
      Writeln('  (none -- either the binary has no nested types, or the ' +
              'LF_NESTTYPE parse is not reaching them)');
  finally
    Reader.Free;
  end;
end.
