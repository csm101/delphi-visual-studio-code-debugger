unit RsmFileReader;

// Parses Delphi Win64 .rsm (remote debug symbol) files.
// Locals and globals are loaded on demand: the file is memory-mapped once
// (instant), a background thread builds a procedure-name->offset index, and
// individual procedures are parsed only when GetLocalsForFunction is called.
// This keeps startup and first-access times sub-second even for 780MB RSMs.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.SyncObjs, System.IOUtils, System.Math,
  System.Threading,
  Winapi.Windows,
  DebugInfoTypes, RsmTags, RsmDecoders;

type
  TRsmFile = class(TInterfacedObject, ILocalSymbolProvider, IGlobalSymbolProvider,
                   IEnumInfoProvider, IClassMemberProvider, IUnitScopedLocalProvider,
                   IUnitUsesProvider, IUnitScopedConstProvider)
  private
    // Memory-mapped file handles
    FFileHandle:     THandle;
    FMappingHandle:  THandle;
    FData:           PByte;   // mapped view (nil when not open)
    FDataSize:       Int64;

    FLoaded:         Boolean;
    FRsmPath:        string;

    // Procedure offset index (background-filled).
    // Key = lowercase proc name, Value = byte offset of proc header in FData.
    FProcOffsets:    TDictionary<string, Int64>;

    // Lazily-parsed results (on-demand, main thread).
    FProcLocals:     TDictionary<string, TArray<TLocalSymbol>>;
    // Best-effort locals parsed while the background index was still building.
    // Kept apart from FProcLocals so an answer derived from a half-built index is
    // never pinned for the session; cleared once the index completes.
    FProvisionalLocals: TDictionary<string, TArray<TLocalSymbol>>;
    FGlobals:        TList<TGlobalSymbol>;

    // User type table -- parsed eagerly (small, needed for type display).
    FUserTypes:      TArray<string>;

    // Module-local type mapping: odd typeId -> type name (e.g. 0x1C75 -> 'TWorkMode').
    // Populated from $2A type declaration records in the RSM.
    FTypeIdToName:   TDictionary<Integer, string>;

    // Variant D records ($A8 filler -- big VCL classes) expose a SECOND
    // 16-bit id at trailer offsets [7][8] that doubles as both the
    // implicit Self.TypeId and the per-class-member ($2C/$2E/$31) hash.
    // The same id is reused across units, so a single (Integer -> string)
    // map can't distinguish e.g. TfrmMainMdi from another class that
    // happens to share id $022D. Keep all candidate names per hash and let
    // ParseClassMemberSection register members under each.
    FClassHashCandidates: TDictionary<Word, TArray<string>>;

    // Enum/set metadata parsed from embedded Delphi TypeInfo records in the RSM.
    FEnumInfoByName: TDictionary<string, TRsmEnumInfo>;

    // TKind byte (Delphi's TTypeKind) for every type that appears in a
    // TTypeInfo record under the `$08 00 00 00 00 00 00 00` prefix. Used
    // to drive class/record decoration decisions from the type's actual
    // shape rather than a hardcoded primitive name list -- so user
    // aliases like `type T = type Integer;` are still treated as
    // integers in the variables view.
    FTypeKindByName: TDictionary<string, Byte>;

    // Per-unit imports tables. Each Delphi unit compiled into the EXE has
    // its own $66-style imports area in the RSM, anchored by `64 06 'System'
    // 00 00 00 66 ...` (note: tag $64, NOT the $65 used for the EXE-global
    // imports). Each area is preceded by a `$70 [LEN] [Path]` record that
    // carries the source file name (e.g. `System.SysUtils.pas`) -- the unit
    // identity. We map the (unit name -> ordered $66 type list) so that
    // class-member TypeIds emitted while compiling that unit can be
    // resolved against the right table. Without this, RTL classes like
    // `Exception` show FMessage as `Boolean` because the GLOBAL FUserTypes
    // (built from `65 06 System` only) puts Boolean where SysUtils put
    // UnicodeString.
    FUnitImports:    TDictionary<string, TArray<string>>;

    // Per-unit uses clause (IUnitUsesProvider): lowercased owner-unit basename ->
    // the lowercased basenames it uses. Parsed lazily on first GetUnitUses from
    // the RSM `63 35` clusters (a contiguous-ish run of `63 35 LEN name` records;
    // the first name is the owning unit, the rest its dependencies).
    FUnitUses:       TDictionary<string, TArray<string>>;
    FUnitUsesParsed: Boolean;

    // Named constants (IUnitScopedConstProvider), from the RSM `$25` records.
    // Key 'lowerunit|lowername' -> value; and a flat 'lowername' -> value for
    // the any-unit fallback. TypeHint kept in a parallel map. Parsed lazily.
    FUnitConsts:      TDictionary<string, Int64>;
    FUnitConstTypes:  TDictionary<string, string>;
    FConstByName:     TDictionary<string, Int64>;
    FConstTypeByName: TDictionary<string, string>;
    FUnitConstsParsed: Boolean;

    // Owning unit for every class hash. Populated alongside
    // FClassHashCandidates. Determines which FUnitImports list each $2C
    // field record's TypeId should be resolved against.
    FClassUnit:      TDictionary<string, string>; // ClassName -> UnitName

    // Sorted list of (per-unit anchor offset, unit name). Used to map a
    // record's file offset to its owning unit (last anchor with offset <=
    // record offset).
    FUnitAnchors:    TList<TPair<Int64, string>>;

    // Lazily-built set of proc names (lowercase) that are declared in MORE THAN
    // ONE unit of this binary. FProcOffsets is name-keyed last-wins, so for such
    // names a plain by-name lookup is ambiguous; NameCollidesAcrossUnits gates
    // the unit-scoped fallback. Built once on first query by EnsureCollisionSet
    // (a single FData scan, so it works on the sidecar fast path too).
    FCollidingProcNames: TDictionary<string, Boolean>;
    FCollisionReady:     Boolean;

    // Class members ($2C field, $2E method, $31 property) keyed by lowercase
    // class name. Built ON DEMAND: GetClassMembers decodes the record bytes
    // from FClassMemberOffsets the first time a class is asked for and
    // caches the result here. Subsequent lookups are O(1).
    FClassMembers:   TDictionary<string, TArray<TClassMember>>;

    // File offsets of every $2C / $2E / $31 record grouped by their 16-bit
    // class hash. Populated by IndexClassMemberRecords during the cold
    // scan; this is the cheap pass (no per-record decode). DecodeClassMembers
    // walks these offsets only when a class is actually inspected.
    FClassMemberOffsets:    TDictionary<Word, TArray<Int64>>;

    // File offset of every $2A class-declaration record keyed by lowercase
    // class name. Lets DecodeClassMembers look up the class's owning unit
    // (via FUnitAnchors) at decode time instead of in a separate eager pass.
    FClassDeclarationOffsets: TDictionary<string, Int64>;

    // Reverse mapping (lowercase class name -> all class-hashes that bind
    // to it). Variant-D classes share a per-unit hash; standard variants
    // use the low 16 bits of their TypeId. DecodeClassMembers iterates
    // every hash here to collect the class's member records.
    FClassNameToHash:        TDictionary<string, TArray<Word>>;

    // Synchronization between background index builder and foreground callers.
    FIndexReady:     Boolean;
    FLock:           TCriticalSection;

    procedure OpenMappedFile(const Path: string);
    procedure CloseMappedFile;
    function  ScanForProcOffsets: Boolean; // True = sidecar loaded (skip save)
    procedure CollectMainBlockLocals;
    procedure ParseUserTypeTable;
    procedure ParsePerUnitImports;
    procedure ParseTypeDeclarationSection;
    procedure ParseTypeInfoSection;
    procedure IndexClassMemberRecords;
    procedure DecodeClassMembers(const ClassName: string;
                out Members: TArray<TClassMember>);
    // One-time scan that fills FCollidingProcNames. Idempotent, lock-guarded.
    procedure EnsureCollisionSet;

    function  LoadProcIndexFromSidecar(const SidecarPath: string): Boolean;
    // The whole cold-path index build, as run on the background index thread:
    // the two phase waves, then serialise -> publish readiness -> write.
    procedure BuildIndexAndPublish(const SidecarPath: string);
    // Serialises the whole index into memory under FLock. Returns nil if it
    // failed; the caller owns the stream.
    function  SerializeIndexToStream: TMemoryStream;
    // Publishes a serialised index at SidecarPath (temp file + atomic rename).
    // Never raises and never touches a file it did not write.
    procedure PublishSidecar(Stream: TMemoryStream; const SidecarPath: string);
    procedure MarkIndexReady;

    function  TryParseProcedureAt(StartOff: Int64; out NextOff: Int64;
                out ProcName: string; out Locals: TArray<TLocalSymbol>): Boolean;
    function  TryParseGlobalAt(StartOff: Int64; out NextOff: Int64;
                out Global: TGlobalSymbol): Boolean;
    function  TryReadIdent(Off: Int64; Len: Integer; out S: string): Boolean;
    function  LookupTypeName(TypeId: Integer): string;
    // Resolves a symbol's RSM TypeId to a type name using the PER-UNIT import
    // list first (an RSM TypeId is per-unit and collides across units on big
    // multi-unit binaries), then the global map. Shared by members, locals and
    // globals so the per-unit assumption is honoured uniformly.
    function  ResolveTypeIdInUnit(const UnitName: string;
                const UnitImports: TArray<string>; ATypeId: Integer): string;
    // Owning unit + its import list for a record at StartOff (FLock-guarded).
    procedure OwningUnitContext(StartOff: Int64; out UnitName: string;
                out UnitImports: TArray<string>);
    // Lazily parse all `63 35` uses clusters into FUnitUses (one FData scan).
    procedure EnsureUnitUsesParsed;

    // Accessors for the thread-local interactive deadline (see the public class
    // property). Delphi cannot declare a threadvar as a class field, so the
    // storage is a unit-level threadvar and the property maps onto it -- callers
    // keep using `TRsmFile.InteractiveDeadlineTicks := ...` unchanged.
    class function  GetInteractiveDeadlineTicks: UInt64; static;
    class procedure SetInteractiveDeadlineTicks(Value: UInt64); static;

  public
    // Per-call upper bound (ms) WaitForIndex will block for its own module's
    // index. This stays LONG: a correctness-critical wait (breakpoint binding,
    // first locals read after a module load) must actually get the fully-built
    // index. Tunable for tests.
    class var IndexWaitBudgetMs: Cardinal;
    // PER-THREAD interactive deadline (GetTickCount64 ticks; 0 = disabled). While
    // the debugger is servicing a STOP on its dispatch/pump thread it sets this so
    // the CUMULATIVE index wait across many just-loaded modules cannot freeze the
    // event loop (a form-open that runtime-loads several large BPLs used to hang
    // the MCP server for minutes -- one full cap per module -- so even
    // wait_until_stopped could not time out). Outside that window (BP binding,
    // module load) it is 0 and the full per-call cap applies. Once the deadline
    // passes, WaitForIndex returns with whatever is indexed and the lookup fills
    // in on a later request. See MCP_LIVE_FINDINGS_TODO.md F14.
    //
    // THREAD-LOCAL on purpose (it used to be a process-wide `class var`). The
    // symbol prefetcher indexes modules on a worker thread and must NOT inherit
    // the dispatch thread's 3 s interactive budget -- it would abandon its own
    // index build half-way and publish a partially-built reader. Symmetrically, a
    // worker clearing the deadline at the end of its own scope would disarm the
    // dispatch thread's F14 protection mid-stop.
    class property InteractiveDeadlineTicks: UInt64
      read GetInteractiveDeadlineTicks write SetInteractiveDeadlineTicks;
    // Block (up to IndexWaitBudgetMs, or the interactive deadline) until the
    // background index finished. Returns True when the index is actually READY and
    // False when the wait gave up -- a caller that would cache a result derived
    // from the index must not pin it after a False (the answer was computed
    // against a half-built index and would stay wrong for the whole session).
    function WaitForIndex: Boolean;
    // Diagnostic: expose LookupTypeName for DevTools probes.
    function  DiagLookupTypeName(TypeId: Integer): string;
    function  DiagTypeIdsForName(const Substring: string): TArray<TPair<Integer, string>>;
    function  DiagUnitImports(const UnitName: string): TArray<string>;
    function  DiagClassHashCandidates(Hash: Word): TArray<string>;
    // Static, pure decoder for the per-class-member ($2C/$2E/$31) hash
    // anchor. Exposed for direct unit testing so the byte-level parsing
    // can be exercised with synthetic record bytes (e.g. the compact
    // `... $08 hashLo hashHi $FF` shape vs the suffixed variant
    // `... $08 hashLo hashHi <extras> $FF` observed on big VCL classes).
    // Returns True when an `$08` anchor is found anywhere between the
    // record's trailer (right after the name) and the last byte that
    // still leaves room for two hash bytes.
    class function DecodeClassMemberHash(Data: PByte; StartOff: Int64;
      RecLen: Integer; out Hash: Word): Boolean; static;

    // Static, pure extractor that walks a buffer and collects the type
    // names from every TTypeInfo record marked by the 8-byte prefix
    // `[$08 $00 $00 $00 $00 $00 $00 $00]`. SampleApp-style RSMs encode the
    // whole user-type table as a sequence of TTypeInfo records (one per
    // declared type) instead of the `$66`-tag table the System unit
    // uses; ParseUserTypeTable's `$65 $06 \"System\"` anchor never
    // matches there, leaving FUserTypes empty and TypeHint blank for
    // every primitive / record / class local. Names are returned in
    // file order; the index in the array corresponds to the type's
    // sequential id (TypeId = (index + 1) * 2 -- same encoding the
    // even-typeId branch of LookupTypeName already uses).
    class function ExtractTypeInfoNames(Data: PByte; Size: Int64):
      TArray<string>; static;

    // Locates the start of the SampleApp-style user-type table, anchored by
    // the ShortString sequence `\05False \04True \06System`. Returns the
    // byte offset right after the trailing `\06System` literal (i.e. where
    // the first type-record preamble begins) and True on success.
    class function FindUserTypeTableAnchor(Data: PByte; Size: Int64;
      out AnchorEndOff: Int64): Boolean; static;

    // True when the sidecar beside ASourcePath would actually be USED: present,
    // no older than its source, AND written in the current format. Anything that
    // decides whether a sidecar needs rebuilding must ask THIS, not just compare
    // timestamps -- the loader rejects a foreign magic and silently falls back to
    // a full scan, so a timestamp-only rule reports files as up to date that the
    // debugger then ignores. That is not hypothetical: after the last format
    // bump, PrebuildIdx skipped 144 sidecars as "already fresh" while every
    // session went on paying the cold scan for all of them.
    class function SidecarIsUsable(const ASourcePath: string): Boolean; static;

    constructor Create;
    destructor  Destroy; override;
    procedure   LoadFromFile(const Path: string);
    function    GetLocalsForFunction(const FunctionName: string;
                  out Locals: TArray<TLocalSymbol>): Boolean;
    function    GetLocalsForFunctionByRva(InnerRva: UInt64;
                  out Locals: TArray<TLocalSymbol>): Boolean;
    // IUnitScopedLocalProvider: find a proc named FunctionName declared WITHIN
    // UnitHint's section (resolves the cross-unit same-name collision that the
    // name-keyed FProcOffsets last-wins cannot).
    function    GetLocalsForFunctionInUnit(const FunctionName, UnitHint: string;
                  out Locals: TArray<TLocalSymbol>): Boolean;
    function    NameCollidesAcrossUnits(const FunctionName: string): Boolean;
    // IUnitUsesProvider: the units `UnitName` uses (lowercased basenames), from
    // the RSM `63 35` clusters. Parsed lazily on first call.
    function    GetUnitUses(const UnitName: string; out AUses: TArray<string>): Boolean;
    // IUnitScopedConstProvider: value of a named constant, optionally scoped to a
    // unit. From the RSM `$25` records. UnitHint='' = flat any-unit lookup.
    function    FindConstInUnit(const Name, UnitHint: string;
                  out Value: Int64; out TypeHint: string): Boolean;
    procedure   EnsureUnitConstsParsed;
    function    GetGlobals: TArray<TGlobalSymbol>;
    function    FindGlobal(const Name: string; out Global: TGlobalSymbol): Boolean;
    function    LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
    // Returns the Delphi TTypeKind byte (1..22) for a known type, or 0 if
    // no TypeInfo record was parsed for that name. tkClass = 7,
    // tkRecord = 14, tkMRecord = 22, tkInterface = 15 are the kinds the
    // adapter treats as "expandable structured value".
    function    LookupTypeKind(const TypeName: string): Byte;
    function    TryResolveEnumLiteral(const Name: string;
                  out Ordinal: Integer; out EnumTypeName: string): Boolean;
    function    GetClassMembers(const ClassName: string;
                  out Members: TArray<TClassMember>; PreferInstanceSize: Integer = 0): Boolean;
    function    AllProcedureNames: TArray<string>;
    function    DiagModuleTypeIds: TArray<TPair<Integer, string>>;
    // Diagnostic: the per-unit `$66` import tables, as `unit=N entries`. A
    // symbol's TypeId is an INDEX into its owning unit's table, so when a hint
    // resolves to an unrelated type this says whether the owning unit was found
    // at all and how many entries it has to index into.
    function    DiagUnitImportSummary: TArray<string>;
    property    Loaded: Boolean read FLoaded;
    property    UserTypes: TArray<string> read FUserTypes;
  end;

implementation

uses
  DapProtocol; // DapLog (diagnostic import-stop logging, gated by DAP_LOG=1)

threadvar
  // Backing storage for TRsmFile.InteractiveDeadlineTicks. Thread-local so the
  // dispatch thread's 3 s stop budget never leaks onto (or gets cleared by) the
  // symbol-prefetcher worker, which must be allowed to build an index to
  // completion before publishing it. Zero-initialised per thread by the RTL.
  GInteractiveDeadlineTicks: UInt64;

