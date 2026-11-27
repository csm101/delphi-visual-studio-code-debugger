program AnalysisSample;

// Fixture for the ROUTINE ANALYSIS (DebuggerCore\RoutineAnalysis.pas,
// docs/PROFILER_COVERAGE_PLAN.md increment 4). Every routine here is a shape
// the analysis has to get right, and a shape a plain linear decode gets wrong:
//
//   * DenseCase         -- a `case` over consecutive values: dcc32 emits
//                          `jmp [reg*4+T]` with the table T right after the jmp;
//   * IndexedCase       -- a `case` with many values and few labels: dcc32 puts
//                          a BYTE INDEX table between the jmp and the address
//                          table;
//   * TryFinally        -- a `try..finally` left the normal way (x86: `pop eax;
//                          jmp eax` to a pushed continuation; x64: the funclet);
//   * RaiseThroughFinally -- the same block run by an exception passing through;
//   * ExceptWithOn      -- `on` clauses: a clause table on both bitnesses;
//   * BareExcept        -- `except` with no `on`: no table at all;
//   * SafecallShape     -- a safecall routine: its handler is a funclet on x64
//                          and a stub to System.@HandleAutoException on x86;
//   * WithNested        -- routines nested two deep;
//   * WithAnonymous     -- an anonymous method, whose body has NO procedure
//                          record in TD32 on either bitness;
//   * LastStatementIsACall -- the epilogue starts at a return address (the x64
//                          unwinder's window);
//   * FramelessLeaf     -- no prologue, no epilogue, compiled with $O+;
//   * AsmTable          -- hand-written assembly that jumps through a table of
//                          its own, placed after its last `ret`;
//   * OneLineLoop       -- a loop and its body on ONE source line: the line is
//                          entered once and its body runs several times.
//
// The main block runs each of them, so the dynamic test can single-step through
// all of it and compare every address the processor stopped at with what the
// analysis found.
//
// Separate target on purpose. Adding scenarios to TestTarget shifts RSM
// per-unit import indices and perturbs first-hit marker ordering, which has
// broken unrelated tests before (docs/TRAPS.md, "Fixture design").
//
// GUI subsystem and deliberately silent: it is launched by the test runner,
// which drives TDebugSession directly, and nothing here should reach a console.

{$O-}

uses
  FixtureQuiet, System.SysUtils;

var
  GSink: Integer = 0;

{ ------------------------------------------------------------ case tables -- }

function DenseCase(Value: Integer): Integer;
begin
  case Value of                              // {BP:AN_DENSE_CASE}
    0: Result := 11;                         // {BP:AN_DENSE_0}
    1: Result := 22;
    2: Result := 33;
    3: Result := 44;
    4: Result := 55;
    5: Result := 66;
    6: Result := 77;                         // {BP:AN_DENSE_6}
    7: Result := 88;
  else
    Result := -1;                            // {BP:AN_DENSE_ELSE}
  end;
end;

// Twenty-four consecutive values and three labels: one byte per value indexes
// a table of three addresses.
function IndexedCase(Value: Integer): Integer;
begin
  case Value of                              // {BP:AN_INDEXED_CASE}
    0, 2, 4, 6, 8, 10, 12, 14, 16, 18: Result := 1;   // {BP:AN_INDEXED_EVEN}
    1, 3, 5, 7, 9, 11, 13, 15, 17, 19: Result := 2;   // {BP:AN_INDEXED_ODD}
    20..23: Result := 3;                     // {BP:AN_INDEXED_TAIL}
  else
    Result := 0;                             // {BP:AN_INDEXED_ELSE}
  end;
end;

{ ------------------------------------------------------- exception blocks -- }

procedure TryFinally(Delta: Integer);
begin
  Inc(GSink);                                // {BP:AN_FINALLY_BEFORE}
  try
    GSink := GSink + Delta;                  // {BP:AN_FINALLY_BODY}
  finally
    GSink := GSink * 2;                      // {BP:AN_FINALLY_BLOCK}
  end;
  Dec(GSink);                                // {BP:AN_FINALLY_AFTER}
end;

procedure RaiseThroughFinally;
begin
  try
    raise EAbort.Create('through');          // {BP:AN_RAISE_THROUGH}
  finally
    Inc(GSink, 3);                           // {BP:AN_FINALLY_UNWOUND}
  end;
end;

