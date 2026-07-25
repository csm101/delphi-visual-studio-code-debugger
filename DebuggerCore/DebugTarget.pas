unit DebugTarget;

// Target-agnostic debugger contract used by the DAP layer and the expression
// evaluator. The Win64 process-API implementation is `TWinDebugger`
// (Win64Debugger.pas); a future Win32 (or attach-mode, or remote) target
// implements the same interface.
//
// Types previously declared inside Win64Debugger.pas (TStopReason,
// TRegisterSnapshot, TLocalValue, TStackFrame, the event callback
// signatures, TBreakpointRec, TBpSpec, TCommand) live here so that
// alternative implementations don't have to depend on Win64Debugger.

interface

uses
  System.SysUtils, Winapi.Windows, DebugInfoTypes, ExceptionRules, TargetLayout;

type
  TStopReason = (srEntry, srBreakpoint, srStep, srException, srPause);

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

  TRegisterSnapshot = record
    Rip, Rsp, Rbp:                           UInt64;
    Rax, Rbx, Rcx, Rdx, Rsi, Rdi:            UInt64;
    R8,  R9,  R10, R11, R12, R13, R14, R15:  UInt64;
    EFlags:                                  UInt32;
    Valid:                                   Boolean;
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
    RegId:      Word;        // 0 = stack-allocated (Address valid).
                             // > 0 = register-allocated; runtime value
                             // read through GetRegisters instead of
                             // ReadProcessMemoryAt(Address).
  end;

  TStackFrame = record
    IP:           UInt64;
    FunctionName: string;
    SourceFile:   string;
    SourceLine:   Integer;
    FrameRBP:     UInt64;   // this frame's RBP (StackWalk64 AddrFrame)
    FuncEntryVA:  UInt64;   // VA of the frame's function entry (for prolog)
  end;

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
  end;

  TCommandKind = (ckContinue, ckStepInto, ckStepOver, ckStepOut, ckPause,
    ckSetBreakpoints);

  TBpSpec = record
    SourceFile:    string;
    Lines:         TArray<Integer>;
    Conditions:    TArray<string>;
    HitConditions: TArray<string>;
    LogMessages:   TArray<string>;
  end;

  TCommand = record
    Kind:     TCommandKind;
    ThreadId: DWORD;    // step target for ckStep*: 0 = the currently-stopped thread
    BpSpec:   TBpSpec;
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
                const ArgValues:  array of UInt64;
                const ArgIsFloat: array of Boolean;
                out RaxResult, Xmm0Low: UInt64): Boolean;
    function  RunRemoteCallEx(FuncVA: UInt64;
                ArgRcx, ArgRdx, ArgR8, ArgR9: UInt64;
                out RaxResult, Xmm0Low: UInt64): Boolean;

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

implementation

end.
