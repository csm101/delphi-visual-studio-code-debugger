unit Win64Debugger;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Winapi.Windows,
  DapProtocol, DebugInfoTypes, DebugInfoSet, DebugTarget, ExceptionRules,
  TargetLayout;

type
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
    FImageBase:    UInt64;
    FPreferredBase: UInt64;
    FDebugInfo:    TDebugInfoSet;
    FBreakpoints:  TList<TBreakpointRec>;
    FStepMode:     (smNone, smInto, smOver, smOut);
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
    // VA of a reusable scratch page in the debuggee used to hold the
    // hidden var-out result slot for managed / Variant / record getters.
    // Allocated lazily; zeroed on each use. One page (4 KB) is enough for
    // every supported return type.
    FRemoteScratch:   UInt64;
    FCommandQueue: TQueue<TCommand>;
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
    FDllBases:     TDictionary<string, UInt64>; // lowercase filename -> actual load base
    FDllSizes:     TDictionary<string, UInt64>; // lowercase filename -> SizeOfImage
    // lcase identifier -> DebugInfo revision at which it was confirmed absent
    // by the global resolver. Lets a repeat watch/hover of a genuinely-missing
    // name skip the multi-second indexing-retry below. Invalidated implicitly:
    // a module load bumps Revision, so a stale entry no longer matches.
    FGlobalMissCache: TDictionary<string, UInt64>;
    // Explicitly-selected call-stack frame (DAP frameId <> 0). When set,
    // GetLocalValues / the expression evaluator read THIS frame's locals
    // instead of the stopped top frame. 0 = top frame.
    FActiveFrameRBP:     UInt64;
    FActiveFrameEntryVA: UInt64;
    FActiveFrameName:    string;
    FActiveFramePC:      UInt64;  // selected frame's instruction pointer (VA),
                                  // for lexical-block scope filtering of locals

    function  VAToRva(VA: UInt64): UInt64;
    function  ReadByte(VA: UInt64; out B: Byte): Boolean;
    function  WriteByte(VA: UInt64; B: Byte): Boolean;
    function  ThreadHandle(TID: DWORD): THandle;
    function  FindBreakpointByVA(VA: UInt64): Integer;
    function  ReadFrameSize(EntryVA: UInt64): UInt32;
    // Recognised=False means "the prologue was not understood", which is NOT
    // the same as a zero-byte frame and must never be treated as one: every
    // address derived from the frame size would be silently wrong. Callers are
    // required to check it and refuse rather than guess.
    // ARCH: x86 has no .pdata at all, so its decoder is byte patterns only.
    function  ReadPrologInfo(EntryVA: UInt64; out ExtraPushBytes: UInt32;
                out Recognised: Boolean): UInt32; virtual;
    function  FunctionBodyStartVA(VA: UInt64): UInt64;
    function  ReadParentFramePointer(ChildRBP: UInt64;
                ChildFrameSize, ChildExtraPushBytes: UInt32): UInt64;
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
    // Machine type handed to StackWalk64. dbghelp already unwinds i386 as well
    // as amd64, so a 32-bit target changes this value rather than needing a
    // hand-rolled walker.
    function  StackWalkMachineType: DWORD; virtual;
    procedure SetTrapFlag(TID: DWORD; Enable: Boolean);
    procedure SetRIP(TID: DWORD; NewRIP: UInt64);
    function  CurrentRIP(TID: DWORD): UInt64;
    function  CurrentRSP(TID: DWORD): UInt64;
    function  CallerReturnAddress(TID: DWORD): UInt64;
    // True when VA lies inside a module dbghelp knows about and is executable --
    // i.e. it is plausibly a return address rather than a leaf-convention guess
    // read out of an uninitialised stack slot.
    function  IsPlausibleReturnAddress(VA: UInt64): Boolean;
    procedure EnsureSymInitialized;
    procedure RegisterModuleWithDbgHelp(const Path: string; Base, ImageSize: UInt64);
    procedure PlantStepBp(VA: UInt64);
    procedure ClearStepBps;
    procedure PlantInFuncStepBps;
    function  RvaInStepFunc(Rva: UInt64): Boolean;
    function  StepOverAtNewLine(Rva: UInt64): Boolean;
    procedure HandleSmOverStep(Tid: DWORD; PcVA: UInt64);
    procedure ApplyAllBreakpoints;
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
    // Thread enumeration (IDebugTarget).
    function  GetThreadIds: TArray<DWORD>;
    function  GetThreadName(TID: DWORD): string;
    function  GetStoppedThreadId: DWORD;
    // Called from debug thread after stop
    function  GetStackFrames: TArray<TStackFrame>; overload;
    function  GetStackFrames(TID: DWORD): TArray<TStackFrame>; overload;
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
    function  WriteMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    function  SetRegisterByName(const Name: string; Value: UInt64): Boolean;
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
    // Memory layout of the debuggee's address space. Fixed at 64-bit here; the
    // x86 implementation reports its own, and callers decoding target
    // structures must consult this rather than SizeOf(Pointer).
    function  TargetLayout: TTargetLayout; virtual;
    // Sets RIP of the currently stopped thread. Returns False if not stopped.
    function  SetInstructionPointer(VA: UInt64): Boolean;
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
    function  TryResolveClassRef(const ClassName: string; out VA: UInt64): Boolean;
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
                const ArgValues:  array of UInt64;
                const ArgIsFloat: array of Boolean;
                out IntResult, FloatResultLow: UInt64): Boolean;
    // Invokes a function in the debuggee, capturing the return value (RAX).
    // Public surface for the expression evaluator's method-backed property
    // getters. Arguments are positional; trailing ones may be 0 for unary
    // callees (Self only).
    function  RunRemoteCallEx(FuncVA: UInt64;
                Arg0, Arg1, Arg2, Arg3: UInt64;
                out IntResult, FloatResultLow: UInt64): Boolean;
  private
    function  RunRemoteCall(FuncVA: UInt64; Arg0, Arg1: UInt64): Boolean;
    // The only calling-convention-aware halves of the synthetic-call
    // machinery. The event pump between them is architecture neutral and stays
    // shared; a 32-bit target replaces exactly these two.
    function  PrepareSyntheticCall(TH: THandle; FuncVA: UInt64;
                const ArgValues: array of UInt64;
                const ArgIsFloat: array of Boolean;
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
    function  LastExceptionMessage: string;
    function  CurrentExceptionObject: UInt64;
    procedure SetExceptionRules(const Rules: TArray<TExceptionRule>);
    property  OnStopped:      TOnStopped     read GetOnStopped     write SetOnStopped;
    property  OnExited:       TOnExited      read GetOnExited      write SetOnExited;
    property  OnOutput:       TOnOutput      read GetOnOutput      write SetOnOutput;
    property  OnDllLoaded:    TOnDllLoaded   read GetOnDllLoaded   write SetOnDllLoaded;
    property  OnDllUnloaded:  TOnDllUnloaded read GetOnDllUnloaded write SetOnDllUnloaded;
    property  OnBpHit:        TOnBpHit       read GetOnBpHit       write SetOnBpHit;
  end;

implementation

{ DbgHelp bindings for StackWalk64 }

type
  // Matches C ADDRESS64: Offset(8) + Segment(2) + 2-byte pad + Mode(4) = 16 bytes
  TDbgAddress64 = record
    Offset:  UInt64;
    Segment: Word;
    Mode:    DWORD;  // ADDRESS_MODE enum (AddrModeFlat = 3); Delphi inserts 2-byte pad before
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
function LocalReadSize(const TypeName: string): Integer; forward;

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
  InitializeCriticalSection(FQueueLock);
  FFirstBreak             := False;
  FRunning                := False;
  FPendingContinueStatus  := DBG_CONTINUE;
  FIsStopped              := False;
  FExceptionFilters       := DEFAULT_EXCEPTION_FILTERS;
  FPauseRequested         := False;
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
function TWinDebugger.ReadDelphiExceptionClass(ObjAddr: UInt64): string;
const
  // Athens 36 Win64 VMT layout -- see DelphiRtti.pas for the empirical
  // mapping. TypeInfo lives at VMT+(-168) (NOT -144 like System.pas
  // claims). TypeInfo layout: Kind(1) + ShortString(name) + TypeData.
  VMT64_TYPEINFO_OFF = -168;
var
  VmtAddr, TypeInfoAddr: UInt64;
  Buf: array[0..255] of AnsiChar;
  Read: SIZE_T;
  Len: Byte;
begin
  Result := '';
  if ObjAddr = 0 then Exit;
  if not ReadProcessMemory(FProcess, Pointer(ObjAddr), @VmtAddr, 8, Read) or
     (Read <> 8) then Exit;
  if VmtAddr = 0 then Exit;
  if not ReadProcessMemory(FProcess, Pointer(Int64(VmtAddr) + VMT64_TYPEINFO_OFF),
       @TypeInfoAddr, 8, Read) or (Read <> 8) or (TypeInfoAddr = 0) then Exit;
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
const
  VMT64_TYPEINFO_OFF = -168;

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
  Read: SIZE_T;
begin
  Result := nil;
  if ObjAddr = 0 then Exit;
  if not ReadProcessMemory(FProcess, Pointer(ObjAddr), @VmtAddr, 8, Read) or
     (Read <> 8) or (VmtAddr = 0) then Exit;
  if not ReadProcessMemory(FProcess, Pointer(Int64(VmtAddr) + VMT64_TYPEINFO_OFF),
       @TypeInfoAddr, 8, Read) or (Read <> 8) or (TypeInfoAddr = 0) then Exit;
  var Depth := 0;
  while (TypeInfoAddr <> 0) and (Depth < 64) do begin
    var NameLen: Byte;
    var Nm := ReadTypeName(TypeInfoAddr, NameLen);
    if Nm = '' then Break;
    Result := Result + [Nm];
    // ParentInfo (PPTypeInfo) at TypeData + 8; TypeData = TypeInfoAddr + 2 + NameLen.
    var ParentInfoPtr: UInt64;
    if not ReadProcessMemory(FProcess,
         Pointer(TypeInfoAddr + 2 + UInt64(NameLen) + 8), @ParentInfoPtr, 8, Read) or
       (Read <> 8) or (ParentInfoPtr = 0) then Break;
    var ParentTypeInfo: UInt64;
    if not ReadProcessMemory(FProcess, Pointer(ParentInfoPtr), @ParentTypeInfo, 8, Read) or
       (Read <> 8) then Break;
    TypeInfoAddr := ParentTypeInfo;
    Inc(Depth);
  end;
end;

// System.SysUtils.Exception declares `FMessage: string` as its first field, so
// on Win64 it sits at offset 8 (right after the VMT pointer). The field holds a
// UnicodeString: a pointer to the char data, with the element count at [data-4].
function TWinDebugger.ReadDelphiExceptionMessage(ObjAddr: UInt64): string;
const
  EXCEPTION_FMESSAGE_OFF = 8;
var
  StrPtr: UInt64;
  Len: Integer;
  Read: SIZE_T;
begin
  Result := '';
  if ObjAddr = 0 then Exit;
  if not ReadProcessMemory(FProcess, Pointer(ObjAddr + EXCEPTION_FMESSAGE_OFF),
       @StrPtr, 8, Read) or (Read <> 8) or (StrPtr = 0) then Exit;
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

function TWinDebugger.StackWalkMachineType: DWORD;
begin
  Result := IMAGE_FILE_MACHINE_AMD64;
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
    var RetTop: UInt64 := 0;
    if ReadProcessMemoryAt(CurSP, @RetTop, 8) and (RetTop <> 0) then begin
      FStepResumeVA := RetTop;
      // CurSP is the RSP just after the CALL pushed the return address; the
      // matching RET pops it, so the stepped frame resumes at CurSP + 8. A hit
      // below that is a deeper recursive incarnation returning to the same site.
      {$Q-}
      FStepResumeSP := CurSP + 8;
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

function TWinDebugger.IsPlausibleReturnAddress(VA: UInt64): Boolean;
begin
  if VA = 0 then
    Exit(False);
  EnsureSymInitialized;
  if SymGetModuleBase64(FProcess, VA) = 0 then
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
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(TH, Ctx) then
    Exit;
  EnsureSymInitialized;

  SF := Default(TDbgStackFrame64);
  SF.AddrPC.Offset    := Ctx.Rip;
  SF.AddrPC.Mode      := AddrModeFlat;
  SF.AddrFrame.Offset := Ctx.Rbp;
  SF.AddrFrame.Mode   := AddrModeFlat;
  SF.AddrStack.Offset := Ctx.Rsp;
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
    for var Rva in FDebugInfo.SourceLineToRvaCandidates(Spec.SourceFile, Line) do begin
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
      // Before the startup break, ApplyAllBreakpoints will plant it (after
      // FImageBase is set), so we just register the spec here.
      // After startup, FImageBase is known and VA is correct -- plant immediately.
      if FFirstBreak then
        PlantInt3(BP);
      FBreakpoints.Add(BP);
    end;
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
      else
        FCommandQueue.Enqueue(C);
  finally
    LeaveCriticalSection(FQueueLock);
  end;
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
      ckContinue:
        if (FProcess <> 0) and FIsStopped then begin
          var ContStatus := FPendingContinueStatus;
          FIsStopped             := False;
          FPendingContinueStatus := DBG_CONTINUE;
          UnpatchBpAtRip;
          ReleasePendingEvent(ContStatus);
        end;
      ckStepInto: begin
        if not FIsStopped then
          Continue;
        // Step the DAP-selected thread (0 = the currently-stopped one) and freeze
        // the rest so only it advances.
        var StepTid := Cmd.ThreadId;
        if StepTid = 0 then
          StepTid := FStoppedTid;
        FIsStopped             := False;
        FPendingContinueStatus := DBG_CONTINUE;
        UnpatchBpAtRip(StepTid);
        FStepMode        := smInto;
        FStepSafetyCount := 0;
        FStepMinSP       := 0;
        var FromRva      := VAToRva(CurrentRIP(StepTid));
        FStepHasFromLoc  := FDebugInfo.RvaToSourceLine(FromRva, FStepFromLoc);
        SetTrapFlag(StepTid, True);
        FreezeThreadsForStep(StepTid);
        ReleasePendingEvent(DBG_CONTINUE);
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
        FIsStopped             := False;
        FPendingContinueStatus := DBG_CONTINUE;
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
            ReleasePendingEvent(DBG_CONTINUE);
            Exit;
          end;
        end;

        // Import thunk or no function range found: use return address (same as step-out).
        var RetAddr := CallerReturnAddress(StepTid);
        if RetAddr <> 0 then begin
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
          ReleasePendingEvent(DBG_CONTINUE);
          Exit;
        end;

        // Last resort: single-step
        FStepMode  := smInto;
        FStepMinSP := 0;
        SetTrapFlag(StepTid, True);
        ReleasePendingEvent(DBG_CONTINUE);
      end;
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
        FIsStopped             := False;
        FPendingContinueStatus := DBG_CONTINUE;
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
          ReleasePendingEvent(DBG_CONTINUE);
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
        ReleasePendingEvent(DBG_CONTINUE);
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
      srBreakpoint: Result := 'breakpoint';
      srStep:       Result := 'step';
      srException:  Result := 'exception';
      srPause:      Result := 'pause';
    else              Result := '?';
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
  if not TargetIsWow64 then
    Exit;
  DapLog('Unsupported target: 32-bit (WOW64) process. This debugger is Win64 only.');
  if not Assigned(FOnOutput) then
    Exit;
  FOnOutput('[FATAL] Target process is 32-bit (WOW64). This debugger supports Win64 targets only.');
  FOnOutput('        Call stacks, breakpoints and variables will NOT resolve for a 32-bit target.');
  FOnOutput('        Fix: debug the Win64 build -- host bin64\bds.exe and the module map/rsm from the Bpl\Win64 folder.');
end;

procedure TWinDebugger.HandleCreateProcess(const Ev: TDebugEvent);
begin
  FProcess   := Ev.CreateProcessInfo.hProcess;
  FProcessId := Ev.dwProcessId;
  FMainTid   := Ev.dwThreadId;  // primary thread -- retargeted-to on pause (F1)
  FImageBase := UInt64(Ev.CreateProcessInfo.lpBaseOfImage);
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
  E_lfanew: UInt32;
  SizeOfImage: UInt32;
  R: SIZE_T;
begin
  Base      := UInt64(Ev.LoadDll.lpBaseOfDll);
  ImageSize := 0;
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

  // Read SizeOfImage from the PE header in the mapped image
  E_lfanew := 0;
  if (Base > 0) and
     ReadProcessMemory(FProcess, Pointer(Base + $3C), @E_lfanew, 4, R) and (R = 4) then begin
    SizeOfImage := 0;
    if ReadProcessMemory(FProcess, Pointer(Base + E_lfanew + $50), @SizeOfImage, 4, R) and
       (R = 4) then
      ImageSize := SizeOfImage;
  end;

  // dbghelp must learn about this module too, not just our own MAP/RSM/TD32
  // loader: StackWalk64 reads its unwind info through dbghelp's module list.
  RegisterModuleWithDbgHelp(Path, Base, ImageSize);

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
              PlantStepBp(BpVA);
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
        var ShouldStop := True;
        if Assigned(FOnBpHit) and not (
            (FStepMode in [smOver, smOut]) and (BpVA = FStepOverVA)) then
          ShouldStop := FOnBpHit(BP);
        if not ShouldStop then begin
          ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
          Exit;
        end;
        if (FStepMode in [smOver, smOut]) and (BpVA = FStepOverVA) then begin
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
          ReportStopped(srBreakpoint, BpVA);
        end;
        Exit;
      end;

      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
    end;

    EXCEPTION_SINGLE_STEP, STATUS_WX86_SINGLE_STEP:
    begin
      FStoppedTid := Ev.dwThreadId;
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
        // The rearm consumed our trap-step. For smOver, that step may have been
        // the `call` that entered a callee -- evaluate NOW, at the callee entry,
        // where [RSP] is still the return address (one more step would be past
        // the prologue push and read a corrupted [RSP]). smInto just keeps
        // single-stepping; without re-arming TF it would run free.
        if FStepMode = smOver then begin
          HandleSmOverStep(Ev.dwThreadId, CurrentRIP(Ev.dwThreadId));
          Exit;
        end;
        if FStepMode = smInto then
          SetTrapFlag(Ev.dwThreadId, True);
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
      FLastExceptionClass   := ExcClass;
      FLastExceptionMessage := ExcMessage;
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

// Walk the call stack of an arbitrary thread. While stopped at a debug event the
// whole process is frozen, so every thread's context is valid and can be walked
// read-only. Frame records carry RBP/IP, so the locals decode (which reads
// process memory at the frame's RBP) works for any thread without further work.
function TWinDebugger.GetStackFrames(TID: DWORD): TArray<TStackFrame>;
var
  TH:    THandle;
  Ctx:   TContext;
  SF:    TDbgStackFrame64;
  Frame: TStackFrame;
  Loc:   TSourceLocation;
begin
  SetLength(Result, 0);
  TH := ThreadHandle(TID);
  if TH = 0 then
    Exit;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(TH, Ctx) then begin
    DapLog(Format('GetStackFrames(TID=%d): GetThreadContext FAILED LastErr=%d', [TID, GetLastError]));
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
     (FCachedFramesTID = TID) and (FCachedFramesRIP = Ctx.Rip) and
     (FCachedFramesRSP = Ctx.Rsp) and
     (FCachedFramesRev = FDebugInfo.Revision) and
     (Length(FCachedFrames) > 0) then
    Exit(FCachedFrames);

  // Lazy init: enumerates every module mapped so far so StackWalk64 can read
  // .pdata unwind info for each one. Modules mapped later are registered from
  // HandleLoadDll -- this sweep sees only what exists right now.
  EnsureSymInitialized;

  // StackWalk64 MUTATES Ctx into the unwound state of each frame it yields, so
  // the cache key must be taken from the seed context here -- reading it back off
  // Ctx after the loop stored the LAST frame's registers under a key that is
  // compared against the live seed, which no healthy walk could ever match.
  var SeedRip := Ctx.Rip;
  var SeedRsp := Ctx.Rsp;
  var SeedRbp := Ctx.Rbp;

  SF := Default(TDbgStackFrame64);
  SF.AddrPC.Offset    := Ctx.Rip;
  SF.AddrPC.Mode      := AddrModeFlat;
  SF.AddrFrame.Offset := Ctx.Rbp;
  SF.AddrFrame.Mode   := AddrModeFlat;
  SF.AddrStack.Offset := Ctx.Rsp;
  SF.AddrStack.Mode   := AddrModeFlat;

  while StackWalk64(StackWalkMachineType, FProcess, TH, SF, @Ctx,
      nil, @SymFunctionTableAccess64, @SymGetModuleBase64, nil) do begin
    if SF.AddrPC.Offset = 0 then
      Break;
    Frame.IP := SF.AddrPC.Offset;
    // StackWalk64 updates @Ctx to the unwound register state for THIS
    // frame; Ctx.Rbp is the frame's actual RBP, which the BPREL local /
    // param offset decode is relative to. SF.AddrFrame is unwind-defined
    // and not a reliable RBP for Delphi frames, so prefer Ctx.Rbp (fall
    // back to AddrFrame only if the context RBP is zero).
    if Ctx.Rbp <> 0 then
      Frame.FrameRBP := Ctx.Rbp
    else
      Frame.FrameRBP := SF.AddrFrame.Offset;
    var FrameRva := VAToRva(SF.AddrPC.Offset);
    // Frame 0 is the live RIP; every caller frame carries a RETURN address,
    // i.e. the instruction AFTER the call. Looking that up maps to the line
    // following the call site (e.g. an Assert call reports the next line).
    // Symbolicate return addresses at RVA-1 so the reported line / function
    // is the call site itself.
    var LookupRva := FrameRva;
    if (Length(Result) > 0) and (FrameRva > 0) then
      LookupRva := FrameRva - 1;
    if FDebugInfo.RvaToSourceLine(LookupRva, Loc) then begin
      Frame.SourceFile := Loc.SourceFile;
      Frame.SourceLine := Loc.Line;
    end else begin
      Frame.SourceFile := '';
      Frame.SourceLine := 0;
    end;
    if not FDebugInfo.RvaToFunctionName(LookupRva, Frame.FunctionName) then
      Frame.FunctionName := '';
    var FuncRva: UInt64 := 0;
    if FDebugInfo.RvaToFunctionStart(LookupRva, FuncRva) then
      Frame.FuncEntryVA := RvaToVA(FuncRva)
    else
      Frame.FuncEntryVA := 0;
    Result := Result + [Frame];
    if Length(Result) >= 30 then
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
  R:   SIZE_T;
  ScopeRva: UInt64;

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

    var Globals := FDebugInfo.GetGlobalsForRva(ScopeRva);
    var BestIdx := -1;
    for var I := 0 to High(Globals) do begin
      if Globals[I].RVA = 0 then
        Continue;
      if not SameText(TailName(Globals[I].Name), Query) then
        Continue;
      if LooksLikeCodeSymbol(Globals[I].Name) then
        Continue;
      // Prefer the shortest qualified name as the least ambiguous match.
      if (BestIdx < 0) or (Length(Globals[I].Name) < Length(Globals[BestIdx].Name)) then
        BestIdx := I;
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

    if (Rva = 0) and (ExactRva <> 0) then begin
      Rva := ExactRva;
      DapLog(Format('EvaluateGlobalName "%s": accept code-resident exact match Rva=$%x (no data candidate)',
        [Name, Rva]));
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
  var ReadSize := LocalReadSize(Value.TypeHint);
  if ReadProcessMemory(FProcess, Pointer(Value.Address), @Value.RawValue,
       ReadSize, R) and (R = SIZE_T(ReadSize)) then
    Value.ValueValid := True;

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
  const ArgValues: array of UInt64; const ArgIsFloat: array of Boolean;
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
  for var I := 0 to High(ArgValues) do begin
    if I < 4 then begin
      if ArgIsFloat[I] then XmmRegs[I] := ArgValues[I]
      else                  IntRegs[I] := ArgValues[I];
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
  const ArgValues: array of UInt64; const ArgIsFloat: array of Boolean;
  out IntResult, FloatResultLow: UInt64): Boolean;
