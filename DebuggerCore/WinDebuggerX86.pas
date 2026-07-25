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

// Delphi's 32-bit `register` convention passes the first three arguments in
// EAX/EDX/ECX with the rest pushed right to left, has no shadow space, and
// returns floats on the x87 stack rather than in an SSE register. Refusing is
// correct until that is implemented: the inherited x64 version would place
// arguments in registers the callee never reads.
function TWin32Debugger.PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
  const ArgValues: array of UInt64; const ArgIsFloat: array of Boolean;
  const SavedCtx: TContext): Boolean;
begin
  Result := False;
end;

function TWin32Debugger.ReadSyntheticCallResult(TH: THandle;
  out IntResult, FloatResultLow: UInt64): Boolean;
begin
  IntResult      := 0;
  FloatResultLow := 0;
  Result := False;
end;

end.
