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
  TOutputKind = (okDebuggee, okDebugger, okLogPoint);

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
  end;

  TSessionBreakpoint = record
    Id:           string;
    SourceFile:   string;
    Line:         Integer;
    Verified:     Boolean;
    Condition:    string;
    HitCondition: string;
    LogMessage:   string;
    HitCount:     Integer;
  end;

  // Session-facing data-breakpoint spec (increment 4 of DATA_BREAKPOINTS_PLAN.md).
  // Expression is a literal address ("$1234" / "0x1234" / a plain decimal) or a
  // global/unit variable name resolved the same way the evaluator resolves one.
  // Locals are explicitly out of scope here -- their lifetime is tied to a
  // stack frame, which needs dataBreakpointInfo (increment 6); SetDataBreakpoints
  // refuses them by name rather than silently accepting a stale address.
  TDataBpSpec = record
    Expression: string;
    SizeBytes:  Integer;   // must be 1, 2, 4 or 8; anything else is refused
    // False = read-or-write. There is no read-only hardware watchpoint on
    // x86/x64 -- WriteOnly=False does not FILTER to reads, it also fires on
    // writes, and the caller is told so via Message rather than left to find
    // out from a surprise hit.
    WriteOnly:  Boolean;
  end;

  TSessionDataBreakpoint = record
    Id:         string;
    Expression: string;
    // Resolved module+RVA when Address falls inside a known module -- a bare
    // VA does not survive a relaunch or a rebased package (see address
    // breakpoints in DISASSEMBLY_PLAN.md for the same reasoning). ModuleName
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
