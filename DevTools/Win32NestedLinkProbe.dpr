program Win32NestedLinkProbe;

// Measures where dcc32 puts the STATIC LINK -- the hidden parent-frame pointer a
// nested procedure receives so it can reach the enclosing routine's variables.
//
// The debugger needs it to show a nested procedure's full lexical scope. On
// Win64 the answer is known and implemented: the link arrives in RCX and Delphi
// spills it to the first home slot, at `RBP + frameSize + extraPushes + 16`.
// That formula is hardcoded, and Win32 has no home slots at all, so on a 32-bit
// target the climb reads whatever is at that address. Measured symptom: standing
// in `Inner`, the locals view shows ONLY Inner's own variables, while the same
// source built for Win64 also shows `ComputeNested.X`, `.D1`, `.Ext1`, `.R48`.
//
// Rather than assume the classic `[EBP+8]`, this finds the offset empirically:
// the enclosing routine records its own EBP, the nested one then scans its
// frame for a slot holding that value and reports every offset that matches.
//
// Several shapes are measured because the answer may depend on them: whether
// the nested routine takes parameters of its own, and how deep the nesting is.
//
// 32-bit only -- it must be COMPILED BY dcc32 to observe dcc32 output.
//   DevTools\build_one32.bat Win32NestedLinkProbe.dpr
//   DevTools\Win32\Debug\Win32NestedLinkProbe.exe

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

var
  GOuterEbp:  NativeUInt;
  GMiddleEbp: NativeUInt;

function CurrentEbp: NativeUInt;
asm
  MOV EAX, EBP
end;

// Prints every offset from the nested routine's EBP whose slot holds Wanted.
// The RANGE deliberately covers both sides: a hidden parameter sits at a
// POSITIVE offset (above the saved EBP and return address), while a spilled
// register parameter sits at a NEGATIVE one under -$O-.
procedure ReportMatches(const Caption: string; ChildEbp, Wanted: NativeUInt);
begin
  Writeln('--- ', Caption, ' ---');
  Writeln(Format('  child EBP  = $%.8x', [ChildEbp]));
  Writeln(Format('  wanted     = $%.8x  (the enclosing routine''s EBP)', [Wanted]));
  var Found := 0;
  for var Ofs := -64 to 64 do begin
    var Slot := PNativeUInt(NativeInt(ChildEbp) + Ofs * SizeOf(Pointer));
    if Slot^ <> Wanted then
      Continue;
    var Sign := '+';
    if Ofs < 0 then
      Sign := '-';
    Writeln(Format('  MATCH at [EBP%s%d]  (slot %d)',
      [Sign, Abs(Ofs) * SizeOf(Pointer), Ofs]));
    Inc(Found);
  end;
  if Found = 0 then
    Writeln('  no slot in [EBP-256 .. EBP+256] holds the parent frame pointer');
end;

// Shape 1: a parameterless nested procedure.
procedure OuterSimple;
var
  Marker: Integer;

  procedure Inner;
  begin
    Marker := 1;   // forces a real static-link use
    ReportMatches('parameterless nested proc', CurrentEbp, GOuterEbp);
  end;

begin
  GOuterEbp := CurrentEbp;
  Marker := 0;
  Inner;
end;

// Shape 2: the nested routine takes parameters of its own, which under the
// `register` convention occupy the slots a hidden parameter might otherwise use.
procedure OuterWithArgs;
var
  Marker: Integer;

  procedure Inner(A, B, C, D: Integer);
  begin
    Marker := A + B + C + D;
    ReportMatches('nested proc with four parameters', CurrentEbp, GOuterEbp);
  end;

begin
  GOuterEbp := CurrentEbp;
  Marker := 0;
  Inner(1, 2, 3, 4);
end;

// Shape 3: two levels. The innermost routine reaches the OUTERMOST variable,
// which is the case that says whether the link chains or is passed directly.
procedure OuterTwoLevels;
var
  OuterMarker: Integer;

  procedure Middle;
  var
    MiddleMarker: Integer;

    procedure Inner;
    begin
      OuterMarker  := 1;
      MiddleMarker := 2;
      ReportMatches('two levels: inner -> middle', CurrentEbp, GMiddleEbp);
      ReportMatches('two levels: inner -> outer',  CurrentEbp, GOuterEbp);
    end;

  begin
    GMiddleEbp := CurrentEbp;
    MiddleMarker := 0;
    Inner;
  end;

begin
  GOuterEbp := CurrentEbp;
  OuterMarker := 0;
  Middle;
end;

// Shape 4: the disambiguator. In every shape above the nested routine is called
// DIRECTLY by its parent, so the saved caller EBP at [EBP+0] happens to equal
// the parent's EBP and shows up as a match that means nothing. Recursing once
// breaks that coincidence: on the second entry the caller is Inner itself, so
// any slot still holding the PARENT's EBP is the static link and nothing else.
procedure OuterRecursive;
var
  Marker: Integer;

  procedure Inner(Depth: Integer);
  begin
    Marker := Depth;
    if Depth > 0 then begin
      Inner(Depth - 1);
      Exit;
    end;
    ReportMatches('recursed nested proc (caller is NOT the parent)',
      CurrentEbp, GOuterEbp);
  end;

begin
  GOuterEbp := CurrentEbp;
  Marker := 0;
  Inner(1);
end;

begin
  Writeln('dcc32 static-link placement for nested procedures');
  Writeln('pointer size = ', SizeOf(Pointer));
  Writeln;
  OuterSimple;
  Writeln;
  OuterWithArgs;
  Writeln;
  OuterTwoLevels;
  Writeln;
  OuterRecursive;
  Writeln;
  Writeln('done.');
end.
