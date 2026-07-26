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
  DebugTarget, DebugInfoSet, TargetLayout, DelphiValueReaders, WinDebuggerBase;

type
  TWin32Debugger = class(TWinDebugger)
  private
    // One page in the debuggee holding an FPU-capture stub and its scratch. The
    // synthetic call returns HERE rather than straight at the INT3 trap; the
    // stub writes the x87 state to memory and jumps on to the trap, so the
    // shared pump still sees the breakpoint at the address it recognises.
    FStubScratch: UInt64;   // 108-byte FNSAVE image
    FStubCode:    UInt64;   // fnsave / frstor / jmp trap
    function EnsureFpuCaptureStub: Boolean;
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

    // Delphi's 32-bit `register` convention -- arguments in EAX/EDX/ECX and on
    // the stack at their declared widths, results out of EDX:EAX or the x87
    // stack.
    function  PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
                const ArgValues: array of UInt64;
                const ArgKinds:  array of TSyntheticArgKind;
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

// Builds the FPU-capture stub in the debuggee, once per session.
//
// Reading the x87 result out of the thread context does not work: the WOW64
// context reports FP state as of the last WOW64 transition, so ST(0) comes back
// empty (TOP=0, all register bytes zero) even when the callee has just returned
// a value in it. Measured, not assumed -- and true of both the legacy FloatSave
// view and the FXSAVE area.
//
// So the value is captured in the debuggee instead. FNSAVE is the right
// instruction for it because it is a NO-WAIT form: it cannot raise, even when
// the x87 stack is empty, which is what makes this safe to run after EVERY
// synthetic call rather than only the ones expected to return a float. (A bare
// `fstp` would fault on an empty stack, and nothing in this seam knows what the
// callee returns.) FNSAVE also reinitialises the FPU, so FRSTOR puts back what
// the CALLEE left -- which still includes the returned value, since by the x87
// ABI popping it is the caller's job and the stub is not that caller.
//
//   DD 35 <abs32>   fnsave  [scratch]     -- 108-byte image, cannot fault
//   DD 25 <abs32>   frstor  [scratch]     -- put the callee's state back
//   E9 <rel32>      jmp     RemoteCallTrap
//
// That leftover value does NOT accumulate across calls, and the reason is worth
// knowing before anyone changes it: the shared pump in RunMethodCall saves the
// thread context with CONTEXT_FULL **or CONTEXT_FLOATING_POINT** before the call
// and restores it after reading the result, and on a WOW64 thread that is the
// same physical x87 stack. Dropping CONTEXT_FLOATING_POINT from that save/restore
// would make every float-returning evaluation leak one x87 slot and overflow the
// debuggee's FPU on the eighth -- silently, since ST(0) reads correctly right up
// until it wraps. Measured: twelve consecutive float evaluations in one session
// all return the right value.
function TWin32Debugger.EnsureFpuCaptureStub: Boolean;
const
  FNSAVE_IMAGE_BYTES = 108;
  CODE_OFFSET        = 112;          // past the image, 4-byte aligned
var
  Code: array[0..16] of Byte;
