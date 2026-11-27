unit CodePatchMap;

// Everything the debugger writes into the target's code that is NOT a
// breakpoint (docs/PROFILER_COVERAGE_PLAN.md, "One map of patched bytes";
// docs/DAP_DEBUGGER_ARCHITECTURE.md, "Code patches").
//
// Breakpoints stay in TWinDebugger.FBreakpoints. A patch is a span of the
// program's bytes replaced for the benefit of a collection (coverage,
// profiling). This increment carries ONE form:
//
//   one-shot   a $CC on the first byte of a line record. The first thread that
//              executes it traps; the debugger records the hit by (module,
//              RVA), puts the program's byte back, rewinds the thread onto the
//              instruction and resumes it. No stop is reported and nothing is
//              single-stepped.
//
// The map is the single owner of three facts about every address it patched:
//
//   * the program's bytes there, so that every reader of code can be shown the
//     program and never a patch (Overlay), and so that a breakpoint planted on
//     the same address saves the PROGRAM's byte (HoldsInt3At);
//   * whether the byte in the target is still ours (the state of the entry),
//     so that a trap arriving after its byte was restored is recognised as
//     ours and rewound instead of being handed to the program (an entry is
//     never forgotten while its module stays mapped: the "tombstone");
//   * what was hit, by (result key, RVA), which outlives the mapping: a module
//     that is unloaded and loaded again is patched afresh and keeps what it
//     had already counted.
//
// One byte, two owners. A breakpoint and a patch can sit on the same address,
// each believing the $CC is its own. The rule both sides follow:
//
//     the byte in the target is $CC  <=>  a breakpoint record is planted there
//                                         OR a patch is armed there
//
// so a side that gives the byte up writes the program's byte back only when the
// other side does not hold it, and a side that claims the byte writes only when
// the other does not hold it already. The map is told which addresses the
// breakpoints hold through a list (TCodePatchForeignByte); the engine asks the
// map through HoldsInt3At.
//
// Shape for the forms still to come (a five-byte jump or call, a retargeted
// call, a $CC that sends the thread to a trampoline): an entry has a LENGTH,
// and Overlay, the restore and the unload purge work on spans. What is missing
// for them is storage for more than one saved byte (TCodePatchEntry.Saved is
// the one byte a $CC replaces) and a second table that maps a trampoline
// address back to the entry it stands for; neither changes what is here.
//
// The unit knows no engine and no process handle: memory comes through three
// callbacks, which is also what lets it be tested without a process.
//
// Thread safety: none. Every method is called on the thread that dispatches
// debug events.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults;

const
  /// <summary>The breakpoint instruction.</summary>
  CODE_PATCH_INT3 = $CC;
  /// <summary>Two patches further apart than this are never written by one
  /// call: the bytes between them would be rewritten for nothing, and every
  /// page a write touches becomes private to the process.</summary>
  CODE_PATCH_MAX_GAP = $1000;
  /// <summary>Longest span read and written in one call.</summary>
  CODE_PATCH_MAX_RUN = $10000;