var
  TH:       THandle;
  SavedCtx: TContext;
  Ev:       TDebugEvent;
begin
  Result    := False;
  IntResult      := 0;
  FloatResultLow := 0;
  if Length(ArgValues) <> Length(ArgIsFloat) then Exit;
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
  SavedCtx.ContextFlags := CONTEXT_FULL or CONTEXT_FLOATING_POINT;
  if not GetThreadContext(TH, SavedCtx) then Exit;

  if not PrepareSyntheticCall(TH, FuncVA, ArgValues, ArgIsFloat, SavedCtx) then
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
  AtomicExchange(FAbortRemoteCall, 0);
  AtomicExchange(FInRemoteCall, 1);
  var CallDeadline := GetTickCount64 + REMOTE_CALL_TIMEOUT_MS;
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
    [False, False, False, False], IntResult, FloatResultLow);
end;

function TWinDebugger.SetStringVariable(VarAddr: UInt64; const Text, TypeHint: string): Boolean;
var
  HelperName: string;
  HelperRva:  UInt64;
  NewPtr:     UInt64;
begin
  Result := False;
  if (TypeHint = 'UnicodeString') or (TypeHint = 'string') or
     (TypeHint = 'WideString') then
    HelperName := '@UStrAsg'
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
  Result := True;
  if      N = 'rip' then Ctx.Rip := Value
  else if N = 'rsp' then Ctx.Rsp := Value
  else if N = 'rbp' then Ctx.Rbp := Value
  else if N = 'rax' then Ctx.Rax := Value
  else if N = 'rbx' then Ctx.Rbx := Value
  else if N = 'rcx' then Ctx.Rcx := Value
  else if N = 'rdx' then Ctx.Rdx := Value
  else if N = 'rsi' then Ctx.Rsi := Value
  else if N = 'rdi' then Ctx.Rdi := Value
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
    // Clean detach. Two things must happen BEFORE DebugActiveProcessStop or the
    // detached target hits our INT3 with no debugger listening and the RTL
    // surfaces it as an unhandled External exception 80000003:
    //   1) Restore every planted INT3 to its original byte.
    //   2) If we are stopped on a held debug event (BP the client never
    //      resumed), release it with DBG_CONTINUE.
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

