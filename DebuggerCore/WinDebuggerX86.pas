unit WinDebuggerX86;

// Debugs a 32-bit (WOW64) target from this 64-bit adapter.
//
// A 64-bit process can debug a 32-bit one; the reverse is impossible. That
// asymmetry is why the adapter stays a single 64-bit binary instead of shipping
// a second 32-bit build: the MCP server is registered once at editor startup
// with a fixed command, long before any target exists, so it could never pick
// the right one.
//
// This class overrides ONLY the architecture seam. Everything else -- the debug
// event loop, breakpoint planting, stepping, module handling, the synthetic-call
// event pump -- is architecture neutral and inherited unchanged.
//
// What a 32-bit target changes, all measured rather than assumed (Phase 0, see
// DevTools\Wow64StackProbe.dpr and DevTools\PrologProbe.dpr):
//
//   * Traps arrive under the WOW64 layer's own status codes. Handled in the
//     shared debug loop, which accepts $4000001F and $4000001E alongside the
//     native ones.
//   * The register file is reached through Wow64Get/SetThreadContext.
//   * StackWalk64 unwinds i386 correctly given a WOW64 context; dbghelp
//     contributes nothing to that walk for a Delphi target, so no hand-rolled
//     EBP walker is needed.
//   * `mov ebp,esp` PRECEDES the frame allocation on x86 -- the opposite of
//     x64 -- so the return address is always [EBP+4] and no frame size is
//     needed to find it.
//   * There is NO x86 analogue of the Win64 parameter home slot.

interface

uses
  Winapi.Windows,
  DebugTarget, DebugInfoSet, TargetLayout, Win64Debugger;

type
  TWin32Debugger = class(TWinDebugger)
  protected
    function  StackWalkMachineType: DWORD; override;

    function  ReadThreadRegisters(TID: DWORD; out Regs: TRegisterSnapshot): Boolean; override;
    function  SetThreadPc(TID: DWORD; VA: UInt64): Boolean; override;
    function  SetThreadTrapFlag(TID: DWORD; Enable: Boolean): Boolean; override;
    function  FillStackWalkContext(TH: THandle; var Buf: TContext;
                out SeedPc, SeedSp, SeedFp: UInt64): Boolean; override;

    function  ReadPrologInfo(EntryVA: UInt64; out ExtraPushBytes: UInt32;
                out Recognised: Boolean): UInt32; override;
    function  LocalsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer; override;
    function  ParamsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer; override;

    // Not yet implemented for x86; each refuses rather than inheriting the x64
    // answer, which would be confidently wrong.
    function  PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
                const ArgValues: array of UInt64;
                const ArgIsFloat: array of Boolean;
                const SavedCtx: TContext): Boolean; override;
    function  ReadSyntheticCallResult(TH: THandle;
                out IntResult, FloatResultLow: UInt64): Boolean; override;
  public
    // Public in the base class, so kept public here.
    function  TargetLayout: TTargetLayout; override;
    function  CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64; override;
  end;

implementation

{ ------------------------------------------------------------ architecture -- }

function TWin32Debugger.TargetLayout: TTargetLayout;
begin
  Result := TTargetLayout.For32Bit;
end;

function TWin32Debugger.StackWalkMachineType: DWORD;
begin
  Result := IMAGE_FILE_MACHINE_I386;
end;

{ ---------------------------------------------------------- register access -- }

// TRegisterSnapshot is a 64-bit superset of both register files. A 32-bit
// target fills the low half of each field and leaves R8..R15 zero, so a consumer
// asking for a ROLE (Pc / StackPtr / FramePtr) gets a correct answer while one
// reading a physical 64-bit name gets a meaningless one -- which is why the
// role accessors exist.
function TWin32Debugger.ReadThreadRegisters(TID: DWORD;
  out Regs: TRegisterSnapshot): Boolean;
var
  Ctx: TWow64Context;
  TH:  THandle;
begin
  Regs := Default(TRegisterSnapshot);
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_FULL;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;
  Regs.Rip    := Ctx.Eip;
  Regs.Rsp    := Ctx.Esp;
  Regs.Rbp    := Ctx.Ebp;
  Regs.Rax    := Ctx.Eax;
  Regs.Rbx    := Ctx.Ebx;
  Regs.Rcx    := Ctx.Ecx;
  Regs.Rdx    := Ctx.Edx;
  Regs.Rsi    := Ctx.Esi;
  Regs.Rdi    := Ctx.Edi;
  Regs.EFlags := Ctx.EFlags;
  Regs.Valid  := True;
  Result := True;
