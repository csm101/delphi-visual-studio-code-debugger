unit DebugTarget;

// Target-agnostic debugger contract used by the DAP layer and the expression
// evaluator. The Win64 process-API implementation is `TWinDebugger`
// (WinDebuggerBase.pas); a future Win32 (or attach-mode, or remote) target
// implements the same interface.
//
// Types previously declared inside WinDebuggerBase.pas (TStopReason,
// TRegisterSnapshot, TLocalValue, TStackFrame, the event callback
// signatures, TBreakpointRec, TBpSpec, TCommand) live here so that
// alternative implementations don't have to depend on WinDebuggerBase.

interface

uses
  System.SysUtils, Winapi.Windows, DebugInfoTypes, ExceptionRules, TargetLayout,
  Disassembler;

type
  TStopReason = (srEntry, srBreakpoint, srStep, srException, srPause,
    srDataBreakpoint);

  // Instruction-granularity stepping (ASSEMBLY_LEVEL_DEBUGGING.md increment 1).
  // Deliberately NOT the same as the source-level TStepMode: "advance until the
  // source line changes" has no terminating condition in code with no line
  // table, which is exactly the code someone steps through one instruction at a
  // time.
  //
  //   iskInto -- one trap-flag step; land wherever it goes, including inside a
  //              callee.
  //   iskOver -- the same, EXCEPT for an instruction that must not be
  //              single-stepped: a `call` (stepping it would enter the callee)
  //              and a `rep`-prefixed string instruction (the trap fires once
  //              per ITERATION, so a trap-flag step retires one iteration and
  //              leaves the PC where it was). Both run to a one-shot breakpoint
  //              at PC + the DECODED length instead.
  //   iskOut  -- run to this frame's return address, which comes from `.pdata`
  //              on x64 and from [EBP+4] on x86 (IDebugTarget's own
  //              CallerReturnAddress). Where neither can prove one, it REFUSES;
  //              unlike the source-level step-out it never degrades to
  //              single-stepping, which cannot terminate without a line table.
  TInstructionStepKind = (iskInto, iskOver, iskOut);

  // A fully-decided instruction step, handed to the debug loop. The DECISION
  // (decode, refuse, choose trap flag vs one-shot) is made on the requesting
  // thread while the target is stopped, because a refusal has to be synchronous;
  // the EXECUTION has to happen on the Run thread, because ContinueDebugEvent
  // must be called from the thread that called WaitForDebugEvent. This record is
  // what crosses between the two.
  TInstrStepPlan = record
    Kind:        TInstructionStepKind;
    // True  -> arm the trap flag and take exactly one step.
    // False -> plant a one-shot breakpoint at ResumeVA and run full speed.
    UseTrapFlag: Boolean;
    ResumeVA:    UInt64;
    // Smallest stack pointer a ResumeVA hit may have and still be OUR step
    // landing. A recursive callee returns to the SAME address one (or many)
    // frames deeper, where the stack pointer is LOWER; without this the step
    // reports the right address in the wrong incarnation. 0 = no constraint.
    MinResumeSP: UInt64;
  end;

  // How one synthetic-call argument has to be materialised in the TARGET.
  //
  // This replaces a plain "is it a float" Boolean, which was sufficient on x64 --
  // there every argument occupies exactly one 8-byte slot BY POSITION and only
  // the register file (integer vs XMM) differs -- and is not sufficient on x86.
  // Measured with DevTools\Win32FloatArgProbe:
  //
  //   * A parameter takes one of EAX/EDX/ECX only if it fits 32 bits AND is not
  //     a float. Everything else goes on the stack and consumes NO register
  //     slot, so ordinals declared after it keep taking registers:
  //     `Foo(A: Integer; B: Double; C: Integer)` puts A in EAX, B on the stack
  //     and C in EDX.
  //   * Stack widths differ: Single 4, Double 8, Int64/Currency 8, and
  //     Extended 12 -- ten bytes padded to a 4-byte boundary.
  //
  // ArgValues carries each value in the TARGET's own encoding for its type: a
  // Single as its 4-byte pattern, a Currency as the scaled Int64. The one
  // exception is Extended, which travels as DOUBLE bits because that is all an
  // 8-byte slot can hold; the x86 placement widens it to 80 bits on the way in.
  TSyntheticArgKind = (
    sakOrdinal,    // fits one pointer-sized register slot
    sakInt64,      // 8 bytes, integer-shaped -- Currency and Comp included
    sakSingle,     // 4-byte IEEE
    sakDouble,     // 8-byte IEEE, plus TDateTime and the Double aliases
    sakExtended    // 10-byte x87 on Win32; a true alias of Double on Win64
  );

  // DAP exception-filter switches. Each flag toggles whether a class of
  // exceptions stops the debuggee at the user-visible level. Defaults
  // (delphi=on, av=on, all=off, unhandled=on) match the historical
  // hardcoded behaviour so the filter UI is purely additive.
  TExceptionFilter = (
    efDelphi,         // first-chance Delphi-raised exceptions ($0EEDFADE)
    efAccessViolation,// first-chance access violations
    efAllFirstChance, // every other first-chance exception (noisy)
    efUnhandled       // second-chance / never-handled exceptions
  );
  TExceptionFilters = set of TExceptionFilter;