type
  PRuntimeFunctionEntry = ^TRuntimeFunctionEntry;
  TRuntimeFunctionEntry = packed record
    BeginAddress, EndAddress, UnwindInfoAddress: UInt32;
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
  if RF = nil then
    Exit;
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
function LocalReadSize(const TypeName: string): Integer;
begin
  if (TypeName = 'Byte') or (TypeName = 'ShortInt') or
     (TypeName = 'AnsiChar') or (TypeName = 'UTF8Char') or
     (TypeName = 'Boolean') or (TypeName = 'ByteBool') then
    Exit(1);
  if (TypeName = 'Word') or (TypeName = 'SmallInt') or
     (TypeName = 'WideChar') or (TypeName = 'Char') or
     (TypeName = 'UCS2Char') or (TypeName = 'WordBool') then
    Exit(2);
  if (TypeName = 'Integer') or (TypeName = 'Cardinal') or
     (TypeName = 'LongInt') or (TypeName = 'LongWord') or
     (TypeName = 'FixedInt') or (TypeName = 'FixedUInt') or
     (TypeName = 'Int32') or (TypeName = 'UInt32') or
     (TypeName = 'Single') or (TypeName = 'HRESULT') or
     (TypeName = 'LongBool') then
    Exit(4);
  // tkInt64, tkFloat (Double / Extended / TDateTime / Currency), all
  // pointer-sized types (class / interface / string / dyn-array / record
  // address / Variant address / Variant data / etc.) all use the full
  // 8-byte slot. Returning 8 as the default keeps existing call paths
  // unchanged for everything we used to read this way.
  Result := 8;