end;

function TWin32Debugger.SetThreadPc(TID: DWORD; VA: UInt64): Boolean;
var
  Ctx: TWow64Context;
  TH:  THandle;
begin
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_CONTROL;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;
  Ctx.Eip := DWORD(VA);
  Result := Wow64SetThreadContext(TH, Ctx);
end;

function TWin32Debugger.SetThreadTrapFlag(TID: DWORD; Enable: Boolean): Boolean;
const
  TRAP_FLAG = DWORD($100);
var
  Ctx: TWow64Context;
  TH:  THandle;
begin
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_CONTROL;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;
  if Enable then
    Ctx.EFlags := Ctx.EFlags or TRAP_FLAG
  else
    Ctx.EFlags := Ctx.EFlags and (not TRAP_FLAG);
  Result := Wow64SetThreadContext(TH, Ctx);
end;

// StackWalk64 wants the raw context it will unwind, which for IMAGE_FILE_MACHINE_I386
// is a WOW64_CONTEXT. Buf is typed TContext because it is the larger and
// correctly aligned of the two; the smaller WOW64 context is written at its
// start and the walk never reads Buf's fields again.
function TWin32Debugger.FillStackWalkContext(TH: THandle; var Buf: TContext;
  out SeedPc, SeedSp, SeedFp: UInt64): Boolean;
var
  Ctx: PWow64Context;
begin
  SeedPc := 0;
  SeedSp := 0;
  SeedFp := 0;
  Buf := Default(TContext);
  Ctx := PWow64Context(@Buf);
  Ctx^.ContextFlags := WOW64_CONTEXT_FULL;
  Result := Wow64GetThreadContext(TH, Ctx^);
  if not Result then
    Exit;
  SeedPc := Ctx^.Eip;
  SeedSp := Ctx^.Esp;
  SeedFp := Ctx^.Ebp;
end;

{ --------------------------------------------------------- prologue decode -- }

// x86 has no .pdata, so byte-pattern matching is the ONLY strategy and it has
// to be right. The shapes below were measured against dcc32 output rather than
// inferred from the x64 decoder (DevTools\PrologProbe.dpr, 17 deliberately
// shaped routines), and they differ from x64 in ways that matter:
//
//   * Delphi allocates with `add esp,-N` (83 C4 / 81 C4, NEGATIVE immediate),
//     not `sub esp,N`. A decoder matching only `sub` reports frame size 0 on
//     nearly every routine.
//   * `mov ebp,esp` runs BEFORE the allocation, the opposite of x64. Requiring
//     it immediately after `push ebp` is also what rejects an optimised frame
//     where EBP is pushed as an ordinary callee-saved register.
//   * Pushes and allocations appear in either order and may repeat, so the
//     decode accumulates rather than expecting a fixed sequence.
//   * A frame larger than a page uses a 16-byte probe loop whose page count is
//     an immediate, plus 4 bytes for the eax it saves.
function TWin32Debugger.ReadPrologInfo(EntryVA: UInt64;
  out ExtraPushBytes: UInt32; out Recognised: Boolean): UInt32;
var
  Bytes: array[0..31] of Byte;

  function CanRead(Off, Need, Avail: Integer): Boolean;
  begin
    Result := Off + Need <= Avail;
  end;

  // 50                 push eax
  // B8 nn nn nn nn     mov eax,<page count>
  // 81 C4 04 F0 FF FF  add esp,-0FFCh
  // 50 / 48 / 75 F6    push eax; dec eax; jnz
  function IsStackProbeLoop(At, Avail: Integer; out PageCount: UInt32): Boolean;
  begin
    Result := False;
    PageCount := 0;
    if not CanRead(At, 16, Avail) then Exit;
    if (Bytes[At] <> $50) or (Bytes[At + 1] <> $B8) then Exit;
    if (Bytes[At + 6] <> $81) or (Bytes[At + 7] <> $C4) or
       (Bytes[At + 8] <> $04) or (Bytes[At + 9] <> $F0) or
       (Bytes[At + 10] <> $FF) or (Bytes[At + 11] <> $FF) then Exit;
    if (Bytes[At + 12] <> $50) or (Bytes[At + 13] <> $48) or
       (Bytes[At + 14] <> $75) then Exit;
    PageCount := PCardinal(@Bytes[At + 2])^;
    Result := True;
  end;

