program InstructionStepSample;

// Fixture for INSTRUCTION-GRANULARITY stepping (docs/ASSEMBLY_LEVEL_DEBUGGING.md
// increment 1). Every scenario here exists because a source-line step cannot
// produce it:
//
//   * a source line made of several instructions, so "one instruction" can be
//     told apart from "one line";
//   * a plain call, to separate step-into (enters the callee) from step-over
//     (must NOT single-step the call);
//   * a RECURSIVE call, whose deeper incarnations return to the very same
//     address the step-over's one-shot breakpoint sits on -- the case that
//     needs the stack-pointer guard, not just a thread-scoped breakpoint;
//   * a `rep movsb` over 64 KB, THE new hazard: a rep-prefixed instruction
//     traps once per ITERATION, so a trap-flag step retires one iteration and
//     leaves the PC where it was. Written in asm because it must be a rep
//     instruction on BOTH bitnesses by construction -- Delphi's own System.Move
//     picks its strategy by size and architecture, so a large Move is not a
//     dependable way to get one;
//   * a call that writes a watched global, so a hardware watchpoint firing
//     during an instruction step can be shown not to end it.
//
// Separate target on purpose. Adding scenarios to TestTarget shifts RSM
// per-unit import indices and perturbs first-hit marker ordering, which has
// broken unrelated tests before (docs/TRAPS.md, "Fixture design").
//
// GUI subsystem and deliberately silent: it is launched by the test runner,
// which drives TDebugSession directly, and nothing here should reach a console.

{$O-}

uses
  System.SysUtils;

const
  REP_BLOCK_SIZE = 65536;   // large enough that stepping it per-iteration is
                            // unmistakably a hang rather than a slow step

var
  GSink:        Integer = 0;
  GDepthSum:    Integer = 0;
  GInstrWatched: Integer = 0;
  GRepSrc:      array[0..REP_BLOCK_SIZE - 1] of Byte;
  GRepDst:      array[0..REP_BLOCK_SIZE - 1] of Byte;

{ ------------------------------------------------- a plain call to step ---- }

function InstrStepCallee(A, B: Integer): Integer;
begin
  Result := A * 3;          // {BP:INSTR_CALLEE_BODY}
  Result := Result + B;
end;

procedure InstrStepCallScenario;
var
  X: Integer;
begin
  X := 7;
  // Several instructions on ONE source line, so a single-instruction step can
  // be distinguished from a source-line step by the line NOT changing. Not the
  // routine's first statement, deliberately: a breakpoint on the first
  // statement is subject to entry/body adjustment (docs/TRAPS.md).
  X := (X * 3) + (X shr 2) - 5;            // {BP:INSTR_MULTI}
  GSink := InstrStepCallee(X, 5) + X;      // {BP:INSTR_CALLSITE}
  GSink := GSink + 1;                      // {BP:INSTR_CALLSITE_NEXT}
end;

{ ----------------------------------------------- a recursive call to step -- }

// The deeper incarnations return to the SAME address as the outermost one, one
// or more frames lower. A step-over whose one-shot breakpoint compares only the
// address (and the thread) ends on the first, innermost return: the right
// instruction, the wrong frame.
function InstrStepRecurse(Depth: Integer): Integer;
begin
  if Depth <= 0 then
    Exit(0);
  Result := InstrStepRecurse(Depth - 1) + Depth;
end;

procedure InstrStepRecursionScenario;
begin
  GSink     := 0;
  GDepthSum := InstrStepRecurse(4);        // {BP:INSTR_RECURSE_ENTRY}
end;

{ ------------------------------------------------------ a rep instruction -- }

// Win64: RCX=Src, RDX=Dst, R8=Count.  Win32 register convention: EAX, EDX, ECX.
// Both verified to compile and to copy the whole block.
procedure InstrStepRepMove(Src, Dst: Pointer; Count: NativeUInt);
{$IFDEF CPUX64}
asm
  push rsi
  push rdi
  mov  rsi, rcx
  mov  rdi, rdx
  mov  rcx, r8
  cld
  rep  movsb
  pop  rdi
  pop  rsi
end;
{$ELSE}
asm
  push esi
  push edi
  mov  esi, eax
  mov  edi, edx
  cld
  rep  movsb
  pop  edi
  pop  esi
end;
{$ENDIF}

procedure InstrStepRepScenario;
begin
  FillChar(GRepSrc, SizeOf(GRepSrc), $5A);
  FillChar(GRepDst, SizeOf(GRepDst), 0);
  InstrStepRepMove(@GRepSrc[0], @GRepDst[0], REP_BLOCK_SIZE);  // {BP:INSTR_REP_CALL}
  GSink := GRepDst[REP_BLOCK_SIZE - 1];                        // {BP:INSTR_REP_NEXT}
end;

{ ------------------------------------ a watched write inside a stepped call - }

procedure InstrStepWriteWatched;
begin
  GInstrWatched := GInstrWatched + 1;      // {BP:INSTR_WATCH_BODY}
end;

procedure InstrStepWatchScenario;
begin
  GSink := 0;
  InstrStepWriteWatched;                   // {BP:INSTR_WATCH_CALL}
  GSink := GSink + 1;                      // {BP:INSTR_WATCH_NEXT}
end;

{ ------------------------- reference-typed locals for the memory-view tests - }

// A `string` and a dynamic array are the two shapes whose SLOT holds a pointer
// and whose bytes live elsewhere, which is what a memory view has to resolve
// correctly. Both values are chosen so their bytes are unambiguous when read
// back: 'Hex' is three ASCII characters (six bytes of UTF-16), and the array is
// four bytes no other buffer in this program would produce.
type
  // An object with a string FIELD: the case where the row a memory view is
  // opened on is a CHILD of an expansion rather than a local. Its slot holds a
  // pointer exactly like a local string's does.
  TMemRefHolder = class
  public
    FText: string;
    constructor Create(const AText: string);
  end;

constructor TMemRefHolder.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
end;

procedure InstrStepMemRefScenario;
begin
  var Text: string := 'Hex';
  var Buf: TBytes := [$11, $22, $33, $44];
  var Holder := TMemRefHolder.Create('Chars');
  // Two extents the type table cannot be trusted for on its own: `Extended` is
  // the one float whose width is target-dependent (8 on Win64, 10 on Win32),
  // and a NIL class reference has no instance to measure -- the variable is
  // still one pointer of storage, which is what the view is open on.
  var Wide: Extended := 1.5;
  var Obj: TObject := nil;
  // One line, and the marker on it: a breakpoint set on the CONTINUATION line of
  // a split statement has no line-table entry to bind to, and the test then
  // fails as "Timeout waiting for stopped event".
  GSink := Length(Text) + Length(Buf) + Trunc(Wide) + Ord(Obj <> nil) + Length(Holder.FText);  // {BP:INSTR_MEMREF}
  Holder.Free;
end;

begin
  InstrStepCallScenario;
  InstrStepRecursionScenario;
  InstrStepRepScenario;
  InstrStepWatchScenario;
  InstrStepMemRefScenario;
  // Keeps every global live so no store above is elided (docs/TRAPS.md: "a local
  // nothing ever reads gets its store ELIDED even under -$O-").
  if (GSink = MaxInt) and (GDepthSum = MaxInt) and (GInstrWatched = MaxInt) then
    Halt(1);
end.
