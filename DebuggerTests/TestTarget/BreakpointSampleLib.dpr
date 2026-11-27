library BreakpointSampleLib;

// Fixture for a module that is relocated AFTER its load event
// (docs/DAP_DEBUGGER_ARCHITECTURE.md, "Breakpoints": "A module relocated after
// its load event"). The image has a FIXED base and no dynamic base;
// BreakpointSample reserves that address before LoadLibrary, so the loader has
// to map the DLL elsewhere and relocate it -- which it does after the debugger
// has seen the load event and before the DLL's entry point runs. At the load
// event the absolute addresses in its code still assume the preferred base,
// and the routine analysis must not read it then.
//
// What the tests look at in here:
//
//   * LibFinally  -- a `finally` block run plainly and by an exception: on x64
//                    its breakpoint needs a copy in the funclet, and the copy
//                    is found by the analysis;
//   * LibTable    -- hand-written assembly with a table of code addresses: the
//                    table's source line has a line record, and a breakpoint on
//                    it must be refused. The bytes there are not zero, so the
//                    fallback that applies while the image cannot be analysed
//                    lets it through.
//
// Separate target: a DLL is a project of its own. Built for both bitnesses by
// build_target.bat, next to BreakpointSample.exe, which loads it by name.

{$IMAGEBASE $3A000000}
{$DYNAMICBASE OFF}
{$O-}

uses
  System.SysUtils;

var
  GLibSink: Integer = 0;

procedure LibFinally(Fail: Boolean);
begin
  Inc(GLibSink);                             // {BP:BSL_FINALLY_BEFORE}
  try
    if Fail then
      raise EAbort.Create('lib');
    Inc(GLibSink, 2);
  finally
    GLibSink := GLibSink * 3;                // {BP:BSL_FINALLY_BLOCK}
  end;
end;

// Jumps through a table of four code addresses that sits AFTER the routine's
// last `ret`: the loader relocates its entries.
function LibTable(Index: Integer): Integer;
{$IFDEF CPUX64}
asm
        .NOFRAME
        CMP     ECX, 3
        JA      @@none
        MOVSXD  RCX, ECX
        LEA     R10, [offset @@table]
        JMP     QWORD PTR [R10+RCX*8]
@@zero:
        MOV     EAX, 100
        RET
@@one:
        MOV     EAX, 101
        RET
@@two:
        MOV     EAX, 102
        RET
@@three:
        MOV     EAX, 103
        RET
@@none:
        MOV     EAX, -1
        RET
        .ALIGN 8
@@table:
        DQ      @@zero, @@one, @@two, @@three
end;
{$ELSE}
asm
        CMP     EAX, 3
        JA      @@none
        JMP     DWORD PTR [@@table+EAX*4]
@@zero:
        MOV     EAX, 100
        RET
@@one:
        MOV     EAX, 101
        RET
@@two:
        MOV     EAX, 102
        RET
@@three:
        MOV     EAX, 103
        RET
@@none:
        MOV     EAX, -1
        RET
        .ALIGN 4
@@table:
        DD      @@zero, @@one, @@two, @@three
end;
{$ENDIF}

// Runs everything once and returns what it computed, for the host to check:
// 1, 3, 9 after the plain pass; 10, 30 after the pass an exception cut short;
// 31 once it is caught; plus 100 + 101 + 102 + 103.
function LibRun: Integer; stdcall;
var
  K: Integer;
begin
  LibFinally(False);                         // {BP:BSL_RUN_FIRST}
  try
    LibFinally(True);
  except
    on E: EAbort do
      Inc(GLibSink);
  end;
  for K := 0 to 3 do
    GLibSink := GLibSink + LibTable(K);
  Result := GLibSink;
end;

exports
  LibRun;

begin
end.