begin
  Result := 0;
  ExtraPushBytes := 0;
  Recognised := False;
  FillChar(Bytes, SizeOf(Bytes), 0);
  if not ReadProcessMemoryAt(EntryVA, @Bytes, SizeOf(Bytes)) then
    Exit;
  var Avail := SizeOf(Bytes);
  if Bytes[0] <> $55 then           // push ebp
    Exit;
  var Off := 1;
  // mov ebp,esp -- 8B EC, or the alternate 89 E5 encoding.
  if CanRead(Off, 2, Avail) and (Bytes[Off] = $8B) and (Bytes[Off + 1] = $EC) then
    Inc(Off, 2)
  else if CanRead(Off, 2, Avail) and (Bytes[Off] = $89) and (Bytes[Off + 1] = $E5) then
    Inc(Off, 2)
  else
    Exit;                           // EBP pushed but not established: not a frame

  Recognised := True;

  var Done := False;
  while (not Done) and CanRead(Off, 1, Avail) do begin
    var PageCount: UInt32;
    if IsStackProbeLoop(Off, Avail, PageCount) then begin
      Inc(ExtraPushBytes, 4);       // the eax the loop saves
      Inc(Result, PageCount * 4096);
      Inc(Off, 16);
      // The saved eax is reloaded immediately: 8B 45 disp8 (mov eax,[ebp+d]).
      if CanRead(Off, 3, Avail) and (Bytes[Off] = $8B) and (Bytes[Off + 1] = $45) then
        Inc(Off, 3);
      Continue;
    end;
    case Bytes[Off] of
      // push r32. A `push ecx` used to reserve one slot and a `push ebx` saving
      // a register are the same instruction; both just move esp down 4.
      $50..$57:
        begin
          Inc(ExtraPushBytes, 4);
          Inc(Off);
        end;
      $83:
        begin
          if not CanRead(Off, 3, Avail) then Break;
          if Bytes[Off + 1] = $EC then begin
            Inc(Result, Bytes[Off + 2]);            // sub esp,imm8
            Inc(Off, 3);
          end else if Bytes[Off + 1] = $C4 then begin
            Inc(Result, UInt32(-ShortInt(Bytes[Off + 2])));  // add esp,-imm8
            Inc(Off, 3);
          end else
            Done := True;
        end;
      $81:
        begin
          if not CanRead(Off, 6, Avail) then Break;
          if Bytes[Off + 1] = $EC then begin
            Inc(Result, PUInt32(@Bytes[Off + 2])^);          // sub esp,imm32
            Inc(Off, 6);
          end else if Bytes[Off + 1] = $C4 then begin
            Inc(Result, UInt32(-PInteger(@Bytes[Off + 2])^)); // add esp,-imm32
            Inc(Off, 6);
          end else
            Done := True;
        end;
    else
      Done := True;
    end;
  end;
end;

// On x86 `mov ebp,esp` precedes the allocation, so a debug-info offset is
// already relative to the frame pointer: locals are at negative offsets and
// parameters at positive ones, with nothing to add back. The x64 bases exist
// only because its frame pointer is established AFTER the allocation.
function TWin32Debugger.LocalsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer;
begin
  Result := 0;
end;

function TWin32Debugger.ParamsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer;
begin
  Result := 0;
end;

{ ------------------------------------------------------- not yet implemented -- }

// Measured in Phase 0: on x86 the first three parameters travel in EAX/EDX/ECX
// with no stack home at all and are spilled to NEGATIVE EBP offsets, while
// stack parameters run in reverse declaration order. Self is provably not at
// EBP+8. There is therefore no positional formula to port -- the answer has to
// come from debug-info symbol offsets. 0 is this method's documented
// "unavailable".
function TWin32Debugger.CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64;
begin
  Result := 0;
end;

{ ------------------------------------------------------- synthetic call ABI -- }