begin
  Result := (FStubCode <> 0);
  if Result then
    Exit;
  var Trap := RemoteCallTrap;
  if (Trap = 0) or (ProcessHandle = 0) then
    Exit;
  var Page := VirtualAllocEx(ProcessHandle, nil, CODE_OFFSET + SizeOf(Code),
    MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  if Page = nil then
    Exit;
  var Base    := UInt64(Page);
  var Scratch := Cardinal(Base);
  var CodeVA  := Base + CODE_OFFSET;

  Code[0] := $DD; Code[1] := $35;  PCardinal(@Code[2])^  := Scratch;   // fnsave
  Code[6] := $DD; Code[7] := $25;  PCardinal(@Code[8])^  := Scratch;   // frstor
  Code[12] := $E9;                                                     // jmp rel32
  PInteger(@Code[13])^ := Integer(Int64(Trap) - Int64(CodeVA + 17));

  if not WriteMemoryAt(CodeVA, @Code[0], SizeOf(Code)) then
    Exit;
  FlushInstructionCache(ProcessHandle, Pointer(CodeVA), SizeOf(Code));
  FStubScratch := Base;
  FStubCode    := CodeVA;
  Result := True;
end;

// Delphi's 32-bit `register` convention. Every rule below was MEASURED against
// dcc32 output (DevTools\PrologProbe, DevTools\Win32FloatArgProbe) rather than
// taken from documentation, which disagrees with itself here.
//
//   * Three register slots exist -- EAX, EDX, ECX -- and only an argument that
//     fits 32 bits and is NOT floating-point competes for one. Everything else
//     goes on the stack and consumes no slot, so the ordinals after it keep
//     taking registers: `Foo(A: Integer; B: Double; C: Integer)` puts A in EAX,
//     B on the stack and C in EDX.
//   * Stack arguments are pushed LEFT TO RIGHT -- the opposite of cdecl. An
//     eight-parameter routine put its stack five at D=+24, E=+20, F=+16, G=+12,
//     H=+8: H closest to the return address means H was pushed last. So the
//     FIRST stack argument sits at the HIGHEST address.
//   * Widths are not uniform: Single 4, Double 8, Int64 and Currency 8, and
//     Extended 12 -- ten bytes of x87 padded to a 4-byte boundary.
//   * There is no shadow space and no 16-byte alignment requirement.

// Bytes one argument of this kind occupies on the x86 stack. Measured, not
// derived from SizeOf: an Extended is ten bytes of x87 but is given TWELVE,
// padded up to a 4-byte boundary.
function StackWidthOf(Kind: TSyntheticArgKind): Cardinal;
begin
  case Kind of
    sakInt64, sakDouble: Result := 8;
    sakExtended:         Result := 12;
  else
    Result := 4;      // sakOrdinal and sakSingle
  end;
end;

// Only a value that fits 32 bits AND is not floating-point competes for one of
// the three register slots. Everything else goes on the stack WITHOUT consuming
// a slot, which is why `Foo(A: Integer; B: Double; C: Integer)` puts A in EAX,
// B on the stack, and C in EDX rather than on the stack behind B.
function TakesRegisterSlot(Kind: TSyntheticArgKind): Boolean;
begin
  Result := Kind = sakOrdinal;
end;

function TWin32Debugger.PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
  const ArgValues: array of UInt64; const ArgKinds:  array of TSyntheticArgKind;
  const SavedCtx: TContext): Boolean;
const
  REGISTER_SLOTS = 3;               // EAX, EDX, ECX
var
  Ctx: TWow64Context;
begin
  Result := False;
  if not EnsureFpuCaptureStub then
    Exit;
  if RemoteCallTrap = 0 then
    Exit;
  if Length(ArgKinds) <> Length(ArgValues) then
    Exit;

  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_FULL;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;

  // PASS 1 -- hand out the three register slots, then record what is left over
  // in declaration order along with the width each one will occupy.
  var Regs: array[0..REGISTER_SLOTS - 1] of DWORD;
  for var R := 0 to REGISTER_SLOTS - 1 do
    Regs[R] := 0;
  var RegsUsed  := 0;
  var StackArgs: TArray<Integer> := [];
  var StackBytes: Cardinal := 0;
  for var I := 0 to High(ArgValues) do begin
    if TakesRegisterSlot(ArgKinds[I]) and (RegsUsed < REGISTER_SLOTS) then begin
      Regs[RegsUsed] := DWORD(ArgValues[I]);
      Inc(RegsUsed);
    end else begin
      StackArgs := StackArgs + [I];
      Inc(StackBytes, StackWidthOf(ArgKinds[I]));
    end;
  end;

  // PASS 2 -- lay the stack out. Arguments are pushed LEFT TO RIGHT (measured;
  // the opposite of cdecl), so the first stack argument ends up at the HIGHEST
  // address and the last sits immediately above the return address.
  var Esp := (Ctx.Esp and not DWORD(3)) - (4 + StackBytes);
  // Return into the FPU-capture stub rather than straight at the trap: it saves
  // the x87 state to memory and jumps on to the trap, so the pump still sees the
  // INT3 at the address it recognises.
  var Ret32: Cardinal := Cardinal(FStubCode);
  if not WriteMemoryAt(Esp, @Ret32, 4) then
    Exit;

  var Cursor: Cardinal := Esp + 4 + StackBytes;   // just past the last argument
  for var J := 0 to High(StackArgs) do begin
    var I     := StackArgs[J];
    var Width := StackWidthOf(ArgKinds[I]);
    Dec(Cursor, Width);
    // Extended is the only kind whose value is not already in the target's own
    // encoding: it travels through the seam as Double bits, because that is all
    // an 8-byte slot can carry, and is widened to 80 bits here. The two padding
    // bytes stay zero.
    if ArgKinds[I] = sakExtended then begin
      var Bytes: array[0..11] of Byte;
      FillChar(Bytes, SizeOf(Bytes), 0);
      var AsDouble: Double := 0;
      PUInt64(@AsDouble)^ := ArgValues[I];
      DoubleToExtendedBytes(AsDouble, Bytes);
      if not WriteMemoryAt(Cursor, @Bytes[0], Width) then
        Exit;
    end else begin
      // Everything else is written straight from the low Width bytes of the
      // value: a Single already carries its 4-byte pattern, a Currency the
      // scaled Int64.
      var Raw: UInt64 := ArgValues[I];
      if not WriteMemoryAt(Cursor, @Raw, Integer(Width)) then
        Exit;
    end;
  end;

  Ctx.Esp := Esp;
  Ctx.Eip := DWORD(FuncVA);
  Ctx.Eax := Regs[0];
  Ctx.Edx := Regs[1];
  Ctx.Ecx := Regs[2];
  Ctx.EFlags := Ctx.EFlags and (not DWORD($100));   // clear TF
  Result := Wow64SetThreadContext(TH, Ctx);