type
  /// <summary>The form of a patch.</summary>
  TCodePatchKind = (
    /// <summary>A $CC that is taken away at its first hit.</summary>
    cpkOneShot
  );

  /// <summary>What has become of a patch in the mapping it was written into.</summary>
  TCodePatchState = (
    /// <summary>The patch is in the target.</summary>
    cpsArmed,
    /// <summary>It was hit and recorded; the program's bytes are back.</summary>
    cpsFired,
    /// <summary>Taken away while the debugger's own synthetic call runs
    /// through it; it goes back when the call ends.</summary>
    cpsSuspended,
    /// <summary>Taken away without a hit (the collection was stopped, or the
    /// debugger is detaching).</summary>
    cpsWithdrawn,
    /// <summary>The bytes in the target were no longer ours when they were to
    /// be restored: something else wrote there. Left alone.</summary>
    cpsLost
  );

  /// <summary>What the map knows about the address of a breakpoint trap.</summary>
  TCodePatchTrap = (
    /// <summary>Nothing: the map never patched this address in this mapping.</summary>
    cptNone,
    /// <summary>A patch is armed there: this is its hit.</summary>
    cptArmed,
    /// <summary>The patch is suspended for a synthetic call.</summary>
    cptSuspended,
    /// <summary>The map patched this address once and took the bytes back: a
    /// trap from there was raised before the restore and arrives after it.</summary>
    cptSpent
  );

  /// <summary>An address whose $CC is held by ANOTHER owner (a planted
  /// breakpoint record), with the program's byte that owner saved.</summary>
  TCodePatchForeignByte = record
    /// <summary>The address.</summary>
    VA: UInt64;
    /// <summary>The program's byte there.</summary>
    ProgramByte: Byte;
  end;

  /// <summary>One region of the target's address space with uniform
  /// protection.</summary>
  TCodePatchRegion = record
    /// <summary>First address of the region.</summary>
    Base: UInt64;
    /// <summary>Its size in bytes.</summary>
    Size: UInt64;
    /// <summary>Committed and readable.</summary>
    Accessible: Boolean;
  end;

  /// <summary>Reads the target's memory as it IS, patches included.</summary>
  /// <param name="VA">First address.</param>
  /// <param name="Buf">Destination.</param>
  /// <param name="Size">Bytes wanted.</param>
  /// <returns>True when every byte was read.</returns>
  TCodePatchRead = reference to function(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;

  /// <summary>Writes into the target's code: makes the pages writable, writes,
  /// puts the protection back. All pages of one call lie in one region.</summary>
  /// <param name="VA">First address.</param>
  /// <param name="Buf">Source.</param>
  /// <param name="Size">Bytes to write.</param>
  /// <returns>True when every byte was written.</returns>
  TCodePatchWrite = reference to function(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;

  /// <summary>Describes the region an address lies in.</summary>
  /// <param name="VA">Any address.</param>
  /// <param name="Region">The region.</param>
  /// <returns>False when the address space cannot be queried there.</returns>
  TCodePatchQuery = reference to function(VA: UInt64; out Region: TCodePatchRegion): Boolean;

  /// <summary>How the map reaches the target's memory.</summary>
  TCodePatchMemory = record
    /// <summary>Raw read.</summary>
    Read: TCodePatchRead;
    /// <summary>Code write.</summary>
    Write: TCodePatchWrite;
    /// <summary>Region query.</summary>
    Query: TCodePatchQuery;
  end;

  /// <summary>What one call to arm patches did.</summary>
  TCodePatchArmOutcome = record
    /// <summary>Distinct addresses asked for.</summary>
    Requested: Integer;
    /// <summary>Patches now in the target because of this call.</summary>
    Armed: Integer;
    /// <summary>Of those, armed without a write: a breakpoint already held the
    /// byte.</summary>
    SharedWithBreakpoint: Integer;
    /// <summary>Already in the map for this mapping, armed or spent: left as
    /// they were.</summary>
    AlreadyPresent: Integer;
    /// <summary>Recorded as hit in an earlier mapping of the module: a one-shot
    /// has nothing more to say about them, so they are not armed again.</summary>
    AlreadyHit: Integer;
    /// <summary>Refused: the program's own byte there is a breakpoint
    /// instruction.</summary>
    OwnBreakpointInstruction: Integer;
    /// <summary>Refused: the address is outside the module.</summary>
    OutsideModule: Integer;
    /// <summary>Not armed: the bytes could not be read.</summary>
    Unreadable: Integer;
    /// <summary>Not armed: the write failed.</summary>
    WriteFailed: Integer;
    /// <summary>True when nothing was armed because the map holds armed
    /// patches of a module at the same address under another result key (or
    /// another image size): the caller named one module two ways.</summary>
    Conflict: Boolean;
    /// <summary>Spans read and written: one read, and at most one write, each.</summary>
    Runs: Integer;
    /// <summary>Calls that wrote into the target.</summary>
    WriteCalls: Integer;
    /// <summary>Bytes those calls covered (patched bytes and the program's own
    /// bytes between them, rewritten unchanged).</summary>
    BytesWritten: UInt64;
    /// <summary>Time the call took, in milliseconds.</summary>
    Milliseconds: Double;
    /// <summary>The addresses refused as the program's own breakpoint
    /// instruction, module-relative.</summary>
    OwnBreakpointRvas: TArray<Cardinal>;
  end;

  /// <summary>What taking patches away did.</summary>
  TCodePatchDisarmOutcome = record
    /// <summary>Patches whose bytes went back to the program.</summary>
    Restored: Integer;
    /// <summary>Patches given up without a write: a breakpoint holds the byte
    /// and keeps it.</summary>
    LeftToBreakpoint: Integer;
    /// <summary>Patches whose bytes were no longer ours: left alone.</summary>
    Lost: Integer;
    /// <summary>Calls that wrote into the target.</summary>
    WriteCalls: Integer;
  end;

  /// <summary>Counters of a map, for reports and tests.</summary>
  TCodePatchStats = record
    /// <summary>Modules with entries in the map.</summary>
    Modules: Integer;
    /// <summary>Entries the map remembers (armed or not).</summary>
    Entries: Integer;
    /// <summary>Patches in the target now.</summary>
    Armed: Integer;
    /// <summary>Patches suspended for a synthetic call now.</summary>
    Suspended: Integer;
    /// <summary>Hits recorded since the map was created or cleared.</summary>
    HitsRecorded: Integer;
    /// <summary>Hits consumed without being recorded: caused by the debugger's
    /// own synthetic call.</summary>
    HitsBySyntheticCall: Integer;
    /// <summary>Traps that arrived after their byte had been restored and were
    /// rewound.</summary>
    LateTraps: Integer;
    /// <summary>Restores that found the bytes changed by someone else.</summary>
    Lost: Integer;
  end;

  /// <summary>One request to arm one-shot probes in a loaded module.</summary>
  TCodePatchArmRequest = record
    /// <summary>Load address of the module, as its load event reported it.</summary>
    ModuleBase: UInt64;
    /// <summary>The name the results are kept under. It must be the same at
    /// every load of the module: results outlive the mapping.</summary>
    ResultKey: string;
    /// <summary>Module-relative addresses. The caller answers for each being
    /// the first byte of an instruction: the engine checks only what it can
    /// see in the bytes.</summary>
    Rvas: TArray<Cardinal>;
    /// <summary>Must be True for a process attached to with killOnDetach
    /// false. Windows has been told to let such a process live if the debugger
    /// dies, and a debugger that dies cannot take its breakpoint bytes back:
    /// the process would then stop at its next unexecuted line.</summary>
    AcceptBreakpointBytesLeftBehindIfTheDebuggerDies: Boolean;
  end;

  /// <summary>The engine's entry points for code patches. An interface of its
  /// own (IDebugTarget has a second implementer in the tests): the engine
  /// class implements it and callers reach it with <c>Supports</c>. Every
  /// method must be called on the thread that pumps the debug events.</summary>
  ICodePatchTarget = interface
    ['{C9F2A1B0-4D3E-44F8-8A22-9F5D8E0C7313}']
    /// <summary>Writes a one-shot probe on each address of a request.</summary>
    /// <remarks>Refused as a whole, with nothing written, when there is no
    /// live process, when no module is mapped at <c>ModuleBase</c>, and for a
    /// process attached to with killOnDetach false unless the request accepts
    /// the risk. An address whose byte is already $CC in the program is
    /// refused individually. When the process is not stopped its threads are
    /// suspended for the duration of the writes.</remarks>
    /// <param name="Request">Module, result key, addresses.</param>
    /// <param name="Outcome">What was armed and what was not.</param>
    /// <param name="Refusal">Why the request was refused as a whole.</param>
    /// <returns>False when the request was refused as a whole.</returns>
    function ArmOneShotProbes(const Request: TCodePatchArmRequest;
      out Outcome: TCodePatchArmOutcome; out Refusal: string): Boolean;
    /// <summary>Takes every armed probe of a module away without recording
    /// anything; the results stay.</summary>
    /// <param name="ModuleBase">Load address of the module; 0 for every
    /// module.</param>
    /// <returns>What was restored.</returns>
    function DisarmProbes(ModuleBase: UInt64): TCodePatchDisarmOutcome;
    /// <summary>The addresses recorded as hit under a result key.</summary>
    /// <param name="ResultKey">The key the probes were armed with.</param>
    /// <returns>Module-relative addresses, ascending, without repeats. Valid
    /// while the process runs and after it has ended.</returns>
    function ProbeHits(const ResultKey: string): TArray<Cardinal>;
    /// <summary>The addresses that carry an armed probe now.</summary>
    /// <param name="ModuleBase">Load address of the module.</param>
    /// <returns>Module-relative addresses, ascending.</returns>
    function ArmedProbes(ModuleBase: UInt64): TArray<Cardinal>;
    /// <summary>Whether the module mapped at an address has been armed in this
    /// mapping. False again once the mapping is gone -- also right after an
    /// unload the pump of a synthetic call saw, which reaches the session only
    /// at the next turn of the main loop.</summary>
    /// <param name="ModuleBase">Load address of the module.</param>
    function ModuleIsArmed(ModuleBase: UInt64): Boolean;
    /// <summary>Forgets every recorded hit. Armed probes stay armed; a probe
    /// that has fired stays fired.</summary>
    procedure ClearProbeHits;
    /// <summary>Counters.</summary>
    function CodePatchStats: TCodePatchStats;
  end;

  /// <summary>One patch, as the map keeps it. Eight bytes.</summary>
  TCodePatchEntry = packed record
    /// <summary>First patched byte, module-relative.</summary>
    Rva: Cardinal;
    /// <summary>What has become of the patch.</summary>
    State: TCodePatchState;
    /// <summary>Its form.</summary>
    Kind: TCodePatchKind;
    /// <summary>Bytes of the program the patch replaced: 1 for a $CC.</summary>
    Len: Byte;
    /// <summary>The program's byte, for a patch of length 1.</summary>
    Saved: Byte;
  end;

  /// <summary>The patches of one debugged process.</summary>
  TCodePatchMap = class
  private type
    TModuleTable = class
      Key:     string;
      Base:    UInt64;
      Size:    UInt64;
      Entries: TArray<TCodePatchEntry>;
      Armed:   Integer;
      // Longest span of an entry: how far below a window an entry that still
      // reaches into it can start.
      MaxLen:  Integer;
      function IndexOf(Rva: Cardinal): Integer;
      function FirstAtOrAfter(Rva: Cardinal): Integer;
    end;
  private
    FMemory:    TCodePatchMemory;
    FModules:   TObjectList<TModuleTable>;
    // Hits of mappings that are gone, by result key: sorted, without repeats.
    FKept:      TObjectDictionary<string, TList<Cardinal>>;
    FSuspended: TList<UInt64>;
    FArmedTotal: Integer;
    FEntryTotal: Integer;
    FHitsRecorded:  Integer;
    FHitsBySynthCall: Integer;
    FLateTraps: Integer;
    FLost:      Integer;
    function  ModuleAt(Base: UInt64): TModuleTable;
    function  ModuleHolding(VA: UInt64): TModuleTable;
    function  Find(VA: UInt64; out Module: TModuleTable; out Index: Integer): Boolean;
    function  KeptHas(const Key: string; Rva: Cardinal): Boolean;
    procedure KeepHitsOf(Module: TModuleTable);
    procedure DropModule(Module: TModuleTable);
    function  GiveByteBack(Module: TModuleTable; Index: Integer): Boolean;
    class function ForeignAt(const Foreign: TArray<TCodePatchForeignByte>; VA: UInt64;
      out ProgramByte: Byte): Boolean; static;
    class function SortedForeign(const Foreign: TArray<TCodePatchForeignByte>): TArray<TCodePatchForeignByte>; static;
    function  DisarmModule(Module: TModuleTable; const Foreign: TArray<TCodePatchForeignByte>;
      var Outcome: TCodePatchDisarmOutcome): Boolean;
  public
    /// <summary>Creates an empty map.</summary>
    /// <param name="Memory">How the target's memory is read, written and
    /// queried.</param>
    /// <exception cref="EArgumentNilException">A callback is nil.</exception>
    constructor Create(const Memory: TCodePatchMemory);
    destructor Destroy; override;
    /// <summary>Writes a one-shot probe on each address asked for.</summary>
    /// <remarks>The addresses are sorted and written in runs: consecutive
    /// addresses less than a page apart, inside one protection region, at most
    /// 64 KB. A run costs one read and one write. An address whose program
    /// byte is $CC is refused; one already recorded as hit under the key in an
    /// earlier mapping is not armed again.</remarks>
    /// <param name="Key">Name the results are kept under.</param>
    /// <param name="Base">Load address of the module.</param>
    /// <param name="Size">Size of its image.</param>
    /// <param name="Rvas">Module-relative addresses, in any order.</param>
    /// <param name="Foreign">The addresses whose $CC a breakpoint holds.</param>
    /// <param name="Outcome">What was done.</param>
    procedure Arm(const Key: string; Base, Size: UInt64; const Rvas: TArray<Cardinal>;
      const Foreign: TArray<TCodePatchForeignByte>; out Outcome: TCodePatchArmOutcome);
    /// <summary>Whether a request to arm under a key would collide with what
    /// the map already holds at that address.</summary>
    /// <param name="Key">Result key of the request.</param>
    /// <param name="Base">Load address of the module.</param>
    /// <param name="Size">Size of its image.</param>
    /// <param name="HeldKey">The key the map holds the module under.</param>
    /// <returns>True when patches of a module at <c>Base</c> are armed or
    /// suspended under another key or another size. Those bytes are in the
    /// target; dropping the table would leave them there untracked.</returns>
    function ConflictsWith(const Key: string; Base, Size: UInt64; out HeldKey: string): Boolean;
    /// <summary>The target's bytes at an address range were written by someone
    /// else than the map (a memory write requested by the user): every armed
    /// patch in the range is no longer the map's. Nothing is written.</summary>
    /// <param name="VA">First address written.</param>
    /// <param name="Size">Bytes written.</param>
    /// <returns>Number of patches given up.</returns>
    function Overwritten(VA: UInt64; Size: NativeUInt): Integer;
    /// <summary>Whether the map has anything to say about any address: False
    /// until the first patch is armed. The one test a breakpoint event costs
    /// while no collection ever ran.</summary>
    function Active: Boolean; inline;
    /// <summary>Number of patches in the target now.</summary>
    function ArmedCount: Integer; inline;
    /// <summary>What the map knows about the address of a breakpoint trap.</summary>
    /// <param name="VA">The address of the breakpoint instruction.</param>
    /// <returns>See <c>TCodePatchTrap</c>.</returns>
    function TrapAt(VA: UInt64): TCodePatchTrap;
    /// <summary>Whether an armed patch holds a $CC on an address.</summary>
    /// <param name="VA">The address.</param>
    /// <param name="ProgramByte">The program's byte there.</param>
    /// <returns>True when the byte in the target is the map's $CC.</returns>
    function HoldsInt3At(VA: UInt64; out ProgramByte: Byte): Boolean;
    /// <summary>An armed one-shot was hit by the program: records the hit and
    /// gives the entry up.</summary>
    /// <param name="VA">The address.</param>
    /// <param name="RestoreByte">True to write the program's byte back (after
    /// comparing: a byte that is no longer $CC is left alone). False when a
    /// breakpoint holds the byte and deals with it itself.</param>
    procedure Fire(VA: UInt64; RestoreByte: Boolean);
    /// <summary>An armed one-shot was hit by the debugger's own synthetic
    /// call: the entry is suspended, nothing is recorded.</summary>
    /// <param name="VA">The address.</param>
    /// <param name="RestoreByte">As for <c>Fire</c>.</param>
    procedure SuspendForCall(VA: UInt64; RestoreByte: Boolean);
    /// <summary>A suspended one-shot was reached by a thread of the program
    /// while the call ran: that is a hit, and the entry will not be armed
    /// again.</summary>
    /// <param name="VA">The address.</param>
    procedure RecordSuspendedHit(VA: UInt64);
    /// <summary>The synthetic call ended: every suspended patch goes back.</summary>
    /// <param name="Foreign">The addresses whose $CC a breakpoint holds.</param>
    /// <returns>Number of patches armed again.</returns>
    function RearmSuspended(const Foreign: TArray<TCodePatchForeignByte>): Integer;
    /// <summary>Counts a trap that arrived after its byte was restored.</summary>
    procedure CountLateTrap;
    /// <summary>Takes every armed patch away, nothing recorded. Each restore
    /// compares first; the entries stay as tombstones.</summary>
    /// <param name="Base">Load address of one module, or 0 for all.</param>
    /// <param name="Foreign">The addresses whose $CC a breakpoint holds: those
    /// bytes are left to the breakpoint.</param>
    /// <returns>What was restored.</returns>
    function Disarm(Base: UInt64; const Foreign: TArray<TCodePatchForeignByte>): TCodePatchDisarmOutcome;
    /// <summary>Replaces, in a buffer read from the target, every patched byte
    /// with the program's.</summary>
    /// <remarks>The buffer must hold the bytes as read, before any other
    /// overlay. An armed patch whose byte there is no longer $CC was
    /// overwritten by the program: its byte is left as it is (it is the
    /// program's) and the patch is given up.</remarks>
    /// <param name="VA">Address the buffer was read from.</param>
    /// <param name="Buf">The bytes.</param>
    /// <param name="Size">How many.</param>
    procedure Overlay(VA: UInt64; Buf: Pointer; Size: NativeUInt);
    /// <summary>Whether the map has a table for the module mapped at an
    /// address: armed there in this mapping, whatever has become of the
    /// patches since.</summary>
    /// <param name="Base">The load address.</param>
    /// <returns>False before the first arming of the mapping, and after its
    /// unload.</returns>
    function HoldsModule(Base: UInt64): Boolean;
    /// <summary>The module mapped at an address is gone: its entries are
    /// dropped WITHOUT writing (the memory is no longer there), its hits are
    /// kept under its key.</summary>
    /// <param name="Base">The load address.</param>
    procedure ModuleUnloaded(Base: UInt64);
    /// <summary>The process is gone: every mapping is dropped, the hits stay.</summary>
    procedure ProcessGone;
    /// <summary>The addresses recorded as hit under a key.</summary>
    /// <param name="Key">The result key.</param>
    /// <returns>Module-relative addresses, ascending, without repeats.</returns>
    function Hits(const Key: string): TArray<Cardinal>;
    /// <summary>The keys that have a module or kept hits.</summary>
    function ResultKeys: TArray<string>;
    /// <summary>The armed addresses of the module mapped at an address.</summary>
    /// <param name="Base">The load address.</param>
    /// <returns>Module-relative addresses, ascending.</returns>
    function ArmedRvas(Base: UInt64): TArray<Cardinal>;
    /// <summary>Forgets every hit: kept ones, and the fired state of the live
    /// entries (which become withdrawn: their bytes are back in the program
    /// and they are still tombstones).</summary>
    procedure ClearHits;
    /// <summary>Counters.</summary>
    function Stats: TCodePatchStats;
  end;

implementation

uses
  System.Diagnostics;

{ TCodePatchMap.TModuleTable }

function TCodePatchMap.TModuleTable.FirstAtOrAfter(Rva: Cardinal): Integer;
begin
  var Lo := 0;
  var Hi := Length(Entries);
  while Lo < Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if Entries[Mid].Rva < Rva then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  Result := Lo;
end;

function TCodePatchMap.TModuleTable.IndexOf(Rva: Cardinal): Integer;
begin
  Result := FirstAtOrAfter(Rva);
  if (Result >= Length(Entries)) or (Entries[Result].Rva <> Rva) then
    Result := -1;
end;

{ TCodePatchMap }

constructor TCodePatchMap.Create(const Memory: TCodePatchMemory);
begin
  inherited Create;
  if not (Assigned(Memory.Read) and Assigned(Memory.Write) and Assigned(Memory.Query)) then
    raise EArgumentNilException.Create('TCodePatchMap.Create: a memory callback is missing');
  FMemory    := Memory;
  FModules   := TObjectList<TModuleTable>.Create(True);
  FKept      := TObjectDictionary<string, TList<Cardinal>>.Create([doOwnsValues]);
  FSuspended := TList<UInt64>.Create;
end;

destructor TCodePatchMap.Destroy;
begin
  FSuspended.Free;
  FKept.Free;
  FModules.Free;
  inherited;
end;

function TCodePatchMap.Active: Boolean;
begin
  Result := FEntryTotal > 0;
end;

function TCodePatchMap.ArmedCount: Integer;
begin
  Result := FArmedTotal;
end;

function TCodePatchMap.ModuleAt(Base: UInt64): TModuleTable;
begin
  for var Module in FModules do
    if Module.Base = Base then
      Exit(Module);
  Result := nil;
end;

function TCodePatchMap.ModuleHolding(VA: UInt64): TModuleTable;
begin
  for var Module in FModules do
    if (VA >= Module.Base) and (VA - Module.Base < Module.Size) then
      Exit(Module);
  Result := nil;
end;

function TCodePatchMap.Find(VA: UInt64; out Module: TModuleTable; out Index: Integer): Boolean;
begin
  Index  := -1;
  Module := ModuleHolding(VA);
  if Module = nil then
    Exit(False);
  Index  := Module.IndexOf(Cardinal(VA - Module.Base));
  Result := Index >= 0;
end;

function TCodePatchMap.KeptHas(const Key: string; Rva: Cardinal): Boolean;
begin
  var List: TList<Cardinal>;
  if not FKept.TryGetValue(Key, List) then
    Exit(False);
  var Index: NativeInt;
  Result := List.BinarySearch(Rva, Index);
end;

class function TCodePatchMap.SortedForeign(
  const Foreign: TArray<TCodePatchForeignByte>): TArray<TCodePatchForeignByte>;
begin
  Result := Copy(Foreign);
  TArray.Sort<TCodePatchForeignByte>(Result, TComparer<TCodePatchForeignByte>.Construct(
    function(const A, B: TCodePatchForeignByte): Integer
    begin
      if A.VA < B.VA then
        Exit(-1);
      if A.VA > B.VA then
        Exit(1);
      Result := 0;
    end));
end;

class function TCodePatchMap.ForeignAt(const Foreign: TArray<TCodePatchForeignByte>;
  VA: UInt64; out ProgramByte: Byte): Boolean;
// Foreign is sorted by address (SortedForeign).
begin
  ProgramByte := 0;
  var Lo := 0;
  var Hi := Length(Foreign);
  while Lo < Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if Foreign[Mid].VA < VA then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  if (Lo >= Length(Foreign)) or (Foreign[Lo].VA <> VA) then
    Exit(False);
  ProgramByte := Foreign[Lo].ProgramByte;
  Result := True;
end;

procedure TCodePatchMap.Arm(const Key: string; Base, Size: UInt64;
  const Rvas: TArray<Cardinal>; const Foreign: TArray<TCodePatchForeignByte>;
  out Outcome: TCodePatchArmOutcome);
type
  TCandidate = record
    Rva:      Cardinal;
    Existing: Integer;   // index of a withdrawn entry to arm again, or -1
  end;
var
  Fresh: TArray<TCodePatchEntry>;
  FreshCount: Integer;
  Module: TModuleTable;
  Held: TArray<TCodePatchForeignByte>;

  procedure Take(const Candidate: TCandidate; ProgramByte: Byte);
  begin
    if Candidate.Existing >= 0 then begin
      Module.Entries[Candidate.Existing].State := cpsArmed;
      Module.Entries[Candidate.Existing].Saved := ProgramByte;
    end else begin
      var Entry := Default(TCodePatchEntry);
      Entry.Rva   := Candidate.Rva;
      Entry.State := cpsArmed;
      Entry.Kind  := cpkOneShot;
      Entry.Len   := 1;
      Entry.Saved := ProgramByte;
      Fresh[FreshCount] := Entry;
      Inc(FreshCount);
    end;
    Inc(Module.Armed);
    Inc(FArmedTotal);
  end;

  // One run: [First, Last] of Candidates, all inside one accessible region and
  // close together. One read, at most one write.
  procedure ArmRun(const Candidates: TArray<TCandidate>; First, Last: Integer;
    var Outcome: TCodePatchArmOutcome);
  begin
    Inc(Outcome.Runs);
    var RunVA  := Base + Candidates[First].Rva;
    var RunLen := NativeUInt(Candidates[Last].Rva - Candidates[First].Rva) + 1;
    var Buf: TArray<Byte>;
    SetLength(Buf, RunLen);
    if not FMemory.Read(RunVA, @Buf[0], RunLen) then begin
      Inc(Outcome.Unreadable, Last - First + 1);
      Exit;
    end;
    // What each candidate will be, decided before anything is written.
    var Wanted: TArray<Byte>;        // 0 refused, 1 to write, 2 shared with a breakpoint
    var ProgramBytes: TArray<Byte>;
    SetLength(Wanted, Last - First + 1);
    SetLength(ProgramBytes, Last - First + 1);
    var DirtyLo: NativeInt := -1;
    var DirtyHi: NativeInt := -1;
    for var K := First to Last do begin
      var Ofs := NativeInt(Candidates[K].Rva - Candidates[First].Rva);
      var ProgramByte := Buf[Ofs];
      var HeldByte: Byte;
      var Shared := ForeignAt(Held, Base + Candidates[K].Rva, HeldByte);
      if Shared then
        ProgramByte := HeldByte;
      ProgramBytes[K - First] := ProgramByte;
      // The program's own breakpoint instruction is not a place for ours: a
      // restore there would put a $CC back, and the trap after the rewind
      // would be the program's.
      if ProgramByte = CODE_PATCH_INT3 then begin
        Inc(Outcome.OwnBreakpointInstruction);
        Outcome.OwnBreakpointRvas := Outcome.OwnBreakpointRvas + [Candidates[K].Rva];
        Continue;
      end;
      if Shared then begin
        Wanted[K - First] := 2;
        Continue;
      end;
      Wanted[K - First] := 1;
      Buf[Ofs] := CODE_PATCH_INT3;
      if DirtyLo < 0 then
        DirtyLo := Ofs;
      DirtyHi := Ofs;
    end;
    var Written := True;
    if DirtyLo >= 0 then begin
      var Count := NativeUInt(DirtyHi - DirtyLo + 1);
      Written := FMemory.Write(RunVA + UInt64(DirtyLo), @Buf[DirtyLo], Count);
      Inc(Outcome.WriteCalls);
      if Written then
        Inc(Outcome.BytesWritten, Count);
    end;
    // A write that failed may still have written a prefix (WriteProcessMemory
    // stops at the first page it cannot write). What the target holds now
    // decides: a $CC where the program has another byte is ours and is
    // tracked; anything else was not written. Unreadable, nothing is claimed.
    var Landed: TArray<Byte> := nil;
    if not Written then begin
      SetLength(Landed, RunLen);
      if not FMemory.Read(RunVA, @Landed[0], RunLen) then
        Landed := nil;
    end;
    for var K := First to Last do
      case Wanted[K - First] of
        1: begin
          var Ofs := NativeInt(Candidates[K].Rva - Candidates[First].Rva);
          var Arrived := Written or ((Length(Landed) > 0) and (Landed[Ofs] = CODE_PATCH_INT3));
          if Arrived then begin
            Take(Candidates[K], ProgramBytes[K - First]);
            Inc(Outcome.Armed);
          end else
            Inc(Outcome.WriteFailed);
        end;
        2: begin
          Take(Candidates[K], ProgramBytes[K - First]);
          Inc(Outcome.Armed);
          Inc(Outcome.SharedWithBreakpoint);
        end;
      end;
  end;

begin
  Outcome := Default(TCodePatchArmOutcome);
  var Clock := TStopwatch.StartNew;
  Held := SortedForeign(Foreign);

  // One module named two ways while bytes of the first name are in the target:
  // nothing is armed, and the table that knows those bytes stays.
  var HeldKey: string;
  if ConflictsWith(Key, Base, Size, HeldKey) then begin
    Outcome.Conflict  := True;
    Outcome.Requested := Length(Rvas);
    Exit;
  end;
  Module := ModuleAt(Base);
  // Another module at the same address with nothing of it in the target: its
  // unload was not seen, and its entries describe bytes that are gone. What it
  // recorded is kept under its own key.
  if (Module <> nil) and ((Module.Key <> Key) or (Module.Size <> Size)) then begin
    DropModule(Module);
    Module := nil;
  end;
  if Module = nil then begin
    Module := TModuleTable.Create;
    Module.Key    := Key;
    Module.Base   := Base;
    Module.Size   := Size;
    Module.MaxLen := 1;
    FModules.Add(Module);
  end;

  var Sorted := Copy(Rvas);
  TArray.Sort<Cardinal>(Sorted);
  var Candidates: TArray<TCandidate>;
  SetLength(Candidates, Length(Sorted));
  var Count := 0;
  for var I := 0 to High(Sorted) do begin
    if (I > 0) and (Sorted[I] = Sorted[I - 1]) then
      Continue;
    Inc(Outcome.Requested);
    if UInt64(Sorted[I]) >= Size then begin
      Inc(Outcome.OutsideModule);
      Continue;
    end;
    var Existing := Module.IndexOf(Sorted[I]);
    if (Existing >= 0) and (Module.Entries[Existing].State <> cpsWithdrawn) then begin
      Inc(Outcome.AlreadyPresent);
      Continue;
    end;
    if (Existing < 0) and KeptHas(Key, Sorted[I]) then begin
      Inc(Outcome.AlreadyHit);
      Continue;
    end;
    Candidates[Count].Rva      := Sorted[I];
    Candidates[Count].Existing := Existing;
    Inc(Count);
  end;
  SetLength(Candidates, Count);
  SetLength(Fresh, Count);
  FreshCount := 0;

  var I := 0;
  while I < Count do begin
    var Region: TCodePatchRegion;
    var FirstVA := Base + Candidates[I].Rva;
    if (not FMemory.Query(FirstVA, Region)) or (not Region.Accessible) then begin
      Inc(Outcome.Unreadable);
      Inc(I);
      Continue;
    end;
    var RegionEnd := Region.Base + Region.Size;
    var J := I;
    while (J + 1 < Count) and
          (Candidates[J + 1].Rva - Candidates[J].Rva < CODE_PATCH_MAX_GAP) and
          (Base + Candidates[J + 1].Rva < RegionEnd) and
          (Candidates[J + 1].Rva - Candidates[I].Rva < CODE_PATCH_MAX_RUN) do
      Inc(J);
    ArmRun(Candidates, I, J, Outcome);
    I := J + 1;
  end;

  // The new entries and the old ones, both sorted, into one table.
  if FreshCount > 0 then begin
    var Old := Module.Entries;
    var Merged: TArray<TCodePatchEntry>;
    SetLength(Merged, Length(Old) + FreshCount);
    var A := 0;
    var B := 0;
    var N := 0;
    while (A < Length(Old)) or (B < FreshCount) do begin
      if (B >= FreshCount) or ((A < Length(Old)) and (Old[A].Rva < Fresh[B].Rva)) then begin
        Merged[N] := Old[A];
        Inc(A);
      end else begin
        Merged[N] := Fresh[B];
        Inc(B);
      end;
      Inc(N);
    end;
    Module.Entries := Merged;
    Inc(FEntryTotal, FreshCount);
  end;
  // The table stays even when nothing could be armed (every record already
  // ran in an earlier mapping, say): it is what says that this mapping has
  // been dealt with (HoldsModule), and an empty table costs nothing.
  Outcome.Milliseconds := Clock.Elapsed.TotalMilliseconds;
end;

function TCodePatchMap.ConflictsWith(const Key: string; Base, Size: UInt64;
  out HeldKey: string): Boolean;
begin
  HeldKey := '';
  var Module := ModuleAt(Base);
  if Module = nil then
    Exit(False);
  HeldKey := Module.Key;
  if (Module.Key = Key) and (Module.Size = Size) then
    Exit(False);
  if Module.Armed > 0 then
    Exit(True);
  for var Entry in Module.Entries do
    if Entry.State = cpsSuspended then
      Exit(True);
  Result := False;
end;

function TCodePatchMap.Overwritten(VA: UInt64; Size: NativeUInt): Integer;
begin
  Result := 0;
  if (FArmedTotal = 0) or (Size = 0) then
    Exit;
  var WindowEnd := VA + Size;
  for var Module in FModules do begin
    if (Module.Armed = 0) or (WindowEnd <= Module.Base) or (VA >= Module.Base + Module.Size) then
      Continue;
    // An entry that starts up to MaxLen - 1 bytes below the window reaches
    // into it.
    var FromRva: Cardinal := 0;
    if VA > Module.Base then begin
      var Lead := VA - Module.Base;
      if Lead >= UInt64(Module.MaxLen - 1) then
        FromRva := Cardinal(Lead - UInt64(Module.MaxLen - 1));
    end;
    var Index := Module.FirstAtOrAfter(FromRva);
    while (Index < Length(Module.Entries)) and (Module.Base + Module.Entries[Index].Rva < WindowEnd) do begin
      if Module.Entries[Index].State = cpsArmed then begin
        Module.Entries[Index].State := cpsLost;
        Dec(Module.Armed);
        Dec(FArmedTotal);
        Inc(FLost);
        Inc(Result);
      end;
      Inc(Index);
    end;
  end;
end;

function TCodePatchMap.TrapAt(VA: UInt64): TCodePatchTrap;
begin
  var Module: TModuleTable;
  var Index: Integer;
  if not Find(VA, Module, Index) then
    Exit(cptNone);
  case Module.Entries[Index].State of
    cpsArmed:     Result := cptArmed;
    cpsSuspended: Result := cptSuspended;
  else
    Result := cptSpent;
  end;
end;

function TCodePatchMap.HoldsInt3At(VA: UInt64; out ProgramByte: Byte): Boolean;
begin
  ProgramByte := 0;
  if FArmedTotal = 0 then
    Exit(False);
  var Module: TModuleTable;
  var Index: Integer;
  if not Find(VA, Module, Index) then
    Exit(False);
  if Module.Entries[Index].State <> cpsArmed then
    Exit(False);
  ProgramByte := Module.Entries[Index].Saved;
  Result := True;
end;

function TCodePatchMap.GiveByteBack(Module: TModuleTable; Index: Integer): Boolean;
// Compare before restore: the byte is written back only while it is still the
// $CC the map put there. A program that hooked the routine, or wrote its own
// code, has made the byte its own, and it stays.
begin
  var VA := Module.Base + Module.Entries[Index].Rva;
  var Now: Byte := 0;
  if (not FMemory.Read(VA, @Now, 1)) or (Now <> CODE_PATCH_INT3) then begin
    Inc(FLost);
    Exit(False);
  end;
  Result := FMemory.Write(VA, @Module.Entries[Index].Saved, 1);
  if not Result then
    Inc(FLost);
end;

procedure TCodePatchMap.Fire(VA: UInt64; RestoreByte: Boolean);
begin
  var Module: TModuleTable;
  var Index: Integer;
  if (not Find(VA, Module, Index)) or (Module.Entries[Index].State <> cpsArmed) then
    Exit;
  Module.Entries[Index].State := cpsFired;
  Dec(Module.Armed);
  Dec(FArmedTotal);
  Inc(FHitsRecorded);
  if RestoreByte then
    GiveByteBack(Module, Index);
end;

procedure TCodePatchMap.SuspendForCall(VA: UInt64; RestoreByte: Boolean);
begin
  var Module: TModuleTable;
  var Index: Integer;
  if (not Find(VA, Module, Index)) or (Module.Entries[Index].State <> cpsArmed) then
    Exit;
  Dec(Module.Armed);
  Dec(FArmedTotal);
  Inc(FHitsBySynthCall);
  Module.Entries[Index].State := cpsSuspended;
  // A byte that could not be given back is not ours to put back later either.
  if RestoreByte and not GiveByteBack(Module, Index) then begin
    Module.Entries[Index].State := cpsLost;
    Exit;
  end;
  FSuspended.Add(VA);
end;

procedure TCodePatchMap.RecordSuspendedHit(VA: UInt64);
begin
  var Module: TModuleTable;
  var Index: Integer;
  if (not Find(VA, Module, Index)) or (Module.Entries[Index].State <> cpsSuspended) then
    Exit;
  Module.Entries[Index].State := cpsFired;
  Inc(FHitsRecorded);
end;

function TCodePatchMap.RearmSuspended(const Foreign: TArray<TCodePatchForeignByte>): Integer;
begin
  Result := 0;
  if FSuspended.Count = 0 then
    Exit;
  var Held := SortedForeign(Foreign);
  for var VA in FSuspended do begin
    var Module: TModuleTable;
    var Index: Integer;
    // Gone with its module, or hit by another thread meanwhile.
    if (not Find(VA, Module, Index)) or (Module.Entries[Index].State <> cpsSuspended) then
      Continue;
    var ProgramByte: Byte := 0;
    var HeldByte: Byte;
    if ForeignAt(Held, VA, HeldByte) then
      ProgramByte := HeldByte
    else begin
      var Int3: Byte := CODE_PATCH_INT3;
      // A $CC nobody owns is not the program's byte: nothing to save.
      if (not FMemory.Read(VA, @ProgramByte, 1)) or (ProgramByte = CODE_PATCH_INT3) or
         (not FMemory.Write(VA, @Int3, 1)) then begin
        Module.Entries[Index].State := cpsLost;
        Inc(FLost);
        Continue;
      end;
    end;
    Module.Entries[Index].Saved := ProgramByte;
    Module.Entries[Index].State := cpsArmed;
    Inc(Module.Armed);
    Inc(FArmedTotal);
    Inc(Result);
  end;
  FSuspended.Clear;
end;

procedure TCodePatchMap.CountLateTrap;
begin
  Inc(FLateTraps);
end;

function TCodePatchMap.DisarmModule(Module: TModuleTable;
  const Foreign: TArray<TCodePatchForeignByte>; var Outcome: TCodePatchDisarmOutcome): Boolean;
// Runs of armed entries, as Arm writes them: one read and at most one write
// each. Every byte is compared before it is given back.
begin
  Result := True;
  var Entries := Module.Entries;
  var I := 0;
  while I < Length(Entries) do begin
    if Entries[I].State = cpsSuspended then
      Module.Entries[I].State := cpsWithdrawn;
    if Entries[I].State <> cpsArmed then begin
      Inc(I);
      Continue;
    end;
    var Region: TCodePatchRegion;
    var HaveRegion := FMemory.Query(Module.Base + Entries[I].Rva, Region) and Region.Accessible;
    var J := I;
    if HaveRegion then
      while (J + 1 < Length(Entries)) and
            (Entries[J + 1].Rva - Entries[J].Rva < CODE_PATCH_MAX_GAP) and
            (Module.Base + Entries[J + 1].Rva < Region.Base + Region.Size) and
            (Entries[J + 1].Rva - Entries[I].Rva < CODE_PATCH_MAX_RUN) do
        Inc(J);
    var RunVA  := Module.Base + Entries[I].Rva;
    var RunLen := NativeUInt(Entries[J].Rva - Entries[I].Rva) + 1;
    var Buf: TArray<Byte>;
    SetLength(Buf, RunLen);
    var Readable := HaveRegion and FMemory.Read(RunVA, @Buf[0], RunLen);
    var DirtyLo: NativeInt := -1;
    var DirtyHi: NativeInt := -1;
    var ToRestore := 0;
    for var K := I to J do begin
      if Entries[K].State <> cpsArmed then
        Continue;
      Dec(Module.Armed);
      Dec(FArmedTotal);
      var Ofs := NativeInt(Entries[K].Rva - Entries[I].Rva);
      var ProgramByte: Byte;
      if ForeignAt(Foreign, Module.Base + Entries[K].Rva, ProgramByte) then begin
        Module.Entries[K].State := cpsWithdrawn;
        Inc(Outcome.LeftToBreakpoint);
        Continue;
      end;
      if (not Readable) or (Buf[Ofs] <> CODE_PATCH_INT3) then begin
        Module.Entries[K].State := cpsLost;
        Inc(Outcome.Lost);
        Inc(FLost);
        Continue;
      end;
      Module.Entries[K].State := cpsWithdrawn;
      Buf[Ofs] := Entries[K].Saved;
      Inc(ToRestore);
      if DirtyLo < 0 then
        DirtyLo := Ofs;
      DirtyHi := Ofs;
    end;
    if DirtyLo >= 0 then begin
      Inc(Outcome.WriteCalls);
      if FMemory.Write(RunVA + UInt64(DirtyLo), @Buf[DirtyLo], NativeUInt(DirtyHi - DirtyLo + 1)) then
        Inc(Outcome.Restored, ToRestore)
      else begin
        Inc(Outcome.Lost, ToRestore);
        Inc(FLost, ToRestore);
        Result := False;
      end;
    end;
    I := J + 1;
  end;
end;

function TCodePatchMap.Disarm(Base: UInt64;
  const Foreign: TArray<TCodePatchForeignByte>): TCodePatchDisarmOutcome;
begin
  Result := Default(TCodePatchDisarmOutcome);
  var Held := SortedForeign(Foreign);
  for var Module in FModules do
    if (Base = 0) or (Module.Base = Base) then
      DisarmModule(Module, Held, Result);
  if Base = 0 then
    FSuspended.Clear;
end;

procedure TCodePatchMap.Overlay(VA: UInt64; Buf: Pointer; Size: NativeUInt);
begin
  if (FArmedTotal = 0) or (Size = 0) then
    Exit;
  var WindowEnd := VA + Size;
  for var Module in FModules do begin
    if (Module.Armed = 0) or (WindowEnd <= Module.Base) or (VA >= Module.Base + Module.Size) then
      Continue;
    // The first entry that can reach into the window: one that starts up to
    // MaxLen - 1 bytes below it.
    var FromRva: Cardinal := 0;
    if VA > Module.Base then begin
      var Lead := VA - Module.Base;
      if Lead >= UInt64(Module.MaxLen - 1) then
        FromRva := Cardinal(Lead - UInt64(Module.MaxLen - 1));
    end;
    var Index := Module.FirstAtOrAfter(FromRva);
    while Index < Length(Module.Entries) do begin
      var Entry := Module.Entries[Index];
      var EntryVA := Module.Base + Entry.Rva;
      if EntryVA >= WindowEnd then
        Break;
      Inc(Index);
      if Entry.State <> cpsArmed then
        Continue;
      // One saved byte per entry today; a longer span copies as many bytes of
      // its saved image as fall inside the window.
      if EntryVA < VA then
        Continue;
      var At := PByte(NativeUInt(Buf) + NativeUInt(EntryVA - VA));
      if At^ = CODE_PATCH_INT3 then begin
        At^ := Entry.Saved;
        Continue;
      end;
      // Not our $CC any more: the program wrote its own byte there (a hooking
      // library patching a routine's entry, an unpacker). That byte is the
      // program's, every reader is shown it, and the entry is given up.
      Module.Entries[Index - 1].State := cpsLost;
      Dec(Module.Armed);
      Dec(FArmedTotal);
      Inc(FLost);
    end;
  end;
end;

function TCodePatchMap.HoldsModule(Base: UInt64): Boolean;
begin
  Result := ModuleAt(Base) <> nil;
end;

procedure TCodePatchMap.KeepHitsOf(Module: TModuleTable);
begin
  var Fired: TArray<Cardinal>;
  SetLength(Fired, Length(Module.Entries));
  var FiredCount := 0;
  for var Entry in Module.Entries do begin
    if Entry.State <> cpsFired then
      Continue;
    Fired[FiredCount] := Entry.Rva;
    Inc(FiredCount);
  end;
  SetLength(Fired, FiredCount);
  if FiredCount = 0 then
    Exit;
  var List: TList<Cardinal>;
  if not FKept.TryGetValue(Module.Key, List) then begin
    List := TList<Cardinal>.Create;
    FKept.Add(Module.Key, List);
  end;
  // Both sorted: merge without repeats.
  var Old := List.ToArray;
  List.Clear;
  var A := 0;
  var B := 0;
  while (A < Length(Old)) or (B < Length(Fired)) do begin
    var Next: Cardinal;
    if (B >= Length(Fired)) or ((A < Length(Old)) and (Old[A] <= Fired[B])) then begin
      Next := Old[A];
      if (B < Length(Fired)) and (Fired[B] = Next) then
        Inc(B);
      Inc(A);
    end else begin
      Next := Fired[B];
      Inc(B);
    end;
    List.Add(Next);
  end;
end;

procedure TCodePatchMap.DropModule(Module: TModuleTable);
begin
  KeepHitsOf(Module);
  Dec(FArmedTotal, Module.Armed);
  Dec(FEntryTotal, Length(Module.Entries));
  FModules.Remove(Module);
end;

procedure TCodePatchMap.ModuleUnloaded(Base: UInt64);
begin
  var Module := ModuleAt(Base);
  if Module <> nil then
    DropModule(Module);
end;

procedure TCodePatchMap.ProcessGone;
begin
  while FModules.Count > 0 do
    DropModule(FModules[FModules.Count - 1]);
  FSuspended.Clear;
end;

function TCodePatchMap.Hits(const Key: string): TArray<Cardinal>;
begin
  var All := TList<Cardinal>.Create;
  try
    var List: TList<Cardinal>;
    if FKept.TryGetValue(Key, List) then
      All.AddRange(List);
    for var Module in FModules do begin
      if Module.Key <> Key then
        Continue;
      for var Entry in Module.Entries do
        if Entry.State = cpsFired then
          All.Add(Entry.Rva);
    end;
    All.Sort;
    Result := nil;
    SetLength(Result, All.Count);
    var N := 0;
    for var I := 0 to All.Count - 1 do begin
      if (I > 0) and (All[I] = All[I - 1]) then
        Continue;
      Result[N] := All[I];
      Inc(N);
    end;
    SetLength(Result, N);
  finally
    All.Free;
  end;
end;

function TCodePatchMap.ResultKeys: TArray<string>;
begin
  Result := nil;
  for var Key in FKept.Keys do
    Result := Result + [Key];
  for var Module in FModules do begin
    var Known := False;
    for var Key in Result do
      if Key = Module.Key then
        Known := True;
    if not Known then
      Result := Result + [Module.Key];
  end;
end;

function TCodePatchMap.ArmedRvas(Base: UInt64): TArray<Cardinal>;
begin
  Result := nil;
  var Module := ModuleAt(Base);
  if Module = nil then
    Exit;
  SetLength(Result, Module.Armed);
  var N := 0;
  for var Entry in Module.Entries do begin
    if Entry.State <> cpsArmed then
      Continue;
    if N >= Length(Result) then
      SetLength(Result, N + 1);
    Result[N] := Entry.Rva;
    Inc(N);
  end;
  SetLength(Result, N);
end;

procedure TCodePatchMap.ClearHits;
begin
  FKept.Clear;
  for var Module in FModules do
    for var I := 0 to High(Module.Entries) do
      if Module.Entries[I].State = cpsFired then
        Module.Entries[I].State := cpsWithdrawn;
  FHitsRecorded := 0;
  FHitsBySynthCall := 0;
end;

function TCodePatchMap.Stats: TCodePatchStats;
begin
  Result := Default(TCodePatchStats);
  Result.Modules   := FModules.Count;
  Result.Entries   := FEntryTotal;
  Result.Armed     := FArmedTotal;
  Result.Suspended := FSuspended.Count;
  Result.HitsRecorded        := FHitsRecorded;
  Result.HitsBySyntheticCall := FHitsBySynthCall;
  Result.LateTraps := FLateTraps;
  Result.Lost      := FLost;
end;

end.
