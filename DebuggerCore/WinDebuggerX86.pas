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
//   * StackWalk64 unwinds i386 given a WOW64 context, and dbghelp contributes
//     nothing to that walk for a Delphi target. Phase 0 concluded from this that
//     no hand-rolled EBP walker was needed; the FIELD disproved it (see
//     WalkRawFrames below), so the EBP chain now drives the walk and StackWalk64
//     is the fallback.
//   * `mov ebp,esp` PRECEDES the frame allocation on x86 -- the opposite of
//     x64 -- so the return address is always [EBP+4] and no frame size is
//     needed to find it.
//   * There is NO x86 analogue of the Win64 parameter home slot.

interface

uses
  Winapi.Windows,
  DebugTarget, DebugInfoSet, TargetLayout, DelphiValueReaders, WinDebuggerBase,
  X86Decode;

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
    // The 32-bit TEB, which is not the one the OS reports for a WOW64 thread.
    function  TryGetThreadTeb(TID: DWORD; out TebVA: UInt64;
                out Reason: string): Boolean; override;
    function  LastErrorOffset: Cardinal; override;
    function  LastStatusOffset: Cardinal; override;

    function  ReadThreadRegisters(TID: DWORD; out Regs: TRegisterSnapshot): Boolean; override;
    function  SetThreadPc(TID: DWORD; VA: UInt64): Boolean; override;
    function  SetThreadTrapFlag(TID: DWORD; Enable: Boolean): Boolean; override;
    function  ReadDebugRegisters(TID: DWORD; out Regs: TDebugRegisters): Boolean; override;
    function  WriteDebugRegisters(TID: DWORD; const Regs: TDebugRegisters): Boolean; override;
    function  FillStackWalkContext(TH: THandle; var Buf: TContext;
                out SeedPc, SeedSp, SeedFp: UInt64): Boolean; override;
    function  WalkRawFrames(TH: THandle; SeedPc, SeedSp, SeedFp: UInt64;
                MaxFrames: Integer): TArray<TRawStackFrame>; override;
    function  CallSiteVerdictAt(VA: UInt64): TCallSiteAnswer; override;
    // x86 has no `.pdata`, so the base class's scope-table decode has nothing to
    // read. The 32-bit answer lives in the fs:[0] registration chain, and only
    // PART of it is derivable -- see the body.
    function  PlanExceptionStep(Tid: DWORD; out Plan: TExceptionStepPlan;
                out RefusalReason: string): Boolean; override;
    // Declines, always -- see the body.
    function  TryGetExceptHandlerBlockAt(PC: UInt64;
                out Blk: TExcHandlerBlock): Boolean; override;
    function  ExceptHandlerScopeUnavailableReason: string; override;
    // Base address of the 32-bit TEB of Tid, which is where fs:[0] points.
    function  Teb32Base(Tid: DWORD; out Base: UInt64; out How: string): Boolean;

    function  ReadPrologInfo(EntryVA: UInt64; out ExtraPushBytes: UInt32;
                out Recognised: Boolean): UInt32; override;
    // A nested procedure's static link. Declines on purpose -- see the body.
    function  ReadParentFramePointer(ChildRBP: UInt64;
                ChildFrameSize, ChildExtraPushBytes: UInt32): UInt64; override;
    function  LocalsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer; override;
    function  ParamsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer; override;
    function  CallerReturnAddress(TID: DWORD): UInt64; override;

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
    function  SetRegisterByName(const Name: string; Value: UInt64): Boolean; override;
  end;

implementation

uses
  System.SysUtils,
  DapProtocol;   // DapLog: why a candidate frame was refused

// Reaching the 32-bit TEB of a WOW64 thread. Neither is in Winapi.Windows.
function Wow64GetThreadSelectorEntry(hThread: THandle; dwSelector: DWORD;
  var lpSelectorEntry: TLdtEntry): BOOL; stdcall;
  external kernel32 name 'Wow64GetThreadSelectorEntry';

function NtQueryInformationThread(ThreadHandle: THandle;
  ThreadInformationClass: DWORD; ThreadInformation: Pointer;
  ThreadInformationLength: ULONG; ReturnLength: PULONG): Integer; stdcall;
  external 'ntdll.dll';

{ ------------------------------------------------------------ architecture -- }

function TWin32Debugger.TargetLayout: TTargetLayout;
begin
  Result := TTargetLayout.For32Bit;
end;

function TWin32Debugger.StackWalkMachineType: DWORD;
begin
  Result := IMAGE_FILE_MACHINE_I386;
end;

function TWin32Debugger.LastErrorOffset: Cardinal;
begin
  Result := $34;   // TEB32.LastErrorValue
end;

function TWin32Debugger.LastStatusOffset: Cardinal;
begin
  Result := $BF4;  // TEB32.LastStatusValue
end;

function TWin32Debugger.TryGetThreadTeb(TID: DWORD; out TebVA: UInt64;
  out Reason: string): Boolean;
// A WOW64 thread has TWO TEBs: the 64-bit one the OS reports to a 64-bit
// debugger, and the 32-bit one the target's own code actually writes to. Asking
// the base class and reading LastError out of the answer would read the wrong
// structure and return a number that looks plausible and is not the target's.
//
// The 32-bit TEB sits immediately after the 64-bit one, at TEB64 + $2000. That
// is a layout convention, not a contract, so nothing here trusts it: the
// candidate is accepted only if the 32-bit NtTib.Self at +$18 points back at the
// candidate. If Microsoft ever moves it, this reports False and says why,
// instead of handing out a plausible-looking wrong value.
const
  WOW64_TEB32_FROM_TEB64 = $2000;
  TEB32_SELF_OFFSET      = $18;