const
  DEFAULT_EXCEPTION_FILTERS: TExceptionFilters =
    [efDelphi, efAccessViolation, efUnhandled];

type

  // A 64-bit SUPERSET of both register files. A 32-bit target fills the same
  // fields from its own registers -- Eip into Rip, Esp into Rsp, and so on --
  // leaving R8..R15 zero, so a consumer that reads a physical name gets a
  // correct value on x64 and a meaningless one on x86.
  //
  // Consumers that want a ROLE ("the program counter", "the frame pointer")
  // rather than a specific physical register must use the accessors below.
  // Physical names are for the x64 implementation itself and for the DAP
  // Registers view, which is deliberately showing the machine's real registers.
  TRegisterSnapshot = record
    Rip, Rsp, Rbp:                           UInt64;
    Rax, Rbx, Rcx, Rdx, Rsi, Rdi:            UInt64;
    R8,  R9,  R10, R11, R12, R13, R14, R15:  UInt64;
    EFlags:                                  UInt32;
    Valid:                                   Boolean;

    function Pc: UInt64;        // RIP / EIP
    function StackPtr: UInt64;  // RSP / ESP
    function FramePtr: UInt64;  // RBP / EBP
  end;

  // The debug-register file, expressed as a ROLE rather than a layout: DR0..DR3
  // hold the watched addresses, DR6 reports what fired, DR7 controls arming.
  // Both bitnesses share this 64-bit shape; a 32-bit target simply never fills
  // the high halves, exactly as TRegisterSnapshot works.
  TDebugRegisters = record
    Dr:  array[0..3] of UInt64;
    Dr6: UInt64;
    Dr7: UInt64;
  end;

  // A hardware watchpoint hit, as the event pump saw it. The firing THREAD is
  // part of the answer, not decoration: "who wrote this" is the question a
  // watchpoint exists to answer.
  TWatchpointHit = record
    ThreadId:   DWORD;
    Slot:       Integer;  // lowest DR that fired, -1 when none
    FiredSlots: Byte;     // bitmask: two slots can trip on one instruction
    Address:    UInt64;   // what that DR was armed on
    Pc:         UInt64;   // where the target was when the trap arrived
    SizeBytes:  Integer;  // width the slot was armed at, for OldValue/NewValue
    // A write watchpoint traps AFTER the store completes, so NewValue is read
    // at the trap; OldValue is whatever NewValue was at the PREVIOUS hit (or at
    // arm time for the first one) -- captured by the allocator, not decoded
    // from the trap itself. Zero-extended into the low SizeBytes.
    OldValue:   UInt64;
    NewValue:   UInt64;
    Description: string;  // the allocator's OwnerDescription -- who asked for it
  end;

  // What one data-breakpoint command asks the engine to do, queued and run on
  // the debug thread exactly like a source breakpoint spec (arming touches
  // thread contexts). Clear=True targets an existing Slot instead of arming a
  // new address.
  TDataBpArmSpec = record
    Clear:            Boolean;
    Slot:             Integer;   // meaningful only when Clear = True
    Address:          UInt64;
    SizeBytes:        Integer;
    WriteOnly:        Boolean;
    OwnerDescription: string;
  end;

  TLocalValue = record
    Name:       string;
    TypeHint:   string;
    RbpOffset:  Integer;
    Address:    UInt64;
    Kind:       TLocalKind;
    RawValue:   UInt64;
    ValueValid: Boolean;
    DerefValue: UInt64;
    DerefValid: Boolean;
    ParamStatus: TSymbolParamStatus;
                             // Parameter, body local, or not stated by any
                             // provider. Decides a question the TYPE cannot: an
                             // open array and a dynamic array have identical
                             // type records, and an open array only ever occurs
                             // as a parameter. The unknown state is load-bearing
                             // -- see TSymbolParamStatus.
    PointeeKind: Byte;       // What this local's type POINTS AT (0 = unknown).
                             // A different question from TypeKind and not
                             // derivable from the spelling: a dynamic array and
                             // a plain typed pointer both read `^T`, so only the
                             // provider that owns the type table can say which
                             // one a `^T` local really is. Reading a genuine
                             // `^T2` as an array of T2 because it happens to
                             // point at a live `array of T1` header renders a
                             // wrong length and strides past the buffer.
    TypeKind:    Byte;       // The kind of this local's own declared type, already
                             // resolved by the provider that produced it
                             // (TK_DYNARRAY, TK_RECORD, ...; 0 = unknown).
                             // A resolved ANSWER rather than a type id, because
                             // an id only means something inside the table it
                             // came from -- TD32 and RSM number the same local
                             // differently, and swapping them resolves to an
                             // unrelated type.
    RegId:      Word;        // 0 = stack-allocated (Address valid).
                             // > 0 = register-allocated; runtime value
                             // read through GetRegisters instead of
                             // ReadProcessMemoryAt(Address).
  end;

  // WHICH mechanism produced a frame. Diagnostic only -- nothing branches on it
  // -- but a stack is assembled by several independent mechanisms and a frame
  // that turns out to be wrong reads exactly like a correct one, so without this
  // the first question after "this frame is bogus" ("who emitted it?") can only
  // be answered by guessing. It has been answered wrongly three times.
  TFrameOrigin = (
    foUnknown,          // not tagged (a producer that has not been instrumented)
    foSeed,             // frame 0, straight from the thread context
    foEbpChain,         // followed a saved-EBP link that validated
    foPrologueProbe,    // return address found near ESP, frame not yet established
    foFramelessRecover, // inserted for a framed caller a frameless routine hid
    foDbgHelpTail,      // spliced from dbghelp below a verified join
    foDbgHelpWhole,     // dbghelp's entire walk, taken because ours had nothing
    foSynthesizedSeed,  // walker produced nothing; frame 0 rebuilt from context
    // Raw stack scan (opt-in, see IDebugTarget.RawStackCandidates). NEVER
    // produced by the ordinary walk, and never mixed into it: these say where a
    // return address IS, not that it is still live.
    foRawProven,        // decoded: the instruction ending here IS a call
    foRawUnproven       // in executable code, but no boundary to decode from
  );

  TStackFrame = record
    IP:           UInt64;
    FunctionName: string;
    SourceFile:   string;
    SourceLine:   Integer;
    FrameRBP:     UInt64;   // this frame's RBP (StackWalk64 AddrFrame)
    FuncEntryVA:  UInt64;   // VA of the frame's function entry (for prolog)
    Origin:       TFrameOrigin;
  end;

  // One word of the thread's stack that could be a return address.
  //
  // "Could": position is established, LIVENESS IS NOT. A return address left by
  // a call that has already returned is still sitting there and still decodes
  // as call-adjacent, and nothing on the stack distinguishes it from a live one
  // without a frame chain -- which is precisely what is missing when this is
  // used. Callers must present these apart from walked frames, never merged.
  TRawStackCandidate = record
    StackAddr: UInt64;   // where the word was found (orders the results)
    PC:        UInt64;   // the code address the word holds
    Proven:    Boolean;  // the instruction ending at PC was DECODED as a call
  end;

  // Which identity a breakpoint carries. A SOURCE breakpoint is keyed on
  // (SourceFile, SourceLine); an ADDRESS breakpoint is keyed on
  // (ModuleName, Rva) instead -- see TAddrBpSpec. Internal one-shot/step
  // breakpoints (stepping, raise-catch, resume points) are created with the
  // default bkSource and are never reported through this distinction anyway:
  // they live only in the engine's own FBreakpoints, never in
  // TDebugSession's separate user-facing breakpoint list.
  TBreakpointKind = (bkSource, bkAddress);

  TBreakpointRec = record
    VA:           UInt64;
    Rva:          UInt64;
    OrigByte:     Byte;
    SourceFile:   string;
    SourceLine:   Integer;
    IsOneShot:    Boolean;
    IsPlanted:    Boolean;
    Condition:    string;
    HitCondition: string;
    LogMessage:   string;
    HitCount:     Integer;
    Kind:         TBreakpointKind;  // bkSource (default) or bkAddress
    ModuleName:   string;           // bkAddress only: '' = main exe, else lowercase file name
  end;

  TCommandKind = (ckContinue, ckStepInto, ckStepOver, ckStepOut, ckPause,
    ckSetBreakpoints, ckSetDataBreakpoints, ckSetAddressBreakpoints,
    ckStepInstruction);

  TBpSpec = record
    SourceFile:    string;
    Lines:         TArray<Integer>;
    Conditions:    TArray<string>;
    HitConditions: TArray<string>;
    LogMessages:   TArray<string>;
  end;

  // Address-breakpoint set for ONE module, identity-keyed the same way TBpSpec
  // is keyed by SourceFile: a repost REPLACES every address breakpoint
  // previously registered for ModuleName, never merges. Rvas are offsets from
  // the module's OWN base, resolved by the CALLER (TDebugSession, which owns
  // the module table via GetModules) -- the engine only knows how to turn a
  // currently-loaded module's name into its live base address (FImageBase for
  // '', FDllBases otherwise) and plant there. A module not currently loaded
  // means the whole spec is silently dropped: no VA can be computed, so
  // nothing is planted and nothing lingers half-resolved
  // (DISASSEMBLY_PLAN.md, "Address breakpoints").
  TAddrBpSpec = record
    ModuleName:    string;   // '' = the main exe; lowercase file name otherwise
    Rvas:          TArray<UInt64>;
    Conditions:    TArray<string>;
    HitConditions: TArray<string>;
    LogMessages:   TArray<string>;
  end;

  TCommand = record
    Kind:       TCommandKind;
    ThreadId:   DWORD;    // step target for ckStep*: 0 = the currently-stopped thread
    BpSpec:     TBpSpec;
    DataBpSpec: TDataBpArmSpec;
    AddrBpSpec: TAddrBpSpec;
    InstrStep:  TInstrStepPlan;   // ckStepInstruction only
  end;

  TOnStopped     = procedure(Reason: TStopReason; const SourceFile: string;
    SourceLine: Integer) of object;
  TOnExited      = procedure(ExitCode: Integer) of object;
  TOnOutput      = procedure(const Text: string) of object;
  TOnDllLoaded   = procedure(const Name, Path: string;
    Base, ImageSize: UInt64) of object;
  TOnDllUnloaded = procedure(const Name: string; Base: UInt64) of object;
  TOnBpHit       = function(const BP: TBreakpointRec): Boolean of object;

  // Abstract debug-target contract. Implementations: TWinDebugger today,
  // future TWin32Debugger / TAttachedDebugger / TRemoteDebugger.
  IDebugTarget = interface
    ['{C9F2A1B0-4D3E-44F8-8A22-9F5D8E0C7311}']
    // Process state.
    function  ProcessHandle: THandle;
    function  ImageBase: UInt64;
    function  HasExited: Boolean;
    function  LastExceptionDesc: string;
    function  LastExceptionClass: string;
    function  LastExceptionMessage: string;
    // VA of the live Delphi exception object at the current exception stop
    // (0 when not stopped on a Delphi raise). Surfaced as the `$exception`
    // pseudo-local so the object is inspectable in the Variables panel.
    function  CurrentExceptionObject: UInt64;

    // Memory I/O.
    function  ReadProcessMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    function  WriteMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    // Like WriteMemoryAt, but reports how many bytes actually landed instead
    // of collapsing every outcome to a Boolean. DAP `writeMemory`'s
    // `allowPartial` (ASSEMBLY_LEVEL_DEBUGGING.md increment 3) needs the true
    // count when a write crosses from writable into read-only/unmapped
    // memory; MCP's all-or-nothing `write_memory` keeps using WriteMemoryAt.
    // Returns whatever WriteProcessMemory itself reports (0..Size); never
    // guesses at a partial count.
    function  WriteMemoryPartial(VA: UInt64; Buf: Pointer; Size: NativeUInt): NativeUInt;
    // Like ReadProcessMemoryAt, but for reading CODE a caller intends to
    // disassemble or otherwise inspect as instructions rather than data.
    // Two differences (DISASSEMBLY_PLAN.md, "Traps"):
    //   1. Any byte the debugger itself planted an INT3 over (a user
    //      breakpoint) is returned as the ORIGINAL opcode, not $CC -- reading
    //      raw process memory at a planted breakpoint would otherwise show
    //      `int3` where the user's code actually is.
    //   2. A request that runs past the end of the committed region TRUNCATES
    //      instead of failing outright -- a disassembly window near the end
    //      of a section is a normal case, not an error.
    // Returns the number of bytes actually placed in Buf (0..Size); 0 means
    // nothing at VA was readable at all. Never raises for a partially-mapped
    // request.
    function  ReadCodeMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): NativeUInt;
    // Greatest address strictly below VA that is a PROVEN instruction
    // boundary belonging to the same routine as VA, taken from debug info
    // (the line table, or the routine's own entry when there is no line
    // there). x86/x64 cannot be decoded backwards, so this -- plus decoding
    // FORWARD from it and checking the result lands exactly on VA -- is the
    // only exact way to find instructions preceding an address
    // (DISASSEMBLY_PLAN.md, "before"). False when no debug-info provider
    // owns VA's routine at all; callers needing a boundary for a
    // symbol-less module fall back to NearestExportedEntryBefore, never to
    // a guess here.
    function  NearestInstructionBoundaryBefore(VA: UInt64;
                out BoundaryVA: UInt64): Boolean;
    // Boundary source of last resort: the nearest PE export-table entry at
    // or before VA, scoped to whichever loaded module VA falls inside. Used
    // only after NearestInstructionBoundaryBefore fails -- a module with NO
    // debug info at all (a third-party package, an OS DLL) still gives a
    // genuinely PROVEN boundary through its export directory, if it has
    // one: an export entry IS the exact address GetProcAddress would return,
    // not a guess. Read from the LIVE mapped image, not a file on disk.
    // False when VA is in no module the debugger has logged, the owning
    // module has no export directory, or every export lies at or after VA.
    function  NearestExportedEntryBefore(VA: UInt64;
                out BoundaryVA: UInt64): Boolean;
    function  RvaToVA(Rva: UInt64): UInt64;
    // Memory layout of the TARGET's address space. Callers decoding target
    // structures must take strides and header offsets from here rather than
    // from SizeOf(Pointer), which describes the debugger and not the debuggee.
    function  TargetLayout: TTargetLayout;

    // Thread enumeration. GetThreadIds lists every live thread (in
    // creation order). GetThreadName returns a human-readable label --
    // either the Win10+ SetThreadDescription string or a synthetic
    // "Thread <tid>" fallback. GetStoppedThreadId returns the tid the
    // debug loop is currently parked on (or 0 if running).
    function  GetThreadIds: TArray<DWORD>;
    function  GetThreadName(TID: DWORD): string;
    function  GetStoppedThreadId: DWORD;

    // Registers and locals target the stopped thread. Stack frames can be
    // walked for any thread (read-only) via the TID overload; the no-arg form
    // walks the stopped thread.
    function  GetRegisters: TRegisterSnapshot;
    function  GetStackFrames: TArray<TStackFrame>; overload;
    function  GetStackFrames(TID: DWORD): TArray<TStackFrame>; overload;
    // Brute-force sweep of the thread's stack for words that could be return
    // addresses, symbolicated like ordinary frames but carrying foRawProven /
    // foRawUnproven. Opt-in and deliberately separate from GetStackFrames: it
    // is for the case where the walk STOPS -- inside code with no unwind data
    // and no frame pointer -- and the question is no longer "what is the call
    // stack" but "which of MY routines is somewhere underneath this".
    //
    // Ordered by stack address, nearest the top of the stack first. FrameRBP is
    // 0 throughout: these are addresses, not frames, so no locals can be read
    // from them.
    function  GetRawStackFrames(TID: DWORD;
                MaxItems: Integer = 0): TArray<TStackFrame>;
    // Re-resolve source/function/entry for frames already found, without
    // walking or sweeping again. Exists because a caller that loads a module's
    // symbols in response to a nameless frame must not pay for a second sweep
    // of a multi-megabyte stack just to see the names.
    function  ResymbolicateFrames(
                const Frames: TArray<TStackFrame>): TArray<TStackFrame>;
    // The class whose method the SELECTED frame is executing, or '' outside a
    // method. Names the Pascal scope an unqualified identifier is resolved in,
    // which is what makes a class-nested enum's members visible: with the
    // default {$SCOPEDENUMS OFF} they live in the CLASS's scope.
    function  CurrentScopeClassName: string;
    function  GetLocalValues: TArray<TLocalValue>;
    // Select / clear the active call-stack frame (DAP frameId). When a
    // non-top frame is active, GetLocalValues and the evaluator read that
    // frame's locals. Clear (or set 0) restores the stopped top frame.
    procedure SetActiveFrame(FrameRBP, FuncEntryVA: UInt64; const FuncName: string;
                FramePC: UInt64 = 0);
    procedure ClearActiveFrame;
    // Win64 home-slot address of ABI parameter ParamIndex (0-based; for a method
    // Self is 0, the first declared param is 1) for the frame locals are
    // currently read from (the active frame if selected, else the stopped top
    // frame). Computed from the frame's RBP + prologue (sub rsp N + extra pushes):
    // the RCX home slot sits at RBP + N + extraPushBytes + 16. 0 if unavailable.
    // Used to surface parameters of a frame no local/param provider describes
    // (an anonymous-method body), placing each declared param at its ABI slot.
    function  CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64;
    function  EvaluateName(const Name: string; out Value: TLocalValue): Boolean;
    // Local-only / global-only variants used by ExprEval to enforce the
    // local -> Self.<name> -> global resolution priority.
    function  EvaluateLocalName(const Name: string; out Value: TLocalValue): Boolean;
    function  EvaluateGlobalName(const Name: string; out Value: TLocalValue): Boolean;

    // --- Hardware watchpoints (debug registers) ------------------------------
    // The raw per-thread primitive and what the event pump saw. Increment 2 of
    // DATA_BREAKPOINTS_PLAN.md stops deliberately here: no slot allocator, no
    // replication onto other threads, no stop reason. What the increment buys
    // is that the stepping engine no longer mistakes a watchpoint hit for its
    // own completed step -- both arrive as the same single-step exception.
    //
    // Arming refuses rather than rounds: Slot must be 0..3, SizeBytes one of
    // 1/2/4/8 (8 only on a 64-bit target), and Address must be aligned to
    // SizeBytes -- the hardware ignores the low address bits, so a misaligned
    // request would silently watch a neighbouring cell.
    function  ArmHardwareWatchpoint(TID: DWORD; Slot: Integer; Address: UInt64;
                SizeBytes: Integer; WriteOnly: Boolean): Boolean;
    function  DisarmHardwareWatchpoint(TID: DWORD; Slot: Integer): Boolean;
    function  HardwareWatchpointHitCount: Integer;
    function  LastHardwareWatchpointHit: TWatchpointHit;

    // Process-wide allocator (increment 3 of DATA_BREAKPOINTS_PLAN.md): picks a
    // free slot and arms it on EVERY thread the debugger knows about -- live now,
    // created later, or already running at attach -- and keeps it that way until
    // ClearDataWatchpoint or detach. The raw per-thread pair above only ever
    // touches one thread, which is correct for a probe or a single-thread test
    // and wrong for a real watchpoint: a slot armed on the thread that reads a
    // variable and not on the one that writes it reports success while
    // answering nothing. Exhaustion of the four hardware slots is refused
    // explicitly, naming what already holds them -- never silently drops the
    // fifth request.
    function  SetDataWatchpoint(Address: UInt64; SizeBytes: Integer; WriteOnly: Boolean;
                const OwnerDescription: string; out Slot: Integer;
                out RefusalReason: string): Boolean;
    function  ClearDataWatchpoint(Slot: Integer): Boolean;
    // Session-facing entry point (increment 4): posts Spec through the command
    // queue -- arming touches thread contexts, same reason ckSetBreakpoints
    // does -- then drains and executes it immediately, so the caller gets the
    // REAL arming outcome (slot exhaustion, misalignment) synchronously rather
    // than an optimistic prediction. Result mirrors SetDataWatchpoint /
    // ClearDataWatchpoint's own True/False.
    function  ApplyDataBreakpointCommand(const Spec: TDataBpArmSpec;
                out Slot: Integer; out RefusalReason: string): Boolean;

    // --- Instruction-granularity stepping (ASSEMBLY_LEVEL_DEBUGGING.md inc 1) --
    // Steps ThreadId (0 = the currently-stopped thread) by exactly one machine
    // instruction, per TInstructionStepKind. Returns False WITHOUT resuming the
    // debuggee and fills RefusalReason when the step cannot be taken exactly:
    // no live debuggee, the debuggee is running, an unknown thread, a decoder
    // that is unavailable or cannot decode the bytes at the PC, or (iskOut) a
    // return address that cannot be proven. This project refuses rather than
    // guesses an instruction length or a plausible-looking address.
    //
    // True means the step was ACCEPTED and the debuggee resumed; the resulting
    // stop arrives on the normal OnStopped path with reason srStep, exactly like
    // the source-level steps.
    function  StepInstruction(Kind: TInstructionStepKind; ThreadId: DWORD;
                out RefusalReason: string): Boolean;
    // Replaces the disassembler instruction stepping decodes with. Injection
    // seam: production leaves it unset and the engine builds a Zydis-backed one
    // on first use, while a test can supply a double (notably an unavailable
    // backend, which the process-wide one-shot Zydis load latch makes impossible
    // to produce by pointing the loader at a bad path -- see TRAPS.md).
    procedure SetInstructionDisassembler(const Disasm: IDisassembler);

    // Mutators (used by `setVariable` and the synthetic remote-call path).
    function  SetRegisterByName(const Name: string; Value: UInt64): Boolean;
    function  SetInstructionPointer(VA: UInt64): Boolean;
    function  AllocateRemoteString(const Text, TypeHint: string;
                out NewPtr: UInt64): Boolean;
    function  SetStringVariable(TargetAddr: UInt64;
                const Text, TypeHint: string): Boolean;

    // Synthetic remote-call infrastructure (used by ExprEval).
    function  TryResolveSymbolVA(const Name: string; out VA: UInt64): Boolean;
    // True when VA lies on a committed, executable page. Lets ExprEval refuse
    // to invoke a name that resolved to a DATA global (e.g. a unit `var`) as if
    // it were a parameterless function -- calling a data address as code runs
    // the variable's bytes as instructions and returns garbage / faults.
    function  AddressIsExecutable(VA: UInt64): Boolean;
    // True while a synthetic remote call (RunMethodCall) is pumping. Lets the
    // stdin thread decide whether an incoming control command should cancel it.
    function  RemoteCallInFlight: Boolean;
    // Requests the in-flight synthetic call (if any) to abort at the next pump
    // iteration. Thread-safe; a no-op when no call is running.
    procedure RequestAbortRemoteCall;
    // Resolves a bare class NAME to its runtime class reference (TClass = the
    // VMT address), scoped to the active frame's `uses` so a same-named class
    // in another unit is not picked. Used as the Self argument when invoking a
    // class function via `TFoo.ClassMethod`. VA=0 / False when not resolvable.
    function  TryResolveClassRef(const ClassName: string; out VA: UInt64): Boolean;
    // Resolves a named CONSTANT (e.g. an inlined `const X = 1`) to its value,
    // scoped to the active frame's `uses`. The value has no runtime storage, so
    // this reads it from debug info (RSM `$25` records). False when unknown.
    function  TryResolveConstValue(const Name: string;
                out Value: Int64; out TypeHint: string): Boolean;
    function  GetRemoteScratchSlot(MinSize: NativeUInt): UInt64;
    function  RunMethodCall(FuncVA: UInt64;
                const ArgValues: array of UInt64;
                const ArgKinds:  array of TSyntheticArgKind;
                out IntResult, FloatResultLow: UInt64): Boolean;
    // Why the last RunMethodCall failed, in the debuggee's own words -- the
    // raised exception's class and message, or the fault. '' when the last call
    // succeeded or failed before reaching the target. Only meaningful
    // immediately after a False return.
    function  LastSyntheticCallError: string;
    // Arguments are POSITIONAL, not register-named: which physical register (or
    // stack slot) each one lands in is the implementation's business, and the
    // answer differs per architecture. Delphi's 32-bit `register` convention
    // passes the first three in EAX/EDX/ECX with the rest pushed, and returns
    // floats on the x87 stack rather than in an SSE register, so a signature
    // spelled ArgRcx/RaxResult would be a lie there.
    function  RunRemoteCallEx(FuncVA: UInt64;
                Arg0, Arg1, Arg2, Arg3: UInt64;
                out IntResult, FloatResultLow: UInt64): Boolean;

    // Forwards to the target's debug-info set; here for evaluator
    // convenience so it doesn't need its own DebugInfoSet ref.
    function  LookupEnumInfo(const TypeName: string;
                out Info: TRsmEnumInfo): Boolean;

    // Exception-filter UI: which categories of debuggee exceptions surface
    // as user-visible stops. Default is DEFAULT_EXCEPTION_FILTERS.
    procedure SetExceptionFilters(Filters: TExceptionFilters);
    // Per-class refinement of the `delphi` filter. When non-empty, a
    // first-chance Delphi raise only stops if the raised class name (read
    // via the standard EObject.ClassName lookup) appears in this comma-
    // separated, case-insensitive list. Empty (default) = stop on every
    // Delphi raise (legacy behaviour).
    procedure SetDelphiClassFilter(const ClassNames: string);
    // Per-exception rule table (from launch.json `exceptionRules`). Evaluated
    // before the filter decision: a matching rule's action (ignore / log /
    // logStack / break) wins; with no match the filter selection above
    // decides. Empty (default) = filters alone, legacy behaviour.
    procedure SetExceptionRules(const Rules: TArray<TExceptionRule>);

    // Lifecycle / control.
    procedure Launch(const ExePath: string; StopAtEntry: Boolean);
    // Attach to an already-running process. After return, debug events
    // flow as if we had launched it; the kernel injects an initial
    // breakpoint to mark "attach completed". Detach behaviour on
    // disconnect depends on `KillOnDetach` (False = leave the target
    // running by calling DebugActiveProcessStop).
    procedure Attach(ProcessId: Cardinal; KillOnDetach: Boolean);
    procedure Terminate;
    procedure PostCommand(const Cmd: TCommand);
    procedure ProcessOneEvent;

    // Event hookup. Plain methods (not properties) on the interface so
    // every implementation has the same getter/setter pair without
    // having to declare them separately.
    function  GetOnStopped: TOnStopped;
    procedure SetOnStopped(const Value: TOnStopped);
    function  GetOnExited: TOnExited;
    procedure SetOnExited(const Value: TOnExited);
    function  GetOnOutput: TOnOutput;
    procedure SetOnOutput(const Value: TOnOutput);
    function  GetOnDllLoaded: TOnDllLoaded;
    procedure SetOnDllLoaded(const Value: TOnDllLoaded);
    function  GetOnDllUnloaded: TOnDllUnloaded;
    procedure SetOnDllUnloaded(const Value: TOnDllUnloaded);
    function  GetOnBpHit: TOnBpHit;
    procedure SetOnBpHit(const Value: TOnBpHit);

    property OnStopped:     TOnStopped     read GetOnStopped     write SetOnStopped;
    property OnExited:      TOnExited      read GetOnExited      write SetOnExited;
    property OnOutput:      TOnOutput      read GetOnOutput      write SetOnOutput;
    property OnDllLoaded:   TOnDllLoaded   read GetOnDllLoaded   write SetOnDllLoaded;
    property OnDllUnloaded: TOnDllUnloaded read GetOnDllUnloaded write SetOnDllUnloaded;
    property OnBpHit:       TOnBpHit       read GetOnBpHit       write SetOnBpHit;
  end;

function FrameOriginName(Origin: TFrameOrigin): string;

implementation

function FrameOriginName(Origin: TFrameOrigin): string;
const
  Names: array[TFrameOrigin] of string = (
    'unknown', 'seed', 'ebp-chain', 'prologue-probe', 'frameless-recover',
    'dbghelp-tail', 'dbghelp-whole', 'synth-seed', 'raw-proven', 'raw-unproven');
begin
  Result := Names[Origin];
end;

function TRegisterSnapshot.Pc: UInt64;
begin
  Result := Rip;
end;

function TRegisterSnapshot.StackPtr: UInt64;
begin
  Result := Rsp;
end;

function TRegisterSnapshot.FramePtr: UInt64;
begin
  Result := Rbp;
end;

end.