const
  // Bumping this invalidates every stale .idx cache, which is the ONLY way a
  // corrected index reaches a machine that already has sidecars on disk.
  // 'RSID' -> 'RSIE': the two-wave build fixed a LOSSY index. The previous flat
  // fan-out let the consumer scans resolve type hints against still-filling
  // producer dictionaries, so a cold build was non-deterministic and short --
  // three builds of one file gave three different, undersized sidecars. Those
  // degraded files were then reused by every later session, so without this bump
  // the fix would never be seen by anyone who had already debugged once.
  RSM_SIDECAR_MAGIC: UInt32 = $52534945; // 'RSIE'
  // Local-record tag bytes -- the bare-form sibling of TAG_LOCAL_VAR etc.
  // declared in RsmTags. Kept locally because the old code passes them
  // around as SUBTAG_* members for a different purpose (no $63 prefix).
  MAX_METADATA_SCAN    = 4096; // upper bound when scanning locals/params after
                               // a proc header. Real procs in big VCL forms
                               // (e.g. event handlers with 4+ params + several
                               // locals) easily exceed the previous 64-byte
                               // limit; the loop also stops early when it sees
                               // a $63 TAG_SYM_CATEGORY, which marks the next
                               // sibling RSM record.

function IsVarKindTag(B: Byte): Boolean; inline;
begin
  // $20 = local / value param, $21 = const param (class methods),
  // $22 = var/ref param, $23 = out param (used for the hidden `Result`
  // slot of var-out functions returning string / Variant / dyn-array).
  Result := (B = $20) or (B = $21) or (B = $22) or (B = $23);
end;

function IsIdentStart(C: Byte): Boolean; inline;
begin
  Result := ((C >= Ord('A')) and (C <= Ord('Z'))) or
            ((C >= Ord('a')) and (C <= Ord('z'))) or (C = Ord('_'));
end;

function IsIdentCont(C: Byte): Boolean; inline;
begin
  Result := ((C >= Ord('A')) and (C <= Ord('Z'))) or
            ((C >= Ord('a')) and (C <= Ord('z'))) or
            ((C >= Ord('0')) and (C <= Ord('9'))) or
            (C = Ord('_')) or (C = Ord('.'));
end;

{ TRsmFile }

class function TRsmFile.DecodeClassMemberHash(Data: PByte; StartOff: Int64;
  RecLen: Integer; out Hash: Word): Boolean;
var
  NameLen:        Integer;
  ScanFrom, I:    Int64;
  CandHash:       Word;
begin
  // Walk the trailer of a class-member ($2C/$2E/$31) record and locate the
  // `$08` anchor that has two bytes following it (the class-hash Word LE).
  // Two record shapes coexist:
  //   compact:   `... $08 hashLo hashHi $FF`
  //   suffixed:  `... $08 hashLo hashHi <suffix...> $FF`
  //              (e.g. FLicenzaDgMessenger on big VCL classes)
  //
  // Walk BACKWARD from the $FF terminator. The first $08 we hit whose
  // following two bytes form a non-zero Word is the class hash. Walking
  // backward (and rejecting zero-hash matches) skips both
  //   (a) stray $08 bytes inside the kind-data trailer (observed on
  //       Debugme.dpr's TFoo.Value: `08 20 9C 09 F1 1E ...` BEFORE the
  //       real `08 7D 1C $FF` anchor; a forward-scanner would pick the
  //       spurious hash $9C20), AND
  //   (b) $08 bytes that happen to appear inside the suffix of records
  //       that carry one (zero-hash false positives caught by the
  //       non-zero validation).
  Result   := False;
  Hash     := 0;
  if (Data = nil) or (RecLen < 5) then Exit;
  NameLen  := Data[StartOff + 1];
  if NameLen < 1 then Exit;
  ScanFrom := StartOff + 2 + NameLen;
  for I := StartOff + RecLen - 3 downto ScanFrom do
    if Data[I] = $08 then begin
      // 1-byte class-hash form `$08 lo $FF`: `lo` is immediately followed by the
      // record terminator, so there is NO high byte. A fixed 2-byte read folds
      // the $FF in ($FFlo instead of $00lo) and indexes the member under a hash
      // the matching $2A declaration never registers (unit-section Variant-D
      // classes whose member-binding hash is an even 1-byte VLE -- TWideFields,
      // TBareClass, TWidget relocated into a unit). Recognise it as $00lo.
      if (I + 2 = StartOff + RecLen - 1) and (Data[I + 2] = $FF) then begin
        Hash := Data[I + 1];
        Exit(True);
      end;
      CandHash := Data[I + 1] or (Integer(Data[I + 2]) shl 8);
      if CandHash <> 0 then begin
        Hash := CandHash;
        Exit(True);
      end;
    end;
end;

class function TRsmFile.FindUserTypeTableAnchor(Data: PByte; Size: Int64;
  out AnchorEndOff: Int64): Boolean;
const
  Anchor: array[0..17] of Byte = (
    $05, Ord('F'), Ord('a'), Ord('l'), Ord('s'), Ord('e'),
    $04, Ord('T'), Ord('r'), Ord('u'), Ord('e'),
    $06, Ord('S'), Ord('y'), Ord('s'), Ord('t'), Ord('e'), Ord('m'));
var
  Off, I: Int64;
  Match:  Boolean;
begin
  Result      := False;
  AnchorEndOff := 0;
  if (Data = nil) or (Size < Length(Anchor)) then Exit;
  Off := 0;
  while Off + Length(Anchor) <= Size do begin
    // Reject on one unaligned 64-bit compare against the first 8 anchor bytes
    // before setting up the byte loop. This scan walks the whole file (it is
    // the TypeInfo fallback, and on a .dcp it walks 45 MB and finds nothing),
    // and the per-byte `for` loop with its Match flag dominated the cost.
    // Equivalent by construction: the byte loop below re-checks all 18 bytes.
    if PUInt64(Data + Off)^ <> PUInt64(@Anchor[0])^ then begin
      Inc(Off);
      Continue;
    end;
    Match := True;
    for I := 0 to High(Anchor) do
      if Data[Off + I] <> Anchor[I] then begin
        Match := False;
        Break;
      end;
    if Match then begin
      AnchorEndOff := Off + Length(Anchor);
      Exit(True);
    end;
    Inc(Off);
  end;
end;

class function TRsmFile.ExtractTypeInfoNames(Data: PByte; Size: Int64):
  TArray<string>;
const
  MIN_TKIND = 1;
  MAX_TKIND = 22; // tkMRecord -- latest Delphi as of Athens 36
var
  Off: Int64;
  Kind, NameLen, I: Integer;
  Name: string;
  AllValid: Boolean;
begin
  SetLength(Result, 0);
  if (Data = nil) or (Size <= 0) then Exit;
  // Amortized-growth accumulator. A `Result := Result + [Name]` append inside
  // this loop is O(n^2): each append reallocates the whole managed-string array
  // and refcounts every prior element. On a big project (SampleApp: tens of
  // thousands of TypeInfo names in a 2 MB .rsm) that turned this scan into a
  // 60+ second synchronous stall. TList.Add is amortized O(1); convert once.
  var Names := TList<string>.Create;
  try
  Off := 0;
  while Off + 12 <= Size do begin
    // Hunt for the 8-byte `$08 00 00 00 00 00 00 00` TypeInfo prefix.
    // Single unaligned 64-bit compare, see ParseTypeInfoSection for the
    // measurement; the `Off + 12 <= Size` loop guard covers the read.
    if PUInt64(Data + Off)^ <> UInt64($0000000000000008) then begin
      Inc(Off);
      Continue;
    end;
    Kind    := Data[Off + 8];
    NameLen := Data[Off + 9];
    if (Kind < MIN_TKIND) or (Kind > MAX_TKIND) or
       (NameLen < 1) or (NameLen > 63) or
       (Off + 10 + NameLen > Size) then begin
      Inc(Off);
      Continue;
    end;
    // Every byte of the name must be printable ASCII (incl. punctuation
    // used by generics: `<`, `>`, `{`, `}`, `.`, ` `, `,`). Reject control
    // bytes and 8-bit garbage so accidental 8-zero runs inside kind-data
    // are not mistaken for type entries.
    AllValid := True;
    for I := 0 to NameLen - 1 do begin
      var C := Data[Off + 10 + I];
      if (C < $20) or (C > $7E) then begin
        AllValid := False;
        Break;
      end;
    end;
    if not AllValid then begin
      Inc(Off);
      Continue;
    end;
    SetString(Name, PAnsiChar(Data + Off + 10), NameLen);
    Names.Add(Name);
    // Skip past the marker + Kind + NameLen + name bytes. Kind-data
    // trailers vary by Kind; rely on the byte-by-byte miss path above to
    // re-sync at the next prefix rather than try to fully decode each
    // shape here.
    Inc(Off, 10 + NameLen);
  end;
    Result := Names.ToArray;
  finally
    Names.Free;
  end;
end;

constructor TRsmFile.Create;
begin
  inherited;
  FFileHandle    := INVALID_HANDLE_VALUE;
  FMappingHandle := 0;
  FData          := nil;
  FDataSize      := 0;
  FProcOffsets   := TDictionary<string, Int64>.Create;
  FProcLocals    := TDictionary<string, TArray<TLocalSymbol>>.Create;
  FProvisionalLocals := TDictionary<string, TArray<TLocalSymbol>>.Create;
  FGlobals       := TList<TGlobalSymbol>.Create;
  FTypeIdToName  := TDictionary<Integer, string>.Create;
  FClassHashCandidates := TDictionary<Word, TArray<string>>.Create;
  FEnumInfoByName := TDictionary<string, TRsmEnumInfo>.Create;
  FClassMembers   := TDictionary<string, TArray<TClassMember>>.Create;
  FClassMemberOffsets      := TDictionary<Word, TArray<Int64>>.Create;
  FClassDeclarationOffsets := TDictionary<string, Int64>.Create;
  FClassNameToHash         := TDictionary<string, TArray<Word>>.Create;
  FTypeKindByName := TDictionary<string, Byte>.Create;
  FUnitImports    := TDictionary<string, TArray<string>>.Create;
  FUnitUses       := TDictionary<string, TArray<string>>.Create;
  FUnitUsesParsed := False;
  FUnitConsts      := TDictionary<string, Int64>.Create;
  FUnitConstTypes  := TDictionary<string, string>.Create;
  FConstByName     := TDictionary<string, Int64>.Create;
  FConstTypeByName := TDictionary<string, string>.Create;
  FUnitConstsParsed := False;
  FClassUnit      := TDictionary<string, string>.Create;
  FUnitAnchors    := TList<TPair<Int64, string>>.Create;
  FCollidingProcNames := TDictionary<string, Boolean>.Create;
  FCollisionReady := False;
  FLock          := TCriticalSection.Create;
end;

destructor TRsmFile.Destroy;
begin
  CloseMappedFile;
  FProcOffsets.Free;
  FProcLocals.Free;
  FProvisionalLocals.Free;
  FGlobals.Free;
  FTypeIdToName.Free;
  FClassHashCandidates.Free;
  FEnumInfoByName.Free;
  FClassMembers.Free;
  FClassMemberOffsets.Free;
  FClassDeclarationOffsets.Free;
  FClassNameToHash.Free;
  FTypeKindByName.Free;
  FUnitImports.Free;
  FUnitUses.Free;
  FUnitConsts.Free;
  FUnitConstTypes.Free;
  FConstByName.Free;
  FConstTypeByName.Free;
  FClassUnit.Free;
  FUnitAnchors.Free;
  FCollidingProcNames.Free;
  FLock.Free;
  inherited;
end;