begin
  TebVA := 0;
  if not inherited TryGetThreadTeb(TID, TebVA, Reason) then
    Exit(False);
  var Candidate := TebVA + WOW64_TEB32_FROM_TEB64;
  var SelfPtr: DWORD := 0;
  if not ReadProcessMemoryAt(Candidate + TEB32_SELF_OFFSET, @SelfPtr, SizeOf(SelfPtr)) then begin
    Reason := Format('the 32-bit TEB candidate at $%x could not be read', [Candidate]);
    Exit(False);
  end;
  if UInt64(SelfPtr) <> Candidate then begin
    Reason := Format('32-bit TEB self-check failed at $%x (NtTib.Self = $%x)',
                     [Candidate, SelfPtr]);
    Exit(False);
  end;
  TebVA  := Candidate;
  Result := True;
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

// Overrides the base's native GetThreadContext/SetThreadContext pair with the
// documented-correct Wow64Get/SetThreadContext one, replacing an UNVERIFIED
// path with a verified one rather than a provenly-wrong one -- see
// docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 6 for the full measurement writeup
// (DevTools\Wow64RegWriteProbe.dpr). Measured, not assumed: at the WOW64
// loader breakpoint (before the 32-bit environment finishes initialising) a
// native write is genuinely invisible to Wow64GetThreadContext, but at a REAL
// application breakpoint -- an INT3 planted in running 32-bit code, which is
// every stop this debugger actually reports to a user -- the native and
// WOW64 views alias exactly on this measured Windows build, for every
// general-purpose AND control register (RIP/RSP/RBP included), and a native
// write reaches the guest-visible register correctly. This override is kept
// anyway: it matches the rest of the thread-context funnel, uses the
// documented-correct API instead of relying on unspecified OS aliasing
// behaviour that could differ across Windows versions, and is REQUIRED for
// the one case that IS a clear-cut defect independent of any aliasing
// question below.
//
// R8..R15 do not exist on x86 at any width, so the name is refused outright
// rather than writing nothing while claiming success -- the same
// no-heuristics rule GetRegisters already follows on the READ side (zero,
// not fabricated) has no honest write-side analogue: there is nowhere for the
// value to go. Before this override, the base's name matching accepted these
// names and reported success while touching a register that means nothing on
// x86 -- confirmed as a real, reachable defect (RED without this fix).
function TWin32Debugger.SetRegisterByName(const Name: string;
  Value: UInt64): Boolean;
var
  Ctx: TWow64Context;
  TH:  THandle;
  N:   string;
begin
  Result := False;
  TH := ThreadHandle(GetStoppedThreadId);
  if TH = 0 then
    Exit;
  N := LowerCase(Name);
  for var ExtReg in ['r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'] do
    if N = ExtReg then
      Exit(False);
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_FULL;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;
  Result := True;
  // Either spelling: the rows this target reports are E-named, but a caller
  // carrying 64-bit names over from another session must still land here.
  if      SameRegisterName(N, 'eip') then Ctx.Eip := DWORD(Value)
  else if SameRegisterName(N, 'esp') then Ctx.Esp := DWORD(Value)
  else if SameRegisterName(N, 'ebp') then Ctx.Ebp := DWORD(Value)
  else if SameRegisterName(N, 'eax') then Ctx.Eax := DWORD(Value)
  else if SameRegisterName(N, 'ebx') then Ctx.Ebx := DWORD(Value)
  else if SameRegisterName(N, 'ecx') then Ctx.Ecx := DWORD(Value)
  else if SameRegisterName(N, 'edx') then Ctx.Edx := DWORD(Value)
  else if SameRegisterName(N, 'esi') then Ctx.Esi := DWORD(Value)
  else if SameRegisterName(N, 'edi') then Ctx.Edi := DWORD(Value)
  else if N = 'eflags' then Ctx.EFlags := DWORD(Value)
  else
    Result := False;
  if Result then
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

// Debug registers of a WOW64 target. Measured (DevTools\DataBpProbe, both
// bitnesses) to behave exactly like the native path: DR7 survives real
// scheduling, DR6 names the slot that fired, and BS is reported for a trap-flag
// step. The WOW64 registers are 32 bits wide, so the widening is the whole
// difference -- which is precisely why this belongs behind the funnel and not
// in the caller.
function TWin32Debugger.ReadDebugRegisters(TID: DWORD;
  out Regs: TDebugRegisters): Boolean;
var
  Ctx: TWow64Context;
  TH:  THandle;
begin
  Regs := Default(TDebugRegisters);
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_DEBUG_REGISTERS;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;
  Regs.Dr[0] := Ctx.Dr0;
  Regs.Dr[1] := Ctx.Dr1;
  Regs.Dr[2] := Ctx.Dr2;
  Regs.Dr[3] := Ctx.Dr3;
  Regs.Dr6   := Ctx.Dr6;
  Regs.Dr7   := Ctx.Dr7;
  Result := True;
end;

function TWin32Debugger.WriteDebugRegisters(TID: DWORD;
  const Regs: TDebugRegisters): Boolean;

  // The WOW64 debug registers ARE 32 bits wide, so narrowing is their real
  // width rather than a lossy cast -- and masking rather than casting keeps it
  // that way under the adapter's range checking. An address that would not fit
  // was already refused by ArmHardwareWatchpoint.
  function Low32(V: UInt64): DWORD;
  begin
    Result := DWORD(V and $FFFFFFFF);
  end;

var
  Ctx: TWow64Context;
  TH:  THandle;
