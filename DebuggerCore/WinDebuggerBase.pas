unit WinDebuggerBase;

// TWinDebugger: the architecture-neutral half of the engine -- the debug event
// loop, breakpoints, stepping, module handling and the synthetic-call pump --
// plus the x64 implementation of the architecture seam as its default.
// TWin32Debugger (WinDebuggerX86.pas) overrides that seam and inherits
// everything else unchanged.
//
// The unit was called Win64Debugger until 32-bit targets landed, at which point
// the name described neither the class nor what it debugs.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Winapi.Windows,
  DapProtocol, DebugInfoTypes, DebugInfoSet, DebugTarget, ExceptionRules,
  TargetLayout, DelphiValueReaders,
  Disassembler,        // IDisassembler: exact instruction lengths for stepping
  ZydisDisassembler,   // the only backend today; reached ONLY through the seam
  X86Decode;   // TCallSiteAnswer: the call-site verdict seam (x86 supplies it)

type
  // One unwound frame before symbolication: where the code is and where its
  // frame pointer is. Separating the WALK from the naming is what lets a target
  // architecture replace the unwind strategy without touching the (identical)
  // source/function/line resolution that follows it.
  TRawStackFrame = record
    PC:       UInt64;
    FramePtr: UInt64;
    Origin:   TFrameOrigin;   // which mechanism produced it (diagnostic)
  end;

  // One entry of a module's export directory, kept sorted by RVA so an address
  // can be attributed to the exported routine that starts at or before it.
  // This is the LAST resort of symbolication: it names code in modules that
  // carry no debug info of any kind (ntdll, kernel32, a third-party DLL), which
  // is why the top of every thread's stack used to read as an anonymous address.
  TExportedSymbol = record
    Rva:  Cardinal;
    Name: string;
  end;
  TExportSymbolIndex = TArray<TExportedSymbol>;

  // Why a single-step exception ($80000004, or $4000001E under WOW64) arrived.
  // The exception code is the same for a completed single step and a hardware
  // watchpoint hit, so only DR6 can separate them:
  //
  //   B0..B3 (bits 0..3) name the slot(s) that fired;
  //   BS     (bit 14)    says the trap flag caused this trap.
  //
  // Both can be set at once -- one instruction can complete our step AND write
  // a watched cell. Measured identical on native x64 and on WOW64
  // (DevTools\DataBpProbe, `-tfstep`), which is why the pump needs no state of
  // its own to tell the two apart.
  TDebugTrapCause = record
    FiredSlots:   Byte;     // bitmask of B0..B3
    TrapFlagStep: Boolean;  // BS
  end;

  // Allocator state for ONE hardware slot, thread-independent by design: DR0..DR3
  // are per-thread registers, but "which slot holds which address, for whom" is a
  // single process-wide fact. Replication onto the actual threads is a SEPARATE
  // step (arm-on-every-live-thread, arm-on-create, arm-on-attach, clear-on-detach)
  // driven off this record, never inferred from it.
  TWatchSlotState = record
    InUse:       Boolean;
    Address:     UInt64;
    SizeBytes:   Integer;
    WriteOnly:   Boolean;
    Description: string;   // who asked for it, e.g. an expression or "GCounter";
                           // '' when armed through the raw per-thread primitive
                           // directly (tests, probes) rather than the allocator.
    // "old -> new" is the whole point of a data breakpoint (docs/DATA_BREAKPOINTS_PLAN.md
    // "Reporting a hit"). A write watchpoint traps AFTER the store completes, so
    // NewValue is readable at the stop; OldValue only exists because it was
    // captured HERE at arm time and refreshed at every hit -- read at Address
    // the moment the slot is claimed, zero-extended into the low SizeBytes.
    OldValue:    UInt64;
  end;

  TWinDebugger = class(TInterfacedObject, IDebugTarget)
  private
    FProcess:      THandle;
    FProcessId:    DWORD;
    FThreads:      TDictionary<DWORD, THandle>; // id -> handle
    // Names threads announced about THEMSELVES via the MS_VC_EXCEPTION
    // ($406D1388) debugger protocol -- what TThread.NameThreadForDebugging
    // raises. Filled when the announcement arrives, which is usually long after
    // the thread was created, so GetThreadName must consult it per request and
    // never cache a name at CREATE_THREAD time.
    FThreadNames:  TDictionary<DWORD, string>;  // id -> announced name
    FStoppedTid:   DWORD;
    // Why the last synthetic call failed, in the debuggee's own words: the
    // exception class and message when it raised, or the fault. Set at the
    // abort site, where the exception record is in hand; read by the evaluator
    // so a failed watch says what went wrong instead of only that it did.
    FLastSyntheticCallError: string;
    FImageBase:    UInt64;
    FImageSize:    UInt64;   // SizeOfImage of the main image, read at CreateProcess
    FPreferredBase: UInt64;
    FDebugInfo:    TDebugInfoSet;
    FBreakpoints:  TList<TBreakpointRec>;
    // smInstr is instruction granularity (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment
    // 1) and is deliberately a MODE of its own rather than a flag on smInto /
    // smOver: those two terminate on a new SOURCE LINE, which is not a condition
    // that exists in the code instruction stepping is for.
    // smToHandler is the step taken at a FIRST-CHANCE EXCEPTION stop: no source
    // line is going to follow the faulting instruction, so the only meaningful
    // destination is the `except` / `finally` block that receives the exception.
    // It terminates on a one-shot breakpoint at a PROVEN handler block, never on
    // a line change and never on the trap flag (which does not survive exception
    // dispatch -- docs/EH_FORMAT_NOTES.md).
    FStepMode:     (smNone, smInto, smOver, smOut, smInstr, smToHandler);
    FStepOverVA:   UInt64;  // temp one-shot BP address for step-over/out
    // Range-based step-over: single-step inside the current function's RVA
    // range; when a CALL leaves the function (or recurses into it) run
    // full-speed to the return address, then resume single-stepping. Membership
    // is decided by RvaToFunctionStart (stable across the prologue), and a CALL
    // vs a RET is told apart by the RSP delta across the single instruction that
    // crossed the function boundary -- never by absolute RSP magnitude, so
    // stepping from a function's `begin` (entry RSP, pre-prologue) works.
    FStepBpVAs:    TArray<UInt64>;  // transient one-shot step BPs (resume + raise-catch)
    FStepFuncStart: UInt64;         // RVA of the function being stepped over
    FStepResumeVA:  UInt64;         // VA of the pending run-to-return resume BP
    // RSP the stepped frame will have when the resume BP legitimately fires (the
    // post-CALL RSP plus the 8 bytes the matching RET pops). A RECURSIVE callee
    // returns to the SAME address, so without this the one-shot BP fired for a
    // DEEPER incarnation and the step "landed" on the right line but in the wrong
    // frame -- every local belonging to another recursion level. A hit at a
    // smaller RSP is deeper: re-arm and keep running.
    FStepResumeSP:  UInt64;
    FStepPrevSP:    UInt64;         // RSP at the previous single-step (for call/ret delta)
    FStepRaiseArmed: Boolean;       // in-function line BPs planted to catch an unwinding raise
    // True while a single step exists ONLY to move the thread off a transient
    // step breakpoint that fired for someone else (see
    // RearmStepBpAfterForeignHit). That trap advances one instruction but
    // decides nothing: whichever step is in flight must resume exactly as it
    // was, or the trap it did not ask for is mistaken for progress.
    FSteppingOffStepBp: Boolean;
    // Instruction-granularity stepping (smInstr). The resume address lives in
    // FStepOverVA and the recursion guard in FStepResumeSP, reusing the
    // step-over machinery rather than duplicating it; only what is genuinely
    // new is kept here.
    FInstrStepKind:     TInstructionStepKind;
    FInstrStepTid:      DWORD;      // the thread this instruction step belongs to
    FInstrStepTrapFlag: Boolean;    // True = one trap-flag step, False = run to FStepOverVA
    // Step-to-handler state (smToHandler). The planted one-shots live in
    // FStepBpVAs like every other transient step breakpoint, but the LANDING is
    // decided against this list instead: PlantStepBp leaves an address that
    // already carries a user breakpoint alone, and such an address would then
    // never appear in FStepBpVAs even though it is exactly where the step ends.
    FExcStepVAs:      TArray<UInt64>;
    FExcStepTid:      DWORD;   // thread whose exception this step is following
    FExcStepFromVA:   UInt64;  // ExceptionAddress of the stop the step started at
    FExcStepFromCode: DWORD;   // its exception code
    FExcStepDesc:     string;  // "finally in Level2Finally (Unit.pas:58)"
    // Set when a step abandoned itself rather than completing -- today only by
    // the re-fire guard. Surfaced with the stop so the same exception arriving
    // again reads as "the step made no progress" instead of as a fresh event,
    // which is what the field failure looked like: the same exception logged
    // forever with nothing saying the step was the cause.
    FLastStepNote:    string;
    // The decoder instruction stepping uses. Built lazily on first use (needs
    // the target's pointer width, which is only known once the process exists);
    // replaced wholesale by SetInstructionDisassembler. Symbolication is
    // deliberately NOT wired in -- stepping needs lengths and mnemonics, and a
    // symbol lookup per step would be paid for nothing.
    FInstrDisasm:       IDisassembler;
    // Per-thread stepping. While a step is in flight, every thread EXCEPT the
    // stepped one is explicitly SuspendThread'd so only it runs -- the Win32
    // debug API resumes ALL threads on ContinueDebugEvent, but an explicit
    // suspend survives the continue, so the others stay frozen until the next
    // reported stop thaws them. This is what makes stepping truly per-thread:
    // only the stepped thread's single-step / one-shot INT3 can fire (also makes
    // step-over/step-out more robust, since no other thread can race a step BP).
    FStepTid:          DWORD;        // thread targeted by the in-flight step (0 = none)
    FStepFreezeActive: Boolean;      // True while other threads are frozen for a step
    FStepFrozenTids:   TList<DWORD>; // threads we explicitly suspended for the current step
    FCachedFrames:    TArray<TStackFrame>; // call stack cached per stop (keyed by TID+RIP+RSP)
    FCachedFramesTID: DWORD;               // thread the cached frames belong to (0 = none)
    FCachedFramesRIP: UInt64;              // RIP the cached frames belong to (0 = none)
    FCachedFramesRSP: UInt64;              // RSP too: same RIP at a different recursion depth
    FCachedFramesRev: UInt64;              // DebugInfoSet revision for the cached frames
    FPendingReactivateVA:   UInt64; // after INT3 hit, re-arm after single-step
    FReactivateTid:         DWORD;  // thread that owns the pending re-arm (the one
                                    // that hit the persistent BP). The re-arm single-
                                    // step belongs to THIS thread; another thread's
                                    // step/hit must not consume it (per-thread stepping)
    FRearmAfterStopVA:     UInt64; // re-plant INT3 at next ReportStopped (step landed on BP)
    FPendingContinueStatus: DWORD; // DBG_CONTINUE or DBG_EXCEPTION_NOT_HANDLED for next resume
    FIsStopped:            Boolean; // True between ReportStopped and resume command
    FPauseRequested:       Boolean; // True after ckPause, until injected BP fires
    FMainTid:              DWORD;   // the target's primary thread (from CREATE_PROCESS)
    // Thread whose pending debug event must be released to resume. Equals
    // FStoppedTid for a normal stop, but for a pause it is the transient thread
    // DebugBreakProcess injected -- distinct from FStoppedTid, which we retarget to
    // a real user thread so the pause reports a usable stack instead of the empty
    // injected-thread frame. 0 = use FStoppedTid.
    FStopEventTid:         DWORD;
    FFirstBreak:      Boolean; // OS startup breakpoint not yet seen
    FStopAtEntry:     Boolean;
    FKillOnDetach:    Boolean; // attach mode: true -> TerminateProcess on disconnect; false -> DebugActiveProcessStop (leave running)
    FExceptionFilters: TExceptionFilters;
    FDelphiClassFilter: string;  // comma-separated class names; empty = match all Delphi raises
    FExceptionRules: TArray<TExceptionRule>; // per-exception rule table; empty = filters alone
    FRunning:         Boolean;
    FHasExited:       Boolean;
    FSymInitialized:  Boolean;
    // Step-into state: walk instructions until a new source line is reached
    FStepFromLoc:     TSourceLocation;
    FStepHasFromLoc:  Boolean;
    FStepSafetyCount: Integer;
    // Minimum RSP a single-step (smInto) stop must reach before it counts as a
    // stop. 0 = no constraint. Set only by the step-OUT fallback, which cannot
    // find its caller and single-steps instead: a step-out that has not yet left
    // the frame must not report success just because the instruction pointer
    // moved onto another source line a few bytes further into the SAME function.
    FStepMinSP:       UInt64;
    // VA of a single 0xCC byte used as the return trap when we synthesise
    // remote calls into the debuggee (e.g. to invoke @UStrAsg). Allocated
    // lazily and reused across calls.
    FRemoteCallTrap:  UInt64;
    // Synthetic-call cancellation (atomics, set/read across threads):
    //   FInRemoteCall   = 1 while a RunMethodCall pump is in flight.
    //   FAbortRemoteCall = 1 requests the in-flight call to abort. Set by the
    // stdin thread when a control command (step/continue/pause/disconnect)
    // arrives while a call runs, and by the pump's own watchdog timeout. The
    // pump forces the call thread to our INT3 trap so the call completes (as a
    // failure) instead of hanging the whole adapter on WaitForDebugEvent.
    FInRemoteCall:    Integer;
    FAbortRemoteCall: Integer;
    // Auto-call window (see IDebugTarget.BeginAutoCallWindow). Depth counts
    // nested opens so the OUTERMOST deadline survives; plain fields, not
    // atomics, because only the thread that pumps the calls ever touches them.
    FAutoCallDepth:    Integer;
    FAutoCallDeadline: UInt64;
    // VA of a reusable scratch page in the debuggee used to hold the
    // hidden var-out result slot for managed / Variant / record getters.
    // Allocated lazily; zeroed on each use. One page (4 KB) is enough for
    // every supported return type.
    FRemoteScratch:   UInt64;
    // Hardware watchpoints. FWatchSlots is the allocator's own state: which
    // slot holds which address, for whom -- thread-independent, because DR0..
    // DR3 must be replicated onto every thread to mean anything (see
    // SetDataWatchpoint / HandleCreateThread / Terminate).
    // FWatchArmedSlots is the cached bitmask (InUse per slot) so the hot path in
    // TakeDebugTrapCause stays a single comparison: while it is zero the event
    // pump never opens a debug-register context at all, so ordinary stepping
    // costs exactly what it did before this feature existed, and a slot never
    // armed cannot have set the B bit that names it.
    FWatchArmedSlots: Byte;
    FWatchSlots:      array[0..3] of TWatchSlotState;
    FWatchHitCount:   Integer;
    FLastWatchHit:    TWatchpointHit;
    FCommandQueue: TQueue<TCommand>;
    // Cheap synchronous request/reply for ckSetDataBreakpoints: the caller posts
    // one command and drains it right back (DrainDataBreakpointCommand), so
    // there is never more than one outcome to hold at a time.
    FLastDataBpSlot:   Integer;
    FLastDataBpOk:     Boolean;
    FLastDataBpReason: string;
    FQueueLock:    TRTLCriticalSection;
    FOnStopped:          TOnStopped;
    FOnExited:           TOnExited;
    FOnOutput:           TOnOutput;
    FOnDllLoaded:        TOnDllLoaded;
    FOnDllUnloaded:      TOnDllUnloaded;
    FOnBpHit:            TOnBpHit;
    FLastExceptionDesc:    string;  // "Class: Message" (or class / AV summary) for the stop UI
    FLastExceptionClass:   string;  // raised class name alone (DAP exceptionInfo.exceptionId)
    FLastExceptionMessage: string;  // Exception.Message text alone
    FExceptionObjAddr:     UInt64;  // VA of the live Delphi exception object (0 = none / AV)
    // Was the last reported exception a Delphi `raise` ($0EEDFADE)? The class
    // name cannot answer it -- a hardware AV is named EAccessViolation too --
    // and consumers need the difference: everything above a Delphi raise is RTL
    // plumbing by construction, while a fault's top frame IS the answer.
    FLastExcIsDelphiRaise: Boolean;
    // Raw identity of the exception the current stop is on. Only the re-fire
    // guard needs these: a step to a handler that produces the SAME code at the
    // SAME address has made no progress, and saying so once beats logging the
    // same exception forever, which is exactly how the defect was reported.
    FLastExceptionAddr: UInt64;
    FLastExceptionCode: DWORD;
    FDllBases:     TDictionary<string, UInt64>; // lowercase filename -> actual load base
    FDllSizes:     TDictionary<string, UInt64>; // lowercase filename -> SizeOfImage
    // lcase identifier -> DebugInfo revision at which it was confirmed absent
    // by the global resolver. Lets a repeat watch/hover of a genuinely-missing
    // name skip the multi-second indexing-retry below. Invalidated implicitly:
    // a module load bumps Revision, so a stale entry no longer matches.
    FGlobalMissCache: TDictionary<string, UInt64>;
    // module base -> its exports, sorted by RVA. Built on first miss for that
    // module and kept: an export directory does not change while the module is
    // mapped. An empty entry is a valid answer (the module exports nothing) and
    // stops the walk from being repeated for every frame.
    FExportIndexes: TDictionary<UInt64, TExportSymbolIndex>;
    // Explicitly-selected call-stack frame (DAP frameId <> 0). When set,
    // GetLocalValues / the expression evaluator read THIS frame's locals
    // instead of the stopped top frame. 0 = top frame.
    FActiveFrameRBP:     UInt64;
    FActiveFrameEntryVA: UInt64;
    FActiveFrameName:    string;
    FActiveFramePC:      UInt64;  // selected frame's instruction pointer (VA),
                                  // for lexical-block scope filtering of locals

    function  ReadByte(VA: UInt64; out B: Byte): Boolean;
    function  WriteByte(VA: UInt64; B: Byte): Boolean;
  protected
    // Visible to a per-architecture descendant: the virtual seam below plus the
    // handful of helpers it needs. Everything else stays private.
    function  ThreadHandle(TID: DWORD): THandle;
    // Address of the one-byte INT3 page a synthetic call returns to. Allocated
    // lazily by RunMethodCall before it hands over to PrepareSyntheticCall, so
    // an override can rely on it being set.
    function  RemoteCallTrap: UInt64;
    // Greatest address strictly below VA that is known to start an instruction,
    // taken from the line table, and belonging to the same routine as VA. The
    // x86 walker decodes forward from here to prove whether an address follows
    // a call; x86 cannot be decoded backwards. Exposed as a narrow helper
    // rather than handing descendants the whole debug-info set.
    function  NearestInstructionBoundaryBefore(VA: UInt64;
                out BoundaryVA: UInt64): Boolean;
    // IDebugTarget.NearestExportedEntryBefore -- the PE-export fallback for a
    // module NearestInstructionBoundaryBefore cannot answer for at all (no
    // debug-info provider owns it). Declared here (not IDebugTarget-only)
    // so TWin32Debugger inherits the one implementation unchanged, same as
    // NearestInstructionBoundaryBefore itself.
    function  NearestExportedEntryBefore(VA: UInt64;
                out BoundaryVA: UInt64): Boolean;
    // Names an address from the export directory of whichever module contains
    // it, for modules no debug-info provider owns. Returns the exported routine
    // that starts at or before VA, plus the distance from its entry.
    function  ExportedSymbolAt(VA: UInt64; out Name: string;
                out Offset: UInt64; out EntryVA: UInt64): Boolean;
    function  ExportIndexOf(ModBase: UInt64): TExportSymbolIndex;
    procedure NameFromModuleExports(VA: UInt64; AtReturnAddress: Boolean;
                var Frame: TStackFrame);
    function  ModuleNameForBase(ModBase: UInt64): string;
    // True when VA lies in a module that has been mapped into the target.
    function  ModuleRangeFor(VA: UInt64; out Base, Size: UInt64): Boolean;
    // TEB lookup and the two offsets into it. Virtual as a group: a WOW64 target
    // needs a different TEB *and* different offsets, and splitting them would
    // let one be overridden without the other.
    function  TryGetThreadTeb(TID: DWORD; out TebVA: UInt64;
                out Reason: string): Boolean; virtual;
    function  LastErrorOffset: Cardinal; virtual;
    function  LastStatusOffset: Cardinal; virtual;
    // True for a module that belongs to the OTHER bitness: the 64-bit WOW64
    // layer seen from a 32-bit session. See the implementation for why the test
    // must not be made symmetric.
    function  IsForeignBitnessModule(Base: UInt64): Boolean;
    // Entry address of the routine containing VA, as a VA. Lets a descendant
    // ask "are these two addresses in the same routine" without reaching into
    // the debug-info set or doing its own RVA arithmetic.
    function  FunctionEntryOf(VA: UInt64; out EntryVA: UInt64): Boolean;
  private
    function  FindBreakpointByVA(VA: UInt64): Integer;
    function  ReadFrameSize(EntryVA: UInt64): UInt32;
  protected
    // Recognised=False means "the prologue was not understood", which is NOT
    // the same as a zero-byte frame and must never be treated as one: every
    // address derived from the frame size would be silently wrong. Callers are
    // required to check it and refuse rather than guess.
    // ARCH: x86 has no .pdata at all, so its decoder is byte patterns only.
    function  ReadPrologInfo(EntryVA: UInt64; out ExtraPushBytes: UInt32;
                out Recognised: Boolean): UInt32; virtual;
    function  FunctionBodyStartVA(VA: UInt64): UInt64;
    // The Win64 answer: the static link arrives in RCX and is spilled to the
    // first home slot. VIRTUAL because that formula is ABI-specific and Win32
    // has no home slots at all -- the 32-bit override declines rather than
    // reading an arbitrary stack slot, and the caller then searches the stack.
    function  ReadParentFramePointer(ChildRBP: UInt64;
                ChildFrameSize, ChildExtraPushBytes: UInt32): UInt64; virtual;
    function  FindParentFrameOnStack(ParentEntryVA, ChildRBP: UInt64): UInt64;
    function  CollectLocalsForFrame(FrameRBP: UInt64; FuncEntryVA: UInt64;
                const FuncName, NamePrefix: string;
                FramePcRva: UInt64): TArray<TLocalValue>;
    procedure PlantInt3(var BP: TBreakpointRec);
    procedure RemoveInt3(var BP: TBreakpointRec);
    // Thread-context funnel: the single place that opens a thread context to
    // read or mutate a ROLE. A WOW64 target swaps these three implementations
    // rather than eleven scattered TContext sites. Callers that need the raw
    // CONTEXT (StackWalk64 seeding, RunMethodCall's marshalling) are genuinely
    // architecture-specific and stay outside.
    function  ReadThreadRegisters(TID: DWORD; out Regs: TRegisterSnapshot): Boolean; virtual;
    function  SetThreadPc(TID: DWORD; VA: UInt64): Boolean; virtual;
    function  SetThreadTrapFlag(TID: DWORD; Enable: Boolean): Boolean; virtual;
    // The debug registers are a FOURTH role behind the same funnel, for the same
    // reason as the other three: a caller that wants "arm slot 2 for a 4-byte
    // write" must not have to know that a 32-bit target needs
    // Wow64Get/SetThreadContext and WOW64_CONTEXT_DEBUG_REGISTERS.
    function  ReadDebugRegisters(TID: DWORD; out Regs: TDebugRegisters): Boolean; virtual;
    function  WriteDebugRegisters(TID: DWORD; const Regs: TDebugRegisters): Boolean; virtual;
    // Machine type handed to StackWalk64. dbghelp already unwinds i386 as well
    // as amd64, so a 32-bit target changes this value rather than needing a
    // hand-rolled walker.
    function  StackWalkMachineType: DWORD; virtual;
    // Fills Buf with the raw context StackWalk64 expects for this architecture
    // and reports the seed registers. The walk itself never reads Buf's fields
    // again -- StackWalk64 mutates it opaquely as it unwinds -- so this is the
    // only place that needs to know the context's shape.
    //
    // Buf is typed TContext because it is the larger and correctly aligned of
    // the two; a WOW64 context is smaller and the x86 override writes it at the
    // start of the same storage.
    function  FillStackWalkContext(TH: THandle; var Buf: TContext;
                out SeedPc, SeedSp, SeedFp: UInt64): Boolean; virtual;
    // Produces the raw (PC, frame pointer) pairs of a call stack, before any
    // symbolication. The base drives StackWalk64; x86 overrides it because
    // dbghelp's i386 unwind is demonstrably wrong in modules it knows nothing
    // about, while the x86 frame model makes the answer a fixed stack slot.
    function  WalkRawFrames(TH: THandle; SeedPc, SeedSp, SeedFp: UInt64;
                MaxFrames: Integer): TArray<TRawStackFrame>; virtual;
    // Bases that turn a debug-info frame-relative offset into a real one.
    // ARCH: x64 Delphi encodes a local relative to the TOP of the locals area,
    // so the (rounded) frame size has to be added back, and a parameter sits
    // above the saved frame pointer past the extra pushes. On x86 `mov ebp,esp`
    // runs BEFORE the allocation, so debug-info offsets are already relative to
    // the frame pointer and both bases are zero.
    function  LocalsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer; virtual;
    function  ParamsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer; virtual;
    // Is the instruction that ENDS at VA a call? The only exact way to tell a
    // return address from any other code address lying on the stack.
    //
    // The base declines for everything: amd64 needs a length decoder this
    // engine does not have on that architecture, and answering `csaNo` without
    // decoding would be a guess dressed as a proof. x86 overrides it.
    function  CallSiteVerdictAt(VA: UInt64): TCallSiteAnswer; virtual;
    // Decides where a step taken at a first-chance exception stop must land:
    // the block of the FIRST frame up the stack that can receive this
    // exception. Runs on the REQUESTING thread and mutates nothing the debuggee
    // can observe, so a refusal is synchronous (see TExceptionStepPlan).
    //
    // The base implementation is the x64 one and reads `.pdata` /
    // `UNWIND_INFO` / Delphi's scope table. x86 has no `.pdata` at all and
    // overrides it with the fs:[0] registration walk.
    //
    // Contract for both: return False with a reason that NAMES what is missing
    // whenever the block address cannot be proven. Never fall back to a
    // plausible-looking stop point.
    function  PlanExceptionStep(Tid: DWORD; out Plan: TExceptionStepPlan;
                out RefusalReason: string): Boolean; virtual;
    // The `except` block PC is standing IN, if any -- the question "am I inside
    // a handler right now", as opposed to PlanExceptionStep's "where will this
    // exception land". Reads the same x64 `.pdata` / `UNWIND_INFO` / Delphi
    // scope-table chain (docs/EH_FORMAT_NOTES.md) and answers False for everything
    // it cannot prove, a non-Delphi language handler included.
    //
    // x86 overrides it to a flat False: a 32-bit binary has no `.pdata`, and the
    // fs:[0] chain describes where an exception WOULD go, not which block the
    // thread is currently executing.
    function  TryGetExceptHandlerBlockAt(PC: UInt64;
                out Blk: TExcHandlerBlock): Boolean; virtual;
    // Why TryGetExceptHandlerBlockAt can never answer on this target, or '' when
    // it can in principle and simply did not this time. x86 overrides it.
    function  ExceptHandlerScopeUnavailableReason: string; virtual;
    // The exception alias of the `on <X>: <Class> do` clause PC is standing in,
    // when the compiler put X somewhere the ordinary locals path cannot see.
    //
    // In a procedure the alias is a plain stack local and every symbol reader
    // already lists it. In a PROGRAM MAIN BLOCK dcc allocates it as a
    // module-level static instead (measured: `_ZN7Debugme1EE`, an LDATA32 at a
    // fixed RVA, on BOTH bitnesses), so it is a global to every reader and never
    // a local of the block -- which is why `evaluate E` answered there while
    // Locals did not list it. This recovers it, for the extent of the clause
    // that owns it and no further.
    function  TryGetHandlerAliasLocal(PC: UInt64;
                out LV: TLocalValue): Boolean;
    // Shared by both architectures' planners: True when VA is an address in a
    // module with symbols that maps to a real source line, which is what
    // separates a user's own except/finally block from an RTL funclet or a
    // piece of table data. Where fills in "Routine (Unit.pas:58)".
    function  DescribeUserCodeAt(VA: UInt64; out Where: string): Boolean;
    // Name of the routine containing VA, or '' when no provider owns it. The
    // x86 planner classifies a Delphi SEH dispatch stub by the name its
    // `jmp rel32` lands on (@HandleOnException / @HandleFinally /
    // @HandleAnyException), which is the only thing that distinguishes them.
    function  FunctionNameAt(VA: UInt64): string;
  private
    // Reads DR6 for TID, clears it, and reports WHY this #DB arrived. Cheap
    // no-op (FiredSlots = 0, TrapFlagStep = True) while no slot is armed, so
    // the pump's fall-through behaviour is unchanged when the feature is unused.
    function  TakeDebugTrapCause(TID: DWORD): TDebugTrapCause;
    procedure RecordWatchpointHit(TID: DWORD; FiredSlots: Byte; Pc: UInt64);
    // Pure register-file primitives: touch ONE thread's DR0..DR7, no allocator
    // bookkeeping. Shared by the raw per-thread ArmHardwareWatchpoint (which
    // updates FWatchSlots itself, for direct single-thread callers) and the
    // process-wide allocator below (which updates FWatchSlots once, after every
    // live thread has been touched, so a partial failure never has to guess
    // which threads to unwind).
    function  ArmWatchRegistersOnThread(TID: DWORD; Slot: Integer; Address: UInt64;
                SizeBytes: Integer; WriteOnly: Boolean; out Reason: string): Boolean;
    function  DisarmWatchRegistersOnThread(TID: DWORD; Slot: Integer): Boolean;
    // Clears Slot on every thread this debugger currently knows about. Used by
    // ClearDataWatchpoint and by the clean-detach path in Terminate.
    procedure ClearWatchSlotOnAllThreads(Slot: Integer);
    procedure SetTrapFlag(TID: DWORD; Enable: Boolean);
    procedure SetRIP(TID: DWORD; NewRIP: UInt64);
    function  CurrentRIP(TID: DWORD): UInt64;
    function  CurrentRSP(TID: DWORD): UInt64;
    // Executes one ckSetDataBreakpoints spec: SetDataWatchpoint / ClearDataWatchpoint,
    // result stashed in FLastDataBp*.
    procedure DoDataBreakpointCommand(const Spec: TDataBpArmSpec);
    // Mirrors DrainBreakpointCommands: dequeues everything, executes the
    // (single) queued ckSetDataBreakpoints command immediately, re-enqueues
    // every other kind untouched. Called right after PostCommand so
    // ApplyDataBreakpointCommand can hand the caller a REAL outcome.
    function  DrainDataBreakpointCommand(out Slot: Integer;
                out RefusalReason: string): Boolean;
  protected
    // Where the current frame will return to. Drives step-over's run-to-return
    // and step-out, so a wrong answer plants a one-shot breakpoint at an address
    // that is never executed and the step simply never completes.
    //
    // The base implementation unwinds one frame with StackWalk64, which needs
    // dbghelp to know the module. A 32-bit target overrides it, because there
    // the answer is a fixed stack slot and needs no unwind information at all.
    function  CallerReturnAddress(TID: DWORD): UInt64; virtual;
    // True when VA lies inside a module dbghelp knows about and is executable --
    // i.e. it is plausibly a return address rather than a leaf-convention guess
    // read out of an uninitialised stack slot.
    function  IsPlausibleReturnAddress(VA: UInt64): Boolean;
    // One TARGET pointer at Addr. The width follows the DEBUGGEE, not the
    // adapter: reading 8 bytes on a 32-bit target splices the neighbouring
    // value into the high half and produces an address that points nowhere.
    // Protected because the x86 stack walk chains through target pointers.
    function  ReadTargetPointer(Addr: UInt64; out V: UInt64): Boolean;
  private
    procedure EnsureSymInitialized;
    procedure RegisterModuleWithDbgHelp(const Path: string; Base, ImageSize: UInt64);
    function  ReadImageSizeOf(Base: UInt64): UInt64;
    function  AddressInLoadedModule(VA: UInt64): Boolean;
    procedure PlantStepBp(VA: UInt64);
    // A transient step breakpoint fired for someone ELSE -- a deeper recursive
    // incarnation returning to the very same address, or another thread. It has
    // to stay armed, but the trapped thread is parked ON it with the original
    // byte already restored, so planting the INT3 straight back would trap on it
    // again the instant the thread resumes, forever. Same dance a persistent
    // breakpoint hit uses: leave it unplanted, single-step the thread off it,
    // re-plant on that trap and keep running.
    procedure RearmStepBpAfterForeignHit(BpVA: UInt64; Tid: DWORD);
    procedure ClearStepBps;
    procedure PlantInFuncStepBps;
    function  RvaInStepFunc(Rva: UInt64): Boolean;
    function  StepOverAtNewLine(Rva: UInt64): Boolean;
    procedure HandleSmOverStep(Tid: DWORD; PcVA: UInt64);
    // --- instruction granularity (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 1) ---
    // The decoder, built on first use. Nil only when the process does not exist
    // yet; an UNAVAILABLE backend is still a live instance whose Available is
    // False, so the refusal can quote its StatusText.
    function  InstructionDisassembler: IDisassembler;
    // Decides one instruction step without mutating anything the debuggee can
    // observe. Runs on the REQUESTING thread (see TInstrStepPlan).
    function  BuildInstructionStepPlan(Kind: TInstructionStepKind; Tid: DWORD;
                out Plan: TInstrStepPlan; out RefusalReason: string): Boolean;
    // Executes an already-decided plan. Runs on the Run thread.
    procedure DoStepInstruction(const Cmd: TCommand);
    // True when a stop at BpVA on Tid is THIS instruction step's landing rather
    // than a deeper recursive incarnation reaching the same address, or another
    // thread's business.
    function  InstrStepLandedAt(BpVA: UInt64; Tid: DWORD): Boolean;
    procedure EndInstructionStep;
    // --- step at a first-chance exception stop -------------------------------
    // Executes an already-decided plan. Runs on the Run thread, and is the ONE
    // place that releases the pending event with DBG_EXCEPTION_NOT_HANDLED for a
    // step -- delivering the exception is the whole mechanism.
    procedure DoStepToHandler(const Cmd: TCommand);
    // True when BpVA is one of the handler blocks the in-flight step is waiting
    // on, whichever thread reached it.
    function  ExcStepBlock(BpVA: UInt64): Boolean;
    // True when a hit at BpVA on Tid is THIS step's landing.
    function  ExcStepLandedAt(BpVA: UInt64; Tid: DWORD): Boolean;
    procedure EndExceptionStep;
    procedure ApplyAllBreakpoints;
    // Moves a breakpoint that landed on a routine's ENTRY (a `begin` line) to
    // the first address of its body, where the parameters are actually spilled.
    function  BreakpointBodyRva(Rva: UInt64): UInt64;
    procedure ClearBreakpointsByFile(const SourceFile: string);
    procedure UnpatchBpAtRip(Tid: DWORD = 0);
    // Freeze every thread except StepTid for the duration of a step; thaw them
    // at the next reported stop. Idempotent-safe (never stacks two freezes).
    procedure FreezeThreadsForStep(StepTid: DWORD);
    procedure ThawStepFrozenThreads;
    function  ReadDelphiExceptionClass(ObjAddr: UInt64): string;
    function  ReadDelphiExceptionClassChain(ObjAddr: UInt64): TArray<string>;
    function  ReadDelphiExceptionMessage(ObjAddr: UInt64): string;
    function  ReadRemoteAnsiString(VA: UInt64; MaxLen: Integer): string;
    procedure CaptureAnnouncedThreadName(const Ev: TDebugEvent);
    function  RaiseSiteLocation(out UnitName: string; out Line: Integer): Boolean;
    function  FormatCallStackText: string;
    procedure ProcessCommandQueue;
    procedure DrainBreakpointCommands;
    procedure DoSetBreakpoints(const Spec: TBpSpec);
    // Address-breakpoint counterparts of ClearBreakpointsByFile/DoSetBreakpoints.
    // Identity is (Kind=bkAddress, ModuleName), not SourceFile -- see TAddrBpSpec.
    procedure ClearAddressBreakpointsByModule(const ModuleName: string);
    procedure DoSetAddressBreakpoints(const Spec: TAddrBpSpec);
    procedure HandleCreateProcess(const Ev: TDebugEvent);
    procedure WarnIfUnsupportedTargetArchitecture;
    procedure HandleCreateThread(const Ev: TDebugEvent);
    procedure HandleExitThread(const Ev: TDebugEvent);
    procedure HandleExitProcess(const Ev: TDebugEvent);
    procedure DrainUntilExit(TimeoutMs: Cardinal);
    procedure CloseTargetHandles;
    procedure HandleOutputDbgString(const Ev: TDebugEvent);
    procedure HandleException(const Ev: TDebugEvent; out ContinueStatus: DWORD);
    procedure HandleLoadDll(const Ev: TDebugEvent);
    procedure HandleUnloadDll(const Ev: TDebugEvent);
    procedure ReportStopped(Reason: TStopReason; VA: UInt64);
    // Thread whose pending event must be released to resume (see FStopEventTid).
    function  ResumeTid: DWORD;
    // Pick a real user thread to REPORT for a pause instead of the injected one.
    function  PickPauseReportTid(EventThread: DWORD): DWORD;
    // Release the current stop's pending debug event (on ResumeTid) and clear the
    // pause override so the next stop reports normally.
    procedure ReleasePendingEvent(Status: DWORD);
  public
    constructor Create(ADebugInfo: TDebugInfoSet; PreferredBase: UInt64);
    destructor  Destroy; override;
    // Called from debug thread
    procedure Launch(const ExePath: string; StopAtEntry: Boolean);
    procedure Attach(ProcessId: Cardinal; KillOnDetach: Boolean);
    procedure SetExceptionFilters(Filters: TExceptionFilters);
    procedure SetDelphiClassFilter(const ClassNames: string);
    procedure ProcessOneEvent; // returns immediately if no event in 10ms
    property  Running:   Boolean read FRunning;
    // Thread-safe: called from stdin reader thread
    procedure PostCommand(const Cmd: TCommand);
    // Instruction-granularity stepping (IDebugTarget; see its declaration for
    // the contract). Decides and refuses synchronously on the CALLING thread,
    // then posts the decided plan for the Run thread to execute.
    function  StepInstruction(Kind: TInstructionStepKind; ThreadId: DWORD;
                out RefusalReason: string): Boolean;
    // Stepping at a first-chance exception stop (IDebugTarget; see its
    // declaration for the contract). Same split as StepInstruction: decided and
    // refused synchronously here, executed on the Run thread.
    function  StoppedOnUndeliveredException: Boolean;
    function  StepToExceptionHandler(ThreadId: DWORD;
                out RefusalReason: string): Boolean;
    // Why the last step abandoned itself, or '' when the last step completed
    // normally. Read by the host so a stop that a step did not reach can say so.
    function  LastStepNote: string;
    procedure SetInstructionDisassembler(const Disasm: IDisassembler);
    // Thread enumeration (IDebugTarget).
    function  GetThreadIds: TArray<DWORD>;
    function  GetThreadName(TID: DWORD): string;
    function  GetStoppedThreadId: DWORD;
    // Called from debug thread after stop
    function  GetStackFrames: TArray<TStackFrame>; overload;
    function  GetStackFrames(TID: DWORD): TArray<TStackFrame>; overload;
    function  RawStackCandidates(TID: DWORD;
                MaxItems: Integer = 0): TArray<TRawStackCandidate>;
    function  GetRawStackFrames(TID: DWORD;
                MaxItems: Integer = 0): TArray<TStackFrame>;
    function  ResymbolicateFrames(
                const Frames: TArray<TStackFrame>): TArray<TStackFrame>;
    procedure SymbolicateAddress(VA: UInt64; AtReturnAddress: Boolean;
                var Frame: TStackFrame);
    function  GetSourceLocation(out SourceFile: string; out Line: Integer): Boolean;
    function  GetLocalValues: TArray<TLocalValue>;
    function  GetLocalValuesForFrame(FrameRBP, FuncEntryVA: UInt64;
                const FuncName: string;
                FramePcRva: UInt64 = 0): TArray<TLocalValue>;
    // Select / clear the active call-stack frame for locals + evaluate.
    procedure SetActiveFrame(FrameRBP, FuncEntryVA: UInt64; const FuncName: string;
                FramePC: UInt64 = 0);
    procedure ClearActiveFrame;
    // ARCH: this is a Win64-ABI question. x86 has NO analogue -- Delphi's
    // 32-bit register convention passes the first three parameters in
    // EAX/EDX/ECX with no stack home at all, spills them to NEGATIVE EBP
    // offsets, and orders stack parameters in reverse. Measured in Phase 0:
    // Self is provably not at EBP+8. The x86 implementation must answer from
    // debug-info symbol offsets or refuse, never from a positional formula.
    function  CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64; virtual;
    function  GetRegisters: TRegisterSnapshot;
    // Look up a symbol name (local or global) and return a TLocalValue for it.
    // Returns False if no such symbol is in scope.
    function  EvaluateName(const Name: string; out Value: TLocalValue): Boolean;
    // Local-only / global-only variants used by ExprEval to enforce the
    // local -> Self.<name> -> global resolution priority.
    function  EvaluateLocalName(const Name: string; out Value: TLocalValue): Boolean;
    function  EvaluateGlobalName(const Name: string; out Value: TLocalValue): Boolean;
    function  ReadProcessMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    function  ReadCodeMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): NativeUInt;
    function  WriteMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    function  WriteMemoryPartial(VA: UInt64; Buf: Pointer; Size: NativeUInt): NativeUInt;
    // Writes a named register by ROLE name (RIP/RSP/RBP/RAX..RDI/R8..R15/
    // EFlags -- the same vocabulary GetRegisters reports). VIRTUAL for the
    // same reason the thread-context funnel above is: a 32-bit target needs
    // Wow64Get/SetThreadContext and has no R8..R15 at all. This base
    // implementation is the native x64 answer; the WOW64 override lives in
    // WinDebuggerX86.pas.
    function  SetRegisterByName(const Name: string; Value: UInt64): Boolean; virtual;
    // Sets a Delphi string variable in the debuggee. Allocates a new
    // immortal-literal buffer (refcount = -1) for the new value, then
    // hijacks the stopped thread to call System.@UStrAsg / @LStrAsg so the
    // old string's refcount is properly decremented (and freed by the RTL
    // if it drops to zero). The new buffer survives until process exit,
    // which mirrors how Delphi treats string literals.
    function  SetStringVariable(VarAddr: UInt64; const Text, TypeHint: string): Boolean;
    // Enum/set type metadata from RSM TypeInfo records.
    function  LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
    // RVA (from MAP file) to actual virtual address in the running process.
    function  RvaToVA(Rva: UInt64): UInt64;
    function  VAToRva(VA: UInt64): UInt64;
    // Memory layout of the debuggee's address space. Fixed at 64-bit here; the
    // x86 implementation reports its own, and callers decoding target
    // structures must consult this rather than SizeOf(Pointer).
    function  TargetLayout: TTargetLayout; virtual;
    // Sets RIP of the currently stopped thread. Returns False if not stopped.
    function  SetInstructionPointer(VA: UInt64): Boolean;
    // Hardware watchpoints. See IDebugTarget for what this increment does and
    // does not cover.
    function  ArmHardwareWatchpoint(TID: DWORD; Slot: Integer; Address: UInt64;
                SizeBytes: Integer; WriteOnly: Boolean): Boolean;
    function  DisarmHardwareWatchpoint(TID: DWORD; Slot: Integer): Boolean;
    function  HardwareWatchpointHitCount: Integer;
    function  LastHardwareWatchpointHit: TWatchpointHit;
    // Process-wide allocator (increment 3): picks a free slot, arms it on every
    // thread live now, and keeps it armed on every thread that appears afterwards
    // (HandleCreateThread) until ClearDataWatchpoint or detach. Exhaustion is
    // refused explicitly, naming what already holds all four slots -- never
    // silently drops the fifth. This is what a real feature surface calls; the
    // raw per-thread pair above stays for direct single-thread control.
    function  SetDataWatchpoint(Address: UInt64; SizeBytes: Integer; WriteOnly: Boolean;
                const OwnerDescription: string; out Slot: Integer;
                out RefusalReason: string): Boolean;
    function  ClearDataWatchpoint(Slot: Integer): Boolean;
    function  ApplyDataBreakpointCommand(const Spec: TDataBpArmSpec;
                out Slot: Integer; out RefusalReason: string): Boolean;
    // Resolves a fully-qualified symbol name (e.g. `TWidget.GetScore`) to its
    // run-time VA via the loaded MAP/RSM data. Returns False when no match.
    function  TryResolveSymbolVA(const Name: string; out VA: UInt64): Boolean;
    function  AddressIsExecutable(VA: UInt64): Boolean;
    // True while a synthetic remote call (RunMethodCall) is pumping. Lets the
    // stdin thread decide whether an incoming control command should abort it.
    function  RemoteCallInFlight: Boolean;
    // Requests the in-flight synthetic call (if any) to abort at the next pump
    // iteration. Thread-safe; a no-op when no call is running.
    procedure RequestAbortRemoteCall;
    procedure BeginAutoCallWindow(TotalMs: Cardinal);
    procedure EndAutoCallWindow;
    function  AutoCallWindowExhausted: Boolean;
    function  TryResolveClassRef(const ClassName: string; out VA: UInt64): Boolean;
    function  CurrentScopeClassName: string;
    function  TryResolveConstValue(const Name: string;
                out Value: Int64; out TypeHint: string): Boolean;
    // Returns the VA of a reusable, zeroed scratch slot in the debuggee
    // suitable for holding the hidden var-out result of a managed getter.
    // Allocates the backing page on first use. Returns 0 on failure.
    function  GetRemoteScratchSlot(MinSize: NativeUInt): UInt64;
    // Allocates a real Delphi string in the debuggee (header + payload +
    // null terminator) and returns its char-buffer pointer. Used when
    // marshalling string literals as arguments to a method call.
    function  AllocateRemoteString(const Text, TypeHint: string;
                out Ptr: UInt64): Boolean;
    // Generic method-call invoker. Callers supply POSITIONAL arguments; this
    // x64 implementation dispatches them to RCX/RDX/R8/R9 (or XMM0..3 for
    // floats, by position) and to the stack for args 5+, then captures RAX and
    // the low qword of XMM0. Which registers those are is this implementation's
    // business, which is why the parameters are not named after them.
    function  RunMethodCall(FuncVA: UInt64;
                const ArgValues: array of UInt64;
                const ArgKinds:  array of TSyntheticArgKind;
                out IntResult, FloatResultLow: UInt64): Boolean;
    function  LastSyntheticCallError: string;
    // Invokes a function in the debuggee, capturing the return value (RAX).
    // Public surface for the expression evaluator's method-backed property
    // getters. Arguments are positional; trailing ones may be 0 for unary
    // callees (Self only).
    function  RunRemoteCallEx(FuncVA: UInt64;
                Arg0, Arg1, Arg2, Arg3: UInt64;
                out IntResult, FloatResultLow: UInt64): Boolean;
  private
    function  RunRemoteCall(FuncVA: UInt64; Arg0, Arg1: UInt64): Boolean;
  protected
    // The only calling-convention-aware halves of the synthetic-call
    // machinery. The event pump between them is architecture neutral and stays
    // shared; a 32-bit target replaces exactly these two.
    function  PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
                const ArgValues: array of UInt64;
                const ArgKinds:  array of TSyntheticArgKind;
                const SavedCtx: TContext): Boolean; virtual;
    function  ReadSyntheticCallResult(TH: THandle;
                out IntResult, FloatResultLow: UInt64): Boolean; virtual;
  public
    procedure Terminate;
    // IDebugTarget event accessors. Method-style getter/setter pairs are
    // required by the interface; the field-backed property is kept for
    // intra-class readability.
    function  GetOnStopped:     TOnStopped;     procedure SetOnStopped(const V: TOnStopped);
    function  GetOnExited:      TOnExited;      procedure SetOnExited(const V: TOnExited);
    function  GetOnOutput:      TOnOutput;      procedure SetOnOutput(const V: TOnOutput);
    function  GetOnDllLoaded:   TOnDllLoaded;   procedure SetOnDllLoaded(const V: TOnDllLoaded);
    function  GetOnDllUnloaded: TOnDllUnloaded; procedure SetOnDllUnloaded(const V: TOnDllUnloaded);
    function  GetOnBpHit:       TOnBpHit;       procedure SetOnBpHit(const V: TOnBpHit);
    // Method-style accessors for the read-only properties -- needed for
    // IDebugTarget. Declared as functions; the field-backed property
    // declarations below let the rest of TWinDebugger keep using
    // `Self.ProcessHandle` etc.
    function  ProcessHandle:     THandle;
    function  ImageBase:         UInt64;
    function  HasExited:         Boolean;
    function  LastExceptionDesc: string;
    function  LastExceptionClass:   string;
    function  LastExceptionIsDelphiRaise: Boolean;
    function  LastExceptionMessage: string;
    function  CurrentExceptionObject: UInt64;
    function  TryGetThreadLastError(TID: DWORD; out LastError, LastStatus: DWORD;
                out Reason: string): Boolean;
    function  TryGetHandlerException(out Kind: TExcHandlerBlockKind;
                out ObjVA: UInt64; out Reason: string): Boolean;
    // The VA of a routine a module MAPPED IN THE DEBUGGEE exports by name.
    //
    // Needed because an application split into runtime packages keeps its RTL
    // in `rtl<version>.bpl`, which ships without debug information: no symbol
    // reader can name a single routine in it. The export directory can, and it
    // is read out of the mapped image, so relocation is already applied.
    // Delphi packages export every routine under its mangled name --
    // `_ZN6System12ExceptObjectEv` on x64, `@System@ExceptObject$qqrv` on x86.
    function  TryResolveExportedRoutine(ModBase: UInt64;
                const ExportName: AnsiString; out VA: UInt64): Boolean;
    procedure SetExceptionRules(const Rules: TArray<TExceptionRule>);
    property  OnStopped:      TOnStopped     read GetOnStopped     write SetOnStopped;
    property  OnExited:       TOnExited      read GetOnExited      write SetOnExited;
    property  OnOutput:       TOnOutput      read GetOnOutput      write SetOnOutput;
    property  OnDllLoaded:    TOnDllLoaded   read GetOnDllLoaded   write SetOnDllLoaded;
    property  OnDllUnloaded:  TOnDllUnloaded read GetOnDllUnloaded write SetOnDllUnloaded;
    property  OnBpHit:        TOnBpHit       read GetOnBpHit       write SetOnBpHit;
  end;

// Removes locals that share a frame address with another local, because two
// distinct STACK locals in one frame cannot. Register-allocated locals are
// exempt. Exposed so the rule is testable without a live process.
function DropAddressCollisions(const Values: TArray<TLocalValue>;
  out Dropped: Integer): TArray<TLocalValue>;

implementation

uses
  System.StrUtils,        // ContainsText, for the language-handler name check
  System.Generics.Defaults;

const
  // Shortest identifier that may be TAIL-MATCHED against unit-qualified global
  // names. Below this the match is a coincidence: a one- or two-character name
  // finds something in any large binary, and the found symbol is unrelated.
  // Three is the shortest length at which a Delphi global name carries enough
  // signal to be worth the risk; anything shorter must be written qualified.
  MIN_TAILMATCH_NAME_LEN = 3;

{ ntdll binding: the TEB address of a thread in another process }

type
  TThreadBasicInformation = record
    ExitStatus:     LongInt;
    TebBaseAddress: Pointer;
    ClientId: record
      UniqueProcess: THandle;
      UniqueThread:  THandle;
    end;
    AffinityMask:   ULONG_PTR;
    Priority:       LongInt;
    BasePriority:   LongInt;
  end;

const
  ThreadBasicInformation = 0;

function NtQueryInformationThread(ThreadHandle: THandle;
  ThreadInformationClass: DWORD; ThreadInformation: Pointer;
  ThreadInformationLength: ULONG; ReturnLength: PULONG): LongInt; stdcall;
  external 'ntdll.dll';

{ DbgHelp bindings for StackWalk64 }

type
  // Matches C ADDRESS64: Offset(8) + Segment(2) + 2-byte pad + Mode(4) = 16 bytes
  TDbgAddress64 = record
    Offset:  UInt64;
    Segment: Word;
    Mode:    DWORD;  // ADDRESS_MODE enum (AddrModeFlat = 3); Delphi inserts 2-byte pad before
  end;

  // One `.pdata` entry (IMAGE_RUNTIME_FUNCTION_ENTRY). Declared here rather
  // than beside its first user because two unrelated features decode it: the
  // prologue reader (frame size) and the exception-step planner (scope tables).
  PRuntimeFunctionEntry = ^TRuntimeFunctionEntry;
  TRuntimeFunctionEntry = packed record
    BeginAddress, EndAddress, UnwindInfoAddress: UInt32;
  end;

  // Matches C STACKFRAME64 (264 bytes on x64)
  TDbgStackFrame64 = record
    AddrPC:         TDbgAddress64;          // current instruction
    AddrReturn:     TDbgAddress64;          // return address
    AddrFrame:      TDbgAddress64;          // frame pointer
    AddrStack:      TDbgAddress64;          // stack pointer
    AddrBStore:     TDbgAddress64;          // backing store (IA-64 only)
    FuncTableEntry: Pointer;                // pointer to pdata/fpo or nil
    Params:         array[0..3] of UInt64;  // possible call arguments
    Far_:           BOOL;                   // WOW far call
    Virtual_:       BOOL;                   // virtual frame
    Reserved:       array[0..2] of UInt64;
    KdHelp:         array[0..111] of Byte;  // KDHELP64 (112 bytes)
  end;

const
  AddrModeFlat             = DWORD(3);
  IMAGE_FILE_MACHINE_AMD64 = DWORD($8664);
  IMAGE_FILE_MACHINE_UNKNOWN = USHORT($0000);
  IMAGE_FILE_MACHINE_I386    = USHORT($014C);
  EXCEPTION_ACCESS_VIOLATION: DWORD = $C0000005;

  // A 32-bit (WOW64) target's traps surface under the WOW64 layer's OWN status
  // codes, not the native ones: an INT3 arrives as $4000001F rather than
  // EXCEPTION_BREAKPOINT ($80000003). A debug loop that tests only the native
  // code misses every user breakpoint in a 32-bit target and leaves it spinning,
  // re-dispatching its own trap forever.
  //
  // Deliberately UNTYPED constants: a typed constant is not a compile-time
  // constant in Delphi and cannot appear as a `case` label.
  STATUS_WX86_BREAKPOINT  = $4000001F;
  STATUS_WX86_SINGLE_STEP = $4000001E;

function IsBreakpointExceptionCode(Code: DWORD): Boolean; inline;
begin
  Result := (Code = DWORD(EXCEPTION_BREAKPOINT)) or (Code = DWORD(STATUS_WX86_BREAKPOINT));
end;

// Measured, not assumed: setting EFLAGS.TF on a WOW64 thread and continuing
// yields $4000001E, not EXCEPTION_SINGLE_STEP. Stepping therefore needs the same
// treatment as breakpoints -- without it every step in a 32-bit target falls
// through to the generic exception path and the step never completes.
function IsSingleStepExceptionCode(Code: DWORD): Boolean; inline;
begin
  Result := (Code = DWORD(EXCEPTION_SINGLE_STEP)) or (Code = DWORD(STATUS_WX86_SINGLE_STEP));
end;

// IsWow64Process2 (Windows 10+) reports the target's image machine directly:
// a 32-bit (WOW64) process yields ProcessMachine = IMAGE_FILE_MACHINE_I386,
// a native x64 process yields IMAGE_FILE_MACHINE_UNKNOWN. Resolved dynamically
// so the adapter still loads on hosts without the export.
type
  TIsWow64Process2 = function(hProcess: THandle;
    out ProcessMachine: USHORT; out NativeMachine: USHORT): BOOL; stdcall;

function SymInitialize(hProcess: THandle; UserSearchPath: PAnsiChar;
  fInvadeProcess: BOOL): BOOL; stdcall; external 'dbghelp.dll';
function SymCleanup(hProcess: THandle): BOOL; stdcall; external 'dbghelp.dll';
function StackWalk64(MachineType: DWORD; hProcess, hThread: THandle;
  var StackFrame: TDbgStackFrame64; ContextRecord: Pointer;
  ReadMemoryRoutine, FunctionTableAccessRoutine,
  GetModuleBaseRoutine, TranslateAddressRoutine: Pointer): BOOL;
  stdcall; external 'dbghelp.dll';
function SymFunctionTableAccess64(hProcess: THandle; AddrBase: UInt64): Pointer;
  stdcall; external 'dbghelp.dll';
function SymGetModuleBase64(hProcess: THandle; qwAddr: UInt64): UInt64;
  stdcall; external 'dbghelp.dll';
// Module (de)registration. SymInitialize(fInvadeProcess=True) enumerates only the
// modules mapped at that instant, so a package/DLL loaded later is invisible to
// dbghelp unless it is registered explicitly -- see RegisterModuleWithDbgHelp.
// The wide variants avoid mangling a path with non-ASCII characters.
function SymLoadModuleExW(hProcess, hFile: THandle;
  ImageName, ModuleName: PWideChar; BaseOfDll: UInt64; DllSize: DWORD;
  Data: Pointer; Flags: DWORD): UInt64; stdcall; external 'dbghelp.dll';
function SymUnloadModule64(hProcess: THandle; BaseOfDll: UInt64): BOOL;
  stdcall; external 'dbghelp.dll';
function SymSetOptions(SymOptions: DWORD): DWORD; stdcall; external 'dbghelp.dll';
function SymGetOptions: DWORD; stdcall; external 'dbghelp.dll';

const
  // Suppress the OS error box dbghelp can raise while opening a module image.
  // TRAP, measured: do NOT add SYMOPT_DEFERRED_LOADS here. It looks free -- we
  // only ever ask dbghelp for module bases and .pdata function tables, never for
  // symbols -- but with it set the function-table callback does not reliably
  // materialise a deferred module, so StackWalk64 loses unwind info and reverts
  // to the leaf convention. It cost the whole Test_ClosureParam_* BPL set.
  SYMOPT_FAIL_CRITICAL_ERRORS = DWORD($00000200);

// Defined further down (locals section); used earlier by EvaluateGlobalName.

{ TWinDebugger }

constructor TWinDebugger.Create(ADebugInfo: TDebugInfoSet; PreferredBase: UInt64);
begin
  inherited Create;
  FDebugInfo     := ADebugInfo;
  FPreferredBase := PreferredBase;
  FThreads       := TDictionary<DWORD, THandle>.Create;
  FThreadNames   := TDictionary<DWORD, string>.Create;
  FStepFrozenTids := TList<DWORD>.Create;
  FBreakpoints   := TList<TBreakpointRec>.Create;
  FCommandQueue  := TQueue<TCommand>.Create;
  FDllBases      := TDictionary<string, UInt64>.Create;
  FDllSizes      := TDictionary<string, UInt64>.Create;
  FGlobalMissCache := TDictionary<string, UInt64>.Create;
  FExportIndexes := TDictionary<UInt64, TExportSymbolIndex>.Create;
  InitializeCriticalSection(FQueueLock);
  FFirstBreak             := False;
  FRunning                := False;
  FPendingContinueStatus  := DBG_CONTINUE;
  FIsStopped              := False;
  FExceptionFilters       := DEFAULT_EXCEPTION_FILTERS;
  FPauseRequested         := False;
  FWatchArmedSlots        := 0;
  FWatchHitCount          := 0;
  FLastWatchHit           := Default(TWatchpointHit);
  FLastWatchHit.Slot      := -1;   // "no hit yet" -- 0 is a real slot number
end;

destructor TWinDebugger.Destroy;
begin
  // Terminate already closes these when it ran; idempotent otherwise (e.g. the
  // engine was created but never launched, or a launch failed early).
  CloseTargetHandles;
  FThreads.Free;
  FThreadNames.Free;
  FStepFrozenTids.Free;
  FBreakpoints.Free;
  FCommandQueue.Free;
  FDllBases.Free;
  FDllSizes.Free;
  FGlobalMissCache.Free;
  FExportIndexes.Free;
  DeleteCriticalSection(FQueueLock);
  inherited;
end;

function TWinDebugger.TryResolveSymbolVA(const Name: string; out VA: UInt64): Boolean;
var
  Rva: UInt64;
begin
  Result := False;
  VA := 0;
  if FDebugInfo = nil then Exit;
  // Scope to the active frame's source unit so a same-named symbol in an
  // unrelated unit is not picked. This applies to BOTH unqualified names (a
  // free proc / bare symbol) AND qualified `Class.Method` names: when a class
  // method collides across units (40 same-named classes in 40 units), the
  // frame's `uses` selects the in-scope copy (Delphi last-wins). NameToRvaScoped
  // falls back to flat first-hit when nothing in scope matches, so non-colliding
  // names are unaffected.
  var FrameVA := FActiveFramePC;
  if FrameVA = 0 then FrameVA := CurrentRIP(FStoppedTid);
  if (FrameVA <> 0) and FDebugInfo.NameToRvaScoped(Name, VAToRva(FrameVA), Rva) then begin
    VA := RvaToVA(Rva);
    Exit(True);
  end;
  if not FDebugInfo.NameToRva(Name, Rva) then Exit;
  VA := RvaToVA(Rva);
  Result := True;
end;

function TWinDebugger.AddressIsExecutable(VA: UInt64): Boolean;
begin
  Result := False;
  if (FProcess = 0) or (VA = 0) then
    Exit;
  var Mbi := Default(MEMORY_BASIC_INFORMATION);
  if VirtualQueryEx(FProcess, Pointer(VA), Mbi, SizeOf(Mbi)) <> SizeOf(Mbi) then
    Exit;
  if Mbi.State <> MEM_COMMIT then
    Exit;
  var Prot := Mbi.Protect and not (PAGE_GUARD or PAGE_NOCACHE);
  Result := (Prot = PAGE_EXECUTE) or
            (Prot = PAGE_EXECUTE_READ) or
            (Prot = PAGE_EXECUTE_READWRITE) or
            (Prot = PAGE_EXECUTE_WRITECOPY);
end;

function TWinDebugger.RemoteCallInFlight: Boolean;
begin
  Result := AtomicCmpExchange(FInRemoteCall, 0, 0) <> 0;
end;

procedure TWinDebugger.RequestAbortRemoteCall;
begin
  AtomicExchange(FAbortRemoteCall, 1);
end;

procedure TWinDebugger.BeginAutoCallWindow(TotalMs: Cardinal);
begin
  // Only the outermost open sets the deadline: a nested burst must not extend
  // the budget of the one that contains it.
  if FAutoCallDepth = 0 then
    FAutoCallDeadline := GetTickCount64 + TotalMs;
  Inc(FAutoCallDepth);
end;

procedure TWinDebugger.EndAutoCallWindow;
begin
  if FAutoCallDepth = 0 then
    Exit;
  Dec(FAutoCallDepth);
  if FAutoCallDepth = 0 then
    FAutoCallDeadline := 0;
end;

function TWinDebugger.AutoCallWindowExhausted: Boolean;
begin
  Result := (FAutoCallDepth > 0) and (GetTickCount64 >= FAutoCallDeadline);
end;

function TWinDebugger.TryResolveClassRef(const ClassName: string;
  out VA: UInt64): Boolean;
var
  Rva: UInt64;
begin
  Result := False;
  VA := 0;
  if FDebugInfo = nil then Exit;
  var FrameVA := FActiveFramePC;
  if FrameVA = 0 then FrameVA := CurrentRIP(FStoppedTid);
  if FrameVA = 0 then Exit;
  if FDebugInfo.TryResolveClassVmtScoped(ClassName, VAToRva(FrameVA), Rva) then begin
    VA := RvaToVA(Rva);
    Result := True;
  end;
end;

function TWinDebugger.LastSyntheticCallError: string;
begin
  Result := FLastSyntheticCallError;
end;

function TWinDebugger.CurrentScopeClassName: string;
begin
  Result := '';
  var FnName := FActiveFrameName;
  if FnName = '' then begin
    // No frame explicitly selected: the scope is the stopped location's.
    var PC := FActiveFramePC;
    if PC = 0 then
      PC := CurrentRIP(FStoppedTid);
    if (PC = 0) or (FDebugInfo = nil) then
      Exit;
    if not FDebugInfo.RvaToFunctionName(VAToRva(PC), FnName) then
      Exit;
  end;
  // 'TNestedHost.Describe' -> 'TNestedHost'; 'Unit.TClass.Method' -> 'TClass'.
  // A plain routine has no dot and yields '', which is correct: it is in no
  // class's scope.
  var Parts := FnName.Split(['.']);
  if Length(Parts) >= 2 then
    Result := Parts[High(Parts) - 1];
end;

function TWinDebugger.TryResolveConstValue(const Name: string;
  out Value: Int64; out TypeHint: string): Boolean;
begin
  Value := 0;
  TypeHint := '';
  Result := False;
  if FDebugInfo = nil then Exit;
  var FrameVA := FActiveFramePC;
  if FrameVA = 0 then FrameVA := CurrentRIP(FStoppedTid);
  Result := FDebugInfo.TryResolveConstScoped(Name, VAToRva(FrameVA), Value, TypeHint);
end;

function TWinDebugger.GetRemoteScratchSlot(MinSize: NativeUInt): UInt64;
const
  SCRATCH_PAGE_SIZE = 4096;
var
  Zero: array[0..255] of Byte;
  ToZero: NativeUInt;
begin
  Result := 0;
  if FProcess = 0 then Exit;
  if FRemoteScratch = 0 then begin
    var P := VirtualAllocEx(FProcess, nil, SCRATCH_PAGE_SIZE,
      MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
    if P = nil then Exit;
    FRemoteScratch := UInt64(P);
  end;
  // Zero the leading bytes the caller asked for (cap at 256 -- every Win64
  // ABI return value we care about fits).
  if MinSize > SizeOf(Zero) then ToZero := SizeOf(Zero) else ToZero := MinSize;
  if ToZero > 0 then begin
    FillChar(Zero, ToZero, 0);
    if not WriteMemoryAt(FRemoteScratch, @Zero, ToZero) then Exit;
  end;
  Result := FRemoteScratch;
end;

function TWinDebugger.RvaToVA(Rva: UInt64): UInt64;
begin
  Result := FImageBase + Rva;
end;

function TWinDebugger.TargetLayout: TTargetLayout;
begin
  Result := TTargetLayout.For64Bit;
end;

function TWinDebugger.VAToRva(VA: UInt64): UInt64;
begin
  if VA >= FImageBase then
    Result := VA - FImageBase
  else
    Result := 0;
end;

function TWinDebugger.NearestInstructionBoundaryBefore(VA: UInt64;
  out BoundaryVA: UInt64): Boolean;
begin
  BoundaryVA := 0;
  if FDebugInfo = nil then
    Exit(False);
  // RVAs are one space anchored at the main image, and every module's provider
  // registers inside it -- which is what lets a BPL frame symbolicate at all.
  // So containment is decided by whether a provider OWNS the address, below,
  // and not by a range test here.
  //
  // Bounding this to the main image was tried and is wrong: it made code in a
  // runtime package permanently undecidable, and the user's own code mostly
  // LIVES in packages. An address no provider covers -- kernel32, ntdll --
  // still fails at RvaToFunctionStart and stays undecidable, which is what
  // preserves the OS tail; that was already true before the range test existed.
  if VA <= FImageBase then
    Exit(False);
  var TargetRva := VAToRva(VA);
  if TargetRva = 0 then
    Exit(False);

  // A boundary is only usable if it belongs to the routine the instruction
  // ENDING at the target lives in: decoding forward from an unrelated address
  // could otherwise land on the target by coincidence and manufacture an answer
  // out of nothing. That routine is the one containing the byte BEFORE the
  // target, which is what makes the -1 here load-bearing rather than cosmetic.
  //
  // Anchoring on the routine containing the target ITSELF (what this did) has
  // no answer when the target IS a function entry: no boundary exists before it
  // inside its own routine, so every such address came back csaUndecidable and
  // was kept unproven. Measured on Hydra2: $45CCB0 is the entry of the main
  // block, and that is precisely the impossible frame the tail kept offering.
  // With this anchor the decode runs through the PRECEDING routine and lands on
  // the target, where the previous instruction is a `ret`.
  //
  // For an ordinary mid-routine return address nothing changes: the byte before
  // it belongs to the same routine.
  var FuncStart: UInt64;
  if not FDebugInfo.RvaToFunctionStart(TargetRva - 1, FuncStart) then
    Exit(False);

  // Prefer the closest line record: the shorter the span, the less chance of
  // meeting the exception table dcc32 emits inline in the code stream.
  var Rva: UInt64;
  if FDebugInfo.NearestLineRvaBefore(TargetRva, Rva) and (Rva > FuncStart) then begin
    var FuncOfBoundary: UInt64;
    if FDebugInfo.RvaToFunctionStart(Rva, FuncOfBoundary) and
       (FuncOfBoundary = FuncStart) then begin
      BoundaryVA := RvaToVA(Rva);
      Exit(True);
    end;
  end;

  // No line record inside the routine, which is normal for a module that has
  // symbols but no line table. The entry is still a guaranteed instruction
  // boundary, so the decode is longer but no less exact.
  BoundaryVA := RvaToVA(FuncStart);
  Result := True;
end;

// See DebugTarget.IDebugTarget.NearestExportedEntryBefore. Reads the PE
// headers and export directory straight out of the LIVE mapped image
// (ReadProcessMemoryAt), never from the file on disk: the loaded image is
// already relocated and is exactly what will be decoded, and RVA-within-the-
// image equals VA-within-the-image directly, with no section/raw-offset
// translation to get wrong.
//
// The search key is VA-1, not VA, for the same reason
// NearestInstructionBoundaryBefore anchors on TargetRva-1: if VA is itself
// an export's entry point, decoding "before" it must still be answerable by
// walking through whatever PRECEDES it in the module (the tail of the
// previous exported routine, or unexported code between two exports) -- the
// byte stream does not stop meaning anything at a routine boundary, and the
// caller verifies the result lands exactly on VA regardless of which
// routine the boundary came from.
function TWinDebugger.IsForeignBitnessModule(Base: UInt64): Boolean;
// A WOW64 process has BOTH loaders mapped: the 32-bit ntdll the target actually
// executes, and the 64-bit ntdll / wow64*.dll layer that translates its
// syscalls. The debug loop is 64-bit, so it receives LOAD_DLL for all of them.
//
// The 64-bit half is not something a 32-bit session can use: no application
// code runs there, it never appears in the 32-bit stack this debugger walks, and
// no breakpoint can be placed in it. It is not merely useless either -- both
// ntdlls arrive under the file name `ntdll.dll`, and the module registry is
// keyed by name, so whichever loaded second used to silently overwrite the
// first. Dropping the foreign half at the door removes the collision by
// construction rather than by convention.
//
// The test is ONE-DIRECTIONAL on purpose. Above 4 GB means 64-bit only because
// we already know we are looking at a WOW64 process, where a 32-bit module
// cannot be there. The converse is NOT true: a 64-bit process can legitimately
// map an image below 4 GB (a DLL with a low preferred base and no relocation),
// so a symmetric rule would discard a real module in a 64-bit session.
begin
  Result := (not TargetLayout.Is64Bit) and (Base > $FFFFFFFF);
end;

function TWinDebugger.ModuleRangeFor(VA: UInt64; out Base, Size: UInt64): Boolean;

  function InRange(TryBase, TrySize: UInt64): Boolean;
  begin
    Result := (TryBase <> 0) and (TrySize <> 0) and
      (VA >= TryBase) and (VA < TryBase + TrySize);
  end;

begin
  Base := 0;
  Size := 0;
  if InRange(FImageBase, FImageSize) then begin
    Base := FImageBase;
    Size := FImageSize;
    Exit(True);
  end;
  for var KV in FDllBases do begin
    var DllSize: UInt64 := 0;
    if FDllSizes.TryGetValue(KV.Key, DllSize) and InRange(KV.Value, DllSize) then begin
      Base := KV.Value;
      Size := DllSize;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TWinDebugger.NearestExportedEntryBefore(VA: UInt64;
  out BoundaryVA: UInt64): Boolean;
const
  DIR_LEN = 40;         // sizeof(IMAGE_EXPORT_DIRECTORY)
  PE32_PLUS_MAGIC = $20B;

  function ReadDword(Addr: UInt64; out Value: DWORD): Boolean;
  begin
    Value := 0;
    Result := ReadProcessMemoryAt(Addr, @Value, 4);
  end;

  function ReadWord(Addr: UInt64; out Value: Word): Boolean;
  begin
    Value := 0;
    Result := ReadProcessMemoryAt(Addr, @Value, 2);
  end;

var
  ModBase, ModSize: UInt64;
begin
  BoundaryVA := 0;
  if not ModuleRangeFor(VA, ModBase, ModSize) then
    Exit(False);

  var ELfanew: DWORD;
  if not ReadDword(ModBase + $3C, ELfanew) then
    Exit(False);
  var PESig: DWORD;
  if not ReadDword(ModBase + ELfanew, PESig) or (PESig <> $00004550) then
    Exit(False);

  var OptBase := ModBase + ELfanew + 24;   // Signature(4) + IMAGE_FILE_HEADER(20)
  var OptMagic: Word;
  if not ReadWord(OptBase, OptMagic) then
    Exit(False);

  // DataDirectory[] sits right after the fixed optional-header fields: 96
  // bytes in for PE32 (Magic $10B), 112 bytes in for PE32+ (Magic $20B) --
  // same offsets DevTools\DisasmCoverage.dpr's TPEImage measures from a file.
  var DataDirBase: UInt64;
  if OptMagic = PE32_PLUS_MAGIC then
    DataDirBase := OptBase + 112
  else
    DataDirBase := OptBase + 96;

  var ExportRva, ExportSize: DWORD;
  if not ReadDword(DataDirBase, ExportRva) or not ReadDword(DataDirBase + 4, ExportSize) then
    Exit(False);
  if (ExportRva = 0) or (ExportSize = 0) then
    Exit(False);   // module has no export directory at all

  var NumFuncs, AddrFuncs: DWORD;
  if not ReadDword(ModBase + ExportRva + 20, NumFuncs) or
     not ReadDword(ModBase + ExportRva + 28, AddrFuncs) then
    Exit(False);

  if VA <= ModBase then
    Exit(False);
  var SearchRva := (VA - ModBase) - 1;   // see header comment: VA-1, not VA

  var BestRva: UInt64 := 0;
  var HaveBest := False;
  for var I := 0 to Integer(NumFuncs) - 1 do begin
    var FuncRva: DWORD;
    if not ReadDword(ModBase + UInt64(AddrFuncs) + UInt64(I) * 4, FuncRva) then
      Continue;
    if FuncRva = 0 then
      Continue;   // unused ordinal slot
    if (FuncRva >= ExportRva) and (FuncRva < ExportRva + ExportSize) then
      Continue;   // forwarder: RVA points at a string inside the export directory, not code
    if UInt64(FuncRva) > SearchRva then
      Continue;
    if (not HaveBest) or (UInt64(FuncRva) > BestRva) then begin
      BestRva := FuncRva;
      HaveBest := True;
    end;
  end;
  if not HaveBest then
    Exit(False);

  BoundaryVA := ModBase + BestRva;
  Result := True;
end;

function TWinDebugger.ExportIndexOf(ModBase: UInt64): TExportSymbolIndex;
// Reads one module's export directory out of the LIVE image and returns its
// named exports sorted by RVA. Built once per module and cached, including when
// it comes back empty: a module with no exports must not be re-walked for every
// frame that lands in it.
//
// The whole export data directory is read in ONE ReadProcessMemory call and
// parsed locally. Walking it with a read per field would mean thousands of
// round-trips into the debuggee for a module like ntdll, on a path that runs
// while the target is stopped and a human is waiting for a call stack.
const
  PE32_PLUS_MAGIC = $20B;
var
  Blob: TBytes;
  ExportRva, ExportSize: DWORD;

  function ReadDword(Addr: UInt64; out Value: DWORD): Boolean;
  begin
    Value := 0;
    Result := ReadProcessMemoryAt(Addr, @Value, 4);
  end;

  // Field access relative to the module, served from the one-shot read when the
  // RVA falls inside the export directory (which is where these arrays live in
  // every normal image) and from the target otherwise.
  function DwordAtRva(Rva: Cardinal; out Value: DWORD): Boolean;
  begin
    if (Rva >= ExportRva) and (Rva + 4 <= ExportRva + ExportSize) then begin
      Move(Blob[Rva - ExportRva], Value, 4);
      Exit(True);
    end;
    Result := ReadDword(ModBase + Rva, Value);
  end;

  function WordAtRva(Rva: Cardinal; out Value: Word): Boolean;
  begin
    if (Rva >= ExportRva) and (Rva + 2 <= ExportRva + ExportSize) then begin
      Move(Blob[Rva - ExportRva], Value, 2);
      Exit(True);
    end;
    Value := 0;
    Result := ReadProcessMemoryAt(ModBase + Rva, @Value, 2);
  end;

  function AnsiStringAtRva(Rva: Cardinal): string;
  begin
    Result := '';
    if (Rva < ExportRva) or (Rva >= ExportRva + ExportSize) then
      Exit;
    var Stop := Rva - ExportRva;
    while (Stop < Cardinal(Length(Blob))) and (Blob[Stop] <> 0) do
      Inc(Stop);
    var Len := Stop - (Rva - ExportRva);
    if Len = 0 then
      Exit;
    var Raw: AnsiString;
    SetString(Raw, PAnsiChar(@Blob[Rva - ExportRva]), Len);
    Result := string(Raw);
  end;

begin
  Result := nil;
  if FExportIndexes.TryGetValue(ModBase, Result) then
    Exit;

  try
    var ELfanew: DWORD;
    if not ReadDword(ModBase + $3C, ELfanew) then Exit;
    var PESig: DWORD;
    if not ReadDword(ModBase + ELfanew, PESig) or (PESig <> $00004550) then Exit;

    var OptBase := ModBase + ELfanew + 24;
    var OptMagic: Word := 0;
    if not ReadProcessMemoryAt(OptBase, @OptMagic, 2) then Exit;
    var DataDirBase: UInt64;
    if OptMagic = PE32_PLUS_MAGIC then
      DataDirBase := OptBase + 112
    else
      DataDirBase := OptBase + 96;

    if not ReadDword(DataDirBase, ExportRva) or
       not ReadDword(DataDirBase + 4, ExportSize) then Exit;
    if (ExportRva = 0) or (ExportSize = 0) then Exit;

    SetLength(Blob, ExportSize);
    if not ReadProcessMemoryAt(ModBase + ExportRva, @Blob[0], ExportSize) then Exit;

    var NumNames, AddrFuncs, AddrNames, AddrOrdinals: DWORD;
    if not DwordAtRva(ExportRva + 24, NumNames) or
       not DwordAtRva(ExportRva + 28, AddrFuncs) or
       not DwordAtRva(ExportRva + 32, AddrNames) or
       not DwordAtRva(ExportRva + 36, AddrOrdinals) then Exit;

    SetLength(Result, NumNames);
    var Kept := 0;
    for var I := 0 to Integer(NumNames) - 1 do begin
      var NameRva: DWORD;
      if not DwordAtRva(AddrNames + Cardinal(I) * 4, NameRva) then Continue;
      var Ordinal: Word;
      if not WordAtRva(AddrOrdinals + Cardinal(I) * 2, Ordinal) then Continue;
      var FuncRva: DWORD;
      if not DwordAtRva(AddrFuncs + Cardinal(Ordinal) * 4, FuncRva) then Continue;
      if FuncRva = 0 then Continue;
      // A forwarder's "address" is a string inside the export directory
      // (`ntdll.RtlAllocateHeap`), not code. Naming an address after one would
      // be a lie: the code it forwards to lives in another module entirely.
      if (FuncRva >= ExportRva) and (FuncRva < ExportRva + ExportSize) then Continue;
      var Name := AnsiStringAtRva(NameRva);
      if Name = '' then Continue;
      Result[Kept].Rva  := FuncRva;
      Result[Kept].Name := Name;
      Inc(Kept);
    end;
    SetLength(Result, Kept);

    TArray.Sort<TExportedSymbol>(Result, TComparer<TExportedSymbol>.Construct(
      function(const A, B: TExportedSymbol): Integer
      begin
        if A.Rva < B.Rva then
          Result := -1
        else if A.Rva > B.Rva then
          Result := 1
        else
          Result := 0;
      end));
  finally
    FExportIndexes.AddOrSetValue(ModBase, Result);
  end;
end;

function TWinDebugger.ModuleNameForBase(ModBase: UInt64): string;
// Lowercase file name of a loaded DLL, or '' when the base is the main image
// (whose path this class never receives -- it only ever sees its base address)
// or a module the loader never announced.
begin
  Result := '';
  for var KV in FDllBases do
    if KV.Value = ModBase then
      Exit(KV.Key);
end;

function TWinDebugger.ExportedSymbolAt(VA: UInt64; out Name: string;
  out Offset: UInt64; out EntryVA: UInt64): Boolean;
// Last-resort naming: the exported routine that starts at or before VA. This is
// what puts `BaseThreadInitThunk` and `RtlUserThreadStart` on the top frames of
// every thread stack instead of a bare address, and it names code in any DLL
// that ships without debug info -- which is the general case the two OS frames
// are only the most visible instance of.
begin
  Name    := '';
  Offset  := 0;
  EntryVA := 0;
  var ModBase, ModSize: UInt64;
  if not ModuleRangeFor(VA, ModBase, ModSize) then
    Exit(False);
  var Index := ExportIndexOf(ModBase);
  if Length(Index) = 0 then
    Exit(False);
  var TargetRva := VA - ModBase;
  if TargetRva > High(Cardinal) then
    Exit(False);

  // Rightmost entry with Rva <= TargetRva.
  var Lo := 0;
  var Hi := High(Index);
  var Best := -1;
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) div 2;
    if UInt64(Index[Mid].Rva) <= TargetRva then begin
      Best := Mid;
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  if Best < 0 then
    Exit(False);

  Name    := Index[Best].Name;
  Offset  := TargetRva - Index[Best].Rva;
  EntryVA := ModBase + Index[Best].Rva;
  Result  := True;
end;

function TWinDebugger.FunctionEntryOf(VA: UInt64; out EntryVA: UInt64): Boolean;
begin
  EntryVA := 0;
  if (FDebugInfo = nil) or (VA <= FImageBase) then
    Exit(False);
  var FuncRva: UInt64;
  if not FDebugInfo.RvaToFunctionStart(VAToRva(VA), FuncRva) then
    Exit(False);
  EntryVA := RvaToVA(FuncRva);
  Result := True;
end;

function TWinDebugger.ReadByte(VA: UInt64; out B: Byte): Boolean;
var
  Read: SIZE_T;
begin
  Result := ReadProcessMemory(FProcess, Pointer(VA), @B, 1, Read) and (Read = 1);
end;

function TWinDebugger.WriteByte(VA: UInt64; B: Byte): Boolean;
var
  Written: SIZE_T;
  OldProt, Dummy: DWORD;
begin
  VirtualProtectEx(FProcess, Pointer(VA), 1, PAGE_EXECUTE_READWRITE, OldProt);
  Result := WriteProcessMemory(FProcess, Pointer(VA), @B, 1, Written) and (Written = 1);
  VirtualProtectEx(FProcess, Pointer(VA), 1, OldProt, Dummy);
  FlushInstructionCache(FProcess, Pointer(VA), 1);
end;

function TWinDebugger.ThreadHandle(TID: DWORD): THandle;
begin
  if not FThreads.TryGetValue(TID, Result) then
    Result := 0;
end;

function TWinDebugger.TryGetThreadTeb(TID: DWORD; out TebVA: UInt64;
  out Reason: string): Boolean;
// The TEB of a thread in the TARGET, as the target's own code sees it.
//
// `NtQueryInformationThread(ThreadBasicInformation)` answers in the debugger's
// own bitness: for a WOW64 thread it reports the 64-bit TEB, which is NOT where
// the 32-bit code stores its last error. TWin32Debugger overrides this to cross
// that gap, which is why the whole lookup is one virtual method rather than an
// offset table.
//
// The result is self-checked rather than trusted: NtTib.Self inside the TEB
// must point back at the TEB. A layout that has moved, or a thread that has
// exited underneath us, then produces False instead of a plausible number read
// out of the wrong place.
const
  TEB64_SELF_OFFSET = $30;
begin
  TebVA  := 0;
  Reason := '';
  var H := ThreadHandle(TID);
  if H = 0 then begin
    Reason := Format('thread %d is not known to this session', [TID]);
    Exit(False);
  end;
  var Info := Default(TThreadBasicInformation);
  var Returned: ULONG := 0;
  if NtQueryInformationThread(H, ThreadBasicInformation, @Info,
       SizeOf(Info), @Returned) < 0 then begin
    Reason := 'NtQueryInformationThread failed';
    Exit(False);
  end;
  var Candidate := UInt64(Info.TebBaseAddress);
  if Candidate = 0 then begin
    Reason := 'the thread reports no TEB';
    Exit(False);
  end;
  var SelfPtr: UInt64 := 0;
  if not ReadProcessMemoryAt(Candidate + TEB64_SELF_OFFSET, @SelfPtr, SizeOf(SelfPtr)) then begin
    Reason := 'the TEB could not be read';
    Exit(False);
  end;
  if SelfPtr <> Candidate then begin
    Reason := Format('TEB self-check failed at $%x (NtTib.Self = $%x)', [Candidate, SelfPtr]);
    Exit(False);
  end;
  TebVA  := Candidate;
  Result := True;
end;

function TWinDebugger.TryGetThreadLastError(TID: DWORD;
  out LastError, LastStatus: DWORD; out Reason: string): Boolean;
// LastErrorValue and LastStatusValue live at fixed offsets in the TEB. The
// offsets differ per bitness, so the pair travels with the TEB lookup that knows
// which TEB it just found (LastErrorOffset / LastStatusOffset, overridden by
// TWin32Debugger alongside TryGetThreadTeb).
begin
  LastError  := 0;
  LastStatus := 0;
  if TID = 0 then
    TID := GetStoppedThreadId;
  var TebVA: UInt64;
  if not TryGetThreadTeb(TID, TebVA, Reason) then
    Exit(False);
  if not ReadProcessMemoryAt(TebVA + LastErrorOffset, @LastError, SizeOf(LastError)) then begin
    Reason := 'the TEB was located but LastError could not be read';
    Exit(False);
  end;
  // A failure to read the status is not a failure of the call: the error is the
  // value callers ask for, and the two live far apart in the TEB.
  if not ReadProcessMemoryAt(TebVA + LastStatusOffset, @LastStatus, SizeOf(LastStatus)) then
    LastStatus := 0;
  Result := True;
end;

function TWinDebugger.LastErrorOffset: Cardinal;
begin
  Result := $68;    // TEB64.LastErrorValue
end;

function TWinDebugger.LastStatusOffset: Cardinal;
begin
  Result := $1250;  // TEB64.LastStatusValue
end;

function TWinDebugger.FindBreakpointByVA(VA: UInt64): Integer;
begin
  for var I := 0 to FBreakpoints.Count - 1 do
    if FBreakpoints[I].VA = VA then
      Exit(I);
  Result := -1;
end;

// Call before any step/continue command. If RIP has a planted persistent BP,
// restore the original byte so the real instruction executes (not INT3).
// FRearmAfterStopVA ensures the BP is replanted at the next ReportStopped.
procedure TWinDebugger.UnpatchBpAtRip(Tid: DWORD = 0);
var
  RIP: UInt64;
  BpIdx: Integer;
begin
  if Tid = 0 then
    Tid := FStoppedTid;
  RIP := CurrentRIP(Tid);
  BpIdx := FindBreakpointByVA(RIP);
  if (BpIdx < 0) or FBreakpoints[BpIdx].IsOneShot or not FBreakpoints[BpIdx].IsPlanted then
    Exit;
  var BP := FBreakpoints[BpIdx];
  RemoveInt3(BP);
  FBreakpoints[BpIdx] := BP;
  FRearmAfterStopVA := RIP;
  DapLog(Format('UnpatchBpAtRip: removed INT3 at $%x, will rearm at next stop', [RIP]));
end;

procedure TWinDebugger.FreezeThreadsForStep(StepTid: DWORD);
begin
  // Never stack two freezes: a fresh step always starts from a thawed baseline.
  ThawStepFrozenThreads;
  for var KV in FThreads do begin
    if KV.Key = StepTid then
      Continue;
    // SuspendThread returns the previous suspend count (or $FFFFFFFF on failure).
    if (KV.Value <> 0) and (SuspendThread(KV.Value) <> DWORD(-1)) then
      FStepFrozenTids.Add(KV.Key);
  end;
  FStepTid          := StepTid;
  FStepFreezeActive := True;
  DapLog(Format('FreezeThreadsForStep: stepping tid=%d, froze %d other thread(s)',
    [StepTid, FStepFrozenTids.Count]));
end;

procedure TWinDebugger.ThawStepFrozenThreads;
begin
  if not FStepFreezeActive and (FStepFrozenTids.Count = 0) then begin
    FStepTid := 0;
    Exit;
  end;
  for var Tid in FStepFrozenTids do begin
    // Re-resolve the handle: a thread that exited mid-step was removed from
    // FThreads (handle closed), so ThreadHandle() returns 0 and we skip it.
    var TH := ThreadHandle(Tid);
    if TH <> 0 then
      ResumeThread(TH);
  end;
  FStepFrozenTids.Clear;
  FStepFreezeActive := False;
  FStepTid          := 0;
end;

// For $0EEDFADE Delphi exceptions: ExcInfo0 = ExceptionInformation[0] =
// address of the exception-object variable on the raiser's stack.
// One dereference gives the TObject pointer; read VMT[-112] for ClassName.
function TWinDebugger.ReadTargetPointer(Addr: UInt64; out V: UInt64): Boolean;
begin
  V := 0;
  Result := ReadProcessMemoryAt(Addr, @V, TargetLayout.PointerSize);
end;

function TWinDebugger.ReadDelphiExceptionClass(ObjAddr: UInt64): string;
var
  VmtAddr, TypeInfoAddr: UInt64;
  Buf: array[0..255] of AnsiChar;
  Read: SIZE_T;
  Len: Byte;
begin
  Result := '';
  if ObjAddr = 0 then Exit;
  // Both the object's VMT pointer and the TypeInfo slot inside the VMT are one
  // TARGET pointer wide, and the slot's offset differs per bitness (-168 on
  // Win64, -72 on Win32 -- measured, see TargetLayout.pas). Reading 8 bytes at a
  // fixed -168 on a 32-bit target yields an address that points nowhere, the
  // read fails, and the stop degrades to a bare "Delphi exception at ..." with
  // no class, no message and no $exception pseudo-local.
  if not ReadTargetPointer(ObjAddr, VmtAddr) or (VmtAddr = 0) then Exit;
  if not ReadTargetPointer(OffsetTargetAddress(VmtAddr, TargetLayout.VmtTypeInfo),
       TypeInfoAddr) or (TypeInfoAddr = 0) then Exit;
  // TypeInfo[0] = Kind (Byte), TypeInfo[1..] = ShortString class name.
  if not ReadProcessMemory(FProcess, Pointer(TypeInfoAddr + 1), @Buf, SizeOf(Buf), Read) or
     (Read < 1) then Exit;
  Len := Byte(Buf[0]);
  if (Len = 0) or (Len > 63) or (Read < UInt64(Len + 1)) then Exit;
  SetLength(Result, Len);
  for var I := 1 to Len do
    Result[I] := Char(Buf[I]);
end;

// Runtime class name plus all ancestors, for `classIs` (Delphi `is` semantics).
// Walks the RTTI chain: each tkClass TypeInfo is Kind(1) + ShortString name +
// TTypeData, whose ParentInfo (PPTypeInfo) sits at TypeData + sizeof(pointer);
// TypeData starts right after the name. TObject's ParentInfo is nil.
function TWinDebugger.ReadDelphiExceptionClassChain(ObjAddr: UInt64): TArray<string>;

  function ReadTypeName(TypeInfoAddr: UInt64; out NameLen: Byte): string;
  var
    Buf: array[0..255] of AnsiChar;
    Read: SIZE_T;
  begin
    Result  := '';
    NameLen := 0;
    if not ReadProcessMemory(FProcess, Pointer(TypeInfoAddr + 1), @Buf, SizeOf(Buf), Read) or
       (Read < 1) then Exit;
    var L := Byte(Buf[0]);
    if (L = 0) or (L > 63) or (Read < UInt64(L + 1)) then Exit;
    NameLen := L;
    SetLength(Result, L);
    for var I := 1 to L do
      Result[I] := Char(Buf[I]);
  end;

var
  VmtAddr, TypeInfoAddr: UInt64;
begin
  Result := nil;
  if ObjAddr = 0 then Exit;
  if not ReadTargetPointer(ObjAddr, VmtAddr) or (VmtAddr = 0) then Exit;
  if not ReadTargetPointer(OffsetTargetAddress(VmtAddr, TargetLayout.VmtTypeInfo),
       TypeInfoAddr) or (TypeInfoAddr = 0) then Exit;
  var Depth := 0;
  while (TypeInfoAddr <> 0) and (Depth < 64) do begin
    var NameLen: Byte;
    var Nm := ReadTypeName(TypeInfoAddr, NameLen);
    if Nm = '' then Break;
    Result := Result + [Nm];
    // TTypeData for a class is ClassType(ptr) then ParentInfo(PPTypeInfo), so
    // ParentInfo sits one TARGET pointer in. TypeData = TypeInfoAddr + 2 + NameLen.
    var ParentInfoPtr: UInt64;
    if not ReadTargetPointer(
         TypeInfoAddr + 2 + UInt64(NameLen) + TargetLayout.PointerSize,
         ParentInfoPtr) or (ParentInfoPtr = 0) then Break;
    var ParentTypeInfo: UInt64;
    if not ReadTargetPointer(ParentInfoPtr, ParentTypeInfo) then Break;
    TypeInfoAddr := ParentTypeInfo;
    Inc(Depth);
  end;
end;

// System.SysUtils.Exception declares `FMessage: string` as its first field, so
// it sits immediately after the VMT pointer -- offset 8 on Win64, 4 on Win32.
// The field holds a UnicodeString: a pointer to the char data, with the element
// count at [data-4]. The string HEADER is bitness-neutral (Delphi fixed it that
// way), so only the field offset and the handle's width follow the target.
function TWinDebugger.ReadDelphiExceptionMessage(ObjAddr: UInt64): string;
var
  StrPtr: UInt64;
  Len: Integer;
  Read: SIZE_T;
begin
  Result := '';
  if ObjAddr = 0 then Exit;
  if not ReadTargetPointer(ObjAddr + TargetLayout.PointerSize, StrPtr) or
     (StrPtr = 0) then Exit;
  if not ReadProcessMemory(FProcess, Pointer(StrPtr - 4), @Len, 4, Read) or
     (Read <> 4) then Exit;
  if (Len <= 0) or (Len > 4096) then Exit;
  SetLength(Result, Len);
  if not ReadProcessMemory(FProcess, Pointer(StrPtr), @Result[1],
       NativeUInt(Len) * SizeOf(Char), Read) then
    Result := '';
end;

procedure TWinDebugger.PlantInt3(var BP: TBreakpointRec);
begin
  if BP.IsPlanted then
    Exit;
  // Two breakpoints can legitimately resolve to ONE address: two source lines
  // mapping to the same code, or the same unit answering from two providers.
  // Planting twice would read the $CC the first one wrote and save THAT as the
  // original byte, so unplanting would restore a breakpoint instruction and
  // leave the target trapping forever at an address no breakpoint owns any more.
  // Adopt the first planter's original byte and skip the write.
  for var I := 0 to FBreakpoints.Count - 1 do
    if FBreakpoints[I].IsPlanted and (FBreakpoints[I].VA = BP.VA) then begin
      BP.OrigByte  := FBreakpoints[I].OrigByte;
      BP.IsPlanted := True;
      Exit;
    end;
  if not ReadByte(BP.VA, BP.OrigByte) then begin
    DapLog(Format('PlantInt3 FAIL ReadByte VA=$%x LastError=%d', [BP.VA, GetLastError]));
    Exit;
  end;
  if not WriteByte(BP.VA, $CC) then
    DapLog(Format('PlantInt3 FAIL WriteByte VA=$%x LastError=%d', [BP.VA, GetLastError]))
  else begin
    BP.IsPlanted := True;
    DapLog(Format('PlantInt3 OK VA=$%x OrigByte=$%x', [BP.VA, BP.OrigByte]));
  end;
end;

procedure TWinDebugger.RemoveInt3(var BP: TBreakpointRec);
begin
  if not BP.IsPlanted then
    Exit;
  WriteByte(BP.VA, BP.OrigByte);
  BP.IsPlanted := False;
end;

{ ---------------------------------------------------------------------------
  Thread-context funnel.

  Everything that reads or mutates a ROLE of the register file -- the program
  counter, the stack pointer, the trap flag -- goes through these three, rather
  than opening its own TContext. That is what makes a WOW64 variant one
  implementation instead of eleven: a 32-bit target needs Wow64GetThreadContext
  and a WOW64_CONTEXT whose fields have different names, and there is no reason
  for a caller that just wants "the program counter" to know that.

  Two categories deliberately stay outside the funnel because they are genuinely
  architecture-specific rather than role-based: seeding StackWalk64 (which wants
  the raw CONTEXT it will unwind) and RunMethodCall's argument marshalling
  (which is the calling convention itself).
  --------------------------------------------------------------------------- }

function TWinDebugger.ReadThreadRegisters(TID: DWORD;
  out Regs: TRegisterSnapshot): Boolean;
var
  Ctx: TContext;
  TH:  THandle;
begin
  Regs := Default(TRegisterSnapshot);
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(TH, Ctx) then
    Exit;
  Regs.Rip    := Ctx.Rip;
  Regs.Rsp    := Ctx.Rsp;
  Regs.Rbp    := Ctx.Rbp;
  Regs.Rax    := Ctx.Rax;
  Regs.Rbx    := Ctx.Rbx;
  Regs.Rcx    := Ctx.Rcx;
  Regs.Rdx    := Ctx.Rdx;
  Regs.Rsi    := Ctx.Rsi;
  Regs.Rdi    := Ctx.Rdi;
  Regs.R8     := Ctx.R8;
  Regs.R9     := Ctx.R9;
  Regs.R10    := Ctx.R10;
  Regs.R11    := Ctx.R11;
  Regs.R12    := Ctx.R12;
  Regs.R13    := Ctx.R13;
  Regs.R14    := Ctx.R14;
  Regs.R15    := Ctx.R15;
  Regs.EFlags := Ctx.EFlags;
  Regs.Valid  := True;
  Result := True;
end;

function TWinDebugger.SetThreadPc(TID: DWORD; VA: UInt64): Boolean;
var
  Ctx: TContext;
  TH:  THandle;
begin
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_CONTROL;
  if not GetThreadContext(TH, Ctx) then
    Exit;
  Ctx.Rip := VA;
  Result := SetThreadContext(TH, Ctx);
end;

function TWinDebugger.ReadDebugRegisters(TID: DWORD;
  out Regs: TDebugRegisters): Boolean;
var
  Ctx: TContext;
  TH:  THandle;
begin
  Regs := Default(TDebugRegisters);
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_DEBUG_REGISTERS;
  if not GetThreadContext(TH, Ctx) then
    Exit;
  Regs.Dr[0] := Ctx.Dr0;
  Regs.Dr[1] := Ctx.Dr1;
  Regs.Dr[2] := Ctx.Dr2;
  Regs.Dr[3] := Ctx.Dr3;
  Regs.Dr6   := Ctx.Dr6;
  Regs.Dr7   := Ctx.Dr7;
  Result := True;
end;

function TWinDebugger.WriteDebugRegisters(TID: DWORD;
  const Regs: TDebugRegisters): Boolean;
var
  Ctx: TContext;
  TH:  THandle;
begin
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_DEBUG_REGISTERS;
  if not GetThreadContext(TH, Ctx) then
    Exit;
  Ctx.Dr0 := Regs.Dr[0];
  Ctx.Dr1 := Regs.Dr[1];
  Ctx.Dr2 := Regs.Dr[2];
  Ctx.Dr3 := Regs.Dr[3];
  Ctx.Dr6 := Regs.Dr6;
  Ctx.Dr7 := Regs.Dr7;
  Result := SetThreadContext(TH, Ctx);
end;

function TWinDebugger.StackWalkMachineType: DWORD;
begin
  Result := IMAGE_FILE_MACHINE_AMD64;
end;

function TWinDebugger.RemoteCallTrap: UInt64;
begin
  Result := FRemoteCallTrap;
end;

// The "round N down to a multiple of 16" rule reflects the 8-byte alignment
// padding Delphi inserts at the top of the locals area when (1 + ExtraPushCount)
// is even. Empirically validated on procs with EP = 0 / 8 / 16; the earlier
// "N - ExtraPushBytes" formula worked only by coincidence when EP = 8.
function TWinDebugger.LocalsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer;
begin
  Result := Integer(SubRspN) - Integer(SubRspN mod 16);
end;

function TWinDebugger.ParamsOffsetBase(SubRspN, ExtraPushBytes: UInt32): Integer;
begin
  Result := Integer(SubRspN) + Integer(ExtraPushBytes);
end;

function TWinDebugger.FillStackWalkContext(TH: THandle; var Buf: TContext;
  out SeedPc, SeedSp, SeedFp: UInt64): Boolean;
begin
  SeedPc := 0;
  SeedSp := 0;
  SeedFp := 0;
  Buf := Default(TContext);
  Buf.ContextFlags := CONTEXT_FULL;
  Result := GetThreadContext(TH, Buf);
  if not Result then
    Exit;
  SeedPc := Buf.Rip;
  SeedSp := Buf.Rsp;
  SeedFp := Buf.Rbp;
end;

function TWinDebugger.SetThreadTrapFlag(TID: DWORD; Enable: Boolean): Boolean;
const
  TRAP_FLAG = DWORD($100);
var
  Ctx: TContext;
  TH:  THandle;
begin
  Result := False;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_CONTROL;
  if not GetThreadContext(TH, Ctx) then
    Exit;
  if Enable then
    Ctx.EFlags := Ctx.EFlags or TRAP_FLAG
  else
    Ctx.EFlags := Ctx.EFlags and (not TRAP_FLAG);
  Result := SetThreadContext(TH, Ctx);
end;

procedure TWinDebugger.SetTrapFlag(TID: DWORD; Enable: Boolean);
begin
  SetThreadTrapFlag(TID, Enable);
end;

procedure TWinDebugger.SetRIP(TID: DWORD; NewRIP: UInt64);
begin
  SetThreadPc(TID, NewRIP);
end;

{ ---------------------------------------------------------------------------
  Hardware watchpoints.

  DR7 lays every slot out the same way: a local-enable bit at 2*Slot, a 2-bit
  access type at 16 + 4*Slot, and a 2-bit length right above it. The bit maths
  is therefore architecture-neutral and lives here once; only the reading and
  writing of the register file differ per bitness, and that is already behind
  the thread-context funnel.
  --------------------------------------------------------------------------- }

// Pure register-file write for ONE thread. No allocator bookkeeping: callers
// decide separately what FWatchSlots should say once every thread they care
// about has been touched. Refusals, never roundings -- the hardware ignores
// the low bits of DRn, so a misaligned or odd-sized request would quietly
// watch a NEIGHBOURING cell and report success, the one failure mode a
// watchpoint must not have.
function TWinDebugger.ArmWatchRegistersOnThread(TID: DWORD; Slot: Integer;
  Address: UInt64; SizeBytes: Integer; WriteOnly: Boolean;
  out Reason: string): Boolean;

  function TryLengthEncoding(out Bits: UInt64): Boolean;
  begin
    Result := True;
    case SizeBytes of
      1: Bits := 0;
      2: Bits := 1;
      4: Bits := 3;
      8: Bits := 2;
    else
      Bits := 0;
      Result := False;
    end;
  end;

begin
  Reason := '';
  if (Slot < 0) or (Slot > 3) then begin
    Reason := 'slot must be 0..3 -- the hardware has exactly four';
    Exit(False);
  end;
  var LenBits: UInt64;
  if not TryLengthEncoding(LenBits) then begin
    Reason := 'size must be 1, 2, 4 or 8 bytes';
    Exit(False);
  end;
  if TargetLayout.PointerSize < 8 then begin
    if SizeBytes = 8 then begin
      Reason := 'an 8-byte watchpoint exists only in 64-bit mode';
      Exit(False);
    end;
    if Address > $FFFFFFFF then begin
      Reason := 'a 32-bit target has no such address';
      Exit(False);
    end;
  end;
  if (Address = 0) or ((Address mod UInt64(SizeBytes)) <> 0) then begin
    Reason := 'address must be non-zero and aligned to the watched size';
    Exit(False);
  end;

  var Regs: TDebugRegisters;
  if not ReadDebugRegisters(TID, Regs) then begin
    Reason := Format('the debug registers of thread %d are unreadable', [TID]);
    Exit(False);
  end;

  var RwBits: UInt64 := 1;    // 01 = break on write
  if not WriteOnly then
    RwBits := 3;              // 11 = break on read or write. There is no
                              // read-ONLY encoding on x86; saying so is the
                              // surface's job, not this one's.
  var FieldShift := 16 + 4 * Slot;
  Regs.Dr[Slot] := Address;
  Regs.Dr7 := Regs.Dr7 and not (UInt64($F) shl FieldShift);
  Regs.Dr7 := Regs.Dr7 or (RwBits shl FieldShift) or (LenBits shl (FieldShift + 2));
  Regs.Dr7 := Regs.Dr7 or (UInt64(1) shl (2 * Slot));
  Regs.Dr6 := 0;              // a stale B bit would name this slot at the very
                              // next trap, before the watchpoint ever fired

  if not WriteDebugRegisters(TID, Regs) then begin
    Reason := 'the thread context rejected the debug registers';
    Exit(False);
  end;

  var AccessName := 'read/write';
  if WriteOnly then
    AccessName := 'write';
  // Read back rather than trust the write: SetThreadContext can report success
  // and still leave a debug register untouched, and a watchpoint that was never
  // really armed looks exactly like a target that never wrote the cell.
  var Verify: TDebugRegisters;
  if ReadDebugRegisters(TID, Verify) then
    DapLog(Format('ArmWatchRegistersOnThread OK tid=%d slot=%d addr=$%x size=%d access=%s ' +
      '(readback DR%d=$%x DR7=$%x)',
      [TID, Slot, Address, SizeBytes, AccessName, Slot, Verify.Dr[Slot], Verify.Dr7]))
  else
    DapLog(Format('ArmWatchRegistersOnThread OK tid=%d slot=%d addr=$%x size=%d access=%s ' +
      '(readback unavailable)', [TID, Slot, Address, SizeBytes, AccessName]));
  Result := True;
end;

function TWinDebugger.DisarmWatchRegistersOnThread(TID: DWORD; Slot: Integer): Boolean;
begin
  Result := False;
  if (Slot < 0) or (Slot > 3) then
    Exit;
  var Regs: TDebugRegisters;
  if not ReadDebugRegisters(TID, Regs) then
    Exit;
  Regs.Dr[Slot] := 0;
  Regs.Dr7 := Regs.Dr7 and not (UInt64(3) shl (2 * Slot));        // local + global enable
  Regs.Dr7 := Regs.Dr7 and not (UInt64($F) shl (16 + 4 * Slot));  // access + length
  Regs.Dr6 := 0;
  Result := WriteDebugRegisters(TID, Regs);
  if Result then
    DapLog(Format('DisarmWatchRegistersOnThread OK tid=%d slot=%d', [TID, Slot]));
end;

procedure TWinDebugger.ClearWatchSlotOnAllThreads(Slot: Integer);
begin
  for var KV in FThreads do
    DisarmWatchRegistersOnThread(KV.Key, Slot);
end;

// Raw per-thread primitive: arms exactly the one thread named, and updates the
// allocator bookkeeping for that slot (Description is left whatever it already
// was -- '' the first time, so a bare probe/test call reads as "no owner").
// Direct single-thread control for probes and the increment-2 tests; a real
// watchpoint should go through SetDataWatchpoint instead, which replicates.
function TWinDebugger.ArmHardwareWatchpoint(TID: DWORD; Slot: Integer;
  Address: UInt64; SizeBytes: Integer; WriteOnly: Boolean): Boolean;
begin
  var Reason: string;
  Result := (Slot >= 0) and (Slot <= 3) and
    ArmWatchRegistersOnThread(TID, Slot, Address, SizeBytes, WriteOnly, Reason);
  if not Result then begin
    if Reason = '' then
      Reason := 'slot must be 0..3 -- the hardware has exactly four';
    DapLog(Format('ArmHardwareWatchpoint REFUSED tid=%d slot=%d addr=$%x size=%d: %s',
      [TID, Slot, Address, SizeBytes, Reason]));
    Exit;
  end;
  FWatchSlots[Slot].InUse     := True;
  FWatchSlots[Slot].Address   := Address;
  FWatchSlots[Slot].SizeBytes := SizeBytes;
  FWatchSlots[Slot].WriteOnly := WriteOnly;
  FWatchArmedSlots := FWatchArmedSlots or Byte(1 shl Slot);
end;

// Raw per-thread primitive: clears exactly the one thread named, and frees the
// slot's allocator bookkeeping. If the same slot is still physically armed on
// OTHER threads (only reachable by calling the raw primitives directly on
// several threads, never through the allocator) those registers are left as
// they are -- this is the single-thread primitive doing exactly what it says.
function TWinDebugger.DisarmHardwareWatchpoint(TID: DWORD; Slot: Integer): Boolean;
begin
  Result := (Slot >= 0) and (Slot <= 3) and DisarmWatchRegistersOnThread(TID, Slot);
  if not Result then
    Exit;
  FWatchSlots[Slot] := Default(TWatchSlotState);
  FWatchArmedSlots  := FWatchArmedSlots and not Byte(1 shl Slot);
end;

function TWinDebugger.HardwareWatchpointHitCount: Integer;
begin
  Result := FWatchHitCount;
end;

function TWinDebugger.LastHardwareWatchpointHit: TWatchpointHit;
begin
  Result := FLastWatchHit;
end;

// The allocator. Picks the first free slot, arms it on every live thread, and
// only THEN records it in FWatchSlots -- so a partial failure (one thread's
// registers refuse the write) is unwound on the threads already touched
// instead of leaving bookkeeping that claims success.
function TWinDebugger.SetDataWatchpoint(Address: UInt64; SizeBytes: Integer;
  WriteOnly: Boolean; const OwnerDescription: string; out Slot: Integer;
  out RefusalReason: string): Boolean;
begin
  Result := False;
  Slot   := -1;
  RefusalReason := '';

  var Free := -1;
  for var I := 0 to 3 do
    if not FWatchSlots[I].InUse then begin
      Free := I;
      Break;
    end;
  if Free < 0 then begin
    var Occupants := '';
    for var I := 0 to 3 do begin
      var Owner := FWatchSlots[I].Description;
      if Owner = '' then
        Owner := '(no description)';
      if Occupants <> '' then
        Occupants := Occupants + '; ';
      Occupants := Occupants + Format('slot %d: $%x %s', [I, FWatchSlots[I].Address, Owner]);
    end;
    RefusalReason := 'all four hardware data-breakpoint slots are in use -- ' + Occupants;
    Exit;
  end;

  var ArmedTids := TList<DWORD>.Create;
  try
    for var KV in FThreads do begin
      var Reason: string;
      if not ArmWatchRegistersOnThread(KV.Key, Free, Address, SizeBytes, WriteOnly, Reason) then begin
        for var Tid in ArmedTids do
          DisarmWatchRegistersOnThread(Tid, Free);
        RefusalReason := Format('thread %d refused the watchpoint: %s', [KV.Key, Reason]);
        Exit;
      end;
      ArmedTids.Add(KV.Key);
    end;
  finally
    ArmedTids.Free;
  end;

  FWatchSlots[Free].InUse       := True;
  FWatchSlots[Free].Address     := Address;
  FWatchSlots[Free].SizeBytes   := SizeBytes;
  FWatchSlots[Free].WriteOnly   := WriteOnly;
  FWatchSlots[Free].Description := OwnerDescription;
  FWatchSlots[Free].OldValue    := 0;
  ReadProcessMemoryAt(Address, @FWatchSlots[Free].OldValue, SizeBytes);
  FWatchArmedSlots := FWatchArmedSlots or Byte(1 shl Free);
  Slot   := Free;
  Result := True;
  DapLog(Format('SetDataWatchpoint OK slot=%d addr=$%x size=%d writeOnly=%s owner=%s ' +
    '(armed on %d thread(s))',
    [Free, Address, SizeBytes, BoolToStr(WriteOnly, True), OwnerDescription, FThreads.Count]));
end;

function TWinDebugger.ClearDataWatchpoint(Slot: Integer): Boolean;
begin
  Result := False;
  if (Slot < 0) or (Slot > 3) or (not FWatchSlots[Slot].InUse) then
    Exit;
  ClearWatchSlotOnAllThreads(Slot);
  FWatchSlots[Slot] := Default(TWatchSlotState);
  FWatchArmedSlots  := FWatchArmedSlots and not Byte(1 shl Slot);
  Result := True;
  DapLog(Format('ClearDataWatchpoint OK slot=%d', [Slot]));
end;

function TWinDebugger.TakeDebugTrapCause(TID: DWORD): TDebugTrapCause;
const
  DR6_SLOT_MASK = UInt64($F);      // B0..B3: which slot fired
  DR6_BS        = UInt64($4000);   // the trap flag caused this #DB
begin
  // Nothing armed: no slot of OURS can have fired, so leave the pump on exactly
  // the path it walked before watchpoints existed, and pay no context switch
  // for a feature that is not in use. Stepping is single-step-heavy.
  Result.FiredSlots   := 0;
  Result.TrapFlagStep := True;
  if FWatchArmedSlots = 0 then
    Exit;

  var Regs: TDebugRegisters;
  if not ReadDebugRegisters(TID, Regs) then
    Exit;

  // DR6 reads back with its reserved bits SET ($FFFF4FF0 for a step, $FFFF0FF1
  // for a slot-0 hit, measured on both bitnesses), so it must be masked field by
  // field -- never compared whole, never tested for "non-zero".
  Result.FiredSlots   := Byte(Regs.Dr6 and DR6_SLOT_MASK) and FWatchArmedSlots;
  Result.TrapFlagStep := (Regs.Dr6 and DR6_BS) <> 0;

  // Clearing is not optional. The CPU never clears DR6 by itself, so leaving it
  // would make the NEXT trap on this thread carry these bits, and every step
  // after this one would look like a watchpoint hit.
  Regs.Dr6 := 0;
  WriteDebugRegisters(TID, Regs);
end;

procedure TWinDebugger.RecordWatchpointHit(TID: DWORD; FiredSlots: Byte;
  Pc: UInt64);
begin
  var Lowest := 0;
  while (Lowest < 3) and ((FiredSlots and Byte(1 shl Lowest)) = 0) do
    Inc(Lowest);
  Inc(FWatchHitCount);
  FLastWatchHit.ThreadId    := TID;
  FLastWatchHit.Slot        := Lowest;
  FLastWatchHit.FiredSlots  := FiredSlots;
  FLastWatchHit.Address     := FWatchSlots[Lowest].Address;
  FLastWatchHit.Pc          := Pc;
  FLastWatchHit.SizeBytes   := FWatchSlots[Lowest].SizeBytes;
  FLastWatchHit.Description := FWatchSlots[Lowest].Description;
  // "old" is whatever "new" was at the previous hit (or at arm time, for the
  // first one); "new" is read now, AFTER the store the trap reports completed.
  FLastWatchHit.OldValue := FWatchSlots[Lowest].OldValue;
  var NewVal: UInt64 := 0;
  ReadProcessMemoryAt(FWatchSlots[Lowest].Address, @NewVal, FWatchSlots[Lowest].SizeBytes);
  FLastWatchHit.NewValue     := NewVal;
  FWatchSlots[Lowest].OldValue := NewVal;
  DapLog(Format('watchpoint HIT tid=%d slot=%d slots=$%x addr=$%x pc=$%x old=$%x new=$%x (hit %d)',
    [TID, Lowest, FiredSlots, FWatchSlots[Lowest].Address, Pc,
     FLastWatchHit.OldValue, FLastWatchHit.NewValue, FWatchHitCount]));
end;

function TWinDebugger.SetInstructionPointer(VA: UInt64): Boolean;
begin
  Result := (FStoppedTid <> 0) and SetThreadPc(FStoppedTid, VA);
end;

function TWinDebugger.CurrentRIP(TID: DWORD): UInt64;
var
  Regs: TRegisterSnapshot;
begin
  if ReadThreadRegisters(TID, Regs) then
    Result := Regs.Pc
  else
    Result := 0;
end;

function TWinDebugger.CurrentRSP(TID: DWORD): UInt64;
var
  Regs: TRegisterSnapshot;
begin
  if ReadThreadRegisters(TID, Regs) then
    Result := Regs.StackPtr
  else
    Result := 0;
end;

// Plant a one-shot step BP at VA and track it in FStepBpVAs. Skips VAs already
// covered by an existing (e.g. user) breakpoint: that BP fires on its own and
// the smOver handler treats the hit as the step landing.
procedure TWinDebugger.PlantStepBp(VA: UInt64);
begin
  if (VA = 0) or (FindBreakpointByVA(VA) >= 0) then Exit;
  var BP := Default(TBreakpointRec);
  BP.VA        := VA;
  BP.IsOneShot := True;
  PlantInt3(BP);
  FBreakpoints.Add(BP);
  FStepBpVAs := FStepBpVAs + [VA];
end;

procedure TWinDebugger.RearmStepBpAfterForeignHit(BpVA: UInt64; Tid: DWORD);
begin
  // The hit handler already deleted the one-shot record and restored the byte.
  // Put the record back UNPLANTED and let the re-arm path plant it after one
  // trap step, exactly as a persistent breakpoint is re-armed -- planting it
  // here would re-trap immediately on the very instruction the thread is
  // parked on and never make progress.
  if FindBreakpointByVA(BpVA) < 0 then begin
    var BP := Default(TBreakpointRec);
    BP.VA        := BpVA;
    BP.IsOneShot := True;
    BP.IsPlanted := False;
    FBreakpoints.Add(BP);
  end;
  var AlreadyTracked := False;
  for var VA in FStepBpVAs do
    if VA = BpVA then begin
      AlreadyTracked := True;
      Break;
    end;
  if not AlreadyTracked then
    FStepBpVAs := FStepBpVAs + [BpVA];

  FPendingReactivateVA := BpVA;
  FReactivateTid       := Tid;
  FSteppingOffStepBp   := True;
  SetTrapFlag(Tid, True);
end;

// Remove every still-planted step BP. Called when a step-over completes or is
// interrupted by another stop, so the transient INT3s never leak.
procedure TWinDebugger.ClearStepBps;
begin
  for var VA in FStepBpVAs do begin
    var Idx := FindBreakpointByVA(VA);
    if Idx < 0 then Continue;
    var BP := FBreakpoints[Idx];
    if BP.IsPlanted then RemoveInt3(BP);
    FBreakpoints.Delete(Idx);
  end;
  SetLength(FStepBpVAs, 0);
end;

// True when Rva belongs to the function currently being stepped over. Uses the
// function's start RVA (looked up via .pdata/TD32 proc ranges) rather than a
// stored [start,end) so a recursive self-call -- which re-enters the same
// start -- is recognised as the same function and handled as a call.
function TWinDebugger.RvaInStepFunc(Rva: UInt64): Boolean;
begin
  var FuncStart: UInt64;
  Result := FDebugInfo.RvaToFunctionStart(Rva, FuncStart) and
            (FuncStart = FStepFuncStart);
end;

// True when Rva maps to a source line different from where the step-over began.
// Used both on each single-step and when a stepped-over call returns: if the
// call was the last instruction on its line, the return address is already the
// next line and we must stop THERE -- not single-step its first instruction,
// which may be another call we would then step over, skipping the line.
function TWinDebugger.StepOverAtNewLine(Rva: UInt64): Boolean;
var
  Loc: TSourceLocation;
begin
  Result := FDebugInfo.RvaToSourceLine(Rva, Loc) and
            (not FStepHasFromLoc or
             not SameText(Loc.SourceFile, FStepFromLoc.SourceFile) or
             (Loc.Line <> FStepFromLoc.Line));
end;

// Decide a single range-based step-over move from the instruction about to
// execute at PcVA. Either reports the landing, plants a run-to-return BP, or
// arms the trap flag for the next single-step. Called both on each single-step
// and right after a persistent-BP re-arm consumed the step that entered a
// callee -- evaluating AT the callee entry, where [RSP] is still the return
// address (a later step is past the prologue push and [RSP] is corrupted).
procedure TWinDebugger.HandleSmOverStep(Tid: DWORD; PcVA: UInt64);
begin
  Inc(FStepSafetyCount);
  var CurRva := VAToRva(PcVA);
  var CurSP  := CurrentRSP(Tid);

  // In-function progress, not the entry RVA (a re-entry at the entry means a
  // recursive self-call, handled as a call below). Stop on a new source line.
  if RvaInStepFunc(CurRva) and (CurRva <> FStepFuncStart) then begin
    if StepOverAtNewLine(CurRva) or (FStepSafetyCount >= 200000) then begin
      FStepMode := smNone;
      ReportStopped(srStep, PcVA);
      Exit;
    end;
    FStepPrevSP := CurSP;
    SetTrapFlag(Tid, True);
    ContinueDebugEvent(FProcessId, Tid, DBG_CONTINUE);
    Exit;
  end;

  // Left the function (or re-entered its entry). RSP dropped across the
  // crossing instruction => a CALL just pushed a return address that points
  // back into the function: run full-speed to it, then resume single-stepping.
  if CurSP < FStepPrevSP then begin
    // The pushed return address is ONE TARGET POINTER wide. Reading 8 bytes on a
    // 32-bit target splices the next stack word into the high half: observed in
    // the field as a run-to-return breakpoint planted at $5196C430B5AA25BC (low
    // half the real return address, high half an unrelated rtl290 address), which
    // failed to plant and let the step-over run free.
    var RetTop: UInt64 := 0;
    if ReadTargetPointer(CurSP, RetTop) and (RetTop <> 0) then begin
      FStepResumeVA := RetTop;
      // CurSP is the SP just after the CALL pushed the return address; the
      // matching RET pops exactly that pointer, so the stepped frame resumes at
      // CurSP + PointerSize. A hit below that is a deeper recursive incarnation
      // returning to the same site.
      {$Q-}
      FStepResumeSP := CurSP + UInt64(TargetLayout.PointerSize);
      {$Q+}
      PlantStepBp(RetTop);
      ContinueDebugEvent(FProcessId, Tid, DBG_CONTINUE);
      Exit;
    end;
  end;

  // Returned to the caller (or no usable return address): stop here.
  FStepMode := smNone;
  ReportStopped(srStep, PcVA);
end;

{ ---------------- instruction granularity (docs/ASSEMBLY_LEVEL_DEBUGGING.md #1) --- }

// The mnemonic Zydis's Intel formatter printed, lowercased. Classifying by the
// decoder's OWN text is the same discipline ZydisDisassembler already uses for
// direct-branch annotation: this unit never re-derives from raw bytes what the
// decoder was asked to produce. `syscall` / `sysenter` are single tokens and so
// cannot be mistaken for `call`.
function FirstMnemonicToken(const Text: string): string;
begin
  Result := LowerCase(Trim(Text));
  var SpaceAt := Pos(' ', Result);
  if SpaceAt > 0 then
    Result := Copy(Result, 1, SpaceAt - 1);
end;

// A `rep`-family prefix, which Zydis prints as its own leading token. THE new
// hazard of instruction stepping: such an instruction traps once per ITERATION,
// so a trap-flag step retires one iteration and leaves the PC exactly where it
// was. Stepped that way a `rep movsb` over a large block produces thousands of
// stops and reads as a hang, so it is completed as a whole -- one-shot at
// PC + length -- by BOTH step-into and step-over. A string move has no callee,
// so nothing is lost by not entering it.
function MnemonicIsRepPrefix(const Mnemonic: string): Boolean;
begin
  for var Prefix in ['rep', 'repe', 'repz', 'repne', 'repnz'] do
    if Mnemonic = Prefix then
      Exit(True);
  Result := False;
end;

function TWinDebugger.InstructionDisassembler: IDisassembler;
begin
  if FInstrDisasm = nil then begin
    var Mode: TDisasmMachineMode;
    if TargetLayout.PointerSize = 8 then
      Mode := dmmLong64
    else
      Mode := dmmLegacy32;
    // ReadCodeMemoryAt, never ReadProcessMemoryAt: it restores the debugger's
    // OWN planted INT3 bytes, so an instruction carrying a breakpoint decodes as
    // the user's opcode rather than as `int3`, and it truncates at the end of a
    // committed region instead of failing the whole read.
    var Reader: TDisasmByteReader :=
      function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
      begin
        Result := Integer(ReadCodeMemoryAt(VA, Buf, NativeUInt(Size)));
      end;
    FInstrDisasm := TZydisDisassembler.Create(Mode, Reader, nil, 0,
      ResolveZydisDllPathForThisExe);
  end;
  Result := FInstrDisasm;
end;

procedure TWinDebugger.SetInstructionDisassembler(const Disasm: IDisassembler);
begin
  FInstrDisasm := Disasm;
end;

function TWinDebugger.BuildInstructionStepPlan(Kind: TInstructionStepKind;
  Tid: DWORD; out Plan: TInstrStepPlan; out RefusalReason: string): Boolean;

  function Refuse(const Reason: string): Boolean;
  begin
    RefusalReason := Reason;
    Result        := False;
  end;

begin
  Plan          := Default(TInstrStepPlan);
  Plan.Kind     := Kind;
  RefusalReason := '';

  var Regs: TRegisterSnapshot;
  if not ReadThreadRegisters(Tid, Regs) or not Regs.Valid then
    Exit(Refuse(Format('the register context of thread %d could not be read', [Tid])));

  // Every kind requires the backend, including step-out, which decodes nothing
  // itself: a surface where two of three kinds refuse and the third silently
  // works is a worse contract than one sentence. There is no fallback decoder
  // anywhere in this project and instruction lengths are never guessed.
  var Disasm := InstructionDisassembler;
  if (Disasm = nil) or not Disasm.Available then begin
    var Status := 'no disassembler backend is configured';
    if Disasm <> nil then
      Status := Disasm.StatusText;
    Exit(Refuse('instruction stepping needs the disassembler backend: ' + Status));
  end;

  if Kind = iskOut then begin
    // .pdata on x64, [EBP+4] on x86 -- CallerReturnAddress is already that seam.
    var Ret := CallerReturnAddress(Tid);
    if not IsPlausibleReturnAddress(Ret) then
      Exit(Refuse(Format('no return address can be proven for the frame at $%x ' +
        '(no unwind data and no usable frame pointer): instruction step-out ' +
        'refuses rather than running to a plausible-looking address', [Regs.Pc])));
    Plan.UseTrapFlag := False;
    Plan.ResumeVA    := Ret;
    // The matching RET pops at least one target pointer, so a hit at or below
    // the current stack pointer belongs to a deeper incarnation of a recursive
    // callee returning to the very same site.
    {$Q-}
    Plan.MinResumeSP := Regs.StackPtr + UInt64(TargetLayout.PointerSize);
    {$Q+}
    Exit(True);
  end;

  var Insns := Disasm.Disassemble(Regs.Pc, 1);
  if (Length(Insns) = 0) or (not Insns[0].Decoded) or (Insns[0].Length <= 0) then
    Exit(Refuse(Format('the bytes at $%x do not decode as an instruction, so its ' +
      'length is unknown; refusing to guess one', [Regs.Pc])));

  var Mnemonic := FirstMnemonicToken(Insns[0].Text);
  var MustRunPastIt := MnemonicIsRepPrefix(Mnemonic) or
                       ((Mnemonic = 'call') and (Kind = iskOver));
  if not MustRunPastIt then begin
    Plan.UseTrapFlag := True;
    Exit(True);
  end;

  // Exact, because the decoder just produced the length -- which makes this
  // MORE reliable than the source-level step-over's return-address arithmetic,
  // not less.
  {$Q-}
  Plan.ResumeVA := Regs.Pc + UInt64(Insns[0].Length);
  {$Q+}
  if not AddressIsExecutable(Plan.ResumeVA) then
    Exit(Refuse(Format('the address after the instruction at $%x ($%x) is not ' +
      'executable memory; refusing to plant a breakpoint there',
      [Regs.Pc, Plan.ResumeVA])));
  Plan.UseTrapFlag := False;
  // A call+ret nets to no stack change, and a rep touches the stack not at all,
  // so the landing must be at the SAME stack pointer this step started from.
  Plan.MinResumeSP := Regs.StackPtr;
  Result := True;
end;

function TWinDebugger.StepInstruction(Kind: TInstructionStepKind;
  ThreadId: DWORD; out RefusalReason: string): Boolean;
begin
  RefusalReason := '';
  Result        := False;
  if (FProcess = 0) or FHasExited then begin
    RefusalReason := 'there is no live debuggee to step';
    Exit;
  end;
  if not FIsStopped then begin
    RefusalReason := 'the debuggee is running; instruction stepping needs a stop';
    Exit;
  end;
  var Tid := ThreadId;
  if Tid = 0 then
    Tid := FStoppedTid;
  if (Tid = 0) or not FThreads.ContainsKey(Tid) then begin
    RefusalReason := Format('thread %d is not a live thread of the debuggee', [Tid]);
    Exit;
  end;

  // On x86 a stack walk does not survive a still-planted breakpoint (docs/TRAPS.md),
  // and step-out takes one. At a breakpoint stop the byte is already restored
  // and the PC already rewound by the hit handler; this covers the remaining
  // case -- a step that LANDED on an address carrying a persistent breakpoint --
  // and is the same call the step command itself makes on the Run thread.
  var PcBpIdx := FindBreakpointByVA(CurrentRIP(Tid));
  if (PcBpIdx >= 0) and FBreakpoints[PcBpIdx].IsPlanted and
     (not FBreakpoints[PcBpIdx].IsOneShot) then
    UnpatchBpAtRip(Tid);

  var Plan: TInstrStepPlan;
  if not BuildInstructionStepPlan(Kind, Tid, Plan, RefusalReason) then begin
    DapLog('StepInstruction REFUSED: ' + RefusalReason);
    Exit;
  end;

  var Cmd := Default(TCommand);
  Cmd.Kind      := ckStepInstruction;
  Cmd.ThreadId  := Tid;
  Cmd.InstrStep := Plan;
  PostCommand(Cmd);
  Result := True;
end;

procedure TWinDebugger.DoStepInstruction(const Cmd: TCommand);
begin
  var Tid := Cmd.ThreadId;
  if Tid = 0 then
    Tid := FStoppedTid;
  FIsStopped             := False;
  FPendingContinueStatus := DBG_CONTINUE;
  UnpatchBpAtRip(Tid);
  FreezeThreadsForStep(Tid);
  ClearStepBps;

  FStepMode          := smInstr;
  FInstrStepKind     := Cmd.InstrStep.Kind;
  FInstrStepTid      := Tid;
  FInstrStepTrapFlag := Cmd.InstrStep.UseTrapFlag;
  FStepOverVA        := Cmd.InstrStep.ResumeVA;
  FStepResumeSP      := Cmd.InstrStep.MinResumeSP;
  FStepResumeVA      := 0;
  FStepRaiseArmed    := False;
  FStepSafetyCount   := 0;
  FStepMinSP         := 0;
  FStepHasFromLoc    := False;

  if FInstrStepTrapFlag then
    SetTrapFlag(Tid, True)
  else
    // Thread-scoped by construction: every other thread is frozen for the
    // duration, and InstrStepLandedAt re-checks both the thread and the stack
    // pointer, so a recursive callee reaching the same address one frame deeper
    // cannot end the step early.
    PlantStepBp(Cmd.InstrStep.ResumeVA);

  DapLog(Format('StepInstruction: kind=%d tid=%d trapFlag=%s resumeVA=$%x minSP=$%x',
    [Ord(FInstrStepKind), Tid, BoolToStr(FInstrStepTrapFlag, True),
     FStepOverVA, FStepResumeSP]));
  ReleasePendingEvent(DBG_CONTINUE);
end;

function TWinDebugger.InstrStepLandedAt(BpVA: UInt64; Tid: DWORD): Boolean;
begin
  Result := False;
  if (FStepMode <> smInstr) or FInstrStepTrapFlag then
    Exit;
  if (BpVA = 0) or (BpVA <> FStepOverVA) or (Tid <> FInstrStepTid) then
    Exit;
  // A deeper recursive incarnation returns to the SAME address at a LOWER stack
  // pointer. Reported there, the step lands on the right instruction in the
  // wrong frame and every local belongs to another recursion level.
  if (FStepResumeSP <> 0) and (CurrentRSP(Tid) < FStepResumeSP) then
    Exit;
  Result := True;
end;

procedure TWinDebugger.EndInstructionStep;
begin
  ClearStepBps;
  FStepMode          := smNone;
  FStepOverVA        := 0;
  FStepResumeSP      := 0;
  FInstrStepTid      := 0;
  FInstrStepTrapFlag := False;
end;

{ ---------------------------------------- stepping at an exception stop ---- }

function TWinDebugger.DescribeUserCodeAt(VA: UInt64; out Where: string): Boolean;
var
  Loc: TSourceLocation;
begin
  Where  := '';
  Result := False;
  if (VA = 0) or (FDebugInfo = nil) then
    Exit;
  var Rva := VAToRva(VA);
  if not FDebugInfo.RvaToSourceLine(Rva, Loc) then
    Exit;
  if Loc.Line <= 0 then
    Exit;
  var FuncName := '';
  FDebugInfo.RvaToFunctionName(Rva, FuncName);
  if FuncName <> '' then
    Where := Format('%s (%s:%d)', [FuncName, ExtractFileName(Loc.SourceFile), Loc.Line])
  else
    Where := Format('%s:%d', [ExtractFileName(Loc.SourceFile), Loc.Line]);
  Result := True;
end;

function TWinDebugger.FunctionNameAt(VA: UInt64): string;
begin
  Result := '';
  if (VA = 0) or (FDebugInfo = nil) then
    Exit;
  if not FDebugInfo.RvaToFunctionName(VAToRva(VA), Result) then
    Result := '';
end;

// x64. The handler address is derivable EXACTLY here, and the layout is
// documented in docs/EH_FORMAT_NOTES.md: RUNTIME_FUNCTION (dbghelp's own .pdata
// lookup) -> UNWIND_INFO -> language handler -> Delphi's MSVC-shaped scope
// table -> per-entry finally funclet / bare except block / `on` clause table.
//
// Two rules from that document are load-bearing and are enforced below rather
// than assumed:
//   * the scope table is decoded ONLY when the language handler really is
//     Delphi's _DelphiExceptionHandler. Under MSVC's __C_specific_handler the
//     same field is a FILTER FUNCTION and the decode yields confident nonsense;
//   * a breakpoint is planted only on a decoded BLOCK address, never on a
//     scope entry's Handler field -- when that field is a clause-table RVA an
//     $CC written there overwrites the clause COUNT and derails dispatch.
function TWinDebugger.PlanExceptionStep(Tid: DWORD;
  out Plan: TExceptionStepPlan; out RefusalReason: string): Boolean;
const
  MAX_FRAMES          = 30;
  UNW_FLAG_EHANDLER   = $01;
  UNW_FLAG_UHANDLER   = $02;
  UNW_FLAG_CHAININFO  = $04;
  MAX_CHAIN_DEPTH     = 4;
  MAX_SCOPE_ENTRIES   = 256;
  MAX_CLAUSES         = 64;
type
  // What one frame turned out to be. `fvPassThrough` is the common case: the
  // routine declares no handler covering its PC, so the exception cannot stop
  // there and the walk continues. `fvOpaque` is a frame that CAN receive it but
  // whose landing we cannot prove -- the walk stops and the step refuses.
  TFrameVerdict = (fvPassThrough, fvHandles, fvOpaque);
var
  Blocks:   TArray<UInt64>;
  Describe: string;
  Why:      string;

  function ReadU32At(VA: UInt64; out Value: UInt32): Boolean;
  begin
    Value  := 0;
    Result := ReadProcessMemoryAt(VA, @Value, SizeOf(Value));
  end;

  procedure NoteBlock(VA: UInt64; const Kind, Where: string);
  begin
    for var Existing in Blocks do
      if Existing = VA then
        Exit;
    Blocks := Blocks + [VA];
    if Describe = '' then
      Describe := Format('%s in %s', [Kind, Where])
    else
      Describe := Describe + Format(', %s in %s', [Kind, Where]);
  end;

  // DWORD Count; Count x { DWORD ClassVmtRva; DWORD BlockRva }. Every clause's
  // block is planted, not just the matching one: only the matching clause ever
  // executes, so letting the first hit win is exact, while re-deriving Delphi's
  // class matching (ancestors, re-raise, interfaces) here would be a second
  // implementation of it -- and a wrong match plants in a block that never runs,
  // which reads as a step that hung.
  function DecodeClauseTable(ModBase: UInt64; TableRva: UInt32): Boolean;
  begin
    Result := False;
    var Count: UInt32;
    if not ReadU32At(ModBase + TableRva, Count) then
      Exit;
    if (Count = 0) or (Count > MAX_CLAUSES) then
      Exit;
    for var I := 0 to Integer(Count) - 1 do begin
      var Pair: array[0..1] of UInt32;
      if not ReadProcessMemoryAt(ModBase + TableRva + 4 + UInt64(I) * 8,
               @Pair[0], SizeOf(Pair)) then
        Exit;
      var Where: string;
      if not DescribeUserCodeAt(ModBase + Pair[1], Where) then
        Exit;
      NoteBlock(ModBase + Pair[1], 'except', Where);
      Result := True;
    end;
  end;

  // The entries of ONE function's scope table that cover FrameRva. More than one
  // covers it when the routine nests a try inside another try; every covering
  // entry's block is planted and the innermost simply gets there first, so no
  // assumption about the table's ordering is needed.
  function DecodeScopeTable(ModBase: UInt64; TableRva: UInt32;
    FuncBeginRva, FuncEndRva, FrameRva: UInt32): TFrameVerdict;
  begin
    var Count: UInt32;
    if not ReadU32At(ModBase + TableRva, Count) then
      Exit(fvOpaque);
    if (Count = 0) or (Count > MAX_SCOPE_ENTRIES) then begin
      Why := Format('its Delphi scope table at $%x declares an implausible entry ' +
        'count (%d)', [ModBase + TableRva, Count]);
      Exit(fvOpaque);
    end;
    Result := fvPassThrough;
    for var I := 0 to Integer(Count) - 1 do begin
      var E: array[0..3] of UInt32;    // Begin, End, Handler, Target
      if not ReadProcessMemoryAt(ModBase + TableRva + 4 + UInt64(I) * 16,
               @E[0], SizeOf(E)) then begin
        Why := Format('entry %d of its Delphi scope table at $%x could not be read',
          [I, ModBase + TableRva]);
        Exit(fvOpaque);
      end;
      // A protected range must lie inside the function the unwind info belongs
      // to. Anything else means this is not the table shape we think it is.
      if (E[0] >= E[1]) or (E[0] < FuncBeginRva) or (E[1] > FuncEndRva) then begin
        Why := Format('entry %d of its Delphi scope table at $%x is not a protected ' +
          'range inside the routine ($%x..$%x)',
          [I, ModBase + TableRva, E[0], E[1]]);
        Exit(fvOpaque);
      end;
      if (FrameRva < E[0]) or (FrameRva >= E[1]) then
        Continue;
      var Where: string;
      if E[2] = 0 then begin
        // try/finally: Target is the finally funclet.
        if not DescribeUserCodeAt(ModBase + E[3], Where) then begin
          Why := Format('the finally funclet its scope table names ($%x) does not map ' +
            'to a source line', [ModBase + E[3]]);
          Exit(fvOpaque);
        end;
        NoteBlock(ModBase + E[3], 'finally', Where);
        Result := fvHandles;
      end
      else if E[2] <= 2 then begin
        // A bare `except` with no `on` clause: Handler is a flag, not an RVA,
        // and Target is the block itself.
        if not DescribeUserCodeAt(ModBase + E[3], Where) then begin
          Why := Format('the except block its scope table names ($%x) does not map ' +
            'to a source line', [ModBase + E[3]]);
          Exit(fvOpaque);
        end;
        NoteBlock(ModBase + E[3], 'except', Where);
        Result := fvHandles;
      end
      else begin
        if not DecodeClauseTable(ModBase, E[2]) then begin
          Why := Format('the `on`-clause table its scope table names ($%x) does not ' +
            'decode into block addresses that map to source lines', [ModBase + E[2]]);
          Exit(fvOpaque);
        end;
        // Some entries carry BOTH a clause table and a Target block.
        if (E[3] <> 0) and DescribeUserCodeAt(ModBase + E[3], Where) then
          NoteBlock(ModBase + E[3], 'except', Where);
        Result := fvHandles;
      end;
    end;
  end;

  function DecodeUnwindInfo(ModBase: UInt64; UnwindRva, FuncBeginRva,
    FuncEndRva, FrameRva: UInt32; Depth: Integer): TFrameVerdict;
  begin
    if Depth > MAX_CHAIN_DEPTH then begin
      Why := 'its UNWIND_INFO chain is deeper than this debugger follows';
      Exit(fvOpaque);
    end;
    var Hdr: array[0..3] of Byte;
    if not ReadProcessMemoryAt(ModBase + UnwindRva, @Hdr[0], SizeOf(Hdr)) then begin
      Why := Format('its UNWIND_INFO at $%x could not be read', [ModBase + UnwindRva]);
      Exit(fvOpaque);
    end;
    var Version := Hdr[0] and 7;
    if (Version <> 1) and (Version <> 2) then begin
      Why := Format('its UNWIND_INFO at $%x declares version %d, which this debugger ' +
        'does not decode', [ModBase + UnwindRva, Version]);
      Exit(fvOpaque);
    end;
    var Flags := Hdr[0] shr 3;
    // The UNWIND_CODE array is padded to an EVEN number of 2-byte slots; the
    // handler RVA and its data follow it.
    var Slots   := (Integer(Hdr[2]) + 1) and not 1;
    var TailRva := UnwindRva + 4 + UInt32(Slots) * 2;

    if (Flags and (UNW_FLAG_EHANDLER or UNW_FLAG_UHANDLER)) <> 0 then begin
      var HandlerRva: UInt32;
      if not ReadU32At(ModBase + TailRva, HandlerRva) then begin
        Why := 'its language-handler RVA could not be read';
        Exit(fvOpaque);
      end;
      var HandlerName := '';
      if FDebugInfo <> nil then
        FDebugInfo.RvaToFunctionName(VAToRva(ModBase + HandlerRva), HandlerName);
      if not ContainsText(HandlerName, 'DelphiExceptionHandler') then begin
        var Named := HandlerName;
        if Named = '' then
          Named := 'an unnamed routine';
        Why := Format('its language handler at $%x is %s, not Delphi''s ' +
          '_DelphiExceptionHandler, so the data after it is not a Delphi scope ' +
          'table and decoding it would produce a confident wrong answer',
          [ModBase + HandlerRva, Named]);
        Exit(fvOpaque);
      end;
      Exit(DecodeScopeTable(ModBase, TailRva + 4, FuncBeginRva, FuncEndRva, FrameRva));
    end;

    if (Flags and UNW_FLAG_CHAININFO) <> 0 then begin
      var Chained: TRuntimeFunctionEntry;
      if not ReadProcessMemoryAt(ModBase + TailRva, @Chained, SizeOf(Chained)) then begin
        Why := 'its chained RUNTIME_FUNCTION could not be read';
        Exit(fvOpaque);
      end;
      Exit(DecodeUnwindInfo(ModBase, Chained.UnwindInfoAddress,
        Chained.BeginAddress, Chained.EndAddress, FrameRva, Depth + 1));
    end;

    // No handler and no chain: this routine cannot receive the exception.
    Result := fvPassThrough;
  end;

begin
  Plan          := Default(TExceptionStepPlan);
  Plan.ThreadId := Tid;
  RefusalReason := '';
  Blocks        := nil;
  Describe      := '';
  Why           := '';

  var TH := ThreadHandle(Tid);
  if TH = 0 then begin
    RefusalReason := Format('thread %d could not be opened, so its stack cannot be ' +
      'walked to find the handler this exception will reach', [Tid]);
    Exit(False);
  end;
  EnsureSymInitialized;
  var Ctx: TContext;
  var SeedPc, SeedSp, SeedFp: UInt64;
  if not FillStackWalkContext(TH, Ctx, SeedPc, SeedSp, SeedFp) then begin
    RefusalReason := Format('the register context of thread %d could not be read, ' +
      'so its stack cannot be walked to find the handler this exception will reach',
      [Tid]);
    Exit(False);
  end;

  var Walked := 0;
  for var Raw in WalkRawFrames(TH, SeedPc, SeedSp, SeedFp, MAX_FRAMES) do begin
    if Raw.PC = 0 then
      Break;
    Inc(Walked);
    // A frame with no source line is never a landing site: the step exists to
    // put the user in their own source, and an OS / RTL frame has none. Its own
    // handler (typically MSVC's __C_specific_handler in ntdll or kernelbase) is
    // therefore skipped rather than refused on -- refusing there would make the
    // whole feature unreachable, since a Delphi raise always passes through
    // kernelbase!RaiseException.
    var FrameWhere: string;
    if not DescribeUserCodeAt(Raw.PC, FrameWhere) then
      Continue;
    var RF: PRuntimeFunctionEntry := SymFunctionTableAccess64(FProcess, Raw.PC);
    if RF = nil then
      Continue;
    var ModBase: UInt64 := SymGetModuleBase64(FProcess, Raw.PC);
    if ModBase = 0 then
      Continue;

    Why := '';
    // For frames above 0 the walker's PC is the RETURN address, which is the
    // address the protected range has to cover -- the call it is about to
    // return into is what sits inside the try.
    var Verdict := DecodeUnwindInfo(ModBase, RF.UnwindInfoAddress,
      RF.BeginAddress, RF.EndAddress, UInt32(Raw.PC - ModBase), 0);

    if Verdict = fvPassThrough then
      Continue;

    if Verdict = fvOpaque then begin
      if Why = '' then
        Why := 'its exception-handling data could not be decoded';
      RefusalReason := Format(
        'a step at an exception stop runs to the handler that receives it. The first ' +
        'frame that can receive this one -- %s at $%x -- cannot be decoded: %s. ' +
        'Refusing rather than delivering the exception and guessing where it lands.',
        [FrameWhere, Raw.PC, Why]);
      Exit(False);
    end;

    Plan.HandlerVAs  := Blocks;
    Plan.Description := Describe;
    Exit(True);
  end;

  if Walked = 0 then
    RefusalReason := Format('the stack of thread %d could not be walked, so the ' +
      'handler this exception will reach cannot be found', [Tid])
  else
    RefusalReason := Format('no frame on the stack of thread %d protects the code ' +
      'this exception came from, so there is no except or finally block to step to. ' +
      'Continue instead: the exception is unhandled and the program''s own default ' +
      'handling will run.', [Tid]);
  Result := False;
end;

function TWinDebugger.StoppedOnUndeliveredException: Boolean;
begin
  Result := FIsStopped and (FPendingContinueStatus = DWORD(DBG_EXCEPTION_NOT_HANDLED));
end;

function TWinDebugger.LastStepNote: string;
begin
  Result := FLastStepNote;
end;

function TWinDebugger.StepToExceptionHandler(ThreadId: DWORD;
  out RefusalReason: string): Boolean;
begin
  RefusalReason := '';
  Result        := False;
  if (FProcess = 0) or FHasExited then begin
    RefusalReason := 'there is no live debuggee to step';
    Exit;
  end;
  if not FIsStopped then begin
    RefusalReason := 'the debuggee is running; stepping needs a stop';
    Exit;
  end;
  if not StoppedOnUndeliveredException then begin
    RefusalReason := 'the debuggee is not stopped on an undelivered exception';
    Exit;
  end;
  var Tid := ThreadId;
  if Tid = 0 then
    Tid := FStoppedTid;
  // The exception belongs to the thread that raised it, and only that thread's
  // stack has a handler for it. Stepping "another thread" at an exception stop
  // is not a thing that exists, so honour the request only when it names the
  // faulting thread.
  if (Tid <> 0) and (Tid <> FStoppedTid) then begin
    RefusalReason := Format('the debuggee is stopped on an exception raised by thread ' +
      '%d; a step at an exception stop follows THAT exception to its handler and ' +
      'cannot be targeted at thread %d', [FStoppedTid, Tid]);
    Exit;
  end;
  Tid := FStoppedTid;

  var Plan: TExceptionStepPlan;
  if not PlanExceptionStep(Tid, Plan, RefusalReason) then begin
    DapLog('StepToExceptionHandler REFUSED: ' + RefusalReason);
    Exit;
  end;
  if Length(Plan.HandlerVAs) = 0 then begin
    RefusalReason := 'no handler block address could be proven for this exception';
    DapLog('StepToExceptionHandler REFUSED: ' + RefusalReason);
    Exit;
  end;

  var Cmd := Default(TCommand);
  Cmd.Kind     := ckStepToHandler;
  Cmd.ThreadId := Tid;
  Cmd.ExcStep  := Plan;
  PostCommand(Cmd);
  Result := True;
end;

procedure TWinDebugger.DoStepToHandler(const Cmd: TCommand);
begin
  var Tid := Cmd.ThreadId;
  if Tid = 0 then
    Tid := FStoppedTid;
  FIsStopped := False;
  UnpatchBpAtRip(Tid);
  ClearStepBps;

  FStepMode        := smToHandler;
  FExcStepVAs      := Cmd.ExcStep.HandlerVAs;
  FExcStepTid      := Tid;
  FExcStepFromVA   := FLastExceptionAddr;
  FExcStepFromCode := FLastExceptionCode;
  FExcStepDesc     := Cmd.ExcStep.Description;
  FStepOverVA      := 0;
  FStepResumeVA    := 0;
  FStepResumeSP    := 0;
  FStepRaiseArmed  := False;
  FStepSafetyCount := 0;
  FStepMinSP       := 0;
  FStepHasFromLoc  := False;
  FLastStepNote    := '';

  for var VA in Cmd.ExcStep.HandlerVAs do
    PlantStepBp(VA);

  // Deliberately NOT FreezeThreadsForStep. Everything else this engine steps is
  // a handful of instructions; this one runs the OS's exception dispatch and
  // Delphi's unwind, which take the memory manager's locks. Freezing a thread
  // that holds one turns a step into a process-wide deadlock. The landing is
  // kept thread-scoped by ExcStepLandedAt instead, which is the same guard the
  // recursion cases already use.
  DapLog(Format('StepToExceptionHandler: tid=%d blocks=%d landing=%s',
    [Tid, Length(Cmd.ExcStep.HandlerVAs), FExcStepDesc]));
  // The whole mechanism: the exception has to be DELIVERED for the handler to
  // run at all. Resuming with DBG_CONTINUE swallows it and re-executes the
  // faulting instruction, which is the defect this step exists to fix.
  FPendingContinueStatus := DBG_CONTINUE;
  ReleasePendingEvent(DBG_EXCEPTION_NOT_HANDLED);
end;

function TWinDebugger.ExcStepBlock(BpVA: UInt64): Boolean;
begin
  Result := False;
  if (FStepMode <> smToHandler) or (BpVA = 0) then
    Exit;
  for var VA in FExcStepVAs do
    if VA = BpVA then
      Exit(True);
end;

function TWinDebugger.ExcStepLandedAt(BpVA: UInt64; Tid: DWORD): Boolean;
begin
  Result := ExcStepBlock(BpVA) and (Tid = FExcStepTid);
end;

procedure TWinDebugger.EndExceptionStep;
begin
  ClearStepBps;
  FStepMode        := smNone;
  FExcStepVAs      := nil;
  FExcStepTid      := 0;
  FExcStepFromVA   := 0;
  FExcStepFromCode := 0;
  FExcStepDesc     := '';
end;

// Plant a one-shot BP at every source line of the function currently being
// stepped over. Used only when a raise unwinds during a step-over: control
// re-enters the function at its except/finally handler -- not at the call's
// return address -- so the run-to-return resume BP would never fire. Binary-
// searches the sorted line RVAs to the function's start, then scans forward
// within a generous window (no real function exceeds it), so the cost is the
// function's own line count, never the whole program's.
procedure TWinDebugger.PlantInFuncStepBps;
const
  FUNC_MAX_SPAN = $40000; // 256 KB of code; larger than any real function
begin
  var Rvas := FDebugInfo.SortedRvas;
  if Length(Rvas) = 0 then
    Exit;
  var Lo := 0;
  var Hi := Length(Rvas);
  while Lo < Hi do begin
    var Mid := (Lo + Hi) div 2;
    if Rvas[Mid] < FStepFuncStart then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  for var I := Lo to High(Rvas) do begin
    if Rvas[I] >= FStepFuncStart + FUNC_MAX_SPAN then
      Break;
    if RvaInStepFunc(Rvas[I]) then
      PlantStepBp(RvaToVA(Rvas[I]));
  end;
end;

// dbghelp is initialised once per process, on first use. fInvadeProcess=True
// enumerates every module mapped AT THAT MOMENT -- which includes the main exe,
// for which the debug loop never receives a LOAD_DLL event. Modules mapped later
// are registered one at a time (RegisterModuleWithDbgHelp).
procedure TWinDebugger.EnsureSymInitialized;
begin
  if FSymInitialized or (FProcess = 0) then
    Exit;
  SymSetOptions(SymGetOptions or SYMOPT_FAIL_CRITICAL_ERRORS);
  SymInitialize(FProcess, nil, True);
  FSymInitialized := True;
end;

// Tell dbghelp about a module that was mapped after it was initialised. Without
// this, SymFunctionTableAccess64 returns nil for every address inside the module,
// so StackWalk64 has no .pdata unwind info and silently falls back to the AMD64
// leaf convention (return address := [RSP]). Just past a Delphi prologue
// (push rbp; sub rsp,N; mov rbp,rsp) RSP equals RBP, so [RSP] is an uninitialised
// local: the walk then truncates the call stack to a single frame and step-out
// (which unwinds through the same code path) loses its caller.
procedure TWinDebugger.RegisterModuleWithDbgHelp(const Path: string;
  Base, ImageSize: UInt64);
begin
  if Base = 0 then
    Exit;
  // Only modules loaded AFTER initialisation need this: the fInvadeProcess sweep
  // that EnsureSymInitialized still performs covers everything mapped before it.
  if not FSymInitialized then
    Exit;
  var ImageName: PWideChar := nil;
  if Path <> '' then
    ImageName := PWideChar(Path);
  SetLastError(ERROR_SUCCESS);
  if (SymLoadModuleExW(FProcess, 0, ImageName, nil, Base, DWORD(ImageSize),
      nil, 0) = 0) and (GetLastError <> ERROR_SUCCESS) then
    DapLog(Format('SymLoadModuleEx failed for %s base=$%x err=%d',
      [Path, Base, GetLastError]));
end;

// SizeOfImage out of the PE header of an image already mapped in the debuggee.
// 0 when it cannot be read, which callers must treat as "extent unknown" rather
// than "empty".
function TWinDebugger.ReadImageSizeOf(Base: UInt64): UInt64;
var
  R: NativeUInt;
begin
  Result := 0;
  if (FProcess = 0) or (Base = 0) then
    Exit;
  var E_lfanew: DWORD := 0;
  if not (ReadProcessMemory(FProcess, Pointer(Base + $3C), @E_lfanew, 4, R) and (R = 4)) then
    Exit;
  var SizeOfImage: DWORD := 0;
  if ReadProcessMemory(FProcess, Pointer(Base + E_lfanew + $50), @SizeOfImage, 4, R) and (R = 4) then
    Result := SizeOfImage;
end;

// Does VA fall inside a module the OS actually told us about?
//
// This used to ask dbghelp (SymGetModuleBase64), and on a WOW64 target that is
// wrong: measured on Hydra2, the kernel32 return address $75925D49 -- a real
// frame, in a module the debugger itself had logged as loaded -- got module
// base 0 from dbghelp and was refused, which truncated the stack at the last
// Delphi frame. dbghelp's module list is whatever its invade sweep and our
// SymLoadModuleEx calls managed to register; OURS is built directly from the
// CREATE_PROCESS / LOAD_DLL debug events, so it is complete by construction.
//
// dbghelp is still consulted last, for the case where a module IS ours but its
// SizeOfImage could not be read, so nothing is lost relative to the old test.
function TWinDebugger.AddressInLoadedModule(VA: UInt64): Boolean;

  function InRange(Base, Size: UInt64): Boolean;
  begin
    Result := (Base <> 0) and (Size <> 0) and (VA >= Base) and (VA < Base + Size);
  end;

begin
  if VA = 0 then
    Exit(False);
  if InRange(FImageBase, FImageSize) then
    Exit(True);
  for var KV in FDllBases do begin
    var Size: UInt64 := 0;
    if FDllSizes.TryGetValue(KV.Key, Size) and InRange(KV.Value, Size) then
      Exit(True);
  end;
  EnsureSymInitialized;
  Result := SymGetModuleBase64(FProcess, VA) <> 0;
end;

function TWinDebugger.CallSiteVerdictAt(VA: UInt64): TCallSiteAnswer;
begin
  Result := csaUndecidable;
end;

// Fills the source/function/entry fields for a code address. Shared by the
// walked stack and the raw sweep so the two cannot drift into disagreeing about
// what an address is called.
//
// AtReturnAddress shifts the lookup back one byte. A RETURN address is the
// instruction AFTER the call, so looking it up directly reports the line
// FOLLOWING the call site -- an `Assert` call reads as the next statement. The
// live PC of frame 0 is not a return address and must not be shifted.
procedure TWinDebugger.SymbolicateAddress(VA: UInt64; AtReturnAddress: Boolean;
  var Frame: TStackFrame);
var
  Loc: TSourceLocation;
begin
  Frame.IP          := VA;
  Frame.SourceFile  := '';
  Frame.SourceLine  := 0;
  Frame.FunctionName := '';
  Frame.FuncEntryVA := 0;
  if FDebugInfo = nil then
    Exit;
  var LookupRva := VAToRva(VA);
  if AtReturnAddress and (LookupRva > 0) then
    Dec(LookupRva);
  if FDebugInfo.RvaToSourceLine(LookupRva, Loc) then begin
    Frame.SourceFile := Loc.SourceFile;
    Frame.SourceLine := Loc.Line;
  end;
  if not FDebugInfo.RvaToFunctionName(LookupRva, Frame.FunctionName) then
    Frame.FunctionName := '';
  var FuncRva: UInt64 := 0;
  if FDebugInfo.RvaToFunctionStart(LookupRva, FuncRva) then
    Frame.FuncEntryVA := RvaToVA(FuncRva);
  if Frame.FunctionName = '' then
    NameFromModuleExports(VA, AtReturnAddress, Frame);
end;

procedure TWinDebugger.NameFromModuleExports(VA: UInt64;
  AtReturnAddress: Boolean; var Frame: TStackFrame);
// No debug-info provider owns this address, which is the normal state of
// affairs for ntdll, kernel32 and any third-party DLL built without debug
// info. Its export directory still says where each exported routine starts, so
// the frame can be named `module!Routine+$offset` instead of being left blank
// for the UI to render as a bare address.
//
// The `!` is deliberate and is not cosmetic: it marks a name that came from an
// export table rather than from debug info. An export tells us where a routine
// STARTS, nothing more -- a static function between two exports is attributed
// to the export before it, so the offset can be large and the name can be the
// wrong routine. A reader has to be able to tell the two kinds of answer apart.
begin
  var Lookup := VA;
  if AtReturnAddress and (Lookup > 0) then
    Dec(Lookup);
  var Name: string;
  var Offset, EntryVA: UInt64;
  if not ExportedSymbolAt(Lookup, Name, Offset, EntryVA) then
    Exit;
  var ModuleName := '';
  var ModBase, ModSize: UInt64;
  if ModuleRangeFor(Lookup, ModBase, ModSize) then
    ModuleName := ModuleNameForBase(ModBase);
  if ModuleName <> '' then
    Frame.FunctionName := ModuleName + '!' + Name
  else
    Frame.FunctionName := Name;
  if Offset > 0 then
    Frame.FunctionName := Frame.FunctionName + Format('+$%x', [Offset]);
  Frame.FuncEntryVA := EntryVA;
end;

function TWinDebugger.ResymbolicateFrames(
  const Frames: TArray<TStackFrame>): TArray<TStackFrame>;
begin
  SetLength(Result, Length(Frames));
  for var I := 0 to High(Frames) do begin
    Result[I] := Frames[I];
    // Frame 0 of a WALKED stack is the live PC; every other frame, and every
    // raw hit including the first, is a return address. Origin says which.
    SymbolicateAddress(Frames[I].IP,
      {AtReturnAddress=}(I > 0) or (Frames[I].Origin in [foRawProven, foRawUnproven]),
      Result[I]);
  end;
end;

function TWinDebugger.GetRawStackFrames(TID: DWORD;
  MaxItems: Integer): TArray<TStackFrame>;
begin
  SetLength(Result, 0);
  EnsureSymInitialized;
  for var Cand in RawStackCandidates(TID, MaxItems) do begin
    var Frame := Default(TStackFrame);
    // Every candidate IS a return address by construction -- that is what the
    // sweep looked for -- so the call-site shift always applies here.
    SymbolicateAddress(Cand.PC, {AtReturnAddress=}True, Frame);
    // No frame pointer: these are addresses, not frames. Leaving it 0 is what
    // stops anything downstream from trying to read locals off them.
    Frame.FrameRBP := 0;
    if Cand.Proven then
      Frame.Origin := foRawProven
    else
      Frame.Origin := foRawUnproven;
    Result := Result + [Frame];
  end;
end;

// Brute-force sweep of a thread's stack for words that could be return
// addresses -- the "raw" mode a Delphi user knows from JCL / madExcept.
//
// WHY it exists, given that the walker is exact: the exact walk STOPS. On i386
// there is no unwind data, so when the chain runs into a routine built without
// a frame pointer there is nothing left to follow, and the frames BELOW that
// point -- which is where the user's own code usually is -- are simply not
// reported. Truncating is the right answer for a call stack. It is the wrong
// answer to the question "which of my routines is underneath this".
//
// WHAT is different from the JCL version: JCL accepts a word if it points at
// executable memory, which any function pointer, VMT slot or dead frame
// satisfies. Here every candidate is put to the DECODER: `Proven` means the
// instruction ending at that address was decoded and IS a call. For the user's
// own modules a line table supplies the boundary to decode from, so their code
// -- the part they care about -- gets proven answers rather than guesses.
// Foreign code with no line table stays undecidable and is reported as such
// rather than dropped, because dropping it loses the shape of the chain.
//
// WHAT REMAINS UNKNOWABLE: liveness. A return address left behind by a call
// that has already returned still sits in the frame that has been popped, and
// still decodes as call-adjacent. Nothing distinguishes it from a live one
// without the frame chain that is missing by assumption. So this reports where
// return addresses ARE, and callers must present that as a different kind of
// claim from a walked frame.
function TWinDebugger.RawStackCandidates(TID: DWORD;
  MaxItems: Integer): TArray<TRawStackCandidate>;
const
  // A thread stack is 1 MB by default and can be larger; beyond this the sweep
  // stops rather than spend unbounded time. Reported through DapLog when hit,
  // because a silently shortened sweep looks exactly like an exhaustive one.
  MAX_SCAN_BYTES = 4 * 1024 * 1024;
  CHUNK_BYTES    = 64 * 1024;
type
  TModuleRange = record Base, Limit: UInt64; end;
var
  // Module ranges, snapshotted once and kept SORTED. The per-word test runs
  // millions of times over a deep stack, so it must not walk a dictionary: the
  // binary search below is what keeps the sweep from being the slowest thing
  // the debugger does.
  Ranges: TArray<TModuleRange>;
  // Page protection costs a syscall per query, so remember the region that
  // last answered: code sections are large, and consecutive candidates land in
  // the same one almost every time.
  CacheBase, CacheLimit: UInt64;
  CacheExec: Boolean;

  // Insertion keeps Ranges ordered without pulling in a sorter; a process has
  // tens of modules, and this runs once per sweep.
  procedure AddRange(Base, Size: UInt64);
  begin
    if (Base = 0) or (Size = 0) then
      Exit;
    var R: TModuleRange;
    R.Base  := Base;
    R.Limit := Base + Size;
    var At := Length(Ranges);
    SetLength(Ranges, At + 1);
    while (At > 0) and (Ranges[At - 1].Base > R.Base) do begin
      Ranges[At] := Ranges[At - 1];
      Dec(At);
    end;
    Ranges[At] := R;
  end;

  function InAnyModule(VA: UInt64): Boolean;
  begin
    var Lo := 0;
    var Hi := High(Ranges);
    while Lo <= Hi do begin
      var Mid := (Lo + Hi) div 2;
      if VA < Ranges[Mid].Base then
        Hi := Mid - 1
      else if VA >= Ranges[Mid].Limit then
        Lo := Mid + 1
      else
        Exit(True);
    end;
    Result := False;
  end;

  function IsExecutable(VA: UInt64): Boolean;
  begin
    if (CacheLimit > CacheBase) and (VA >= CacheBase) and (VA < CacheLimit) then
      Exit(CacheExec);
    var M := Default(MEMORY_BASIC_INFORMATION);
    if VirtualQueryEx(FProcess, Pointer(VA), M, SizeOf(M)) <> SizeOf(M) then
      Exit(False);
    CacheBase  := UInt64(M.BaseAddress);
    CacheLimit := CacheBase + M.RegionSize;
    var Prot := M.Protect and not (PAGE_GUARD or PAGE_NOCACHE);
    CacheExec  := (M.State = MEM_COMMIT) and
                  ((Prot = PAGE_EXECUTE) or (Prot = PAGE_EXECUTE_READ) or
                   (Prot = PAGE_EXECUTE_READWRITE) or (Prot = PAGE_EXECUTE_WRITECOPY));
    Result := CacheExec;
  end;

  // The stack's extent, taken from the target's own memory map rather than
  // assumed: one reserved allocation, of which the committed part is the live
  // stack. Walking regions upward while the allocation base holds finds the top
  // exactly, and needs no TEB -- whose 32-bit copy is awkward to reach from a
  // 64-bit debugger.
  function StackExtent(SP, PtrSize: UInt64; out Lo, Hi: UInt64): Boolean;
  begin
    Lo := SP - (SP mod PtrSize);
    Hi := 0;
    var Mbi := Default(MEMORY_BASIC_INFORMATION);
    if VirtualQueryEx(FProcess, Pointer(Lo), Mbi, SizeOf(Mbi)) <> SizeOf(Mbi) then
      Exit(False);
    var StackAlloc := UInt64(Mbi.AllocationBase);
    Hi := UInt64(Mbi.BaseAddress) + Mbi.RegionSize;
    for var Step := 1 to 4096 do begin
      if VirtualQueryEx(FProcess, Pointer(Hi), Mbi, SizeOf(Mbi)) <> SizeOf(Mbi) then
        Break;
      if UInt64(Mbi.AllocationBase) <> StackAlloc then
        Break;
      Hi := UInt64(Mbi.BaseAddress) + Mbi.RegionSize;
    end;
    Result := Hi > Lo;
  end;

begin
  SetLength(Result, 0);
  SetLength(Ranges, 0);
  CacheBase  := 0;
  CacheLimit := 0;
  CacheExec  := False;
  if FProcess = 0 then
    Exit;
  var TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  var Ctx: TContext;
  var SeedPc, SeedSp, SeedFp: UInt64;
  if not FillStackWalkContext(TH, Ctx, SeedPc, SeedSp, SeedFp) then
    Exit;
  if SeedSp = 0 then
    Exit;

  var PtrSize := UInt64(TargetLayout.PointerSize);
  var ScanLo, ScanHi: UInt64;
  if not StackExtent(SeedSp, PtrSize, ScanLo, ScanHi) then
    Exit;
  if ScanHi - ScanLo > MAX_SCAN_BYTES then begin
    DapLog(Format('RawStackCandidates(TID=%d): stack $%x..$%x is %d bytes; ' +
      'sweeping the first %d only',
      [TID, ScanLo, ScanHi, ScanHi - ScanLo, MAX_SCAN_BYTES]));
    ScanHi := ScanLo + MAX_SCAN_BYTES;
  end;

  AddRange(FImageBase, FImageSize);
  for var KV in FDllBases do begin
    var Size: UInt64 := 0;
    if FDllSizes.TryGetValue(KV.Key, Size) then
      AddRange(KV.Value, Size);
  end;
  if Length(Ranges) = 0 then
    Exit;

  // A sweep reads megabytes and decodes thousands of candidates. Saying how
  // long it took and how much it looked at is what turns "the UI paused" into a
  // number, and this is the one operation in the engine whose cost scales with
  // the debuggee's stack rather than with anything the user did.
  var StartedAt := GetTickCount64;
  var Buf: TBytes;
  SetLength(Buf, CHUNK_BYTES);
  var At := ScanLo;
  while At < ScanHi do begin
    var Want := ScanHi - At;
    if Want > CHUNK_BYTES then
      Want := CHUNK_BYTES;
    // A read that fails is a hole in the committed stack, not the end of it:
    // skip the chunk and carry on rather than truncate the sweep.
    if not ReadProcessMemoryAt(At, @Buf[0], Want) then begin
      Inc(At, CHUNK_BYTES);
      Continue;
    end;
    var Slot: UInt64 := 0;
    while Slot + PtrSize <= Want do begin
      var VA: UInt64;
      if PtrSize = 4 then
        VA := PUInt32(@Buf[Slot])^
      else
        VA := PUInt64(@Buf[Slot])^;
      if (VA >= 65536) and InAnyModule(VA) and IsExecutable(VA) then begin
        var Verdict := CallSiteVerdictAt(VA);
        // csaNo is the only rejection. csaUndecidable is kept and reported as
        // unproven: dropping it would lose every frame in code with no line
        // table, which is most of the chain this mode exists to see through.
        if Verdict <> csaNo then begin
          var Cand: TRawStackCandidate;
          Cand.StackAddr := At + Slot;
          Cand.PC        := VA;
          Cand.Proven    := Verdict = csaYes;
          Result := Result + [Cand];
          if (MaxItems > 0) and (Length(Result) >= MaxItems) then begin
            DapLog(Format('RawStackCandidates(TID=%d): stopped at the %d-item ' +
              'cap after %d ms', [TID, MaxItems, GetTickCount64 - StartedAt]));
            Exit;
          end;
        end;
      end;
      Inc(Slot, PtrSize);
    end;
    Inc(At, Want);
  end;
  DapLog(Format('RawStackCandidates(TID=%d): swept $%x..$%x (%d KB), %d hit(s), %d ms',
    [TID, ScanLo, ScanHi, (ScanHi - ScanLo) div 1024, Length(Result),
     GetTickCount64 - StartedAt]));
end;

function TWinDebugger.IsPlausibleReturnAddress(VA: UInt64): Boolean;
begin
  if VA = 0 then
    Exit(False);
  if not AddressInLoadedModule(VA) then
    Exit(False);
  Result := AddressIsExecutable(VA);
end;

// Returns the RIP that the current frame will return to, by unwinding one
// frame with StackWalk64. This honours the function's prologue (saved
// registers, frame size from .pdata) and is correct anywhere inside the
// callee, unlike a naive read of [RSP] which only works at function entry
// before the prologue moves RSP.
function TWinDebugger.CallerReturnAddress(TID: DWORD): UInt64;
var
  TH:  THandle;
  Ctx: TContext;
  SF:  TDbgStackFrame64;
begin
  Result := 0;
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  var SeedPc, SeedSp, SeedFp: UInt64;
  if not FillStackWalkContext(TH, Ctx, SeedPc, SeedSp, SeedFp) then
    Exit;
  EnsureSymInitialized;

  SF := Default(TDbgStackFrame64);
  SF.AddrPC.Offset    := SeedPc;
  SF.AddrPC.Mode      := AddrModeFlat;
  SF.AddrFrame.Offset := SeedFp;
  SF.AddrFrame.Mode   := AddrModeFlat;
  SF.AddrStack.Offset := SeedSp;
  SF.AddrStack.Mode   := AddrModeFlat;

  // Consume the current frame.
  if not StackWalk64(StackWalkMachineType, FProcess, TH, SF, @Ctx,
      nil, @SymFunctionTableAccess64, @SymGetModuleBase64, nil) then
    Exit;
  // Caller frame: AddrPC.Offset is the RIP we'll return to.
  if not StackWalk64(StackWalkMachineType, FProcess, TH, SF, @Ctx,
      nil, @SymFunctionTableAccess64, @SymGetModuleBase64, nil) then
    Exit;
  Result := SF.AddrPC.Offset;
end;

procedure TWinDebugger.ApplyAllBreakpoints;
begin
  for var I := 0 to FBreakpoints.Count - 1 do begin
    if FBreakpoints[I].IsPlanted then
      Continue;
    var BP := FBreakpoints[I];
    // Recompute VA now that FImageBase is guaranteed to be set
    if BP.Rva > 0 then
      BP.VA := RvaToVA(BP.Rva);
    PlantInt3(BP);
    FBreakpoints[I] := BP;
  end;
end;

procedure TWinDebugger.ClearBreakpointsByFile(const SourceFile: string);
var
  Upper: string;
  I: Integer;
begin
  Upper := UpperCase(ExtractFileName(SourceFile));
  I := 0;
  while I < FBreakpoints.Count do begin
    if UpperCase(ExtractFileName(FBreakpoints[I].SourceFile)) = Upper then begin
      var BP := FBreakpoints[I];
      RemoveInt3(BP);
      FBreakpoints.Delete(I);
    end else
      Inc(I);
  end;
end;

// A breakpoint on a routine's `begin` line resolves to the routine's ENTRY
// address, where the prologue has not yet spilled Self or any by-register
// parameter. Every local read there returns the CALLER's frame bytes -- typed
// correctly, flagged as nothing. Reported from the field: a breakpoint on the
// `begin` of a constructor showed `Self` as an unrelated class and an
// uninitialised local as a plausible-looking number.
//
// Move such a breakpoint to the first address inside the routine whose line
// record differs from the entry's. That is the same boundary
// FunctionBodyStartVA derives for the step-into pivot, but taken from the line
// table alone: this runs before the image base is known and, on a 32-bit target,
// there is no `.pdata` for that function to consult at all.
//
// A routine whose body shares the entry's line record (one-liner, or a
// frameless `asm` body) has no such address. Then the entry IS the answer and
// the RVA is returned unchanged, rather than guessing past the prologue.
function TWinDebugger.BreakpointBodyRva(Rva: UInt64): UInt64;
const
  PREAMBLE_SCAN_LIMIT = 4096;
var
  EntryLoc: TSourceLocation;
begin
  Result := Rva;
  var FuncStart: UInt64;
  if not FDebugInfo.RvaToFunctionStart(Rva, FuncStart) then
    Exit;
  // Already on a statement: the user picked a real line, leave it alone.
  if Rva <> FuncStart then
    Exit;
  if not FDebugInfo.RvaToSourceLine(Rva, EntryLoc) then
    Exit;
  for var Scan := Rva + 1 to Rva + PREAMBLE_SCAN_LIMIT do begin
    var ScanFuncStart: UInt64;
    if not FDebugInfo.RvaToFunctionStart(Scan, ScanFuncStart) or
       (ScanFuncStart <> FuncStart) then
      Exit;   // ran out of the routine without finding a new line record
    var Loc: TSourceLocation;
    if not FDebugInfo.RvaToSourceLine(Scan, Loc) then
      Continue;
    if (Loc.Line <> EntryLoc.Line) or
       not SameText(Loc.SourceFile, EntryLoc.SourceFile) then
      Exit(Scan);
  end;
end;

procedure TWinDebugger.DoSetBreakpoints(const Spec: TBpSpec);

  function NthOrEmpty(const Arr: TArray<string>; Idx: Integer): string;
  begin
    if (Idx >= 0) and (Idx < Length(Arr)) then Result := Arr[Idx] else Result := '';
  end;

begin
  ClearBreakpointsByFile(Spec.SourceFile);
  for var I := 0 to High(Spec.Lines) do begin
    var Line := Spec.Lines[I];
    // Plant at EVERY address this (file, line) resolves to, not just the first
    // provider's. Line keys are basename-based, so in a multi-module target two
    // files sharing a basename -- or one unit linked into both the host exe and a
    // package -- both answer; taking the first hit bound the breakpoint to the
    // WRONG module's copy while still reporting it verified, so it either never
    // fired or stopped in the other file while the UI highlighted the user's.
    for var Candidate in FDebugInfo.SourceLineToRvaCandidates(Spec.SourceFile, Line) do begin
      var Rva := BreakpointBodyRva(Candidate);
      var BP: TBreakpointRec;
      BP.Rva          := Rva;
      BP.VA           := RvaToVA(Rva);  // may be wrong if FImageBase not yet known
      BP.OrigByte     := 0;
      BP.SourceFile   := ExtractFileName(Spec.SourceFile);
      BP.SourceLine   := Line;
      BP.IsOneShot    := False;
      BP.IsPlanted    := False;
      BP.Condition    := NthOrEmpty(Spec.Conditions,    I);
      BP.HitCondition := NthOrEmpty(Spec.HitConditions, I);
      BP.LogMessage   := NthOrEmpty(Spec.LogMessages,   I);
      BP.HitCount     := 0;
      BP.Kind         := bkSource;
      BP.ModuleName   := '';
      // Before the startup break, ApplyAllBreakpoints will plant it (after
      // FImageBase is set), so we just register the spec here.
      // After startup, FImageBase is known and VA is correct -- plant immediately.
      if FFirstBreak then
        PlantInt3(BP);
      FBreakpoints.Add(BP);
    end;
  end;
end;

procedure TWinDebugger.ClearAddressBreakpointsByModule(const ModuleName: string);
var
  I: Integer;
begin
  I := 0;
  while I < FBreakpoints.Count do begin
    if (FBreakpoints[I].Kind = bkAddress) and
       SameText(FBreakpoints[I].ModuleName, ModuleName) then begin
      var BP := FBreakpoints[I];
      if BP.IsPlanted then
        RemoveInt3(BP);
      FBreakpoints.Delete(I);
    end else
      Inc(I);
  end;
end;

// Counterpart of DoSetBreakpoints for address breakpoints. Identity is
// (ModuleName), not SourceFile -- a repost REPLACES every address breakpoint
// previously registered for this module, mirroring ClearBreakpointsByFile.
//
// Unlike a source breakpoint, an address breakpoint is NEVER registered
// unresolved: the caller (TDebugSession.SetAddressBreakpoint) only ever
// attributes an address to a module that is ALREADY loaded, so by the time a
// spec reaches here the module's live base is knowable NOW or the spec is
// stale (the module has since unloaded) -- either way there is no "wait for
// FImageBase" case like DoSetBreakpoints has for the pre-startup exe. A
// module that cannot be resolved (unloaded, or never loaded under this
// name) means the whole spec is dropped after the clear: nothing is
// planted, and no half-resolved placeholder is kept in FBreakpoints
// (docs/DISASSEMBLY_PLAN.md, "Address breakpoints" -- "do NOT plant").
procedure TWinDebugger.DoSetAddressBreakpoints(const Spec: TAddrBpSpec);

  function NthOrEmpty(const Arr: TArray<string>; Idx: Integer): string;
  begin
    if (Idx >= 0) and (Idx < Length(Arr)) then Result := Arr[Idx] else Result := '';
  end;

  function TryResolveModuleBase(out ModBase: UInt64): Boolean;
  begin
    if Spec.ModuleName = '' then begin
      ModBase := FImageBase;
      Result  := FImageBase <> 0;
    end else
      Result := FDllBases.TryGetValue(LowerCase(Spec.ModuleName), ModBase);
  end;

begin
  ClearAddressBreakpointsByModule(Spec.ModuleName);
  var ModBase: UInt64;
  if not TryResolveModuleBase(ModBase) then
    Exit;
  for var I := 0 to High(Spec.Rvas) do begin
    var BP: TBreakpointRec;
    BP.Rva          := Spec.Rvas[I];
    BP.VA           := ModBase + Spec.Rvas[I];
    BP.OrigByte     := 0;
    BP.SourceFile   := '';
    BP.SourceLine   := 0;
    BP.IsOneShot    := False;
    BP.IsPlanted    := False;
    BP.Condition    := NthOrEmpty(Spec.Conditions,    I);
    BP.HitCondition := NthOrEmpty(Spec.HitConditions, I);
    BP.LogMessage   := NthOrEmpty(Spec.LogMessages,   I);
    BP.HitCount     := 0;
    BP.Kind         := bkAddress;
    BP.ModuleName   := Spec.ModuleName;
    PlantInt3(BP);
    FBreakpoints.Add(BP);
  end;
end;

procedure TWinDebugger.PostCommand(const Cmd: TCommand);
begin
  EnterCriticalSection(FQueueLock);
  try
    FCommandQueue.Enqueue(Cmd);
  finally
    LeaveCriticalSection(FQueueLock);
  end;
end;

procedure TWinDebugger.DrainBreakpointCommands;
// Processes ONLY ckSetBreakpoints commands currently queued, planting
// their int3 bytes synchronously. Other command kinds (continue / step)
// are preserved in order. Called from the LOAD_DLL handler so a
// breakpoint that resolves into a freshly-loaded module is physically
// planted BEFORE the debuggee resumes -- otherwise the module's
// initialization code (e.g. a BPL unit's `initialization` section) can
// run past the breakpoint location before the int3 is written, and the
// BP is silently missed. This race surfaced with a second runtime-loaded
// BPL whose init ran immediately on LoadPackage.
var
  Pending: TArray<TCommand>;
begin
  EnterCriticalSection(FQueueLock);
  try
    SetLength(Pending, 0);
    while FCommandQueue.Count > 0 do
      Pending := Pending + [FCommandQueue.Dequeue];
    // Plant breakpoints now; re-enqueue everything else in original order.
    for var C in Pending do
      if C.Kind = ckSetBreakpoints then
        DoSetBreakpoints(C.BpSpec)
      else if C.Kind = ckSetAddressBreakpoints then
        DoSetAddressBreakpoints(C.AddrBpSpec)
      else
        FCommandQueue.Enqueue(C);
  finally
    LeaveCriticalSection(FQueueLock);
  end;
end;

procedure TWinDebugger.DoDataBreakpointCommand(const Spec: TDataBpArmSpec);
begin
  if Spec.Clear then begin
    FLastDataBpOk     := ClearDataWatchpoint(Spec.Slot);
    FLastDataBpSlot    := Spec.Slot;
    FLastDataBpReason := '';
    if not FLastDataBpOk then
      FLastDataBpReason := Format('slot %d is not in use', [Spec.Slot]);
  end else
    FLastDataBpOk := SetDataWatchpoint(Spec.Address, Spec.SizeBytes, Spec.WriteOnly,
      Spec.OwnerDescription, FLastDataBpSlot, FLastDataBpReason);
end;

function TWinDebugger.DrainDataBreakpointCommand(out Slot: Integer;
  out RefusalReason: string): Boolean;
// Mirrors DrainBreakpointCommands: dequeue everything, execute the queued
// ckSetDataBreakpoints command(s) synchronously (there is only ever one --
// ApplyDataBreakpointCommand posts and drains in the same call), re-enqueue
// every other kind untouched and in order.
var
  Pending: TArray<TCommand>;
begin
  Result := False;
  Slot   := -1;
  RefusalReason := '';
  EnterCriticalSection(FQueueLock);
  try
    SetLength(Pending, 0);
    while FCommandQueue.Count > 0 do
      Pending := Pending + [FCommandQueue.Dequeue];
    for var C in Pending do
      if C.Kind = ckSetDataBreakpoints then begin
        DoDataBreakpointCommand(C.DataBpSpec);
        Slot          := FLastDataBpSlot;
        RefusalReason := FLastDataBpReason;
        Result        := FLastDataBpOk;
      end else
        FCommandQueue.Enqueue(C);
  finally
    LeaveCriticalSection(FQueueLock);
  end;
end;

function TWinDebugger.ApplyDataBreakpointCommand(const Spec: TDataBpArmSpec;
  out Slot: Integer; out RefusalReason: string): Boolean;
var
  Cmd: TCommand;
begin
  Cmd := Default(TCommand);
  Cmd.Kind       := ckSetDataBreakpoints;
  Cmd.DataBpSpec := Spec;
  PostCommand(Cmd);
  Result := DrainDataBreakpointCommand(Slot, RefusalReason);
end;

procedure TWinDebugger.ProcessCommandQueue;
var
  Cmd: TCommand;
begin
  repeat
    EnterCriticalSection(FQueueLock);
    try
      if FCommandQueue.Count = 0 then
        Exit;
      Cmd := FCommandQueue.Dequeue;
    finally
      LeaveCriticalSection(FQueueLock);
    end;

    case Cmd.Kind of
      ckSetBreakpoints:
        DoSetBreakpoints(Cmd.BpSpec);
      ckSetAddressBreakpoints:
        DoSetAddressBreakpoints(Cmd.AddrBpSpec);
      ckSetDataBreakpoints:
        // Reached only if a caller posts without draining immediately
        // (ApplyDataBreakpointCommand always drains in the same call); kept so
        // an un-drained command is still applied rather than silently dropped.
        DoDataBreakpointCommand(Cmd.DataBpSpec);
      ckContinue:
        if (FProcess <> 0) and FIsStopped then begin
          var ContStatus := FPendingContinueStatus;
          FIsStopped             := False;
          FPendingContinueStatus := DBG_CONTINUE;
          FLastStepNote          := '';
          UnpatchBpAtRip;
          ReleasePendingEvent(ContStatus);
        end;
      ckStepToHandler:
        if FIsStopped then
          DoStepToHandler(Cmd);
      ckStepInto: begin
        if not FIsStopped then
          Continue;
        // Step the DAP-selected thread (0 = the currently-stopped one) and freeze
        // the rest so only it advances.
        var StepTid := Cmd.ThreadId;
        if StepTid = 0 then
          StepTid := FStoppedTid;
        // CONSUMED, not overwritten. A stop on an undelivered exception has this
        // set to DBG_EXCEPTION_NOT_HANDLED, and forcing DBG_CONTINUE here
        // SWALLOWS the exception and re-executes the faulting instruction, which
        // raises it again -- the reported "step at an exception stop loops
        // forever". Such a stop is routed to ckStepToHandler before it ever gets
        // here; this keeps the invariant true for any path that does not.
        var ContStatus := FPendingContinueStatus;
        FIsStopped             := False;
        FPendingContinueStatus := DBG_CONTINUE;
        FLastStepNote          := '';
        UnpatchBpAtRip(StepTid);
        FStepMode        := smInto;
        FStepSafetyCount := 0;
        FStepMinSP       := 0;
        var FromRva      := VAToRva(CurrentRIP(StepTid));
        FStepHasFromLoc  := FDebugInfo.RvaToSourceLine(FromRva, FStepFromLoc);
        SetTrapFlag(StepTid, True);
        FreezeThreadsForStep(StepTid);
        ReleasePendingEvent(ContStatus);
      end;
      ckStepOver: begin
        if not FIsStopped then
          Continue;
        // Step the DAP-selected thread (0 = the currently-stopped one) and freeze
        // the rest so only it advances -- also makes the run-to-return / raise-arm
        // machinery below race-free (no other thread can trip a transient step BP).
        var StepTid := Cmd.ThreadId;
        if StepTid = 0 then
          StepTid := FStoppedTid;
        // Consumed, not overwritten -- see ckStepInto.
        var ContStatus := FPendingContinueStatus;
        FIsStopped             := False;
        FPendingContinueStatus := DBG_CONTINUE;
        FLastStepNote          := '';
        UnpatchBpAtRip(StepTid);
        FreezeThreadsForStep(StepTid);
        var RIP := CurrentRIP(StepTid);
        var Rva := VAToRva(RIP);
        var Loc: TSourceLocation;

        // Detect import thunk: FF 25 xx xx xx xx = JMP QWORD PTR [RIP+off].
        // Delphi emits this stub for every `external` declaration.
        // Stepping over it must use the caller's return address (like step-out),
        // not the "next line in same file" heuristic, which would plant the BP
        // at an unrelated function in the same unit.
        var B0, B1: Byte;
        var IsImportThunk := ReadByte(RIP, B0) and ReadByte(RIP + 1, B1) and
                             (B0 = $FF) and (B1 = $25);

        if not IsImportThunk and FDebugInfo.RvaToSourceLine(Rva, Loc) then begin
          // Range-based step-over: single-step within the current function's
          // RVA range. When a CALL leaves the function (or recurses into it),
          // run full-speed to the return address and resume single-stepping;
          // otherwise stop at the first source line different from this one, or
          // in the caller when the function returns. This follows whichever
          // branch is actually taken (so a not-taken `if X = nil then raise`
          // can no longer let execution run free) and -- unlike the old RSP
          // recursion guard -- works when stepping from a function's `begin`,
          // because membership is decided by RVA range, not RSP magnitude.
          var FuncStart: UInt64;
          if FDebugInfo.RvaToFunctionStart(Rva, FuncStart) then begin
            ClearStepBps;
            FStepMode        := smOver;
            FStepOverVA      := 0;
            FStepFuncStart   := FuncStart;
            FStepFromLoc     := Loc;
            FStepHasFromLoc  := True;
            FStepResumeVA    := 0;
            FStepResumeSP    := 0;
            FStepRaiseArmed  := False;
            FStepPrevSP      := CurrentRSP(StepTid);
            FStepSafetyCount := 0;
            FStepMinSP       := 0;
            SetTrapFlag(StepTid, True);
            ReleasePendingEvent(ContStatus);
            Exit;
          end;
        end;

        // Import thunk or no function range found: use return address (same as
        // step-out) -- and validate it the same way. A non-zero test is not
        // enough: an unwind that fails on a 32-bit host returns a wide or
        // stack-resident value, and patching an INT3 there corrupts an unrelated
        // byte and leaves the step with nothing to stop it.
        var RetAddr := CallerReturnAddress(StepTid);
        if IsPlausibleReturnAddress(RetAddr) then begin
          FStepMode   := smOver;
          FStepOverVA := RetAddr;
          FStepMinSP  := 0;
          if FindBreakpointByVA(RetAddr) < 0 then begin
            var BP := Default(TBreakpointRec);
            BP.VA        := RetAddr;
            BP.IsOneShot := True;
            PlantInt3(BP);
            FBreakpoints.Add(BP);
          end;
          ReleasePendingEvent(ContStatus);
          Exit;
        end;

        // Last resort: single-step
        FStepMode  := smInto;
        FStepMinSP := 0;
        SetTrapFlag(StepTid, True);
        ReleasePendingEvent(ContStatus);
      end;
      ckStepInstruction:
        // Already decided (and already refused, if it had to be) on the
        // requesting thread -- see TInstrStepPlan. Nothing here may decide
        // anything: the resume has to happen on THIS thread, and the refusal
        // had to happen on the other one.
        if FIsStopped then
          DoStepInstruction(Cmd);
      ckStepOut: begin
        // Find the caller's resume RIP via StackWalk64 (uses .pdata unwind
        // info), then plant a one-shot INT3 there. Reading [RSP] directly
        // only works at function entry, before the prologue moves RSP.
        if not FIsStopped then
          Continue;
        // Step the DAP-selected thread (0 = the currently-stopped one) and freeze
        // the rest so only it advances.
        var StepTid := Cmd.ThreadId;
        if StepTid = 0 then
          StepTid := FStoppedTid;
        // Consumed, not overwritten -- see ckStepInto.
        var ContStatus := FPendingContinueStatus;
        FIsStopped             := False;
        FPendingContinueStatus := DBG_CONTINUE;
        FLastStepNote          := '';
        UnpatchBpAtRip(StepTid);
        FreezeThreadsForStep(StepTid);
        var RetAddr := CallerReturnAddress(StepTid);
        // Without unwind info StackWalk64 falls back to the AMD64 leaf convention
        // and returns whatever [RSP] happened to hold -- an uninitialised local
        // just past a Delphi prologue. Planting an INT3 on that would overwrite a
        // byte of unrelated data, so only an address inside executable code of a
        // known module is accepted as a caller.
        if IsPlausibleReturnAddress(RetAddr) then begin
          FStepMode   := smOut;
          FStepOverVA := RetAddr;
          FStepMinSP  := 0;
          if FindBreakpointByVA(RetAddr) < 0 then begin
            var BP: TBreakpointRec;
            BP.VA         := RetAddr;
            BP.OrigByte   := 0;
            BP.SourceFile := '';
            BP.SourceLine := 0;
            BP.IsOneShot  := True;
            BP.IsPlanted  := False;
            PlantInt3(BP);
            FBreakpoints.Add(BP);
          end;
          ReleasePendingEvent(ContStatus);
          Exit;
        end;
        // Fallback: single-step out of the frame. Better than nothing when unwind
        // info is missing (e.g. JITted or hand-written code), but it must not
        // masquerade as a completed step-out: seed the from-location (else the
        // very first trap already satisfies the new-line test a few bytes into the
        // SAME function) and require the stop to reach a strictly higher RSP,
        // i.e. the frame really was left.
        FStepMode        := smInto;
        FStepSafetyCount := 0;
        FStepMinSP       := CurrentRSP(StepTid);
        var FromRva      := VAToRva(CurrentRIP(StepTid));
        FStepHasFromLoc  := FDebugInfo.RvaToSourceLine(FromRva, FStepFromLoc);
        SetTrapFlag(StepTid, True);
        ReleasePendingEvent(ContStatus);
      end;
      ckPause:
        if (FProcess <> 0) and not FIsStopped then begin
          FPauseRequested := True;
          DebugBreakProcess(FProcess);
          DapLog('ckPause: DebugBreakProcess called');
        end;
    end;
  until False;
end;

function TWinDebugger.ResumeTid: DWORD;
begin
  if FStopEventTid <> 0 then
    Result := FStopEventTid
  else
    Result := FStoppedTid;
end;

procedure TWinDebugger.ReleasePendingEvent(Status: DWORD);
begin
  ContinueDebugEvent(FProcessId, ResumeTid, Status);
  FStopEventTid := 0;
end;

function TWinDebugger.PickPauseReportTid(EventThread: DWORD): DWORD;
begin
  // The main application thread carries a real (message-loop / user-code) stack;
  // the DebugBreakProcess-injected thread has none. Prefer the main thread when it
  // is a distinct, still-live thread, else fall back to the event thread.
  if (FMainTid <> 0) and (FMainTid <> EventThread) and FThreads.ContainsKey(FMainTid) then
    Result := FMainTid
  else
    Result := EventThread;
end;

procedure TWinDebugger.ReportStopped(Reason: TStopReason; VA: UInt64);
  function ReasonStr: string;
  begin
    case Reason of
      srEntry:      Result := 'entry';
      srBreakpoint:     Result := 'breakpoint';
      srStep:           Result := 'step';
      srException:      Result := 'exception';
      srPause:          Result := 'pause';
      srDataBreakpoint: Result := 'data breakpoint';
    else                  Result := '?';
    end;
  end;
var
  Loc: TSourceLocation;
  SF: string;
  SL: Integer;
begin
  // A step just landed (or any stop was reached): un-freeze the threads we
  // suspended for per-thread stepping before handing control back. Single choke
  // point -- every stop path (breakpoint / step / exception / pause / entry)
  // funnels through here.
  ThawStepFrozenThreads;
  SF := '';
  SL := 0;
  if FDebugInfo.RvaToSourceLine(VAToRva(VA), Loc) then begin
    SF := Loc.SourceFile;
    SL := Loc.Line;
  end;
  DapLog(Format('ReportStopped: reason=%s VA=$%x file=%s line=%d',
    [ReasonStr, VA, SF, SL]));
  FStepMinSP             := 0;
  FStepMode              := smNone;
  FSteppingOffStepBp     := False;
  FIsStopped             := True;
  FPendingContinueStatus := DBG_CONTINUE;
  if FRearmAfterStopVA <> 0 then begin
    var RearmIdx := FindBreakpointByVA(FRearmAfterStopVA);
    if (RearmIdx >= 0) and not FBreakpoints[RearmIdx].IsOneShot and
       not FBreakpoints[RearmIdx].IsPlanted then begin
      var RearmBP := FBreakpoints[RearmIdx];
      PlantInt3(RearmBP);
      FBreakpoints[RearmIdx] := RearmBP;
    end;
    FRearmAfterStopVA := 0;
  end;
  if Assigned(FOnStopped) then
    FOnStopped(Reason, SF, SL);
end;

{ Debug event handlers }

procedure TWinDebugger.WarnIfUnsupportedTargetArchitecture;

  function TargetIsWow64: Boolean;
  var
    K32: HMODULE;
    IsWow64_2: TIsWow64Process2;
    ProcMachine, NativeMachine: USHORT;
    Wow64: BOOL;
  begin
    Result := False;
    K32 := GetModuleHandle('kernel32.dll');
    if K32 = 0 then
      Exit;
    @IsWow64_2 := GetProcAddress(K32, 'IsWow64Process2');
    if Assigned(IsWow64_2) then begin
      if IsWow64_2(FProcess, ProcMachine, NativeMachine) then
        Result := ProcMachine <> IMAGE_FILE_MACHINE_UNKNOWN;
      Exit;
    end;
    // Fallback for hosts without IsWow64Process2: IsWow64Process carries no
    // machine detail; TRUE means a 32-bit process on a 64-bit OS.
    if IsWow64Process(FProcess, Wow64) then
      Result := Wow64;
  end;

begin
  // The debugger class was chosen from the on-disk PE header before the process
  // existed, because IsWow64Process2 needs a live handle and cannot answer until
  // now -- far too late to pick a class. This is the other half of that bargain:
  // the first moment the live process CAN be asked, check that it agrees with
  // what was built. Agreement is the normal case and says nothing.
  var LiveIs32  := TargetIsWow64;
  var BuiltIs32 := not TargetLayout.Is64Bit;
  if LiveIs32 = BuiltIs32 then
    Exit;
  var Live:  string := '64-bit';
  if LiveIs32 then Live := '32-bit (WOW64)';
  var Built: string := '64-bit';
  if BuiltIs32 then Built := '32-bit';
  DapLog(Format('Architecture mismatch: the running process is %s but the ' +
    'debugger was built for a %s target.', [Live, Built]));
  if not Assigned(FOnOutput) then
    Exit;
  FOnOutput(Format('[FATAL] Architecture mismatch: the running process is %s, ' +
    'but this session was set up for a %s target.', [Live, Built]));
  FOnOutput('        Breakpoints, call stacks and variables will not resolve. The ' +
            'architecture is chosen from the executable''s PE header, so this ' +
            'means the launched image is not the one that was inspected.');
end;

procedure TWinDebugger.HandleCreateProcess(const Ev: TDebugEvent);
begin
  FProcess   := Ev.CreateProcessInfo.hProcess;
  FProcessId := Ev.dwProcessId;
  FMainTid   := Ev.dwThreadId;  // primary thread -- retargeted-to on pause (F1)
  FImageBase := UInt64(Ev.CreateProcessInfo.lpBaseOfImage);
  FImageSize := ReadImageSizeOf(FImageBase);
  FThreads.AddOrSetValue(Ev.dwThreadId, Ev.CreateProcessInfo.hThread);
  FRunning := True;
  // Per the debug-event contract the receiver owns hFile and must close it
  // (hProcess/hThread stay system-managed).
  if Ev.CreateProcessInfo.hFile <> 0 then
    CloseHandle(Ev.CreateProcessInfo.hFile);
  DapLog(Format('CreateProcess: ImageBase=$%x PreferredBase=$%x',
    [FImageBase, FPreferredBase]));
  WarnIfUnsupportedTargetArchitecture;
  if FStopAtEntry then begin
    var EntryVA := UInt64(Ev.CreateProcessInfo.lpStartAddress);
    DapLog(Format('StopAtEntry: lpStartAddress=$%x', [EntryVA]));
    if EntryVA > 0 then begin
      // Default() zeroes Rva: ApplyAllBreakpoints recomputes VA for any
      // record with Rva > 0, so a garbage Rva here had it replant the
      // entry INT3 at a random address and the entry stop was lost.
      var BP := Default(TBreakpointRec);
      BP.VA        := EntryVA;
      BP.IsOneShot := True;
      FBreakpoints.Add(BP);
    end;
  end;
  ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
end;

procedure TWinDebugger.HandleCreateThread(const Ev: TDebugEvent);
begin
  FThreads.AddOrSetValue(Ev.dwThreadId, Ev.CreateThread.hThread);
  // A thread born while a per-thread step is in flight must also be frozen, else
  // it would run free alongside the single stepped thread. It is thawed with the
  // rest at the next reported stop.
  if FStepFreezeActive and (Ev.CreateThread.hThread <> 0) and
     (Ev.dwThreadId <> FStepTid) then
    if SuspendThread(Ev.CreateThread.hThread) <> DWORD(-1) then
      FStepFrozenTids.Add(Ev.dwThreadId);
  // A watchpoint set before this thread existed must cover it too, or a write
  // from exactly this thread is the one write the feature misses. Also covers
  // attach: DebugActiveProcess synthesises a CREATE_THREAD_DEBUG_EVENT for
  // every thread already running in the target, through this same path.
  if FWatchArmedSlots <> 0 then
    for var Slot := 0 to 3 do
      if FWatchSlots[Slot].InUse then begin
        var Reason: string;
        if not ArmWatchRegistersOnThread(Ev.dwThreadId, Slot, FWatchSlots[Slot].Address,
            FWatchSlots[Slot].SizeBytes, FWatchSlots[Slot].WriteOnly, Reason) then
          DapLog(Format('WATCHPOINT NOT ARMED on new tid=%d slot=%d addr=$%x (%s): a ' +
            'write from this thread will NOT be caught',
            [Ev.dwThreadId, Slot, FWatchSlots[Slot].Address, Reason]));
      end;
  ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
end;

procedure TWinDebugger.HandleExitThread(const Ev: TDebugEvent);
var
  TH: THandle;
begin
  // Drop the exiting thread from the freeze set BEFORE its handle is closed, so
  // ThawStepFrozenThreads never resumes a dead handle.
  for var I := FStepFrozenTids.Count - 1 downto 0 do
    if FStepFrozenTids[I] = Ev.dwThreadId then
      FStepFrozenTids.Delete(I);
  // If the thread being stepped exits mid-step, its single-step can never land;
  // thaw everyone so the process is not left with all other threads frozen and
  // nothing runnable (deadlock), and drop the now-orphaned step mode.
  if FStepFreezeActive and (Ev.dwThreadId = FStepTid) then begin
    ThawStepFrozenThreads;
    FStepMode := smNone;
  end;
  if FThreads.TryGetValue(Ev.dwThreadId, TH) then begin
    CloseHandle(TH);
    FThreads.Remove(Ev.dwThreadId);
  end;
  // Thread ids are recycled by the OS: a stale announced name would otherwise
  // be inherited by an unrelated future thread.
  FThreadNames.Remove(Ev.dwThreadId);
  ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
end;

procedure TWinDebugger.HandleExitProcess(const Ev: TDebugEvent);
begin
  FRunning   := False;
  FHasExited := True;
  // The process is gone: drop any step-freeze bookkeeping without touching the
  // (now invalid) thread handles.
  FStepFrozenTids.Clear;
  FStepFreezeActive := False;
  FStepTid          := 0;
  ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
  if Assigned(FOnExited) then
    FOnExited(Ev.ExitProcess.dwExitCode);
end;

procedure TWinDebugger.HandleOutputDbgString(const Ev: TDebugEvent);
var
  Len: WORD;
  Buf: TBytes;
  R: SIZE_T;
  S: string;
begin
  Len := Ev.DebugString.nDebugStringLength;
  if Len = 0 then begin
    ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    Exit;
  end;
  // nDebugStringLength counts CHARACTERS (incl. terminating null): bytes are
  // Len for ANSI events, Len*2 for Unicode. Reading Len*2 unconditionally
  // decoded the ANSI tail as garbage (and could fail outright when the
  // over-read crossed an unmapped page).
  var ByteCount: NativeUInt := Len;
  if Ev.DebugString.fUnicode <> 0 then
    ByteCount := NativeUInt(Len) * 2;
  SetLength(Buf, ByteCount);
  if ReadProcessMemory(FProcess, Ev.DebugString.lpDebugStringData,
       @Buf[0], ByteCount, R) and (R > 0) then begin
    if Ev.DebugString.fUnicode <> 0 then
      S := TEncoding.Unicode.GetString(Buf, 0, R)
    else
      S := TEncoding.ANSI.GetString(Buf, 0, R);
    // Drop the terminating null(s) so the DAP output event carries the
    // exact text the program passed to OutputDebugString.
    while (S <> '') and (S[Length(S)] = #0) do
      SetLength(S, Length(S) - 1);
    if Assigned(FOnOutput) then
      FOnOutput(S);
  end;
  ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
end;

procedure TWinDebugger.HandleLoadDll(const Ev: TDebugEvent);
var
  Base, ImageSize: UInt64;
  Name, Path: string;
  Buf: array[0..MAX_PATH - 1] of Char;
  PathLen: DWORD;
begin
  Base      := UInt64(Ev.LoadDll.lpBaseOfDll);
  Name      := '';
  Path      := '';

  if Ev.LoadDll.hFile <> 0 then begin
    PathLen := GetFinalPathNameByHandle(Ev.LoadDll.hFile, Buf, MAX_PATH, 0);
    if PathLen > 0 then begin
      SetString(Path, PChar(@Buf[0]), PathLen);
      if Path.StartsWith('\\?\') then
        Path := Path.Substring(4);
      Name := LowerCase(ExtractFileName(Path));
    end;
    CloseHandle(Ev.LoadDll.hFile);
  end;

  ImageSize := ReadImageSizeOf(Base);

  // dbghelp must learn about this module too, not just our own MAP/RSM/TD32
  // loader: StackWalk64 reads its unwind info through dbghelp's module list.
  // Registered for EVERY module, including the ones skipped below: it costs
  // nothing and the walk's requirements are not ours to second-guess.
  RegisterModuleWithDbgHelp(Path, Base, ImageSize);

  if IsForeignBitnessModule(Base) then begin
    DapLog(Format('LoadDll: ignoring 64-bit %s base=$%x in a 32-bit session',
                  [Name, Base]));
    Exit;
  end;

  if Name <> '' then begin
    FDllBases.AddOrSetValue(Name, Base);
    FDllSizes.AddOrSetValue(Name, ImageSize);
    DapLog(Format('LoadDll: %s base=$%x size=$%x', [Name, Base, ImageSize]));
    // Wrap callback so an exception in the host (e.g. exotic MAP/RSM in a
    // third-party BPL) doesn't tear down the whole debug loop. The host is
    // responsible for logging causes; the loop must keep dispatching events.
    if Assigned(FOnDllLoaded) then
      try
        FOnDllLoaded(Name, Path, Base, ImageSize);
      except
        on E: Exception do
          DapLog(Format('OnDllLoaded host exception for %s: %s: %s',
            [Name, E.ClassName, E.Message]));
      end;
  end;
end;

procedure TWinDebugger.HandleUnloadDll(const Ev: TDebugEvent);
var
  Base: UInt64;
  Name: string;
  DllBase, DllEnd: UInt64;
begin
  Base := UInt64(Ev.UnloadDll.lpBaseOfDll);
  // Drop the dbghelp registration even for a module we never tracked ourselves,
  // so a later module reusing this base cannot inherit stale unwind info.
  if FSymInitialized and (Base <> 0) then
    SymUnloadModule64(FProcess, Base);
  Name := '';
  for var KV in FDllBases do
    if KV.Value = Base then begin
      Name := KV.Key;
      Break;
    end;
  if Name = '' then
    Exit;

  // Remove any breakpoints that fall inside this module's VA range
  DllBase := Base;
  var DllSize: UInt64 := 0;
  FDllSizes.TryGetValue(Name, DllSize);
  DllEnd := Base + DllSize;
  var I := FBreakpoints.Count - 1;
  while I >= 0 do begin
    var BP := FBreakpoints[I];
    if (BP.VA >= DllBase) and ((DllEnd = DllBase) or (BP.VA < DllEnd)) then begin
      if BP.IsPlanted then
        RemoveInt3(BP);
      FBreakpoints.Delete(I);
    end;
    Dec(I);
  end;

  FDllBases.Remove(Name);
  FDllSizes.Remove(Name);
  DapLog(Format('UnloadDll: %s base=$%x', [Name, Base]));
  if Assigned(FOnDllUnloaded) then
    FOnDllUnloaded(Name, Base);
end;

const
  // MS_VC_EXCEPTION. Not a program error: a thread raises it to TELL the
  // debugger its own name. Delphi's TThread.NameThreadForDebugging raises it
  // (only when IsDebuggerPresent), as does the classic MSVC SetThreadName.
  MS_VC_EXCEPTION = DWORD($406D1388);
  // THREADNAME_INFO.dwType -- the structure is only trusted when it matches.
  THREADNAME_INFO_TYPE = DWORD($1000);
  // Hard cap on an announced name. The buffer lives in the debuggee and is
  // fully untrusted, so nothing longer is read even if no NUL is ever found.
  MAX_ANNOUNCED_THREAD_NAME = 255;

// Reads a NUL-terminated ANSI string out of the debuggee.
//
// Every property of the buffer is untrusted: it may be unmapped, it may run to
// the end of a page, and it may never be terminated at all. So the read is done
// in small chunks that never cross a page boundary (ReadProcessMemory fails the
// WHOLE request if any byte of it is unmapped, which would otherwise lose a
// perfectly good name that merely sits near the end of a mapped page), the scan
// stops at the first control byte (NUL or garbage), and the total length is
// capped by the caller. An unreadable pointer simply yields ''.
function TWinDebugger.ReadRemoteAnsiString(VA: UInt64; MaxLen: Integer): string;
const
  ChunkSize = 32;
  PageSize  = 4096;
var
  Chunk: array[0..ChunkSize - 1] of AnsiChar;
begin
  Result := '';
  if (VA = 0) or (MaxLen <= 0) then
    Exit;
  var Raw: AnsiString := '';
  var Offset := 0;
  while Offset < MaxLen do begin
    var Addr := VA + UInt64(Offset);
    var Want := ChunkSize;
    var ToPageEnd := Integer(PageSize - (Addr and (PageSize - 1)));
    if ToPageEnd < Want then
      Want := ToPageEnd;
    if Offset + Want > MaxLen then
      Want := MaxLen - Offset;
    if not ReadProcessMemoryAt(Addr, @Chunk[0], Want) then
      Break;  // unreadable page: keep whatever was already collected
    for var I := 0 to Want - 1 do begin
      if Chunk[I] < #32 then
        Exit(string(Raw));  // terminator, or a byte no thread name contains
      Raw := Raw + Chunk[I];
    end;
    Inc(Offset, Want);
  end;
  Result := string(Raw);
end;

// Consumes a MS_VC_EXCEPTION thread-name announcement and records the name.
//
// RaiseException copies the raiser's THREADNAME_INFO verbatim into
// ExceptionInformation, so the ULONG_PTR words ARE the structure:
//   [0] dwType     -- must be $1000
//   [1] szName     -- PAnsiChar in the DEBUGGEE's address space
//   [2] dwThreadID -- low dword ($FFFFFFFF = "the calling thread")
// On Win64 dwFlags shares [2]'s high dword (struct padding puts szName at
// offset 8); a WOW64 raiser sends the same first three words zero-extended
// from its 4-byte-pointer structure, with dwFlags landing in [3] instead. Both
// bitnesses therefore decode identically here.
//
// Some producers pass a POINTER to the structure in [1] instead of the
// structure inline. That shape is detected naturally -- reading a string at the
// struct address hits dwType's leading zero byte and yields '' -- and handled
// by the fallback, which tries the 64-bit then the 32-bit struct layout.
procedure TWinDebugger.CaptureAnnouncedThreadName(const Ev: TDebugEvent);

  // Tries to read a THREADNAME_INFO at StructVA. Returns '' unless dwType
  // matches, which keeps a bogus pointer from producing a bogus name.
  function NameFromStructAt(StructVA: UInt64; NameOffset, TypeSize: Integer;
    out StructTid: DWORD): string;
  begin
    Result    := '';
    StructTid := 0;
    var DwType: DWORD := 0;
    if not ReadProcessMemoryAt(StructVA, @DwType, SizeOf(DwType)) then
      Exit;
    if DwType <> THREADNAME_INFO_TYPE then
      Exit;
    var NamePtr: UInt64 := 0;
    if not ReadProcessMemoryAt(StructVA + UInt64(NameOffset), @NamePtr, TypeSize) then
      Exit;
    if not ReadProcessMemoryAt(StructVA + UInt64(NameOffset + TypeSize), @StructTid,
             SizeOf(StructTid)) then
      StructTid := 0;
    Result := ReadRemoteAnsiString(NamePtr, MAX_ANNOUNCED_THREAD_NAME);
  end;

begin
  var Params := Ev.Exception.ExceptionRecord.NumberParameters;
  if Params < 2 then
    Exit;
  if DWORD(Ev.Exception.ExceptionRecord.ExceptionInformation[0]) <> THREADNAME_INFO_TYPE then
    Exit;

  var NameArg  := UInt64(Ev.Exception.ExceptionRecord.ExceptionInformation[1]);
  var StructTid: DWORD := 0;
  if Params >= 3 then
    StructTid := DWORD(Ev.Exception.ExceptionRecord.ExceptionInformation[2]);

  var Name := ReadRemoteAnsiString(NameArg, MAX_ANNOUNCED_THREAD_NAME);
  if Name = '' then begin
    // Fallback: [1] was a pointer to the structure, not to the name.
    var NestedTid: DWORD := 0;
    Name := NameFromStructAt(NameArg, 8, 8, NestedTid);   // Win64 layout
    if Name = '' then
      Name := NameFromStructAt(NameArg, 4, 4, NestedTid); // WOW64 layout
    if Name <> '' then
      StructTid := NestedTid;
  end;
  if Name = '' then begin
    DapLog(Format('ThreadName announcement on tid %d: name unreadable (arg=$%x)',
      [Ev.dwThreadId, NameArg]));
    Exit;
  end;

  // dwThreadID = -1 means "the calling thread". Any other value is honoured
  // only when it names a thread we actually know, so a stray word (or dwFlags
  // bleeding into the low dword) can never relabel an unrelated thread.
  var TargetTid := Ev.dwThreadId;
  if (StructTid <> 0) and (StructTid <> DWORD(-1)) and FThreads.ContainsKey(StructTid) then
    TargetTid := StructTid;

  FThreadNames.AddOrSetValue(TargetTid, Name);
  DapLog(Format('ThreadName announcement: tid %d is now "%s"', [TargetTid, Name]));
end;

procedure TWinDebugger.HandleException(const Ev: TDebugEvent;
  out ContinueStatus: DWORD);
var
  Code: DWORD;
  ExcAddr: UInt64;
  BpIdx: Integer;
begin
  ContinueStatus := DBG_CONTINUE;
  Code    := Ev.Exception.ExceptionRecord.ExceptionCode;
  ExcAddr := UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress);
  case Code of
    EXCEPTION_BREAKPOINT, STATUS_WX86_BREAKPOINT:
    begin
      DapLog(Format('EXCEPTION_BREAKPOINT ($%x) at $%x FirstBreak=%s',
        [Code, ExcAddr, BoolToStr(FFirstBreak, True)]));
      if not FFirstBreak then begin
        FFirstBreak := True;
        ApplyAllBreakpoints;
        DapLog(Format('Startup break: planted %d breakpoints', [FBreakpoints.Count]));
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
        Exit;
      end;

      // ExceptionAddress IS the address of the INT3; RIP is already ExcAddr+1
      var BpVA := ExcAddr;

      if (FPendingReactivateVA = BpVA) and (Ev.dwThreadId = FReactivateTid) then begin
        // Re-arm: single-step fired, now re-plant INT3. Gated on the owning
        // thread: while stepping another thread, a DIFFERENT thread hitting this
        // VA is a genuine breakpoint, not this thread's pending re-arm.
        BpIdx := FindBreakpointByVA(BpVA);
        if BpIdx >= 0 then begin
          var BP := FBreakpoints[BpIdx];
          PlantInt3(BP);
          FBreakpoints[BpIdx] := BP;
        end;
        FPendingReactivateVA := 0;
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
        Exit;
      end;

      BpIdx := FindBreakpointByVA(BpVA);
      DapLog(Format('BP hit at $%x BpIdx=%d', [BpVA, BpIdx]));

      // Pause-button breakpoint injected by DebugBreakProcess: no INT3 to restore.
      // RIP is already at BpVA+1 (past the injected INT3); do NOT rewind.
      if FPauseRequested and (BpIdx < 0) then begin
        FPauseRequested := False;
        // The INT3 is on the injected thread; that thread's event is what must be
        // released to resume, but it has no user stack. Report a real user thread
        // (the main thread) so the pause shows a usable location/stack/locals (F1).
        FStopEventTid := Ev.dwThreadId;
        FStoppedTid   := PickPauseReportTid(Ev.dwThreadId);
        DapLog(Format('Pause break at $%x eventTid=%d reportTid=%d',
          [BpVA, Ev.dwThreadId, FStoppedTid]));
        ReportStopped(srPause, BpVA);
        Exit;
      end;

      if BpIdx < 0 then begin
        // Not our BP -- let the process handle it
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_EXCEPTION_NOT_HANDLED);
        Exit;
      end;

      var BP := FBreakpoints[BpIdx];
      // Restore original byte and rewind RIP
      RemoveInt3(BP);
      FBreakpoints[BpIdx] := BP;
      SetRIP(Ev.dwThreadId, BpVA);
      FStoppedTid := Ev.dwThreadId;

      if BP.IsOneShot then begin
        FBreakpoints.Delete(BpIdx);
        // Instruction granularity: the one-shot planted past a `call` / a
        // `rep`-prefixed instruction, or at a step-out's return address.
        if (FStepMode = smInstr) and (BpVA = FStepOverVA) then begin
          if not InstrStepLandedAt(BpVA, Ev.dwThreadId) then begin
            // A deeper recursive incarnation reached the same address (or
            // another thread did): step off it, re-arm, and keep running.
            RearmStepBpAfterForeignHit(BpVA, Ev.dwThreadId);
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Exit;
          end;
          EndInstructionStep;
          ReportStopped(srStep, BpVA);
          Exit;
        end;
        // Step at an exception stop: a one-shot planted on a PROVEN handler
        // block fired, which means the exception really did reach that block.
        // Nothing else can end this step -- it has no line condition and no
        // trap flag.
        if ExcStepBlock(BpVA) then begin
          if not ExcStepLandedAt(BpVA, Ev.dwThreadId) then begin
            // Another thread reached the same block with its own exception.
            // Threads are deliberately NOT frozen for this step (the unwind
            // takes the memory manager's locks), so this is reachable and must
            // leave the step armed for the thread that owns it.
            RearmStepBpAfterForeignHit(BpVA, Ev.dwThreadId);
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Exit;
          end;
          EndExceptionStep;
          ReportStopped(srStep, BpVA);
          Exit;
        end;
        // Range-based step-over: a transient step BP fired.
        var IsStepBp := False;
        for var SV in FStepBpVAs do
          if SV = BpVA then begin IsStepBp := True; Break; end;
        if (FStepMode = smOver) and IsStepBp then begin
          if BpVA = FStepResumeVA then begin
            // The run-to-return resume BP: we are back in the stepped function
            // just after a call (or returned from a recursive self-call).
            // RECURSION: a deeper incarnation returns to this SAME address. Its
            // RSP is below the stepped frame's, so treat that hit as not-ours --
            // re-arm the one-shot BP and keep running full speed. Without this
            // the step reported the correct next LINE while execution sat several
            // frames deeper, and every local came from the wrong incarnation.
            if (FStepResumeSP <> 0) and
               (CurrentRSP(Ev.dwThreadId) < FStepResumeSP) then begin
              // The thread is parked ON the breakpoint with its original byte
              // restored, so it must be stepped off before the INT3 goes back
              // (an immediate re-plant re-traps on the same instruction and
              // never progresses -- measured while building instruction
              // stepping, on the identical guard).
              RearmStepBpAfterForeignHit(BpVA, Ev.dwThreadId);
              ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
              Exit;
            end;
            FStepResumeSP   := 0;
            FStepResumeVA   := 0;
            FStepRaiseArmed := False;
            ClearStepBps;
            // If the call was the last instruction on its line, the return
            // address is already the NEXT source line -- stop here. Otherwise a
            // line consisting of a single parameterless call (`Foo;`) would be
            // skipped: we would single-step its call instruction, step over that
            // call too, and chain through every such line.
            if RvaInStepFunc(VAToRva(BpVA)) and StepOverAtNewLine(VAToRva(BpVA)) then begin
              FStepMode := smNone;
              ReportStopped(srStep, BpVA);
              Exit;
            end;
            // Same line (call returned mid-line): resume single-stepping.
            FStepPrevSP := CurrentRSP(Ev.dwThreadId);
            SetTrapFlag(Ev.dwThreadId, True);
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Exit;
          end;
          // A raise-catch BP: a raise unwound into the function's handler.
          // That handler line is where the step-over lands.
          FStepResumeVA   := 0;
          FStepResumeSP   := 0;
          FStepRaiseArmed := False;
          ClearStepBps;
          FStepMode := smNone;
          ReportStopped(srStep, BpVA);
          Exit;
        end;
        // If this was a step-over/step-out target: report step
        if (FStepMode in [smOver, smOut]) and (BpVA = FStepOverVA) then begin
          FStepOverVA := 0;
          ReportStopped(srStep, BpVA);
          Exit;
        end;
        if FStopAtEntry then begin
          FStopAtEntry := False;
          ReportStopped(srEntry, BpVA);
          Exit;
        end;
      end else begin
        FPendingReactivateVA := BpVA;
        FReactivateTid       := Ev.dwThreadId;
        SetTrapFlag(Ev.dwThreadId, True);
        // Conditional / hit-count / log-point support: bump the BP's hit
        // counter then ask the host (DapServer) whether this hit should
        // actually surface as a user-visible stop. The callback may emit
        // an `output` event (log-points) and/or evaluate the condition.
        // When it returns False, we keep the trap-step / re-arm machinery
        // running but bypass ReportStopped so VS Code never sees the stop.
        Inc(BP.HitCount);
        FBreakpoints[BpIdx] := BP;
        // A persistent breakpoint already occupied an instruction step's resume
        // address, so PlantStepBp left it alone and the hit arrives here instead
        // of on the one-shot path. Same landing, same guards.
        var InstrStepLanded := InstrStepLandedAt(BpVA, Ev.dwThreadId);
        // The same, for a step to an exception handler whose block already
        // carried a user breakpoint: PlantStepBp leaves an occupied address
        // alone, so the hit arrives here. The landing is the same one.
        var ExcStepLanded := ExcStepLandedAt(BpVA, Ev.dwThreadId);
        var ShouldStop := True;
        if Assigned(FOnBpHit) and not InstrStepLanded and not ExcStepLanded and not (
            (FStepMode in [smOver, smOut]) and (BpVA = FStepOverVA)) then
          ShouldStop := FOnBpHit(BP);
        if not ShouldStop then begin
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Exit;
        end;
        if InstrStepLanded then begin
          EndInstructionStep;
          ReportStopped(srStep, BpVA);
        end else if ExcStepLanded then begin
          EndExceptionStep;
          ReportStopped(srStep, BpVA);
        end else if (FStepMode in [smOver, smOut]) and (BpVA = FStepOverVA) then begin
          FStepOverVA := 0;
          ReportStopped(srStep, BpVA);
        end else begin
          // A user breakpoint interrupted an in-flight step-over (e.g. a BP
          // inside a stepped-over callee): drop the transient resume BP so it
          // never leaks into later execution.
          if FStepMode = smOver then begin
            ClearStepBps;
            FStepResumeVA   := 0;
            FStepResumeSP   := 0;
            FStepRaiseArmed := False;
            FStepMode := smNone;
          end;
          // The same, for an instruction step: a breakpoint anywhere inside the
          // callee being stepped over pre-empts it, and its one-shot must not
          // survive into later execution.
          if FStepMode = smInstr then
            EndInstructionStep;
          ReportStopped(srBreakpoint, BpVA);
        end;
        Exit;
      end;

      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    end;

    EXCEPTION_SINGLE_STEP, STATUS_WX86_SINGLE_STEP:
    begin
      FStoppedTid := Ev.dwThreadId;

      // A hardware watchpoint hit is delivered as a SINGLE-STEP exception -- the
      // very event everything below consumes -- and the exception code does not
      // distinguish the two. DR6 does, and nothing else can: B0..B3 name the
      // slot that fired, BS says the trap flag caused this trap. Reading it
      // also CLEARS it; leaving stale bits would make every later step look
      // like a watchpoint hit.
      var Trap := TakeDebugTrapCause(Ev.dwThreadId);
      if Trap.FiredSlots <> 0 then begin
        RecordWatchpointHit(Ev.dwThreadId, Trap.FiredSlots, ExcAddr);
        if not Trap.TrapFlagStep then begin
          // A watched cell was written while the target was running free: no
          // step of ours completed here.
          if FStepMode = smNone then begin
            // Nothing owns this thread right now (a plain Continue, not a
            // step) -- this is a genuine, user-visible stop. Increment 2/3
            // deliberately locked in the OTHER case below (a hit during an
            // in-flight step must not redirect it, see
            // RunWatchpointHitDuringStepIsNotAStepCompletion); this is that
            // rule's complement.
            FStoppedTid := Ev.dwThreadId;
            ReportStopped(srDataBreakpoint, ExcAddr);
            Exit;
          end;
          // A step (or its own resume/re-arm machinery) is in flight and
          // still owns this thread -- the honest thing is to resume and
          // leave it exactly as it was; its own resume breakpoint still owns
          // it. The hit is already recorded above.
          //
          // The trap flag is deliberately NOT touched on the way out: BS was
          // clear, so it was already off, and writing the thread context here
          // would be a needless round-trip on a thread that is running free.
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Exit;
        end;
        // BS as well: one instruction both completed our step and tripped the
        // watchpoint. Fall through so the step still finishes normally.
      end;
      SetTrapFlag(Ev.dwThreadId, False);

      if (FPendingReactivateVA <> 0) and (Ev.dwThreadId = FReactivateTid) then begin
        // Re-arm persistent BP (only the owning thread's trap-step re-arms; a
        // single-step from a different thread being stepped must fall through to
        // its own step handling and leave this pending re-arm intact).
        BpIdx := FindBreakpointByVA(FPendingReactivateVA);
        if BpIdx >= 0 then begin
          var BP := FBreakpoints[BpIdx];
          PlantInt3(BP);
          FBreakpoints[BpIdx] := BP;
        end;
        FPendingReactivateVA := 0;
        // The trap existed ONLY to move the thread off a transient step
        // breakpoint that fired for someone else; it decided nothing. Whatever
        // step is in flight still owns the thread through its own (now
        // re-planted) breakpoint, so resume without touching its state.
        if FSteppingOffStepBp then begin
          FSteppingOffStepBp := False;
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Exit;
        end;
        // The rearm consumed our trap-step. For smOver, that step may have been
        // the `call` that entered a callee -- evaluate NOW, at the callee entry,
        // where [RSP] is still the return address (one more step would be past
        // the prologue push and read a corrupted [RSP]). smInto just keeps
        // single-stepping; without re-arming TF it would run free.
        if FStepMode = smOver then begin
          HandleSmOverStep(Ev.dwThreadId, CurrentRIP(Ev.dwThreadId));
          Exit;
        end;
        // Instruction granularity: the re-arm's trap-step IS the one instruction
        // we asked for, so a trap-flag plan is complete here. A run-to-one-shot
        // plan (a `call` / `rep` / step-out) must NOT re-arm the trap flag: the
        // step it just consumed executed the call, and the rest of the plan is
        // the one-shot breakpoint already planted at the resume address.
        if FStepMode = smInstr then begin
          if FInstrStepTrapFlag and (Ev.dwThreadId = FInstrStepTid) then begin
            var LandedAt := CurrentRIP(Ev.dwThreadId);
            EndInstructionStep;
            ReportStopped(srStep, LandedAt);
            Exit;
          end;
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Exit;
        end;
        if FStepMode = smInto then
          SetTrapFlag(Ev.dwThreadId, True);
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
        Exit;
      end;

      // Instruction granularity. This trap IS the completed instruction --
      // there is no line-table condition to satisfy and nothing to run on to,
      // which is the whole point of the mode. Reached only for a trap-flag
      // plan; while a run-to-one-shot plan is in flight the trap flag is off,
      // so a single-step event here is not ours and the one-shot still owns
      // the thread. A watchpoint that fired during either was already dealt
      // with above, through DR6, and never arrives here as a step completion.
      if FStepMode = smInstr then begin
        if FInstrStepTrapFlag and (Ev.dwThreadId = FInstrStepTid) then begin
          EndInstructionStep;
          ReportStopped(srStep, ExcAddr);
          Exit;
        end;
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
        Exit;
      end;

      if FStepMode = smInto then begin
        // Walk instructions until we land on a source line different from
        // where the step started.
        Inc(FStepSafetyCount);
        var CurRva := VAToRva(ExcAddr);
        var CurLoc: TSourceLocation;
        var HasCurLoc := FDebugInfo.RvaToSourceLine(CurRva, CurLoc);
        var AtNewLine := HasCurLoc and
          (not FStepHasFromLoc or
           not SameText(CurLoc.SourceFile, FStepFromLoc.SourceFile) or
           (CurLoc.Line <> FStepFromLoc.Line));
        // A step-OUT that had to fall back to single-stepping has only succeeded
        // once the frame is gone -- a new source line inside the same frame is not
        // a step-out (see FStepMinSP).
        if AtNewLine and (FStepMinSP <> 0) then
          AtNewLine := CurrentRSP(Ev.dwThreadId) > FStepMinSP;
        // A callee's ENTRY address already maps to a source line, so the test above
        // is satisfied by the very FIRST instruction of the function we just
        // stepped into -- before its prologue established the frame and before the
        // register arguments were spilled to their home slots. Everything read
        // there (Self, every by-register parameter) is the CALLER's leftover frame,
        // typed correctly and flagged as nothing. Run on to the start of the
        // function body instead: the same address a breakpoint on the first
        // statement binds to, which is why breakpoints were never affected.
        //
        // A one-shot BP rather than more single-stepping, because a preamble may
        // CALL (managed-local initialisation, stack probes); single-stepping would
        // dive into sourceless RTL code and resurface in the middle of the
        // preamble. Reuses the run-to-VA-then-report-a-step path already used by
        // the sourceless pivot below.
        if AtNewLine then begin
          var BodyVA := FunctionBodyStartVA(ExcAddr);
          if (BodyVA > ExcAddr) and IsPlausibleReturnAddress(BodyVA) then begin
            FStepMode   := smOut;
            FStepOverVA := BodyVA;
            FStepMinSP  := 0;
            if FindBreakpointByVA(BodyVA) < 0 then begin
              var BP: TBreakpointRec;
              BP.VA         := BodyVA;
              BP.OrigByte   := 0;
              BP.SourceFile := '';
              BP.SourceLine := 0;
              BP.IsOneShot  := True;
              BP.IsPlanted  := False;
              PlantInt3(BP);
              FBreakpoints.Add(BP);
            end;
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Exit;
          end;
        end;
        if AtNewLine then begin
          ReportStopped(srStep, ExcAddr);
          Exit;
        end;
        // Sourceless code (import thunk, system DLL, RTL internals): pivot to
        // step-out -- plant a one-shot BP at the caller's return address so we
        // resurface at the next Delphi source line without burning thousands of
        // single-steps through unknown territory.
        if not HasCurLoc then begin
          var RetAddr := CallerReturnAddress(FStoppedTid);
          // Same guard as ckStepOut: a leaf-convention guess must never be
          // patched with an INT3.
          if IsPlausibleReturnAddress(RetAddr) then begin
            FStepMode   := smOut;
            FStepOverVA := RetAddr;
            FStepMinSP  := 0;
            // If a persistent BP already exists at the return address, rely on
            // the BP hit handler to report srStep -- don't plant a duplicate.
            if FindBreakpointByVA(RetAddr) < 0 then begin
              var BP: TBreakpointRec;
              BP.VA         := RetAddr;
              BP.OrigByte   := 0;
              BP.SourceFile := '';
              BP.SourceLine := 0;
              BP.IsOneShot  := True;
              BP.IsPlanted  := False;
              PlantInt3(BP);
              FBreakpoints.Add(BP);
            end;
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Exit;
          end;
        end;
        // Safety net: stop after too many steps with no new source line.
        if FStepSafetyCount >= 10000 then begin
          ReportStopped(srStep, ExcAddr);
          Exit;
        end;
        // Keep stepping
        SetTrapFlag(Ev.dwThreadId, True);
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
        Exit;
      end;

      if FStepMode = smOver then begin
        HandleSmOverStep(Ev.dwThreadId, ExcAddr);
        Exit;
      end;

      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    end;

    MS_VC_EXCEPTION:
    begin
      // Debugger protocol traffic, not a program error: the thread is telling
      // us its name. Consume it, record the name and resume with DBG_CONTINUE
      // (which dismisses the exception, exactly as RaiseException's caller
      // expects). Deliberately handled BEFORE the filter/rule machinery: it
      // must never surface as a stop, not even with the `all` first-chance
      // filter on, and no user rule may turn it into one.
      CaptureAnnouncedThreadName(Ev);
      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
      Exit;
    end;

  else
    // Any other exception: surface it (or not) according to the user's
    // exception-filter selection. Filter set is initialised to the
    // legacy hardcoded defaults (Delphi + AV + Unhandled), so behaviour
    // is unchanged unless the user toggles filters via the DAP
    // `setExceptionBreakpoints` request.
    begin
      FStoppedTid := Ev.dwThreadId;
      var IsSecondChance  := Ev.Exception.dwFirstChance = 0;
      var IsAV            := Code = EXCEPTION_ACCESS_VIOLATION;
      var IsDelphiRaise   := Code = $0EEDFADE;
      // Read the Delphi class name early so we can apply the per-class
      // refinement when both the `delphi` filter is on AND a non-empty
      // class list was configured.
      var DelphiClassName: string := '';
      // Athens 36 Win64 RTL packs 8 ULONG_PTRs into ExceptionInformation;
      // info[1] holds the exception OBJECT pointer (info[0] is a fixed
      // small offset whose meaning isn't decoded). Older Delphi RTL kept
      // the object at info[0]; we try [1] first and fall back to [0]
      // for compatibility with pre-Athens binaries.
      var DelphiMessage: string := '';
      FExceptionObjAddr := 0;
      if IsDelphiRaise then begin
        // The object pointer is at info[1] on Athens, info[0] on older RTL.
        // Whichever yields a class name is the real object; read its message too.
        var ObjAddr: UInt64 := 0;
        if Ev.Exception.ExceptionRecord.NumberParameters >= 2 then begin
          ObjAddr         := Ev.Exception.ExceptionRecord.ExceptionInformation[1];
          DelphiClassName := ReadDelphiExceptionClass(ObjAddr);
        end;
        if (DelphiClassName = '') and (Ev.Exception.ExceptionRecord.NumberParameters >= 1) then begin
          ObjAddr         := Ev.Exception.ExceptionRecord.ExceptionInformation[0];
          DelphiClassName := ReadDelphiExceptionClass(ObjAddr);
        end;
        if DelphiClassName <> '' then begin
          DelphiMessage     := ReadDelphiExceptionMessage(ObjAddr);
          FExceptionObjAddr := ObjAddr;  // expose as the $exception pseudo-local
        end;
      end;

      var DelphiClassMatches: Boolean := True;
      if IsDelphiRaise and (FDelphiClassFilter <> '') then begin
        DelphiClassMatches := False;
        for var Want in TArray<string>(FDelphiClassFilter.Split([',', ';'])) do
          if SameText(Trim(Want), DelphiClassName) then begin
            DelphiClassMatches := True;
            Break;
          end;
      end;

      // Decode the class/message/description unconditionally -- needed for rule
      // matching, console logging, and the stop UI alike.
      var ExcClass   := Format('Exception 0x%.8x', [Code]);
      var ExcMessage := DelphiMessage;
      if IsDelphiRaise then begin
        if DelphiClassName <> '' then
          ExcClass := DelphiClassName
        else
          ExcClass := Format('Delphi exception at $%x', [ExcAddr]);
      end else if IsAV then begin
        ExcClass := 'EAccessViolation';
        // AV info: [0] = 0 read / 1 write / 8 DEP, [1] = faulting address.
        if Ev.Exception.ExceptionRecord.NumberParameters >= 2 then begin
          var RW := Ev.Exception.ExceptionRecord.ExceptionInformation[0];
          var Verb := 'accessing';
          if      RW = 0 then Verb := 'reading'
          else if RW = 1 then Verb := 'writing';
          ExcMessage := Format('Access violation at $%x %s address $%x',
            [ExcAddr, Verb, Ev.Exception.ExceptionRecord.ExceptionInformation[1]]);
        end else
          ExcMessage := Format('Access violation at $%x', [ExcAddr]);
      end else if IsSecondChance then
        ExcClass := Format('Second-chance exception 0x%.8x', [Code]);
      FLastExceptionClass    := ExcClass;
      FLastExceptionMessage  := ExcMessage;
      FLastExcIsDelphiRaise  := IsDelphiRaise;
      // Combined summary for the stop UI: "Class: Message" when a message exists.
      var ExcDesc := ExcClass;
      if ExcMessage <> '' then
        ExcDesc := ExcClass + ': ' + ExcMessage;
      FLastExceptionDesc := ExcDesc;

      // Filter selection is the fallback when no rule matches.
      var FilterStop :=
        (IsSecondChance and (efUnhandled       in FExceptionFilters)) or
        ((not IsSecondChance) and (
          (IsDelphiRaise  and (efDelphi          in FExceptionFilters)
                          and DelphiClassMatches) or
          (IsAV           and (efAccessViolation in FExceptionFilters)) or
          (efAllFirstChance in FExceptionFilters)));

      // Rule engine: a matching rule's action overrides the filter decision.
      var EffAction: TExceptionAction;
      if FilterStop then EffAction := eaBreak else EffAction := eaIgnore;
      if Length(FExceptionRules) > 0 then begin
        var RaiseUnit := '';
        var RaiseLine := 0;
        var HasRaiseSite := False;
        if RulesNeedRaiseSite(FExceptionRules) then
          HasRaiseSite := RaiseSiteLocation(RaiseUnit, RaiseLine);
        // Runtime class + ancestors for `classIs`; a non-Delphi exception has no
        // object, so its chain is just the synthetic class name.
        var ClassChain: TArray<string>;
        if IsDelphiRaise and (FExceptionObjAddr <> 0) then
          ClassChain := ReadDelphiExceptionClassChain(FExceptionObjAddr);
        if Length(ClassChain) = 0 then
          ClassChain := [ExcClass];
        // The raw Win32 code is passed too: it is the only criterion that can
        // match a native exception (no Delphi object, so no class / message).
        var RuleAction: TExceptionAction;
        if MatchExceptionRules(FExceptionRules, ClassChain, ExcMessage,
             RaiseUnit, HasRaiseSite, RaiseLine, Code, RuleAction) then
          EffAction := RuleAction;
      end;

      DapLog(Format('Exception 0x%.8x at $%x (firstChance=%d) -> %s [%s]',
        [Code, ExcAddr, Ev.Exception.dwFirstChance, ExcDesc,
         ExceptionActionToStr(EffAction)]));

      if EffAction = eaBreak then begin
        if Assigned(FOnOutput) then
          FOnOutput(Format('[Exception] %s at $%x', [ExcDesc, ExcAddr]));
        // An exception surfaced while a step-over was in flight: abandon the
        // step and drop any transient resume BP so it cannot fire spuriously
        // after the stack unwinds past it.
        if FStepMode = smOver then begin
          ClearStepBps;
          FStepResumeVA   := 0;
          FStepResumeSP   := 0;
          FStepRaiseArmed := False;
          FStepMode := smNone;
        end;
        // Same for an instruction step: once the stack unwinds past the resume
        // address, its one-shot can only fire somewhere unrelated.
        if FStepMode = smInstr then
          EndInstructionStep;
        // A step to the handler was in flight and an exception arrived instead
        // of the handler block. Either way the step is over -- its one-shots
        // must not survive into later execution. When it is the SAME exception
        // at the SAME address, the step made NO progress, and saying so once is
        // the whole difference between this and the reported symptom, where the
        // same exception refired forever with nothing naming the cause.
        if FStepMode = smToHandler then begin
          if (Code = FExcStepFromCode) and (ExcAddr = FExcStepFromVA) then begin
            FLastStepNote := Format('the step to %s made no progress: %s re-fired at ' +
              'the same address ($%x). The step has been abandoned; the handler was ' +
              'not reached.', [FExcStepDesc, ExcClass, ExcAddr]);
            if Assigned(FOnOutput) then
              FOnOutput('[Step] ' + FLastStepNote);
            DapLog('StepToExceptionHandler ABANDONED: ' + FLastStepNote);
          end;
          EndExceptionStep;
        end;
        FLastExceptionAddr := ExcAddr;
        FLastExceptionCode := Code;
        ReportStopped(srException, ExcAddr);
        // Keep the exception pending so the program's own try/except handles it.
        // FPendingContinueStatus is also set here so ckContinue/step use the right status.
        FPendingContinueStatus := DBG_EXCEPTION_NOT_HANDLED;
        ContinueStatus         := DBG_EXCEPTION_NOT_HANDLED;
      end else begin
        // ignore / log / logStack: do not pause; resume after optional logging.
        if (EffAction in [eaLog, eaLogStack]) and Assigned(FOnOutput) then begin
          FOnOutput(Format('[Exception] %s at $%x', [ExcDesc, ExcAddr]));
          if EffAction = eaLogStack then
            FOnOutput(FormatCallStackText);
        end;
        // If a step-over is running over a call (resume BP planted) and this is
        // a real unwinding exception, the raise will not return to the call's
        // return address -- it lands in this function's except/finally handler.
        // Arm one-shot BPs on every line of the stepped function so the step
        // lands on the handler instead of running free. Done once per step and
        // only for genuine unwinds (Delphi raise / access violation).
        if (FStepMode = smOver) and (FStepResumeVA <> 0) and
           (not FStepRaiseArmed) and (IsDelphiRaise or IsAV) then begin
          PlantInFuncStepBps;
          FStepRaiseArmed := True;
        end;
        // Pass through so the process's own handler runs. Without this, any such
        // event leaves the process permanently suspended.
        ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_EXCEPTION_NOT_HANDLED);
      end;
    end;
  end;
end;

procedure TWinDebugger.Launch(const ExePath: string; StopAtEntry: Boolean);
var
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  FStopAtEntry  := StopAtEntry;
  FFirstBreak   := False;
  FKillOnDetach := True;  // launch mode: we own the process; kill on disconnect.
  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  // No window / console flags here: the adapter must not interfere with the
  // debuggee's UI in any way. GUI debuggees show their forms as usual; their
  // own subsystem decides whether a console is allocated. Test targets are
  // built as GUI-subsystem programs and never write to stdio, so the DAP
  // channel on the adapter's stdin/stdout stays clean.
  if not CreateProcess(nil, PChar(ExePath), nil, nil, False,
      DEBUG_ONLY_THIS_PROCESS,
      nil, nil, SI, PI) then
    RaiseLastOSError;
  // Handles stored when CREATE_PROCESS_DEBUG_EVENT arrives
  CloseHandle(PI.hThread);  // we get the thread handle in the event
  CloseHandle(PI.hProcess);
end;

// Enable SeDebugPrivilege in the current process token so DebugActiveProcess
// can attach to processes the user owns (the default DACL grants access only
// when the caller's token has this privilege enabled). Best effort -- if the
// privilege isn't held by the user (standard user with no policy grant) the
// call succeeds silently and the subsequent DebugActiveProcess will fail
// with Access Denied as before.
procedure EnableDebugPrivilege;
const
  SE_DEBUG_NAME = 'SeDebugPrivilege';
var
  Tok: THandle;
  Luid: TLargeInteger;
  Tp:   TTokenPrivileges;
begin
  if not OpenProcessToken(GetCurrentProcess,
       TOKEN_ADJUST_PRIVILEGES or TOKEN_QUERY, Tok) then Exit;
  try
    if not LookupPrivilegeValue(nil, SE_DEBUG_NAME, Luid) then Exit;
    Tp.PrivilegeCount := 1;
    Tp.Privileges[0].Luid       := Luid;
    Tp.Privileges[0].Attributes := SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(Tok, False, Tp, 0, PTokenPrivileges(nil)^,
      PCardinal(nil)^);
  finally
    CloseHandle(Tok);
  end;
end;

procedure TWinDebugger.Attach(ProcessId: Cardinal; KillOnDetach: Boolean);
begin
  // StopAtEntry is meaningless for an existing process -- it's already past
  // entry. The kernel injects an initial INT3 right after attach completes;
  // the regular `not FFirstBreak` path treats it as a benign synchronous
  // breakpoint (ApplyAllBreakpoints + continue) so we don't surface a stop
  // for it.
  FStopAtEntry  := False;
  FFirstBreak   := False;
  FKillOnDetach := KillOnDetach;
  EnableDebugPrivilege;
  if not DebugActiveProcess(DWORD(ProcessId)) then
    RaiseLastOSError;
  // Default Windows behaviour kills the debuggee if the debugger exits
  // without an orderly detach (e.g. adapter crash). With KillOnDetach=False
  // the user wants the target to survive a disconnect, so flip the flag so
  // an abnormal adapter death does NOT take down the attached process.
  if not KillOnDetach then
    DebugSetProcessKillOnExit(False);
  // CREATE_PROCESS_DEBUG_EVENT arrives shortly with the process handle and
  // thread handles for every existing thread, followed by LOAD_DLL events
  // for every already-loaded module. Same code paths as launch handle them.
end;

procedure TWinDebugger.ProcessOneEvent;
var
  Ev: TDebugEvent;
  ContStatus: DWORD;
begin
  ProcessCommandQueue;

  if not WaitForDebugEvent(Ev, 10) then
    Exit;

  ContStatus := DBG_CONTINUE;
  case Ev.dwDebugEventCode of
    CREATE_PROCESS_DEBUG_EVENT: HandleCreateProcess(Ev);
    CREATE_THREAD_DEBUG_EVENT:  HandleCreateThread(Ev);
    EXIT_THREAD_DEBUG_EVENT:    HandleExitThread(Ev);
    EXIT_PROCESS_DEBUG_EVENT:   HandleExitProcess(Ev);
    OUTPUT_DEBUG_STRING_EVENT:  HandleOutputDbgString(Ev);
    EXCEPTION_DEBUG_EVENT:      HandleException(Ev, ContStatus);
    LOAD_DLL_DEBUG_EVENT: begin
      HandleLoadDll(Ev);
      // HandleLoadDll -> OnDllLoaded may post ckSetBreakpoints for specs
      // that resolve into the just-loaded module. Plant them NOW, while
      // the debuggee is still suspended at this event, so the int3 is in
      // place before the module's init code can run past the BP.
      DrainBreakpointCommands;
      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    end;
    UNLOAD_DLL_DEBUG_EVENT: begin
      HandleUnloadDll(Ev);
      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    end;
  else
    ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, ContStatus);
  end;
end;

function TWinDebugger.GetStackFrames: TArray<TStackFrame>;
begin
  Result := GetStackFrames(FStoppedTid);
end;

// x64: dbghelp drives the unwind off .pdata, which is exact. It mutates its own
// context copy as it goes, so this owns a private one rather than borrowing the
// caller's.
function TWinDebugger.WalkRawFrames(TH: THandle; SeedPc, SeedSp, SeedFp: UInt64;
  MaxFrames: Integer): TArray<TRawStackFrame>;
var
  Ctx: TContext;
  SF:  TDbgStackFrame64;
begin
  SetLength(Result, 0);
  var IgnorePc, IgnoreSp, IgnoreFp: UInt64;
  if not FillStackWalkContext(TH, Ctx, IgnorePc, IgnoreSp, IgnoreFp) then
    Exit;

  SF := Default(TDbgStackFrame64);
  SF.AddrPC.Offset    := SeedPc;
  SF.AddrPC.Mode      := AddrModeFlat;
  SF.AddrFrame.Offset := SeedFp;
  SF.AddrFrame.Mode   := AddrModeFlat;
  SF.AddrStack.Offset := SeedSp;
  SF.AddrStack.Mode   := AddrModeFlat;

  while StackWalk64(StackWalkMachineType, FProcess, TH, SF, @Ctx,
      nil, @SymFunctionTableAccess64, @SymGetModuleBase64, nil) do begin
    if SF.AddrPC.Offset = 0 then
      Break;
    var Raw: TRawStackFrame;
    Raw.Origin := foDbgHelpWhole;
    Raw.PC := SF.AddrPC.Offset;
    // StackWalk64 updates Ctx to the unwound register state for THIS frame;
    // Ctx.Rbp is the frame's actual RBP, which the BPREL local / param offset
    // decode is relative to. SF.AddrFrame is unwind-defined and not a reliable
    // RBP for Delphi frames, so prefer Ctx.Rbp.
    if Ctx.Rbp <> 0 then
      Raw.FramePtr := Ctx.Rbp
    else
      Raw.FramePtr := SF.AddrFrame.Offset;
    Result := Result + [Raw];
    if Length(Result) >= MaxFrames then
      Break;
  end;
end;

// Walk the call stack of an arbitrary thread. While stopped at a debug event the
// whole process is frozen, so every thread's context is valid and can be walked
// read-only. Frame records carry RBP/IP, so the locals decode (which reads
// process memory at the frame's RBP) works for any thread without further work.
function TWinDebugger.GetStackFrames(TID: DWORD): TArray<TStackFrame>;
const
  MAX_FRAMES = 30;
var
  TH:    THandle;
  Ctx:   TContext;
  Frame: TStackFrame;
  Loc:   TSourceLocation;
begin
  SetLength(Result, 0);
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  // StackWalk64 MUTATES Ctx into the unwound state of each frame it yields, so
  // the seed registers must be captured HERE -- reading them back off Ctx after
  // the loop stored the LAST frame's registers under a key that is compared
  // against the live seed, which no healthy walk could ever match.
  var SeedRip, SeedRsp, SeedRbp: UInt64;
  if not FillStackWalkContext(TH, Ctx, SeedRip, SeedRsp, SeedRbp) then begin
    DapLog(Format('GetStackFrames(TID=%d): thread context read FAILED LastErr=%d', [TID, GetLastError]));
    Exit;
  end;

  // Per-stop cache, keyed by RIP+RSP: VS Code issues stackTrace twice per stop
  // and scopes/evaluate also need the frames. Recomputing a deep stack
  // (StackWalk64 across every module) is the dominant post-stop cost on a real
  // app, so serve repeats from the cache. The key auto-invalidates: any
  // step/goto/continue changes RIP or RSP, so the next call recomputes. RSP is
  // part of the key because a recursive function can stop at the same RIP at
  // different depths -- same instruction, different stack.
  // ...but a walk made while a provider is still building its index produces
  // names that are missing only because the answer was not ready YET. Caching
  // that outcome PINS it for the whole stop: every later stackTrace in the same
  // stop replays the same blank frames, and the caller has no way to retry short
  // of resuming. So while indexing is outstanding, neither serve nor store the
  // cache -- the walk repeats (bounded, non-blocking) until the indexes are ready
  // and the first complete result is the one that gets pinned.
  var IndexingPending := FDebugInfo.AnyBackgroundIndexingPending;
  // Snapshot the provider-set revision BEFORE the walk. Stamping the cache with
  // the revision read AFTER it would pin frames that were symbolicated WITHOUT a
  // provider that arrived mid-walk, under that provider's new revision -- i.e.
  // permanently nameless frames for a module whose symbols did land.
  var RevBefore := FDebugInfo.Revision;
  if (not IndexingPending) and
     (FCachedFramesTID = TID) and (FCachedFramesRIP = SeedRip) and
     (FCachedFramesRSP = SeedRsp) and
     (FCachedFramesRev = FDebugInfo.Revision) and
     (Length(FCachedFrames) > 0) then
    Exit(FCachedFrames);

  // Lazy init: enumerates every module mapped so far so StackWalk64 can read
  // .pdata unwind info for each one. Modules mapped later are registered from
  // HandleLoadDll -- this sweep sees only what exists right now.
  EnsureSymInitialized;

  for var Raw in WalkRawFrames(TH, SeedRip, SeedRsp, SeedRbp, MAX_FRAMES) do begin
    if Raw.PC = 0 then
      Break;
    Frame.IP := Raw.PC;
    // Frame 0's PC is not the walker's to decide: it is the thread's live PC,
    // which the caller already read and which the stop location was resolved
    // from. Observed on a 32-bit target whose top frame sat in a runtime package
    // dbghelp knew nothing about: StackWalk64 returned $FFFFFFFFB5C34A23 for a
    // PC of $B5C34A23 -- the address SIGN-extended to 64 bits. That belongs to
    // no module, so the frame rendered as "unknown module" with no source and
    // the editor would not open the line, even though ReportStopped had already
    // resolved the very same address to frmEnumsU.pas:235.
    if Length(Result) = 0 then
      Frame.IP := SeedRip;
    // A WOW64 process has no user address above 4 GB, so anything wider is the
    // walker having gone astray rather than a real frame. Stop rather than
    // emit frames that can only mis-resolve.
    if (not TargetLayout.Is64Bit) and (Frame.IP > $FFFFFFFF) then
      Break;
    Frame.FrameRBP := Raw.FramePtr;
    Frame.Origin   := Raw.Origin;
    // Frame.IP, not the walker's raw PC: frame 0 was just re-anchored to the
    // thread's live PC above, and symbolication has to follow the corrected
    // address or it resolves the walker's bad one.
    SymbolicateAddress(Frame.IP, {AtReturnAddress=}Length(Result) > 0, Frame);
    Result := Result + [Frame];
    if Length(Result) >= MAX_FRAMES then
      Break;
  end;

  // Defensive (F15): StackWalk64 sometimes cannot unwind a real-world worker thread
  // at all -- Oracle/OCI, thread-pool, or COM threads whose TOP frame lacks usable
  // .pdata unwind info -- and returns nothing. GetThreadContext still gave a valid
  // RIP, so surface frame 0 from the raw seed context rather than an empty stack, so
  // a thread picked via get_threads at least shows its current location/module.
  if (Length(Result) = 0) and (SeedRip <> 0) then begin
    Frame := Default(TStackFrame);
    Frame.IP       := SeedRip;
    Frame.FrameRBP := SeedRbp;
    Frame.Origin   := foSynthesizedSeed;
    var Rva0 := VAToRva(SeedRip);
    if FDebugInfo.RvaToSourceLine(Rva0, Loc) then begin
      Frame.SourceFile := Loc.SourceFile;
      Frame.SourceLine := Loc.Line;
    end;
    FDebugInfo.RvaToFunctionName(Rva0, Frame.FunctionName);
    var FuncRva0: UInt64 := 0;
    if FDebugInfo.RvaToFunctionStart(Rva0, FuncRva0) then
      Frame.FuncEntryVA := RvaToVA(FuncRva0);
    Result := Result + [Frame];
    DapLog(Format('GetStackFrames(TID=%d): StackWalk yielded 0 frames; synthesized frame0 RIP=$%x', [TID, SeedRip]));
  end;

  // Only a walk done against ready indexes may be pinned for the rest of the
  // stop (see the serve guard above). An incomplete one is returned to the
  // caller but deliberately not remembered, so the next request re-walks.
  // Indexing is re-sampled: a build that STARTED during the walk makes this
  // result just as incomplete as one that was already running when it began.
  if IndexingPending or FDebugInfo.AnyBackgroundIndexingPending then
    Exit;
  FCachedFrames    := Result;
  FCachedFramesTID := TID;
  FCachedFramesRIP := SeedRip;
  FCachedFramesRSP := SeedRsp;
  FCachedFramesRev := RevBefore;
end;

function TWinDebugger.GetRegisters: TRegisterSnapshot;
begin
  ReadThreadRegisters(FStoppedTid, Result);
end;

function TWinDebugger.EvaluateLocalName(const Name: string;
  out Value: TLocalValue): Boolean;

  // For names that came back qualified (e.g. "Increment.d1"), also try
  // matching the unqualified suffix so a watch on "d1" resolves to the
  // parent's local. Own locals win over parent locals because they appear
  // first in the list returned by GetLocalValues.
  function ShortName(const FullName: string): string;
  begin
    var DotPos := FullName.LastIndexOf('.');
    if DotPos >= 0 then
      Result := FullName.Substring(DotPos + 1)
    else
      Result := FullName;
  end;

begin
  Result := False;
  var Locals := GetLocalValues;
  for var L in Locals do
    if SameText(L.Name, Name) or SameText(ShortName(L.Name), Name) then begin
      Value := L;
      Exit(True);
    end;
end;

function TWinDebugger.EvaluateGlobalName(const Name: string;
  out Value: TLocalValue): Boolean;
var
  Rva: UInt64;
  ScopeRva: UInt64;
  // Set when the name resolved to a CALLABLE (a function entry) rather than to
  // a variable. What the user wants then is the routine's ADDRESS, not the
  // machine code stored at it -- see the read below.
  AcceptedCodeEntry: Boolean;

  function TailName(const S: string): string;
  begin
    var P := LastDelimiter('.', S);
    if P > 0 then
      Result := Copy(S, P + 1, MaxInt)
    else
      Result := S;
  end;

  function TryResolveFromGlobalProviders(const Query: string;
    out Sym: TGlobalSymbol): Boolean;

    function LooksLikeCodeSymbol(const N: string): Boolean;
    begin
      // Filter out obvious code/proc names when doing tail matching over
      // globals from mixed providers (MAP/TD32/RSM).
      Result := N.EndsWith('@', True) or
                N.EndsWith('.initialization', True) or
                N.EndsWith('.finalization', True) or
                (Pos('.T', N) > 0);
    end;

  begin
    Result := False;
    Sym := Default(TGlobalSymbol);
    if FDebugInfo = nil then
      Exit;

    // Fast exact path first.
    if FDebugInfo.FindGlobalForRva(ScopeRva, Query, Sym) then begin
      if Sym.RVA <> 0 then
        Exit(True);
      DapLog(Format('EvaluateGlobalName "%s": exact global metadata hit without RVA (Name="%s" TypeHint="%s")',
        [Query, Sym.Name, Sym.TypeHint]));
    end;

    // Unqualified watch (`Globals`) -> try unit-qualified globals
    // (`Oracle.Globals`) by tail-name match.
    if Pos('.', Query) > 0 then
      Exit(False);

    // A SHORT name must not be tail-matched at all. The match is a guess whose
    // collision probability rises as the name shortens, and at one or two
    // characters it is certain to hit something in a large binary.
    //
    // Measured: stopped in the optimised RTL's `TStringList.Find`, whose body
    // locals are register-allocated and absent from the debug info, the local
    // `L` fell through to here and came back as an unrelated global typed
    // `TErrorCorrectionLevel` -- a barcode enum. The correct answer was "not
    // found": nothing can read a register-allocated local.
    //
    // The cost of refusing is that a genuinely short global must be written
    // qualified (`Unit.L`), which the exact path above already handles.
    if Length(Query) < MIN_TAILMATCH_NAME_LEN then begin
      DapLog(Format('EvaluateGlobalName "%s": too short to tail-match a qualified ' +
        'global (min %d) -- refusing rather than guessing',
        [Query, MIN_TAILMATCH_NAME_LEN]));
      Exit(False);
    end;

    var Globals := FDebugInfo.GetGlobalsForRva(ScopeRva);
    var BestIdx := -1;
    var Matches := 0;
    for var I := 0 to High(Globals) do begin
      if Globals[I].RVA = 0 then
        Continue;
      if not SameText(TailName(Globals[I].Name), Query) then
        Continue;
      if LooksLikeCodeSymbol(Globals[I].Name) then
        Continue;
      // Distinct ADDRESSES, not distinct names: the same global reported by
      // two providers is one symbol, and must not read as an ambiguity.
      if (BestIdx < 0) or (Globals[I].RVA <> Globals[BestIdx].RVA) then
        Inc(Matches);
      if (BestIdx < 0) or (Length(Globals[I].Name) < Length(Globals[BestIdx].Name)) then
        BestIdx := I;
    end;

    // Two different globals whose names end the same way: which one the user
    // meant is not knowable, and picking the shortest qualified name was a
    // tie-break dressed as an answer.
    if Matches > 1 then begin
      DapLog(Format('EvaluateGlobalName "%s": %d distinct globals tail-match -- ' +
        'ambiguous, refusing', [Query, Matches]));
      Exit(False);
    end;

    if BestIdx >= 0 then begin
      Sym := Globals[BestIdx];
      Exit(True);
    end;
  end;

  function LooksLikeDataAddress(const VA: UInt64): Boolean;
  begin
    Result := False;
    if (FProcess = 0) or (VA = 0) then
      Exit;

    var Mbi := Default(MEMORY_BASIC_INFORMATION);
    if VirtualQueryEx(FProcess, Pointer(VA), Mbi, SizeOf(Mbi)) <> SizeOf(Mbi) then
      Exit;

    if Mbi.State <> MEM_COMMIT then
      Exit;

    var Prot := Mbi.Protect and not (PAGE_GUARD or PAGE_NOCACHE);
    // Globals are expected in readable/writable data pages; executable-only
    // pages usually indicate we matched a function symbol tail by mistake.
    Result := (Prot = PAGE_READONLY) or
              (Prot = PAGE_READWRITE) or
              (Prot = PAGE_WRITECOPY) or
              (Prot = PAGE_EXECUTE_READWRITE) or
              (Prot = PAGE_EXECUTE_WRITECOPY);
  end;

begin
  Result := False;
  if FDebugInfo = nil then
    Exit;

  ScopeRva := VAToRva(CurrentRIP(FStoppedTid));

  Rva := 0;
  AcceptedCodeEntry := False;
  var GSym := Default(TGlobalSymbol);
  var HaveGSym := False;

  HaveGSym := TryResolveFromGlobalProviders(Name, GSym);
  if HaveGSym then begin
    Rva := GSym.RVA;
    if (Rva = 0) and (GSym.Name <> '') and (not SameText(GSym.Name, Name)) and
       FDebugInfo.NameToRva(GSym.Name, Rva) then begin
      DapLog(Format('EvaluateGlobalName "%s": resolved via canonical global name "%s" -> Rva=$%x',
        [Name, GSym.Name, Rva]));
    end;
  end
  else begin
    // A name confirmed absent at the current provider revision stays absent
    // until a module load changes the provider set (which bumps Revision).
    // VS Code re-evaluates every watch/hover on every stop, so without this the
    // retry window below was paid again for each unresolved watch on each step
    // -- the dominant step-over cost on large multi-module targets. The miss is
    // cached only AFTER the full retry window elapses (at the miss exit below),
    // so a symbol that resolves once background indexing finishes is never
    // cached as missing prematurely.
    var Rev := FDebugInfo.Revision;
    var CachedRev: UInt64;
    if FGlobalMissCache.TryGetValue(LowerCase(Name), CachedRev) and (CachedRev = Rev) then
      Exit; // known-missing at this revision -> immediate miss, skip retry + scan

    // MAP publics parse on a background thread right after a module warm-up, so
    // a name that WILL resolve once that finishes is briefly absent. Retry while
    // ANY provider is still indexing -- and stop the instant nothing is pending,
    // instead of blind-sleeping the whole window. For a genuinely absent name
    // with every index already built (the common case at a warm stop) this
    // returns immediately rather than costing ~5 s per unresolved watch/hover.
    // The 5 s cap is only a safety bound while a background parse is in flight.
    var Deadline := GetTickCount64 + 5000;
    while True do begin
      if FDebugInfo.NameToRva(Name, Rva) then
        Break;
      if not FDebugInfo.AnyBackgroundIndexingPending then
        Break;
      if GetTickCount64 > Deadline then
        Break;
      Sleep(25);
    end;

    if Rva = 0 then begin
      HaveGSym := TryResolveFromGlobalProviders(Name, GSym);
      if HaveGSym then
        Rva := GSym.RVA;
    end;

    // The data-address heuristic below only PREFERS data-resident matches
    // (to avoid mis-matching a function tail when looking for a data global
    // on large mixed-provider binaries). It must not permanently discard a
    // legitimately code-resident exact match -- a proc / method referenced
    // by name (`DoWork`, interface `Name`) lives in an executable page and
    // is the correct symbol. Remember the exact hit and restore it as a
    // last resort if no data candidate exists.
    var ExactRva := Rva;

    if (Rva <> 0) and (not HaveGSym) then begin
      var CandidateVA := RvaToVA(Rva);
      if not LooksLikeDataAddress(CandidateVA) then begin
        DapLog(Format('EvaluateGlobalName "%s": discard non-data candidate Rva=$%x VA=$%x',
          [Name, Rva, CandidateVA]));
        Rva := 0;
      end;
    end;

    if (Rva = 0) and (not HaveGSym) then begin
      for var CandidateRva in FDebugInfo.NameToRvaCandidates(Name) do begin
        var CandidateVA := RvaToVA(CandidateRva);
        if not LooksLikeDataAddress(CandidateVA) then
          Continue;
        Rva := CandidateRva;
        DapLog(Format('EvaluateGlobalName "%s": selected data candidate from multi-provider scan Rva=$%x VA=$%x',
          [Name, Rva, CandidateVA]));
        Break;
      end;
    end;

    // A code-resident exact match used to be restored here as a last resort,
    // and that is how a DATA read ended up serving a CODE address.
    //
    // Measured on `Application` in a bds.exe session: NameToRva answered
    // Rva=$1C38, RvaToVA made that $2D1C38, and the read came back $F8BAE850
    // with no type -- rendered in the UI as a bare pointer. The same watch later
    // in the same session answered `$4295900 (TApplication)` correctly, so the
    // wrong answer is a matter of WHEN it is asked, i.e. of which providers have
    // registered by then. WHICH provider produces $1C38 is not established: a
    // module MAP is shifted into exe-RVA space and range-scoped, so it cannot be
    // vcl290's. That is what the candidate dump below is for.
    //
    // An executability test cannot separate the two cases -- the bad address IS
    // executable, that is the whole problem. Neither can "is it in the main
    // image": $2D1C38 lands inside bds.exe just as a real main-image symbol
    // would. Refusing every code-resident match is wrong too, and measurably so:
    // it broke `Now`, `DoWork` and an interface method's `Name`, which are
    // genuinely code and genuinely what the user asked for.
    //
    // The discriminator that does hold: a callable symbol's address is a
    // FUNCTION ENTRY, and a data global's address never is. The providers answer
    // that directly. For the bogus `Application` the RVA lands in a module with
    // no symbols at all, so there is no function to find and the match is
    // refused; for `Now` it is the entry of a proc the providers know, so it is
    // kept.
    if (Rva = 0) and (ExactRva <> 0) then begin
      var FuncStart: UInt64 := 0;
      if FDebugInfo.RvaToFunctionStart(ExactRva, FuncStart) and
         (FuncStart = ExactRva) then begin
        Rva := ExactRva;
        AcceptedCodeEntry := True;
        DapLog(Format('EvaluateGlobalName "%s": accept code-resident exact match Rva=$%x ' +
          '(no data candidate; it is a function entry)', [Name, Rva]));
      end
      else begin
        DapLog(Format('EvaluateGlobalName "%s": REFUSED code-resident match Rva=$%x VA=$%x ' +
          '-- not a function entry, so it is neither a data global nor a callable symbol',
          [Name, ExactRva, RvaToVA(ExactRva)]));
        // Dump every candidate when the name could not be resolved to anything
        // usable. Knowing which RVAs were on offer -- and how each one classifies
        // -- is what turns "Application came back wrong" into a specific
        // provider, and it costs nothing on the path that already failed.
        for var Cand in FDebugInfo.NameToRvaCandidates(Name) do begin
          var CandVA := RvaToVA(Cand);
          var FS: UInt64 := 0;
          var IsEntry := FDebugInfo.RvaToFunctionStart(Cand, FS) and (FS = Cand);
          var FuncName := '';
          FDebugInfo.RvaToFunctionName(Cand, FuncName);
          DapLog(Format('  candidate Rva=$%x VA=$%x data=%s funcEntry=%s nearest="%s"',
            [Cand, CandVA, BoolToStr(LooksLikeDataAddress(CandVA), True),
             BoolToStr(IsEntry, True), FuncName]));
        end;
      end;
    end;

    if Rva = 0 then begin
      DapLog(Format('EvaluateGlobalName "%s": unresolved (NameToRva + global-provider fallback miss)', [Name]));
      FGlobalMissCache.AddOrSetValue(LowerCase(Name), Rev);
      Exit;
    end;
  end;

  Value := Default(TLocalValue);
  Value.Name      := Name;
  Value.Kind      := lkLocal;
  Value.Address   := RvaToVA(Rva);
  Value.RbpOffset := 0;

  // Pull the type hint from global metadata when available.
  if not HaveGSym then
    HaveGSym := FDebugInfo.FindGlobalForRva(ScopeRva, Name, GSym);
  if (not HaveGSym) and (Pos('.', Name) = 0) then
    HaveGSym := TryResolveFromGlobalProviders(Name, GSym);
  if HaveGSym then
    Value.TypeHint := GSym.TypeHint;

  // Width-aware read (same rule as locals): narrow primitives leave the
  // upper RawValue bytes zeroed instead of folding in the neighbouring
  // global's bytes.
  //
  // With NO type there is no width either, and the fallback is a full pointer's
  // worth. That is how a release build -- a MAP with publics and no embedded
  // debug info, which is a shape real applications ship in -- turned a `Byte`
  // holding 5 into -1091589627: the three following globals were packed at +1,
  // +2 and +4 and got folded into the value, with nothing marking it as
  // unreliable. Bound the read by the distance to the next symbol, which is a
  // fact from the MAP rather than an assumption: two symbols cannot overlap, so
  // whatever lives here ends before the next one starts. On the measured
  // fixture that bound is exactly 1 byte and the answer becomes 5.
  // A CALLABLE is not a variable, so there is nothing at its address to read as
  // a value -- the bytes there are its machine code. Reading them anyway is how
  // a watch on `VCL` came back as 1796744703, which is `FF 25 18 6B`, the first
  // four bytes of an import thunk. Measured in a real 32-bit VCL application.
  //
  // The address IS the answer a debugger should give for a routine name, so
  // report that. Nothing is invented: this branch is only reached because the
  // resolver already established the symbol is a function ENTRY and no data
  // candidate existed.
  if AcceptedCodeEntry and (Value.TypeHint = '') then begin
    Value.TypeHint   := 'Pointer';
    Value.RawValue   := Value.Address;
    Value.ValueValid := True;
    DapLog(Format('EvaluateGlobalName "%s": callable at $%x -- reporting its ADDRESS, ' +
      'not the code stored there', [Name, Value.Address]));
    Exit(True);
  end;

  var ReadCap := 0;
  if Value.TypeHint = '' then
    if not FDebugInfo.MaxSymbolBytesAt(Rva, ReadCap) then
      ReadCap := 0;
  Value.ValueValid := ReadValueSlotRaw(
    function(A: UInt64; Dest: Pointer; Size: Integer): Boolean
    begin
      Result := ReadProcessMemoryAt(A, Dest, Size);
    end,
    Value.Address, Value.TypeHint, TargetLayout.PointerSize, Value.RawValue,
    ReadCap);

  DapLog(Format('EvaluateGlobalName "%s": Rva=$%x VA=$%x Raw=$%x ' +
    'rsmGlobal=%s TypeHint="%s"',
    [Name, Rva, Value.Address, Value.RawValue, BoolToStr(HaveGSym, True),
     Value.TypeHint]));

  Result := True;
end;

function TWinDebugger.EvaluateName(const Name: string;
  out Value: TLocalValue): Boolean;
begin
  // Resolution order: locals (incl. parent-frame short names) -> globals.
  // Callers that need Self.<name> resolution (the expression evaluator) go
  // through the split EvaluateLocalName / EvaluateGlobalName entry points
  // and slot Self.<name> between the two stages.
  Result := EvaluateLocalName(Name, Value) or EvaluateGlobalName(Name, Value);
end;

function TWinDebugger.ReadProcessMemoryAt(VA: UInt64; Buf: Pointer;
  Size: NativeUInt): Boolean;
var
  R: SIZE_T;
begin
  Result := (FProcess <> 0) and
    Winapi.Windows.ReadProcessMemory(FProcess, Pointer(VA), Buf, Size, R) and
    (R = Size);
end;

// See DebugTarget.IDebugTarget.ReadCodeMemoryAt: restores the debugger's own
// planted INT3 bytes within the returned window (docs/DISASSEMBLY_PLAN.md trap 1)
// and truncates at the end of the committed region instead of failing the
// whole request (trap 2). Shared, unchanged, by TWin32Debugger: breakpoint
// planting and FProcess are inherited as-is (only the architecture seam --
// registers, stack walk, prologue decode -- is overridden for x86).
function TWinDebugger.ReadCodeMemoryAt(VA: UInt64; Buf: Pointer;
  Size: NativeUInt): NativeUInt;
var
  AvailInRegion: UInt64;
  ReadLen: NativeUInt;
  BytesRead: SIZE_T;
begin
  Result := 0;
  if (FProcess = 0) or (Size = 0) then
    Exit;
  var Mbi := Default(MEMORY_BASIC_INFORMATION);
  if VirtualQueryEx(FProcess, Pointer(VA), Mbi, SizeOf(Mbi)) <> SizeOf(Mbi) then
    Exit;
  if (Mbi.State <> MEM_COMMIT) or (Mbi.Protect = PAGE_NOACCESS) or
     (Mbi.Protect and PAGE_GUARD <> 0) then
    Exit;

  {$Q-}
  AvailInRegion := (UInt64(Mbi.BaseAddress) + Mbi.RegionSize) - VA;
  {$Q+}
  ReadLen := Size;
  if UInt64(ReadLen) > AvailInRegion then
    ReadLen := AvailInRegion;   // truncate at the region boundary -- trap 2
  if ReadLen = 0 then
    Exit;

  if not Winapi.Windows.ReadProcessMemory(FProcess, Pointer(VA), Buf, ReadLen, BytesRead) then
    Exit;
  Result := BytesRead;

  // Restore any of OUR planted breakpoints inside [VA, VA+Result) -- trap 1.
  for var I := 0 to FBreakpoints.Count - 1 do begin
    var BP := FBreakpoints[I];
    if not BP.IsPlanted then Continue;
    if (BP.VA < VA) or (BP.VA >= VA + Result) then Continue;
    PByte(NativeUInt(Buf) + NativeUInt(BP.VA - VA))^ := BP.OrigByte;
  end;
end;

function TWinDebugger.WriteMemoryAt(VA: UInt64; Buf: Pointer;
  Size: NativeUInt): Boolean;
var
  W: SIZE_T;
  OldProt, Dummy: DWORD;
begin
  if FProcess = 0 then Exit(False);
  // Make the page writable, even if it was read-only.
  VirtualProtectEx(FProcess, Pointer(VA), Size, PAGE_READWRITE, OldProt);
  Result := WriteProcessMemory(FProcess, Pointer(VA), Buf, Size, W) and
    (W = Size);
  VirtualProtectEx(FProcess, Pointer(VA), Size, OldProt, Dummy);
end;

// See IDebugTarget.WriteMemoryPartial: same mechanism as WriteMemoryAt (make
// the page(s) writable, attempt the write, restore protection), but reports
// the actual byte count WriteProcessMemory transferred instead of folding it
// into a Boolean. A separate body rather than WriteMemoryAt re-implemented in
// terms of this one -- WriteMemoryAt's FProcess=0 short-circuit returns False
// unconditionally regardless of Size, which a `Result = Size` wrapper around
// this function would get wrong for Size=0.
function TWinDebugger.WriteMemoryPartial(VA: UInt64; Buf: Pointer;
  Size: NativeUInt): NativeUInt;
var
  W: SIZE_T;
  OldProt, Dummy: DWORD;
begin
  Result := 0;
  if (FProcess = 0) or (Size = 0) then Exit;
  VirtualProtectEx(FProcess, Pointer(VA), Size, PAGE_READWRITE, OldProt);
  W := 0;
  WriteProcessMemory(FProcess, Pointer(VA), Buf, Size, W);
  VirtualProtectEx(FProcess, Pointer(VA), Size, OldProt, Dummy);
  Result := NativeUInt(W);
end;

// Build an immortal Delphi-style string buffer in the debuggee's memory and
// return a pointer to its character buffer (the address that goes into a
// string variable's slot). RefCnt = -1 marks the block as a literal so the
// RTL helpers (e.g. @UStrAsg, @UStrClr) leave it alone.
function TWinDebugger.AllocateRemoteString(const Text, TypeHint: string;
  out Ptr: UInt64): Boolean;
const
  HEADER_SIZE = 12;
var
  ElemSize:  Word;
  CodePage:  Word;
  Bytes:     TBytes;
  CharCount: Integer;
begin
  Result := False;
  Ptr    := 0;
  if FProcess = 0 then
    Exit;

  // A WideString is an OLE BSTR, not a Delphi string: the four bytes before the
  // data are a BYTE count, and there is no code page, element size or refcount
  // header at all. Building a TStrRec here and handing it over as a WideString
  // put the CHARACTER count where the byte count belongs, so reading the value
  // back gave half of it -- `changed-wide` came back as `change`.
  if TypeHint = 'WideString' then begin
    var WideBytes := Length(Text) * 2;
    var BstrSize: NativeUInt := 4 + NativeUInt(WideBytes) + 2;  // len + data + #0#0
    var BstrBase := VirtualAllocEx(FProcess, nil, BstrSize,
                      MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
    if BstrBase = nil then
      Exit;
    var BstrBlock: TBytes;
    SetLength(BstrBlock, BstrSize);
    PInteger(@BstrBlock[0])^ := WideBytes;
    if WideBytes > 0 then
      Move(PChar(Text)^, BstrBlock[4], WideBytes);
    if not WriteMemoryAt(UInt64(BstrBase), @BstrBlock[0], BstrSize) then
      Exit;
    Ptr := UInt64(BstrBase) + 4;
    Exit(True);
  end;

  if (TypeHint = 'AnsiString') or (TypeHint = 'RawByteString') or
     (TypeHint = 'UTF8String') then begin
    ElemSize := 1;
    if TypeHint = 'UTF8String' then
      CodePage := 65001
    else if TypeHint = 'RawByteString' then
      CodePage := 65535
    else
      CodePage := 1252;
    Bytes := TEncoding.GetEncoding(Integer(CodePage)).GetBytes(Text);
    CharCount := Length(Bytes);
  end else begin
    ElemSize  := 2;
    CodePage  := 1200;
    CharCount := Length(Text);
    SetLength(Bytes, CharCount * 2);
    if CharCount > 0 then
      Move(PChar(Text)^, Bytes[0], CharCount * 2);
  end;

  var AllocSize: NativeUInt := HEADER_SIZE + UInt64(CharCount + 1) * ElemSize;
  var Base := VirtualAllocEx(FProcess, nil, AllocSize, MEM_COMMIT or MEM_RESERVE,
    PAGE_READWRITE);
  if Base = nil then
    Exit;

  var Block: TBytes;
  SetLength(Block, AllocSize);
  PWord(@Block[0])^    := CodePage;
  PWord(@Block[2])^    := ElemSize;
  PInteger(@Block[4])^ := -1;        // immortal literal
  PInteger(@Block[8])^ := CharCount;
  if CharCount > 0 then
    Move(Bytes[0], Block[HEADER_SIZE], Length(Bytes));

  if not WriteMemoryAt(UInt64(Base), @Block[0], AllocSize) then
    Exit;
  Ptr    := UInt64(Base) + HEADER_SIZE;
  Result := True;
end;

{ ---------------------------------------------------------------------------
  Synthetic-call ABI. These two are the ONLY calling-convention-aware parts of
  the synthetic-call machinery; the event pump around them is architecture
  neutral and stays shared. A 32-bit target replaces exactly these two: Delphi's
  `register` convention puts the first three arguments in EAX/EDX/ECX with the
  rest pushed right-to-left, has no shadow space, and returns floats on the x87
  stack rather than in an SSE register.
  --------------------------------------------------------------------------- }

// Places a synthetic call frame for POSITIONAL arguments and points the thread
// at FuncVA, with the return address aimed at our INT3 trap page.
function TWinDebugger.PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
  const ArgValues: array of UInt64; const ArgKinds:  array of TSyntheticArgKind;
  const SavedCtx: TContext): Boolean;
var
  CallCtx: TContext;
  IntRegs: array[0..3] of UInt64;  // RCX, RDX, R8, R9 (after arg dispatch)
  XmmRegs: array[0..3] of UInt64;
  Stack:   array of UInt64;        // args 5+ in order
begin
  Result := False;
  // Win64 ABI: argument N (1-based) lands in either an integer register
  // (RCX/RDX/R8/R9) or a float register (XMM0/1/2/3) based on its kind,
  // BUT IN BOTH CASES by POSITION. Args 5+ go to the stack at
  // [RSP+32+(I-4)*8]. We don't overlap int and float regs because Delphi
  // does not use the "shadow" classification trick: each arg position
  // commits exactly one register.
  IntRegs[0] := 0; IntRegs[1] := 0; IntRegs[2] := 0; IntRegs[3] := 0;
  XmmRegs[0] := 0; XmmRegs[1] := 0; XmmRegs[2] := 0; XmmRegs[3] := 0;
  SetLength(Stack, 0);
  // On x64 the WIDTH never matters: every argument occupies one 8-byte slot by
  // position, and the kind only chooses the register file. A Single already
  // arrives as its 4-byte pattern in the low half of the value, which is exactly
  // what the callee reads out of XMM. Extended is a true alias of Double here.
  for var I := 0 to High(ArgValues) do begin
    if I < 4 then begin
      if ArgKinds[I] in [sakSingle, sakDouble, sakExtended] then
        XmmRegs[I] := ArgValues[I]
      else
        IntRegs[I] := ArgValues[I];
    end else
      Stack := Stack + [ArgValues[I]];
  end;

  CallCtx := SavedCtx;
  // RSP: 16-align down, then reserve 32 (shadow) + 8 (ret) + 8*Length(Stack)
  // for stacked args. After the (synthetic) call instruction the callee
  // sees RSP at 8 mod 16, so we mimic that.
  var StackBytes: NativeUInt := 32 + 8 + 8 * NativeUInt(Length(Stack));
  // Round StackBytes up to a multiple of 16 so the post-push RSP stays
  // 8 mod 16 -- strictly we need: (CallCtx.Rsp + 8) mod 16 = 0 after
  // pushing the return address. The align-down + -StackBytes math below
  // achieves that when StackBytes == 8 (mod 16).
  if (StackBytes mod 16) <> 8 then
    Inc(StackBytes, 16 - ((StackBytes - 8) mod 16));
  CallCtx.Rsp := (SavedCtx.Rsp and not UInt64(15)) - StackBytes;
  // Write return address at [RSP].
  if not WriteMemoryAt(CallCtx.Rsp, @FRemoteCallTrap, 8) then Exit;
  // Stacked args: with the return address at [RSP], the callee's 32-byte
  // shadow (home) space is [RSP+8 .. RSP+39], so the 5th argument lives at
  // [RSP+40], the 6th at [RSP+48], ... Writing them at [RSP+32] would land
  // the 5th arg in R9's home slot (clobbered by the callee's own spills)
  // while the callee reads garbage from the real +40 slot.
  for var I := 0 to High(Stack) do
    if not WriteMemoryAt(CallCtx.Rsp + 40 + UInt64(I) * 8, @Stack[I], 8) then Exit;
  CallCtx.Rip := FuncVA;
  CallCtx.Rcx := IntRegs[0]; CallCtx.Rdx := IntRegs[1];
  CallCtx.R8  := IntRegs[2]; CallCtx.R9  := IntRegs[3];
  PUInt64(@CallCtx.Xmm0)^ := XmmRegs[0];
  PUInt64(@CallCtx.Xmm1)^ := XmmRegs[1];
  PUInt64(@CallCtx.Xmm2)^ := XmmRegs[2];
  PUInt64(@CallCtx.Xmm3)^ := XmmRegs[3];
  CallCtx.EFlags := CallCtx.EFlags and (not DWORD($100)); // clear TF
  Result := SetThreadContext(TH, CallCtx);
end;

// Reads the return value out of the thread that has just hit the return trap.
function TWinDebugger.ReadSyntheticCallResult(TH: THandle;
  out IntResult, FloatResultLow: UInt64): Boolean;
var
  PostCtx: TContext;
begin
  IntResult      := 0;
  FloatResultLow := 0;
  PostCtx := Default(TContext);
  PostCtx.ContextFlags := CONTEXT_FULL or CONTEXT_FLOATING_POINT;
  Result := GetThreadContext(TH, PostCtx);
  if not Result then Exit;
  IntResult      := PostCtx.Rax;
  FloatResultLow := PUInt64(@PostCtx.Xmm0)^;
end;

// Hijacks the stopped thread to invoke an RTL helper such as @UStrAsg.
// Saves the thread's context, places a synthetic call (return address points
// to a 0xCC trap page we own), pumps WaitForDebugEvent until that trap fires,
// then restores the original context. While we wait, debug events for other
// threads or unrelated exceptions are passed through unchanged so the
// debuggee doesn't hang.
function TWinDebugger.RunMethodCall(FuncVA: UInt64;
  const ArgValues: array of UInt64; const ArgKinds:  array of TSyntheticArgKind;
  out IntResult, FloatResultLow: UInt64): Boolean;
var
  TH:       THandle;
  SavedCtx: TContext;
  Ev:       TDebugEvent;
begin
  Result    := False;
  IntResult      := 0;
  FloatResultLow := 0;
  // Cleared per call so a caller can never attribute an OLD failure's reason to
  // a new one -- a stale "EAccessViolation" on an unrelated expression would be
  // worse than no reason at all.
  FLastSyntheticCallError := '';
  if Length(ArgValues) <> Length(ArgKinds) then Exit;
  TH := ThreadHandle(FStoppedTid);
  if (TH = 0) or (FProcess = 0) or (FuncVA = 0) then Exit;
  // Stopped on a first-chance exception: the pending debug event must be
  // continued with DBG_EXCEPTION_NOT_HANDLED so the program's own handler
  // runs. A synthetic call would consume that event with DBG_CONTINUE,
  // swallowing the exception and desynchronising FPendingContinueStatus
  // from the trap event it later applies to. Refuse the call instead.
  if FPendingContinueStatus <> DBG_CONTINUE then begin
    DapLog('RunMethodCall: refused while stopped on an exception ' +
      '(pending continue status would be lost)');
    Exit;
  end;

  // Lazy-allocate the INT3 return-trap (same one used by RunRemoteCallEx).
  if FRemoteCallTrap = 0 then begin
    var Trap := VirtualAllocEx(FProcess, nil, 1, MEM_COMMIT or MEM_RESERVE,
      PAGE_EXECUTE_READWRITE);
    if Trap = nil then Exit;
    var Cc: Byte := $CC;
    if not WriteMemoryAt(UInt64(Trap), @Cc, 1) then Exit;
    FRemoteCallTrap := UInt64(Trap);
  end;

  SavedCtx := Default(TContext);
  // CONTEXT_FLOATING_POINT is load-bearing, not defensive. On a 32-bit target
  // the callee returns floats on the x87 stack and the capture stub leaves the
  // value there (popping it is the caller's job by the x87 ABI, and the stub is
  // not the caller). Restoring the FP state below is what discards it. Without
  // that flag every float-returning evaluation leaks one x87 slot and overflows
  // the debuggee's FPU on the eighth -- silently, because ST(0) still reads
  // correctly right up until it wraps.
  SavedCtx.ContextFlags := CONTEXT_FULL or CONTEXT_FLOATING_POINT;
  if not GetThreadContext(TH, SavedCtx) then Exit;

  if not PrepareSyntheticCall(TH, FuncVA, ArgValues, ArgKinds, SavedCtx) then
    Exit;

  ContinueDebugEvent(FProcessId, FStoppedTid, DBG_CONTINUE);
  // Planted breakpoints being skipped inside the injected call:
  // tid -> BP VA whose INT3 is temporarily removed while its real
  // instruction single-steps.
  var PendingSkips := TDictionary<DWORD, UInt64>.Create;
  // Cancellation + watchdog: the injected call may never return to our trap (a
  // getter that blocks on a wait, spins, or enters a message loop). Pump with a
  // short timeout instead of INFINITE; on a user abort request (a control
  // command arrived -- step/continue/pause/disconnect) or the watchdog
  // deadline, force the call thread's RIP to our INT3 trap so the very next
  // event completes the call as a FAILURE rather than hanging the adapter.
  const REMOTE_CALL_TIMEOUT_MS = 8000;
  // A call made INSIDE an auto-call window was not asked for individually, so
  // it gets a budget an order of magnitude smaller: the user is waiting on a
  // panel that renders many rows, not on this one getter. Both numbers live
  // here, together, so the policy is one place to read rather than
  // milliseconds scattered through the layers that request a call.
  const REMOTE_CALL_AUTO_TIMEOUT_MS = 400;
  AtomicExchange(FAbortRemoteCall, 0);
  AtomicExchange(FInRemoteCall, 1);
  var CallDeadline := GetTickCount64 + UInt64(REMOTE_CALL_TIMEOUT_MS);
  if FAutoCallDepth > 0 then begin
    // Whichever runs out first: this call's own reduced budget, or what is left
    // of the window shared by the whole burst.
    CallDeadline := GetTickCount64 + UInt64(REMOTE_CALL_AUTO_TIMEOUT_MS);
    if FAutoCallDeadline < CallDeadline then
      CallDeadline := FAutoCallDeadline;
  end;
  var Aborted := False;
  try
    while True do begin
      if not WaitForDebugEvent(Ev, 100) then begin
        // No debug event this slice. Abort the call if a control command asked
        // us to, or the watchdog expired; if a forced abort already happened
        // and its trap never surfaced, restore and fail hard.
        var WatchdogHit := GetTickCount64 > CallDeadline;
        if (not Aborted) and
           ((AtomicCmpExchange(FAbortRemoteCall, 0, 1) = 1) or WatchdogHit) then begin
          DapLog(Format('RunMethodCall: aborting in-flight call (%s) -> forcing trap',
            [BoolToStr(WatchdogHit, True)]));
          if SuspendThread(TH) <> DWORD(-1) then begin
            var AbCtx := Default(TContext);
            AbCtx.ContextFlags := CONTEXT_CONTROL;
            if GetThreadContext(TH, AbCtx) then begin
              AbCtx.Rip := FRemoteCallTrap;
              SetThreadContext(TH, AbCtx);
            end;
            ResumeThread(TH);
          end;
          Aborted     := True;
          CallDeadline := GetTickCount64 + 2000; // bound the forced-trap window
        end
        else if Aborted and WatchdogHit then begin
          DapLog('RunMethodCall: forced trap did not surface -> hard restore');
          SetThreadContext(TH, SavedCtx);
          Result := False;
          Exit;
        end;
        Continue;
      end;
      if (Ev.dwDebugEventCode = EXCEPTION_DEBUG_EVENT) and
         IsBreakpointExceptionCode(Ev.Exception.ExceptionRecord.ExceptionCode) and
         (UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress) = FRemoteCallTrap) and
         (Ev.dwThreadId = FStoppedTid) then begin
        ReadSyntheticCallResult(TH, IntResult, FloatResultLow);
        SetThreadContext(TH, SavedCtx);
        // When the trap is the one WE forced to abort a hung call, the RAX/XMM0
        // just read are meaningless -- report failure so the caller surfaces
        // `<evaluation cancelled>` rather than a garbage value.
        if Aborted then
          DapLog('RunMethodCall: aborted call reached forced trap -> fail');
        Result := not Aborted;
        Exit;
      end;

      // A planted breakpoint (user BP or transient step BP) fired inside the
      // injected call. Plain DBG_CONTINUE would resume at VA+1 with the 0xCC
      // still in place: the patched-out instruction never executes and the
      // callee corrupts (typically an AV that aborts the watch). Skip the BP
      // transparently instead: restore the original byte, rewind RIP,
      // single-step the real instruction, re-plant, keep pumping. No stop is
      // surfaced (DAP has no nested-stop concept) and HitCount stays
      // untouched -- this is debugger-induced execution, not a program stop.
      if (Ev.dwDebugEventCode = EXCEPTION_DEBUG_EVENT) and
         IsBreakpointExceptionCode(Ev.Exception.ExceptionRecord.ExceptionCode) then begin
        var HitVA := UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress);
        var BpIdx := FindBreakpointByVA(HitVA);
        if (BpIdx >= 0) and FBreakpoints[BpIdx].IsPlanted then begin
          var BP := FBreakpoints[BpIdx];
          RemoveInt3(BP);
          FBreakpoints[BpIdx] := BP;
          SetRIP(Ev.dwThreadId, HitVA);
          SetTrapFlag(Ev.dwThreadId, True);
          PendingSkips.AddOrSetValue(Ev.dwThreadId, HitVA);
          DapLog(Format('RunMethodCall: skipping planted BP at $%x (tid=%d)',
            [HitVA, Ev.dwThreadId]));
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Continue;
        end;
      end;

      // A hardware watchpoint fired while the synthetic call was running. DR6
      // must be sampled before anything else touches this thread's context --
      // docs/TRAPS.md, the ordering that made increment 2's WOW64 measurement
      // observable in the first place -- or the bits leak into the FIRST
      // ordinary step after the call returns, and that step is misread as a
      // watchpoint hit. Increment 4 decision: a watchpoint hit during a
      // synthetic call aborts the call exactly like a raise (the model this
      // whole function already follows) -- silently swallowing it would make
      // code invoked by evaluation behave differently from the same code
      // running normally, and the user's own watchpoint would go unreported.
      if (Ev.dwDebugEventCode = EXCEPTION_DEBUG_EVENT) and
         IsSingleStepExceptionCode(Ev.Exception.ExceptionRecord.ExceptionCode) then begin
        var Trap := TakeDebugTrapCause(Ev.dwThreadId);
        if Trap.FiredSlots <> 0 then begin
          RecordWatchpointHit(Ev.dwThreadId, Trap.FiredSlots,
            UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress));
          DapLog(Format('RunMethodCall: watchpoint fired mid-call (tid=%d addr=$%x) ' +
            '-> aborting', [Ev.dwThreadId, FLastWatchHit.Address]));
          FLastSyntheticCallError := Format(
            'data breakpoint hit during evaluation (thread %d wrote %s)',
            [Ev.dwThreadId, FLastWatchHit.Description]);
          SetThreadContext(TH, SavedCtx);
          Result := False;
          Exit;
        end;
      end;

      // Completion of a BP skip: the real instruction executed, re-plant the
      // INT3 so the breakpoint keeps working for normal execution.
      if (Ev.dwDebugEventCode = EXCEPTION_DEBUG_EVENT) and
         IsSingleStepExceptionCode(Ev.Exception.ExceptionRecord.ExceptionCode) then begin
        var SkipVA: UInt64;
        if PendingSkips.TryGetValue(Ev.dwThreadId, SkipVA) then begin
          PendingSkips.Remove(Ev.dwThreadId);
          SetTrapFlag(Ev.dwThreadId, False);
          var BpIdx := FindBreakpointByVA(SkipVA);
          if BpIdx >= 0 then begin
            var BP := FBreakpoints[BpIdx];
            PlantInt3(BP);
            FBreakpoints[BpIdx] := BP;
          end;
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Continue;
        end;
      end;

      // The injected call raised (or faulted) instead of returning to the
      // trap. Letting it run would unwind PAST our synthetic frame -- the
      // trap is never reached, this loop spins/blocks forever (the watch
      // hangs the whole adapter), and the exception can resume the program
      // from a real up-stack handler, corrupting the stopped state. Abort
      // here while the thread is cleanly stopped at the exception event:
      // restore the pre-call context and report failure, exactly like the
      // success path leaves the debuggee frozen at the original stop.
      // Only genuine faults trigger the abort -- a Delphi raise, an access
      // violation, or any second-chance exception on the call's thread.
      // Benign first-chance noise (e.g. STATUS_GUARD_PAGE_VIOLATION on stack
      // growth) is passed through with DBG_CONTINUE so legitimate calls that
      // touch a guard page still complete.
      if (Ev.dwDebugEventCode = EXCEPTION_DEBUG_EVENT) and
         (Ev.dwThreadId = FStoppedTid) then begin
        var FaultCode := Ev.Exception.ExceptionRecord.ExceptionCode;
        var SecondChance := Ev.Exception.dwFirstChance = 0;
        if (FaultCode = $0EEDFADE) or (FaultCode = EXCEPTION_ACCESS_VIOLATION) or
           SecondChance then begin
          DapLog(Format('RunMethodCall: ABORT fault=0x%.8x secondChance=%s -> fail',
            [FaultCode, BoolToStr(SecondChance, True)]));
          // WHY it failed, captured HERE because this is the only moment it is
          // knowable: the exception record is in hand and the debuggee is still
          // frozen at the fault. A caller that sees only False can say
          // "invocation failed", which tells the user nothing they did not
          // already see.
          FLastSyntheticCallError := '';
          if FaultCode = $0EEDFADE then begin
            var ObjAddr: UInt64 := 0;
            var ExcClass := '';
            if Ev.Exception.ExceptionRecord.NumberParameters >= 2 then begin
              ObjAddr  := Ev.Exception.ExceptionRecord.ExceptionInformation[1];
              ExcClass := ReadDelphiExceptionClass(ObjAddr);
            end;
            if (ExcClass = '') and (Ev.Exception.ExceptionRecord.NumberParameters >= 1) then begin
              ObjAddr  := Ev.Exception.ExceptionRecord.ExceptionInformation[0];
              ExcClass := ReadDelphiExceptionClass(ObjAddr);
            end;
            if ExcClass <> '' then begin
              FLastSyntheticCallError := ExcClass;
              var ExcMsg := ReadDelphiExceptionMessage(ObjAddr);
              if ExcMsg <> '' then
                FLastSyntheticCallError := ExcClass + ': ' + ExcMsg;
            end
            else
              FLastSyntheticCallError := 'a Delphi exception was raised';
          end
          else if FaultCode = EXCEPTION_ACCESS_VIOLATION then
            FLastSyntheticCallError := 'access violation'
          else
            FLastSyntheticCallError :=
              Format('unhandled exception 0x%.8x', [FaultCode]);
          SetThreadContext(TH, SavedCtx);
          Result := False;
          Exit;
        end;
      end;

      // A thread naming itself while the injected call runs: the main dispatch
      // never sees this event, so consume the announcement here too. The event
      // then falls through to the plain DBG_CONTINUE at the bottom, which is
      // exactly the right disposition for it.
      if (Ev.dwDebugEventCode = EXCEPTION_DEBUG_EVENT) and
         (Ev.Exception.ExceptionRecord.ExceptionCode = MS_VC_EXCEPTION) then
        CaptureAnnouncedThreadName(Ev);

      // Track threads born/dying while the call runs so a skip on a brand-new
      // thread can still resolve its handle through ThreadHandle().
      if Ev.dwDebugEventCode = CREATE_THREAD_DEBUG_EVENT then
        FThreads.AddOrSetValue(Ev.dwThreadId, Ev.CreateThread.hThread)
      else if Ev.dwDebugEventCode = EXIT_THREAD_DEBUG_EVENT then begin
        var DeadTH: THandle;
        if FThreads.TryGetValue(Ev.dwThreadId, DeadTH) then begin
          CloseHandle(DeadTH);
          FThreads.Remove(Ev.dwThreadId);
        end;
        FThreadNames.Remove(Ev.dwThreadId);
      end;

      // The injected call exited the whole process: nothing to restore.
      if Ev.dwDebugEventCode = EXIT_PROCESS_DEBUG_EVENT then begin
        Result := False;
        Exit;
      end;

      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    end;
  finally
    // Leaving with a skip still in flight (trap fired on the main thread
    // while another thread was mid-skip): re-plant now. The skipped thread's
    // RIP is still AT the BP, so the re-planted INT3 fires again on resume
    // and the regular BP machinery handles it -- the breakpoint is not lost.
    for var KV in PendingSkips do begin
      var BpIdx := FindBreakpointByVA(KV.Value);
      if BpIdx >= 0 then begin
        var BP := FBreakpoints[BpIdx];
        PlantInt3(BP);
        FBreakpoints[BpIdx] := BP;
      end;
    end;
    PendingSkips.Free;
    AtomicExchange(FInRemoteCall, 0);
  end;
end;

function TWinDebugger.RunRemoteCall(FuncVA: UInt64;
  Arg0, Arg1: UInt64): Boolean;
var
  IntDummy, FloatDummy: UInt64;
begin
  Result := RunRemoteCallEx(FuncVA, Arg0, Arg1, 0, 0, IntDummy, FloatDummy);
end;

function TWinDebugger.RunRemoteCallEx(FuncVA: UInt64;
  Arg0, Arg1, Arg2, Arg3: UInt64; out IntResult, FloatResultLow: UInt64): Boolean;
begin
  // Thin wrapper over RunMethodCall so there is exactly ONE synthetic-call
  // event pump. The historical separate implementation here lacked the
  // abort-on-raise / EXIT_PROCESS handling: a property getter that raised
  // (or exited the process) left WaitForDebugEvent(INFINITE) spinning and
  // hung the whole adapter.
  Result := RunMethodCall(FuncVA, [Arg0, Arg1, Arg2, Arg3],
    [sakOrdinal, sakOrdinal, sakOrdinal, sakOrdinal], IntResult, FloatResultLow);
end;

function TWinDebugger.SetStringVariable(VarAddr: UInt64; const Text, TypeHint: string): Boolean;
var
  HelperName: string;
  HelperRva:  UInt64;
  NewPtr:     UInt64;
begin
  Result := False;
  if (TypeHint = 'UnicodeString') or (TypeHint = 'string') then
    HelperName := '@UStrAsg'
  // A WideString needs its OWN helper. _UStrAsg treats the destination as a
  // refcounted Delphi string and touches a refcount field that a BSTR does not
  // have, writing over the four bytes that ARE its length. _WStrAsg copies the
  // source into a BSTR the RTL allocates itself, which also means the block
  // allocated above is never handed to SysFreeString.
  else if TypeHint = 'WideString' then
    HelperName := '@WStrAsg'
  else if (TypeHint = 'AnsiString') or (TypeHint = 'RawByteString') or
          (TypeHint = 'UTF8String') then
    HelperName := '@LStrAsg'
  else
    Exit; // unsupported string family

  if not FDebugInfo.NameToRva(HelperName, HelperRva) then
    Exit;

  if not AllocateRemoteString(Text, TypeHint, NewPtr) then
    Exit;

  // _UStrAsg(var Dest; const Source). Win64 ABI: RCX = Dest address,
  // RDX = source string handle (pointer to chars).
  Result := RunRemoteCall(RvaToVA(HelperRva), VarAddr, NewPtr);
end;

function TWinDebugger.SetRegisterByName(const Name: string;
  Value: UInt64): Boolean;
var
  Ctx: TContext;
  TH: THandle;
  N: string;
begin
  Result := False;
  TH := ThreadHandle(FStoppedTid);
  if TH = 0 then Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(TH, Ctx) then Exit;
  N := LowerCase(Name);
  // A 3-letter E-spelling on a 64-bit target names the LOW HALF of the
  // register, and a 32-bit write zero-extends into the full 64-bit register on
  // real hardware -- so narrow the value first and then write the whole thing.
  // ("EFlags" is 6 letters and is genuinely 32 bits wide; it is not affected.)
  if (Length(N) = 3) and (N[1] = 'e') then
    Value := DWORD(Value);
  Result := True;
  if      SameRegisterName(N, 'rip') then Ctx.Rip := Value
  else if SameRegisterName(N, 'rsp') then Ctx.Rsp := Value
  else if SameRegisterName(N, 'rbp') then Ctx.Rbp := Value
  else if SameRegisterName(N, 'rax') then Ctx.Rax := Value
  else if SameRegisterName(N, 'rbx') then Ctx.Rbx := Value
  else if SameRegisterName(N, 'rcx') then Ctx.Rcx := Value
  else if SameRegisterName(N, 'rdx') then Ctx.Rdx := Value
  else if SameRegisterName(N, 'rsi') then Ctx.Rsi := Value
  else if SameRegisterName(N, 'rdi') then Ctx.Rdi := Value
  else if N = 'r8'  then Ctx.R8  := Value
  else if N = 'r9'  then Ctx.R9  := Value
  else if N = 'r10' then Ctx.R10 := Value
  else if N = 'r11' then Ctx.R11 := Value
  else if N = 'r12' then Ctx.R12 := Value
  else if N = 'r13' then Ctx.R13 := Value
  else if N = 'r14' then Ctx.R14 := Value
  else if N = 'r15' then Ctx.R15 := Value
  else if N = 'eflags' then Ctx.EFlags := DWORD(Value)
  else
    Result := False;
  if Result then
    Result := SetThreadContext(TH, Ctx);
end;

function TWinDebugger.LookupEnumInfo(const TypeName: string;
  out Info: TRsmEnumInfo): Boolean;
begin
  Result := FDebugInfo.LookupEnumInfo(TypeName, Info);
end;

procedure TWinDebugger.SetExceptionFilters(Filters: TExceptionFilters);
begin
  FExceptionFilters := Filters;
end;

procedure TWinDebugger.SetDelphiClassFilter(const ClassNames: string);
begin
  FDelphiClassFilter := Trim(ClassNames);
end;

procedure TWinDebugger.SetExceptionRules(const Rules: TArray<TExceptionRule>);
begin
  FExceptionRules := Rules;
end;

// The raise site is the first stack frame that maps to a known source unit.
// For a Delphi `raise` the exception record's address points into the RTL, so
// frame 0 is sourceless; for an access violation it is the faulting user
// instruction (frame 0). Walking to the first sourced frame handles both.
function TWinDebugger.RaiseSiteLocation(out UnitName: string; out Line: Integer): Boolean;
begin
  UnitName := '';
  Line     := 0;
  for var F in GetStackFrames do
    if F.SourceFile <> '' then begin
      UnitName := F.SourceFile;
      Line     := F.SourceLine;
      Exit(True);
    end;
  Result := False;
end;

function TWinDebugger.FormatCallStackText: string;
begin
  var SB := TStringBuilder.Create;
  try
    for var F in GetStackFrames do begin
      var Where := F.FunctionName;
      if F.SourceFile <> '' then
        Where := Format('%s (%s:%d)', [F.FunctionName, ExtractFileName(F.SourceFile), F.SourceLine]);
      SB.Append('    ').AppendLine(Where);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// Pump the debug port until the target's EXIT_PROCESS event (or a timeout),
// releasing each intermediate event with DBG_CONTINUE. After a TerminateProcess
// the killed target still holds outstanding debug events; until we consume the
// terminal EXIT_PROCESS the debug object keeps the process alive as a zombie --
// its image section stays mapped and the .exe file stays locked until THIS
// process exits. WaitForDebugEvent is thread-affine: Terminate runs on the same
// thread as Launch/ProcessOneEvent, so this is safe.
procedure TWinDebugger.DrainUntilExit(TimeoutMs: Cardinal);
var
  Ev: TDebugEvent;
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while (not FHasExited) and (GetTickCount64 < Deadline) do begin
    if not WaitForDebugEvent(Ev, 50) then
      Continue;
    if (Ev.dwDebugEventCode = EXIT_PROCESS_DEBUG_EVENT) and
       (Ev.dwProcessId = FProcessId) then begin
      FHasExited := True;
      FRunning   := False;
    end;
    ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
  end;
end;

// Close the target's process/thread handles immediately (do not defer to
// Destroy) and clear them so nothing we hold keeps the terminated kernel object
// alive. Idempotent: safe to call again from Destroy.
procedure TWinDebugger.CloseTargetHandles;
begin
  if FSymInitialized then begin
    SymCleanup(FProcess);
    FSymInitialized := False;
  end;
  for var KV in FThreads do
    CloseHandle(KV.Value);
  FThreads.Clear;
  FThreadNames.Clear;
  if FProcess <> 0 then begin
    CloseHandle(FProcess);
    FProcess := 0;
  end;
end;

procedure TWinDebugger.Terminate;
begin
  if FProcess = 0 then Exit;
  // Attach mode + KillOnDetach=False: detach without killing the target.
  // DebugActiveProcessStop drops the debugger relationship; the target
  // resumes as a normal non-debugged process.
  if FKillOnDetach or (FProcessId = 0) then begin
    TerminateProcess(FProcess, 0);
    // If we are parked on an unacknowledged stop event (the common case: the
    // client disconnects while stopped at a breakpoint), the debug port will NOT
    // deliver any further event -- including the kill's EXIT_PROCESS -- until that
    // event is released. Continue it now so DrainUntilExit can actually observe the
    // exit promptly instead of spinning the whole timeout on every disconnect.
    if FIsStopped and (FStoppedTid <> 0) then begin
      SetTrapFlag(FStoppedTid, False);
      FPendingReactivateVA := 0;
      FIsStopped := False;
      ContinueDebugEvent(FProcessId, FStoppedTid, DBG_CONTINUE);
    end;
    // Consume the kill's debug events so the debug object reaps the process
    // instead of leaving a locked zombie behind (see DrainUntilExit).
    DrainUntilExit(3000);
    // Belt-and-braces: if EXIT_PROCESS never arrived within the timeout,
    // explicitly drop the debug relationship so the target can still be reaped.
    if not FHasExited then
      DebugActiveProcessStop(FProcessId);
    CloseTargetHandles;
    Exit;
  end
  else begin
    // Clean detach. Four things must happen BEFORE DebugActiveProcessStop or
    // the detached target is left in a state no debugger is listening for:
    //   1) Restore every planted INT3 to its original byte.
    //   2) If we are stopped on a held debug event (BP the client never
    //      resumed), release it with DBG_CONTINUE.
    //   3) Clear every armed DR7 slot on every thread -- a detached target
    //      with a watchpoint still armed keeps trapping into a debugger that
    //      is no longer there to catch it.
    //   4) Resume whatever a per-thread step left suspended. Every stop path
    //      thaws through ReportStopped, but a disconnect can arrive with a step
    //      still in flight, and an explicit SuspendThread outlives the detach:
    //      those threads would stay parked forever in a process that carries on
    //      running. Only this branch needs it -- the kill branch above ends the
    //      process, which makes its suspend counts moot.
    ThawStepFrozenThreads;
    if FWatchArmedSlots <> 0 then
      for var Slot := 0 to 3 do
        if FWatchSlots[Slot].InUse then
          ClearDataWatchpoint(Slot);
    for var I := 0 to FBreakpoints.Count - 1 do begin
      var BP := FBreakpoints[I];
      if BP.IsPlanted then begin
        RemoveInt3(BP);
        FBreakpoints[I] := BP;
      end;
    end;
    if FIsStopped and (FStoppedTid <> 0) then begin
      // Clear the trap flag BEFORE the final continue. After a BP hit
      // HandleException sets TF=1 (line ~1097) for the re-arm single-step.
      // Detaching with TF still set leaves the thread armed for a single-step
      // exception ($80000004) the moment it resumes -- with no debugger left to
      // catch it, the RTL surfaces it as External exception 80000004 in a modal
      // dialog and the process hangs (also blocks any later re-attach BPs).
      SetTrapFlag(FStoppedTid, False);
      FPendingReactivateVA := 0;
      FIsStopped := False;
      ContinueDebugEvent(FProcessId, FStoppedTid, DBG_CONTINUE);
    end;
    if not DebugActiveProcessStop(FProcessId) then
      // If detach fails (process already exited, etc.) fall back to terminate.
      TerminateProcess(FProcess, 0);
  end;
  CloseTargetHandles;
end;

{ IDebugTarget event accessors }

function  TWinDebugger.GetOnStopped:     TOnStopped;     begin Result := FOnStopped;     end;
procedure TWinDebugger.SetOnStopped(const V: TOnStopped); begin FOnStopped := V;         end;
function  TWinDebugger.GetOnExited:      TOnExited;      begin Result := FOnExited;      end;
procedure TWinDebugger.SetOnExited(const V: TOnExited);  begin FOnExited := V;           end;
function  TWinDebugger.GetOnOutput:      TOnOutput;      begin Result := FOnOutput;      end;
procedure TWinDebugger.SetOnOutput(const V: TOnOutput);  begin FOnOutput := V;           end;
function  TWinDebugger.GetOnDllLoaded:   TOnDllLoaded;   begin Result := FOnDllLoaded;   end;
procedure TWinDebugger.SetOnDllLoaded(const V: TOnDllLoaded);   begin FOnDllLoaded := V;   end;
function  TWinDebugger.GetOnDllUnloaded: TOnDllUnloaded; begin Result := FOnDllUnloaded; end;
procedure TWinDebugger.SetOnDllUnloaded(const V: TOnDllUnloaded); begin FOnDllUnloaded := V; end;
function  TWinDebugger.GetOnBpHit:       TOnBpHit;       begin Result := FOnBpHit;       end;
procedure TWinDebugger.SetOnBpHit(const V: TOnBpHit);    begin FOnBpHit := V;            end;

function TWinDebugger.ProcessHandle:     THandle; begin Result := FProcess;            end;
function TWinDebugger.ImageBase:         UInt64;  begin Result := FImageBase;          end;
function TWinDebugger.GetStoppedThreadId: DWORD;  begin Result := FStoppedTid;         end;

function TWinDebugger.GetThreadIds: TArray<DWORD>;
begin
  SetLength(Result, FThreads.Count);
  var I := 0;
  for var KV in FThreads do begin
    Result[I] := KV.Key;
    Inc(I);
  end;
  TArray.Sort<DWORD>(Result);
end;

// GetThreadDescription is the Win10 1607+ API for SetThreadDescription
// names. Resolve dynamically so we still load on older Windows where the
// API is absent.
type
  TGetThreadDescription = function(hThread: THandle; out ppszThreadDescription: PWideChar): HRESULT; stdcall;

var
  GGetThreadDescription:  TGetThreadDescription;
  GGetThreadDescResolved: Boolean;

function TryGetThreadDescription(TH: THandle; out Name: string): Boolean;
var
  Buf: PWideChar;
begin
  Result := False;
  Name := '';
  if not GGetThreadDescResolved then begin
    GGetThreadDescResolved := True;
    var H := GetModuleHandleW('kernel32.dll');
    if H <> 0 then
      GGetThreadDescription := TGetThreadDescription(
        GetProcAddress(H, 'GetThreadDescription'));
  end;
  if not Assigned(GGetThreadDescription) then Exit;
  if Succeeded(GGetThreadDescription(TH, Buf)) and (Buf <> nil) then begin
    Name := string(Buf);
    LocalFree(HLOCAL(Buf));
    Result := Name <> '';
  end;
end;

function TWinDebugger.GetThreadName(TID: DWORD): string;
begin
  // A name the thread announced itself (MS_VC_EXCEPTION) wins: it is what the
  // program calls that thread, it is what Delphi code actually sets, and it is
  // available on Windows versions predating SetThreadDescription. Looked up per
  // call, so a name announced after the thread started is reflected by the next
  // threads request.
  if FThreadNames.TryGetValue(TID, Result) and (Result <> '') then
    Exit;
  var TH: THandle;
  if FThreads.TryGetValue(TID, TH) and (TH <> 0) then
    if TryGetThreadDescription(TH, Result) and (Result <> '') then
      Exit;
  if TID = FStoppedTid then
    Result := Format('Thread %d (stopped)', [TID])
  else
    Result := Format('Thread %d', [TID]);
end;
function TWinDebugger.HasExited:         Boolean; begin Result := FHasExited;          end;
function TWinDebugger.LastExceptionDesc: string;     begin Result := FLastExceptionDesc;     end;
function TWinDebugger.LastExceptionClass: string;    begin Result := FLastExceptionClass;    end;
function TWinDebugger.LastExceptionMessage: string;  begin Result := FLastExceptionMessage;  end;
function TWinDebugger.CurrentExceptionObject: UInt64; begin Result := FExceptionObjAddr;       end;

function TWinDebugger.TryResolveExportedRoutine(ModBase: UInt64;
  const ExportName: AnsiString; out VA: UInt64): Boolean;
const
  MAX_EXPORT_NAMES = 200000;   // rtl290.bpl carries ~50 000; well clear of it
var
  // Filled by the bulk read below, before NameAt is ever called.
  NamePtrs: TArray<UInt32>;

  function ReadU16(At: UInt64; out Value: Word): Boolean;
  begin
    Value  := 0;
    Result := ReadProcessMemoryAt(At, @Value, SizeOf(Value));
  end;

  function ReadU32(At: UInt64; out Value: UInt32): Boolean;
  begin
    Value  := 0;
    Result := ReadProcessMemoryAt(At, @Value, SizeOf(Value));
  end;

  function NameAt(Index: Integer): AnsiString;
  var
    Buf: array[0..511] of AnsiChar;
  begin
    Result := '';
    FillChar(Buf, SizeOf(Buf), 0);
    // A short read at the end of a section is normal; the buffer stays
    // zero-filled and the name simply ends where the bytes did.
    if not ReadProcessMemoryAt(ModBase + NamePtrs[Index], @Buf[0], SizeOf(Buf) - 1) then
      Exit;
    Result := AnsiString(PAnsiChar(@Buf[0]));
  end;

begin
  VA     := 0;
  Result := False;
  if ModBase = 0 then Exit;

  var MzSig: Word;
  if not ReadU16(ModBase, MzSig) or (MzSig <> $5A4D) then Exit;
  var NtOff: UInt32;
  if not ReadU32(ModBase + $3C, NtOff) or (NtOff = 0) or (NtOff > $10000) then Exit;
  var PeSig: UInt32;
  if not ReadU32(ModBase + NtOff, PeSig) or (PeSig <> $00004550) then Exit;
  var OptMagic: Word;
  if not ReadU16(ModBase + NtOff + 24, OptMagic) then Exit;
  // The data directories start at a different offset in the optional header
  // for PE32 and PE32+, and a WOW64 target's modules are PE32 while the
  // debugger is not. Read the magic rather than assuming either.
  var DirOff: UInt32;
  case OptMagic of
    $010B: DirOff := NtOff + 24 + 96;
    $020B: DirOff := NtOff + 24 + 112;
  else
    Exit;
  end;
  var ExpRva, ExpSize: UInt32;
  if not ReadU32(ModBase + DirOff, ExpRva) then Exit;
  if not ReadU32(ModBase + DirOff + 4, ExpSize) then Exit;
  if (ExpRva = 0) or (ExpSize = 0) then Exit;

  var NumNames, NamesRva, OrdinalsRva, FunctionsRva: UInt32;
  if not ReadU32(ModBase + ExpRva + 24, NumNames) then Exit;
  if not ReadU32(ModBase + ExpRva + 28, FunctionsRva) then Exit;
  if not ReadU32(ModBase + ExpRva + 32, NamesRva) then Exit;
  if not ReadU32(ModBase + ExpRva + 36, OrdinalsRva) then Exit;
  if (NumNames = 0) or (NumNames > MAX_EXPORT_NAMES) then Exit;

  // One bulk read of the name-pointer array, then a binary search over it: the
  // PE format requires the name table to be sorted, and a 50 000-entry linear
  // scan would be 50 000 cross-process reads.
  SetLength(NamePtrs, NumNames);
  if not ReadProcessMemoryAt(ModBase + NamesRva, @NamePtrs[0],
           NativeUInt(NumNames) * SizeOf(UInt32)) then Exit;

  var Lo := 0;
  var Hi := Integer(NumNames) - 1;
  var Found := -1;
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) div 2;
    var Cmp := CompareStr(string(NameAt(Mid)), string(ExportName));  // ordinal, as the table is sorted
    if Cmp = 0 then begin
      Found := Mid;
      Break;
    end;
    if Cmp < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  if Found < 0 then Exit;

  var Ordinal: Word;
  if not ReadU16(ModBase + OrdinalsRva + UInt64(Found) * 2, Ordinal) then Exit;
  var FuncRva: UInt32;
  if not ReadU32(ModBase + FunctionsRva + UInt64(Ordinal) * 4, FuncRva) then Exit;
  if FuncRva = 0 then Exit;
  // An RVA inside the export directory itself is a FORWARDER string, not code.
  if (FuncRva >= ExpRva) and (FuncRva < ExpRva + ExpSize) then Exit;
  VA     := ModBase + FuncRva;
  Result := True;
end;

function TWinDebugger.ExceptHandlerScopeUnavailableReason: string;
begin
  Result := '';
end;

function TWinDebugger.TryGetHandlerException(out Kind: TExcHandlerBlockKind;
  out ObjVA: UInt64; out Reason: string): Boolean;
const
  // System.ExceptObject returns RaiseListPtr^.ExceptObject for the CALLING
  // thread -- the RTL's own answer to "what is being handled here", pushed by
  // the handler prologue and popped by @DoneExcept. Confirmed against the
  // shipped RTL source (System.pas, TABLE_BASED_EXCEPTIONS branch) and present
  // as a public symbol in both a Win64 and a Win32 Delphi binary.
  //
  // It is read by CALLING it rather than by reading the threadvar, because
  // RaiseListPtr lives in Delphi's own TLS block at an offset the compiler
  // keeps to itself: no symbol carries it, so there is nothing to read.
  EXCEPT_OBJECT_SYMBOL = 'System.ExceptObject';

  // WHICH System.ExceptObject. There can be more than one in a process and
  // they do not share a raise list: an exe that statically links the RTL has
  // its own, and a package that `requires rtl` uses the one in rtl<ver>.bpl.
  // Calling the wrong copy reads an empty raise list and reports, with
  // complete confidence, that nothing is being handled.
  //
  // So: the copy in the MODULE THE HANDLER IS EXECUTING IN wins. When that
  // module has no copy of its own -- the packaged case, where the RTL lives in
  // rtl<ver>.bpl and that binary ships without debug information -- fall back
  // to the export directory, which is the only thing in a stripped package
  // that still names a routine.
  function TryResolveExceptObjectRoutine(PC: UInt64; out FnVA: UInt64;
    out Why: string): Boolean;
  begin
    FnVA   := 0;
    Why    := '';
    Result := False;
    var PcModBase := SymGetModuleBase64(FProcess, PC);

    var Candidates := FDebugInfo.NameToRvaCandidates(EXCEPT_OBJECT_SYMBOL);
    for var Rva in Candidates do begin
      var VA := RvaToVA(Rva);
      if (PcModBase <> 0) and (SymGetModuleBase64(FProcess, VA) <> PcModBase) then
        Continue;
      FnVA := VA;
      Exit(True);
    end;

    var ExportName: AnsiString;
    if TargetLayout.PointerSize = 8 then
      ExportName := '_ZN6System12ExceptObjectEv'
    else
      ExportName := '@System@ExceptObject$qqrv';
    // The handler's own module first, then every other mapped module. In a
    // packaged application exactly one binary exports it, so the order only
    // decides how quickly the search ends.
    if TryResolveExportedRoutine(PcModBase, ExportName, FnVA) then
      Exit(True);
    for var KV in FDllBases do
      if (KV.Value <> PcModBase) and
         TryResolveExportedRoutine(KV.Value, ExportName, FnVA) then
        Exit(True);
    if (FImageBase <> PcModBase) and
       TryResolveExportedRoutine(FImageBase, ExportName, FnVA) then
      Exit(True);

    Why := Format('%s could not be located in the module this handler runs in, ' +
      'nor exported by any module mapped in the target, so the RTL''s own record ' +
      'of the exception being handled cannot be read', [EXCEPT_OBJECT_SYMBOL]);
  end;

begin
  Kind   := ehbNone;
  ObjVA  := 0;
  Reason := '';
  Result := False;
  if FDebugInfo = nil then begin
    Reason := 'no debug information is loaded for this target';
    Exit;
  end;
  // At an exception stop the thread is at the RAISE, not inside a handler, and
  // hijacking it to run a synthetic call there is refused anyway. The exception
  // object of that stop is CurrentExceptionObject's job.
  if StoppedOnUndeliveredException then begin
    Reason := 'the target is stopped ON an exception, not inside a handler';
    Exit;
  end;

  var PC: UInt64 := FActiveFramePC;
  if PC = 0 then begin
    var TH := ThreadHandle(FStoppedTid);
    if TH = 0 then begin
      Reason := 'the stopped thread could not be opened';
      Exit;
    end;
    var Ctx := Default(TContext);
    Ctx.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(TH, Ctx) then begin
      Reason := 'the register context of the stopped thread could not be read';
      Exit;
    end;
    PC := Ctx.Rip;
  end;

  var Blk: TExcHandlerBlock;
  if not TryGetExceptHandlerBlockAt(PC, Blk) then begin
    Reason := ExceptHandlerScopeUnavailableReason;
    if Reason = '' then
      Reason := Format('$%x is not inside an `except` block this debugger can ' +
        'locate in the routine''s exception-dispatch data', [PC]);
    Exit;
  end;
  Kind := Blk.Kind;

  var FnVA: UInt64;
  if not TryResolveExceptObjectRoutine(PC, FnVA, Reason) then
    Exit;

  var IntResult, FloatResult: UInt64;
  if not RunRemoteCallEx(FnVA, 0, 0, 0, 0, IntResult, FloatResult) then begin
    Reason := Format('calling %s in the target failed: %s',
      [EXCEPT_OBJECT_SYMBOL, LastSyntheticCallError]);
    Exit;
  end;
  if IntResult = 0 then begin
    // Inside a handler block and yet no exception on the raise list: the only
    // way that happens is a PC that is genuinely elsewhere (an inlined body,
    // a mis-decoded block). Say so rather than showing a nil object.
    Reason := 'the RTL reports no exception being handled on this thread';
    Exit;
  end;
  ObjVA  := IntResult;
  Result := True;
end;
function TWinDebugger.LastExceptionIsDelphiRaise: Boolean; begin Result := FLastExcIsDelphiRaise; end;

function TWinDebugger.GetSourceLocation(out SourceFile: string;
  out Line: Integer): Boolean;
var
  RIP: UInt64;
  Loc: TSourceLocation;
begin
  SourceFile := '';
  Line       := 0;
  RIP        := CurrentRIP(FStoppedTid);
  Result     := FDebugInfo.RvaToSourceLine(VAToRva(RIP), Loc);
  if Result then begin
    SourceFile := Loc.SourceFile;
    Line       := Loc.Line;
  end;
end;

// Reads the first ~16 bytes of machine code at the given VA and returns the
// stack allocation done by the function prolog. Delphi Win64 uses one of:
//    55 48 83 EC NN                 push rbp; sub rsp, NN     (frame <128)
//    55 48 81 EC NN NN NN NN        push rbp; sub rsp, imm32  (larger frame)
// Returns 0 when the prolog cannot be recognised.
// Returns the value to use in the local-offset formula
//   actual_rbp_offset = (encoded_offset div 2) + ReadFrameSize
// Empirically that value is (N - ExtraPushBytes), where N is the operand of
// `sub rsp, N` in the prologue. When the prologue has no extra `push r64`
// instructions (ExtraPushBytes = 0) this collapses to N -- matching the
// historical behaviour for simple procs. For procs that save callee-preserved
// registers between `push rbp` and `sub rsp` (typical when there are managed
// locals like Variants), ExtraPushBytes > 0 and the subtraction is needed.
function TWinDebugger.ReadFrameSize(EntryVA: UInt64): UInt32;
var
  ExtraBytes: UInt32;
  Recognised: Boolean;
begin
  Result := ReadPrologInfo(EntryVA, ExtraBytes, Recognised);
  if not Recognised then
    Exit(0);
  if Result >= ExtraBytes then
    Dec(Result, ExtraBytes);
end;

const
  // UNWIND_OPCODE values (winnt.h).
  UWOP_PUSH_NONVOL     = 0;
  UWOP_ALLOC_LARGE     = 1;
  UWOP_ALLOC_SMALL     = 2;
  UWOP_SET_FPREG       = 3;
  UWOP_SAVE_NONVOL     = 4;
  UWOP_SAVE_NONVOL_FAR = 5;
  UWOP_SAVE_XMM128     = 8;
  UWOP_SAVE_XMM128_FAR = 9;
  UWOP_PUSH_MACHFRAME  = 10;

// Returns the prolog's stack-allocation size and the cumulative size of
// any non-volatile registers pushed BEFORE the main `sub rsp` (excluding
// rbp itself, which Delphi nested-frame walking handles separately).
//
// Two strategies, in priority order:
//   1. Win64 unwind data via DbgHelp.SymFunctionTableAccess64. Works for
//      any function that emits a `.pdata` entry (every Win64 function
//      by ABI) -- ASM-coded helpers, optimised release builds, non-Delphi
//      compiler output. We honour the UNWIND_INFO opcodes the same way
//      RtlVirtualUnwind would.
//   2. Hand-rolled byte pattern match for the standard Delphi prolog
//      shape (push rbp; [push rXX...]; sub rsp, NN; mov rbp, rsp).
//      Used as a fallback if no unwind data is available.
function TWinDebugger.ReadPrologInfo(EntryVA: UInt64;
  out ExtraPushBytes: UInt32; out Recognised: Boolean): UInt32;

  // Walk UNWIND_INFO + UNWIND_CODE array from debuggee memory at UnwindVA.
  function FromUnwindData(UnwindVA: UInt64; out FrameSize, ExtraPushes: UInt32): Boolean;
  var
    Header: array[0..3] of Byte;
    Codes:  array[0..63] of Word;
    CountOfCodes, I: Integer;
  begin
    Result := False;
    FrameSize := 0;
    ExtraPushes := 0;
    if not ReadProcessMemoryAt(UnwindVA, @Header, 4) then Exit;
    // Header[0] = (Version:3) | (Flags:5); Version must be 1 or 2.
    var Version := Header[0] and 7;
    if (Version <> 1) and (Version <> 2) then Exit;
    CountOfCodes := Header[2];
    if CountOfCodes = 0 then Exit(True);
    if CountOfCodes > 64 then CountOfCodes := 64;
    if not ReadProcessMemoryAt(UnwindVA + 4, @Codes[0], CountOfCodes * 2) then
      Exit;
    I := 0;
    while I < CountOfCodes do begin
      var Slot := Codes[I];
      var Op   := (Slot shr 8) and $0F;
      var Info := (Slot shr 12) and $0F;
      case Op of
        UWOP_PUSH_NONVOL: begin
          // Each push consumes 8 bytes. RBP itself (Info=5) is the
          // frame-pointer register; everything else is an extra push.
          if Info <> 5 then
            Inc(ExtraPushes, 8);
          Inc(I);
        end;
        UWOP_ALLOC_LARGE: begin
          if Info = 0 then begin
            Inc(FrameSize, UInt32(Codes[I + 1]) * 8);
            Inc(I, 2);
          end else begin
            // Info = 1: next two slots form a u32 byte count (no /8 scaling).
            Inc(FrameSize, UInt32(Codes[I + 1]) or
                           (UInt32(Codes[I + 2]) shl 16));
            Inc(I, 3);
          end;
        end;
        UWOP_ALLOC_SMALL: begin
          Inc(FrameSize, UInt32(Info) * 8 + 8);
          Inc(I);
        end;
        UWOP_SET_FPREG, UWOP_PUSH_MACHFRAME:
          Inc(I);
        UWOP_SAVE_NONVOL, UWOP_SAVE_XMM128:
          Inc(I, 2);
        UWOP_SAVE_NONVOL_FAR, UWOP_SAVE_XMM128_FAR:
          Inc(I, 3);
      else
        // Unknown opcode: bail out, fall back to byte-pattern matcher.
        Exit;
      end;
    end;
    Result := True;
  end;

var
  Bytes: array[0..31] of Byte;
  R: SIZE_T;
begin
  Result := 0;
  ExtraPushBytes := 0;
  Recognised := False;

  // Strategy 1: DbgHelp .pdata lookup. Returns nil if SymInitialize never
  // ran or the address is outside any loaded module's function table.
  var RF: PRuntimeFunctionEntry := SymFunctionTableAccess64(FProcess, EntryVA);
  if RF <> nil then begin
    var ImageBase: UInt64 := SymGetModuleBase64(FProcess, EntryVA);
    if ImageBase <> 0 then begin
      var FS, EP: UInt32;
      if FromUnwindData(ImageBase + RF.UnwindInfoAddress, FS, EP) then begin
        Result := FS;
        ExtraPushBytes := EP;
        Recognised := True;
        Exit;
      end;
    end;
  end;

  // Strategy 2: byte-pattern matcher (Delphi-standard prolog shape).
  if not ReadProcessMemory(FProcess, Pointer(EntryVA), @Bytes, SizeOf(Bytes), R) then
    Exit;
  if R < 5 then
    Exit;
  if Bytes[0] <> $55 then // push rbp
    Exit;
  // Skip REX-prefixed push r64 (41 5x: push r8..r15) and plain push r64 (50..57: push rax..rdi).
  var Off: Integer := 1;
  while Off < Integer(R) - 4 do begin
    if (Bytes[Off] >= $50) and (Bytes[Off] <= $57) then begin
      Inc(Off);
      Inc(ExtraPushBytes, 8);
    end else if (Bytes[Off] = $41) and (Bytes[Off + 1] >= $50) and (Bytes[Off + 1] <= $57) then begin
      Inc(Off, 2);
      Inc(ExtraPushBytes, 8);
    end else
      Break;
  end;

  // A frame larger than a page gets a stack-probe loop between the pushes and
  // the real allocation, so `sub rsp` is NOT the next instruction:
  //
  //   B8 <size:u32>        mov eax, <bytes to probe>
  //   48 2D 00 10 00 00    sub rax, 1000h
  //   88 04 04             mov [rsp+rax], al
  //   48 3D <limit:u32>    cmp rax, <limit>
  //   77 EF                ja   (back to the sub)
  //   48 81 EC <size:u32>  sub rsp, N        <- the allocation we actually want
  //
  // The loop is a fixed 22 bytes. Verify its signature at the expected offsets
  // rather than skipping blindly, then continue matching from the far side.
  // Without this the matcher stopped at the `B8` and reported frame size 0 --
  // measured against a routine whose real frame is 16464 bytes.
  if (Off + 22 < Integer(R)) and (Bytes[Off] = $B8) and
     (Bytes[Off + 5] = $48) and (Bytes[Off + 6] = $2D) and
     (Bytes[Off + 11] = $88) and (Bytes[Off + 12] = $04) and (Bytes[Off + 13] = $04) and
     (Bytes[Off + 14] = $48) and (Bytes[Off + 15] = $3D) and
     (Bytes[Off + 20] = $77) and (Bytes[Off + 21] = $EF) then
    Inc(Off, 22);

  if (Off + 3 < Integer(R)) and (Bytes[Off] = $48) and (Bytes[Off + 1] = $83) and (Bytes[Off + 2] = $EC) then begin
    Result := Bytes[Off + 3];
    Recognised := True;
  end else if (Off + 6 < Integer(R)) and (Bytes[Off] = $48) and (Bytes[Off + 1] = $81) and (Bytes[Off + 2] = $EC) then begin
    Result := PUInt32(@Bytes[Off + 3])^;
    Recognised := True;
  end else if (Off + 2 < Integer(R)) and (Bytes[Off] = $48) and (Bytes[Off + 1] = $8B) and (Bytes[Off + 2] = $EC) then begin
    // push rbp; [pushes]; mov rbp,rsp -- a genuine zero-byte local area.
    Result := 0;
    Recognised := True;
  end;
end;

// Returns the VA of the first instruction of the BODY of the function that
// contains VA, i.e. the first address at which the frame is fully established:
// past the UNWIND_INFO prologue AND past the register-argument spills and local
// initialisation the compiler emits before the first statement. Returns 0 when
// the answer cannot be established.
//
// Why this is needed at all: a function's ENTRY address already maps to a source
// line, so "we reached a new source line" is true from the very first instruction
// of a callee -- while RBP still belongs to the CALLER and none of the register
// arguments (RCX/RDX/R8/R9, XMM0..3) have been spilled to their home slots. Every
// [rbp+N] read there -- Self and each by-register parameter -- returns the
// caller's frame bytes, with a correct-looking type and no warning.
//
// The boundary is derived from the binary + the line table, never guessed:
//   * `.pdata`/UNWIND_INFO gives the function's exact extent (BeginAddress /
//     EndAddress) and SizeOfProlog, the compiler-emitted prologue length.
//   * The line table gives the real boundary. SizeOfProlog covers ONLY the
//     unwind-relevant frame setup (push rbp; push regs; sub rsp,N; mov rbp,rsp);
//     Delphi's `mov [rbp+home],rcx` argument spills come AFTER it and are
//     attributed to the routine's `begin` line. So the first address whose line
//     record differs from the ENTRY's line record is the first statement -- which
//     is exactly the address a breakpoint on that statement binds to, and why a
//     breakpoint there always reported correct values.
//
// Degenerate case: a routine written entirely on one line has a single line
// record, so no differing record exists inside it. Then the prologue end is the
// best available answer -- and for a leaf/frameless routine (SizeOfProlog = 0, as
// for a chained UNWIND_INFO) that is the entry itself, so such a routine is still
// reported at its very first instruction.
function TWinDebugger.FunctionBodyStartVA(VA: UInt64): UInt64;
const
  // A compiler-generated entry preamble is a few dozen bytes; the cap only stops
  // a pathological scan and is itself clamped to the function's real extent.
  PREAMBLE_SCAN_LIMIT = 4096;

  function SameLineRecord(const A, B: TSourceLocation): Boolean;
  begin
    if A.Line <> B.Line then
      Exit(False);
    Result := SameText(A.SourceFile, B.SourceFile);
  end;

begin
  Result := 0;
  if VA = 0 then
    Exit;
  EnsureSymInitialized;
  var RF: PRuntimeFunctionEntry := SymFunctionTableAccess64(FProcess, VA);
  if RF = nil then begin
    // No `.pdata` for this address. On a 32-bit target there is none for ANY
    // address, so without this the step-into pivot never ran there at all and
    // a step into a routine parked on its ENTRY -- pre-prologue, where the
    // parameters are still the caller's frame bytes and the stack walk silently
    // drops the immediate caller. Measured on Win32 stepping into GetFortyTwo:
    // the stop was at funcStart+0 (`55 8B EC ...`, the push ebp itself) and the
    // call stack showed RunAllScenarios where RunEvalTests belonged.
    //
    // The line table alone answers the same question -- it is what
    // BreakpointBodyRva already uses for a breakpoint landing on a `begin`.
    var BodyRva := BreakpointBodyRva(VAToRva(VA));
    if BodyRva <> VAToRva(VA) then
      Result := RvaToVA(BodyRva);
    Exit;
  end;
  var ImageBase: UInt64 := SymGetModuleBase64(FProcess, VA);
  if ImageBase = 0 then
    Exit;
  var FuncStart := ImageBase + RF.BeginAddress;
  var FuncEnd   := ImageBase + RF.EndAddress;
  if (VA < FuncStart) or (VA >= FuncEnd) or (FuncEnd <= FuncStart) then
    Exit;

  var EntryLoc: TSourceLocation;
  if not FDebugInfo.RvaToSourceLine(VAToRva(FuncStart), EntryLoc) then
    Exit;

  var Limit := FuncEnd;
  if Limit > FuncStart + PREAMBLE_SCAN_LIMIT then
    Limit := FuncStart + PREAMBLE_SCAN_LIMIT;
  var Scan := FuncStart + 1;
  while Scan < Limit do begin
    var Loc: TSourceLocation;
    if FDebugInfo.RvaToSourceLine(VAToRva(Scan), Loc) and
       not SameLineRecord(Loc, EntryLoc) then
      Exit(Scan);
    Inc(Scan);
  end;

  // One line record covers the whole preamble: fall back to UNWIND_INFO's
  // authoritative prologue length.
  var Header: array[0..3] of Byte;
  if not ReadProcessMemoryAt(ImageBase + RF.UnwindInfoAddress, @Header, 4) then
    Exit;
  var Version := Header[0] and 7;
  if (Version <> 1) and (Version <> 2) then
    Exit;
  Result := FuncStart + Header[1];   // UNWIND_INFO.SizeOfProlog
end;

// Reads a Delphi nested procedure's saved parent-frame pointer. The hidden
// parameter is passed in RCX (Win64 ABI) and Delphi spills it to the home
// slot at RBP + FrameSize + 0x10. Returns 0 if the read fails or the proc
// has no recognisable parent frame pointer.
// Locates an enclosing routine's frame on the CURRENT call stack: the nearest
// frame above the child whose function entry is the parent's.
//
// This is the architecture-independent way to reach a nested procedure's static
// link, and it is why Win32 does not need the hidden-parameter offset measured
// in DevTools\Win32NestedLinkProbe.dpr. Computing that offset means computing
// the byte size of the child's declared stack parameters, and getting it wrong
// does not fail -- it produces a plausible WRONG frame, i.e. confident wrong
// values for every one of the parent's variables. Searching cannot do that: it
// either finds a frame the walker already vouched for, or nothing.
//
// "Above" is by stack address, since the stack grows down and a caller's frame
// is always at a higher address than its callee's. The NEAREST such frame is
// the right one when the parent recurses.
function TWinDebugger.FindParentFrameOnStack(ParentEntryVA, ChildRBP: UInt64): UInt64;
begin
  Result := 0;
  if (ParentEntryVA = 0) or (ChildRBP = 0) then
    Exit;
  for var Frame in GetStackFrames(FStoppedTid) do begin
    if Frame.FuncEntryVA <> ParentEntryVA then
      Continue;
    if (Frame.FrameRBP = 0) or (Frame.FrameRBP <= ChildRBP) then
      Continue;
    if (Result = 0) or (Frame.FrameRBP < Result) then
      Result := Frame.FrameRBP;
  end;
end;

function TWinDebugger.ReadParentFramePointer(
  ChildRBP: UInt64; ChildFrameSize, ChildExtraPushBytes: UInt32): UInt64;
var
  P: UInt64;
begin
  // Layout high -> low after Delphi prolog `push rbp; [push rX...]; sub rsp, N;
  // mov rbp, rsp`:
  //   RBP + N + EP       -> last extra-pushed register (EP = total extra-push bytes)
  //   RBP + N + EP + 8   -> saved RBP
  //   RBP + N + EP + 16  -> caller's RCX home slot (first shadow slot -- Delphi
  //                        stores the parent-frame pointer here for nested procs)
  // (The return address lives 8 bytes above RCX home; it's not what we need.)
  Result := 0;
  if ReadProcessMemoryAt(ChildRBP + ChildFrameSize + ChildExtraPushBytes + 16,
                         @P, 8) then
    Result := P;
end;

// Number of meaningful bytes to read from a local's slot. Narrow primitive
// types (Integer = 4, AnsiChar = 1, ...) leave the upper bytes of the
// destination UInt64 untouched; without this we'd fold stack garbage from
// the high half into Int64-cast displays. Falls back to 8 for any
// pointer-sized / unknown type so existing class/string/Int64 paths work
// unchanged.

// Builds TLocalValue records for one procedure's locals given:
//   FrameRBP    - the value of RBP for that procedure's frame
//   FuncEntryVA - VA of the procedure's first instruction (to read the prolog)
//   FuncName    - simple name used to look up locals in debug info
//   NamePrefix  - optional string prepended to each local's name (e.g. parent.)
// Two distinct STACK locals in one frame cannot share an address. When they do,
// the location data is not real and every one of them reads the same bytes --
// so the values are not merely imprecise, they are fabricated, and they arrive
// with plausible names and types and nothing marking them wrong.
//
// Measured on a 505 MB single-exe build of a real application: stopped in the
// program's MAIN BLOCK, TD32 had no entry for it and RSM's by-name lookup
// answered with 23 locals belonging to an unrelated JSON/RTTI routine, 22 of
// them carrying neither a frame offset nor a register. All 22 rendered the
// saved frame pointer as their value.
//
// Colliding entries are dropped rather than the whole set: an entry with a
// unique address may well be genuine -- the 23rd, at offset -4, was. Which
// member of a colliding group is the real one is not knowable, so none of them
// is kept. REGISTER-allocated locals are exempt: their value is not on the
// frame at all, so sharing a frame address says nothing about them.
//
// A free function so the rule can be tested on its own, without a live process.
function DropAddressCollisions(const Values: TArray<TLocalValue>;
  out Dropped: Integer): TArray<TLocalValue>;
begin
  Result  := nil;
  Dropped := 0;
  for var I := 0 to High(Values) do begin
    var Collides := False;
    if Values[I].RegId = 0 then
      for var J := 0 to High(Values) do
        if (J <> I) and (Values[J].RegId = 0) and
           (Values[J].Address = Values[I].Address) then begin
          Collides := True;
          Break;
        end;
    if Collides then
      Inc(Dropped)
    else
      Result := Result + [Values[I]];
  end;
end;

function TWinDebugger.CollectLocalsForFrame(FrameRBP: UInt64;
  FuncEntryVA: UInt64; const FuncName, NamePrefix: string;
  FramePcRva: UInt64): TArray<TLocalValue>;

  // Width of a local's lexical-block scope; 0/0 (function-wide) = widest.
  function BlockWidth(const S: TLocalSymbol): UInt64;
  begin
    if S.BlockEndRva = 0 then Exit(High(UInt64));
    Result := S.BlockEndRva - S.BlockStartRva;
  end;

var
  Locals: TArray<TLocalSymbol>;
  Widths: TArray<UInt64>;     // parallel to Result: each kept local's scope width
begin
  SetLength(Result, 0);
  var FuncRva := VAToRva(FuncEntryVA);
  if not FDebugInfo.GetLocalsForFunctionByRva(FuncRva, FuncName, Locals) then
    Exit;
  // Decode RSM-encoded RBP offsets:
  //   actual_rbp_offset = SAR(encoded, 1) + base
  // where base depends on whether the symbol lives below RBP (locals) or
  // above (parameters in shadow space):
  //   locals  (encoded negative)  -> base = floor(N / 16) * 16
  //   params  (encoded positive)  -> base = N + ExtraPushBytes
  // N is the `sub rsp, N` operand; ExtraPushBytes is the total of extra
  // `push r64` instructions between `push rbp` and `sub rsp`.
  // The "round N down to a multiple of 16" rule for locals reflects the
  // 8-byte alignment padding Delphi inserts at the top of the locals area
  // when (1 + ExtraPushCount) is even (i.e. N mod 16 = 8). For odd push
  // counts the locals area is already 16-aligned and the base is just N.
  // Empirically validated on procs with EP = 0 / 8 / 16. The earlier
  // "N - ExtraPushBytes" formula only worked by coincidence when EP = 8;
  // procs with EP >= 16 (e.g. RunVariantTests once the test target grew
  // a third saved register) read locals 16 bytes too low and surfaced
  // Variants as `<nil VarArray>`.
  var ExtraPushBytes: UInt32;
  var PrologRecognised: Boolean;
  var SubRspN := ReadPrologInfo(FuncEntryVA, ExtraPushBytes, PrologRecognised);
  // Every local address below is anchored on the frame size. If the prologue
  // was not understood, reporting locals would mean reporting whatever happens
  // to sit at the guessed offsets -- report none instead.
  if not PrologRecognised then
    Exit(nil);
  var LocalsBase := LocalsOffsetBase(SubRspN, ExtraPushBytes);
  var ParamsBase := ParamsOffsetBase(SubRspN, ExtraPushBytes);
  for var Sym in Locals do begin
    // Lexical-block scoping: a block-local (BlockEndRva<>0) is live only when
    // the frame PC is inside its [start,end) range. This hides not-yet-declared
    // / out-of-scope inline vars and disambiguates same-named inline vars in
    // sibling blocks. FramePcRva=0 disables filtering (callers without a PC,
    // e.g. enclosing-proc frames in the nesting climb).
    if (FramePcRva <> 0) and (Sym.BlockEndRva <> 0) and
       not ((FramePcRva >= Sym.BlockStartRva) and (FramePcRva < Sym.BlockEndRva)) then
      Continue;
    var V: TLocalValue;
    V.Name       := NamePrefix + Sym.Name;
    V.TypeHint    := Sym.TypeHint;
    V.TypeKind    := Sym.TypeKind;
    V.PointeeKind := Sym.PointeeKind;
    V.ParamStatus := Sym.ParamStatus;
    V.Kind        := Sym.Kind;
    V.RawValue   := 0;
    V.ValueValid := False;
    V.DerefValue := 0;
    V.DerefValid := False;
    V.RegId      := Sym.RegId;
    // Win64 ABI: every Variant parameter is passed by reference (24-byte
    // TVarData doesn't fit a register). RSM / TD32 still tag the symbol
    // as lkLocal -- promote it here so the rest of the adapter treats
    // the slot as a pointer-to-value (DerefValue path) and the Variant
    // formatter reads TVarData through the pointer. Applies only to
    // parameters (positive Sym.RbpOffset); in-body Variant locals
    // remain inline lkLocal.
    if (Sym.Kind = lkLocal) and (Sym.RbpOffset >= 0) and
       (SameText(Sym.TypeHint, 'Variant') or
        SameText(Sym.TypeHint, 'OleVariant') or
        SameText(Sym.TypeHint, 'TVarData')) then
      V.Kind := lkVarParam;
    // TD32 emits `out`/`var` parameters as `^Primitive` (pointer to the
    // caller's slot). Treat them as lkVarParam so the value is read
    // through the pointer instead of surfacing the address as an
    // integer. Restricted to pointer-to-primitive shapes -- class-typed
    // pointers / records keep their own formatting path.
    if (Sym.Kind = lkLocal) and (Sym.RbpOffset >= 0) and
       (Length(Sym.TypeHint) >= 2) and (Sym.TypeHint[1] = '^') then begin
      var Tail := Copy(Sym.TypeHint, 2, MaxInt);
      if SameText(Tail, 'Integer')  or SameText(Tail, 'Cardinal') or
         SameText(Tail, 'LongInt')  or SameText(Tail, 'LongWord') or
         SameText(Tail, 'Int32')    or SameText(Tail, 'UInt32')   or
         SameText(Tail, 'SmallInt') or SameText(Tail, 'Word')     or
         SameText(Tail, 'Int16')    or SameText(Tail, 'UInt16')   or
         SameText(Tail, 'Byte')     or SameText(Tail, 'ShortInt') or
         SameText(Tail, 'Int64')    or SameText(Tail, 'UInt64')   or
         SameText(Tail, 'Single')   or SameText(Tail, 'Double')   or
         SameText(Tail, 'Boolean')  or SameText(Tail, 'Char')     or
         SameText(Tail, 'AnsiChar') or SameText(Tail, 'WideChar') then
        V.Kind := lkVarParam;
    end;
    // Register-allocated locals: the variable lives in a CPU register at
    // this program point, not at an RBP offset. Resolve the value from
    // the current thread's register snapshot. Borland Athens 36 emits
    // Microsoft CV register codes ($11..$18 for the 32-bit subregs,
    // $148..$157 for the 64-bit Win64 register file). Codes outside
    // those ranges are surfaced with Address=0 and ValueValid=False so
    // the formatter prints `<register $%x>` rather than a wrong value.
    if Sym.RegId > 0 then begin
      V.RbpOffset := 0;
      V.Address   := 0;
      var Regs := GetRegisters;
      if Regs.Valid then begin
        var Full: UInt64 := 0;
        var Hit := True;
        case Sym.RegId of
          // Win64 CV register codes ($148..$157 for RAX..R15)
          $148: Full := Regs.Rax;
          $149: Full := Regs.Rcx;
          $14A: Full := Regs.Rdx;
          $14B: Full := Regs.Rbx;
          $14C: Full := Regs.Rsp;
          $14D: Full := Regs.Rbp;
          $14E: Full := Regs.Rsi;
          $14F: Full := Regs.Rdi;
          $150: Full := Regs.R8;
          $151: Full := Regs.R9;
          $152: Full := Regs.R10;
          $153: Full := Regs.R11;
          $154: Full := Regs.R12;
          $155: Full := Regs.R13;
          $156: Full := Regs.R14;
          $157: Full := Regs.R15;
          // 32-bit subregs ($11..$18)
          $11: Full := Regs.Rax and $FFFFFFFF;
          $12: Full := Regs.Rcx and $FFFFFFFF;
          $13: Full := Regs.Rdx and $FFFFFFFF;
          $14: Full := Regs.Rbx and $FFFFFFFF;
          $15: Full := Regs.Rsp and $FFFFFFFF;
          $16: Full := Regs.Rbp and $FFFFFFFF;
          $17: Full := Regs.Rsi and $FFFFFFFF;
          $18: Full := Regs.Rdi and $FFFFFFFF;
        else
          Hit := False;
        end;
        if Hit then begin
          V.RawValue   := Full;
          V.ValueValid := True;
        end;
      end;
      Result := Result + [V];
      Continue;
    end;
    // Sym.RbpOffset arrives already SAR-decoded by the RSM reader (see
    // ReadVleOffset). It is the signed displacement RELATIVE TO a per-direction
    // base: locals (negative displacements) anchor to N - ExtraPushBytes;
    // parameters (positive displacements, addressed in the caller's shadow
    // space above the prologue saves) anchor to N + ExtraPushBytes.
    // TD32 (and TYPEREF_MARKER_MAIN RSM locals) bypass that encoding entirely:
    // the BPREL32 ($0200) offset is already the literal RBP-relative
    // displacement, so the per-direction base must NOT be added or every
    // local lands at the wrong address (observed inside class-method
    // nested procs in SampleApp -- e.g. Integer 1 surfacing as -116 because
    // SubRspN was being folded into a slot that did not need it).
    if Sym.UseDirectOffset then
      V.RbpOffset := Sym.RbpOffset
    else if Sym.RbpOffset >= 0 then
      V.RbpOffset := Sym.RbpOffset + ParamsBase
    else
      V.RbpOffset := Sym.RbpOffset + LocalsBase;
    // Add a signed offset to an unsigned base without tripping {$Q+}.
    // UInt64(Int64(negative)) raises EIntOverflow because the negative
    // value cannot be represented as a UInt64. Branch on the sign instead.
    if V.RbpOffset >= 0 then
      V.Address := FrameRBP + UInt64(V.RbpOffset)
    else
      V.Address := FrameRBP - UInt64(-V.RbpOffset);
    DapLog(Format('  CL "%s/%s" SymOff=%d N=%d EP=%d ParamsBase=%d LocalsBase=%d decoded=%d FrameRBP=$%x addr=$%x TypeId=$%x TypeHint="%s"',
      [FuncName, Sym.Name, Sym.RbpOffset, SubRspN, ExtraPushBytes, ParamsBase, LocalsBase, V.RbpOffset, FrameRBP, V.Address, Sym.TypeId, Sym.TypeHint]));
    // Size-aware read: narrow types (Integer = 4, Byte = 1, ...) leave the
    // upper bytes of V.RawValue at zero so the formatter doesn't fold
    // stack garbage into Int64-cast displays of declared 4-byte values.
    V.RawValue := 0;
    if ReadValueSlotRaw(
         function(A: UInt64; Dest: Pointer; Size: Integer): Boolean
         begin
           Result := ReadProcessMemoryAt(A, Dest, Size);
         end,
         V.Address, Sym.TypeHint, TargetLayout.PointerSize, V.RawValue) then begin
      V.ValueValid := True;
      // A var parameter's slot holds a pointer to the caller's storage, so this
      // reads the POINTEE -- at the POINTEE's width, which is not the pointer's.
      // Debug info types such a parameter `^Integer`, so sizing the read by that
      // name would read eight bytes for a four-byte Integer and fold the
      // neighbouring word into the high half, which is how `AResult` displayed
      // as -865266791511752704.
      var PointeeType := Sym.TypeHint;
      if (Length(PointeeType) >= 2) and (PointeeType[1] = '^') then
        PointeeType := Copy(PointeeType, 2, MaxInt);
      V.DerefValue := 0;
      if (V.Kind = lkVarParam) and (V.RawValue <> 0) and
         ReadProcessMemoryAt(V.RawValue, @V.DerefValue,
           LocalReadSize(PointeeType, TargetLayout.PointerSize)) then
        V.DerefValid := True;
    end;
    // Innermost-wins dedup: with nested blocks both containing the PC, a
    // same-named inner declaration shadows the outer one. Keep the narrower
    // scope. (Sibling blocks are already disjoint, so only one survives the
    // PC filter above -- this only matters for true nesting.)
    var W := BlockWidth(Sym);
    var Replaced := False;
    for var K := 0 to High(Result) do
      if SameText(Result[K].Name, V.Name) then begin
        if W < Widths[K] then begin
          Result[K] := V;
          Widths[K] := W;
        end;
        Replaced := True;
        Break;
      end;
    if not Replaced then begin
      Result := Result + [V];
      Widths := Widths + [W];
    end;
  end;

  // Two distinct stack locals in ONE frame cannot share an address. When they
  // do, the location data is not real and every one of them reads the same
  // bytes -- so the values are not merely imprecise, they are fabricated.
  //
  // Measured on a 505 MB single-exe: stopped in the program's MAIN BLOCK, TD32
  // had no entry for it and RSM's by-name lookup returned 23 locals belonging
  // to an unrelated JSON/RTTI routine, 22 of them with neither a frame offset
  // nor a register. All 22 rendered the saved frame pointer as their value,
  // with plausible names and types and nothing marking them wrong.
  //
  // Colliding entries are dropped rather than the whole set: an entry with a
  // unique address may well be genuine (the 23rd, at offset -4, was). Which
  // member of a colliding group is the real one is not knowable, so none is
  // kept. Register-allocated locals are exempt -- their value is not on the
  // frame, so sharing offset 0 says nothing about them.
  var Dropped := 0;
  var Kept := DropAddressCollisions(Result, Dropped);
  if Dropped > 0 then begin
    DapLog(Format('CollectLocalsForFrame("%s"): dropped %d of %d local(s) sharing ' +
      'a frame address -- the debug info gave them no distinct location',
      [FuncName, Dropped, Length(Result)]));
    Result := Kept;
  end;
end;

function TWinDebugger.TryGetExceptHandlerBlockAt(PC: UInt64;
  out Blk: TExcHandlerBlock): Boolean;
const
  UNW_FLAG_EHANDLER  = $01;
  UNW_FLAG_UHANDLER  = $02;
  UNW_FLAG_CHAININFO = $04;
  MAX_CHAIN_DEPTH    = 4;
  MAX_SCOPE_ENTRIES  = 256;
  MAX_CLAUSES        = 64;
type
  // One { Begin, End, Handler, Target } row of Delphi's MSVC-shaped scope
  // table, kept as read so the block search below can consult all of them.
  TScopeRow = record
    BeginRva, EndRva, Handler, Target: UInt32;
  end;
  // A block address the table names, before it is known whether PC is in it.
  TCandidate = record
    Kind:        TExcHandlerBlockKind;
    StartRva:    UInt32;
    ClassVmtRva: UInt32;
  end;
var
  ModBase:    UInt64;
  Rows:       TArray<TScopeRow>;
  Candidates: TArray<TCandidate>;

  function ReadU32At(VA: UInt64; out Value: UInt32): Boolean;
  begin
    Value  := 0;
    Result := ReadProcessMemoryAt(VA, @Value, SizeOf(Value));
  end;

  procedure AddCandidate(Kind: TExcHandlerBlockKind; StartRva, ClassVmtRva: UInt32);
  begin
    if StartRva = 0 then Exit;
    for var Existing in Candidates do
      if Existing.StartRva = StartRva then Exit;
    var C: TCandidate;
    C.Kind        := Kind;
    C.StartRva    := StartRva;
    C.ClassVmtRva := ClassVmtRva;
    Candidates := Candidates + [C];
  end;

  // DWORD Count; Count x { DWORD ClassVmtRva; DWORD BlockRva } -- one entry per
  // `on <Class> do` clause of a single `except`.
  procedure LoadClauseTable(TableRva: UInt32);
  begin
    var Count: UInt32;
    if not ReadU32At(ModBase + TableRva, Count) then Exit;
    if (Count = 0) or (Count > MAX_CLAUSES) then Exit;
    for var I := 0 to Integer(Count) - 1 do begin
      var Pair: array[0..1] of UInt32;
      if not ReadProcessMemoryAt(ModBase + TableRva + 4 + UInt64(I) * 8,
               @Pair[0], SizeOf(Pair)) then Exit;
      AddCandidate(ehbOnClause, Pair[1], Pair[0]);
    end;
  end;

  function LoadScopeTable(TableRva, FuncBeginRva, FuncEndRva: UInt32): Boolean;
  begin
    Result := False;
    var Count: UInt32;
    if not ReadU32At(ModBase + TableRva, Count) then Exit;
    if (Count = 0) or (Count > MAX_SCOPE_ENTRIES) then Exit;
    for var I := 0 to Integer(Count) - 1 do begin
      var E: array[0..3] of UInt32;
      if not ReadProcessMemoryAt(ModBase + TableRva + 4 + UInt64(I) * 16,
               @E[0], SizeOf(E)) then Exit;
      // The same shape check PlanExceptionStep applies: a protected range that
      // is not inside the routine means this is not the table it looks like,
      // and decoding on would produce confident nonsense.
      if (E[0] >= E[1]) or (E[0] < FuncBeginRva) or (E[1] > FuncEndRva) then Exit;
      var Row: TScopeRow;
      Row.BeginRva := E[0];
      Row.EndRva   := E[1];
      Row.Handler  := E[2];
      Row.Target   := E[3];
      Rows := Rows + [Row];
      if E[2] = 0 then
        Continue                                 // try .. finally: not a handler
      else if E[2] <= 2 then
        AddCandidate(ehbBareExcept, E[3], 0)     // Handler is a flag, Target the block
      else begin
        LoadClauseTable(E[2]);
        // Some entries carry BOTH a clause table and a Target block.
        if E[3] <> 0 then
          AddCandidate(ehbBareExcept, E[3], 0);
      end;
    end;
    Result := True;
  end;

  function LoadFromUnwindInfo(UnwindRva, FuncBeginRva, FuncEndRva: UInt32;
    Depth: Integer): Boolean;
  begin
    Result := False;
    if Depth > MAX_CHAIN_DEPTH then Exit;
    var Hdr: array[0..3] of Byte;
    if not ReadProcessMemoryAt(ModBase + UnwindRva, @Hdr[0], SizeOf(Hdr)) then Exit;
    var Version := Hdr[0] and 7;
    if (Version <> 1) and (Version <> 2) then Exit;
    var Flags   := Hdr[0] shr 3;
    // The UNWIND_CODE array is padded to an EVEN number of 2-byte slots.
    var Slots   := (Integer(Hdr[2]) + 1) and not 1;
    var TailRva := UnwindRva + 4 + UInt32(Slots) * 2;

    if (Flags and (UNW_FLAG_EHANDLER or UNW_FLAG_UHANDLER)) <> 0 then begin
      var HandlerRva: UInt32;
      if not ReadU32At(ModBase + TailRva, HandlerRva) then Exit;
      // Under MSVC's __C_specific_handler the same field is a FILTER function,
      // not a Delphi scope table, and every ntdll / kernelbase frame is one.
      var HandlerName := '';
      if FDebugInfo <> nil then
        FDebugInfo.RvaToFunctionName(VAToRva(ModBase + HandlerRva), HandlerName);
      if not ContainsText(HandlerName, 'DelphiExceptionHandler') then Exit;
      Exit(LoadScopeTable(TailRva + 4, FuncBeginRva, FuncEndRva));
    end;

    if (Flags and UNW_FLAG_CHAININFO) <> 0 then begin
      var Chained: TRuntimeFunctionEntry;
      if not ReadProcessMemoryAt(ModBase + TailRva, @Chained, SizeOf(Chained)) then Exit;
      Exit(LoadFromUnwindInfo(Chained.UnwindInfoAddress,
        Chained.BeginAddress, Chained.EndAddress, Depth + 1));
    end;
    // No handler and no chain: this routine has no except block at all.
  end;

  // dcc wraps every handler BODY in a compiler-generated try .. finally -- it is
  // what calls System.@DoneExcept -- so the block's extent is the narrowest
  // protected range covering the byte AFTER the block starts. Measured on
  // Debugme's main block: the `on E:` block at $2FCCE is covered by
  // [$2FCCE, $2FD6F) and the bare block at $2FD90 by [$2FD91, $2FDF7).
  //
  // Taking the byte after the start is what makes the bare form work: its block
  // address is the PREVIOUS entry's exclusive End, so the block address itself
  // is not inside the wrapping range.
  function NarrowestRangeCovering(Rva: UInt32; out EndRva: UInt32): Boolean;
  begin
    Result := False;
    EndRva := 0;
    var BestWidth: UInt32 := 0;
    for var Row in Rows do begin
      if (Rva < Row.BeginRva) or (Rva >= Row.EndRva) then Continue;
      var Width := Row.EndRva - Row.BeginRva;
      if (not Result) or (Width < BestWidth) then begin
        Result    := True;
        BestWidth := Width;
        EndRva    := Row.EndRva;
      end;
    end;
  end;

begin
  Blk    := Default(TExcHandlerBlock);
  Result := False;
  if (PC = 0) or (FProcess = 0) then Exit;
  EnsureSymInitialized;
  var RF: PRuntimeFunctionEntry := SymFunctionTableAccess64(FProcess, PC);
  if RF = nil then Exit;
  ModBase := SymGetModuleBase64(FProcess, PC);
  if ModBase = 0 then Exit;
  Rows       := nil;
  Candidates := nil;
  if not LoadFromUnwindInfo(RF.UnwindInfoAddress, RF.BeginAddress,
           RF.EndAddress, 0) then Exit;

  var PcRva := UInt32(PC - ModBase);
  var BestWidth: UInt32 := 0;
  for var Cand in Candidates do begin
    if PcRva < Cand.StartRva then Continue;
    var EndRva: UInt32;
    // No wrapping range means the block's end is not derivable. Decline rather
    // than stretch it to the end of the routine: a handler alias that lingers
    // past its own block is exactly the confidently-wrong answer this exists
    // to avoid.
    if not NarrowestRangeCovering(Cand.StartRva + 1, EndRva) then Continue;
    if PcRva >= EndRva then Continue;
    var Width := EndRva - Cand.StartRva;
    if Result and (Width >= BestWidth) then Continue;   // keep the innermost
    Result    := True;
    BestWidth := Width;
    Blk.Kind    := Cand.Kind;
    Blk.StartVA := ModBase + Cand.StartRva;
    Blk.EndVA   := ModBase + EndRva;
    if Cand.ClassVmtRva <> 0 then
      Blk.ClassVmtVA := ModBase + Cand.ClassVmtRva
    else
      Blk.ClassVmtVA := 0;
  end;
end;

function TWinDebugger.TryGetHandlerAliasLocal(PC: UInt64;
  out LV: TLocalValue): Boolean;
const
  // `mov [rip+disp32], rax` -- the alias lives in a module-level static, which
  // is what dcc emits for a handler in the program main block. Measured on
  // Debugme.dpr:102 -> `48 89 05 F3 52 01 00`, storing into the LDATA32 `E`.
  // A `48 89 45 xx` / `48 89 85 xx xx xx xx` (`mov [rbp+disp], rax`) says the
  // alias is an ordinary stack local, which every symbol reader already lists,
  // so there is nothing to synthesise for it.
  MOV_RIPREL_RAX: array[0..2] of Byte = ($48, $89, $05);
  MOV_RIPREL_LEN = 7;
begin
  LV     := Default(TLocalValue);
  Result := False;
  if FDebugInfo = nil then Exit;
  var Blk: TExcHandlerBlock;
  if not TryGetExceptHandlerBlockAt(PC, Blk) then Exit;
  if Blk.Kind <> ehbOnClause then Exit;

  var Code: array[0 .. MOV_RIPREL_LEN - 1] of Byte;
  if not ReadProcessMemoryAt(Blk.StartVA, @Code[0], SizeOf(Code)) then Exit;
  for var I := Low(MOV_RIPREL_RAX) to High(MOV_RIPREL_RAX) do
    if Code[I] <> MOV_RIPREL_RAX[I] then Exit;
  // Until that store has retired the slot still holds whatever the previous
  // handler left in it. Standing on the `on` line itself is therefore outside
  // the alias's real lifetime, not merely early in it.
  if PC < Blk.StartVA + MOV_RIPREL_LEN then Exit;

  var Disp   := PInteger(@Code[3])^;
  var SlotVA := UInt64(Int64(Blk.StartVA) + MOV_RIPREL_LEN + Disp);
  var Sym: TGlobalSymbol;
  if not FDebugInfo.TryGetGlobalAtRva(VAToRva(SlotVA), Sym) then Exit;
  if Sym.Name = '' then Exit;

  LV.Name        := Sym.Name;
  LV.TypeHint    := Sym.TypeHint;
  LV.Address     := SlotVA;
  LV.Kind        := lkLocal;
  LV.ParamStatus := spsLocal;
  LV.RawValue    := 0;
  if ReadProcessMemoryAt(SlotVA, @LV.RawValue, TargetLayout.PointerSize) then
    LV.ValueValid := True;
  DapLog(Format('exception alias "%s" (%s) at $%x, live for the `on` block $%x..$%x',
    [LV.Name, LV.TypeHint, SlotVA, Blk.StartVA, Blk.EndVA]));
  Result := True;
end;

function TWinDebugger.GetLocalValuesForFrame(FrameRBP, FuncEntryVA: UInt64;
  const FuncName: string; FramePcRva: UInt64): TArray<TLocalValue>;

  // True when Name is already among the locals collected for this frame.
  function AlreadyListed(const Values: TArray<TLocalValue>;
    const Name: string): Boolean;
  begin
    for var V in Values do
      if SameText(V.Name, Name) then Exit(True);
    Result := False;
  end;

begin
  SetLength(Result, 0);
  if (FrameRBP = 0) or (FuncEntryVA = 0) or (FuncName = '') then
    Exit;
  var FuncRva := VAToRva(FuncEntryVA);
  // Only the immediate frame is scope-filtered (FramePcRva is its PC). The
  // enclosing-proc frames in the nesting climb below pass 0 (no PC known),
  // so their locals are not block-filtered.
  Result := CollectLocalsForFrame(FrameRBP, FuncEntryVA, FuncName, '', FramePcRva);

  // Walk the lexical-scope chain up to all enclosing procedures. Each
  // nested level's hidden parent-frame pointer is at the standard RCX
  // home slot (RBP + frame_size + 0x10). Keep climbing until we run out
  // of enclosing procedures or hit the safety cap. Locals from each
  // parent are surfaced with a "<parent>." prefix.
  const MAX_NEST_DEPTH = 32;
  var CurName     := FuncName;
  var CurRBP      := FrameRBP;
  var CurEntry    := FuncEntryVA;
  var CurInnerRva := FuncRva;
  for var Depth := 1 to MAX_NEST_DEPTH do begin
    // Prefer RVA-keyed lookup -- name-keyed FInnerToParent collides when
    // two units each declare a nested proc with the same short name
    // (SampleApp: multiple CreateNodes across units).
    var ParentName: string;
    if not FDebugInfo.GetEnclosingProcedureByRva(CurInnerRva, ParentName) then
      if not FDebugInfo.GetEnclosingProcedure(CurName, ParentName) then
        Break;
    // Resolve the parent's body RVA. Prefer the RVA-keyed map (unique,
    // same-unit) over a name round-trip -- NameToRva on a bare parent
    // leaf (e.g. `Mid`) collides when two units each have one.
    //
    // Resolved BEFORE the frame pointer, because the fallback below needs to
    // know which routine it is looking for.
    var ParentRva: UInt64;
    if not FDebugInfo.GetEnclosingProcedureRvaByRva(CurInnerRva, ParentRva) then
      if not FDebugInfo.NameToRva(ParentName, ParentRva) then
        Break;
    var ParentEntry := RvaToVA(ParentRva);

    var ChildExtraPushes: UInt32;
    var ChildRecognised:  Boolean;
    var ChildFrameSize   := ReadPrologInfo(CurEntry, ChildExtraPushes, ChildRecognised);
    // Walking to the parent frame from an unrecognised prologue would follow a
    // pointer read from an arbitrary stack slot. Ask for the static link only
    // when the prologue was understood.
    var ParentRBP: UInt64 := 0;
    if ChildRecognised then
      ParentRBP := ReadParentFramePointer(CurRBP, ChildFrameSize, ChildExtraPushes);
    // No static link available -- which is the normal case on x86, where the
    // Win64 home-slot formula does not apply and the 32-bit override declines
    // rather than reading an arbitrary slot. The parent's frame is still on the
    // stack whenever the nested routine was entered from it, so LOOK for it
    // instead of computing an address: the nearest frame above the child whose
    // function entry is the parent's. That needs no ABI knowledge, is the same
    // answer on both bitnesses, and finds nothing (so the climb simply stops)
    // when the parent is genuinely not on the stack.
    if ParentRBP = 0 then
      ParentRBP := FindParentFrameOnStack(ParentEntry, CurRBP);
    if ParentRBP = 0 then
      Break;
    Result := Result + CollectLocalsForFrame(
      ParentRBP, ParentEntry, ParentName, ParentName + '.', {FramePcRva=}0);
    CurName     := ParentName;
    CurRBP      := ParentRBP;
    CurEntry    := ParentEntry;
    CurInnerRva := ParentRva;
  end;

  // Only the immediate frame carries a PC, and the alias means nothing outside
  // the block that PC is standing in -- an enclosing frame is somewhere else.
  if FramePcRva <> 0 then begin
    var Alias: TLocalValue;
    if TryGetHandlerAliasLocal(RvaToVA(FramePcRva), Alias) and
       not AlreadyListed(Result, Alias.Name) then
      Result := Result + [Alias];
  end;
end;

function TWinDebugger.GetLocalValues: TArray<TLocalValue>;
var
  Ctx:    TContext;
  TH:     THandle;
  FuncNm: string;
begin
  SetLength(Result, 0);
  // An explicitly-selected (non-top) call-stack frame wins: the DAP
  // client set it via scopes/evaluate on a frameId other than 0.
  if (FActiveFrameRBP <> 0) and (FActiveFrameEntryVA <> 0) then
    Exit(GetLocalValuesForFrame(FActiveFrameRBP, FActiveFrameEntryVA, FActiveFrameName,
      VAToRva(FActiveFramePC)));

  TH := ThreadHandle(FStoppedTid);
  if TH = 0 then
    Exit;

  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(TH, Ctx) then
    Exit;

  var Rva := VAToRva(Ctx.Rip);
  if not FDebugInfo.RvaToFunctionName(Rva, FuncNm) then
    Exit;

  var FuncRva: UInt64 := 0;
  FDebugInfo.RvaToFunctionStart(Rva, FuncRva);
  // Rva is the stopped PC -> drives lexical-block scope filtering of locals.
  Result := GetLocalValuesForFrame(Ctx.Rbp, RvaToVA(FuncRva), FuncNm, Rva);
end;

procedure TWinDebugger.SetActiveFrame(FrameRBP, FuncEntryVA: UInt64;
  const FuncName: string; FramePC: UInt64);
begin
  FActiveFrameRBP     := FrameRBP;
  FActiveFrameEntryVA := FuncEntryVA;
  FActiveFrameName    := FuncName;
  FActiveFramePC      := FramePC;
end;

procedure TWinDebugger.ClearActiveFrame;
begin
  FActiveFrameRBP     := 0;
  FActiveFrameEntryVA := 0;
  FActiveFrameName    := '';
  FActiveFramePC      := 0;
end;

function TWinDebugger.CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64;

  // Home-slot address of ABI param ParamIndex for a frame with the given RBP +
  // entry VA. The RCX home slot (param 0) is at RBP + N + extraPushBytes + 16
  // (same anchor ReadParentFramePointer uses); each later param home slot is 8
  // bytes higher (the Win64 shadow / stack-arg area is positional).
  function ParamAddr(FrameRBP, FuncEntryVA: UInt64): UInt64;
  begin
    if (FrameRBP = 0) or (FuncEntryVA = 0) then Exit(0);
    var ExtraPushBytes: UInt32;
    var Recognised: Boolean;
    var SubRspN := ReadPrologInfo(FuncEntryVA, ExtraPushBytes, Recognised);
    // An unrecognised prologue makes every offset below a guess. 0 is this
    // function's documented "unavailable", so refuse instead of returning an
    // address that looks valid and points at an unrelated stack slot.
    if not Recognised then Exit(0);
    Result := FrameRBP + UInt64(SubRspN) + UInt64(ExtraPushBytes) + 16 +
              UInt64(ParamIndex) * 8;
  end;

var
  Ctx: TContext;
  TH:  THandle;
begin
  // An explicitly-selected (non-top) frame wins, matching GetLocalValues.
  if (FActiveFrameRBP <> 0) and (FActiveFrameEntryVA <> 0) then
    Exit(ParamAddr(FActiveFrameRBP, FActiveFrameEntryVA));
  Result := 0;
  TH := ThreadHandle(FStoppedTid);
  if TH = 0 then Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(TH, Ctx) then Exit;
  var FuncRva: UInt64 := 0;
  FDebugInfo.RvaToFunctionStart(VAToRva(Ctx.Rip), FuncRva);
  Result := ParamAddr(Ctx.Rbp, RvaToVA(FuncRva));
end;

end.