// Delphi's 32-bit `register` convention: the first three arguments travel in
// EAX, EDX and ECX in declaration order, and the rest go on the stack.
//
// The stack ORDER was taken from measurement, not documentation. PrologProbe
// compiled an eight-parameter routine with dcc32 and found A/B/C spilled to
// EBP-4/-8/-12 (the register three) and the remainder at D=+24, E=+20, F=+16,
// G=+12, H=+8. H sitting closest to the return address means H was pushed
// LAST, so the stack arguments are pushed left to right -- the opposite of
// cdecl. Laying the frame out by hand, argument i of n therefore lands at
// [ESP + 4 + 4*(n-1-i)].
//
// There is no shadow space and no 16-byte alignment requirement.
function TWin32Debugger.PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
  const ArgValues: array of UInt64; const ArgIsFloat: array of Boolean;
  const SavedCtx: TContext): Boolean;
var
  Ctx: TWow64Context;
begin
  Result := False;
  // Floats do not travel in the integer registers on x86 and are returned on
  // the x87 stack, neither of which this implements yet. Refuse rather than
  // place a float where the callee will read an integer.
  for var I := 0 to High(ArgIsFloat) do
    if ArgIsFloat[I] then
      Exit;

  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_FULL;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;

  var StackArgs := Length(ArgValues) - 3;
  if StackArgs < 0 then
    StackArgs := 0;
  // Return address plus the stack arguments, below the current stack pointer.
  var Esp := (Ctx.Esp and not DWORD(3)) - DWORD(4 + 4 * StackArgs);
  var Trap := RemoteCallTrap;
  if Trap = 0 then
    Exit;
  var Trap32: Cardinal := Cardinal(Trap);
  if not WriteMemoryAt(Esp, @Trap32, 4) then
    Exit;
  for var I := 3 to High(ArgValues) do begin
    var Slot: Cardinal := Cardinal(ArgValues[I]);
    var Addr := UInt64(Esp) + 4 + 4 * UInt64(High(ArgValues) - I);
    if not WriteMemoryAt(Addr, @Slot, 4) then
      Exit;
  end;

  Ctx.Esp := Esp;
  Ctx.Eip := DWORD(FuncVA);
  if Length(ArgValues) > 0 then Ctx.Eax := DWORD(ArgValues[0]);
  if Length(ArgValues) > 1 then Ctx.Edx := DWORD(ArgValues[1]);
  if Length(ArgValues) > 2 then Ctx.Ecx := DWORD(ArgValues[2]);
  Ctx.EFlags := Ctx.EFlags and (not DWORD($100));   // clear TF
  Result := Wow64SetThreadContext(TH, Ctx);
end;

// Converts an x87 80-bit extended to the bit pattern of the nearest Double,
// which is what the shared code expects to find in FloatResultLow (on x64 that
// slot holds the low qword of XMM0, i.e. a Double).
//
// The 80-bit layout is sign(1) | exponent(15, bias 16383) | mantissa(64, with an
// EXPLICIT leading integer bit). A Double is sign(1) | exponent(11, bias 1023) |
// mantissa(52, leading bit implicit), so the conversion re-biases the exponent
// and drops both the explicit integer bit and the 11 lowest mantissa bits.
function ExtendedBytesToDoubleBits(const Bytes: array of Byte): UInt64;
begin
  Result := 0;
  var Mantissa: UInt64 := PUInt64(@Bytes[0])^;
  var SignExp:  Word   := PWord(@Bytes[8])^;
  var Sign:     UInt64 := UInt64(SignExp shr 15) shl 63;
  var Exp80:    Integer := SignExp and $7FFF;

  if (Exp80 = 0) and (Mantissa = 0) then
    Exit(Sign);                        // +/- zero
  if Exp80 = $7FFF then                // infinity or NaN
    Exit(Sign or (UInt64($7FF) shl 52) or (Mantissa shr 11) and ((UInt64(1) shl 52) - 1));

  var Exp64 := Exp80 - 16383 + 1023;
  if Exp64 <= 0 then
    Exit(Sign);                        // underflows a Double: report zero
  if Exp64 >= $7FF then
    Exit(Sign or (UInt64($7FF) shl 52));  // overflows: report infinity

  // Drop the explicit integer bit (bit 63) and keep the next 52.
  var Frac := (Mantissa shr 11) and ((UInt64(1) shl 52) - 1);
  Result := Sign or (UInt64(Exp64) shl 52) or Frac;