begin
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_DEBUG_REGISTERS;
  if not Wow64GetThreadContext(TH, Ctx) then
    Exit;
  Ctx.Dr0 := Low32(Regs.Dr[0]);
  Ctx.Dr1 := Low32(Regs.Dr[1]);
  Ctx.Dr2 := Low32(Regs.Dr[2]);
  Ctx.Dr3 := Low32(Regs.Dr[3]);
  Ctx.Dr6 := Low32(Regs.Dr6);
  Ctx.Dr7 := Low32(Regs.Dr7);
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

// Walks the EBP chain instead of asking dbghelp.
//
// On x86 `mov ebp,esp` runs BEFORE the frame allocation, so inside a framed
// routine the saved caller EBP is at [EBP] and the return address at [EBP+4] --
// exact, and needing no unwind information at all. dbghelp's i386 unwind is not:
// debugging a design-time package inside bds.exe it returned $14FF318 for the
// caller of a Delphi frame -- a STACK address -- which fabricated a bogus frame
// and LOST the real caller, so the join into the VCL frames was junk. The same
// defect made step-over hang until CallerReturnAddress started reading [EBP+4]
// directly; this applies the identical reasoning to the whole walk.
//
// Every link is validated rather than trusted, because the chain does end: a
// frameless routine (system DLLs are routinely built with the frame pointer
// omitted, and a pure-`asm` body has no frame either) leaves EBP pointing at
// some ancestor's frame or at nothing at all. When a link fails the walk stops
// and, if it produced almost nothing, defers to the inherited StackWalk64 --
// which for a stack that is mostly system code may still do better.
// Decode forward from a known instruction boundary and report whether one lands
// on VA with a `call` ending there. x86 is not self-synchronising, so reading
// BACKWARDS cannot answer this: the earlier version scanned a few bytes back
// for something call-shaped and accepted the address Delphi pushes with
// `push offset @@finallyHandler`, producing a frame that named the right
// routine while pointing at its `finally` block.
//
// A method rather than a closure inside the walker because the raw stack sweep
// needs the same proof, and two copies of a rule that has already been got
// wrong once is one too many.
function TWin32Debugger.CallSiteVerdictAt(VA: UInt64): TCallSiteAnswer;
begin
  var StartVA: UInt64;
  if not NearestInstructionBoundaryBefore(VA, StartVA) then
    Exit(csaUndecidable);
  Result := CallSiteEndsAt(
    function(At: UInt64; Buf: Pointer; Size: Integer): Boolean
    begin
      Result := ReadProcessMemoryAt(At, Buf, Size);
    end,
    StartVA, VA);
end;

function TWin32Debugger.WalkRawFrames(TH: THandle; SeedPc, SeedSp, SeedFp: UInt64;
  MaxFrames: Integer): TArray<TRawStackFrame>;