end;

// Builds TLocalValue records for one procedure's locals given:
//   FrameRBP    - the value of RBP for that procedure's frame
//   FuncEntryVA - VA of the procedure's first instruction (to read the prolog)
//   FuncName    - simple name used to look up locals in debug info
//   NamePrefix  - optional string prepended to each local's name (e.g. parent.)
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
  var LocalsBase := Integer(SubRspN) - Integer(SubRspN mod 16);
  var ParamsBase := Integer(SubRspN) + Integer(ExtraPushBytes);
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
    V.TypeHint   := Sym.TypeHint;
    V.Kind       := Sym.Kind;
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
    var ReadSize: Integer := LocalReadSize(Sym.TypeHint);
    if ReadProcessMemoryAt(V.Address, @V.RawValue, ReadSize) then begin
      V.ValueValid := True;
      if (V.Kind = lkVarParam) and (V.RawValue <> 0) and
         ReadProcessMemoryAt(V.RawValue, @V.DerefValue, 8) then
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
end;

function TWinDebugger.GetLocalValuesForFrame(FrameRBP, FuncEntryVA: UInt64;
  const FuncName: string; FramePcRva: UInt64): TArray<TLocalValue>;
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
    var ChildExtraPushes: UInt32;
    var ChildRecognised:  Boolean;
    var ChildFrameSize   := ReadPrologInfo(CurEntry, ChildExtraPushes, ChildRecognised);
    // Walking to the parent frame from an unrecognised prologue would follow a
    // pointer read from an arbitrary stack slot. Stop the walk instead.
    if not ChildRecognised then
      Break;
    var ParentRBP        := ReadParentFramePointer(CurRBP, ChildFrameSize, ChildExtraPushes);
    if ParentRBP = 0 then
      Break;
    // Resolve the parent's body RVA. Prefer the RVA-keyed map (unique,
    // same-unit) over a name round-trip -- NameToRva on a bare parent
    // leaf (e.g. `Mid`) collides when two units each have one.
    var ParentRva: UInt64;
    if not FDebugInfo.GetEnclosingProcedureRvaByRva(CurInnerRva, ParentRva) then
      if not FDebugInfo.NameToRva(ParentName, ParentRva) then
        Break;
    var ParentEntry := RvaToVA(ParentRva);
    Result := Result + CollectLocalsForFrame(
      ParentRBP, ParentEntry, ParentName, ParentName + '.', {FramePcRva=}0);
    CurName     := ParentName;
    CurRBP      := ParentRBP;
    CurEntry    := ParentEntry;
    CurInnerRva := ParentRva;
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