function ExceptWithOn(Fail: Boolean): Integer;
begin
  Result := 0;
  try
    if Fail then
      RaiseThroughFinally;                   // {BP:AN_EXCEPT_ON_BODY}
    Result := 1;
  except
    on E: EAbort do                          // {BP:AN_EXCEPT_ON_CLAUSE}
      Result := 2;                           // {BP:AN_EXCEPT_ON_BLOCK}
    on E: Exception do
      Result := 3;                           // {BP:AN_EXCEPT_ON_OTHER}
  end;
end;

function BareExcept(Fail: Boolean): Integer;
begin
  Result := 0;
  try
    if Fail then
      raise Exception.Create('bare');        // {BP:AN_BARE_BODY}
    Result := 1;
  except
    Result := 2;                             // {BP:AN_BARE_BLOCK}
  end;
end;

// A safecall routine: the compiler wraps its whole body in a handler of its own
// that turns an exception into an HRESULT. On x64 that handler is a funclet --
// a function of its own inside the routine's range; on x86 a stub to
// System.@HandleAutoException.
function SafecallShape(Fail: Boolean): Integer; safecall;
begin
  if Fail then
    raise Exception.Create('safecall');      // {BP:AN_SAFECALL_RAISE}
  Result := 7;                               // {BP:AN_SAFECALL_BODY}
end;

function CallSafecall(Fail: Boolean): Integer;
begin
  try
    Result := SafecallShape(Fail);           // {BP:AN_SAFECALL_CALL}
  except
    Result := -7;                            // {BP:AN_SAFECALL_CAUGHT}
  end;
end;

{ --------------------------------------------- nested and anonymous code -- }

function WithNested(Value: Integer): Integer;
var
  Total: Integer;

  procedure AddTwice(Delta: Integer);

    procedure AddOnce;
    begin
      Inc(Total, Delta);                     // {BP:AN_NESTED_INNER}
    end;

  begin
    AddOnce;                                 // {BP:AN_NESTED_MIDDLE}
    AddOnce;
  end;

begin
  Total := Value;
  AddTwice(5);                               // {BP:AN_NESTED_OUTER}
  Result := Total;
end;

// A capturing closure lives in its OWN routine: inside another one it would
// relocate that routine's frame (docs/TRAPS.md, "Fixture design").
function WithAnonymous(Value: Integer): Integer;
var
  Triple: TFunc<Integer, Integer>;
begin
  Triple := function(X: Integer): Integer
    begin
      Result := X * 3 + Value;               // {BP:AN_ANON_BODY}
    end;
  Result := Triple(7);                       // {BP:AN_ANON_CALL}
end;

{ --------------------------------------------------------- routine shapes -- }

procedure LastStatementIsACall(Value: Integer);
begin
  GSink := Value;                            // {BP:AN_LASTCALL_FIRST}
  TryFinally(Value);                         // {BP:AN_LASTCALL_CALL}
end;

{$O+}
function FramelessLeaf(A, B: Integer): Integer;
begin
  Result := A + B;                           // {BP:AN_LEAF_BODY}
end;
{$O-}

// Jumps through a table of four code addresses that sits AFTER the routine's
// last `ret`: nothing but the jump leads to the four labels.
function AsmTable(Index: Integer): Integer;
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

procedure OneLineLoop;
var
  I: Integer;
begin
  for I := 1 to 3 do Inc(GSink, I);          // {BP:AN_ONELINE_LOOP}
  GSink := GSink + 1;                        // {BP:AN_ONELINE_AFTER}
end;

var
  K: Integer;

begin
  GSink := DenseCase(0) + DenseCase(6) + DenseCase(42);     // {BP:AN_MAIN_FIRST}
  GSink := GSink + IndexedCase(4) + IndexedCase(7) + IndexedCase(22) + IndexedCase(99);
  TryFinally(2);
  GSink := GSink + ExceptWithOn(False) + ExceptWithOn(True);
  GSink := GSink + BareExcept(False) + BareExcept(True);
  GSink := GSink + CallSafecall(False) + CallSafecall(True);
  GSink := GSink + WithNested(1);
  GSink := GSink + WithAnonymous(4);
  LastStatementIsACall(3);
  GSink := GSink + FramelessLeaf(GSink, 2);
  for K := 0 to 4 do
    GSink := GSink + AsmTable(K);                           // {BP:AN_MAIN_ASM}
  OneLineLoop;
  // Keeps the global live so no store above is elided (docs/TRAPS.md: "a local
  // nothing ever reads gets its store ELIDED even under -$O-").
  if GSink = MaxInt then                                    // {BP:AN_MAIN_LAST}
    Halt(1);
end.