const
  MAX_FRAME_SPAN = $100000;   // 1 MB: larger than any real single stack frame
  // How far above ESP to look for the pushed return address when frame 0's
  // frame is not established. A prologue has pushed at most a handful of words
  // by then; a wider window would start finding stale addresses.
  PROLOGUE_PROBE_SLOTS = 8;

  // A frame pointer must be inside the thread's stack, above the previous one
  // (the stack grows DOWN, so a caller's frame is at a HIGHER address), 4-byte
  // aligned, and not absurdly far away. Anything else means the chain has run
  // off the end of the framed region.
  function IsPlausibleNextFramePtr(Prev, Next: UInt64): Boolean;
  begin
    if (Next = 0) or (Next > $FFFFFFFF) then
      Exit(False);
    if Next <= Prev then
      Exit(False);
    if Next - Prev > MAX_FRAME_SPAN then
      Exit(False);
    Result := (Next and 3) = 0;
  end;

  // PROVES that VA is the instruction immediately after a call -- i.e. a live
  // return address rather than some other code address that happens to be on
  // the stack. Only csaYes is an acceptance; csaNo and csaUndecidable both
  // reject, so the walker declines instead of guessing.
  //
  // This cannot be answered by reading backwards. x86 is not self-
  // synchronising, and the earlier version of this test -- scan a few bytes
  // back for something call-shaped -- accepted the address Delphi pushes with
  // `push offset @@finallyHandler`, which produced a frame naming the right
  // routine while pointing at its `finally` block. Decoding forward from a
  // known instruction boundary is the only exact method; the line table
  // supplies the boundary, since every line record starts an instruction.
  function CallSiteVerdict(VA: UInt64): TCallSiteAnswer;
  begin
    Result := CallSiteVerdictAt(VA);
  end;

  function IsAfterCallSite(VA: UInt64): Boolean;
  begin
    Result := CallSiteVerdict(VA) = csaYes;
  end;

  // Only a PROVEN negative. Used where a frame is already on offer and the
  // question is whether to keep it, rather than whether to invent one: an
  // address the decoder cannot judge is left alone, an address it can prove is
  // not preceded by a call is refused.
  function IsProvenNotAfterCallSite(VA: UInt64): Boolean;
  begin
    Result := CallSiteVerdict(VA) = csaNo;
  end;

  // A FRAMELESS routine between two framed ones is invisible to the chain: it
  // never pushed EBP, so the link from its callee steps straight over it to its
  // caller. What goes missing is not the frameless routine -- its PC is still
  // reported, as the return address its callee saved -- but the FRAMED CALLER
  // above it, whose own return address nobody stored. That is the shape the
  // user reported: stopped in a comparer System.Classes calls back into, the
  // routine that started the sort was simply absent while every frame on screen
  // was real.
  //
  // Recovering it needs no guessing, because the missing routine can be
  // identified from the OTHER side and then confirmed on the stack:
  //
  //   1. the frame ABOVE the gap sits at the return address of a call, and if
  //      that call is DIRECT its target names the missing routine exactly;
  //   2. the missing routine's own return address lies in the stack region the
  //      chain skipped, and CallSiteEndsAt can PROVE which word follows a call;
  //   3. requiring that match to be UNIQUE removes the last degree of freedom.
  //
  // All three, or nothing. An earlier attempt took the first word that merely
  // looked call-adjacent and picked up the `finally` handler address out of the
  // try/finally exception record: right routine, wrong statement. A frame that
  // names the correct function while pointing at the wrong line is still a
  // wrong frame, and worse than an absent one, because nothing marks it.
  procedure RecoverFramelessCallers;
  const
    // The skipped region is one framed frame plus a frameless routine's own
    // stack use. Beyond this the walk declines rather than scan further; a
    // wider window buys nothing and costs a decode attempt per word.
    MAX_SKIPPED_SPAN = $4000;
  begin
    var ReadCode: TReadCodeProc :=
      function(At: UInt64; Buf: Pointer; Size: Integer): Boolean
      begin
        Result := ReadProcessMemoryAt(At, Buf, Size);
      end;

    var I := 1;
    while (I < Length(Result) - 1) and (Length(Result) < MaxFrames) do begin
      var Below := Result[I - 1];   // nearer the top of the stack
      var Here  := Result[I];
      var Above := Result[I + 1];

      // Step 1: name the routine the frame above called.
      var MissingEntry: UInt64 := 0;
      var BoundaryVA: UInt64;
      var CallInsn: TX86Insn;
      if NearestInstructionBoundaryBefore(Above.PC, BoundaryVA) and
         (CallSiteEndsAt(ReadCode, BoundaryVA, Above.PC, CallInsn) = csaYes) and
         CallInsn.CallIsDirect then
        MissingEntry := CallInsn.DirectTarget;

      var HereEntry: UInt64 := 0;
      FunctionEntryOf(Here.PC, HereEntry);

      // Nothing to do when the chain already produced that routine, which is
      // the normal case for framed code.
      if (MissingEntry = 0) or (MissingEntry = HereEntry) then begin
        Inc(I);
        Continue;
      end;

      // Step 2: the words the chain stepped over.
      var LoAddr := Below.FramePtr;
      var HiAddr := Here.FramePtr;
      if (LoAddr = 0) or (HiAddr < LoAddr + 8) or
         (HiAddr - LoAddr > MAX_SKIPPED_SPAN) then begin
        Inc(I);
        Continue;
      end;

      // One read for the whole region. Word-at-a-time would be a syscall per
      // stack slot, and this runs for every adjacent triple of every walk.
      var Gap: TArray<UInt32>;
      SetLength(Gap, (HiAddr - LoAddr - 4) div 4);
      if (Length(Gap) = 0) or
         not ReadProcessMemoryAt(LoAddr + 4, @Gap[0], Length(Gap) * 4) then begin
        Inc(I);
        Continue;
      end;

      var Found: UInt64 := 0;
      var Matches := 0;
      for var Slot := 0 to High(Gap) do begin
        var W := UInt64(Gap[Slot]);
        var WEntry: UInt64;
        if IsPlausibleReturnAddress(W) and FunctionEntryOf(W, WEntry) and
           (WEntry = MissingEntry) and IsAfterCallSite(W) then begin
          Inc(Matches);
          Found := W;
          if Matches > 1 then
            Break;
        end;
      end;

      // Step 3: exactly one, or the walk says nothing.
      if Matches <> 1 then begin
        Inc(I);
        Continue;
      end;

      var Raw: TRawStackFrame;
      Raw.Origin := foFramelessRecover;
      Raw.PC := Found;
      // The missing routine IS framed -- it is its callee that was not -- and
      // the frame pointer the chain attributed to the frameless entry is in
      // fact this routine's.
      Raw.FramePtr := Here.FramePtr;
      System.Insert([Raw], Result, I + 1);
      Inc(I, 2);
    end;
  end;

  // Appends dbghelp frames Src[FromIndex..], stopping at the first one that
  // fails validation.
  //
  // BOTH places that consume dbghelp go through here, and that is the point.
  // The checks used to live only in the tail splice, so the OTHER consumer --
  // the "chain produced nothing, take dbghelp's whole answer" path below --
  // copied its output verbatim, unvalidated. Measured on Hydra2 with the frame
  // origin instrumented: the impossible `frmLogModificheVegaU.pas:148` frame
  // came out of that path (`origin=dbghelp-whole`), which is why three fixes
  // aimed at the chain walk and at the tail splice all changed nothing. A rule
  // that only one of two callers obeys is not a rule.
  procedure AppendDbgHelpFrames(const Src: TArray<TRawStackFrame>;
    FromIndex: Integer; Origin: TFrameOrigin);

    // A stack that stops early looks exactly like a stack that ended, so say
    // WHICH test refused the next frame. Without this the two are
    // indistinguishable from the outside, and the last three attempts at this
    // walker were spent guessing between them.
    procedure Refuse(PC: UInt64; const Test: string);
    begin
      DapLog(Format('WalkRawFrames(x86): dbghelp frame $%x refused by %s; ' +
        'stack ends at %d frames', [PC, Test, Length(Result)]));
    end;

  begin
    for var I := FromIndex to High(Src) do begin
      if Length(Result) >= MaxFrames then
        Break;
      var Cand := Src[I];
      if (Cand.PC = 0) or (Cand.PC > $FFFFFFFF) then begin
        Refuse(Cand.PC, 'address width');
        Break;
      end;
      if not IsPlausibleReturnAddress(Cand.PC) then begin
        Refuse(Cand.PC, 'not executable code in a known module');
        Break;
      end;
      // "Executable code in a known module" is not the same claim as "a return
      // address", and dbghelp's i386 unwind supplies the difference. Measured
      // on a real BPL-loading application: below three kernel32/ntdll frames it
      // offered `frmLogModificheVegaU.pas:148`, which is impossible --
      // application code cannot call the OS thread starter. Decoding says why:
      // that address is a function ENTRY, and the byte before it is `C3`, a
      // `ret`.
      //
      // Only a PROVEN negative stops the walk. The OS frames themselves carry
      // no line table, so no boundary is available to decode from and the
      // verdict is undecidable -- those are kept, which is what preserves the
      // legitimate kernel32/ntdll tail.
      case CallSiteVerdict(Cand.PC) of
        csaNo: begin
          Refuse(Cand.PC, 'proven not preceded by a call');
          Break;
        end;
        csaUndecidable:
          // Kept, but say so: this is the only class of frame in the tail that
          // rests on an absence of evidence rather than on evidence.
          DapLog(Format('WalkRawFrames(x86): dbghelp frame $%x kept UNPROVEN ' +
            '(no instruction boundary to decode from)', [Cand.PC]));
      end;
      if (Cand.FramePtr > $FFFFFFFF) or ((Cand.FramePtr and 3) <> 0) then
        Cand.FramePtr := 0;   // unknown, which the locals decode already handles
      Cand.Origin := Origin;
      Result := Result + [Cand];
    end;
  end;

  // Appends frames by following the saved-EBP chain from StartFp, stopping at
  // the first link that does not hold up. Shared by the normal walk and the
  // prologue recovery below, which differ only in where the chain starts.
  procedure ChainFrom(StartFp: UInt64);
  begin
    var Fp := StartFp;
    while Length(Result) < MaxFrames do begin
      if (Fp = 0) or (Fp > $FFFFFFFF) then
        Break;
      var Ret:    UInt64 := 0;
      var NextFp: UInt64 := 0;
      if not ReadTargetPointer(Fp + 4, Ret) then
        Break;
      if not ReadTargetPointer(Fp, NextFp) then
        Break;
      if not IsPlausibleReturnAddress(Ret) then
        Break;
      if not IsPlausibleNextFramePtr(Fp, NextFp) then
        Break;
      var Raw: TRawStackFrame;
      Raw.Origin   := foEbpChain;
      Raw.PC       := Ret;
      Raw.FramePtr := NextFp;
      Result := Result + [Raw];
      Fp := NextFp;
    end;
  end;

