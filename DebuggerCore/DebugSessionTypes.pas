unit DebugSessionTypes;

// Frontend-neutral vocabulary shared by every frontend that drives the
// debug engine. The DAP server and the (future) MCP server both sit on one
// `TDebugSession` core facade and speak these records instead of any
// wire-specific (JSON/DAP) shape.
//
// This unit is pure declarations: enums, value records, and option records.
// It contains NO classes, NO logic, and NO frontend dependency. Each frontend
// parses its own wire format into these neutral types (see TLaunchOptions /
// TAttachOptions) and renders these neutral types back out to its wire format.
//
// Handles are opaque (TVarHandle): a frontend passes them back verbatim to
// expand a variable; it must never treat one as a raw address or a DAP int.
//
// The only real types reused here are TStopReason and TFrameOrigin (from
// DebugTarget), so a stop event carries the same reason enum the engine already
// produces and a frame keeps the engine's own record of which unwind mechanism
// built it. DebugTarget does not depend on this unit, so no cycle is introduced.

interface

uses
  DebugTarget, DebugInfoTypes, ExceptionRules;

type
  TDebugSessionState = (
    dsNone,
    dsConfiguring,
    dsLaunching,
    dsAttaching,
    dsRunning,
    dsStopped,
    dsExited,
    dsDetached,
    dsTerminated
  );

  // Opaque expand token handed to a frontend and passed back to expand a
  // variable. Strong typedef so it cannot be confused with a raw address.
  // 0 = not expandable.
  TVarHandle = type UInt64;

  TProcessArch = (paUnknown, paX86, paX64, paArm64);

  // Who produced a line of output, because the three belong in different
  // places. okDebuggee is the program's own stdout and okLogPoint is a message
  // the USER authored on a breakpoint -- both are program-facing and belong in
  // the Debug Console. okDebugger is the debugger talking about itself (symbol
  // loading, modules without debug info, warnings), which is diagnostics and
  // drowns the other two when mixed with them.
  // okNotice is the debugger reporting a fault in something the USER wrote -- a
  // breakpoint condition that would not evaluate. It goes to the Debug Console
  // rather than the diagnostics channel precisely because it is about the user's
  // own input: burying it among symbol-loading lines is how it stayed invisible.
  TOutputKind = (okDebuggee, okDebugger, okLogPoint, okNotice);

  TVarKind = (
    vkScalar,
    vkClass,
    vkRecord,
    vkArray,
    vkPointer,
    vkSet,
    vkEnum,
    vkVariant,
    vkInterface,
    vkProperty,
    vkError,
    vkGroup      // synthetic category row ('properties'/'event handlers'/'fields')
  );

  TWaitKind = (wkNone, wkStop, wkExit, wkAny);

  TRegisterValue = record
    Name:  string;
    Value: UInt64;
    Size:  Byte;
  end;

  TSessionFrame = record
    Index:        Integer;
    FunctionName: string;
    SourceFile:   string;
    ModuleName:   string;
    SourceLine:   Integer;
    IP:           UInt64;
    // Why this frame has (or lacks) a name. A frame with FunctionName = '' is
    // otherwise indistinguishable between "unknown address", "module without
    // debug info" and "index still building"; ModuleName + Symbols make the
    // difference visible to every frontend. ModuleName is filled whenever a
    // module is known, named or not.
    Symbols:      TSymbolAvailability;
    // Raw selection data carried from TStackFrame so a frontend can re-root
    // locals/evaluate on this frame via TDebugSession.SelectFrame(Index).
    // The frame's arguments, already formatted and truncated, e.g.
    // `x: 42, Name: 'hello'`. Empty when the frame has none, when its symbols
    // do not say which slots are parameters, or when it sits past the depth
    // this is computed for (reading them costs a memory round trip per value).
    Arguments:    string;
    FrameRBP:     UInt64;   // this frame's RBP (for BPREL local/param decode)
    FuncEntryVA:  UInt64;   // VA of the frame's function entry (prolog read)
    // Which unwind mechanism produced this frame. Diagnostic: a stack is
    // assembled by several of them and a wrong frame is indistinguishable from a
    // right one, so this is what makes "who emitted it?" answerable.
    Origin:       TFrameOrigin;
  end;

  TSessionVariable = record
    Name:         string;
    Value:        string;
    TypeName:     string;
    Kind:         TVarKind;
    Expandable:   Boolean;
    Handle:       TVarHandle;
    EvaluateName: string;
    // The variable's own address in the debuggee, when it genuinely has one
    // (a stack local, a class/record field, an array element). 0 means "no
    // real address" -- a register-resident local, a synthetic group row
    // ('properties'/'fields'), or a value a getter CALL produced rather than
    // read from a slot. DAP's `memoryReference` (docs/ASSEMBLY_LEVEL_DEBUGGING.md
    // increment 3) is built from this and only emitted when it is non-zero;
    // every producer of a TSessionVariable follows the same convention
    // established locals already use (LV.Address <> 0 means addressable).
    Address:      UInt64;
    // Where the value's BYTES live, when that is NOT the variable's own
    // storage. A `string`, a dynamic array, a class instance and an interface
    // all occupy one pointer; dumping that pointer's bytes shows the pointer,
    // never the text or the elements -- which is precisely what someone asking
    // to see a variable's binary data wants. 0 means "the value is its own
    // storage" (an Integer, a record, a static array) and the caller uses
    // Address. A frontend that has to pick ONE address -- DAP's
    // `memoryReference` -- prefers this one when it is set.
    DataAddress:  UInt64;
    // How many bytes the value occupies at whichever of the two addresses above
    // is its own -- the string's characters, the array's elements, the object's
    // instance, the record's declared size. 0 means "not established", and it
    // stays 0 rather than being guessed: a memory view draws this range as the
    // variable's extent, and a wrong one would claim a neighbouring variable's
    // bytes belong to this one.
    ValueSize:    UInt64;
    // Set ONLY on a getter-backed property row: the spelling a safelist entry
    // for this member would use (e.g. 'TWidget.DoCalcScore', falling back to
    // 'TWidget.Score' when the getter's name is unknown). It is what the
    // frontend's "always evaluate this" / "never" actions write, so the row
    // and the archive cannot disagree about the member's identity. Empty
    // everywhere else.
    SafelistKey:  string;
  end;

  TSessionScope = record
    Name:   string;
    Handle: TVarHandle;
  end;

  TSessionThread = record
    Index:      Integer;
    OsThreadId: Cardinal;
    Name:       string;
    IsStopped:  Boolean;
    IsCurrent:  Boolean;
    // The thread's TEB values: what the last Win32 call stored, and the
    // NTSTATUS underneath it. HasLastError is False when they could not be
    // read -- a zero LastError is a real answer ("the last call succeeded")
    // and must not be confused with not knowing.
    HasLastError: Boolean;
    LastError:    Cardinal;
    LastStatus:   Cardinal;
  end;

  TSessionEvalResult = record
    Success:    Boolean;
    Value:      string;
    TypeName:   string;
    ErrorText:  string;
    Expandable: Boolean;
    Handle:     TVarHandle;
    // Raw evaluator outcome, exposed so a frontend can make its own cache /
    // retry decisions (e.g. the DAP eval-miss cache keys a confirmed miss on
    // IsValid=False). IsValid mirrors TExprValue.IsValid; RawValue is the
    // decoded pointer/integer (post VMT double-deref rewrite when applicable).
    IsValid:    Boolean;
    RawValue:   UInt64;
    // Same pair, and the same meaning, as TSessionVariable's: where the
    // expression's storage is (0 for an rvalue -- a computed sum, a value a
    // method call returned) and where its BYTES are when those are not the same
    // place. A watch on a string or a dynamic array is the case that motivated
    // carrying them here: without an address a watch row cannot offer "View
    // Binary Data" at all, and with the WRONG one it dumps a pointer.
    Address:     UInt64;
    DataAddress: UInt64;
    ValueSize:   UInt64;   // as TSessionVariable.ValueSize; 0 = not established
  end;

  // TBreakpointKind (bkSource / bkAddress) is DebugTarget's, reused verbatim so
  // there is one definition of "which identity does this breakpoint carry"
  // shared by the engine's TBreakpointRec and this session-facing record.
  TSessionBreakpoint = record
    Id:           string;
    Kind:         TBreakpointKind;  // bkSource (default) or bkAddress
    SourceFile:   string;           // bkSource only
    Line:         Integer;          // bkSource only
    // bkAddress only, mirroring TSessionDataBreakpoint's ModuleName/Rva/Address
    // fields for exactly the same reason: a bare VA does not survive a
    // relaunch or a rebased package, so the module+offset PAIR is the
    // identity and Address is only the last address it resolved to.
    ModuleName:   string;
    Rva:          UInt64;
    Address:      UInt64;
    Verified:     Boolean;
    // bkAddress only: refusal reason when Verified=False (address not
    // currently inside any loaded module, or its module has since unloaded),
    // '' otherwise. Source breakpoints keep their existing frontend-supplied
    // "No debug info for this line" text instead of using this field.
    Message:      string;
    Condition:    string;
    HitCondition: string;
    LogMessage:   string;
    HitCount:     Integer;
  end;

  // Which frame a data breakpoint's address belongs to, and therefore how long
  // that address means anything. dbtLocal is the ONLY kind whose address dies:
  // it is valid exactly while the frame identified by (ThreadId, FrameBase,
  // FuncEntryVA) is still on the stack (increment 6 of docs/DATA_BREAKPOINTS_PLAN.md).
  TDataBpScopeKind = (dbsAddress, dbsGlobal, dbsLocal);

  // Identity of the stack frame a dbsLocal watchpoint is scoped to. Compared
  // against the thread's live frames at EVERY stop; a frame that is gone makes
  // the watchpoint STALE and it is removed rather than left watching whatever
  // the next call reuses that slot for.
  //
  // Frame identity is (FrameBase, FuncEntryVA) rather than FrameBase alone
  // because a different routine reaching the same stack depth reuses the same
  // base. The residual, undetectable case is documented at FrameStillLive.
  TDataBpFrameScope = record
    Scoped:      Boolean;
    ThreadId:    Cardinal;
    FrameBase:   UInt64;
    FuncEntryVA: UInt64;
  end;

  // Session-facing data-breakpoint spec (increment 4 of docs/DATA_BREAKPOINTS_PLAN.md;
  // frame scoping added by increment 6). Expression is a literal address
  // ("$1234" / "0x1234" / a plain decimal) or a global/unit variable name
  // resolved the same way the evaluator resolves one.
  //
  // A LOCAL is only accepted through Frame: the caller must first have resolved
  // it against a live frame (TDebugSession.GetDataBreakpointInfo, which is what
  // DAP's dataBreakpointInfo request drives) and must pass the resulting address
  // as a literal together with that frame's identity. A bare local NAME is still
  // refused by name -- an address with no frame behind it is a watchpoint on
  // reused stack waiting to happen.
  TDataBpSpec = record
    Expression: string;
    SizeBytes:  Integer;   // must be 1, 2, 4 or 8; anything else is refused
    // False = read-or-write. There is no read-only hardware watchpoint on
    // x86/x64 -- WriteOnly=False does not FILTER to reads, it also fires on
    // writes, and the caller is told so via Message rather than left to find
    // out from a surprise hit.
    WriteOnly:  Boolean;
    // What to CALL this watchpoint in a stop description. '' = use Expression.
    // A frame-scoped local arrives as a literal address, so without this every
    // stop would read "$7ff6...: $1 -> $2a" instead of naming the variable.
    DisplayName: string;
    Frame:       TDataBpFrameScope;
  end;

  TSessionDataBreakpoint = record
    Id:         string;
    Expression: string;
    // Resolved module+RVA when Address falls inside a known module -- a bare
    // VA does not survive a relaunch or a rebased package (see address
    // breakpoints in docs/DISASSEMBLY_PLAN.md for the same reasoning). ModuleName
    // is '' when Address falls outside every known module.
    ModuleName: string;
    Rva:        UInt64;
    Address:    UInt64;
    SizeBytes:  Integer;
    WriteOnly:  Boolean;
    Slot:       Integer;    // hardware DR index actually holding this, -1 until armed
    Verified:   Boolean;
    // Refusal reason when Verified=False, or an informational note (e.g. the
    // read-or-write caveat above) when Verified=True.
    Message:    string;
    DisplayName: string;
    Frame:       TDataBpFrameScope;
  end;

  // What TDebugSession.GetDataBreakpointInfo could work out about a candidate
  // watchpoint target -- the neutral answer behind DAP's dataBreakpointInfo.
  // CanWatch=False means REFUSED, and Reason says why in the user's terms; the
  // request never guesses an address it cannot justify.
  //
  // AccessWrite / AccessReadWrite are the access types genuinely available on
  // this CPU. There is deliberately no read-only member: x86/x64 has no
  // read-only watchpoint, so offering one would be a filter that does not
  // exist. ReadWriteCaveat carries the sentence that must reach the user when
  // read-or-write is chosen.
  TDataBpTargetInfo = record
    CanWatch:    Boolean;
    Reason:      string;   // refusal reason when CanWatch=False
    Kind:        TDataBpScopeKind;
    DisplayName: string;   // what to call it ('V', 'GCounter', '$401000')
    Description: string;   // human-readable summary for the frontend to echo
    Address:     UInt64;
    SizeBytes:   Integer;
    ModuleName:  string;   // '' when the address is outside every known module
    Rva:         UInt64;
    Frame:       TDataBpFrameScope;
    AccessWrite:     Boolean;
    AccessReadWrite: Boolean;
    ReadWriteCaveat: string;
  end;

  TSessionExceptionInfo = record
    ExceptionClass: string;
    Message:        string;
    Description:    string;
    OsThreadId:     Cardinal;
    ObjectVA:       UInt64;
    Frames:         TArray<TSessionFrame>;
  end;

  TStopInfo = record
    Reason:       TStopReason;
    SourceFile:   string;
    SourceLine:   Integer;
    FunctionName: string;
    OsThreadId:   Cardinal;
    // Populated only when Reason = srException: the engine's decoded exception
    // description, so a frontend's stopped event carries it without an extra
    // GetExceptionDetails round trip.
    ExceptionDescription: string;
    // Populated only when Reason = srDataBreakpoint: "expression: old -> new
    // (thread N)". The thread that fired is also OsThreadId above -- naming
    // WHICH thread wrote the cell is frequently the whole answer, so it is not
    // buried inside this string alone.
    DataBreakpointDescription: string;
    // Populated only when Reason = srBreakpoint AND the breakpoint's condition
    // could not be evaluated. The stop happened BECAUSE the condition failed, so
    // a frontend that renders a stop reason must say so -- otherwise the user
    // sees an unconditional-looking stop on a line they conditioned.
    BreakpointConditionError: string;
  end;

  TCompactSnapshot = record
    State:           TDebugSessionState;
    StopReason:      TStopReason;
    CurrentFile:     string;
    CurrentFunction: string;
    CurrentLine:     Integer;
    OsThreadId:      Cardinal;
    TopFrames:       TArray<TSessionFrame>;
    Locals:          TArray<TSessionVariable>;
    HasException:    Boolean;
    Exception_:      TSessionExceptionInfo;
    // Populated only when StopReason = srDataBreakpoint; see TStopInfo.
    DataBreakpointDescription: string;
    // Populated when the stop happened because a breakpoint condition would not
    // evaluate; see TStopInfo.BreakpointConditionError.
    BreakpointConditionError: string;
  end;

  // Per runtime-module (DLL/BPL) sidecar overrides from a frontend's launch
  // config `modules` array. Name is the (case-insensitive) module file name;
  // the paths override the auto-discovered adjacent sidecars. Empty = today's
  // auto-discovery behaviour (the MCP frontend passes an empty array).
  TSessionModuleConfig = record
    Name:    string;
    MapPath: string;
    RsmPath: string;
    DcpPath: string;
  end;

  // Launch/attach options: each frontend parses its own wire format into these
  // neutral records before handing them to the engine.
  //
  // Exception config guard: an EMPTY/default block reproduces today's behaviour
  // exactly. ExceptionFiltersSet must be True for ExceptionFilters/
  // DelphiClassFilter to be applied; an empty ExceptionRules array is not
  // pushed to the engine. A caller that passes nothing (MCP) changes nothing.
  // One image mapped in the debuggee, and what the debugger can say about it.
  //
  // `Formats` is the point: "has symbols" is not one fact but several, and a
  // module answering from a `.map` alone cannot do what one with TD32 can.
  // Listing the formats that actually REGISTERED (not the ones that were
  // looked for) is what lets a caller tell "built without debug info" from
  // "sidecar missing next to the binary".
  TSessionModule = record
    Name:     string;    // lowercase file name, e.g. 'libtabanagd29.bpl'
    Path:     string;    // full path when the OS reported one
    Base:     UInt64;    // actual load base (may differ from the preferred one)
    Size:     UInt64;    // SizeOfImage, 0 when it could not be read
    IsMain:   Boolean;   // the executable itself, not a runtime-loaded module
    Symbols:  TSymbolAvailability;
    Formats:  TArray<string>;  // 'td32' | 'tds' | 'map' | 'rsm' | 'dcp' | 'jdbg'
  end;

  // The source files one module's debug info can name -- DAP's `loadedSources`,
  // grouped by module because "which file" is only half the question: the other
  // half is which image would own a breakpoint set in it.
  //
  // `ListedBy` names the format that produced `Files`. It is '' when none of the
  // module's loaded formats can enumerate (`.rsm`, `.dcp` and `.jdbg` map
  // addresses but hold no file index), which is a different fact from a module
  // having no source files at all -- without it the two are indistinguishable.
  TSessionModuleSources = record
    Module:   string;              // lowercase module file name
    IsMain:   Boolean;
    Formats:  TArray<string>;      // every format registered for the module
    ListedBy: string;              // 'td32' | 'tds' | 'map' | '' (cannot list)
    Complete: Boolean;             // False while the listing index is still filling
    Files:    TArray<TSourceFileEntry>;
  end;

  TLaunchOptions = record
    ExePath:          string;
    MapPath:          string;
    RsmPath:          string;
    SourceRoot:       string;
    ExtraSourcePaths: TArray<string>;
    Args:             string;
    StopAtEntry:      Boolean;
    Modules:          TArray<TSessionModuleConfig>;
    ExceptionRules:   TArray<TExceptionRule>;
    ExceptionFilters:    TExceptionFilters;
    ExceptionFiltersSet: Boolean;
    DelphiClassFilter:   string;
  end;

  TAttachOptions = record
    ProgramPath:      string;
    MapPath:          string;
    RsmPath:          string;
    SourceRoot:       string;
    ExtraSourcePaths: TArray<string>;
    Modules:          TArray<TSessionModuleConfig>;
    ExceptionRules:   TArray<TExceptionRule>;
    ExceptionFilters:    TExceptionFilters;
    ExceptionFiltersSet: Boolean;
    DelphiClassFilter:   string;
  end;

  TBpLineSpec = record
    Line:         Integer;
    Condition:    string;
    HitCondition: string;
    LogMessage:   string;
  end;

implementation

end.