procedure TRsmFile.OpenMappedFile(const Path: string);
begin
  FFileHandle := CreateFile(PChar(Path), GENERIC_READ, FILE_SHARE_READ, nil,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FFileHandle = INVALID_HANDLE_VALUE then
    Exit;
  var SizeLow, SizeHigh: DWORD;
  SizeLow := GetFileSize(FFileHandle, @SizeHigh);
  FDataSize := Int64(SizeHigh) shl 32 or SizeLow;
  if FDataSize = 0 then begin
    CloseMappedFile;
    Exit;
  end;
  FMappingHandle := CreateFileMapping(FFileHandle, nil, PAGE_READONLY, 0, 0, nil);
  if FMappingHandle = 0 then begin
    CloseMappedFile;
    Exit;
  end;
  FData := MapViewOfFile(FMappingHandle, FILE_MAP_READ, 0, 0, 0);
  if FData = nil then
    CloseMappedFile;
end;

procedure TRsmFile.CloseMappedFile;
begin
  if FData <> nil then begin
    UnmapViewOfFile(FData);
    FData := nil;
  end;
  if FMappingHandle <> 0 then begin
    CloseHandle(FMappingHandle);
    FMappingHandle := 0;
  end;
  if FFileHandle <> INVALID_HANDLE_VALUE then begin
    CloseHandle(FFileHandle);
    FFileHandle := INVALID_HANDLE_VALUE;
  end;
  FDataSize := 0;
end;

procedure TRsmFile.LoadFromFile(const Path: string);
begin
  FRsmPath     := Path;
  FLoaded      := False;
  FIndexReady  := False;
  FProcOffsets.Clear;
  FProcLocals.Clear;
  FProvisionalLocals.Clear;
  FGlobals.Clear;
  FTypeIdToName.Clear;
  FClassHashCandidates.Clear;
  FEnumInfoByName.Clear;
  FClassMembers.Clear;
  FClassMemberOffsets.Clear;
  FClassDeclarationOffsets.Clear;
  FClassNameToHash.Clear;
  FTypeKindByName.Clear;
  FUnitImports.Clear;
  FClassUnit.Clear;
  FUnitAnchors.Clear;
  SetLength(FUserTypes, 0);
  CloseMappedFile;

  if not FileExists(Path) then
    Exit;

  OpenMappedFile(Path);
  if FData = nil then
    Exit;

  // Accepted magics:
  //   'CSH7' -- Delphi remote symbol map (.rsm), produced for EXE/DLL targets
  //   'PKX0' -- Delphi compiled package (.dcp), used as fallback symbol source
  //            for code that lives inside a runtime BPL. The dcc64 package
  //            linker emits unit-level debug records (proc / locals / params /
  //            type metadata) into the .dcp using the same record schema as
  //            the .rsm; only the file-prefix container differs, and the
  //            byte-walking scanners ignore that prefix anyway.
  if FDataSize < 4 then begin
    CloseMappedFile;
    Exit;
  end;
  var IsRsm := (FData[0] = Ord('C')) and (FData[1] = Ord('S')) and
               (FData[2] = Ord('H')) and (FData[3] = Ord('7'));
  var IsDcp := (FData[0] = Ord('P')) and (FData[1] = Ord('K')) and
               (FData[2] = Ord('X')) and (FData[3] = Ord('0'));
  if not (IsRsm or IsDcp) then begin
    CloseMappedFile;
    Exit;
  end;

  // Sidecar fast-path: if a valid `.idx` exists alongside the .rsm and is
  // at least as new, load the entire parser state from it and skip every
  // expensive scan. On cold start (or after RSM mtime changes) we fall
  // through to the full pipeline below.
  var SidecarPath := FRsmPath + '.idx';
  if SidecarIsUsable(FRsmPath) and LoadProcIndexFromSidecar(SidecarPath) then begin
    FLoaded := True;
    FLock.Acquire;
    try
      FIndexReady := True;
    finally
      FLock.Release;
    end;
    Exit;
  end;

  // Cold path: parse everything, then persist to sidecar.
  // User type table is small and parsed synchronously (early variable
  // requests can use it before the background indexer finishes).
  ParseUserTypeTable;

  FLoaded := True;

  TThread.CreateAnonymousThread(procedure
  begin
    BuildIndexAndPublish(SidecarPath);
  end).Start;
end;

procedure TRsmFile.BuildIndexAndPublish(const SidecarPath: string);
begin
  var IndexBytes: TMemoryStream := nil;
  try
    try
      // The index build runs in two WAVES, not one flat fan-out.
      //
      // Wave 1 phases are pure producers: each walks the whole byte buffer and
      // fills containers no other wave-1 phase reads, so they can run
      // concurrently and the wall-clock cost collapses to ~max(individual cost)
      // instead of their sum.
      //
      // Wave 2 phases are CONSUMERS of wave 1. ScanForProcOffsets (via
      // TryParseGlobalAt) and CollectMainBlockLocals both call
      // OwningUnitContext + ResolveTypeIdInUnit, which read FUnitAnchors /
      // FUnitImports (ParsePerUnitImports), FTypeIdToName /
      // FClassHashCandidates (ParseTypeDeclarationSection) and FUserTypes.
      // Running them inside the same fan-out as their producers made the build
      // both LOSSY and NON-DETERMINISTIC: type hints resolved against
      // half-filled dictionaries, so three consecutive cold builds of the same
      // SampleApp.rsm produced three different sidecars, all smaller than the one
      // the same code produces when the phases run sequentially -- and that
      // degraded index is what got cached in the .idx. It also read
      // FTypeIdToName / FClassHashCandidates without FLock while another task
      // was writing them under it, which is an access-violation risk on a
      // TDictionary rehash, not merely a wrong answer.
      //
      // Splitting into waves fixes both: the sidecar is now reproducible and
      // identical to the fully sequential reference. It is not slower either --
      // moving IndexClassMemberRecords (~210 ms on cxLibraryRS29.dcp, the
      // largest single phase) out of its own serial step and into wave 1
      // roughly cancels the cost of the extra join.
      var Producers := TArray<TProc>.Create(
        procedure begin ParsePerUnitImports;          end,
        procedure begin ParseTypeDeclarationSection;  end,
        procedure begin ParseTypeInfoSection;         end,
        // Collects every $2C/$2E/$31 record offset grouped by 16-bit class
        // hash. Actual per-member decoding (with per-unit TypeName resolution)
        // is deferred to GetClassMembers so unused classes never pay for it.
        // Reads raw bytes only, writes only FClassMemberOffsets -- hence wave 1.
        procedure begin IndexClassMemberRecords;      end
      );
      TParallel.&For(0, High(Producers), procedure(I: Integer) begin Producers[I](); end);

      var Consumers := TArray<TProc>.Create(
        procedure begin ScanForProcOffsets;           end,
        procedure begin CollectMainBlockLocals;       end
      );
      TParallel.&For(0, High(Consumers), procedure(I: Integer) begin Consumers[I](); end);

      // Serialise, PUBLISH READINESS, then write to disk -- in that order.
      //
      // Readiness used to be set after the file write, which coupled symbol
      // availability to I/O latency: every WaitForIndex on the dispatch thread
      // waited for a sidecar write to a shared (possibly network) BPL output
      // directory that no caller needs.
      //
      // Readiness is NOT moved before the serialisation, which would be unsafe
      // and non-deterministic: the serialiser enumerates containers (FProcLocals
      // above all) that lazy lookups mutate once the index is ready, so the
      // sidecar's contents would depend on which lookups happened to land
      // first. Serialising first keeps the byte stream reproducible (the
      // property IndexBuild_SidecarIsReproducible asserts) and leaves only the
      // ~10 ms of in-memory serialisation, not the file write, ahead of
      // readiness.
      IndexBytes := SerializeIndexToStream;
    finally
      // Unconditional, and it covers the phases above as well: a reader whose
      // FIndexReady is never set makes every later WaitForIndex burn its full
      // 60 s budget. That is exactly how a failed sidecar write used to hang
      // the debugger for a minute per lookup.
      MarkIndexReady;
    end;
    PublishSidecar(IndexBytes, SidecarPath);
  finally
    IndexBytes.Free;
  end;
end;

class function TRsmFile.SidecarIsUsable(const ASourcePath: string): Boolean;
begin
  Result := False;
  var SidecarPath := ASourcePath + '.idx';
  if not FileExists(SidecarPath) then
    Exit;
  try
    if TFile.GetLastWriteTime(SidecarPath) < TFile.GetLastWriteTime(ASourcePath) then
      Exit;
    var F := TFileStream.Create(SidecarPath, fmOpenRead or fmShareDenyNone);
    try
      var Magic: UInt32 := 0;
      if F.Read(Magic, SizeOf(Magic)) <> SizeOf(Magic) then
        Exit;
      Result := Magic = RSM_SIDECAR_MAGIC;
    finally
      F.Free;
    end;
  except
    // Unreadable or locked: treat as unusable so the caller rebuilds or parses.
    Result := False;
  end;
end;

class function TRsmFile.GetInteractiveDeadlineTicks: UInt64;
begin
  Result := GInteractiveDeadlineTicks;
end;

class procedure TRsmFile.SetInteractiveDeadlineTicks(Value: UInt64);
begin
  GInteractiveDeadlineTicks := Value;
end;

function TRsmFile.WaitForIndex: Boolean;
begin
  var Deadline := GetTickCount64 + IndexWaitBudgetMs;
  while True do begin
    FLock.Acquire;
    try
      if FIndexReady then Exit(True);
    finally
      FLock.Release;
    end;
    // Interactive stop path: bail out early so cumulative waits across modules
    // cannot freeze the dispatch thread (F14). 0 = not in an interactive window.
    if (InteractiveDeadlineTicks <> 0) and (GetTickCount64 >= InteractiveDeadlineTicks) then
      Exit(False);
    if GetTickCount64 > Deadline then Exit(False);
    Sleep(10);
  end;
end;

function TRsmFile.LoadProcIndexFromSidecar(const SidecarPath: string): Boolean;
var
  F: TStream;
  Magic: UInt32;
  ProcCount, GlobCount, ProcLocalsCount, LocalCount: UInt32;
  // Loop counters MUST be signed: `for I := 0 to Count - 1` with an unsigned I
  // and Count = 0 underflows `Count - 1` to $FFFFFFFF and spins ~4 billion times
  // over garbage -- the reason this sidecar never once loaded (SampleApp has zero
  // proc-locals, so ProcLocalsCount = 0 hit the underflow every time).
  I, J: Integer;
  Offset: Int64;
  G: TGlobalSymbol;
  KindByte, DirectByte: Byte;
begin
  Result := False;
  try
    // Read the whole sidecar into memory up front. The decoder issues thousands
    // of tiny ReadBuffer calls (one per field); against an unbuffered TFileStream
    // each is a separate syscall, and a corrupt count used to drive a huge read
    // loop -- together a multi-second-to-minute stall. A memory stream makes every
    // read a memcpy and turns any past-end read into an immediate fast failure.
    F := TMemoryStream.Create;
    try
      TMemoryStream(F).LoadFromFile(SidecarPath);
      if F.Size < 8 then Exit;
      F.ReadBuffer(Magic, 4);
      if Magic <> RSM_SIDECAR_MAGIC then Exit;
      // Proc offsets
      F.ReadBuffer(ProcCount, 4);
      for I := 0 to Integer(ProcCount) - 1 do begin
        var Key := SidecarReadStr(F);
        F.ReadBuffer(Offset, 8);
        FProcOffsets.AddOrSetValue(Key, Offset);
      end;
      // Globals
      F.ReadBuffer(GlobCount, 4);
      for I := 0 to Integer(GlobCount) - 1 do begin
        G.Name := SidecarReadStr(F);
        F.ReadBuffer(G.RVA, 8);
        F.ReadBuffer(G.TypeId, 4);
        G.TypeHint := SidecarReadStr(F);
        FGlobals.Add(G);
      end;
      // Proc locals
      F.ReadBuffer(ProcLocalsCount, 4);
      for I := 0 to Integer(ProcLocalsCount) - 1 do begin
        var ProcName := SidecarReadStr(F);
        F.ReadBuffer(LocalCount, 4);
        SidecarGuardCount(F, LocalCount);
        var Locals: TArray<TLocalSymbol>;
        SetLength(Locals, LocalCount);
        for J := 0 to Integer(LocalCount) - 1 do begin
          Locals[J].Name := SidecarReadStr(F);
          F.ReadBuffer(Locals[J].RbpOffset, 4);
          F.ReadBuffer(Locals[J].TypeId, 4);
          Locals[J].TypeHint := SidecarReadStr(F);
          F.ReadBuffer(KindByte, 1);
          Locals[J].Kind := TLocalKind(KindByte);
          F.ReadBuffer(DirectByte, 1);
          Locals[J].UseDirectOffset := DirectByte <> 0;
        end;
        FProcLocals.AddOrSetValue(ProcName, Locals);
      end;
      // FUserTypes
      FUserTypes := SidecarReadStrArr(F);
      // FUnitImports
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var UN := SidecarReadStr(F);
        var Arr := SidecarReadStrArr(F);
        FUnitImports.AddOrSetValue(UN, Arr);
      end;
      // FUnitAnchors
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var AOff: Int64;
        F.ReadBuffer(AOff, 8);
        var AName := SidecarReadStr(F);
        FUnitAnchors.Add(TPair<Int64, string>.Create(AOff, AName));
      end;
      // FClassUnit
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var KName := SidecarReadStr(F);
        var VName := SidecarReadStr(F);
        FClassUnit.AddOrSetValue(KName, VName);
      end;
      // FTypeIdToName
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var Tid: Integer;
        F.ReadBuffer(Tid, 4);
        var TName := SidecarReadStr(F);
        FTypeIdToName.AddOrSetValue(Tid, TName);
      end;
      // FClassHashCandidates
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var H: Word;
        F.ReadBuffer(H, 2);
        var Arr := SidecarReadStrArr(F);
        FClassHashCandidates.AddOrSetValue(H, Arr);
      end;
      // FTypeKindByName
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var TN := SidecarReadStr(F);
        var KB: Byte;
        F.ReadBuffer(KB, 1);
        FTypeKindByName.AddOrSetValue(TN, KB);
      end;
      // FEnumInfoByName
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var EN := SidecarReadStr(F);
        var EI: TRsmEnumInfo;
        F.ReadBuffer(EI.Kind, 1);
        F.ReadBuffer(EI.MinValue, 4);
        F.ReadBuffer(EI.MaxValue, 4);
        EI.Names := SidecarReadStrArr(F);
        EI.BaseTypeName := SidecarReadStr(F);
        var ValidByte: Byte;
        F.ReadBuffer(ValidByte, 1);
        EI.IsValid := ValidByte <> 0;
        FEnumInfoByName.AddOrSetValue(EN, EI);
      end;
      // FClassMemberOffsets (lazy decode source)
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var H: Word;
        F.ReadBuffer(H, 2);
        var CCount: UInt32;
        F.ReadBuffer(CCount, 4);
        SidecarGuardCount(F, CCount, 8);
        var OffArr: TArray<Int64>;
        SetLength(OffArr, CCount);
        for var J2 := 0 to Integer(CCount) - 1 do
          F.ReadBuffer(OffArr[J2], 8);
        FClassMemberOffsets.AddOrSetValue(H, OffArr);
      end;
      // FClassDeclarationOffsets
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var KN := SidecarReadStr(F);
        var V: Int64;
        F.ReadBuffer(V, 8);
        FClassDeclarationOffsets.AddOrSetValue(KN, V);
      end;
      // FClassNameToHash
      F.ReadBuffer(I, 4);
      for var K := 0 to Integer(I) - 1 do begin
        var KN := SidecarReadStr(F);
        var HCount: UInt32;
        F.ReadBuffer(HCount, 4);
        SidecarGuardCount(F, HCount, 2);
        var HArr: TArray<Word>;
        SetLength(HArr, HCount);
        for var J2 := 0 to Integer(HCount) - 1 do
          F.ReadBuffer(HArr[J2], 2);
        FClassNameToHash.AddOrSetValue(KN, HArr);
      end;
      Result := True;
    finally
      F.Free;
    end;
  except
    // Any decode failure (bad magic, truncated/corrupt sidecar, out-of-range
    // count) discards partial state and falls back to the cold parse.
    FProcOffsets.Clear;
    FGlobals.Clear;
    FProcLocals.Clear;
    SetLength(FUserTypes, 0);
    FUnitImports.Clear;
    FUnitAnchors.Clear;
    FClassUnit.Clear;
    FTypeIdToName.Clear;
    FClassHashCandidates.Clear;
    FTypeKindByName.Clear;
    FEnumInfoByName.Clear;
    FClassMembers.Clear;
    FClassMemberOffsets.Clear;
    FClassDeclarationOffsets.Clear;
    FClassNameToHash.Clear;
    Result := False;
  end;
end;

procedure TRsmFile.MarkIndexReady;
begin
  FLock.Acquire;
  try
    FIndexReady := True;
  finally
    FLock.Release;
  end;
end;

procedure TRsmFile.PublishSidecar(Stream: TMemoryStream; const SidecarPath: string);
begin
  if Stream = nil then Exit;
  // Publish ATOMICALLY: write a private temp file, then rename it over the
  // target. Writing straight to SidecarPath let any concurrent reader (another
  // debug session, or DevTools\PrebuildIdx) open a HALF-WRITTEN index; the
  // reader's own guards catch most truncations, but nothing makes a partial
  // file distinguishable from a complete one in general.
  var TempPath := Format('%s.%.8x-%.8x.tmp',
    [SidecarPath, GetCurrentProcessId, GetCurrentThreadId]);
  try
    try
      Stream.SaveToFile(TempPath);
      // A rename that loses a race is FINE: whatever is already there was
      // published by another writer and is complete. What must never happen is
      // what the old code did -- deleting a sidecar it did not write (and, when
      // that delete failed too, letting the exception escape the index thread,
      // so FIndexReady stayed False and every WaitForIndex burned its full 60 s
      // budget). PrebuildIdx running alongside a live session hit exactly that.
      if not MoveFileEx(PChar(TempPath), PChar(SidecarPath), MOVEFILE_REPLACE_EXISTING) then
        RaiseLastOSError;
    except
      // Best effort: remove OUR temp file. Any sidecar at SidecarPath belongs
      // to someone else and is left untouched.
      if TFile.Exists(TempPath) then
        TFile.Delete(TempPath);
    end;
  except
    // Cleanup failed as well. A stray .tmp is harmless; an exception escaping
    // into the index thread is not.
  end;
end;

function TRsmFile.SerializeIndexToStream: TMemoryStream;
var
  F: TStream;
  Magic: UInt32;
  Count: UInt32;
begin
  Result := nil;
  try
    // Serialise into MEMORY while holding FLock; the caller writes the finished
    // buffer to disk with the lock released.
    //
    // The lock is mandatory. This runs on the index thread BEFORE FIndexReady is
    // set, and it enumerates containers (FProcLocals above all) that the dispatch
    // thread mutates under FLock as soon as its WaitForIndex gives up -- exactly
    // what the 3 s interactive budget makes happen during a many-package stop. A
    // TDictionary rehash under a for-in is an access violation, not a wrong
    // answer. The under-lock cost is the ~10 ms of pure serialisation measured
    // after the buffering fix; the file write, which is the part that can block
    // on a slow or network output directory, stays outside.
    //
    // The byte stream is unchanged (verified byte-identical by SHA-256 on
    // cxLibraryRS29.dcp, Spring.Base.dcp, Tee929.dcp, SampleApp.rsm).
    F := TMemoryStream.Create;
    try
      FLock.Acquire;
      try
        Magic := RSM_SIDECAR_MAGIC;
        F.WriteBuffer(Magic, 4);
        // FProcOffsets
        Count := FProcOffsets.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FProcOffsets do begin
          SidecarWriteStr(F, KV.Key);
          F.WriteBuffer(KV.Value, 8);
        end;
        // FGlobals
        Count := FGlobals.Count;
        F.WriteBuffer(Count, 4);
        for var G in FGlobals do begin
          SidecarWriteStr(F, G.Name);
          F.WriteBuffer(G.RVA, 8);
          F.WriteBuffer(G.TypeId, 4);
          SidecarWriteStr(F, G.TypeHint);
        end;
        // FProcLocals
        Count := FProcLocals.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FProcLocals do begin
          SidecarWriteStr(F, KV.Key);
          var LocalCount: UInt32 := Length(KV.Value);
          F.WriteBuffer(LocalCount, 4);
          for var L in KV.Value do begin
            SidecarWriteStr(F, L.Name);
            F.WriteBuffer(L.RbpOffset, 4);
            F.WriteBuffer(L.TypeId, 4);
            SidecarWriteStr(F, L.TypeHint);
            var KindByte: Byte := Ord(L.Kind);
            F.WriteBuffer(KindByte, 1);
            var DirectByte: Byte := Ord(L.UseDirectOffset);
            F.WriteBuffer(DirectByte, 1);
          end;
        end;
        // FUserTypes
        SidecarWriteStrArr(F, FUserTypes);
        // FUnitImports
        Count := FUnitImports.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FUnitImports do begin
          SidecarWriteStr(F, KV.Key);
          SidecarWriteStrArr(F, KV.Value);
        end;
        // FUnitAnchors
        Count := FUnitAnchors.Count;
        F.WriteBuffer(Count, 4);
        for var P in FUnitAnchors do begin
          var AOff: Int64 := P.Key;
          F.WriteBuffer(AOff, 8);
          SidecarWriteStr(F, P.Value);
        end;
        // FClassUnit
        Count := FClassUnit.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FClassUnit do begin
          SidecarWriteStr(F, KV.Key);
          SidecarWriteStr(F, KV.Value);
        end;
        // FTypeIdToName
        Count := FTypeIdToName.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FTypeIdToName do begin
          var Tid: Integer := KV.Key;
          F.WriteBuffer(Tid, 4);
          SidecarWriteStr(F, KV.Value);
        end;
        // FClassHashCandidates
        Count := FClassHashCandidates.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FClassHashCandidates do begin
          var H: Word := KV.Key;
          F.WriteBuffer(H, 2);
          SidecarWriteStrArr(F, KV.Value);
        end;
        // FTypeKindByName
        Count := FTypeKindByName.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FTypeKindByName do begin
          SidecarWriteStr(F, KV.Key);
          F.WriteBuffer(KV.Value, 1);
        end;
        // FEnumInfoByName
        Count := FEnumInfoByName.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FEnumInfoByName do begin
          SidecarWriteStr(F, KV.Key);
          F.WriteBuffer(KV.Value.Kind, 1);
          F.WriteBuffer(KV.Value.MinValue, 4);
          F.WriteBuffer(KV.Value.MaxValue, 4);
          SidecarWriteStrArr(F, KV.Value.Names);
          SidecarWriteStr(F, KV.Value.BaseTypeName);
          var ValidByte: Byte := Ord(KV.Value.IsValid);
          F.WriteBuffer(ValidByte, 1);
        end;
        // FClassMemberOffsets
        Count := FClassMemberOffsets.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FClassMemberOffsets do begin
          var H: Word := KV.Key;
          F.WriteBuffer(H, 2);
          var CCount: UInt32 := Length(KV.Value);
          F.WriteBuffer(CCount, 4);
          for var V in KV.Value do
            F.WriteBuffer(V, 8);
        end;
        // FClassDeclarationOffsets
        Count := FClassDeclarationOffsets.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FClassDeclarationOffsets do begin
          SidecarWriteStr(F, KV.Key);
          var V: Int64 := KV.Value;
          F.WriteBuffer(V, 8);
        end;
        // FClassNameToHash
        Count := FClassNameToHash.Count;
        F.WriteBuffer(Count, 4);
        for var KV in FClassNameToHash do begin
          SidecarWriteStr(F, KV.Key);
          var HCount: UInt32 := Length(KV.Value);
          F.WriteBuffer(HCount, 4);
          for var H in KV.Value do
            F.WriteBuffer(H, 2);
        end;
      finally
        FLock.Release;
      end;
      Result := TMemoryStream(F);
    except
      F.Free;
      raise;
    end;
  except
    // A failed serialisation costs the sidecar (the next session rebuilds the
    // index from the .rsm), nothing else. It must not propagate: the caller has
    // still to publish readiness.
    Result := nil;
  end;
end;

// Fast-skip past a procedure body (metadata + local var records) to find
// the offset of the next procedure or global header.
// Looks for $63 followed by $28 (procedure) or $20 (global) with a sane name-len.
function SkipProcBody(Data: PByte; DataSize: Int64; Off: Int64): Int64;

  function LooksLikeName(NameOff: Int64; NameLen: Byte): Boolean;
  var
    C: Byte;
  begin
    Result := False;
    if (NameLen < 1) or (NameLen > 63) or (NameOff + NameLen > DataSize) then Exit;
    C := Data[NameOff];
    Result := ((C >= Ord('A')) and (C <= Ord('Z'))) or
              ((C >= Ord('a')) and (C <= Ord('z'))) or
              (C = Ord('_'));
  end;

var
  Limit: Int64;
begin
  Limit := Off + 65536;
  if Limit > DataSize - 2 then Limit := DataSize - 2;
  while Off < Limit do begin
    if Data[Off] = $63 then begin
      var Sub := Data[Off + 1];
      if (Sub = $28) or (Sub = $20) then begin
        if LooksLikeName(Off + 3, Data[Off + 2]) then
          Exit(Off);
      end;
    end;
    // Bare $28 -- class method without $63 prefix (occurs in .dpr-defined classes).
    if (Data[Off] = $28) and ((Off = 0) or (Data[Off - 1] <> $63)) and
       LooksLikeName(Off + 2, Data[Off + 1]) then
      Exit(Off);
    Inc(Off);
  end;
  Result := Off;
end;

function TRsmFile.ScanForProcOffsets: Boolean;
var
  Off: Int64;
begin
  // Sidecar fast-path is now handled at LoadFromFile level: if a valid
  // sidecar exists, the entire parser pipeline (including this scan) is
  // skipped. By the time we get here, we know we're on the cold path.
  Result := False;

  Off := 0;
  while Off + 4 < FDataSize do begin
    // Procedure header: 63 28 [LEN] [NAME]
    if (FData[Off] = TAG_SYM_CATEGORY) and (FData[Off + 1] = SUBTAG_PROCEDURE) then begin
      var NameLen := FData[Off + 2];
      var ProcName: string;
      if (NameLen >= 1) and (NameLen <= 63) and
         TryReadIdent(Off + 3, NameLen, ProcName) then begin
        FLock.Acquire;
        try
          FProcOffsets.AddOrSetValue(LowerCase(ProcName), Off);
        finally
          FLock.Release;
        end;
        // Skip past proc header + name, then scan for next boundary.
        Off := SkipProcBody(FData, FDataSize, Off + 3 + NameLen);
        Continue;
      end;
    end;

    // Bare 28 [LEN] [NAME] -- class method records (no preceding $63).
    // Only match when the preceding byte is not $63 (to avoid double-counting $63 $28).
    if (FData[Off] = SUBTAG_PROCEDURE) and
       ((Off = 0) or (FData[Off - 1] <> TAG_SYM_CATEGORY)) then begin
      var BareNameLen := FData[Off + 1];
      var BareProcName: string;
      if (BareNameLen >= 1) and (BareNameLen <= 63) and
         TryReadIdent(Off + 2, BareNameLen, BareProcName) then begin
        FLock.Acquire;
        try
          FProcOffsets.AddOrSetValue(LowerCase(BareProcName), Off);
        finally
          FLock.Release;
        end;
        Off := SkipProcBody(FData, FDataSize, Off + 2 + BareNameLen);
        Continue;
      end;
    end;

    // Global var header: 63 20 [LEN] [NAME] ...
    // The two tag bytes are tested HERE, before the call, even though
    // TryParseGlobalAt re-tests them itself (see its guard). This scan visits
    // every byte of the file, and the callee takes an out TGlobalSymbol holding
    // two managed strings: calling it unconditionally paid a non-inlined call
    // plus record initialise/finalise for all ~45 million bytes of a 45 MB .dcp,
    // only to be rejected on these same two compares. Measured on real inputs,
    // hoisting them makes this scan 6-10x faster and roughly HALVES the whole
    // cold index build (it was 54% of it); the emitted .idx is byte-identical.
    if (Off + 3 <= FDataSize) and
       (FData[Off] = TAG_SYM_CATEGORY) and (FData[Off + 1] = SUBTAG_GLOBAL_VAR) then begin
      var NextOff: Int64;
      var Global: TGlobalSymbol;
      if TryParseGlobalAt(Off, NextOff, Global) then begin
        FLock.Acquire;
        try
          FGlobals.Add(Global);
        finally
          FLock.Release;
        end;
        Off := NextOff;
        Continue;
      end;
    end;

    Inc(Off);
  end;
end;

procedure TRsmFile.CollectMainBlockLocals;

  // Mirrors ReadVleOffset in TryParseProcedureAt; kept duplicated to avoid a
  // shared nested-helper hoist while CollectMainBlockLocals is still scanning
  // the RSM independently of the procedure index.
  function ReadVleOffset(Off: Int64; out Decoded, BytesUsed: Integer): Boolean;
  var
    B1, B2: Byte;
    V8:     ShortInt;
    V16:    SmallInt;
  begin
    Result := False;
    if Off >= FDataSize then Exit;
    B1 := FData[Off];
    if (B1 and 1) = 0 then begin
      V8 := ShortInt(B1);
      if V8 >= 0 then
        Decoded := V8 shr 1
      else
        Decoded := -((-V8 + 1) shr 1);
      BytesUsed := 1;
    end else begin
      if Off + 1 >= FDataSize then Exit;
      B2  := FData[Off + 1];
      V16 := SmallInt(B1 or (B2 shl 8));
      if V16 >= 0 then
        Decoded := V16 shr 2
      else
        Decoded := -((-V16 + 3) shr 2);
      BytesUsed := 2;
    end;
    Result := True;
  end;

  function ProgramMainName: string;
  begin
    Result := '';
    if FDataSize < $40 then Exit;
    var EndOff: Int64 := $20;
    while (EndOff < $400) and (EndOff < FDataSize) and (FData[EndOff] <> 0) do
      Inc(EndOff);
    var Len := EndOff - $20;
    if Len <= 0 then Exit;
    SetString(Result, PAnsiChar(FData + $20), Len);
    Result := ChangeFileExt(ExtractFileName(Result), '');
  end;

var
  Orphans: TArray<TLocalSymbol>;
begin
  SetLength(Orphans, 0);
  var MainName := ProgramMainName;
  if MainName = '' then Exit;

  FLock.Acquire;
  try
    if FProcLocals.ContainsKey(LowerCase(MainName)) then Exit;
  finally
    FLock.Release;
  end;

  var Off: Int64 := 0;
  while Off + 9 < FDataSize do begin
    if FData[Off] = $20 then begin
      var VarNameLen := FData[Off + 1];
      if (VarNameLen >= 1) and (VarNameLen <= 63) and
         (Off + 2 + VarNameLen + 7 <= FDataSize) then begin
        var TypeRefPos := Off + 2 + VarNameLen;
        if (FData[TypeRefPos] = TYPEREF_MARKER_MAIN) and
           (FData[TypeRefPos + 1] = 0) and
           (FData[TypeRefPos + 2] = 1) then begin
          var VarName: string;
          if TryReadIdent(Off + 2, VarNameLen, VarName) then begin
            var Sym: TLocalSymbol;
            Sym.Name := VarName;
            Sym.Kind := lkLocal;
            // Record tail, measured on TestTarget (DevTools\HexDump over the
            // `$20`/`$46` records of the program main block):
            //   "Res"       46 00 01 04 | 06    | D8      6-byte tail
            //   "TheWidget" 46 00 01 04 | 01 04 | E0      7-byte tail
            // so the width really does vary with bit 0 of the byte at +4, and
            // consuming two bytes for the odd form is correct -- the offset that
            // follows lands where it should either way.
            var TypeIdByte := FData[TypeRefPos + 4];
            var OffsetPos:  Int64;
            var WideTypeId := (TypeIdByte and 1) <> 0;
            if not WideTypeId then begin
              Sym.TypeId := TypeIdByte;
              OffsetPos  := TypeRefPos + 5;
            end else begin
              Sym.TypeId := TypeIdByte or (Integer(FData[TypeRefPos + 5]) shl 8);
              OffsetPos  := TypeRefPos + 6;
            end;
            var Decoded, OffBytes: Integer;
            if ReadVleOffset(OffsetPos, Decoded, OffBytes) then begin
              Sym.RbpOffset := Decoded;
              var OUnit: string;
              var OImports: TArray<string>;
              OwningUnitContext(Off, OUnit, OImports);
              // The SINGLE-byte form indexes the user-type table by the same
              // rule as everywhere else -- `Res` carries $06, i.e. idx 2, which
              // is `Integer`, and it is right.
              //
              // The TWO-byte form does NOT, and no decoding of it does. Measured
              // on TestTarget: `TheWidget: TWidget` carries $0401 = 1025, while
              // that table holds 246 entries (max valid TypeId $01EC); `shr 1`
              // gives idx 255 (past the end) and `shr 2` gives idx 127
              // (`PVariant`). `TWidget` is not in the table at all -- its module
              // type id is $62C9 -- so the value belongs to some other space
              // that is not yet identified.
              //
              // Until it is, resolving it produces a CONFIDENTLY WRONG name:
              // LookupTypeName(1025) returned `EPrivilege` on Win32 and
              // `RunClosureParamSampler$2$Intf` on Win64 -- whatever happened to
              // sit at that index in each build. Leave the hint EMPTY instead.
              // The value still renders correctly from the runtime VMT
              // (`$28CB370 (TWidget)`), so the user loses a declared type they
              // never really had and stops being told a false one.
              if not WideTypeId then
                Sym.TypeHint := ResolveTypeIdInUnit(OUnit, OImports, Sym.TypeId)
              else
                Sym.TypeHint := '';
              // This is a byte-by-byte scan of the WHOLE file for a record
              // shape, so the same variable can match more than once -- `Cmp`
              // was listed twice in TestTarget's main block. A repeated
              // (name, slot) pair is never a second variable.
              var AlreadySeen := False;
              for var Prev in Orphans do
                if SameText(Prev.Name, Sym.Name) and
                   (Prev.RbpOffset = Sym.RbpOffset) then begin
                  AlreadySeen := True;
                  Break;
                end;
              if not AlreadySeen then
                Orphans := Orphans + [Sym];
            end;
          end;
        end;
      end;
    end;
    Inc(Off);
  end;

  if Length(Orphans) > 0 then begin
    FLock.Acquire;
    try
      FProcLocals.AddOrSetValue(LowerCase(MainName), Orphans);
    finally
      FLock.Release;
    end;
  end;
end;

procedure TRsmFile.ParseUserTypeTable;
const
  TAG_UNIT_REF         = $65;
  TAG_TYPE_REF         = $66;
  SYSTEM_PAYLOAD_BYTES = 3;
  SystemBytes: array[0..7] of Byte =
    ($65, $06, Ord('S'), Ord('y'), Ord('s'), Ord('t'), Ord('e'), Ord('m'));

  function MatchesAt(Off: Int64): Boolean;
  begin
    Result := False;
    if Off + 13 > FDataSize then Exit;
    for var I := 0 to High(SystemBytes) do
      if FData[Off + I] <> SystemBytes[I] then Exit;
    if (FData[Off + 8] <> 0) or (FData[Off + 9] <> 0) or (FData[Off + 10] <> 0) then Exit;
    if FData[Off + 11] <> $66 then Exit;
    var TypeNameLen := FData[Off + 12];
    if (TypeNameLen < 1) or (TypeNameLen > 63) then Exit;
    Result := True;
  end;

var
  Off: Int64;
  // Sanity check used by the DCP fallback: a tag-0x66 record at Off looks
  // like a type-table entry when it has a plausible identifier-ish name
  // followed by 4 trailing bytes (the standard typeref payload).
  function LooksLikeTypeRefAt(Off: Int64): Boolean;
  begin
    Result := False;
    if Off + 2 > FDataSize then Exit;
    if FData[Off] <> TAG_TYPE_REF then Exit;
    var NameLen := FData[Off + 1];
    if (NameLen < 1) or (NameLen > 63) then Exit;
    if Off + 2 + NameLen + 4 > FDataSize then Exit;
    // Names in the type table are mostly printable ASCII (incl. '@', '`',
    // '<', '>', '.' for generics and decorated symbols). Reject anything
    // with control bytes or 8-bit garbage to avoid false positives mid-code.
    for var I := 0 to NameLen - 1 do begin
      var C := FData[Off + 2 + I];
      if (C < 32) or (C >= 127) then Exit;
    end;
    Result := True;
  end;

begin
  SetLength(FUserTypes, 0);
  Off := 0;
  var Found := False;
  while Off + Length(SystemBytes) < FDataSize do begin
    // Prefilter hoisted OUT of MatchesAt (same reasoning as ScanForProcOffsets):
    // MatchesAt is a NESTED function, so it carries a hidden static link and
    // can never be inlined -- every one of the ~45 million bytes of a big .dcp
    // paid a real call that the very first compare rejected. One unaligned
    // 64-bit compare covers all 8 bytes of the `65 06 'System'` prefix at once;
    // the callee re-tests them, so behaviour and the emitted .idx are
    // unchanged. The loop guard (`Off + 8 < FDataSize`) covers the read.
    if (PUInt64(FData + Off)^ = PUInt64(@SystemBytes[0])^) and MatchesAt(Off) then begin
      Found := True;
      Break;
    end;
    Inc(Off);
  end;
  if Found then
    Inc(Off, 2 + 6 + SYSTEM_PAYLOAD_BYTES)
  else begin
    // Fallback for .dcp containers (PKX0 magic): the DCP type table is not
    // anchored by a "System" unit-ref record -- it just begins with the first
    // tag-0x66 type entry preceded by a few container/index bytes. Scan for
    // the first plausible 0x66 record and start there. The subsequent loop
    // walks the same record schema as the RSM, so once we land on the first
    // entry the rest works unchanged.
    Off := 0;
    while Off + 6 < FDataSize do begin
      // Same nested-function hoist as the System-anchor loop above.
      if (FData[Off] = TAG_TYPE_REF) and LooksLikeTypeRefAt(Off) then begin
        Found := True;
        Break;
      end;
      Inc(Off);
    end;
    if not Found then Exit;
  end;

  // Amortized append (see ExtractTypeInfoNames): a per-iteration
  // `FUserTypes := FUserTypes + [Name]` is O(n^2) on a table with many
  // entries. Collect into a TList and convert once.
  var TypeNames := TList<string>.Create;
  try
    while Off + 2 < FDataSize do begin
      var Tag := FData[Off];
      if Tag = TAG_SYM_CATEGORY then Break;
      // $6E -- type-alias declaration emitted for `type Foo = type Integer;`
      // and friends. 5-byte trailer instead of 4. DOES consume a TypeId
      // slot, named after the base type the alias points at.
      if Tag = $6E then begin
        var NL: Integer := FData[Off + 1];
        if (NL < 1) or (NL > 63) then Break;
        if Off + 2 + NL + 5 > FDataSize then Break;
        var Name: string;
        SetString(Name, PAnsiChar(FData + Off + 2), NL);
        TypeNames.Add(Name);
        Inc(Off, 2 + NL + 5);
        Continue;
      end;
      if (Tag <> TAG_TYPE_REF) and (Tag <> $67) and (Tag <> $65) and
         (Tag <> $64) and (Tag <> $68) then Break;
      var NameLen := FData[Off + 1];
      if (NameLen < 1) or (NameLen > 63) then Break;
      if Off + 2 + NameLen + 4 > FDataSize then Break;
      if Tag = TAG_TYPE_REF then begin
        var Name: string;
        SetString(Name, PAnsiChar(FData + Off + 2), NameLen);
        TypeNames.Add(Name);
      end;
      Inc(Off, 2 + NameLen + 4);
    end;
  finally
    FUserTypes := TypeNames.ToArray;
    TypeNames.Free;
  end;

  // Fallback for big-project RSMs (SampleApp-style) where the user-type
  // table is encoded as a sequence of TTypeInfo records (`$08 00 ...`
  // prefix) instead of `$66`-tag records. The two encodings are
  // mutually exclusive in practice, so we only use the TypeInfo scan
  // when the $66-based parser produced (almost) nothing. We anchor on
  // the `\05False \04True \06System` ShortString sequence that marks
  // the start of the table; without that, a free scan of the whole
  // file would pick up TypeInfo records emitted elsewhere (unit-local
  // enums etc.) and shift every TypeId index.
  if Length(FUserTypes) < 5 then begin
    var AnchorEnd: Int64;
    if FindUserTypeTableAnchor(FData, FDataSize, AnchorEnd) and
       (AnchorEnd < FDataSize) then
      FUserTypes := ExtractTypeInfoNames(FData + AnchorEnd,
                                         FDataSize - AnchorEnd);
  end;
end;

// Locates every per-unit imports area in the RSM. Each Delphi unit compiled
// into the EXE emits its own `64 06 'System' 00 00 00 66 ...` block of $66 /
// $67 records (note: tag $64, distinct from the $65 used for the EXE-global
// imports). The owning unit is identifiable from a `$70 [LEN] [Path]`
// record placed shortly before the anchor (Path = source `.pas` file name,
// e.g. `System.SysUtils.pas`). For every anchor we extract the unit name,
// walk forward to collect the ordered $66 type list, and stash everything
// in FUnitImports + FUnitAnchors. Class-member type resolution later picks
// the right per-unit list based on the class's owning unit.
procedure TRsmFile.ParsePerUnitImports;
var
  Off: Int64;

  function ExtractUnitName(AnchorOff: Int64): string;

    function IsPasOrDpr(SuffixStart: Int64): Boolean;
    begin
      Result := (FData[SuffixStart] = Ord('.')) and
                (((FData[SuffixStart + 1] = Ord('p')) or (FData[SuffixStart + 1] = Ord('P'))) and
                 ((FData[SuffixStart + 2] = Ord('a')) or (FData[SuffixStart + 2] = Ord('A'))) and
                 ((FData[SuffixStart + 3] = Ord('s')) or (FData[SuffixStart + 3] = Ord('S'))))
                or
                (((FData[SuffixStart + 1] = Ord('d')) or (FData[SuffixStart + 1] = Ord('D'))) and
                 ((FData[SuffixStart + 2] = Ord('p')) or (FData[SuffixStart + 2] = Ord('P'))) and
                 ((FData[SuffixStart + 3] = Ord('r')) or (FData[SuffixStart + 3] = Ord('R'))));
    end;

  begin
    // Backward-scan window. Path records sit a few records before the
    // `64|65 06 'System'` anchor; the worst-case distance is dominated
    // by `unit Some.Long.Namespace.Path.pas` (LEN byte max is 100 per
    // the PathLen check below, with another ~10 bytes of preamble).
    // 512 bytes gives margin for deep dotted-namespace paths.
    Result := '';
    var I: Int64 := AnchorOff - 1;
    var EndAt: Int64 := AnchorOff - 512;
    if EndAt < 0 then
      EndAt := 0;
    while I > EndAt do begin
      if FData[I] = $70 then begin
        var PathLen: Integer := FData[I + 1];
        if (PathLen >= 5) and (PathLen <= 100) and
           (I + 2 + PathLen <= AnchorOff) then begin
          var Last4Start := I + 2 + PathLen - 4;
          if IsPasOrDpr(Last4Start) then begin
            var S: AnsiString;
            SetString(S, PAnsiChar(FData + I + 2), PathLen - 4);
            Result := string(S);
            // `System.SysUtils` -> `SysUtils`; `TestTarget` -> `TestTarget`.
            // Strip any leading directory path components (Windows or POSIX
            // separators) and any `{Unit}` namespace prefix dcc64 uses on
            // class declarations.
            var SlashPos: Integer := Result.LastIndexOf('\');
            if SlashPos < 0 then
              SlashPos := Result.LastIndexOf('/');
            if SlashPos >= 0 then
              Result := Result.Substring(SlashPos + 1);
            var DotPos: Integer := Result.LastIndexOf('.');
            if DotPos >= 0 then
              Result := Result.Substring(DotPos + 1);
            Exit;
          end;
        end;
      end;
      Dec(I);
    end;
  end;

  procedure CollectImportsAt(StartOff: Int64; const UnitName: string);
  var
    TypesList: TList<string>;
    Cur: Int64;

    // A genuine $63$64 / $64 / $65 / $6E record carries an identifier name.
    // Mid-payload bytes frequently happen to equal one of those tags followed
    // by a plausible length byte; consuming such a phantom (its bogus length
    // swallows the real records that follow, e.g. a stray $64 LEN=40 eating the
    // SC_CLOSE/SC_MAXIMIZE $67 const-refs) truncated Forms' import list at 118.
    // Require a printable-identifier name before trusting the record.
    function ValidUnitName(NameOff: Int64; Len: Integer): Boolean;
    begin
      Result := False;
      if (Len < 1) or (Len > 63) or (NameOff + Len > FDataSize) then Exit;
      if not IsIdentStart(FData[NameOff]) then Exit;
      for var I := 1 to Len - 1 do
        if not IsIdentCont(FData[NameOff + I]) then Exit;
      Result := True;
    end;

    // True when P plausibly begins a known import-area record. Used to find a
    // record's true extent by validating that the following byte starts another
    // record (instead of guessing payload sizes). A named record additionally
    // requires an identifier name; this keeps the check from matching a random
    // payload byte that merely equals a tag.
    function IsImportRecordStart(P: Int64): Boolean;
    begin
      Result := False;
      if P + 2 >= FDataSize then Exit(True); // end of buffer = clean stop
      // NOTE: bare $64/$65 are intentionally NOT accepted here. This predicate
      // resolves the payload extent of $35 cluster entries and $63$64/$65
      // inner-uses records by validating the landing. Inside those regions the
      // next record always starts with $63 / $35 / a type-ref ($66/$67/$68) /
      // $6E / $9F. A 2-byte payload value such as `65 02` (followed by the next
      // entry's `63 63`) would otherwise false-match as a $65 record named "cc"
      // and desync the index (Forms stalled at idx 377 this way).
      case FData[P] of
        $66, $67, $68: Result := ValidUnitName(P + 2, FData[P + 1]);
        $6E:           Result := ValidUnitName(P + 2, FData[P + 1]);
        // A real $9F is a 5-byte record, so a genuine one is followed by
        // another valid record at P+5. Requiring that rejects a stray $9F byte
        // sitting inside another record's payload (e.g. the `9F` in a $25 enum
        // value's `8A 00 00 9F 7E ...` payload), which would otherwise
        // false-match and truncate the payload extent.
        $9F:           Result := (P + 5 <= FDataSize) and IsImportRecordStart(P + 5);
        $9C:           Result := (P + 2 < FDataSize) and (FData[P + 1] = $08);
        $37:           Result := (FData[P + 1] >= 1) and (FData[P + 1] <= 63) and
                                  (P + 2 < FDataSize) and IsIdentStart(FData[P + 2]);
        $35, $25:      Result := ValidUnitName(P + 2, FData[P + 1]);
        $63:           Result := (FData[P + 1] = $64) or (FData[P + 1] = $65) or
                                  (FData[P + 1] = $63) or (FData[P + 1] = $35) or
                                  (FData[P + 1] = $25);
      end;
    end;

    // DIAG: dump the parse-stop point for the unit owning TApplication so the
    // blocking record kind can be reverse-engineered. Logs only when DAP_LOG=1.
    procedure LogStop(const Reason: string; At: Int64; Collected: Integer);
    begin
      if not UnitName.EndsWith('Forms', True) then Exit;
      var Hex := '';
      for var I := 0 to 31 do
        if At + I < FDataSize then
          Hex := Hex + IntToHex(FData[At + I], 2) + ' ';
      DapLog(Format('IMPORTSTOP unit=%s reason=%s off=$%x imports=%d bytes: %s',
        [UnitName, Reason, At, Collected, Hex]));
    end;

  begin
    if UnitName = '' then Exit;
    // TList<string> with growth-doubling avoids the O(n^2) cost of
    // `Types := Types + [Name]` (each concat allocates a fresh array of
    // length N+1 and copies all prior entries). For hundreds of imports
    // per unit on real RSMs the saving is measurable.
    TypesList := TList<string>.Create;
    try
    Cur := StartOff;
    while Cur + 6 < FDataSize do begin
      var Tag := FData[Cur];
      // Per-unit imports area interleaves several record kinds:
      //   $66 LEN Name [4]   -- type ref (TypeId-bearing)
      //   $67 LEN Name [4]   -- function/proc/const ref
      //   $68 LEN Name [4]   -- observed (tolerated)
      //   $63 $64 LEN Name [3] -- inner uses-clause unit reference; does NOT
      //                          consume a TypeId slot.
      // Any other tag terminates the area.
      // 63 64|65 LEN Name(SubLen) + variable payload. Inner uses-clause unit
      // references (e.g. Forms references `Winapi.FlatSB`, `System.ImageList`
      // this way); neither consumes a type slot. The payload is NOT a fixed
      // size -- it is `00 00 00` (3) for some refs and `01 02 00 00` (4) for
      // others -- so resolve its extent structurally: the smallest length whose
      // end lands on a valid record start (same technique as the $35 cluster).
      // Without $63$65 the Forms import walk stopped at idx 360; with a fixed
      // 3-byte payload it then stopped at 375 on a 4-byte one.
      if (Tag = $63) and (Cur + 2 < FDataSize) and
         ((FData[Cur + 1] = $64) or (FData[Cur + 1] = $65)) and
         ValidUnitName(Cur + 3, FData[Cur + 2]) then begin
        var NameEnd: Int64 := Cur + 3 + FData[Cur + 2];
        var Found := False;
        for var PaySize := 3 to 16 do
          if (NameEnd + PaySize <= FDataSize) and
             IsImportRecordStart(NameEnd + PaySize) then begin
            Cur := NameEnd + PaySize;
            Found := True;
            Break;
          end;
        if Found then Continue;
        LogStop('inner-uses-payload', Cur, TypesList.Count);
        Break;
      end;
      // Namespaced uses-clause cluster: zero or more leading $63 bytes, then
      // `$35 LEN Name`, then a variable-length payload. These unit-refs do NOT
      // consume a type slot. The payload length is NOT guessed -- it is the
      // smallest extent whose end lands on the start of another valid record
      // (validated structurally). If no extent in the scanned window yields a
      // valid next record, the record is not understood: STOP rather than
      // desync into wrong type-refs.
      // Sub-tag $35 = a namespaced uses-clause unit reference; $25 = an enum
      // member declaration (e.g. TCloseAction's caNone/caHide/caFree carried in
      // Forms' import area). Both may carry zero or more leading $63 bytes and
      // neither consumes a type slot.
      if (Tag = $63) or (Tag = $35) or (Tag = $25) then begin
        var K: Integer := 0;
        while (Cur + K < FDataSize) and (FData[Cur + K] = $63) do
          Inc(K);
        var Sub := FData[Cur + K];
        if (Cur + K + 2 < FDataSize) and ((Sub = $35) or (Sub = $25)) and
           ValidUnitName(Cur + K + 2, FData[Cur + K + 1]) then begin
          var PayAt: Int64 := Cur + K + 2 + FData[Cur + K + 1];
          var Found := False;
          for var PaySize := 3 to 16 do
            if (PayAt + PaySize <= FDataSize) and
               IsImportRecordStart(PayAt + PaySize) then begin
              Cur := PayAt + PaySize;
              Found := True;
              Break;
            end;
          if Found then Continue;
          LogStop('cluster-payload', Cur, TypesList.Count);
          Break; // payload extent not resolvable -> stop, do not desync
        end;
      end;
      // Tolerate $64 / $65 unit-ref records interleaved in the imports area
      // (TestTarget.dpr's main-module $65 area has them between groups of
      // $66 type-refs). They consume a TypeId slot in some encodings, but
      // not for the "$66-only" indexing we mirror -- skip them at +2+NL+3.
      // A bogus name means this is a phantom match: fall through to the
      // unknown-tag resync rather than swallowing the following records.
      if ((Tag = $64) or (Tag = $65)) and
         ValidUnitName(Cur + 2, FData[Cur + 1]) and
         (Cur + 2 + FData[Cur + 1] + 3 <= FDataSize) then begin
        Inc(Cur, 2 + FData[Cur + 1] + 3);
        Continue;
      end;
      // $6E -- type-alias declaration (e.g. `type Foo = type Integer;`
      // emits `6E LEN 'Integer' <5-byte trailer>`). The record names the
      // BASE type (Integer) but DOES occupy a TypeId slot whose name we
      // store as the base type. Aliased locals' TypeIds index into this
      // slot, so without counting it every TypeId from the alias point
      // forward is off-by-N.
      if (Tag = $6E) and ValidUnitName(Cur + 2, FData[Cur + 1]) and
         (Cur + 2 + FData[Cur + 1] + 5 <= FDataSize) then begin
        var SubLen: Integer := FData[Cur + 1];
        var S: AnsiString;
        SetString(S, PAnsiChar(FData + Cur + 2), SubLen);
        TypesList.Add(string(S));
        Inc(Cur, 2 + SubLen + 5);
        Continue;
      end;
      // $9F -- 5-byte record (tag + 4-byte payload, no name). Interleaved among
      // $67 const-refs on real VCL units; does NOT consume a type slot. Without
      // handling it the walk stalled and truncated Forms' imports at 118.
      if Tag = $9F then begin
        if Cur + 5 > FDataSize then Break;
        Inc(Cur, 5);
        Continue;
      end;
      // $9C -- XML doc-comment record (e.g. `</summary>` text attached to a
      // const/type, seen on Forms' rcDefault/rcOff). Header `9C 08 ...`, UTF-8
      // text, terminated by $FF; variable length, no type slot. Scan to the
      // terminator and validate the landing (UTF-8 text never contains $FF).
      if (Tag = $9C) and (Cur + 1 < FDataSize) and (FData[Cur + 1] = $08) then begin
        var P: Int64 := Cur + 2;
        var Limit: Int64 := Cur + 8192;
        while (P < FDataSize) and (P < Limit) and (FData[P] <> $FF) do
          Inc(P);
        if (P < FDataSize) and (FData[P] = $FF) and
           IsImportRecordStart(P + 1) then begin
          Cur := P + 1;
          Continue;
        end;
        LogStop('doc-9C', Cur, TypesList.Count);
        Break;
      end;
      // $37 -- FF-terminated declaration record (e.g. compiler-generated
      // `TScrollBox.$ClassInitFlag`). `37 LEN Name <payload> FF`; the name may
      // contain '$'/'.', so it is not a ValidUnitName. No type slot. Scan to the
      // $FF terminator and validate the landing.
      if (Tag = $37) and (Cur + 2 < FDataSize) and
         (FData[Cur + 1] >= 1) and (FData[Cur + 1] <= 63) and
         IsIdentStart(FData[Cur + 2]) then begin
        var P: Int64 := Cur + 2 + FData[Cur + 1];
        var Limit: Int64 := Cur + 8192;
        while (P < FDataSize) and (P < Limit) and (FData[P] <> $FF) do
          Inc(P);
        if (P < FDataSize) and (FData[P] = $FF) and
           IsImportRecordStart(P + 1) then begin
          Cur := P + 1;
          Continue;
        end;
        LogStop('rec-37', Cur, TypesList.Count);
        Break;
      end;
      // Unknown tag: STOP. We do not skip-and-resync (that silently desyncs the
      // type-ref index and mis-types later fields). Every record kind that
      // genuinely precedes the type-refs we need has an explicit handler above;
      // anything else means we have reached an un-modeled record or the end of
      // the area, so we stop with the reliably-parsed prefix.
      if (Tag <> $66) and (Tag <> $67) and (Tag <> $68) then begin
        LogStop('unknown-tag', Cur, TypesList.Count);
        Break;
      end;
      var NameLen := FData[Cur + 1];
      if (NameLen < 1) or (NameLen > 63) then begin
        LogStop('bad-namelen', Cur, TypesList.Count);
        Break;
      end;
      if Cur + 2 + NameLen + 4 > FDataSize then Break;
      // Match ParseUserTypeTable's tolerance: advance ALL accepted records
      // by their length-prefixed extent, even when their name bytes look
      // ugly (some $67 function-imports embed non-printable chars in their
      // raw-decorated name). For the $66 type-imports we DO need an actual
      // identifier-looking string to add to the per-unit list -- silently
      // skip the slot when the name isn't printable so the TypeId index
      // stays in sync with the global imports indexing.
      var Printable := True;
      for var I := 0 to NameLen - 1 do begin
        var C := FData[Cur + 2 + I];
        if (C < $20) or (C > $7E) then begin
          Printable := False; Break;
        end;
      end;
      if Tag = $66 then begin
        var S: AnsiString := '';
        if Printable then
          SetString(S, PAnsiChar(FData + Cur + 2), NameLen);
        TypesList.Add(string(S));
      end;
      Inc(Cur, 2 + NameLen + 4);
    end;
    if TypesList.Count = 0 then Exit;
    var Types := TypesList.ToArray;
    FLock.Acquire;
    try
      var Existing: TArray<string>;
      // A real-world EXE may compile the same unit multiple times (rare) or
      // emit several anchors for the same unit's imports area. Keep the
      // longest list -- shorter ones are usually truncated by an early
      // terminating tag.
      if FUnitImports.TryGetValue(UnitName, Existing) and
         (Length(Existing) >= Length(Types)) then
        Exit;
      FUnitImports.AddOrSetValue(UnitName, Types);
      // Insert anchor in sorted-by-offset position so binary search in
      // TRsmFile_FindOwningUnit stays O(log N) without a post-pass sort.
      var Idx: Integer := 0;
      while (Idx < FUnitAnchors.Count) and (FUnitAnchors[Idx].Key < StartOff) do
        Inc(Idx);
      FUnitAnchors.Insert(Idx,
        TPair<Int64, string>.Create(StartOff, UnitName));
    finally
      FLock.Release;
    end;
    finally
      TypesList.Free;
    end;
  end;

begin
  Off := 0;
  while Off + 12 < FDataSize do begin
    // Match either `$64 06 System 00 00 00` (per-unit import area) or
    // `$65 06 System 00 00 00` (EXE-main-module import area). Both encode
    // the unit's first dependency (System) and immediately precede the
    // $66 type-refs / $67 func-refs of the owning module.
    var TagByte := FData[Off];
    var Match := ((TagByte = $64) or (TagByte = $65)) and
                 (FData[Off + 1] = $06) and
                 (FData[Off + 2] = Ord('S')) and
                 (FData[Off + 3] = Ord('y')) and
                 (FData[Off + 4] = Ord('s')) and
                 (FData[Off + 5] = Ord('t')) and
                 (FData[Off + 6] = Ord('e')) and
                 (FData[Off + 7] = Ord('m')) and
                 (FData[Off + 8] = 0) and
                 (FData[Off + 9] = 0) and
                 (FData[Off + 10] = 0);
    // Validate: the byte immediately after the anchor must look like the
    // start of a $66 / $67 / $68 / $63-$64 import record so we don't pick
    // up accidental `64 06 System 00 00 00` byte sequences that appear in
    // other contexts (e.g. inside a uses-clause cluster).
    if Match then begin
      var Next := FData[Off + 11];
      if (Next <> $66) and (Next <> $67) and (Next <> $68) and (Next <> $63) then
        Match := False;
    end;
    if Match then begin
      var UnitName := ExtractUnitName(Off);
      // The anchor IS the System unit-ref record (11 bytes: $64 $06 'System'
      // + 3 zero-payload bytes). The $66 type-refs and $67 function-refs
      // for this unit start at Off + 11.
      CollectImportsAt(Off + 11, UnitName);
      Inc(Off, 11);
    end else
      Inc(Off);
  end;
  // Keep anchors sorted by offset for binary-search lookup.
  // FUnitAnchors is already sorted: CollectImportsAt inserts in position.
end;

function TRsmFile.DiagLookupTypeName(TypeId: Integer): string;
begin
  Result := LookupTypeName(TypeId);
end;

function TRsmFile.DiagTypeIdsForName(const Substring: string): TArray<TPair<Integer, string>>;
begin
  SetLength(Result, 0);
  FLock.Acquire;   // FTypeIdToName is still being filled by the index thread
  try
    for var KV in FTypeIdToName do
      if KV.Value.ToLower.Contains(Substring.ToLower) then
        Result := Result + [TPair<Integer, string>.Create(KV.Key, KV.Value)];
  finally
    FLock.Release;
  end;
end;

function TRsmFile.DiagUnitImports(const UnitName: string): TArray<string>;
begin
  SetLength(Result, 0);
  FLock.Acquire;
  try
    FUnitImports.TryGetValue(UnitName, Result);
  finally
    FLock.Release;
  end;
end;

function TRsmFile.DiagClassHashCandidates(Hash: Word): TArray<string>;
begin
  SetLength(Result, 0);
  FLock.Acquire;
  try
    FClassHashCandidates.TryGetValue(Hash, Result);
  finally
    FLock.Release;
  end;
end;

function TRsmFile.LookupTypeName(TypeId: Integer): string;
begin
  Result := '';
  if TypeId <= 0 then Exit;
  if (TypeId and 1) = 0 then begin
    // Even typeId: index into the system/user type table
    var Idx := (TypeId div 2) - 1;
    if (Idx >= 0) and (Idx < Length(FUserTypes)) then
      Result := FUserTypes[Idx];
    Exit;
  end;
  // Odd typeId: module-local type. Try FTypeIdToName first (covers
  // user-declared types). If unresolved, fall back to the class trailer
  // hash registry -- $2C field records referencing class-typed fields
  // (e.g. Exception.FInnerException : Exception) carry the trailer hash
  // from the matching $2A class declaration, not the declaration's own
  // TypeId. Both are registered in FClassHashCandidates by the $2A
  // Variant D scanner.
  //
  // FLock is MANDATORY here: ParseTypeDeclarationSection fills both dictionaries
  // under FLock on the index thread, while this runs on the dispatch thread for
  // every local of every parsed procedure. Reading a TDictionary during another
  // thread's rehash is an access violation, not merely a wrong answer -- and it
  // is reachable today, because a caller whose WaitForIndex expired proceeds
  // straight into TryParseProcedureAt -> ResolveTypeIdInUnit -> here. FLock is a
  // Windows critical section (reentrant) and it is the reader's only lock, so
  // nesting inside another FLock scope cannot deadlock.
  FLock.Acquire;
  try
    if not FTypeIdToName.TryGetValue(TypeId, Result) then begin
      var Candidates: TArray<string>;
      if FClassHashCandidates.TryGetValue(Word(TypeId), Candidates)
         and (Length(Candidates) >= 1) then
        Result := Candidates[0];
    end;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.TryReadIdent(Off: Int64; Len: Integer; out S: string): Boolean;
begin
  Result := False;
  if (Len < 1) or (Len > 63) then Exit;
  if Off + Len > FDataSize then Exit;
  if not IsIdentStart(FData[Off]) then Exit;
  for var I := 1 to Len - 1 do
    if not IsIdentCont(FData[Off + I]) then Exit;
  SetString(S, PAnsiChar(FData + Off), Len);
  Result := True;
end;

function TRsmFile.ResolveTypeIdInUnit(const UnitName: string;
  const UnitImports: TArray<string>; ATypeId: Integer): string;
begin
  Result := '';
  if UnitName <> '' then begin
    Result := ResolveTypeNameForUnit(UnitName, ATypeId, UnitImports, FUserTypes);
    // Multi-byte typeIds carry bit0=1 (the VLE width marker); the even import
    // index is the raw value shr 1. Mirrors GetClassMembers.
    if (Result = '') and ((ATypeId and 1) = 1) then
      Result := ResolveTypeNameForUnit(UnitName, ATypeId shr 1, UnitImports, nil);
  end;
  if Result = '' then
    Result := LookupTypeName(ATypeId);
end;

procedure TRsmFile.OwningUnitContext(StartOff: Int64; out UnitName: string;
  out UnitImports: TArray<string>);
begin
  UnitName := '';
  SetLength(UnitImports, 0);
  FLock.Acquire;
  try
    UnitName := FindOwningUnit(FUnitAnchors, StartOff);
    if UnitName <> '' then
      FUnitImports.TryGetValue(UnitName, UnitImports);
  finally
    FLock.Release;
  end;
end;

function TRsmFile.TryParseProcedureAt(StartOff: Int64; out NextOff: Int64;
  out ProcName: string; out Locals: TArray<TLocalSymbol>): Boolean;

  // Reads a Delphi-style variable-length signed offset:
  //   * If the LSB of byte[0] is 0  ->  single-byte encoding,
  //     decoded value = SAR(Int8(byte[0]), 1).
  //   * If the LSB of byte[0] is 1  ->  two-byte encoding,
  //     decoded value = SAR(Int16(byte[0] | byte[1] shl 8), 2).
  //     This appears when the actual RBP offset doesn't fit in 7 signed bits
  //     after the LSB flag is reserved (e.g. Variants past the second managed
  //     local in `RunVariantTests`).
  // Returns the decoded offset and the number of bytes consumed (1 or 2).
  function ReadVleOffset(Off: Int64; out Decoded, BytesUsed: Integer): Boolean;
  var
    B1, B2: Byte;
    V8:     ShortInt;
    V16:    SmallInt;
  begin
    Result := False;
    if Off >= FDataSize then Exit;
    B1 := FData[Off];
    if (B1 and 1) = 0 then begin
      V8 := ShortInt(B1);
      if V8 >= 0 then
        Decoded := V8 shr 1
      else
        Decoded := -((-V8 + 1) shr 1);  // arithmetic right shift by 1
      BytesUsed := 1;
    end else begin
      if Off + 1 >= FDataSize then Exit;
      B2  := FData[Off + 1];
      V16 := SmallInt(B1 or (B2 shl 8));
      if V16 >= 0 then
        Decoded := V16 shr 2
      else
        Decoded := -((-V16 + 3) shr 2);  // arithmetic right shift by 2
      BytesUsed := 2;
    end;
    Result := True;
  end;

  function IsLocalVarRecord(Off: Int64; out OutSize, OutTypeId, OutOffsetByte: Integer;
    out OutDirectOffset: Boolean): Boolean;
  var
    VarName: string;
  begin
    Result := False;
    OutDirectOffset := False;
    if Off + 2 > FDataSize then Exit;
    if not IsVarKindTag(FData[Off]) then Exit;
    if (Off > 0) and (FData[Off - 1] = TAG_SYM_CATEGORY) then Exit;
    var VarNameLen := FData[Off + 1];
    if (VarNameLen < 1) or (VarNameLen > 63) then Exit;
    if Off + 2 + VarNameLen + 5 > FDataSize then Exit;
    if not TryReadIdent(Off + 2, VarNameLen, VarName) then Exit;
    var TypeRefPos := Off + 2 + VarNameLen;
    var TRM := FData[TypeRefPos];
    if ((TRM <> TYPEREF_MARKER) and (TRM <> TYPEREF_MARKER_MAIN) and
        (TRM <> TYPEREF_MARKER_CONST)) or
       (FData[TypeRefPos + 1] <> 0) then Exit;
    OutDirectOffset := False;
    var FormatFlag := FData[TypeRefPos + 2];
    var OffsetPos: Int64;
    var Decoded, OffBytes: Integer;
    if FormatFlag = 0 then begin
      OutTypeId := FData[TypeRefPos + 3];
      if (OutTypeId and 1) = 0 then begin
        // Even typeId: 1-byte TypeId at +3, offset starts at +4
        OffsetPos := TypeRefPos + 4;
      end else begin
        // Odd typeId: 2-byte TypeId at +3..+4, offset starts at +5
        if Off + 2 + VarNameLen + 6 > FDataSize then Exit;
        OutTypeId := OutTypeId or (Integer(FData[TypeRefPos + 4]) shl 8);
        OffsetPos := TypeRefPos + 5;
      end;
    end else if FormatFlag = 1 then begin
      // Inline format: TypeId at +4 (one byte if even, two if odd)
      if Off + 2 + VarNameLen + 6 > FDataSize then Exit;
      OutTypeId := FData[TypeRefPos + 4];
      if (OutTypeId and 1) = 0 then
        OffsetPos := TypeRefPos + 5
      else begin
        if Off + 2 + VarNameLen + 7 > FDataSize then Exit;
        OutTypeId := OutTypeId or (Integer(FData[TypeRefPos + 5]) shl 8);
        OffsetPos := TypeRefPos + 6;
      end;
    end else
      Exit;
    if not ReadVleOffset(OffsetPos, Decoded, OffBytes) then Exit;
    if Off + (OffsetPos - Off) + OffBytes > FDataSize then Exit;
    OutOffsetByte := Decoded;
    OutSize       := Integer(OffsetPos - Off) + OffBytes;
    Exit(True);
  end;

begin
  Result   := False;
  Locals   := nil;
  ProcName := '';

  var HeaderLen: Integer;
  if (StartOff + 3 <= FDataSize) and
     (FData[StartOff] = TAG_SYM_CATEGORY) and
     (FData[StartOff + 1] = SUBTAG_PROCEDURE) then
    HeaderLen := 3
  else if (StartOff + 2 <= FDataSize) and
          (FData[StartOff] = SUBTAG_PROCEDURE) then
    HeaderLen := 2
  else
    Exit;

  var NameLen := FData[StartOff + HeaderLen - 1];
  if NameLen = 0 then
    ProcName := ''
  else if not TryReadIdent(StartOff + HeaderLen, NameLen, ProcName) then
    Exit;

  var AfterName    := StartOff + HeaderLen + NameLen;
  var Off          := AfterName;
  var ScanEnd      := AfterName + MAX_METADATA_SCAN;
  var RecSize, TypeId, OffByte: Integer;
  var DirectOffset: Boolean;
  var LastLocalEnd := -1;

  // Owning unit + its import list, for per-unit local-type resolution below.
  var ProcUnit: string;
  var ProcUnitImports: TArray<string>;
  OwningUnitContext(StartOff, ProcUnit, ProcUnitImports);

  // Scan byte-by-byte: advance by RecSize on a valid local, by 1 on miss.
  // This handles RSM files where inter-record metadata gaps appear between
  // consecutive parameters (confirmed in TestTarget.rsm: 10-byte gap after Self).
  while (Off < ScanEnd) and (Off < FDataSize) do begin
    // Stop at the next sibling-record header ($63 TAG_SYM_CATEGORY). Without
    // this terminator, the scanner used to either give up early (when the
    // 64-byte cap was hit before all params/locals were seen) or, conversely,
    // overrun into the next procedure's metadata when the cap was raised.
    if FData[Off] = TAG_SYM_CATEGORY then
      Break;
    if IsLocalVarRecord(Off, RecSize, TypeId, OffByte, DirectOffset) then begin
      var VarNameLen := FData[Off + 1];
      var VarName: string;
      SetString(VarName, PAnsiChar(FData + Off + 2), VarNameLen);

      var Local: TLocalSymbol;
      Local.Name            := VarName;
      Local.RbpOffset       := OffByte;
      Local.TypeId          := TypeId;
      Local.UseDirectOffset := DirectOffset;
      if FData[Off] = $22 then
        Local.Kind := lkVarParam
      else
        Local.Kind := lkLocal;
      // RSM tags parameters on the record, so this reader can state the fact
      // rather than leave it unknown. `$22` is a var/reference parameter and
      // `$23` an out parameter; `$20` is a body local. Consumers rely on this
      // to tell an open-array PARAMETER (no length header, bound passed
      // separately) from a dynamic-array LOCAL, which have identical types.
      if FData[Off] in [$22, $23] then
        Local.ParamStatus := spsParameter
      else
        Local.ParamStatus := spsLocal;
      Local.TypeHint  := ResolveTypeIdInUnit(ProcUnit, ProcUnitImports, TypeId);
      // The implicit `Self` parameter always points to an instance of the
      // method's enclosing class. The RSM TypeId for Self is per-unit, so on
      // big projects (e.g. SampleAppSingleExe: many units, ~819 MB RSM) it can
      // collide with an unrelated type whose name then becomes Self's
      // TypeHint -- e.g. TfrmMainMdi.Self ended up tagged as
      // `IEnumerator<DocsCloud.Exp.Engine.TInfoErrori>` because the global
      // TypeId->Name dictionary stored that name for the same 2-byte id.
      // The qualified proc name carries the authoritative class name, so
      // use it unconditionally for Self -- LookupTypeName can never give a
      // better answer here.
      if SameText(Local.Name, 'Self') then begin
        var DotPos := ProcName.LastIndexOf('.');
        if DotPos > 0 then
          Local.TypeHint := ProcName.Substring(0, DotPos);
      end;
      Locals := Locals + [Local];

      LastLocalEnd := Off + RecSize;
      Inc(Off, RecSize);
    end else
      Inc(Off);
  end;

  // If any locals were found, advance past the last one; otherwise stay at
  // AfterName so ScanForProcOffsets does not skip nearby procedures.
  if LastLocalEnd >= 0 then
    NextOff := LastLocalEnd
  else
    NextOff := AfterName;
  Result := True;
end;

function TRsmFile.TryParseGlobalAt(StartOff: Int64; out NextOff: Int64;
  out Global: TGlobalSymbol): Boolean;

  function ReadGlobalTypeId(Off: Int64; out TypeId, BytesUsed: Integer): Boolean;
  begin
    Result := False;
    if Off >= FDataSize then Exit;
    TypeId := FData[Off];
    if (TypeId and 1) = 0 then begin
      BytesUsed := 1;
      Exit(True);
    end;
    if Off + 1 >= FDataSize then Exit;
    TypeId := TypeId or (Integer(FData[Off + 1]) shl 8);
    BytesUsed := 2;
    Exit(True);
  end;

begin
  Result := False;
  if StartOff + 3 > FDataSize then Exit;
  if (FData[StartOff] <> TAG_SYM_CATEGORY) or
     (FData[StartOff + 1] <> SUBTAG_GLOBAL_VAR) then Exit;

  var NameLen := FData[StartOff + 2];
  var Name: string;
  if not TryReadIdent(StartOff + 3, NameLen, Name) then Exit;

  var TypePos := StartOff + 3 + NameLen;
  if TypePos + 1 > FDataSize then Exit;
  var TypeTag := FData[TypePos];
  if (TypeTag <> $66) and (TypeTag <> $C6) then Exit;

  Global.Name := Name;
  Global.RVA  := 0;
  if TypeTag = $66 then begin
    if (TypePos + 7 > FDataSize) or
       (FData[TypePos + 1] <> 0) or (FData[TypePos + 2] <> 0) then Exit;
    var TypeIdBytes: Integer;
    if not ReadGlobalTypeId(TypePos + 3, Global.TypeId, TypeIdBytes) then Exit;
    if TypePos + 3 + TypeIdBytes + 3 > FDataSize then Exit;
    // A global's RSM TypeId is per-unit too -- resolve against the owning
    // unit's imports before the (colliding) global map.
    var GUnit: string;
    var GImports: TArray<string>;
    OwningUnitContext(StartOff, GUnit, GImports);
    Global.TypeHint := ResolveTypeIdInUnit(GUnit, GImports, Global.TypeId);
    if SameText(Global.Name, 'frmSplashScreen') or SameText(Global.Name, 'Globals') then
      DapLog(Format('RSM global parse "%s": unit="%s" bytes=%2.2x %2.2x %2.2x %2.2x %2.2x %2.2x typeId=$%x typeIdBytes=%d typeHint="%s"',
        [Global.Name, GUnit,
         FData[TypePos], FData[TypePos + 1], FData[TypePos + 2],
         FData[TypePos + 3], FData[TypePos + 4], FData[TypePos + 5],
         Global.TypeId, TypeIdBytes, Global.TypeHint]));
    NextOff         := TypePos + 3 + TypeIdBytes + 3;
  end else begin
    Global.TypeId   := 0;
    Global.TypeHint := '';
    NextOff         := StartOff + 3 + NameLen + 1;
  end;
  Result := True;
end;

function TRsmFile.GetLocalsForFunctionByRva(InnerRva: UInt64;
  out Locals: TArray<TLocalSymbol>): Boolean;
begin
  // RSM keys locals by procedure name only (no RVA index). RVA-keyed
  // lookups would require walking every PROC record to find one whose
  // RVA matches -- not worth the cost given MAP / TD32 supply this and
  // RSM is on the deprecation path. Stubbed to False so the adapter
  // falls back to GetLocalsForFunction (name-keyed) on this provider.
  Result := False;
  SetLength(Locals, 0);
end;

procedure TRsmFile.EnsureCollisionSet;
begin
  if FCollisionReady then Exit;
  FLock.Acquire;
  try
    if FCollisionReady then Exit;  // double-checked under the lock
    FCollidingProcNames.Clear;
    if FData <> nil then begin
      // name (lowercase) -> the FIRST owning unit seen. A second, DIFFERENT
      // owning unit for the same name marks it as cross-unit colliding.
      var NameToUnit := TDictionary<string, string>.Create;
      try
        var Off: Int64 := 0;
        while Off + 4 < FDataSize do begin
          var HdrLen := 0;
          if (FData[Off] = TAG_SYM_CATEGORY) and (FData[Off + 1] = SUBTAG_PROCEDURE) then
            HdrLen := 3
          else if (FData[Off] = SUBTAG_PROCEDURE) and
                  ((Off = 0) or (FData[Off - 1] <> TAG_SYM_CATEGORY)) then
            HdrLen := 2;
          if HdrLen > 0 then begin
            var NameLen := FData[Off + HdrLen - 1];
            var PName: string;
            if (NameLen >= 1) and (NameLen <= 63) and
               TryReadIdent(Off + HdrLen, NameLen, PName) then begin
              var Key := LowerCase(PName);
              var ThisUnit := FindOwningUnit(FUnitAnchors, Off);
              var PrevUnit: string;
              if NameToUnit.TryGetValue(Key, PrevUnit) then begin
                if not SameText(PrevUnit, ThisUnit) then
                  FCollidingProcNames.AddOrSetValue(Key, True);
              end
              else
                NameToUnit.Add(Key, ThisUnit);
              Off := SkipProcBody(FData, FDataSize, Off + HdrLen + NameLen);
              Continue;
            end;
          end;
          Inc(Off);
        end;
      finally
        NameToUnit.Free;
      end;
    end;
    FCollisionReady := True;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.NameCollidesAcrossUnits(const FunctionName: string): Boolean;
begin
  Result := False;
  if FunctionName = '' then Exit;
  WaitForIndex;
  EnsureCollisionSet;
  FLock.Acquire;
  try
    Result := FCollidingProcNames.ContainsKey(LowerCase(FunctionName));
  finally
    FLock.Release;
  end;
end;

procedure TRsmFile.EnsureUnitUsesParsed;

  function NameAt(Off: Int64; Len: Integer; out Nm: string): Boolean;
  begin
    Nm := '';
    if (Len <= 0) or (Off + Len > FDataSize) then Exit(False);
    for var k := 0 to Len - 1 do begin
      var b := FData[Off + k];
      if (b < 32) or (b > 126) then Exit(False);  // not a clean identifier
    end;
    SetString(Nm, PAnsiChar(FData + Off), Len);
    Result := True;
  end;

begin
  if FUnitUsesParsed then Exit;
  FLock.Acquire;
  try
    if FUnitUsesParsed then Exit;
    if FData <> nil then begin
      // Walk every `63 35 LEN <name>` record. Records are grouped into clusters
      // by proximity: a gap > 256 bytes from the previous record starts a new
      // cluster, whose FIRST name is the owning unit and the rest its uses.
      var i: Int64 := 0;
      var Owner := '';
      var UsesList: TArray<string>;
      var PrevEnd: Int64 := -1000;
      while i < FDataSize - 3 do begin
        if (FData[i] = $63) and (FData[i + 1] = $35) then begin
          var Len := FData[i + 2];
          var Nm: string;
          if NameAt(i + 3, Len, Nm) then begin
            var LName := LowerCase(Nm);
            if i - PrevEnd > 256 then begin
              if Owner <> '' then
                FUnitUses.AddOrSetValue(Owner, UsesList);
              Owner    := LName;   // first name of a new cluster = owner unit
              UsesList := nil;
            end
            else
              UsesList := UsesList + [LName];  // a used unit
            PrevEnd := i + 3 + Len;
            Inc(i, 3 + Len);
            Continue;
          end;
        end;
        Inc(i);
      end;
      if Owner <> '' then
        FUnitUses.AddOrSetValue(Owner, UsesList);
    end;
    FUnitUsesParsed := True;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.GetUnitUses(const UnitName: string; out AUses: TArray<string>): Boolean;
begin
  AUses := nil;
  Result := False;
  if UnitName = '' then Exit;
  EnsureUnitUsesParsed;
  FLock.Acquire;
  try
    Result := FUnitUses.TryGetValue(LowerCase(UnitName), AUses);
  finally
    FLock.Release;
  end;
end;

// Walks every `$25` named-constant record and attributes it to the unit whose
// `63 35` cluster most recently opened (records are grouped by unit; a cluster
// starts a unit's block -- same gap>256 heuristic as EnsureUnitUsesParsed).
//
// $25 record layout (reverse-engineered, see RSM_FIELD_OFFSETS.md):
//   25 [LEN] [NAME ANSI] | 8A 00 00 (marker) | [4-byte name hash] |
//   [type-id byte] 00 00 | [value leaf]
// Value leaf: bit0=0 -> single-byte ordinal, value = leaf>>1 (covers the common
// `const X = <small int>`). Escape leaf 0x0F -> a 4-byte little-endian Int32.
// Other leaves (strings/floats/wide ints) are not decoded yet and the constant
// is skipped (resolution then reports it as not found rather than wrong).
procedure TRsmFile.EnsureUnitConstsParsed;

  function NameAt(Off: Int64; Len: Integer; out Nm: string): Boolean;
  begin
    Nm := '';
    if (Len < 2) or (Len > 40) or (Off + Len > FDataSize) then Exit(False);
    for var k := 0 to Len - 1 do begin
      var b := FData[Off + k];
      if (b < 32) or (b > 126) then Exit(False);
    end;
    SetString(Nm, PAnsiChar(FData + Off), Len);
    Result := True;
  end;

  function TypeHintForId(Id: Byte): string;
  begin
    case Id of
      $02: Result := 'Boolean';
      $0C: Result := 'Integer';
    else
      Result := 'Integer';
    end;
  end;

  // Decodes the value leaf at Off. Returns False for leaves we cannot decode.
  function DecodeLeaf(Off: Int64; out Value: Int64): Boolean;
  begin
    Value := 0;
    if Off >= FDataSize then Exit(False);
    var B0 := FData[Off];
    if (B0 and 1) = 0 then begin
      Value := B0 shr 1;          // single-byte ordinal
      Exit(True);
    end;
    if (B0 = $0F) and (Off + 4 < FDataSize) then begin
      Value := Int64(Integer(FData[Off + 1] or (FData[Off + 2] shl 8) or
                             (FData[Off + 3] shl 16) or (FData[Off + 4] shl 24)));
      Exit(True);
    end;
    Result := False;
  end;

begin
  if FUnitConstsParsed then Exit;
  FLock.Acquire;
  try
    if FUnitConstsParsed then Exit;
    if FData <> nil then begin
      var i: Int64 := 0;
      var Owner := '';
      var PrevClusterEnd: Int64 := -1000;
      while i < FDataSize - 4 do begin
        // Track the current unit via `63 35` cluster starts (gap>256).
        if (FData[i] = $63) and (FData[i + 1] = $35) then begin
          var Len := FData[i + 2];
          var Nm: string;
          if NameAt(i + 3, Len, Nm) then begin
            if i - PrevClusterEnd > 256 then
              Owner := LowerCase(Nm);   // first name of a new cluster = owner unit
            PrevClusterEnd := i + 3 + Len;
            Inc(i, 3 + Len);
            Continue;
          end;
        end;
        // Named constant record.
        if FData[i] = $25 then begin
          var Len := FData[i + 1];
          var Nm: string;
          if NameAt(i + 2, Len, Nm) then begin
            var After := i + 2 + Len;
            // Validate the `8A 00 00` constant marker -- filters false $25 bytes.
            if (After + 10 < FDataSize) and (FData[After] = $8A) and
               (FData[After + 1] = 0) and (FData[After + 2] = 0) then begin
              var TypeId := FData[After + 7];        // after marker(3) + hash(4)
              var Value: Int64;
              if DecodeLeaf(After + 10, Value) then begin   // marker(3)+hash(4)+id(1)+00 00(2)
                var LName := LowerCase(Nm);
                var TH := TypeHintForId(TypeId);
                if Owner <> '' then begin
                  var UKey := Owner + '|' + LName;
                  if not FUnitConsts.ContainsKey(UKey) then begin
                    FUnitConsts.Add(UKey, Value);
                    FUnitConstTypes.Add(UKey, TH);
                  end;
                end;
                if not FConstByName.ContainsKey(LName) then begin
                  FConstByName.Add(LName, Value);
                  FConstTypeByName.Add(LName, TH);
                end;
              end;
            end;
          end;
        end;
        Inc(i);
      end;
    end;
    FUnitConstsParsed := True;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.FindConstInUnit(const Name, UnitHint: string;
  out Value: Int64; out TypeHint: string): Boolean;
begin
  Value := 0;
  TypeHint := '';
  Result := False;
  if Name = '' then Exit;
  EnsureUnitConstsParsed;
  FLock.Acquire;
  try
    if UnitHint <> '' then begin
      var UKey := LowerCase(UnitHint) + '|' + LowerCase(Name);
      if FUnitConsts.TryGetValue(UKey, Value) then begin
        FUnitConstTypes.TryGetValue(UKey, TypeHint);
        Exit(True);
      end;
      Exit(False);
    end;
    if FConstByName.TryGetValue(LowerCase(Name), Value) then begin
      FConstTypeByName.TryGetValue(LowerCase(Name), TypeHint);
      Exit(True);
    end;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.GetLocalsForFunctionInUnit(const FunctionName, UnitHint: string;
  out Locals: TArray<TLocalSymbol>): Boolean;
begin
  Result := False;
  SetLength(Locals, 0);
  if (FunctionName = '') or (UnitHint = '') then Exit;
  WaitForIndex;

  // Find UnitHint's section [SectStart, SectEnd) via the unit anchors (sorted
  // by offset). UnitHint is the frame's source-unit basename; anchors carry the
  // RSM unit name -- match case-insensitively.
  var SectStart: Int64 := -1;
  var SectEnd:   Int64 := FDataSize;
  FLock.Acquire;
  try
    for var I := 0 to FUnitAnchors.Count - 1 do
      if SameText(FUnitAnchors[I].Value, UnitHint) then begin
        SectStart := FUnitAnchors[I].Key;
        if I + 1 < FUnitAnchors.Count then
          SectEnd := FUnitAnchors[I + 1].Key;
        Break;
      end;
  finally
    FLock.Release;
  end;
  if SectStart < 0 then Exit;

  // Scan only that unit's section for a proc header (`63 28 len name` or a bare
  // `28 len name`) whose name matches, then parse it. This resolves the
  // collision the name-keyed FProcOffsets (last-wins) cannot.
  var Off := SectStart;
  while (Off + 3 < SectEnd) and (Off + 3 < FDataSize) do begin
    var HdrLen := 0;
    if (FData[Off] = TAG_SYM_CATEGORY) and (FData[Off + 1] = SUBTAG_PROCEDURE) then
      HdrLen := 3
    else if (FData[Off] = SUBTAG_PROCEDURE) and
            ((Off = 0) or (FData[Off - 1] <> TAG_SYM_CATEGORY)) then
      HdrLen := 2;
    if HdrLen > 0 then begin
      var NameLen := FData[Off + HdrLen - 1];
      var PName: string;
      if (NameLen >= 1) and (NameLen <= 63) and
         TryReadIdent(Off + HdrLen, NameLen, PName) and
         SameText(PName, FunctionName) then begin
        var NextOff: Int64;
        var ProcName: string;
        if TryParseProcedureAt(Off, NextOff, ProcName, Locals) then
          Exit(True);
      end;
    end;
    Inc(Off);
  end;
end;

function TRsmFile.GetLocalsForFunction(const FunctionName: string;
  out Locals: TArray<TLocalSymbol>): Boolean;
var
  CacheKey: string;
  ProcOffset: Int64;
  ProcName: string;
  NextOff: Int64;
begin
  CacheKey := LowerCase(FunctionName);

  // Fast path: already parsed and cached against a COMPLETE index.
  FLock.Acquire;
  try
    if FProcLocals.TryGetValue(CacheKey, Locals) then
      Exit(True);
    // Provisional hit: a best-effort answer already computed while the index was
    // still building. Serving it avoids paying the whole wait-and-reparse again
    // for every repeat of the same lookup (a single `variables` request expands
    // many children and would otherwise burn the interactive budget on each one).
    // It is discarded, not promoted, once the index completes.
    if (not FIndexReady) and FProvisionalLocals.TryGetValue(CacheKey, Locals) then
      Exit(Length(Locals) > 0);
  finally
    FLock.Release;
  end;

  // Wait for background index to complete. IndexReady = False means the wait gave
  // up (interactive budget / per-call cap) and everything below is parsed against
  // a HALF-BUILT index: FTypeIdToName / FUnitImports are still filling, so type
  // hints come out blank or wrong. That answer is still worth returning as a
  // best effort, but it must NOT be pinned in FProcLocals -- pinning it makes a
  // transient shortage permanent for the rest of the session (and, once the
  // sidecar is written, potentially across sessions). Same precedent as
  // TWinDebugger.GetStackFrames refusing to pin an incomplete stack walk.
  var IndexReady := WaitForIndex;

  // Re-check cache: the background index may have populated this entry
  // (e.g. via sidecar load or CollectMainBlockLocals) while we were waiting.
  // Without this, the anon-proc fallback below would overwrite correct
  // main-block-local data with the wrong $46-record decoding.
  FLock.Acquire;
  try
    if FProcLocals.TryGetValue(CacheKey, Locals) then
      Exit(True);
  finally
    FLock.Release;
  end;

  // Find offset in proc index.
  FLock.Acquire;
  try
    if not FProcOffsets.TryGetValue(CacheKey, ProcOffset) then begin
      Locals := nil;
      Exit(False);
    end;
  finally
    FLock.Release;
  end;

  // Parse this procedure's locals from the mmap'd data.
  if not TryParseProcedureAt(ProcOffset, NextOff, ProcName, Locals) then begin
    Locals := nil;
    Exit(False);
  end;

  // If no locals found, look for an anonymous proc record ($28 $00) immediately
  // before this one. Delphi DPR main bodies emit locals in a nameless proc
  // header that precedes the named module record.
  if Length(Locals) = 0 then begin
    var SearchEnd := Max(0, ProcOffset - 2);
    var SearchStart := Max(0, ProcOffset - 256);
    var AnonOff := SearchEnd;
    while AnonOff >= SearchStart do begin
      if (FData[AnonOff] = SUBTAG_PROCEDURE) and (FData[AnonOff + 1] = 0) and
         ((AnonOff = 0) or (FData[AnonOff - 1] <> TAG_SYM_CATEGORY)) then begin
        var AnonName: string;
        var AnonLocals: TArray<TLocalSymbol>;
        var AnonNextOff: Int64;
        if TryParseProcedureAt(AnonOff, AnonNextOff, AnonName, AnonLocals) then
          Locals := AnonLocals;
        Break;
      end;
      Dec(AnonOff);
    end;
  end;

  // Cache the result. A result computed against a COMPLETE index is pinned; one
  // computed against a still-building index goes to the provisional cache, which
  // is dropped wholesale as soon as the index is ready so the next lookup
  // re-derives it properly.
  FLock.Acquire;
  try
    if IndexReady then begin
      FProcLocals.AddOrSetValue(CacheKey, Locals);
      if FProvisionalLocals.Count > 0 then
        FProvisionalLocals.Clear;
    end else
      FProvisionalLocals.AddOrSetValue(CacheKey, Locals);
  finally
    FLock.Release;
  end;

  Result := Length(Locals) > 0;
end;

function TRsmFile.GetGlobals: TArray<TGlobalSymbol>;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    Result := FGlobals.ToArray;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.FindGlobal(const Name: string; out Global: TGlobalSymbol): Boolean;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    Result := False;
    for var G in FGlobals do
      if SameText(G.Name, Name) then begin
        Global := G;
        Exit(True);
      end;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.DiagModuleTypeIds: TArray<TPair<Integer, string>>;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    SetLength(Result, 0);
    for var Pair in FTypeIdToName do
      Result := Result + [TPair<Integer, string>.Create(Pair.Key, Pair.Value)];
  finally
    FLock.Release;
  end;
end;

function TRsmFile.DiagUnitImportSummary: TArray<string>;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    SetLength(Result, 0);
    for var Pair in FUnitImports do
      Result := Result + [Format('%s = %d entries', [Pair.Key, Length(Pair.Value)])];
  finally
    FLock.Release;
  end;
end;

function TRsmFile.AllProcedureNames: TArray<string>;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    Result := FProcOffsets.Keys.ToArray;
  finally
    FLock.Release;
  end;
end;

// Scans for $2A type-declaration records that map odd module-local typeIds to
// type names. Format per record: $2A [nameLen] [name] [3 filler] [typeId_lo] [typeId_hi] [00].
procedure TRsmFile.ParseTypeDeclarationSection;
var
  Off: Int64;
begin
  Off := 0;
  while Off + 9 < FDataSize do begin
    if FData[Off] <> $2A then begin
      Inc(Off);
      Continue;
    end;
    var NameLen := Integer(FData[Off + 1]);
    if (NameLen < 1) or (NameLen > 127) then begin
      Inc(Off);
      Continue;
    end;
    if Off + 2 + NameLen + 5 >= FDataSize then begin
      Inc(Off);
      Continue;
    end;
    var FirstChar := FData[Off + 2];
    if not (((FirstChar >= Ord('A')) and (FirstChar <= Ord('Z'))) or
            ((FirstChar >= Ord('a')) and (FirstChar <= Ord('z'))) or
            (FirstChar = Ord('_')) or (FirstChar = Ord('{'))) then begin
      Inc(Off);
      Continue;
    end;
    // All name bytes must be printable ASCII (allows <, >, {, }, ., etc.)
    var AllValid := True;
    for var I := 1 to NameLen - 1 do begin
      var C := FData[Off + 2 + I];
      if (C < $20) or (C > $7E) then begin
        AllValid := False;
        Break;
      end;
    end;
    if not AllValid then begin
      Inc(Off);
      Continue;
    end;
    // Variant classification by (filler byte, suffix-flag byte at +N+7,
    // terminator byte at +N+5). Each row produces (Recognised, IsVarD-ness,
    // Advance distance from Off).
    //   Variant A (simple types):       filler=$20, +N+7=$1E. Advance N+10.
    //   Variant B (generic insts):      +N+5=$00.            Advance N+8.
    //   Variant C (classes $M+):        filler=$20, +N+7=$1F. Advance N+10.
    //   Variant D (large VCL classes):  filler=$A8.          Variable trailer; conservative N+7.
    //   Variant E (generic classes):    filler in {$20,$40}, +N+5<>$00, +N+7 not $1E/$1F. Advance N+10.
    //   Variant F (type-alias):         filler=$18.          Variable trailer; conservative N+7.
    //
    // Detection priority: B -> A -> C -> D -> E -> F. Variant B's `+N+5=$00`
    // is the most specific signature so it wins; otherwise we pick on
    // filler[0] / +N+7 alone.
    var Filler: Byte := FData[Off + 2 + NameLen];
    var Filler1: Byte := FData[Off + 2 + NameLen + 1];
    var Filler2: Byte := FData[Off + 2 + NameLen + 2];
    var Marker5: Byte := FData[Off + 2 + NameLen + 5];
    var Marker7: Byte := FData[Off + 2 + NameLen + 7];
    var IsVarA, IsVarB, IsVarC, IsVarD, IsVarE, IsVarF: Boolean;
    IsVarB := Marker5 = $00;
    IsVarA := (not IsVarB) and (Marker7 = VARIANT_A_SUFFIX);
    IsVarC := (not IsVarB) and (not IsVarA) and (Marker7 = VARIANT_C_SUFFIX);
    var FillerZeroTail: Boolean := (Filler1 = 0) and (Filler2 = 0);
    IsVarD := (not IsVarB) and (not IsVarA) and (not IsVarC) and
              (Filler = VARIANT_D_FILLER) and FillerZeroTail;
    IsVarE := (not IsVarB) and (not IsVarA) and (not IsVarC) and (not IsVarD) and
              ((Filler = VARIANT_E_FILLER_1) or (Filler = VARIANT_E_FILLER_2)) and
              FillerZeroTail;
    IsVarF := (not IsVarB) and (not IsVarA) and (not IsVarC) and (not IsVarD) and
              (not IsVarE) and
              (Filler = VARIANT_F_FILLER) and FillerZeroTail;
    if not (IsVarA or IsVarB or IsVarC or IsVarD or IsVarE or IsVarF) then begin
      Inc(Off);
      Continue;
    end;
    var TypeIdLo := Integer(FData[Off + 2 + NameLen + 3]);
    var TypeIdHi := Integer(FData[Off + 2 + NameLen + 4]);
    var TypeId   := TypeIdLo or (TypeIdHi shl 8);
    if TypeId > 0 then begin
      var RawName: string;
      SetString(RawName, PAnsiChar(FData + Off + 2), NameLen);
      // Strip leading {Unit} prefix (e.g. '{TestTarget}TWorkMode' -> 'TWorkMode')
      var TypeName := RawName;
      var BraceEnd := Pos('}', TypeName);
      if BraceEnd > 0 then
        TypeName := Copy(TypeName, BraceEnd + 1, MaxInt);
      if TypeName <> '' then begin
        FLock.Acquire;
        try
          FTypeIdToName.AddOrSetValue(TypeId, TypeName);
          // Index the class declaration offset for lazy member decode
          // (DecodeClassMembers uses this to look up the owning unit via
          // FUnitAnchors).
          if not FClassDeclarationOffsets.ContainsKey(LowerCase(TypeName)) then
            FClassDeclarationOffsets.AddOrSetValue(LowerCase(TypeName), Off);
          // Standard variants tag their member ($2C/$2E/$31) records with the
          // low 16 bits of the class's TypeId. Register that mapping so
          // DecodeClassMembers can find the member records by class name.
          var NameKey := LowerCase(TypeName);
          var Hashes: TArray<Word>;
          FClassNameToHash.TryGetValue(NameKey, Hashes);
          var StdHash := Word(TypeId and $FFFF);
          var Present := False;
          for var H in Hashes do
            if H = StdHash then begin Present := True; Break; end;
          if not Present then begin
            Hashes := Hashes + [StdHash];
            FClassNameToHash.AddOrSetValue(NameKey, Hashes);
          end;
        finally
          FLock.Release;
        end;
        // Variant D class records carry a second 16-bit id at trailer
        // offsets [7][8] (Word LE). This is the value used as the "class
        // hash" by per-class member ($2C/$2E/$31) records AND as the
        // TypeId of the implicit Self parameter in methods. Register it
        // too so class-member lookup and Self-typing can find the class
        // by either id.
        if IsVarD then begin
          var Trailer  := Off + 2 + NameLen;
          var ClassHash := Word(Integer(FData[Trailer + 7]) or
                                (Integer(FData[Trailer + 8]) shl 8));
          if ClassHash > 0 then begin
            FLock.Acquire;
            try
              var Candidates: TArray<string>;
              FClassHashCandidates.TryGetValue(ClassHash, Candidates);
              var Already := False;
              for var C in Candidates do
                if SameText(C, TypeName) then begin
                  Already := True;
                  Break;
                end;
              if not Already then begin
                Candidates := Candidates + [TypeName];
                FClassHashCandidates.AddOrSetValue(ClassHash, Candidates);
              end;
              // Reverse mapping for DecodeClassMembers.
              var NameKey := LowerCase(TypeName);
              var Hashes: TArray<Word>;
              FClassNameToHash.TryGetValue(NameKey, Hashes);
              var Present := False;
              for var H in Hashes do
                if H = ClassHash then begin Present := True; Break; end;
              if not Present then begin
                Hashes := Hashes + [ClassHash];
                FClassNameToHash.AddOrSetValue(NameKey, Hashes);
              end;
              // The member ($2C/$2E/$31) records of a Variant-D class bind by a
              // 1-byte class hash when the low byte is an even VLE (`...$08 lo
              // $FF`), NOT the 2-byte ClassHash above. Seen on unit-section
              // classes (TWideFields/TBareClass/TWidget after relocation). Also
              // register that 1-byte form so DecodeClassMembers -- which keys
              // member offsets by each record's own decoded hash -- finds them.
              var LoByte := Word(FData[Trailer + 7]);
              if ((LoByte and 1) = 0) and (LoByte <> 0) and (LoByte <> ClassHash) then begin
                var LoCand: TArray<string>;
                FClassHashCandidates.TryGetValue(LoByte, LoCand);
                var LoAlready := False;
                for var C in LoCand do
                  if SameText(C, TypeName) then begin LoAlready := True; Break; end;
                if not LoAlready then begin
                  LoCand := LoCand + [TypeName];
                  FClassHashCandidates.AddOrSetValue(LoByte, LoCand);
                end;
                var HasLo := False;
                for var H in Hashes do
                  if H = LoByte then begin HasLo := True; Break; end;
                if not HasLo then begin
                  Hashes := Hashes + [LoByte];
                  FClassNameToHash.AddOrSetValue(NameKey, Hashes);
                end;
              end;
            finally
              FLock.Release;
            end;
          end;
        end;
      end;
    end;
    if IsVarA then
      Inc(Off, 2 + NameLen + 8)
    else if IsVarC then
      Inc(Off, 2 + NameLen + 8)
    else if IsVarE then
      // Same length as A/C: filler(3) + TypeId(2) + 3-byte trailer.
      Inc(Off, 2 + NameLen + 8)
    else if IsVarF then
      // Type-alias declaration. Trailer length variable; advance past
      // filler+TypeId only and let the outer scan resync at the next
      // record start.
      Inc(Off, 2 + NameLen + 5)
    else if IsVarD then
      // Past filler(3) + TypeId(2) only -- the trailer of variant D records
      // is variable length; rely on the byte-by-byte miss path in the outer
      // loop to re-sync at the next record start.
      Inc(Off, 2 + NameLen + 5)
    else
      Inc(Off, 2 + NameLen + 6);
  end;
end;

// Scans for embedded Delphi TypeInfo records in the RSM. Each record starts
// with an 8-byte prefix [08 00 00 00 00 00 00 00], followed by Kind, ShortString
// name, and type-specific data (see Delphi TypInfo for layout).
procedure TRsmFile.ParseTypeInfoSection;
var
  Off:    Int64;
  I:      Integer;
begin
  Off := 0;
  while Off + 12 < FDataSize do begin
    // One unaligned 64-bit compare instead of a chain of eight byte compares.
    // On .dcp input the byte $08 is common, so the chain was entered
    // constantly and executed several compares per byte; the single load is
    // 29% faster on cxLibraryRS29.dcp, 20% on a 17 MB .rsm. x64 little-endian
    // only, which this project already assumes throughout. The loop guard
    // (`Off + 12 < FDataSize`) already covers the 8-byte read.
    if PUInt64(FData + Off)^ <> UInt64($0000000000000008) then begin
      Inc(Off);
      Continue;
    end;
    var Kind    := Integer(FData[Off + 8]);
    var NameLen := Integer(FData[Off + 9]);
    // Delphi TTypeKind: 1=tkInteger ... 22=tkMRecord (Athens 36). Reject
    // anything outside this band, but accept every valid kind -- we
    // need the TKind data to drive class/record decoration decisions
    // for non-enum types too (e.g. `type T = type Integer` is tkInteger,
    // not tkClass, even though the name capitalisation looks classy).
    if (Kind < 1) or (Kind > 22) or (NameLen < 1) or (NameLen > 63) then begin
      Inc(Off);
      Continue;
    end;
    if Off + 10 + NameLen > FDataSize then begin
      Inc(Off);
      Continue;
    end;
    if not IsIdentStart(FData[Off + 10]) then begin
      Inc(Off);
      Continue;
    end;
    var TypeName: string;
    SetString(TypeName, PAnsiChar(FData + Off + 10), NameLen);
    FTypeKindByName.AddOrSetValue(TypeName, Byte(Kind));
    if (Kind <> 3) and (Kind <> 6) then begin
      // Other kinds carry kind-specific TypeData we don't fully decode;
      // advance one byte and let the outer scan re-sync at the next
      // `$08 00 ...` prefix.
      Inc(Off);
      Continue;
    end;
    var DataOff := Off + 10 + NameLen;

    if Kind = 3 then begin // tkEnumeration
      // OrdType(1) + MinValue(4) + MaxValue(4) + BaseType(8) = 17 bytes before NameList
      if DataOff + 17 > FDataSize then begin
        Inc(Off);
        Continue;
      end;
      var Info: TRsmEnumInfo;
      Info := Default(TRsmEnumInfo);
      Info.Kind     := 3;
      Info.MinValue := Integer(FData[DataOff + 1]) or (Integer(FData[DataOff + 2]) shl 8) or
                       (Integer(FData[DataOff + 3]) shl 16) or (Integer(FData[DataOff + 4]) shl 24);
      Info.MaxValue := Integer(FData[DataOff + 5]) or (Integer(FData[DataOff + 6]) shl 8) or
                       (Integer(FData[DataOff + 7]) shl 16) or (Integer(FData[DataOff + 8]) shl 24);
      var NameCount := Int64(Info.MaxValue) - Int64(Info.MinValue) + 1;
      if (NameCount > 0) and (NameCount <= 256) then begin
        var NC := Integer(NameCount);
        SetLength(Info.Names, NC);
        var NamesOff := DataOff + 17; // skip OrdType+MinValue+MaxValue+BaseType
        var Ok := True;
        for I := 0 to NC - 1 do begin
          if NamesOff >= FDataSize then begin Ok := False; Break; end;
          var NLen := Integer(FData[NamesOff]);
          Inc(NamesOff);
          if (NLen = 0) or (NLen > 63) or (NamesOff + NLen > FDataSize) then begin
            Ok := False;
            Break;
          end;
          SetString(Info.Names[I], PAnsiChar(FData + NamesOff), NLen);
          Inc(NamesOff, NLen);
        end;
        if Ok then begin
          Info.IsValid := True;
          FEnumInfoByName.AddOrSetValue(TypeName, Info);
        end;
      end;
      Inc(Off, 10 + NameLen);
    end else if Kind = 6 then begin // tkSet
      if DataOff + 9 > FDataSize then begin
        Inc(Off);
        Continue;
      end;
      var Info: TRsmEnumInfo;
      Info := Default(TRsmEnumInfo);
      Info.Kind    := 6;
      Info.IsValid := True;
      FEnumInfoByName.AddOrSetValue(TypeName, Info);
      Inc(Off, 10 + NameLen);
    end else
      Inc(Off);
  end;
end;

// Scans for class-member records ($2C field, $2E method, $31 property).
// Each record ends with `... 08 <classHash> FF`. classHash is a 1- or 2-byte
// value (no VLE here -- just raw little-endian; the same value also appears
// in the corresponding `$2A` class declaration, captured in FTypeIdToName).
//
// Member records sit consecutively and back-to-back. We scan the whole file
// for `<MemberTag> <NameLen> <Name>` candidates and validate by demanding
// the byte immediately preceding be `FF` (a previous record's terminator)
// or one of a small set of plausible context starters. Then walk forward
// to the record's own `FF`, decode the trailing class hash, group by class.
//
// Per-record decoding (after `tag NL Name`):
//   $2C  field    flags(1) vis(1) reserved(1) typeIdByte(1) offsetByte(1)
//                 9C 09 hash16 ...
//   $2E  method   flags(1) vis(1) reserved(1) E2 bodyHash16 ...
//   $31  property flags(1) vis(1) reserved(1) typeIdByte(1) FE 0F 00 00 00
//                 80 getterHash16 ...
// Cheap first walk: just collect every $2C / $2E / $31 record's offset
// indexed by its 16-bit class hash. No per-member decoding -- that lives in
// DecodeClassMembers and runs only when a class is actually inspected.
procedure TRsmFile.IndexClassMemberRecords;
var
  Local: TDictionary<Word, TArray<Int64>>;
begin
  Local := TDictionary<Word, TArray<Int64>>.Create;
  try
    var Off: Int64 := 0;
    while Off + 16 < FDataSize do begin
      if not ClassMember_IsMemberTag(FData[Off]) then begin
        Inc(Off); Continue;
      end;
      var NameLen := Integer(FData[Off + 1]);
      if (NameLen < 1) or (NameLen > 63) or (Off + 2 + NameLen >= FDataSize) or
         not IsIdentStart(FData[Off + 2]) then begin
        Inc(Off); Continue;
      end;
      // Validate ALL name bytes look like an identifier. Random binary
      // sequences inside a class section often happen to start with one of
      // the member tags ($2C / $2E / $31) followed by a sane NameLen byte
      // and a letter; without checking the rest of the "name" they would
      // produce a 60+ byte phantom record that swallows the real members
      // sitting inside its claimed extent.
      var NameOK := True;
      for var I := 1 to NameLen - 1 do
        if not IsIdentCont(FData[Off + 2 + I]) then begin
          NameOK := False; Break;
        end;
      if not NameOK then begin
        Inc(Off); Continue;
      end;
      var RecLen: Integer;
      if not ClassMember_FindRecordEnd(FData, FDataSize, Off, RecLen) then begin
        Inc(Off); Continue;
      end;
      var Hash: Word;
      if not TRsmFile.DecodeClassMemberHash(FData, Off, RecLen, Hash) then begin
        Inc(Off); Continue;
      end;
      var Arr: TArray<Int64>;
      Local.TryGetValue(Hash, Arr);
      Arr := Arr + [Off];
      Local.AddOrSetValue(Hash, Arr);
      Inc(Off, RecLen);
    end;
    FLock.Acquire;
    try
      for var Pair in Local do
        FClassMemberOffsets.AddOrSetValue(Pair.Key, Pair.Value);
    finally
      FLock.Release;
    end;
  finally
    Local.Free;
  end;
end;

// Lazy decode: walks the offset list for every class-hash bound to
// ClassName, decodes each record into a TClassMember (resolving TypeName
// against the OWNING unit's per-unit imports table), and returns the
// merged member list. Caches the result so subsequent calls are O(1).
procedure TRsmFile.DecodeClassMembers(const ClassName: string;
  out Members: TArray<TClassMember>);
var
  NameKey:        string;
  Hashes:         TArray<Word>;
  Offsets:        TArray<Int64>;
  UnitName:       string;
  UnitImports:    TArray<string>;
  DeclOff:        Int64;
  Acc:            TList<TClassMember>;
begin
  SetLength(Members, 0);
  NameKey := LowerCase(ClassName);

  FLock.Acquire;
  try
    if FClassMembers.TryGetValue(NameKey, Members) then Exit;
    FClassNameToHash.TryGetValue(NameKey, Hashes);
    if not FClassDeclarationOffsets.TryGetValue(NameKey, DeclOff) then
      DeclOff := -1;
    if DeclOff >= 0 then
      UnitName := FindOwningUnit(FUnitAnchors, DeclOff);
    if UnitName <> '' then
      FUnitImports.TryGetValue(UnitName, UnitImports);
  finally
    FLock.Release;
  end;

  Acc := TList<TClassMember>.Create;
  try
    for var Hash in Hashes do begin
      FLock.Acquire;
      try
        Offsets := nil;
        FClassMemberOffsets.TryGetValue(Hash, Offsets);
      finally
        FLock.Release;
      end;
      for var Off in Offsets do begin
        // Drop foreign members pulled in by a low-16-bit TypeId collision:
        // keep only records emitted in the class's own unit section. See
        // MemberMatchesClassUnit for the collision rationale.
        var MemberUnit: string;
        FLock.Acquire;
        try
          MemberUnit := FindOwningUnit(FUnitAnchors, Off);
        finally
          FLock.Release;
        end;
        if not MemberMatchesClassUnit(UnitName, MemberUnit) then Continue;
        var M: TClassMember;
        if not ClassMember_TryDecode(FData, FDataSize, Off, M) then Continue;
        if M.TypeId > 0 then begin
          // Imported types/aliases resolve through the owning unit's $66 list
          // indexed by ImportTypeId (raw VLE shr 1 for multi-byte ids). Local
          // class references (e.g. Exception) are not in the import list and
          // fall back to the class-hash / module typeId map via the raw TypeId.
          var Resolved := ResolveTypeNameForUnit(UnitName, M.TypeId,
                                                 UnitImports, FUserTypes);
          // Multi-byte typeIds carry bit0=1 (the VLE width marker), so the raw
          // value is odd; ResolveTypeNameForUnit (which needs an even id) above
          // rejected it. For those the even ImportTypeId = raw shr 1 is the
          // per-unit import index: resolve it against the owning unit's imports
          // BEFORE any global lookup (the raw odd id is not a valid key for the
          // module type map, so LookupTypeName would mis-type it).
          if (Resolved = '') and (M.ImportTypeId <> M.TypeId) then
            Resolved := ResolveTypeNameForUnit(UnitName, M.ImportTypeId,
                                               UnitImports, nil);
          if Resolved = '' then
            Resolved := LookupTypeName(M.TypeId);
          M.TypeName := Resolved;
        end;
        Acc.Add(M);
      end;
    end;
    Members := Acc.ToArray;
  finally
    Acc.Free;
  end;

  FLock.Acquire;
  try
    FClassMembers.AddOrSetValue(NameKey, Members);
  finally
    FLock.Release;
  end;
end;

// A built-in scalar / string type name is NEVER a class, so it must never
// resolve to class members. The RSM emits a `$2A` declaration record for type
// aliases like `Integer` / `Double` too; with the 1-byte Variant-D class-hash
// registration those alias records can collide with a real class's member
// records (only 128 even 1-byte hashes exist) and make GetClassMembers('Integer')
// spuriously return another class's fields -- which then makes ExprEval treat
// `Integer(3.9)` as a CLASS cast (raw bits) instead of a numeric truncation.
// Reject the primitive names up front: correct on its own (primitives have no
// members) and immune to any hash collision.
function IsBuiltinScalarTypeName(const Name: string): Boolean;
const
  K: array[0..32] of string = (
    'Integer', 'Cardinal', 'LongInt', 'LongWord', 'ShortInt', 'SmallInt',
    'Byte', 'Word', 'Int64', 'UInt64', 'NativeInt', 'NativeUInt',
    'Boolean', 'ByteBool', 'WordBool', 'LongBool',
    'Char', 'AnsiChar', 'WideChar',
    'Single', 'Double', 'Extended', 'Real', 'Comp', 'Currency', 'Pointer',
    'string', 'AnsiString', 'UnicodeString', 'WideString', 'UTF8String',
    'RawByteString', 'ShortString');
begin
  for var S in K do
    if SameText(Name, S) then
      Exit(True);
  Result := False;
end;

function TRsmFile.GetClassMembers(const ClassName: string;
  out Members: TArray<TClassMember>; PreferInstanceSize: Integer): Boolean;
begin
  // RSM keeps a flat, non-size-indexed member table; the size hint (used by TD32
  // to disambiguate same-named classes) does not apply here.
  SetLength(Members, 0);
  if IsBuiltinScalarTypeName(ClassName) then
    Exit(False);
  WaitForIndex;
  FLock.Acquire;
  try
    if FClassMembers.TryGetValue(LowerCase(ClassName), Members) then
      Exit(True);
  finally
    FLock.Release;
  end;
  DecodeClassMembers(ClassName, Members);
  Result := Length(Members) > 0;
end;

function TRsmFile.LookupTypeKind(const TypeName: string): Byte;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    if not FTypeKindByName.TryGetValue(TypeName, Result) then
      Result := 0;
  finally
    FLock.Release;
  end;
end;

function TRsmFile.LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
begin
  Result := FEnumInfoByName.TryGetValue(TypeName, Info) and Info.IsValid;
  if not Result then Exit;
  // For sets, resolve the base enum type name lazily (strip trailing 's').
  if (Info.Kind = 6) and (Info.BaseTypeName = '') then begin
    var BaseName := TypeName;
    if BaseName.EndsWith('s') then begin
      BaseName := Copy(BaseName, 1, Length(BaseName) - 1);
      if FEnumInfoByName.ContainsKey(BaseName) then begin
        Info.BaseTypeName := BaseName;
        FEnumInfoByName.AddOrSetValue(TypeName, Info);
      end;
    end;
  end;
end;

function TRsmFile.TryResolveEnumLiteral(const Name: string;
  out Ordinal: Integer; out EnumTypeName: string): Boolean;
begin
  WaitForIndex;
  FLock.Acquire;
  try
    for var Pair in FEnumInfoByName do begin
      if (Pair.Value.Kind <> 3) or not Pair.Value.IsValid then Continue;
      for var I := 0 to High(Pair.Value.Names) do
        if SameText(Pair.Value.Names[I], Name) then begin
          Ordinal      := Pair.Value.MinValue + I;
          EnumTypeName := Pair.Key;
          Exit(True);
        end;
    end;
  finally
    FLock.Release;
  end;
  Result := False;
end;

initialization
  // Long per-call cap: a correctness-critical wait (BP binding / first locals
  // after load) must get the fully-built index. The event-loop protection is the
  // per-stop InteractiveDeadlineTicks, set by the session around interactive reads.
  TRsmFile.IndexWaitBudgetMs := 60000;
  // InteractiveDeadlineTicks is a threadvar: the RTL zero-initialises it per
  // thread, so there is nothing to reset here.

end.