begin
  SetLength(Result, 0);
  if MaxFrames <= 0 then
    Exit;

  var Frame0: TRawStackFrame;
  Frame0.Origin   := foSeed;
  Frame0.PC       := SeedPc;
  Frame0.FramePtr := SeedFp;
  Result := [Frame0];

  ChainFrom(SeedFp);

  // The chain produced nothing beyond frame 0. The usual cause is that frame 0's
  // frame is NOT ESTABLISHED YET: inside a routine's prologue -- and Delphi
  // constructors have a compiler-generated preamble that the line table already
  // attributes to the routine's first lines -- EBP still belongs to the CALLER,
  // so [EBP+4] is not this routine's return address. Observed in the field:
  // stopping on the first line of a constructor gave a ONE-frame call stack,
  // while the very next line gave a correct one, with a DIFFERENT EBP for the
  // same function.
  //
  // The pushed return address is then still near the top of the stack, at [ESP]
  // before `push ebp` and one slot higher after it. Probe a small window for a
  // word that is not merely executable but sits immediately after a CALL, which
  // is what separates a live return address from a stale one; EBP is already the
  // caller's frame pointer, so the chain resumes from it unchanged.
  if Length(Result) < 2 then begin
    var Recovered := False;
    for var Slot := 0 to PROLOGUE_PROBE_SLOTS - 1 do begin
      var Ret: UInt64 := 0;
      if not ReadTargetPointer(SeedSp + UInt64(Slot * 4), Ret) then
        Break;
      if not IsPlausibleReturnAddress(Ret) or not IsAfterCallSite(Ret) then
        Continue;
      var Raw: TRawStackFrame;
      Raw.Origin   := foPrologueProbe;
      Raw.PC       := Ret;
      Raw.FramePtr := SeedFp;
      Result := Result + [Raw];
      Recovered := True;
      Break;
    end;
    if Recovered then
      // EBP is already the caller's frame pointer, so the chain resumes from it.
      ChainFrom(SeedFp);
  end;

  // Fill in framed callers the chain stepped over because a frameless routine
  // sat between them and their callee. Runs on the chain's own output, before
  // any dbghelp tail is spliced on, so it only ever inserts between two frames
  // the chain already vouched for.
  RecoverFramelessCallers;

  // Still nothing to chain from: frame 0 is in frameless code, or its caller is
  // -- which is the normal shape for a stop in a program's main block, whose
  // caller is the RTL/OS startup. dbghelp may have something; append it to the
  // seed frame we already hold, through the same validation the tail splice
  // uses. Replacing Result wholesale with dbghelp's array (what this did) let
  // its unwind emit whatever it liked, checked by nothing.
  if Length(Result) < 2 then begin
    AppendDbgHelpFrames(
      inherited WalkRawFrames(TH, SeedPc, SeedSp, SeedFp, MaxFrames),
      1, foDbgHelpWhole);
    Exit;
  end;

  // The chain ended where FRAMING ends, which is normal: system DLLs are built
  // with the frame pointer omitted, so the walk runs out exactly at the boundary
  // between Delphi code and the OS. Truncating there would drop the whole
  // VCL/OS tail -- the first version of this walker did, and the call stack
  // collapsed to "only the frames whose source we found". Hand the remainder to
  // dbghelp instead, re-seeded from the last frame the chain vouched for: each
  // mechanism then covers the region it is actually good at.
  if Length(Result) >= MaxFrames then
    Exit;
  var Last := Result[High(Result)];
  if (Last.PC = 0) or (Last.FramePtr = 0) then
    Exit;
  // dbghelp is run from the ORIGINAL seed and spliced at a MATCHED join: find
  // our last frame's PC in its walk and take only what follows.
  //
  // Re-seeding dbghelp at the join instead (PC and frame pointer of our last
  // frame, SP guessed at the frame pointer) was tried first and is wrong: it
  // restarts in the middle of the stack and walks the SAME frames again.
  // Measured on the recursion fixture -- frames 0..7 correct, then frames 8..14
  // were a verbatim replay of 1..7. A duplicated stack is worse than a short
  // one, because every frame in it looks real.
  //
  // Frames are still validated on the way in: dbghelp's i386 unwind is the thing
  // that could not be trusted to begin with, and it fills the frame pointer from
  // the amd64 field of a context it never wrote -- measured as $117600000893E3C
  // on a 32-bit target, which is not an address at all.
  var Full := inherited WalkRawFrames(TH, SeedPc, SeedSp, SeedFp, MaxFrames);
  var JoinAt := -1;
  for var I := High(Full) downto 0 do
    if Full[I].PC = Last.PC then begin
      JoinAt := I;
      Break;
    end;
  if JoinAt < 0 then
    Exit;   // no verified join: leave the stack short rather than guess a tail
  AppendDbgHelpFrames(Full, JoinAt + 1, foDbgHelpTail);