end;

// EAX carries the integer result, EDX:EAX a 64-bit one, and a floating-point
// result arrives via the capture stub rather than the thread context.
//
// Combining EDX:EAX is safe for the same reason it is on x64, where IntResult
// is the whole of RAX: the consumer masks the raw value down to the declared
// type's width before using it, so a 32-bit return discards EDX exactly as it
// discards RAX's high half. An earlier note here claimed the opposite and was
// wrong.
//
// The x87 state cannot be read from the WOW64 thread context at all: both the
// legacy FloatSave view and the FXSAVE area report ST(0) empty, because the
// context carries FP state as of the last WOW64 transition rather than the live
// stack. Hence the capture stub, which asks the debuggee itself -- FNSAVE
// executes in the target and writes its own image, so it cannot be stale.
//
// FNSAVE rather than FSTP is what makes the stub unconditional. FSTP on an empty
// stack raises invalid-operation, which Delphi unmasks by default, so an FSTP
// stub could only be planted when a float result is expected -- and the seam is
// told which ARGUMENTS are floats, never what the callee RETURNS. FNSAVE cannot
// fault, so one stub serves every call and the tag word then reports whether a
// float was actually returned.
//
// FNSAVE image layout (32-bit): control word at +0, status at +4, tag at +8,
// then the register area from +28, ten bytes each.
//
// THE TRAP, which cost three wrong conclusions before it was spotted: the tag
// word is indexed by PHYSICAL register (two bits each, 11b = empty, so ST(0)'s
// tag is at bit offset TOP*2), but the saved register AREA is in STACK order
// with ST(0) ALWAYS in the first slot. Scaling the register offset by TOP reads
// ST(7) and produces a plausible wrong number rather than an obvious failure.
//
// The value handed back is the nearest Double's bit pattern, matching what the
// x64 side puts in this slot (the low qword of XMM0). Callers that need a
// different encoding -- a Single's 4-byte pattern, a Currency's scaled Int64 --
// convert from it; see TExprEvaluator.NormaliseFloatReturn.
function TWin32Debugger.ReadSyntheticCallResult(TH: THandle;
  out IntResult, FloatResultLow: UInt64): Boolean;
const
  FN_STATUS = 4;
  FN_TAG    = 8;
  FN_ST0    = 28;
  FN_STRIDE = 10;
  TAG_EMPTY = 3;
var
  Ctx:   TWow64Context;
  Image: array[0..107] of Byte;
begin
  IntResult      := 0;
  FloatResultLow := 0;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_FULL;
  Result := Wow64GetThreadContext(TH, Ctx);
  if not Result then
    Exit;
  IntResult := (UInt64(Ctx.Edx) shl 32) or UInt64(Ctx.Eax);

  if FStubScratch = 0 then
    Exit;
  if not ReadProcessMemoryAt(FStubScratch, @Image[0], SizeOf(Image)) then
    Exit;
  var Fsw := PWord(@Image[FN_STATUS])^;
  var Ftw := PWord(@Image[FN_TAG])^;
  var Top := (Fsw shr 11) and 7;
  // Nothing on the x87 stack: an integer-returning call. Leave the float slot
  // at zero rather than decoding whatever bytes happen to be in the register.
  if ((Ftw shr (Top * 2)) and 3) = TAG_EMPTY then
    Exit;
  var Reg: array[0..9] of Byte;
  Move(Image[FN_ST0], Reg[0], 10);
  FloatResultLow := ExtendedBytesToDoubleBits(Reg);
end;
end.