end;

// EAX carries the integer/pointer result.
//
// KNOWN GAP 1 -- Int64 returns. An Int64 comes back in EDX:EAX and only EAX is
// reported. Combining them blindly would be worse, not better: on x64 a 32-bit
// result leaves the high half of RAX zeroed by the hardware, but x86 leaves EDX
// holding whatever the callee last put there, so every ordinary Integer return
// would come back with garbage in its high half. Reporting EAX alone reproduces
// the x64 behaviour up to 32 bits and truncates only genuine Int64 returns,
// which is the narrower failure of the two.
//
// KNOWN GAP 2 -- floating-point returns. What is and is not known, measured
// rather than guessed, so the next attempt does not repeat the dead ends:
//
//   * The 80-bit to Double decode above is CORRECT. Verified by hand against
//     3.25, whose extended form converts to $400A000000000000, exactly the
//     Double bit pattern for 3.25.
//   * This function IS reached for a Double-returning getter -- instrumented
//     and confirmed. An earlier note claiming the fault lay upstream in
//     ExprEval was WRONG; it rested on a diagnostic that never compiled in.
//   * WOW64_CONTEXT_FLOATING_POINT returns a FloatSave area that is entirely
//     zero, status word included. That legacy FNSAVE view is not what the WOW64
//     layer fills, which is why the FXSAVE area is read instead.
//   * The FXSAVE area IS populated -- its status word reads $0020, not zero --
//     but ST(0) is EMPTY at this point: TOP is 0 and the register bytes are all
//     zero, on every call observed.
//
// TOP=0 with every register byte zero is a RESET FPU image, not a used one --
// a callee that had just pushed a result would leave TOP=7. So the WOW64
// context most likely reports FP state as of the last WOW64 transition rather
// than the thread's live x87 stack, and no combination of context flags will
// reach it.
//
// The obvious workaround is to return the synthetic call into a stub that
// stores ST(0) to memory first -- `DD 1D <disp32>` (fstp qword ptr [addr])
// followed by the INT3, written into the same page as the return trap, with
// eight bytes of scratch alongside. That much is easy.
//
// What makes it a DESIGN change rather than a quick fix: `fstp` on an empty
// stack raises invalid-operation, and Delphi unmasks that by default, so the
// stub may only be used when a float result is actually expected. Nothing in
// this seam knows that -- PrepareSyntheticCall is told which ARGUMENTS are
// floats, never what the callee returns. Doing this properly means adding the
// expected result class to the seam, which touches the shared pump and the x64
// implementation too. It is a contained change, but it is not a local one, and
// bolting it on without that signal would break every integer call.
//
// Do NOT read the 0 this currently produces as a value.
function TWin32Debugger.ReadSyntheticCallResult(TH: THandle;
  out IntResult, FloatResultLow: UInt64): Boolean;
var
  Ctx: TWow64Context;
begin
  IntResult      := 0;
  FloatResultLow := 0;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_FULL or WOW64_CONTEXT_FLOATING_POINT or
                      WOW64_CONTEXT_EXTENDED_REGISTERS;
  Result := Wow64GetThreadContext(TH, Ctx);
  if not Result then
    Exit;
  IntResult := Ctx.Eax;

  // FXSAVE layout: FCW at +0, FSW at +2, then the eight registers from +32, one
  // every 16 bytes with only the low 10 in use. RegisterArea holds the PHYSICAL
  // registers R0..R7 while ST(0) is R[TOP], so the stack top has to come out of
  // the status word (bits 11..13) rather than be assumed to be register zero.
  const FX_STATUS_WORD = 2;
  const FX_ST0         = 32;
  const FX_REG_STRIDE  = 16;
  if Length(Ctx.ExtendedRegisters) < FX_ST0 + 8 * FX_REG_STRIDE then
    Exit;
  var Fsw := PWord(@Ctx.ExtendedRegisters[FX_STATUS_WORD])^;
  var Top := (Fsw shr 11) and 7;
  var Reg: array[0..9] of Byte;
  Move(Ctx.ExtendedRegisters[FX_ST0 + Integer(Top) * FX_REG_STRIDE], Reg[0], 10);
  FloatResultLow := ExtendedBytesToDoubleBits(Reg);
end;

end.