end;

// Declines, deliberately.
//
// The inherited Win64 formula reads the first HOME SLOT, and Win32 has none, so
// inheriting it means reading an arbitrary stack slot and climbing to a frame
// that is not the parent's. That is what made a 32-bit target show only the
// nested routine's own locals, where the same source built for Win64 also
// showed the enclosing routine's.
//
// dcc32 DOES pass a static link -- measured in DevTools\Win32NestedLinkProbe:
// a hidden stack parameter pushed last, at `[EBP + 8 + declaredStackParamBytes]`.
// It is not read here because that byte count has to be derived from the
// child's declared parameter types, and getting it wrong yields a plausible
// WRONG frame rather than a failure: confident wrong values for every parent
// variable. Returning 0 sends the caller to FindParentFrameOnStack, which
// locates the parent among frames the walker has already vouched for and needs
// no ABI knowledge on either bitness.
function TWin32Debugger.ReadParentFramePointer(ChildRBP: UInt64;
  ChildFrameSize, ChildExtraPushBytes: UInt32): UInt64;
begin
  Result := 0;
end;

{ ------------------------------------------ stepping at an exception stop -- }

// The 32-bit TEB, which is what fs:[0] is relative to. Two routes, in the order
// ExcHandlerProbe measured them:
//   1. Wow64GetThreadSelectorEntry on the thread's own FS selector. Authoritative.
//   2. TEB64 + $2000 (the fixed WOW64 layout), VERIFIED rather than assumed by
//      reading TEB32+$18 (Self) back and requiring it to point at itself.
// THREAD_BASIC_INFORMATION is exactly 48 bytes on x64; passing any other length
// returns STATUS_INFO_LENGTH_MISMATCH and the fallback silently never works.
function TWin32Debugger.Teb32Base(Tid: DWORD; out Base: UInt64;
  out How: string): Boolean;
var
  Ctx: TWow64Context;
  Ldt: TLdtEntry;
begin
  Base   := 0;
  How    := '';
  Result := False;
  var TH := ThreadHandle(Tid);
  if TH = 0 then begin
    How := Format('thread %d could not be opened', [Tid]);
    Exit;
  end;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_CONTROL or WOW64_CONTEXT_SEGMENTS or
                      WOW64_CONTEXT_INTEGER;
  if not Wow64GetThreadContext(TH, Ctx) then begin
    How := Format('Wow64GetThreadContext failed (error %d)', [GetLastError]);
    Exit;
  end;
  Ldt := Default(TLdtEntry);
  if Wow64GetThreadSelectorEntry(TH, Ctx.SegFs, Ldt) then begin
    Base := UInt64(Ldt.BaseLow) or (UInt64(Ldt.BaseMid) shl 16) or
            (UInt64(Ldt.BaseHi) shl 24);
    if Base <> 0 then begin
      How := 'Wow64GetThreadSelectorEntry';
      Exit(True);
    end;
  end;

  var Info: array[0..5] of UInt64;   // THREAD_BASIC_INFORMATION, 48 bytes
  FillChar(Info, SizeOf(Info), 0);
  if NtQueryInformationThread(TH, 0, @Info[0], SizeOf(Info), nil) < 0 then begin
    How := 'neither the FS selector nor NtQueryInformationThread could locate the ' +
           '32-bit TEB';
    Exit;
  end;
  var Teb32 := Info[1] + $2000;
  var SelfPtr: UInt32 := 0;
  if ReadProcessMemoryAt(Teb32 + $18, @SelfPtr, SizeOf(SelfPtr)) and
     (UInt64(SelfPtr) = Teb32) then begin
    Base := Teb32;
    How  := 'TEB64+$2000 (Self field verified)';
    Exit(True);
  end;
  How := 'the 32-bit TEB computed as TEB64+$2000 did not verify against its own ' +
         'Self field';
end;

// x86, and the negative half of this is as load-bearing as the positive half.
//
// There is no `.pdata` on a 32-bit target, so nothing the base class decodes
// exists. The dispatch data is the fs:[0] registration chain, walked innermost
// first, and each record's Handler points at an `E9 rel32` stub INSIDE the
// protected routine. The stub's target names the case (docs/EH_FORMAT_NOTES.md):
//
//   @HandleOnException  -- an `except` with `on` clauses. A clause table follows
//                          the stub at stub+5, holding ABSOLUTE VAs (not RVAs):
//                          DWORD Count; Count x { ClassVmtVA; BlockVA }. Those
//                          BlockVAs are the user's blocks and ARE plantable.
//   @HandleFinally      -- a try/finally.  NO table follows.
//   @HandleAnyException -- a bare `except`. NO table follows.
//
// For the last two the block address is simply NOT DERIVABLE from the record --
// only the stub is, and a hit on the stub is the SEH SEARCH pass, i.e. it fires
// before that frame is known to receive the exception and before the block runs.
// Reporting "you are stopped in the finally" there would name the wrong
// execution phase, so this refuses and says which construct it was. That is a
// deliberate choice over the alternative (stop on the stub, whose address does
// resolve to the `finally` line): a refusal that names what is missing is worth
// more than a stop that looks right and is not.
function TWin32Debugger.ExceptHandlerScopeUnavailableReason: string;
begin
  Result := 'this is a 32-bit target: it has no `.pdata`, so nothing in it ' +
    'states where an `except` block begins and ends. The fs:[0] chain answers ' +
    'a different question -- where an exception WOULD be dispatched -- and for ' +
    'a bare `except` it does not name the block at all. Handler-scoped ' +
    '`$exception` and the synthesised `on` alias are therefore x64-only.';
end;

function TWin32Debugger.TryGetExceptHandlerBlockAt(PC: UInt64;
  out Blk: TExcHandlerBlock): Boolean;
begin
  // "Which except block is this PC inside?" is not answerable on a 32-bit
  // target. There is no `.pdata`, so there is no scope table stating any
  // block's extent; the fs:[0] registration chain says where an exception
  // WOULD be dispatched, which is a different question, and the block address
  // is not even derivable from it for a bare `except` or a `finally`
  // (docs/EH_FORMAT_NOTES.md, "x86 -- partial, and the negative half is
  // load-bearing").
  //
  // So a 32-bit target gets no synthesised handler alias and no handler-scoped
  // `$exception`. Everything that does not depend on this -- an `on E:` alias
  // that the compiler put on the STACK, which is every handler outside a
  // program main block -- is unaffected, because that path never comes here.
  Blk    := Default(TExcHandlerBlock);
  Result := False;
end;

function TWin32Debugger.PlanExceptionStep(Tid: DWORD;
  out Plan: TExceptionStepPlan; out RefusalReason: string): Boolean;
const
  MAX_RECORDS = 32;
  MAX_CLAUSES = 64;
var
  Blocks:   TArray<UInt64>;
  Describe: string;

  function ReadU32At(VA: UInt64; out Value: UInt32): Boolean;
  begin
    Value  := 0;
    Result := ReadProcessMemoryAt(VA, @Value, SizeOf(Value));
  end;

  // DWORD Count; Count x { DWORD ClassVmtVA; DWORD BlockVA }, absolute. Every
  // clause's block is planted for the same reason as on x64: only the matching
  // one runs, so the first hit is exact and no class matching is re-derived.
  function DecodeClauseTable(TableVA: UInt64): Boolean;
  begin
    Result := False;
    var Count: UInt32;
    if not ReadU32At(TableVA, Count) then
      Exit;
    if (Count = 0) or (Count > MAX_CLAUSES) then
      Exit;
    for var I := 0 to Integer(Count) - 1 do begin
      var Pair: array[0..1] of UInt32;
      if not ReadProcessMemoryAt(TableVA + 4 + UInt64(I) * 8, @Pair[0], SizeOf(Pair)) then
        Exit(False);
      var Where: string;
      if not DescribeUserCodeAt(Pair[1], Where) then
        Exit(False);
      var Known := False;
      for var Existing in Blocks do
        if Existing = Pair[1] then begin
          Known := True;
          Break;
        end;
      if not Known then begin
        Blocks := Blocks + [Pair[1]];
        if Describe = '' then
          Describe := 'except in ' + Where
        else
          Describe := Describe + ', except in ' + Where;
      end;
      Result := True;
    end;
  end;

begin
  Plan          := Default(TExceptionStepPlan);
  Plan.ThreadId := Tid;
  RefusalReason := '';
  Blocks        := nil;
  Describe      := '';

  var FsBase: UInt64;
  var How: string;
  if not Teb32Base(Tid, FsBase, How) then begin
    RefusalReason := Format('the fs:[0] exception-registration chain of thread %d ' +
      'could not be reached, so the handler this exception will run cannot be ' +
      'identified: %s', [Tid, How]);
    Exit(False);
  end;

  var Head: UInt32;
  if not ReadU32At(FsBase, Head) then begin
    RefusalReason := Format('fs:[0] of thread %d could not be read, so the handler ' +
      'this exception will run cannot be identified', [Tid]);
    Exit(False);
  end;

  var Rec: UInt64 := Head;
  for var Index := 0 to MAX_RECORDS - 1 do begin
    if (Rec = 0) or (Rec = $FFFFFFFF) then
      Break;
    var Pair: array[0..1] of UInt32;   // Next, Handler
    if not ReadProcessMemoryAt(Rec, @Pair[0], SizeOf(Pair)) then
      Break;
    var HandlerVA: UInt64 := Pair[1];
    var Next:      UInt64 := Pair[0];

    // Records whose handler is not the user's own code -- the RTL's outermost
    // @ExceptionHandler, ntdll's -- are skipped for the same reason x64 skips
    // sourceless frames: the step exists to land in the user's source, and a
    // refusal on every RTL record would make the feature unreachable.
    var StubWhere: string;
    if not DescribeUserCodeAt(HandlerVA, StubWhere) then begin
      Rec := Next;
      Continue;
    end;

    var Stub: array[0..4] of Byte;
    if not ReadProcessMemoryAt(HandlerVA, @Stub[0], SizeOf(Stub)) then begin
      RefusalReason := Format('a step at an exception stop runs to the handler that ' +
        'receives it. The first frame that can receive this one -- %s -- has an ' +
        'fs:[0] handler at $%x whose bytes could not be read.',
        [StubWhere, HandlerVA]);
      Exit(False);
    end;
    if Stub[0] <> $E9 then begin
      RefusalReason := Format('a step at an exception stop runs to the handler that ' +
        'receives it. The first frame that can receive this one -- %s -- has an ' +
        'fs:[0] handler at $%x that is not a Delphi `jmp rel32` dispatch stub, so ' +
        'which construct it protects, and where that block is, cannot be ' +
        'determined. Refusing rather than guessing a landing site.',
        [StubWhere, HandlerVA]);
      Exit(False);
    end;
    var Target := UInt64(Int64(HandlerVA) + 5 + PInteger(@Stub[1])^);
    var StubKind := FunctionNameAt(Target);

    if Pos('HandleOnException', StubKind) > 0 then begin
      if not DecodeClauseTable(HandlerVA + 5) then begin
        RefusalReason := Format('a step at an exception stop runs to the handler ' +
          'that receives it. The first frame that can receive this one -- %s -- ' +
          'protects an `except` with `on` clauses, but the clause table at $%x did ' +
          'not decode into block addresses that map to source lines.',
          [StubWhere, HandlerVA + 5]);
        Exit(False);
      end;
      Plan.HandlerVAs  := Blocks;
      Plan.Description := Describe;
      Exit(True);
    end;

    var Construct := '';
    if Pos('HandleFinally', StubKind) > 0 then
      Construct := 'a try/FINALLY'
    else if Pos('HandleAnyException', StubKind) > 0 then
      Construct := 'a bare `except` (no `on` clause)';

    if Construct <> '' then begin
      RefusalReason := Format('a step at an exception stop runs to the handler that ' +
        'receives it, and on a 32-bit target that address cannot always be proven. ' +
        'The first frame that receives this exception -- %s -- protects %s. Its ' +
        'fs:[0] record points at a %s dispatch stub, which carries NO table, so the ' +
        'address of the block itself is not derivable -- only the stub, and a hit ' +
        'there is the SEH SEARCH pass, not the block running. Refusing rather than ' +
        'reporting a stop in the wrong execution phase. Use continue, or set a ' +
        'breakpoint on the handler line.',
        [StubWhere, Construct, StubKind]);
      Exit(False);
    end;

    var Named := StubKind;
    if Named = '' then
      Named := Format('an unnamed routine at $%x', [Target]);
    RefusalReason := Format('a step at an exception stop runs to the handler that ' +
      'receives it. The first frame that can receive this one -- %s -- has an ' +
      'fs:[0] dispatch stub jumping to %s, which this debugger does not recognise ' +
      'as one of Delphi''s (@HandleOnException / @HandleFinally / ' +
      '@HandleAnyException). Refusing rather than guessing a landing site.',
      [StubWhere, Named]);
    Exit(False);
  end;

  RefusalReason := Format('no fs:[0] registration record of thread %d belongs to code ' +
    'this debugger has symbols for, so there is no except or finally block to step ' +
    'to. Continue instead: the exception is unhandled as far as the user''s code is ' +
    'concerned.', [Tid]);
  Result := False;
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

// On x86 the return address needs no unwind information: `mov ebp,esp` runs
// BEFORE the frame allocation (the opposite of x64), so inside a framed routine
// the saved caller EBP is at [EBP] and the return address is always at [EBP+4].
// Measured in Phase 0; see the prologue notes above.
//
// This matters beyond tidiness. The inherited implementation unwinds one frame
// with StackWalk64, which needs dbghelp to know the module -- and in a real
// 32-bit host loading runtime packages it frequently does not. Observed on the
// Delphi IDE loading a design-time package: the walker returned a STACK address
// as the caller, so step-over planted its run-to-return breakpoint somewhere
// that never executes and the step hung.
//
// The read is validated rather than trusted: at the very first instruction of a
// routine EBP still belongs to the caller, and a frameless routine has no such
// slot at all. When the slot does not hold something that looks like a return
// address, fall back to the inherited walk rather than guess.
function TWin32Debugger.CallerReturnAddress(TID: DWORD): UInt64;
var
  Regs: TRegisterSnapshot;
begin
  Result := 0;
  if ReadThreadRegisters(TID, Regs) and (Regs.FramePtr <> 0) then begin
    var Ret: UInt64 := 0;
    if ReadProcessMemoryAt(Regs.FramePtr + 4, @Ret, 4) and
       IsPlausibleReturnAddress(Ret) then
      Exit(Ret);
  end;
  Result := inherited CallerReturnAddress(TID);
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
