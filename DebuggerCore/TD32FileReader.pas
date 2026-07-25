unit TD32FileReader;

// TD32 (Borland Turbo Debug 32) reader for Delphi Win64 PE files.
// Parses the `.debug` section produced by Delphi Athens 36 with -V/-VN.
// Provides line<->RVA mapping via ISourceLineProvider.
//
// Layout notes (verified empirically against TestTarget.exe; JCL's
// TJclTD32InfoParser documents an older Win32 layout with implicit
// padding that does NOT match Athens 36 Win64):
//
//   .debug section
//     +0          IMAGE_DEBUG_DIRECTORY entries (28 bytes each), then
//                 padding to align TD32 header.
//     +N          TD32 header: "FB09" (DWORD $39304246) + DWORD DirRelOff.
//     +N+DirRelOff
//                 Directory header (16 bytes):
//                   Word  HeaderSize  (= 16)
//                   Word  EntrySize   (= 12)
//                   DWord EntryCount
//                   DWord LfoNext     (unused)
//                   DWord Flags
//                 Followed by EntryCount * 12-byte entries:
//                   Word  SubType
//                   Word  ModuleIndex
//                   DWord Offset (relative to TD32 header start)
//                   DWord Size
//     EndOf.debug-8
//                 Trailer signature: DWORD $39304246 + DWORD OffsetBack.
//
// SOURCE_MODULE subsection ($127) layout, base = TD32Header + Entry.Offset:
//   +0   Word  SegmentCount
//   +2   Word  FileCount
//   +4   DWord BaseSrcFile[SegmentCount]    (offsets to per-file structs,
//                                            relative to SOURCE_MODULE base)
//   +4 + 4*SegCount
//        TOffsetPair SegmentRanges[SegmentCount]  (8 bytes each: StartRVA, EndRVA)
//   +4 + 12*SegCount
//        Word SegmentIndex[SegmentCount]
//
// TFileEntry layout, base = SOURCE_MODULE base + BaseSrcFile[i]:
//   +0   Word  SegmentCount
//   +2   DWord NameIndex                     (NOTE: JCL puts a padding word
//                                              here; Athens 36 is truly packed)
//   +6   DWord BaseSrcLines[SegmentCount]    (offsets to per-segment line
//                                              tables, relative to SOURCE_MODULE
//                                              base -- NOT to file entry)
//   +6 + 4*SegCount
//        TOffsetPair SegmentRanges[SegmentCount]
//   +6 + 12*SegCount
//        Word SegmentIndex[SegmentCount]
//   followed by ShortString Name
//
// Per-segment line table, base = SOURCE_MODULE base + BaseSrcLines[i]:
//   +0   Word  SegmentIndex
//   +2   Word  PairCount
//   +4   DWord Offsets[PairCount]   (RVAs into code segment)
//   +4 + 4*PairCount
//        Word LineNumbers[PairCount]
//
// NAMES subsection ($130) layout:
//   +0   DWord NameCount
//   +4   Repeated NameCount times: AnsiChar Len + Len bytes (ShortString).
//
// Only SOURCE_MODULE subsections produce line tables. Other module types
// (ALIGN_SYMBOLS without SOURCE_MODULE) have no line info -- typically RTL.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.SyncObjs, System.IOUtils,
  Winapi.Windows,
  DebugInfoTypes;

const
  TD32_SIGNATURE: Cardinal = $39304246; // 'FB09' little-endian

  SST_MODULE         = $120;
  SST_TYPES          = $121;
  SST_SYMBOLS        = $124;
  SST_ALIGN_SYMBOLS  = $125;
  SST_SOURCE_MODULE  = $127;
  SST_GLOBAL_SYMBOLS = $129;
  SST_GLOBAL_TYPES   = $12B;
  SST_NAMES          = $130;

type
  TTD32DirectoryEntry = record
    SubType:  Word;
    ModIndex: Word;
    Offset:   Cardinal;
    Size:     Cardinal;
  end;

  TTD32ProcRange = record
    StartRva: UInt64;
    EndRva:   UInt64;
    Name:     string;   // demangled name; empty if name lookup failed
    TypeId:   Cardinal; // GPROC32/LPROC32 proctype field (+30): the LF_PROCEDURE
                        // type id. Resolves to parmCount for free-function arity.
                        // 0 when the record was too short to carry it.
  end;

  // Head/tail of one singly-linked chain of locals inside the reader's flat
  // locals store (see FLocalsStore). Both the by-name and the by-RVA index map
  // their key to a chain; the chain preserves the order the parser produced,
  // which is the order every consumer of GetLocalsForFunction* already sees.
  // -1 terminates a chain.
  TTD32LocalChain = record
    Head: Integer;
    Tail: Integer;
  end;

  // One type table entry. Drawn from SST_TYPES / SST_GLOBAL_TYPES records
  // produced by the Athens 36 Delphi compiler. Each entry corresponds to a
  // single TYPES record (record index N) and carries the decoded metadata.
  // The compiler-assigned TypeId in BPREL32 / GDATA32 records is the
  // record's offset within the section's record area (not the index --
  // see FTypeIdToRecord below for the lookup).
  TTD32TypeKind = (tkUnknown, tkPointer, tkArray, tkClass, tkStructure,
                   tkUnion, tkEnum, tkProcedure, tkMFunction, tkVtShape,
                   tkArgList, tkFieldList, tkMethodList, tkModifier,
                   tkVftPath, tkDerivedList, tkMethodPtr, tkSet);
  TTD32TypeMember = record
    Name:     string;   // demangled member name
    TypeId:   Cardinal; // type-table reference of the member's declared type
    TypeName: string;   // resolved member-type name (deferred lookup)
    Offset:   Cardinal; // byte offset within the enclosing class/struct
                        // (for cmkField; for method-backed properties this
                        // stays 0 and GetterName carries the binding).
    Attr:     Word;     // visibility / static / virtual bits (LF_MEMBER attr)
    IsProperty: Boolean;// True when the member came from an LF_MEMBER whose
                        // type points at a Borland $0030..$0035 property
                        // descriptor.
    GetterName: string; // For method-backed properties: demangled method
                        // name (e.g. 'GetMyLabel'). Empty for field-backed
                        // properties and ordinary fields.
    IsIndexed:  Boolean;// True for an indexed (array) property -- the getter
                        // takes an index argument. The property descriptor
                        // carries a non-zero index-args type at offset +6.
    IsDefaultProperty: Boolean; // the Pascal `default` array property, i.e.
                        // the one `Obj[X]` resolves to. Bit 0 of the u16 at +4.
    ReturnTypeId: Cardinal; // For a property: the CV type id of the RETURN
                        // (value) type, decoded from the $0035 descriptor's
                        // payload+0. 0 for fields (TypeId already IS their type)
                        // and for properties whose descriptor lacked it. Lets the
                        // owning reader resolve the property's kind/size by the
                        // EXACT id instead of round-tripping through its name.
  end;
  TTD32TypeRecord = record
    Index:        Integer;            // record index in the section
    Kind:         TTD32TypeKind;
    LeafCode:     Word;               // raw LF_* code from the record
    Name:         string;             // demangled name (classes / structs / enums)
    Size:         Cardinal;           // structure size in bytes (when stored)
    FieldListId:  Cardinal;           // TypeId of the LF_FIELDLIST trailer
    BaseTypeId:   Cardinal;           // LF_POINTER target / LF_ARRAY element /
                                      // LF_ENUM base
    BaseClassId:  Cardinal;           // LF_BCLASS: parent class TypeId (0 = none)
    IdxTypeId:    Cardinal;           // LF_ARRAY ($0032) index-subrange type id
    ElemCount:    Cardinal;           // LF_ARRAY ($0032) element count for THIS dim
    Members:      TArray<TTD32TypeMember>; // populated for FIELDLIST entries
    NameIdx:      Cardinal;           // raw NAMES-section index for diagnostics
    PayloadPtr:   PByte;              // raw payload bytes (after cb + leaf)
    PayloadLen:   Integer;            // payload length in bytes
  end;

  TTD32FileReader = class(TInterfacedObject, ISourceLineProvider,
                          IFunctionNameProvider, IGlobalSymbolProvider,
                          ILocalSymbolProvider, IUnitScopedGlobalProvider,
                          IUnitScopedFuncProvider,
                          IClassMemberProvider, IEnumInfoProvider,
                          ITypeSizeProvider, IClassHierarchyProvider,
                          IMethodSignatureProvider)
  private
    FFileHandle:    THandle;
    FMappingHandle: THandle;
    FBase:          PByte;
    FSize:          Int64;
    FExePath:       string;
    FOutputRvaShift: UInt64;

    // Second mapping for an EXTERNAL `.tds` (dcc64 -VT): the PE structure (section
    // table, import directory -> FBase/FSize) still comes from the companion exe,
    // but the CodeView blob lives in the standalone `.tds`, mapped here and pointed
    // to by FDebugBase/FDebugEnd. Nil/unused for the normal embedded `.debug` path.
    FTdsFileHandle:    THandle;
    FTdsMappingHandle: THandle;
    FTdsBase:          PByte;
    // PE preferred ImageBase (from the optional header), captured in
    // FindDebugSection. Needed by the external `.tds` path: unlike the embedded
    // `.debug` section (whose CodeView offsets are pure segment-relative), an
    // external `.tds` stores segment offsets as (segment-relative - ImageBase), so
    // the `.tds` path adds ImageBase back onto each segment VA.
    FImageBase:        UInt64;

    // .debug section in file (raw offsets, mapped pointer = FBase + RawOff).
    FDebugRawOff:  Cardinal;
    FDebugRawSize: Cardinal;
    FDebugBase:    PByte;   // = FBase + FDebugRawOff
    FDebugEnd:     PByte;   // exclusive

    // PE section table -> segment VA. TD32 line-table offsets are relative
    // to the segment, not to the image base. SegmentVA[segIdx-1] gives the
    // VirtualAddress of the PE section that segment maps to. Built from the
    // PE section table during LoadFromFile.
    FSegmentVAs:   TArray<UInt64>;
    // Per-section RVA range + raw file offset, kept around so RVAs anywhere
    // in the image (e.g. the import directory, not just .debug) can be
    // resolved to a mapped pointer.
    FSecRvaStart:  TArray<Cardinal>;
    FSecRvaEnd:    TArray<Cardinal>;
    FSecFileOff:   TArray<Cardinal>;

    // TD32 header position (within .debug).
    FTd32Base:     PByte;

    // Directory.
    FDirBase:      PByte;   // first directory block's entries (legacy field,
                            //   kept for completeness; iteration goes through
                            //   FDirEntries to honour the lfoNextDir chain).
    FDirCount:     Cardinal;
    FDirEntrySize: Word;
    FDirEntries:   TArray<TTD32DirectoryEntry>;

    // NAMES table, fully decoded during the load (name index -> string). Built
    // once by LocateNamesSection so the reader is immutable after loading.
    FNamesBase:    PByte;
    FNamesSize:    Cardinal;
    FNamesCount:   Cardinal;
    FNamesByIndex: TArray<string>;
    FNamesIndexed: Boolean;

    // SOURCE_MODULE result tables.
    FRvaToLoc:     TDictionary<UInt64, TSourceLocation>;
    FLineToRva:    TDictionary<string, UInt64>;
    FSortedRvas:   TArray<UInt64>;

    // Proc symbol tables (built from ALIGN_SYMBOLS LPROC32/GPROC32 records).
    FProcs:         TArray<TTD32ProcRange>;   // sorted by StartRva ascending
    FNameToRva:     TDictionary<string, UInt64>;
    FInnerToParent: TDictionary<string, string>;

    // Global data symbols (built from GDATA32 records).
    FGlobals:       TArray<TGlobalSymbol>;
    FGlobalByName:  TDictionary<string, Integer>; // lcase name -> idx in FGlobals
    // TD32 module index -> owning unit name (basename, no ext). Built in
    // ParseSourceModule. Lets per-module ALIGN_SYMBOLS globals be attributed to
    // their declaring unit (foundation for unit-scoped global resolution).
    FModIndexUnit:  TDictionary<Word, string>;
    // Unit-scoped globals: key = lcase(unit)+'|'+lcase(name) -> the global as
    // declared in THAT unit. Populated from ALIGN_SYMBOLS (which carry a
    // ModIndex). Resolves the cross-unit same-name collision the flat
    // FNameToRva/FGlobalByName (first-hit) cannot.
    FUnitGlobals:   TDictionary<string, TGlobalSymbol>;
    // Per-unit proc attribution (IUnitScopedFuncProvider): 'unit|name' (lower)
    // -> RVA. FNameToRva is name-keyed so same-named procs in several units
    // collapse; this keeps each unit's copy so resolution can pick the one the
    // frame's unit `uses`. Populated in HandleProcRecord via the owning ModIndex.
    FUnitProcs:     TDictionary<string, UInt64>;
    // lcase(name) -> first owning unit seen; a second DIFFERENT unit marks the
    // name colliding (FCollidingGlobals).
    FGlobalFirstUnit:  TDictionary<string, string>;
    FCollidingGlobals: TDictionary<string, Boolean>;

    // Procedure locals (built from BPREL32 records inside LPROC32/GPROC32).
    //
    // Storage is ONE flat array plus two chains of indices into it, NOT two
    // dictionaries of arrays. The previous shape (`Existing := Existing + [L]`
    // per index) reallocated and copied a whole TArray<TLocalSymbol> for every
    // local, twice -- quadratic per key, inside the hottest parse phase
    // (ParseAllAlignSymbols is ~half of a TD32 load). cxLibraryRS29.bpl (44 MB
    // of debug data) has 146,279 locals over 48,124 name keys, longest chain
    // 398; LoadFromFile went 585 -> 494 ms (medians of 5, same probe built
    // against both revisions). Chaining also stores each local ONCE instead of
    // once per index -- reader heap 161.5 -> 152.6 MB on that package -- at the
    // cost of two 4-byte links per local.
    FLocalsStore:      TArray<TLocalSymbol>;  // append-only; FLocalsCount valid entries
    FLocalsCount:      Integer;
    FLocalNextByName:  TArray<Integer>;       // next-in-chain for FProcLocalChains
    FLocalNextByRva:   TArray<Integer>;       // next-in-chain for FRvaLocalChains
    FProcLocalChains:  TDictionary<string, TTD32LocalChain>;  // lcase name -> locals
    // Per-RVA locals: disambiguates same-named procs across units. Keyed
    // by the proc's body StartRva (the one stored in TTD32ProcRange).
    FRvaLocalChains:   TDictionary<UInt64, TTD32LocalChain>;
    // Opt-in: TD32 locals lack full type info (no record/class metadata),
    // so by default GetLocalsForFunction is a no-op. Enable when RSM is
    // unavailable for the target.
    FExposeLocals:  Boolean;

    // Type table built from SST_TYPES / SST_GLOBAL_TYPES.
    FTypes:           TArray<TTD32TypeRecord>; // indexed by record index
    FTypeIdToRecord:  TDictionary<Cardinal, Integer>; // GDATA32/BPREL32 TypeIdx
                                                      // -> index in FTypes
    FNameToTypeIdx:   TDictionary<string, Integer>;   // lowercase demangled
                                                      // class/struct/enum name
                                                      // -> index in FTypes

    FLoaded:       Boolean;

    procedure OpenMappedFile(const ExePath: string);
    // Maps a standalone `.tds` read-only into FTdsBase; returns its byte size.
    function  OpenTdsMapping(const TdsPath: string): Int64;
    procedure CloseMappedFile;
    function  FindDebugSection: Boolean;
    function  FindTD32Header: Boolean;
    function  ReadDirectory: Boolean;
    function  ReadDirectoryEntry(Index: Integer; out E: TTD32DirectoryEntry): Boolean;
    procedure LocateNamesSection;
    procedure BuildNamesIndex;
    function  ResolveNameByIndex(Idx: Cardinal): string;
    procedure ParseAllSourceModules;
    procedure ParseSourceModule(const Entry: TTD32DirectoryEntry);
    procedure ParseAllAlignSymbols;
    procedure ParseAlignSymbols(const Entry: TTD32DirectoryEntry);
    procedure ParseGlobalSymbols(const Entry: TTD32DirectoryEntry);
    procedure ParseSymbolStream(Base, Stop: PByte; IncludeGData: Boolean;
                OwningModIndex: Integer = -1);
    procedure HandleProcRecord(Payload: PByte; PayloadEnd: PByte;
                               IsGlobal: Boolean;
                               out NewProcName: string;
                               out NewProcRva: UInt64;
                               OwningModIndex: Integer = -1);
    // Appends L to the flat store and returns its index (amortised O(1)).
    function  AddLocalToStore(const L: TLocalSymbol): Integer;
    // Links store entry Index at the END of the chain that Key maps to.
    procedure LinkLocalToChain<TKey>(Chains: TDictionary<TKey, TTD32LocalChain>;
                            const Key: TKey; var NextLink: TArray<Integer>;
                            Index: Integer);
    // Materialises a chain, in link order, as the flat array every consumer
    // of GetLocalsForFunction* expects.
    function  CollectChain(Head: Integer;
                            const NextLink: TArray<Integer>): TArray<TLocalSymbol>;
    procedure AppendLocalToScope(const L: TLocalSymbol;
                                 const ScopeName: string; ScopeRva: UInt64);
    procedure HandlePub32(Payload: PByte; PayloadEnd: PByte);
    procedure HandleGData32(Payload: PByte; PayloadEnd: PByte;
                OwningModIndex: Integer = -1);
    procedure HandleRegister(Payload, PayloadEnd: PByte;
                             const ScopeName: string; ScopeRva: UInt64;
                             BlockStartRva, BlockEndRva: UInt64);
    procedure ParseAllTypeTables;
    procedure ParseTypeTable(const Entry: TTD32DirectoryEntry);
    procedure ParseImportTable;
    function  RvaToFilePtr(Rva: Cardinal): PByte;
    // Computes a symbol's exe-space RVA from a CodeView (1-based segment, offset)
    // pair. Truncates the segment+offset sum to 32 bits (a PE RVA is 32-bit) so the
    // external-`.tds` ImageBase bias folded into FSegmentVAs cancels, then adds the
    // 64-bit runtime relocation. Callers must pre-validate SegOneBased in range.
    function  SegOffsetToRva(SegOneBased: Word; Offs: Cardinal): UInt64;
    procedure DecodeTypeRecord(var R: TTD32TypeRecord; LeafCode: Word;
                               Payload, PayloadEnd: PByte);
    function  DecodeFriendlyTypeName(const Mangled: string): string;
    // Second pass: expand FIELDLIST sub-records into the parent class /
    // struct / enum record's Members array. Runs after the top-level
    // type table has been parsed so all TypeIds resolve.
    procedure PopulateClassMembers;
    procedure DecodeFieldList(var Owner: TTD32TypeRecord;
                              Payload: PByte; Len: Integer);
    // Appends a class's members (base-class chain first, then own) into
    // Members. Used by GetClassMembers to surface inherited fields.
    procedure AppendClassMembersByIdx(Idx: Integer;
                              var Members: TArray<TClassMember>; Depth: Integer);
    // Deterministic kind/size of a type given its EXACT CV type id (not its
    // name). Resolve non-primitive types (>= $1000) through FTypeIdToRecord --
    // the exact record, immune to the first-wins ambiguity of same-named types.
    // Return 0 for primitives (id < $1000): their names never collide, so the
    // name path handles them without loss (and drives float-in-XMM correctly).
    function  TypeKindById(TypeId: Cardinal; Depth: Integer = 0): Byte;
    function  TypeSizeById(TypeId: Cardinal): Integer;
    procedure HandleBpRel32(Payload: PByte; PayloadEnd: PByte;
                            const ScopeName: string; ScopeRva: UInt64;
                            BlockStartRva, BlockEndRva: UInt64);
    procedure SortAndIndexProcs;
    function  FindProcIndex(Rva: UInt64): Integer;
    procedure RebuildSortedRvas;
    class function LineKey(const FileName: string; Line: Integer): string;
  public
    // Itanium-style demangler tuned for Delphi mangled names. Public so the
    // unit-test suite can exercise it directly.
    class function DemangleItanium(const Mangled: string;
                    out InnerName, ParentName: string): Boolean; static;
    // dcc32 mangles differently from dcc64. Public for the same reason.
    class function DemangleBorland(const Mangled: string;
                    out InnerName, ParentName: string): Boolean; static;
    constructor Create;
    destructor  Destroy; override;
    procedure   LoadFromFile(const ExePath: string; OutputRvaShift: UInt64 = 0);
    // Loads debug info from an EXTERNAL `.tds` file (dcc64 -VT) instead of the
    // embedded `.debug` section. TdsPath supplies the CodeView blob; ExePath is the
    // companion binary the `.tds` describes (its PE section table + import directory
    // are still read from it). Same CodeView format as LoadFromFile -- only the blob
    // location differs. The caller is responsible for the stale check (a `.tds`
    // older than ExePath must be skipped).
    procedure   LoadFromTdsFile(const TdsPath, ExePath: string; OutputRvaShift: UInt64 = 0);
    // True once debug info was successfully parsed (embedded `.debug` or `.tds`).
    property    Loaded: Boolean read FLoaded;

    // ISourceLineProvider
    function    RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
    function    SourceLineToRva(const FileName: string; Line: Integer;
                  out Rva: UInt64): Boolean;
    function    SortedRvas: TArray<UInt64>;

    // IFunctionNameProvider
    function    RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
    function    RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
    function    NameToRva(const Name: string; out Rva: UInt64): Boolean;
    function    GetEnclosingProcedure(const Inner: string;
                  out Parent: string): Boolean;
    function    GetEnclosingProcedureByRva(InnerRva: UInt64;
                  out Parent: string): Boolean;
    function    GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
                  out ParentRva: UInt64): Boolean;

    // IGlobalSymbolProvider
    function    GetGlobals: TArray<TGlobalSymbol>;
    function    FindGlobal(const Name: string; out Global: TGlobalSymbol): Boolean;
    // IUnitScopedGlobalProvider: a global var name can collide across units in
    // ONE binary (TD32's flat name index keeps the first-hit). These resolve the
    // collision by the owning unit (attributed from ALIGN_SYMBOLS ModIndex ->
    // SOURCE_MODULE unit).
    function    FindGlobalInUnit(const Name, UnitHint: string;
                  out Global: TGlobalSymbol): Boolean;
    function    GlobalNameCollidesAcrossUnits(const Name: string): Boolean;
    // IUnitScopedFuncProvider: the RVA of proc Name declared in UnitHint.
    function    FindFuncRvaInUnit(const Name, UnitHint: string;
                  out Rva: UInt64): Boolean;

    // ILocalSymbolProvider (gated by ExposeLocals; default False so RSM wins).
    function    GetLocalsForFunction(const FunctionName: string;
                  out Locals: TArray<TLocalSymbol>): Boolean;
    function    GetLocalsForFunctionByRva(InnerRva: UInt64;
                  out Locals: TArray<TLocalSymbol>): Boolean;
    function    AllProcedureNames: TArray<string>;
    property    ExposeLocals: Boolean read FExposeLocals write FExposeLocals;

    // IClassMemberProvider -- backed by FTypes / FNameToTypeIdx.
    function    GetClassMembers(const TypeName: string;
                  out Members: TArray<TClassMember>; PreferInstanceSize: Integer = 0): Boolean;
    // IMethodSignatureProvider -- decodes a class method's declared params from
    // the FIELDLIST -> LF_METHOD -> LF_METHODLIST -> LF_MFUNCTION -> LF_ARGLIST
    // chain (on-demand; does not touch the bulk type parse).
    function    TryGetMethodParams(const ClassName, MethodName: string;
                  out Params: TArray<TMethodParam>; out HasSelf: Boolean): Boolean;
    function    TryGetFreeFunctionParamCount(const FuncName: string;
                  out Count: Integer): Boolean;
    // ITypeSizeProvider
    function    GetTypeSize(const TypeName: string; out Size: Integer): Boolean;
    // IClassHierarchyProvider
    function    GetParentClassName(const ClassName: string; out Parent: string): Boolean;
    // Diagnostic: human-readable kind/size/base chain for a type id.
    function    DescribeTypeChain(TypeId: Cardinal): string;

    // IEnumInfoProvider
    function    LookupEnumInfo(const TypeName: string;
                  out Info: TRsmEnumInfo): Boolean;
    function    EnumValueToOrdinal(const TypeName, ValueName: string;
                  out Ordinal: Integer; out EnumTypeName: string): Boolean;
    function    TryResolveEnumLiteral(const Name: string;
                  out Ordinal: Integer; out EnumTypeName: string): Boolean;
    function    LookupTypeKind(const TypeName: string): Byte;

    // Lower bound of an LF_ARRAY index ($0031 subrange); 0 when unknown.
    function    ArrayDimLowBound(IdxTypeId: Cardinal): Integer;
    // Byte size of an array element type (record .Size or primitive), 0 if unknown.
    function    ArrayElemByteSize(TypeId: Cardinal): Integer;

    // Diagnostics over the TD32 type table.
    function    GetTypeName(TypeId: Cardinal): string;
    function    GetTypeRecord(TypeId: Cardinal; out Rec: TTD32TypeRecord): Boolean;
    function    FindTypeByName(const Name: string;
                  out Rec: TTD32TypeRecord): Boolean;
    // Diagnostic: resolves a NAMES section index to its string. Public
    // so probe tools can dump raw fieldlist sub-record references.
    function    DiagResolveName(Idx: Cardinal): string;
    // List of source filenames (basename only, lowercase) referenced by
    // any SOURCE_MODULE record. Used by the BPL containment check so
    // breakpoint resolution can route to TD32 even when no MAP file is
    // available alongside the package.
    function    GetSourceFiles: TArray<string>;
    // Diagnostic: returns the raw bytes (payload only, after cb+leaf) of
    // a type record. Used by probes when reverse-engineering new leaf
    // kinds. Returns nil + Len=0 if TypeId is out of range or below the
    // primitive cutoff ($1000).
    function    GetTypeRecordPayload(TypeId: Cardinal;
                  out Payload: PByte; out Len: Integer): Boolean;

    // Diagnostics
    function    AllKnownProcNames: TArray<string>;
    // Diagnostic: raw scan of every ALIGN_SYMBOLS / GLOBAL_SYMBOLS stream,
    // reporting each data/local/public record whose decoded name contains
    // NameFilter (case-insensitive; '' dumps every $0202/$0201 data global).
    // Each line carries the stream subtype, owning module/unit, record kind,
    // name, segment and computed RVA. The header lines are aggregate counts.
    // Answers "why is global X not captured?" -- e.g. on SampleApp it showed the
    // main exe's TD32 covers only ~33 units (GlobalsU is not one; its `Globals`
    // lives in libSharedFormsD29.bpl, where the same scan finds it at RVA $6F198).
    function    DiagFindSymbolRecords(const NameFilter: string): TArray<string>;
  end;

implementation

uses
  System.Math, System.Generics.Defaults;

{ ------------------------- helpers ------------------------- }

function DecodeTD32Name(const Buf: TBytes): string;
begin
  // TD32 names are length-prefixed byte strings, almost always ASCII
  // identifiers. Try UTF-8 first (TUTF8Encoding uses MB_ERR_INVALID_CHARS,
  // so it RAISES on a non-UTF-8 byte); fall back to ANSI, which substitutes
  // invalid bytes instead of raising. This keeps a single bad byte in one
  // symbol name from aborting the whole TD32 load.
  if Length(Buf) = 0 then Exit('');
  try
    Result := TEncoding.UTF8.GetString(Buf);
  except
    on EEncodingError do
      Result := TEncoding.ANSI.GetString(Buf);
  end;
end;

function StripBareSourceName(const S: string): string;
// dcc64 emits unqualified globals (program/unit `var`s) in TD32 as a bare
// Itanium source-name -- a decimal length prefix followed by the identifier
// (e.g. `15frmSplashScreen`, `8TlsIndex`) -- WITHOUT the `_ZN ... E` wrapper,
// so DemangleItanium (which requires `_Z`) leaves the prefix intact and the
// name fails every by-name lookup. Strip the prefix when it is exactly the
// length of the remaining identifier. A Delphi identifier never starts with a
// digit, so a leading digit run is unambiguously the length prefix; requiring
// an exact length match keeps genuinely odd names untouched.
begin
  Result := S;
  if (S = '') or not CharInSet(S[1], ['0'..'9']) then Exit;
  var P := 1;
  var Len := 0;
  while (P <= Length(S)) and CharInSet(S[P], ['0'..'9']) do begin
    Len := Len * 10 + Ord(S[P]) - Ord('0');
    Inc(P);
  end;
  if (Len >= 1) and (Length(S) - (P - 1) = Len) then
    Result := Copy(S, P, Len);
end;

function ReadAnsiShortString(P: PByte): string;
var
  Len: Byte;
  Buf: TBytes;
begin
  Len := P^;
  if Len = 0 then Exit('');
  SetLength(Buf, Len);
  Move((P + 1)^, Buf[0], Len);
  Result := DecodeTD32Name(Buf);
end;

{ ------------------------- TTD32FileReader ------------------------- }

constructor TTD32FileReader.Create;
begin
  inherited;
  FFileHandle    := INVALID_HANDLE_VALUE;
  FMappingHandle := 0;
  FBase          := nil;
  FSize          := 0;
  FTdsFileHandle    := INVALID_HANDLE_VALUE;
  FTdsMappingHandle := 0;
  FTdsBase          := nil;
  FRvaToLoc      := TDictionary<UInt64, TSourceLocation>.Create;
  FLineToRva     := TDictionary<string, UInt64>.Create;
  FNameToRva     := TDictionary<string, UInt64>.Create;
  FInnerToParent := TDictionary<string, string>.Create;
  FGlobalByName  := TDictionary<string, Integer>.Create;
  FProcLocalChains := TDictionary<string, TTD32LocalChain>.Create;
  FRvaLocalChains  := TDictionary<UInt64, TTD32LocalChain>.Create;
  FTypeIdToRecord:= TDictionary<Cardinal, Integer>.Create;
  FNameToTypeIdx := TDictionary<string, Integer>.Create;
  FModIndexUnit  := TDictionary<Word, string>.Create;
  FUnitGlobals   := TDictionary<string, TGlobalSymbol>.Create;
  FUnitProcs     := TDictionary<string, UInt64>.Create;
  FGlobalFirstUnit  := TDictionary<string, string>.Create;
  FCollidingGlobals := TDictionary<string, Boolean>.Create;
end;

destructor TTD32FileReader.Destroy;
begin
  CloseMappedFile;
  FRvaToLoc.Free;
  FLineToRva.Free;
  FNameToRva.Free;
  FInnerToParent.Free;
  FGlobalByName.Free;
  FProcLocalChains.Free;
  FRvaLocalChains.Free;
  FTypeIdToRecord.Free;
  FNameToTypeIdx.Free;
  FModIndexUnit.Free;
  FUnitGlobals.Free;
  FUnitProcs.Free;
  FGlobalFirstUnit.Free;
  FCollidingGlobals.Free;
  inherited;
end;

procedure TTD32FileReader.OpenMappedFile(const ExePath: string);
begin
  FFileHandle := CreateFileW(PChar(ExePath), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FFileHandle = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('Cannot open %s', [ExePath]);
  var Hi: DWORD := 0;
  var Lo: DWORD := GetFileSize(FFileHandle, @Hi);
  FSize := (Int64(Hi) shl 32) or Lo;
  FMappingHandle := CreateFileMapping(FFileHandle, nil, PAGE_READONLY, 0, 0, nil);
  if FMappingHandle = 0 then begin
    CloseMappedFile;
    raise Exception.Create('CreateFileMapping failed');
  end;
  FBase := MapViewOfFile(FMappingHandle, FILE_MAP_READ, 0, 0, 0);
  if FBase = nil then begin
    CloseMappedFile;
    raise Exception.Create('MapViewOfFile failed');
  end;
end;

procedure TTD32FileReader.CloseMappedFile;
begin
  if FBase <> nil then begin
    UnmapViewOfFile(FBase);
    FBase := nil;
  end;
  if FMappingHandle <> 0 then begin
    CloseHandle(FMappingHandle);
    FMappingHandle := 0;
  end;
  if FFileHandle <> INVALID_HANDLE_VALUE then begin
    CloseHandle(FFileHandle);
    FFileHandle := INVALID_HANDLE_VALUE;
  end;
  // Second mapping (external `.tds`), if any.
  if FTdsBase <> nil then begin
    UnmapViewOfFile(FTdsBase);
    FTdsBase := nil;
  end;
  if FTdsMappingHandle <> 0 then begin
    CloseHandle(FTdsMappingHandle);
    FTdsMappingHandle := 0;
  end;
  if FTdsFileHandle <> INVALID_HANDLE_VALUE then begin
    CloseHandle(FTdsFileHandle);
    FTdsFileHandle := INVALID_HANDLE_VALUE;
  end;
end;

function TTD32FileReader.RvaToFilePtr(Rva: Cardinal): PByte;
// Maps an image-relative RVA to a pointer inside the mmap'd PE file,
// using the per-section start/end ranges captured by FindDebugSection.
// Returns nil if the RVA does not lie inside any mapped section.
begin
  Result := nil;
  for var I := 0 to High(FSecRvaStart) do
    if (Rva >= FSecRvaStart[I]) and (Rva < FSecRvaEnd[I]) then begin
      var Off: Cardinal := Rva - FSecRvaStart[I] + FSecFileOff[I];
      if Int64(Off) >= FSize then Exit(nil);
      Result := FBase + Off;
      Exit;
    end;
end;

function TTD32FileReader.SegOffsetToRva(SegOneBased: Word; Offs: Cardinal): UInt64;
begin
  Result := UInt64(Cardinal(Offs + Cardinal(FSegmentVAs[SegOneBased - 1]))) + FOutputRvaShift;
end;

procedure TTD32FileReader.ParseImportTable;
// Walks the PE image's IMAGE_IMPORT_DESCRIPTOR array (DataDirectory[1])
// and adds every named imported function to FNameToRva. The RVA stored
// is the IAT slot RVA (`FirstThunk + i*8` for PE32+), which is where
// the loader writes the resolved function address at runtime and what
// `call [IAT_slot]` references in compiler-emitted call sites. Mirrors
// MAP file behaviour for `external 'kernel32.dll' name 'X'` symbols.
//
// Layout (PE32+):
//   DOS header  : at +$3C -> PE header offset.
//   PE header   : 'PE\0\0' + COFF header + Optional header.
//   OptHdr+108  : NumberOfRvaAndSizes (UInt32). DataDirectory[16] follows.
//   DataDir[1]  : (RVA, Size) of the IMAGE_IMPORT_DESCRIPTOR array.
//   IMAGE_IMPORT_DESCRIPTOR (20 bytes): OriginalFirstThunk, TimeDateStamp,
//                                       ForwarderChain, NameRva, FirstThunk.
//                                       Terminator descriptor is all zero.
//   ILT entries (PE32+, 8 bytes each):
//     bit 63 set: ordinal import (low 16 bits = ordinal, no name)
//     bit 63 clear: low 31 bits = RVA to IMAGE_IMPORT_BY_NAME =
//                                 Hint(WORD) + zero-terminated UTF-8 name.
const
  IMAGE_DIRECTORY_ENTRY_IMPORT = 1;
begin
  if FBase = nil then Exit;
  if FSize < 64 then Exit;
  if (FBase[0] <> Ord('M')) or (FBase[1] <> Ord('Z')) then Exit;
  var PeOff: Cardinal := PCardinal(FBase + $3C)^;
  if (PeOff + 24 >= FSize) then Exit;
  if (FBase[PeOff] <> Ord('P')) or (FBase[PeOff + 1] <> Ord('E')) then Exit;
  var OptHdr := PeOff + 24;
  var Magic: Word := PWord(FBase + OptHdr)^;
  var DataDirOff: Cardinal;
  if Magic = $20B then
    DataDirOff := OptHdr + 112  // PE32+
  else
    DataDirOff := OptHdr + 96;  // PE32
  if Int64(DataDirOff) + (IMAGE_DIRECTORY_ENTRY_IMPORT + 1) * 8 > FSize then
    Exit;
  var ImpRva:  Cardinal := PCardinal(FBase + DataDirOff + IMAGE_DIRECTORY_ENTRY_IMPORT * 8)^;
  var ImpSize: Cardinal := PCardinal(FBase + DataDirOff + IMAGE_DIRECTORY_ENTRY_IMPORT * 8 + 4)^;
  if (ImpRva = 0) or (ImpSize = 0) then Exit;
  var DescP := RvaToFilePtr(ImpRva);
  if DescP = nil then Exit;
  var DescPtr: PByte := DescP;
  var Pe32Plus := (Magic = $20B);
  while True do begin
    if PCardinal(DescPtr +  0)^ = 0 then
      if PCardinal(DescPtr + 16)^ = 0 then
        Break;
    var OFT:     Cardinal := PCardinal(DescPtr +  0)^;  // OriginalFirstThunk
    // var TimeStamp := PCardinal(DescPtr + 4)^;
    // var Forwarder := PCardinal(DescPtr + 8)^;
    // var DllNameRva := PCardinal(DescPtr + 12)^;
    var FT:      Cardinal := PCardinal(DescPtr + 16)^;  // FirstThunk = IAT base
    var WalkRva: Cardinal := OFT;
    if WalkRva = 0 then
      WalkRva := FT;
    var WalkP := RvaToFilePtr(WalkRva);
    var IatRva: Cardinal := FT;
    if WalkP <> nil then begin
      var Idx: Cardinal := 0;
      while True do begin
        if Pe32Plus then begin
          if Int64(WalkP + Idx * 8 + 8) > Int64(FBase + FSize) then Break;
          var Entry: UInt64 := PUInt64(WalkP + Idx * 8)^;
          if Entry = 0 then Break;
          if (Entry and (UInt64(1) shl 63)) = 0 then begin
            var NameRva: Cardinal := Cardinal(Entry and $7FFFFFFF);
            var NameByName := RvaToFilePtr(NameRva);
            if NameByName <> nil then begin
              // skip 2-byte Hint, read NUL-terminated name
              var NameP: PAnsiChar := PAnsiChar(NameByName + 2);
              var FuncName: string := string(AnsiString(NameP));
              if FuncName <> '' then begin
                var Slot: UInt64 := UInt64(IatRva + Idx * 8) + FOutputRvaShift;
                var Key := AnsiLowerCase(FuncName);
                if not FNameToRva.ContainsKey(Key) then
                  FNameToRva.Add(Key, Slot);
              end;
            end;
          end;
          Inc(Idx);
        end else begin
          if Int64(WalkP + Idx * 4 + 4) > Int64(FBase + FSize) then Break;
          var Entry32: Cardinal := PCardinal(WalkP + Idx * 4)^;
          if Entry32 = 0 then Break;
          if (Entry32 and $80000000) = 0 then begin
            var NameRva: Cardinal := Entry32 and $7FFFFFFF;
            var NameByName := RvaToFilePtr(NameRva);
            if NameByName <> nil then begin
              var NameP: PAnsiChar := PAnsiChar(NameByName + 2);
              var FuncName: string := string(AnsiString(NameP));
              if FuncName <> '' then begin
                var Slot: UInt64 := UInt64(IatRva + Idx * 4) + FOutputRvaShift;
                var Key := AnsiLowerCase(FuncName);
                if not FNameToRva.ContainsKey(Key) then
                  FNameToRva.Add(Key, Slot);
              end;
            end;
          end;
          Inc(Idx);
        end;
      end;
    end;
    Inc(DescPtr, 20);
  end;
  // Delayed imports (IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT = 13). The
  // descriptor shape differs from the eager one:
  //   IMAGE_DELAYLOAD_DESCRIPTOR (32 bytes):
  //     +0  Attributes        : u32
  //     +4  DllNameRVA        : u32
  //     +8  ModuleHandleRVA   : u32
  //     +12 ImportAddressTbl  : u32  -- IAT (resolved addresses)
  //     +16 ImportNameTable   : u32  -- INT  (name pointers, same shape
  //                                          as eager OFT)
  //     +20 BoundDelayImpRVA  : u32
  //     +24 UnloadDelayImpRVA : u32
  //     +28 TimeDateStamp     : u32
  // Walked identically to the eager case past the field shuffle.
  const IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT = 13;
  if Int64(DataDirOff) + (IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT + 1) * 8 > FSize then
    Exit;
  var DelayRva:  Cardinal := PCardinal(FBase + DataDirOff + IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT * 8)^;
  var DelaySize: Cardinal := PCardinal(FBase + DataDirOff + IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT * 8 + 4)^;
  if (DelayRva = 0) or (DelaySize = 0) then Exit;
  var DelayP := RvaToFilePtr(DelayRva);
  if DelayP = nil then Exit;
  while True do begin
    if PCardinal(DelayP +  4)^ = 0 then  // DllNameRVA terminator
      Break;
    var IatRva:  Cardinal := PCardinal(DelayP + 12)^;
    var IntRva:  Cardinal := PCardinal(DelayP + 16)^;
    if IntRva = 0 then IntRva := IatRva;
    var IntP := RvaToFilePtr(IntRva);
    if IntP <> nil then begin
      var Idx: Cardinal := 0;
      while True do begin
        if Pe32Plus then begin
          if Int64(IntP + Idx * 8 + 8) > Int64(FBase + FSize) then Break;
          var Entry: UInt64 := PUInt64(IntP + Idx * 8)^;
          if Entry = 0 then Break;
          if (Entry and (UInt64(1) shl 63)) = 0 then begin
            var NameRva: Cardinal := Cardinal(Entry and $7FFFFFFF);
            var NameByName := RvaToFilePtr(NameRva);
            if NameByName <> nil then begin
              var NameP: PAnsiChar := PAnsiChar(NameByName + 2);
              var FuncName: string := string(AnsiString(NameP));
              if FuncName <> '' then begin
                var Slot: UInt64 := UInt64(IatRva + Idx * 8) + FOutputRvaShift;
                var Key := AnsiLowerCase(FuncName);
                if not FNameToRva.ContainsKey(Key) then
                  FNameToRva.Add(Key, Slot);
              end;
            end;
          end;
          Inc(Idx);
        end else begin
          if Int64(IntP + Idx * 4 + 4) > Int64(FBase + FSize) then Break;
          var Entry32: Cardinal := PCardinal(IntP + Idx * 4)^;
          if Entry32 = 0 then Break;
          if (Entry32 and $80000000) = 0 then begin
            var NameRva: Cardinal := Entry32 and $7FFFFFFF;
            var NameByName := RvaToFilePtr(NameRva);
            if NameByName <> nil then begin
              var NameP: PAnsiChar := PAnsiChar(NameByName + 2);
              var FuncName: string := string(AnsiString(NameP));
              if FuncName <> '' then begin
                var Slot: UInt64 := UInt64(IatRva + Idx * 4) + FOutputRvaShift;
                var Key := AnsiLowerCase(FuncName);
                if not FNameToRva.ContainsKey(Key) then
                  FNameToRva.Add(Key, Slot);
              end;
            end;
          end;
          Inc(Idx);
        end;
      end;
    end;
    Inc(DelayP, 32);
  end;
end;

function TTD32FileReader.FindDebugSection: Boolean;
begin
  Result := False;
  if FSize < 64 then Exit;
  if (FBase[0] <> Ord('M')) or (FBase[1] <> Ord('Z')) then Exit;
  var PeOff: Cardinal := PCardinal(FBase + $3C)^;
  if (PeOff + 24 >= FSize) then Exit;
  if (FBase[PeOff] <> Ord('P')) or (FBase[PeOff + 1] <> Ord('E')) then Exit;
  var NumSections: Word := PWord(FBase + PeOff + 6)^;
  var OptSize:     Word := PWord(FBase + PeOff + 20)^;
  // Preferred ImageBase from the optional header: PE32+ ($20B) stores an 8-byte
  // ImageBase at optHdr+24; PE32 ($10B) a 4-byte one at optHdr+28.
  var OptHdr := PeOff + 24;
  var OptMagic: Word := PWord(FBase + OptHdr)^;
  if OptMagic = $20B then
    FImageBase := PUInt64(FBase + OptHdr + 24)^
  else
    FImageBase := PCardinal(FBase + OptHdr + 28)^;
  var SectTbl := PeOff + 24 + OptSize;
  for var I := 0 to NumSections - 1 do begin
    var Hdr := SectTbl + Cardinal(I) * 40;
    var NameP := FBase + Hdr;
    var SecName: AnsiString;
    SetString(SecName, PAnsiChar(NameP), 8);
    var Z := Pos(AnsiChar(#0), SecName);
    if Z > 0 then
      SecName := Copy(SecName, 1, Z - 1);
    var SecVSize:   Cardinal := PCardinal(FBase + Hdr +  8)^;
    var SecVA:      Cardinal := PCardinal(FBase + Hdr + 12)^;
    var SecRawSize: Cardinal := PCardinal(FBase + Hdr + 16)^;
    var SecRawOff:  Cardinal := PCardinal(FBase + Hdr + 20)^;
    FSegmentVAs   := FSegmentVAs   + [UInt64(SecVA)];
    FSecRvaStart  := FSecRvaStart  + [SecVA];
    var EndRva: Cardinal := SecVSize;
    if SecRawSize > EndRva then EndRva := SecRawSize;
    FSecRvaEnd    := FSecRvaEnd    + [SecVA + EndRva];
    FSecFileOff   := FSecFileOff   + [SecRawOff];
    if string(SecName) = '.debug' then begin
      FDebugRawSize := PCardinal(FBase + Hdr + 16)^;
      FDebugRawOff  := PCardinal(FBase + Hdr + 20)^;
      if (FDebugRawOff = 0) or (Int64(FDebugRawOff) + FDebugRawSize > FSize) then
        Exit;
      FDebugBase := FBase + FDebugRawOff;
      FDebugEnd  := FDebugBase + FDebugRawSize;
      Result := True;
    end;
  end;
end;

function TTD32FileReader.FindTD32Header: Boolean;
begin
  Result := False;
  if FDebugBase = nil then Exit;
  // Trailer at end-8: signature + offset-back. Most reliable anchor.
  if FDebugRawSize < 16 then Exit;
  var Trailer := FDebugBase + FDebugRawSize - 8;
  var TrailerSig: Cardinal := PCardinal(Trailer)^;
  if TrailerSig = TD32_SIGNATURE then begin
    var OffBack: Cardinal := PCardinal(Trailer + 4)^;
    if (OffBack > 0) and (OffBack <= FDebugRawSize) then begin
      var Candidate := FDebugBase + FDebugRawSize - OffBack;
      if PCardinal(Candidate)^ = TD32_SIGNATURE then begin
        FTd32Base := Candidate;
        Exit(True);
      end;
    end;
  end;
  // Fallback: linear scan for "FB09" signature in first 256 bytes.
  var Limit := Min(Int64(256), Int64(FDebugRawSize - 4));
  for var I: Int64 := 0 to Limit do begin
    if PCardinal(FDebugBase + I)^ = TD32_SIGNATURE then begin
      FTd32Base := FDebugBase + I;
      Exit(True);
    end;
  end;
end;

function TTD32FileReader.ReadDirectory: Boolean;
// CodeView v4 directory header layout:
//   +0  cbDirHeader : u16
//   +2  cbDirEntry  : u16
//   +4  cDir        : u32   (entries in THIS block)
//   +8  lfoNextDir  : u32   (TD32-relative offset of next block, or 0)
//   +12 flags       : u32
// The header is followed by `cDir * cbDirEntry` bytes of directory
// entries. If `lfoNextDir <> 0`, a second header lives there with the
// same shape, contributing more entries. We collect them all into
// FDirEntries so callers see a single flat list.
//
// Athens 36 has been observed emitting a single block even for large
// binaries (SampleApp = 21718 entries, no chain). The chain walk is in
// place for forward-compatibility with future toolchain releases.
const
  MAX_BLOCKS = 16;
begin
  Result := False;
  if FTd32Base = nil then Exit;
  SetLength(FDirEntries, 0);
  var Rel: Cardinal := PCardinal(FTd32Base + 4)^;
  for var Block := 0 to MAX_BLOCKS - 1 do begin
    var Abs_ := FTd32Base + Rel;
    if (Abs_ < FDebugBase) or (Abs_ + 16 > FDebugEnd) then Exit;
    var HeaderSize: Word := PWord(Abs_)^;
    var EntrySize: Word := PWord(Abs_ + 2)^;
    var Count: Cardinal := PCardinal(Abs_ + 4)^;
    var Next: Cardinal := PCardinal(Abs_ + 8)^;
    if (HeaderSize < 16) or (EntrySize < 12) or
       (Count > 1000000) then Exit;
    if Block = 0 then begin
      FDirBase      := Abs_ + HeaderSize;
      FDirEntrySize := EntrySize;
    end;
    var EntryStart := Abs_ + HeaderSize;
    if EntryStart + Int64(Count) * EntrySize > FDebugEnd then Exit;
    var BlockStart := Length(FDirEntries);
    SetLength(FDirEntries, BlockStart + Integer(Count));
    for var I := 0 to Integer(Count) - 1 do begin
      var P := EntryStart + I * EntrySize;
      FDirEntries[BlockStart + I].SubType  := PWord(P)^;
      FDirEntries[BlockStart + I].ModIndex := PWord(P + 2)^;
      FDirEntries[BlockStart + I].Offset   := PCardinal(P + 4)^;
      FDirEntries[BlockStart + I].Size     := PCardinal(P + 8)^;
    end;
    if Next = 0 then
      Break;
    Rel := Next;
  end;
  FDirCount := Length(FDirEntries);
  Result    := FDirCount > 0;
end;

function TTD32FileReader.ReadDirectoryEntry(Index: Integer;
  out E: TTD32DirectoryEntry): Boolean;
begin
  Result := False;
  if (Index < 0) or (Index >= Length(FDirEntries)) then Exit;
  E := FDirEntries[Index];
  Result := True;
end;

procedure TTD32FileReader.LocateNamesSection;
begin
  FNamesBase    := nil;
  FNamesSize    := 0;
  FNamesCount   := 0;
  FNamesIndexed := False;
  SetLength(FNamesByIndex, 0);
  for var I := 0 to Integer(FDirCount) - 1 do begin
    var E: TTD32DirectoryEntry;
    if not ReadDirectoryEntry(I, E) then Continue;
    if E.SubType = SST_NAMES then begin
      var P := FTd32Base + E.Offset;
      if (P < FDebugBase) or (P + 4 > FDebugEnd) then Exit;
      FNamesCount := PCardinal(P)^;
      FNamesBase  := P + 4;
      FNamesSize  := E.Size - 4;
      // Build the whole names table NOW, during the load, rather than lazily on
      // the first ResolveNameByIndex. TTD32FileReader has no lock of any kind and
      // is shared by every consumer of a module's symbols; a lazy build meant the
      // hot name-resolution path MUTATED the reader (SetLength + element writes +
      // a dictionary Add) long after publication. Two threads naming addresses in
      // the same module then raced a dynamic-array realloc, and the cache's
      // `Add` (not AddOrSetValue) could raise a duplicate-key EListError out of a
      // stackTrace. Building here makes the reader immutable once loaded, which
      // is what lets the symbol prefetcher hand a finished reader to the
      // dispatch thread without any synchronisation at all.
      BuildNamesIndex;
      Exit;
    end;
  end;
end;

procedure TTD32FileReader.BuildNamesIndex;
begin
  if FNamesIndexed or (FNamesBase = nil) then
    Exit;
  // Walk the names table once. JCL format: each name = <LenByte><Bytes><NUL>.
  // For Len > 255: 255 stored in lenbyte then actual content includes
  // 256-byte chunks until a NUL terminator is reached.
  SetLength(FNamesByIndex, FNamesCount + 1);
  var P := FNamesBase;
  var Stop := FNamesBase + FNamesSize;
  var I: Cardinal := 1;
  while (P < Stop) and (I <= FNamesCount) do begin
    var L := P^;
    Inc(P);  // past length byte
    var Start := P;
    Inc(P, L);
    // Tail: scan for NUL. JCL: "while PszName^ <> #0 do Inc(pszName, 256)".
    while (P < Stop) and (P^ <> 0) do
      Inc(P, 256);
    var ActualLen: Int64 := P - Start;
    if (Start < Stop) and (ActualLen > 0) and (ActualLen < FNamesSize) then begin
      var Buf: TBytes;
      SetLength(Buf, ActualLen);
      Move(Start^, Buf[0], ActualLen);
      FNamesByIndex[I] := DecodeTD32Name(Buf);
    end;
    Inc(P);  // past NUL terminator
    Inc(I);
  end;
  FNamesIndexed := True;
end;

function TTD32FileReader.ResolveNameByIndex(Idx: Cardinal): string;
begin
  // Pure read: FNamesByIndex is complete before the reader is published (see
  // LocateNamesSection). No cache -- an array index is cheaper than the
  // TDictionary lookup that used to front it, and removing the dictionary is
  // what makes this method side-effect free.
  Result := '';
  if (Idx >= 1) and (Idx < Cardinal(Length(FNamesByIndex))) then
    Result := FNamesByIndex[Idx];
end;

procedure TTD32FileReader.ParseSourceModule(const Entry: TTD32DirectoryEntry);
var
  SecBase: PByte;
begin
  SecBase := FTd32Base + Entry.Offset;
  if (SecBase < FDebugBase) or (SecBase + Entry.Size > FDebugEnd) then Exit;
  if Entry.Size < 4 then Exit;
  var SegCount:  Word := PWord(SecBase)^;
  var FileCount: Word := PWord(SecBase + 2)^;
  if (SegCount = 0) or (FileCount = 0) then Exit;
  if 4 + 4 * Integer(SegCount) > Integer(Entry.Size) then Exit;

  // Read first file entry (in practice Athens 36 emits one file per module).
  for var FileIdx := 0 to FileCount - 1 do begin
    var BaseSrcFile: Cardinal := PCardinal(SecBase + 4 + 4 * FileIdx)^;
    var FileEntry := SecBase + BaseSrcFile;
    if (FileEntry < SecBase) or (FileEntry + 6 > SecBase + Entry.Size) then
      Continue;

    var FSegCount: Word := PWord(FileEntry)^;
    var NameIdx: Cardinal := PCardinal(FileEntry + 2)^;
    if FSegCount = 0 then Continue;
    var BaseSrcLinesOff := FileEntry + 6;
    if BaseSrcLinesOff + 4 * Integer(FSegCount) > SecBase + Entry.Size then
      Continue;

    // Athens 36 does NOT embed a ShortString name in TFileEntry. The file
    // name is resolved via NameIndex into the NAMES subsection. Fall back
    // to a synthetic placeholder if the name lookup fails (e.g. when NAMES
    // subsection is missing or NameIndex is out of range).
    var SrcFileName := ResolveNameByIndex(NameIdx);
    if SrcFileName = '' then
      SrcFileName := Format('mod_%d', [Entry.ModIndex]);
    var BaseName := ExtractFileName(SrcFileName);
    // Record module-index -> owning unit (basename, no ext) for per-module
    // global attribution. First file entry wins (one file per module on Athens).
    if not FModIndexUnit.ContainsKey(Entry.ModIndex) then
      FModIndexUnit.Add(Entry.ModIndex, ChangeFileExt(BaseName, ''));

    // Walk per-segment line tables.
    for var Seg := 0 to FSegCount - 1 do begin
      var LineMapOff: Cardinal := PCardinal(BaseSrcLinesOff + 4 * Seg)^;
      var LineTbl := SecBase + LineMapOff;
      if (LineTbl < SecBase) or (LineTbl + 4 > SecBase + Entry.Size) then
        Continue;
      var SegIdx: Word := PWord(LineTbl)^;
      var PairCount: Word := PWord(LineTbl + 2)^;
      if PairCount = 0 then Continue;
      var OffsetsArr := LineTbl + 4;
      var LinesArr   := LineTbl + 4 + 4 * Integer(PairCount);
      if LinesArr + 2 * Integer(PairCount) > SecBase + Entry.Size then
        Continue;
      // SegIdx is 1-based and indexes the PE section table built during
      // FindDebugSection. If out of range, skip this segment.
      if (SegIdx = 0) or (SegIdx > Cardinal(Length(FSegmentVAs))) then
        Continue;
      for var P := 0 to PairCount - 1 do begin
        var Offs: Cardinal := PCardinal(OffsetsArr + 4 * P)^;
        var LineNum: Word := PWord(LinesArr + 2 * P)^;
        if (Offs = 0) or (LineNum = 0) then Continue;
        var Rva: UInt64 := SegOffsetToRva(SegIdx, Offs);
        var Loc: TSourceLocation;
        Loc.SourceFile := BaseName;
        Loc.Line       := LineNum;
        FRvaToLoc.AddOrSetValue(Rva, Loc);
        var Key := LineKey(BaseName, LineNum);
        // Keep the FIRST RVA seen for any (file,line) pair, matching MAP
        // file behavior: stable breakpoint placement at the line's earliest
        // emitted instruction.
        if not FLineToRva.ContainsKey(Key) then
          FLineToRva.Add(Key, Rva);
      end;
    end;
  end;
end;

procedure TTD32FileReader.ParseAllSourceModules;
begin
  for var I := 0 to Integer(FDirCount) - 1 do begin
    var E: TTD32DirectoryEntry;
    if not ReadDirectoryEntry(I, E) then Continue;
    if E.SubType = SST_SOURCE_MODULE then
      ParseSourceModule(E);
  end;
end;

procedure TTD32FileReader.RebuildSortedRvas;
begin
  SetLength(FSortedRvas, FRvaToLoc.Count);
  var I := 0;
  for var Rva in FRvaToLoc.Keys do begin
    FSortedRvas[I] := Rva;
    Inc(I);
  end;
  TArray.Sort<UInt64>(FSortedRvas);
end;

class function TTD32FileReader.LineKey(const FileName: string; Line: Integer): string;
begin
  Result := AnsiLowerCase(FileName) + ':' + IntToStr(Line);
end;

// Borland-style mangling, which is what dcc32 emits where dcc64 uses the
// Itanium form:
//
//   @Testtargetedge@EdgeFactorial$qqri      unit + routine
//   @Forms@TApplication@Run$qqrv            unit + class + method
//
// The `$` introduces the parameter encoding (`$qqr...`) and carries no name.
// Deliberately mirrors the Itanium demangler's presentation so a stack from a
// 32-bit target reads identically to one from a 64-bit target: the unit prefix
// is dropped for a plain routine, and a method keeps its Class.Method form.
class function TTD32FileReader.DemangleBorland(const Mangled: string;
  out InnerName, ParentName: string): Boolean;
begin
  InnerName  := '';
  ParentName := '';
  Result := False;
  if not Mangled.StartsWith('@') then
    Exit;
  var Body := Mangled.Substring(1);
  var DollarPos := Body.IndexOf('$');
  if DollarPos >= 0 then
    Body := Body.Substring(0, DollarPos);
  if Body = '' then
    Exit;
  var Parts := Body.Split(['@']);
  for var P in Parts do
    if P = '' then
      Exit;   // a stray '@' means this is not the shape we think it is
  case Length(Parts) of
    0: Exit;
    1: InnerName := Parts[0];
    2: begin
         // A unit's initialization/finalization section is presented as the
         // OWNING UNIT's name, not as the section keyword -- the same
         // special case the Itanium demangler already makes, so a main block
         // reads the same on both bitnesses. Without this, a 64-bit stack says
         // `Testtarget` where a 32-bit one says `initialization`.
         if SameText(Parts[1], 'initialization') or
            SameText(Parts[1], 'finalization') then
           InnerName := Parts[0]
         else
           InnerName := Parts[1];                   // unit + routine
       end;
  else
    InnerName  := Parts[High(Parts)];               // unit + ... + class + method
    ParentName := Parts[High(Parts) - 1];
  end;
  Result := InnerName <> '';
end;

class function TTD32FileReader.DemangleItanium(const Mangled: string;
  out InnerName, ParentName: string): Boolean;
// Itanium ABI demangler with the Delphi-relevant subset:
//   * length-prefixed source names (Source-name production)
//   * nested names `_ZN ... E`
//   * constructors / destructors (C0..C3 / D0..D2)
//   * templates `<args>` (encoded as `I ... E`)
//   * substitution back-references (S_, S0_, S1_, ...)
//   * operator names (pl, mi, ml, ... -> Delphi-friendly form)
//   * Borland-extended prefixes (_ZTR / _ZTI / _ZTS / _ZTV / _ZTT)
//
// Anything outside the name (function signature / parameter types
// after the closing E) is discarded -- the adapter only needs the
// symbol name, not the full signature.
const
  // Itanium built-in types: single letters that mark a primitive in
  // type-position (template arguments / function args). Mapped to a
  // Delphi-friendly name when surfaced via templates.
  BuiltinTypes: array[0..21] of record Code, Name: string; end = (
    (Code: 'v'; Name: 'void'),    (Code: 'b'; Name: 'Boolean'),
    (Code: 'c'; Name: 'AnsiChar'),(Code: 'a'; Name: 'ShortInt'),
    (Code: 'h'; Name: 'Byte'),    (Code: 's'; Name: 'SmallInt'),
    (Code: 't'; Name: 'Word'),    (Code: 'i'; Name: 'Integer'),
    (Code: 'j'; Name: 'Cardinal'),(Code: 'l'; Name: 'NativeInt'),
    (Code: 'm'; Name: 'NativeUInt'),
    (Code: 'x'; Name: 'Int64'),   (Code: 'y'; Name: 'UInt64'),
    (Code: 'n'; Name: '__int128'),(Code: 'o'; Name: '__uint128'),
    (Code: 'f'; Name: 'Single'),  (Code: 'd'; Name: 'Double'),
    (Code: 'e'; Name: 'Extended'),(Code: 'g'; Name: 'Extended128'),
    (Code: 'w'; Name: 'WideChar'),(Code: 'Di'; Name: 'Char'),
    (Code: 'Ds'; Name: 'Char16'));

  // Common Itanium operator codes mapped to Delphi syntax.
  Operators: array[0..16] of record Code, Name: string; end = (
    (Code: 'pl'; Name: 'operator+'),  (Code: 'mi'; Name: 'operator-'),
    (Code: 'ml'; Name: 'operator*'),  (Code: 'dv'; Name: 'operator/'),
    (Code: 'rm'; Name: 'operator mod'),
    (Code: 'eq'; Name: 'operator='),  (Code: 'ne'; Name: 'operator<>'),
    (Code: 'lt'; Name: 'operator<'),  (Code: 'le'; Name: 'operator<='),
    (Code: 'gt'; Name: 'operator>'),  (Code: 'ge'; Name: 'operator>='),
    (Code: 'aN'; Name: 'operator&='), (Code: 'oR'; Name: 'operator|='),
    (Code: 'an'; Name: 'operator and'),(Code: 'or'; Name: 'operator or'),
    (Code: 'co'; Name: 'operator not'),(Code: 'ix'; Name: 'operator[]'));

  function LookupBuiltin(const S: string): string;
  begin
    Result := '';
    for var B in BuiltinTypes do
      if B.Code = S then Exit(B.Name);
  end;

  function LookupOperator(const S: string): string;
  begin
    Result := '';
    for var O in Operators do
      if O.Code = S then Exit(O.Name);
  end;

var
  P:    Integer;
  Subs: TArray<string>;

  procedure RememberSub(const S: string);
  begin
    if (S = '') or (Length(Subs) >= 64) then Exit;
    Subs := Subs + [S];
  end;

  function ReadLenPrefixedIdent(out S: string): Boolean;
  var Len: Integer;
  begin
    Result := False;
    S := '';
    if (P > Length(Mangled)) or not CharInSet(Mangled[P], ['0'..'9']) then Exit;
    Len := 0;
    while (P <= Length(Mangled)) and CharInSet(Mangled[P], ['0'..'9']) do begin
      Len := Len * 10 + Ord(Mangled[P]) - Ord('0');
      Inc(P);
    end;
    if (Len < 1) or (P + Len - 1 > Length(Mangled)) then Exit;
    S := Copy(Mangled, P, Len);
    Inc(P, Len);
    Result := True;
  end;

  function ReadSubstitutionId: Integer;
  // Reads `S_` -> 0, `S0_` -> 1, `S1_` -> 2, ..., `SN_` -> N+1.
  // Cursor on 'S' on entry. Leaves cursor after '_' on success.
  var Id: Integer;
  begin
    Result := -1;
    if (P > Length(Mangled)) or (Mangled[P] <> 'S') then Exit;
    Inc(P);
    if (P <= Length(Mangled)) and (Mangled[P] = '_') then begin
      Inc(P);
      Exit(0);
    end;
    Id := 0;
    while (P <= Length(Mangled)) and
          (CharInSet(Mangled[P], ['0'..'9', 'A'..'Z'])) do begin
      var C := Mangled[P];
      if CharInSet(C, ['0'..'9']) then
        Id := Id * 36 + Ord(C) - Ord('0')
      else
        Id := Id * 36 + Ord(C) - Ord('A') + 10;
      Inc(P);
    end;
    if (P > Length(Mangled)) or (Mangled[P] <> '_') then Exit;
    Inc(P);
    Result := Id + 1;
  end;

  function ParseType: string; forward;

  function ParseTemplateArgs: string;
  // Parses an Itanium template-arg list, encoded as `I <arg>+ E`. Returns
  // the rendered `<arg1, arg2, ...>` string ready to be appended to the
  // template-name.
  var
    Args: TArray<string>;
    A:    string;
  begin
    Result := '';
    if (P > Length(Mangled)) or (Mangled[P] <> 'I') then Exit;
    Inc(P);
    while (P <= Length(Mangled)) and (Mangled[P] <> 'E') do begin
      A := ParseType;
      if A = '' then begin
        // Don't get stuck on an unrecognised template arg -- consume one
        // character so the outer parser advances.
        if P <= Length(Mangled) then Inc(P);
        Continue;
      end;
      Args := Args + [A];
    end;
    if (P <= Length(Mangled)) and (Mangled[P] = 'E') then
      Inc(P);
    if Length(Args) = 0 then Exit;
    Result := '<' + string.Join(', ', Args) + '>';
  end;

  function ParseType: string;
  // Subset of the Itanium <type> production sufficient to render template
  // arguments. Substitutions reuse previously stored components; built-in
  // single-letter codes map to Delphi primitive names; length-prefixed
  // identifiers are taken as user-defined type names.
  var
    SubId: Integer;
    Code:  string;
  begin
    Result := '';
    if P > Length(Mangled) then Exit;
    var C := Mangled[P];
    // Substitution back-reference.
    if C = 'S' then begin
      SubId := ReadSubstitutionId;
      if (SubId >= 0) and (SubId < Length(Subs)) then
        Result := Subs[SubId];
      Exit;
    end;
    // Length-prefixed source name -- user-defined type.
    if CharInSet(C, ['0'..'9']) then begin
      var Ident: string;
      if ReadLenPrefixedIdent(Ident) then begin
        Result := Ident;
        RememberSub(Result);
      end;
      Exit;
    end;
    // Pointer / reference qualifiers wrap a sub-type.
    if (C = 'P') or (C = 'R') or (C = 'O') then begin
      Inc(P);
      var Inner := ParseType;
      if Inner <> '' then begin
        if C = 'P' then Result := '^' + Inner
        else            Result := Inner;
        RememberSub(Result);
      end;
      Exit;
    end;
    // Nested `N ... E` inside a template arg.
    if C = 'N' then begin
      Inc(P);
      var Parts: TArray<string>;
      while (P <= Length(Mangled)) and (Mangled[P] <> 'E') do begin
        var T := ParseType;
        if T = '' then Break;
        Parts := Parts + [T];
      end;
      if (P <= Length(Mangled)) and (Mangled[P] = 'E') then Inc(P);
      if Length(Parts) > 0 then Result := string.Join('.', Parts);
      Exit;
    end;
    // Built-in primitive (single character).
    Code := C;
    Inc(P);
    Result := LookupBuiltin(Code);
    if Result <> '' then Exit;
    // 2-letter built-in (Di / Ds for Char family).
    if (P <= Length(Mangled)) and (Code = 'D') then begin
      var Code2 := Code + Mangled[P];
      var Hit := LookupBuiltin(Code2);
      if Hit <> '' then begin
        Inc(P);
        Exit(Hit);
      end;
    end;
    // Unknown -- return the single character so the outer parser can
    // tell something was consumed.
    Result := Code;
  end;

  function ReadNamePart(out Part: string): Boolean;
  // Reads one component of a nested-name: source name (with optional
  // template args), operator name, constructor / destructor marker, or
  // a substitution back-reference. Side-effect: appends a substitution
  // entry for source names (per Itanium ABI rule).
  var
    Tmpl: string;
  begin
    Result := False;
    Part := '';
    if P > Length(Mangled) then Exit;
    var C := Mangled[P];
    // Constructor / destructor markers.
    if CharInSet(C, ['C', 'D']) and (P + 1 <= Length(Mangled)) and
       CharInSet(Mangled[P + 1], ['0'..'3']) then begin
      if C = 'C' then Part := 'Create' else Part := 'Destroy';
      Inc(P, 2);
      Exit(True);
    end;
    // Substitution back-reference.
    if C = 'S' then begin
      var Id := ReadSubstitutionId;
      if (Id >= 0) and (Id < Length(Subs)) then begin
        Part := Subs[Id];
        Result := True;
      end;
      Exit;
    end;
    // Operator name (2 lowercase / mixed-case letters with known code).
    if not CharInSet(C, ['0'..'9']) and (P + 1 <= Length(Mangled)) then begin
      var Op := Copy(Mangled, P, 2);
      var OpName := LookupOperator(Op);
      if OpName <> '' then begin
        Part := OpName;
        Inc(P, 2);
        Exit(True);
      end;
    end;
    // Length-prefixed source name (optionally followed by template args).
    if not ReadLenPrefixedIdent(Part) then Exit;
    if (P <= Length(Mangled)) and (Mangled[P] = 'I') then begin
      Tmpl := ParseTemplateArgs;
      if Tmpl <> '' then
        Part := Part + Tmpl;
    end;
    RememberSub(Part);
    Result := True;
  end;

var
  Parts: TArray<string>;
  Part:  string;
begin
  Result     := False;
  InnerName  := '';
  ParentName := '';
  if Mangled = '' then Exit;
  if not Mangled.StartsWith('_Z') then Exit;
  // Itanium nested-name `_ZN ... E` (most common shape for Delphi).
  if (Length(Mangled) >= 3) and (Mangled[3] = 'N') then begin
    P := 4;
    while (P <= Length(Mangled)) and (Mangled[P] <> 'E') do begin
      if not ReadNamePart(Part) then Exit;
      Parts := Parts + [Part];
    end;
    if Length(Parts) = 0 then Exit;
    InnerName := Parts[High(Parts)];
    // Pick the closest enclosing scope as Parent. For 2-part top-level
    // procs (Unit.Proc), drop the unit so the friendly name is just
    // Proc -- mirrors MAP file convention.
    if Length(Parts) >= 3 then
      ParentName := Parts[High(Parts) - 1];
    // Special-case program / unit initialization and finalization
    // synthetic procedures: RSM keys them by the unit name, not by the
    // pseudo-method name the mangler emits. Reduce to the outermost
    // namespace component.
    if (SameText(InnerName, 'initialization') or SameText(InnerName, 'finalization'))
       and (Length(Parts) >= 2) then begin
      InnerName  := Parts[0];
      ParentName := '';
    end;
  end else begin
    P := 3;
    if not ReadLenPrefixedIdent(InnerName) then Exit;
  end;
  Result := True;
end;

procedure TTD32FileReader.HandleProcRecord(Payload: PByte; PayloadEnd: PByte;
  IsGlobal: Boolean; out NewProcName: string; out NewProcRva: UInt64;
  OwningModIndex: Integer);
begin
  NewProcName := '';
  NewProcRva  := 0;
  if PayloadEnd - Payload < 38 then Exit;
  var ProcLen: Cardinal := PCardinal(Payload + 12)^;
  var Offs:    Cardinal := PCardinal(Payload + 24)^;
  var Seg:     Word     := PWord(Payload + 28)^;
  var NameIdx: Cardinal := PCardinal(Payload + 36)^;
  if (Seg = 0) or (Seg > Cardinal(Length(FSegmentVAs))) then Exit;
  var Rva: UInt64 := SegOffsetToRva(Seg, Offs);
  NewProcRva := Rva;
  var Mangled := ResolveNameByIndex(NameIdx);
  var Inner, Parent: string;
  var Friendly: string;
  if DemangleItanium(Mangled, Inner, Parent) then begin
    if Parent <> '' then
      Friendly := Parent + '.' + Inner
    else
      Friendly := Inner;
    if Mangled.StartsWith('_ZZ') and (Parent <> '') then
      FInnerToParent.AddOrSetValue(AnsiLowerCase(Inner), Parent);
  end else if DemangleBorland(Mangled, Inner, Parent) then begin
    if Parent <> '' then
      Friendly := Parent + '.' + Inner
    else
      Friendly := Inner;
  end else
    Friendly := Mangled;
  if Friendly = '' then Exit;
  var R: TTD32ProcRange;
  R.StartRva := Rva;
  R.EndRva   := Rva + ProcLen;
  R.Name     := Friendly;
  // GPROC32/LPROC32 proctype (LF_PROCEDURE type id) sits at +32: Seg(+28,u16),
  // then 2 pad bytes, then the u32 typind, then NameIdx(+36). Kept for
  // free-function arity. (Verified empirically: the u32 at +30 reads 2 bytes low.)
  if PayloadEnd - Payload >= 36 then
    R.TypeId := PCardinal(Payload + 32)^
  else
    R.TypeId := 0;
  FProcs := FProcs + [R];
  if not FNameToRva.ContainsKey(AnsiLowerCase(Friendly)) then
    FNameToRva.Add(AnsiLowerCase(Friendly), Rva);
  NewProcName := AnsiLowerCase(Friendly);
  // Per-unit attribution: keep this proc under its OWNING unit so a same-named
  // proc in another unit (which FNameToRva first-wins drops) is still findable
  // for unit-scoped resolution. Itanium demangling drops the unit on 2-part
  // names, so the owning unit comes from the SOURCE_MODULE ModIndex, not the
  // mangled string.
  if OwningModIndex >= 0 then begin
    var OwnUnit: string;
    if FModIndexUnit.TryGetValue(Word(OwningModIndex), OwnUnit) and (OwnUnit <> '') then begin
      var UKey := AnsiLowerCase(OwnUnit) + '|' + AnsiLowerCase(Friendly);
      if not FUnitProcs.ContainsKey(UKey) then
        FUnitProcs.Add(UKey, Rva);
    end;
  end;
end;

procedure TTD32FileReader.HandlePub32(Payload: PByte; PayloadEnd: PByte);
begin
  // PUB32: Offset(4) Segment(2) Reserved(2) TypeIndex(4) then inline ShortString name.
  if PayloadEnd - Payload < 12 then Exit;
  var Offs: Cardinal := PCardinal(Payload)^;
  var Seg:  Word     := PWord(Payload + 4)^;
  if (Seg = 0) or (Seg > Cardinal(Length(FSegmentVAs))) then Exit;
  var Rva: UInt64 := SegOffsetToRva(Seg, Offs);
  var NameOff := Payload + 12;
  if NameOff >= PayloadEnd then Exit;
  var L := NameOff^;
  if (L = 0) or (NameOff + 1 + L > PayloadEnd) then Exit;
  var Buf: TBytes;
  SetLength(Buf, L);
  Move((NameOff + 1)^, Buf[0], L);
  var Mangled := DecodeTD32Name(Buf);
  var Inner, Parent: string;
  var Friendly: string;
  if DemangleItanium(Mangled, Inner, Parent) then begin
    if Parent <> '' then
      Friendly := Parent + '.' + Inner
    else
      Friendly := Inner;
  end else
    // NB: do NOT strip a bare source-name length prefix here. PUB32 publics
    // share the name table with functions/methods whose clean names already
    // come from the proc records; stripping here shadowed those with the
    // PUB32 entry and broke free-function / method resolution (Now, DoWork,
    // interface Name). Bare-name stripping is only needed for data globals
    // (HandleGData32).
    Friendly := Mangled;
  if (Friendly <> '') and not FNameToRva.ContainsKey(AnsiLowerCase(Friendly)) then
    FNameToRva.Add(AnsiLowerCase(Friendly), Rva);
end;

procedure TTD32FileReader.HandleGData32(Payload: PByte; PayloadEnd: PByte;
  OwningModIndex: Integer);
begin
  // Athens 36 GDATA32 payload (after Size+Kind): 20 bytes.
  //   Offset    : DWORD  (segment-relative)
  //   Segment   : Word   (1-based PE section)
  //   Reserved1 : Word
  //   TypeIndex : DWORD  (RSM type table index)
  //   NameIndex : DWORD  (NAMES section index)
  //   Reserved2 : DWORD
  if PayloadEnd - Payload < 20 then Exit;
  var Offs:    Cardinal := PCardinal(Payload)^;
  var Seg:     Word     := PWord(Payload + 4)^;
  var TypeIdx: Cardinal := PCardinal(Payload + 8)^;
  var NameIdx: Cardinal := PCardinal(Payload + 12)^;
  if (Seg = 0) or (Seg > Cardinal(Length(FSegmentVAs))) then Exit;
  var Rva: UInt64 := SegOffsetToRva(Seg, Offs);
  var Mangled := ResolveNameByIndex(NameIdx);
  var Inner, Parent: string;
  var Friendly: string;
  if DemangleItanium(Mangled, Inner, Parent) then begin
    if Parent <> '' then
      Friendly := Parent + '.' + Inner
    else
      Friendly := Inner;
  end else
    Friendly := StripBareSourceName(Mangled);
  if Friendly = '' then Exit;
  var G: TGlobalSymbol;
  G.Name     := Friendly;
  G.RVA      := Rva;
  G.TypeId   := Integer(TypeIdx);
  G.TypeHint := GetTypeName(TypeIdx);
  var Key := AnsiLowerCase(Friendly);

  // Unit-scoped attribution (from ALIGN_SYMBOLS, which carry a ModIndex). Must
  // run BEFORE the flat-index dedup Exit below: a same-named global in a second
  // unit hits that Exit (Key already present) and would otherwise never reach
  // the per-unit index. The demangler drops the unit on 2-part names, so the
  // owning unit comes from ModIndex -> FModIndexUnit.
  if OwningModIndex >= 0 then begin
    var OwnUnit: string;
    if FModIndexUnit.TryGetValue(Word(OwningModIndex), OwnUnit) and (OwnUnit <> '') then begin
      var UKey := AnsiLowerCase(OwnUnit) + '|' + Key;
      if not FUnitGlobals.ContainsKey(UKey) then
        FUnitGlobals.Add(UKey, G);
      var PrevUnit: string;
      if FGlobalFirstUnit.TryGetValue(Key, PrevUnit) then begin
        if not SameText(PrevUnit, OwnUnit) then
          FCollidingGlobals.AddOrSetValue(Key, True);
      end
      else
        FGlobalFirstUnit.Add(Key, OwnUnit);
    end;
  end;

  if FGlobalByName.ContainsKey(Key) then Exit;
  FGlobals := FGlobals + [G];
  FGlobalByName.Add(Key, High(FGlobals));
  // Also expose under the function-name table so EvaluateGlobalName can find
  // it via NameToRva (the global symbol's address is looked up the same way
  // a public function's RVA is).
  if not FNameToRva.ContainsKey(Key) then
    FNameToRva.Add(Key, Rva);
end;

function TTD32FileReader.AddLocalToStore(const L: TLocalSymbol): Integer;
begin
  if FLocalsCount = Length(FLocalsStore) then begin
    var NewCapacity := Length(FLocalsStore) * 2;
    if NewCapacity < 1024 then
      NewCapacity := 1024;
    SetLength(FLocalsStore, NewCapacity);
    SetLength(FLocalNextByName, NewCapacity);
    SetLength(FLocalNextByRva, NewCapacity);
  end;
  Result := FLocalsCount;
  FLocalsStore[Result]     := L;
  FLocalNextByName[Result] := -1;
  FLocalNextByRva[Result]  := -1;
  Inc(FLocalsCount);
end;

procedure TTD32FileReader.LinkLocalToChain<TKey>(
  Chains: TDictionary<TKey, TTD32LocalChain>; const Key: TKey;
  var NextLink: TArray<Integer>; Index: Integer);
begin
  var Chain: TTD32LocalChain;
  if Chains.TryGetValue(Key, Chain) then
    NextLink[Chain.Tail] := Index
  else
    Chain.Head := Index;
  Chain.Tail := Index;
  Chains.AddOrSetValue(Key, Chain);
end;

function TTD32FileReader.CollectChain(Head: Integer;
  const NextLink: TArray<Integer>): TArray<TLocalSymbol>;
begin
  var Count := 0;
  var Idx := Head;
  while Idx >= 0 do begin
    Inc(Count);
    Idx := NextLink[Idx];
  end;
  SetLength(Result, Count);
  Idx := Head;
  for var I := 0 to Count - 1 do begin
    Result[I] := FLocalsStore[Idx];
    Idx := NextLink[Idx];
  end;
end;

procedure TTD32FileReader.AppendLocalToScope(const L: TLocalSymbol;
  const ScopeName: string; ScopeRva: UInt64);
begin
  // Maintain both indexes: by-name (what the legacy lookup path uses) and the
  // RVA-keyed one that the adapter uses to disambiguate same-named procs across
  // units. Both accumulate, in parse order.
  if (ScopeName = '') and (ScopeRva = 0) then Exit;
  var Index := AddLocalToStore(L);
  if ScopeName <> '' then
    LinkLocalToChain<string>(FProcLocalChains, ScopeName, FLocalNextByName, Index);
  if ScopeRva <> 0 then
    LinkLocalToChain<UInt64>(FRvaLocalChains, ScopeRva, FLocalNextByRva, Index);
end;

procedure TTD32FileReader.HandleBpRel32(Payload: PByte; PayloadEnd: PByte;
  const ScopeName: string; ScopeRva: UInt64;
  BlockStartRva, BlockEndRva: UInt64);
begin
  // Athens 36 BPREL32 payload (after Size+Kind): 16 bytes.
  //   Offset    : Int32  (signed RBP-relative; negative = local, positive = param)
  //   TypeIndex : DWORD
  //   NameIndex : DWORD
  //   Reserved  : DWORD
  if (ScopeName = '') or (PayloadEnd - Payload < 16) then Exit;
  var Offs: Integer  := PInteger(Payload)^;
  var Typ:  Cardinal := PCardinal(Payload + 4)^;
  var Nm:   Cardinal := PCardinal(Payload + 8)^;
  var LocalName := ResolveNameByIndex(Nm);
  if LocalName = '' then Exit;
  var L: TLocalSymbol;
  L.Name      := LocalName;
  L.RbpOffset := Offs;
  L.TypeId    := Integer(Typ);
  // TD32 does not distinguish var-parameter (lkVarParam) from value
  // parameters; treat everything as lkLocal. Positive offsets are
  // parameter slots, negative offsets are locals -- caller distinguishes.
  L.Kind            := lkLocal;
  L.TypeHint        := GetTypeName(Typ);
  // TD32 BPREL32 offsets in Delphi follow the same RSM-encoded
  // convention (offset relative to the per-direction base, NOT
  // literal RBP). Setting UseDirectOffset=False lets the adapter's
  // base-adjustment path produce the correct slot address; setting it
  // to True (treating Offs as RBP-relative literal) reads the wrong
  // bytes on procs with non-trivial prologs.
  L.UseDirectOffset := False;
  L.BlockStartRva   := BlockStartRva;
  L.BlockEndRva     := BlockEndRva;
  AppendLocalToScope(L, ScopeName, ScopeRva);
end;

procedure TTD32FileReader.HandleRegister(Payload, PayloadEnd: PByte;
  const ScopeName: string; ScopeRva: UInt64;
  BlockStartRva, BlockEndRva: UInt64);
begin
  // Athens 36 S_REGISTER payload (after Size+Kind): 16 bytes.
  //   TypeIndex : DWORD  (RSM type table index)
  //   RegId     : Word   (CV register code -- Microsoft AMD64 numbering
  //                       in practice; observed values: $03, $14, $12...)
  //   NameIndex : DWORD  (NAMES section index)
  //   Reserved  : 6 bytes
  // The variable lives in a CPU register at this program point. We
  // record the slot with RegId>0 so the variables view can surface
  // it (runtime value extraction via the per-thread context register
  // table is a separate milestone).
  if (ScopeName = '') or (PayloadEnd - Payload < 16) then Exit;
  var Typ:   Cardinal := PCardinal(Payload + 0)^;
  var RegId: Word     := PWord(Payload + 4)^;
  var Nm:    Cardinal := PCardinal(Payload + 6)^;
  var LocalName := ResolveNameByIndex(Nm);
  if LocalName = '' then Exit;
  var L: TLocalSymbol;
  L.Name            := LocalName;
  L.RbpOffset       := 0;
  L.TypeId          := Integer(Typ);
  L.Kind            := lkLocal;
  L.TypeHint        := GetTypeName(Typ);
  L.UseDirectOffset := False;
  L.RegId           := RegId;
  L.BlockStartRva   := BlockStartRva;
  L.BlockEndRva     := BlockEndRva;
  AppendLocalToScope(L, ScopeName, ScopeRva);
end;

procedure TTD32FileReader.ParseSymbolStream(Base, Stop: PByte;
  IncludeGData: Boolean; OwningModIndex: Integer);
var
  ScopeStack:    TArray<string>;
  ScopeRvaStack: TArray<UInt64>;
  // Parallel to ScopeStack: the lexical-block code range for each scope level.
  // A proc level carries 0/0 (function-wide); a BLOCK32 level carries the
  // block's [start,end) RVA so locals inside it can be scope-filtered by PC.
  ScopeBlkStart: TArray<UInt64>;
  ScopeBlkEnd:   TArray<UInt64>;
begin
  var Cur := Base;
  while Cur + 4 <= Stop do begin
    var RecSize: Word := PWord(Cur)^;
    var Kind:    Word := PWord(Cur + 2)^;
    if (RecSize < 2) or (Cur + 2 + Int64(RecSize) > Stop) then Break;
    var Payload    := Cur + 4;
    var PayloadEnd := Cur + 2 + Int64(RecSize);
    case Kind of
      $0204, $0205: begin
        var Nm:  string;
        var ProcRva: UInt64;
        HandleProcRecord(Payload, PayloadEnd, Kind = $0205, Nm, ProcRva, OwningModIndex);
        ScopeStack    := ScopeStack    + [Nm];
        ScopeRvaStack := ScopeRvaStack + [ProcRva];
        ScopeBlkStart := ScopeBlkStart + [0];   // proc level: function-wide scope
        ScopeBlkEnd   := ScopeBlkEnd   + [0];
      end;
      $0207: begin                                            // BLOCK32: lexical sub-scope
        // A lexical block belongs to its enclosing procedure. INHERIT the
        // parent scope name/RVA so locals declared inside it are attributed to
        // the containing function -- not dropped. Delphi wraps every inline
        // `var x := ...` in such a block, so without this all inline-var locals
        // in named functions/methods are invisible (SampleApp IsNull's `vtype`).
        if Length(ScopeStack) > 0 then begin
          ScopeStack    := ScopeStack    + [ScopeStack[High(ScopeStack)]];
          ScopeRvaStack := ScopeRvaStack + [ScopeRvaStack[High(ScopeRvaStack)]];
        end else begin
          ScopeStack    := ScopeStack    + [''];
          ScopeRvaStack := ScopeRvaStack + [0];
        end;
        // Athens S_BLOCK32 payload (after Size+Kind): pParent(4) pEnd(4)
        // length(4)@8 offset(4)@12 segment(2)@16. The block's code range lets
        // the adapter resolve same-named inline vars in sibling/nested blocks
        // by the current PC (lexical shadowing).
        var BlkStart: UInt64 := 0;
        var BlkEnd:   UInt64 := 0;
        if PayloadEnd - Payload >= 18 then begin
          var BlkLen: Cardinal := PCardinal(Payload + 8)^;
          var BlkOff: Cardinal := PCardinal(Payload + 12)^;
          var BlkSeg: Word     := PWord(Payload + 16)^;
          if (BlkSeg >= 1) and (BlkSeg <= Cardinal(Length(FSegmentVAs))) then begin
            BlkStart := SegOffsetToRva(BlkSeg, BlkOff);
            BlkEnd   := BlkStart + BlkLen;
          end;
        end;
        ScopeBlkStart := ScopeBlkStart + [BlkStart];
        ScopeBlkEnd   := ScopeBlkEnd   + [BlkEnd];
      end;
      $0006:                                                  // END: pop
        if Length(ScopeStack) > 0 then begin
          SetLength(ScopeStack,    Length(ScopeStack)    - 1);
          SetLength(ScopeRvaStack, Length(ScopeRvaStack) - 1);
          SetLength(ScopeBlkStart, Length(ScopeBlkStart) - 1);
          SetLength(ScopeBlkEnd,   Length(ScopeBlkEnd)   - 1);
        end;
      $0203: HandlePub32(Payload, PayloadEnd);
      // $0202 GDATA32 = global data; $0201 LDATA32 = unit/program-level static
      // data. Both share the DATASYM32 payload, and Delphi emits program/unit
      // `var` globals (TheStuff, GSink, ...) as LDATA32 -- so treat them the same
      // to expose user globals (RSM was the only source for these before).
      $0202, $0201: if IncludeGData then HandleGData32(Payload, PayloadEnd, OwningModIndex);
      $0200: if Length(ScopeStack) > 0 then
               HandleBpRel32(Payload, PayloadEnd,
                 ScopeStack[High(ScopeStack)], ScopeRvaStack[High(ScopeRvaStack)],
                 ScopeBlkStart[High(ScopeBlkStart)], ScopeBlkEnd[High(ScopeBlkEnd)]);
      $0002: if Length(ScopeStack) > 0 then
               HandleRegister(Payload, PayloadEnd,
                 ScopeStack[High(ScopeStack)], ScopeRvaStack[High(ScopeRvaStack)],
                 ScopeBlkStart[High(ScopeBlkStart)], ScopeBlkEnd[High(ScopeBlkEnd)]);
      // Recognised-but-unhandled symbol kinds. The outer loop advances by
      // RecSize regardless, so listing them here is mostly documentation
      // -- but it stops future refactors from accidentally trying to
      // treat them as unknown:
      //   $0001 S_COMPILE  (compile flags, 17/binary in TestTarget)
      //   $0002 S_REGISTER (register-allocated local; decoding deferred
      //                     -- runtime value would need a register read
      //                     instead of a memory read, see KNOWN_UNKNOWNS)
      //   $0004 S_UDT      (user-defined type alias)
      //   $0005 S_SSEARCH  (compilation-unit start search marker)
      //   $0020          Borland extension (630 in TestTarget)
      //   $0024..$0026    Borland extensions (~17 each)
      //   $0027          Borland extension (9207 in TestTarget; common
      //                  per-symbol annotation, possibly an extended LDATA)
      //   $0206 S_THUNK32  (thunks)
      //   $0230          Borland extension (103 in TestTarget)
      $0001, $0004, $0005, $0020, $0024..$0027,
      $0206, $0230:
        ; // recognised, parser advances by RecSize
    end;
    Inc(Cur, 2 + Int64(RecSize));
  end;
end;

procedure TTD32FileReader.ParseAlignSymbols(const Entry: TTD32DirectoryEntry);
begin
  var Base := FTd32Base + Entry.Offset;
  if (Base < FDebugBase) or (Base + Entry.Size > FDebugEnd) then Exit;
  if Entry.Size < 4 then Exit;
  // Skip 4-byte signature. ALIGN_SYMBOLS belong to a module -> pass the ModIndex
  // so GDATA32/LDATA32 globals get attributed to their owning unit.
  ParseSymbolStream(Base + 4, Base + Entry.Size, True, Entry.ModIndex);
end;

procedure TTD32FileReader.ParseGlobalSymbols(const Entry: TTD32DirectoryEntry);
begin
  var Base := FTd32Base + Entry.Offset;
  if (Base < FDebugBase) or (Base + Entry.Size > FDebugEnd) then Exit;
  // GLOBAL_SYMBOLS has a 32-byte header (Borland TD32 variant -- larger
  // than the Microsoft sstGlobalSym SymHash header). Records start after.
  if Entry.Size <= 32 then Exit;
  ParseSymbolStream(Base + 32, Base + Entry.Size, True);
end;

procedure TTD32FileReader.ParseAllAlignSymbols;
begin
  for var I := 0 to Integer(FDirCount) - 1 do begin
    var E: TTD32DirectoryEntry;
    if not ReadDirectoryEntry(I, E) then Continue;
    case E.SubType of
      SST_ALIGN_SYMBOLS:  ParseAlignSymbols(E);
      SST_GLOBAL_SYMBOLS: ParseGlobalSymbols(E);
    end;
  end;
  // Give back the doubling slack (up to half the store). This is the only
  // producer of locals, so nothing appends after it in practice -- and if
  // something ever did, AddLocalToStore simply grows again.
  SetLength(FLocalsStore,     FLocalsCount);
  SetLength(FLocalNextByName, FLocalsCount);
  SetLength(FLocalNextByRva,  FLocalsCount);
end;

procedure TTD32FileReader.SortAndIndexProcs;
begin
  TArray.Sort<TTD32ProcRange>(FProcs,
    TComparer<TTD32ProcRange>.Construct(
      function(const A, B: TTD32ProcRange): Integer
      begin
        if A.StartRva < B.StartRva then Result := -1
        else if A.StartRva > B.StartRva then Result := 1
        else Result := 0;
      end));
end;

function TTD32FileReader.FindProcIndex(Rva: UInt64): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Result := -1;
  if Length(FProcs) = 0 then Exit;
  Lo := 0;
  Hi := High(FProcs);
  while Lo <= Hi do begin
    Mid := (Lo + Hi) div 2;
    if FProcs[Mid].StartRva <= Rva then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  if Hi < 0 then Exit;
  if (Rva >= FProcs[Hi].StartRva) and (Rva < FProcs[Hi].EndRva) then
    Result := Hi;
end;

procedure TTD32FileReader.LoadFromFile(const ExePath: string;
  OutputRvaShift: UInt64 = 0);
begin
  if FLoaded then Exit;
  FExePath := ExePath;
  FOutputRvaShift := OutputRvaShift;
  OpenMappedFile(ExePath);
  if not FindDebugSection then
    raise Exception.Create('No .debug section in ' + ExePath);
  if not FindTD32Header then
    raise Exception.Create('No TD32 signature in .debug');
  if not ReadDirectory then
    raise Exception.Create('Invalid TD32 directory');
  LocateNamesSection;
  ParseAllTypeTables;     // build FTypes / FTypeIdToRecord / FNameToTypeIdx first;
                          // ParseAllAlignSymbols then back-fills TypeHint on
                          // globals and locals using the populated tables.
  ParseAllSourceModules;
  ParseAllAlignSymbols;
  ParseImportTable;       // adds external DLL imports (kernel32.GetTickCount64
                          // etc.) to FNameToRva so the adapter can resolve
                          // them without falling back to the MAP file.
  SortAndIndexProcs;
  RebuildSortedRvas;
  FLoaded := True;
end;

function TTD32FileReader.OpenTdsMapping(const TdsPath: string): Int64;
begin
  FTdsFileHandle := CreateFileW(PChar(TdsPath), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FTdsFileHandle = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt('Cannot open %s', [TdsPath]);
  var Hi: DWORD := 0;
  var Lo: DWORD := GetFileSize(FTdsFileHandle, @Hi);
  Result := (Int64(Hi) shl 32) or Lo;
  FTdsMappingHandle := CreateFileMapping(FTdsFileHandle, nil, PAGE_READONLY, 0, 0, nil);
  if FTdsMappingHandle = 0 then
    raise Exception.Create('CreateFileMapping (.tds) failed');
  FTdsBase := MapViewOfFile(FTdsMappingHandle, FILE_MAP_READ, 0, 0, 0);
  if FTdsBase = nil then
    raise Exception.Create('MapViewOfFile (.tds) failed');
end;

procedure TTD32FileReader.LoadFromTdsFile(const TdsPath, ExePath: string;
  OutputRvaShift: UInt64 = 0);
begin
  if FLoaded then Exit;
  FExePath := ExePath;
  FOutputRvaShift := OutputRvaShift;
  // The companion binary supplies the PE section table (segment -> RVA) and the
  // import directory; FindDebugSection builds FSegmentVAs / FSecRva* from it. A
  // -VT binary has NO embedded `.debug`, so its result is ignored -- the CodeView
  // blob comes from the `.tds` mapped below.
  OpenMappedFile(ExePath);
  FindDebugSection;
  // External `.tds` CodeView offsets are stored relative to (segment - ImageBase)
  // (empirically verified: they are ImageBase lower than the embedded `.debug`
  // convention). Every CV address is computed as `offset + FSegmentVAs[seg]`, so
  // folding ImageBase into the segment VAs corrects lines, proc RVAs and globals
  // uniformly. FSecRvaStart/End/FileOff are left as true RVAs -- RvaToFilePtr uses
  // them to read the companion exe's import table.
  for var I := 0 to High(FSegmentVAs) do
    FSegmentVAs[I] := FSegmentVAs[I] + FImageBase;
  var TdsSize := OpenTdsMapping(TdsPath);
  // Point the CodeView cursor at the `.tds` blob (FB09 at offset 0). The blob spans
  // the whole file; FindTD32Header's linear scan anchors on the leading signature.
  FDebugBase    := FTdsBase;
  FDebugEnd     := FTdsBase + TdsSize;
  FDebugRawSize := Cardinal(TdsSize);
  FDebugRawOff  := 0;
  if not FindTD32Header then
    raise Exception.Create('No TD32 signature in ' + TdsPath);
  if not ReadDirectory then
    raise Exception.Create('Invalid TD32 directory in ' + TdsPath);
  LocateNamesSection;
  ParseAllTypeTables;
  ParseAllSourceModules;
  ParseAllAlignSymbols;
  ParseImportTable;       // reads the companion exe's import directory via FBase
  SortAndIndexProcs;
  RebuildSortedRvas;
  FLoaded := True;
end;

function TTD32FileReader.RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
begin
  Result := False;
  Name := '';
  var Idx := FindProcIndex(Rva);
  if Idx < 0 then Exit;
  Name := FProcs[Idx].Name;
  Result := Name <> '';
end;

function TTD32FileReader.RvaToFunctionStart(Rva: UInt64;
  out FuncRva: UInt64): Boolean;
begin
  Result := False;
  FuncRva := 0;
  var Idx := FindProcIndex(Rva);
  if Idx < 0 then Exit;
  FuncRva := FProcs[Idx].StartRva;
  Result := True;
end;

function TTD32FileReader.NameToRva(const Name: string; out Rva: UInt64): Boolean;

  function Normalize(const S: string): string;
  begin
    // Delphi mangler emits RTL helper names like `@UStrAsg` as `_UStrAsg`
    // (the `@` is not a valid C identifier character). Normalize both
    // directions so the caller can use either spelling.
    Result := AnsiLowerCase(S).Replace('@', '_');
  end;

begin
  // Exact match first.
  Result := FNameToRva.TryGetValue(Normalize(Name), Rva);
  if Result then Exit;
  // Suffix match: callers commonly pass unqualified names (`Now`) while
  // the TD32 entry carries a unit prefix (`sysutils.now`). Only triggered
  // when the caller's name is itself unqualified, so already-qualified
  // requests don't pick up a fuzzy match.
  if Name.Contains('.') then Exit;
  var Needle := '.' + Normalize(Name);
  for var KV in FNameToRva do
    if KV.Key.EndsWith(Needle) then begin
      Rva := KV.Value;
      Exit(True);
    end;
end;

function TTD32FileReader.GetEnclosingProcedure(const Inner: string;
  out Parent: string): Boolean;
begin
  Result := FInnerToParent.TryGetValue(AnsiLowerCase(Inner), Parent);
end;

function TTD32FileReader.GetEnclosingProcedureByRva(InnerRva: UInt64;
  out Parent: string): Boolean;
begin
  // TD32 NAMES stores nested procs by short name only -- no RVA index.
  // Leave RVA-keyed lookups to providers that actually parse `_ZZ`
  // mangled symbols (MapFileReader).
  Result := False;
  Parent := '';
end;

function TTD32FileReader.GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
  out ParentRva: UInt64): Boolean;
begin
  Result := False;
  ParentRva := 0;
end;

function TTD32FileReader.GetGlobals: TArray<TGlobalSymbol>;
begin
  Result := FGlobals;
end;

function TTD32FileReader.FindGlobal(const Name: string;
  out Global: TGlobalSymbol): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if not FGlobalByName.TryGetValue(AnsiLowerCase(Name), Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FGlobals)) then Exit;
  Global := FGlobals[Idx];
  Result := True;
end;

function TTD32FileReader.GlobalNameCollidesAcrossUnits(const Name: string): Boolean;
begin
  Result := (Name <> '') and FCollidingGlobals.ContainsKey(AnsiLowerCase(Name));
end;

function TTD32FileReader.FindGlobalInUnit(const Name, UnitHint: string;
  out Global: TGlobalSymbol): Boolean;
begin
  Result := False;
  Global := Default(TGlobalSymbol);
  if (Name = '') or (UnitHint = '') then Exit;
  // Key = lcase(unit)+'|'+lcase(name). UnitHint is the frame's source-unit
  // basename (from RvaToSourceLine); FUnitGlobals keys on the SOURCE_MODULE unit
  // basename -- the two match (same source file), so a plain lowercase compare
  // is enough.
  Result := FUnitGlobals.TryGetValue(
    AnsiLowerCase(UnitHint) + '|' + AnsiLowerCase(Name), Global);
end;

function TTD32FileReader.FindFuncRvaInUnit(const Name, UnitHint: string;
  out Rva: UInt64): Boolean;
begin
  Rva := 0;
  if (Name = '') or (UnitHint = '') then Exit(False);
  Result := FUnitProcs.TryGetValue(
    AnsiLowerCase(UnitHint) + '|' + AnsiLowerCase(Name), Rva);
end;

function TTD32FileReader.AllKnownProcNames: TArray<string>;
begin
  SetLength(Result, FNameToRva.Count);
  var I := 0;
  for var KV in FNameToRva do begin
    Result[I] := KV.Key;
    Inc(I);
  end;
end;

function TTD32FileReader.DiagFindSymbolRecords(const NameFilter: string): TArray<string>;
var
  Lines:      TArray<string>;
  TotalGData: Integer;
  TotalLData: Integer;
  TotalRecs:  Integer;
  TotalProc:  Integer;
  TotalBpRel: Integer;
  TotalPub:   Integer;
  NAlign:     Integer;
  NGlobalSec: Integer;
  Filter:     string;

  function UnitForMod(ModIndex: Integer): string;
  begin
    if ModIndex < 0 then
      Exit('(global-syms)');
    if not FModIndexUnit.TryGetValue(Word(ModIndex), Result) then
      Result := Format('(mod#%d)', [ModIndex]);
  end;

  function NameByIdxAt(Payload, PayloadEnd: PByte; Off: Integer): string;
  begin
    Result := '';
    if PayloadEnd - Payload < Off + 4 then
      Exit;
    Result := ResolveNameByIndex(PCardinal(Payload + Off)^);
  end;

  function PubName(Payload, PayloadEnd: PByte): string;
  begin
    Result := '';
    var NameOff := Payload + 12;
    if NameOff >= PayloadEnd then
      Exit;
    var L := NameOff^;
    if (L = 0) or (NameOff + 1 + L > PayloadEnd) then
      Exit;
    var Buf: TBytes;
    SetLength(Buf, L);
    Move((NameOff + 1)^, Buf[0], L);
    Result := DecodeTD32Name(Buf);
  end;

  procedure Emit(const Tag, Nm: string; ModIndex: Integer; Kind: Word;
    Payload, PayloadEnd: PByte);
  begin
    if Nm = '' then
      Exit;
    // Empty filter -> dump every data global ($0202/$0201) so the full
    // per-unit coverage is visible; non-data kinds stay filtered out.
    if Filter = '' then begin
      if (Kind <> $0202) and (Kind <> $0201) then
        Exit;
    end
    else if Pos(Filter, AnsiLowerCase(Nm)) = 0 then
      Exit;
    var SegInfo := '';
    if ((Kind = $0202) or (Kind = $0201) or (Kind = $0203)) and
       (PayloadEnd - Payload >= 6) then begin
      var Offs: Cardinal := PCardinal(Payload)^;
      var Seg:  Word     := PWord(Payload + 4)^;
      var Rva:  UInt64   := 0;
      if (Seg >= 1) and (Seg <= Cardinal(Length(FSegmentVAs))) then
        Rva := SegOffsetToRva(Seg, Offs);
      SegInfo := Format(' seg=%d offs=$%x rva=$%x', [Seg, Offs, Rva]);
    end;
    Lines := Lines + [Format('%-6s unit=%-24s kind=$%.4x name="%s"%s',
      [Tag, UnitForMod(ModIndex), Kind, Nm, SegInfo])];
  end;

  procedure ScanStream(Base, Stop: PByte; ModIndex: Integer; const Tag: string);
  begin
    var Cur := Base;
    while Cur + 4 <= Stop do begin
      var RecSize: Word := PWord(Cur)^;
      var Kind:    Word := PWord(Cur + 2)^;
      if (RecSize < 2) or (Cur + 2 + Int64(RecSize) > Stop) then
        Break;
      var Payload    := Cur + 4;
      var PayloadEnd := Cur + 2 + Int64(RecSize);
      Inc(TotalRecs);
      case Kind of
        $0202: begin Inc(TotalGData); Emit(Tag, NameByIdxAt(Payload, PayloadEnd, 12), ModIndex, Kind, Payload, PayloadEnd); end;
        $0201: begin Inc(TotalLData); Emit(Tag, NameByIdxAt(Payload, PayloadEnd, 12), ModIndex, Kind, Payload, PayloadEnd); end;
        $0200: begin Inc(TotalBpRel); Emit(Tag, NameByIdxAt(Payload, PayloadEnd, 8), ModIndex, Kind, Payload, PayloadEnd); end;
        $0002: Emit(Tag, NameByIdxAt(Payload, PayloadEnd, 6), ModIndex, Kind, Payload, PayloadEnd);
        $0203: begin Inc(TotalPub); Emit(Tag, PubName(Payload, PayloadEnd), ModIndex, Kind, Payload, PayloadEnd); end;
        $0204, $0205: Inc(TotalProc);
      end;
      Inc(Cur, 2 + Int64(RecSize));
    end;
  end;

begin
  SetLength(Result, 0);
  Lines      := nil;
  TotalGData := 0;
  TotalLData := 0;
  TotalRecs  := 0;
  TotalProc  := 0;
  TotalBpRel := 0;
  TotalPub   := 0;
  NAlign     := 0;
  NGlobalSec := 0;
  Filter     := AnsiLowerCase(NameFilter);
  for var I := 0 to Integer(FDirCount) - 1 do begin
    var E: TTD32DirectoryEntry;
    if not ReadDirectoryEntry(I, E) then
      Continue;
    var Base := FTd32Base + E.Offset;
    if (Base < FDebugBase) or (Base + E.Size > FDebugEnd) then
      Continue;
    case E.SubType of
      SST_ALIGN_SYMBOLS:
        if E.Size > 4 then begin
          Inc(NAlign);
          ScanStream(Base + 4, Base + E.Size, E.ModIndex, 'ALIGN');
        end;
      SST_GLOBAL_SYMBOLS:
        if E.Size > 32 then begin
          Inc(NGlobalSec);
          ScanStream(Base + 32, Base + E.Size, -1, 'GLOBAL');
        end;
    end;
  end;
  Result := Result + [Format('dir entries=%d  ALIGN_SYMBOLS streams=%d  GLOBAL_SYMBOLS streams=%d  modules=%d',
    [FDirCount, NAlign, NGlobalSec, FModIndexUnit.Count])];
  Result := Result + [Format('records walked=%d  GDATA32=%d  LDATA32=%d  BPREL32=%d  PUB32=%d  PROC=%d  matches=%d',
    [TotalRecs, TotalGData, TotalLData, TotalBpRel, TotalPub, TotalProc, Length(Lines)])];
  Result := Result + Lines;
end;

function TTD32FileReader.GetLocalsForFunction(const FunctionName: string;
  out Locals: TArray<TLocalSymbol>): Boolean;
begin
  Locals := nil;
  Result := False;
  if not FExposeLocals then Exit;
  var Chain: TTD32LocalChain;
  if not FProcLocalChains.TryGetValue(AnsiLowerCase(FunctionName), Chain) then Exit;
  Locals := CollectChain(Chain.Head, FLocalNextByName);
  Result := True;
end;

function TTD32FileReader.GetLocalsForFunctionByRva(InnerRva: UInt64;
  out Locals: TArray<TLocalSymbol>): Boolean;
begin
  Locals := nil;
  Result := False;
  if not FExposeLocals then Exit;
  var Chain: TTD32LocalChain;
  if not FRvaLocalChains.TryGetValue(InnerRva, Chain) then Exit;
  Locals := CollectChain(Chain.Head, FLocalNextByRva);
  Result := True;
end;

function TTD32FileReader.AllProcedureNames: TArray<string>;
begin
  if not FExposeLocals then begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, FProcLocalChains.Count);
  var I := 0;
  for var KV in FProcLocalChains do begin
    Result[I] := KV.Key;
    Inc(I);
  end;
end;

function TTD32FileReader.RvaToSourceLine(Rva: UInt64;
  out Loc: TSourceLocation): Boolean;
// Exact-match lookup hits the per-statement RVAs the compiler
// emitted. For arbitrary RIPs that don't line up (typically a
// return address one or two instructions past the last decoded
// line entry of a statement), fall back to the NEAREST PREVIOUS
// line entry. Without this, stepping into a callee from
// `IsNull(v); ...` and asking for the LoadMenu frame's source
// returns False -- the adapter then surfaces "unknown source" to
// VS Code even though the line table has good data a few bytes
// earlier.
//
// Binary search through FSortedRvas (built once at load time)
// keeps the lookup O(log N).
var
  Lo, Hi, Mid: Integer;
  Cand: UInt64;
begin
  Loc := Default(TSourceLocation);
  if FRvaToLoc.TryGetValue(Rva, Loc) then
    Exit(True);
  Result := False;
  if Length(FSortedRvas) = 0 then Exit;
  // Find largest entry <= Rva.
  Lo := 0;
  Hi := High(FSortedRvas);
  while Lo <= Hi do begin
    Mid := (Lo + Hi) shr 1;
    if FSortedRvas[Mid] <= Rva then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  if Hi < 0 then Exit;
  Cand := FSortedRvas[Hi];
  // The candidate line belongs to some function. If the QUERIED Rva lies past
  // that function's END it is not inside it, so the line would be borrowed from a
  // neighbouring routine -- often in a DIFFERENT UNIT, which then gets reported
  // (and opened) as the frame's source. The 4 KB gap cap alone does not catch
  // this: an inter-function gap is usually far smaller than 4 KB. The legitimate
  // case -- a return address a few bytes past the last line entry of the SAME
  // proc -- stays inside EndRva and is unaffected.
  var ProcIdx := FindProcIndex(Cand);
  if (ProcIdx >= 0) and (Rva >= FProcs[ProcIdx].EndRva) then Exit;
  // Fallback for a candidate with no covering proc record: don't propagate a hit
  // across a large gap. 4 KB is well above any typical inter-line gap.
  if (Rva - Cand) > 4096 then Exit;
  Result := FRvaToLoc.TryGetValue(Cand, Loc);
end;

function TTD32FileReader.SourceLineToRva(const FileName: string; Line: Integer;
  out Rva: UInt64): Boolean;
begin
  Result := FLineToRva.TryGetValue(LineKey(ExtractFileName(FileName), Line), Rva);
end;

function TTD32FileReader.SortedRvas: TArray<UInt64>;
begin
  Result := FSortedRvas;
end;

function TTD32FileReader.GetSourceFiles: TArray<string>;
var
  Seen: TDictionary<string, Boolean>;
begin
  SetLength(Result, 0);
  Seen := TDictionary<string, Boolean>.Create;
  try
    for var Pair in FRvaToLoc do begin
      var Key := AnsiLowerCase(Pair.Value.SourceFile);
      if (Key <> '') and not Seen.ContainsKey(Key) then begin
        Seen.Add(Key, True);
        Result := Result + [Key];
      end;
    end;
  finally
    Seen.Free;
  end;
end;

{ --------------------- TYPES / GLOBAL_TYPES section ---------------------

  Layout (Athens 36 -- empirically determined from TestTarget +
  SampleAppSingleExe, verified against JCL's older TD32 reader and
  Microsoft CodeView v4 conventions):

    +0  Version : UInt32 (= 1)
    +4  NumRecs : UInt32
    +8  Offsets : array[0..NumRecs-1] of UInt32 -- offset of each record
                  within the SECTION (i.e. relative to +0). Offsets and
                  the record area can be interleaved with the offset
                  table only by chance; in practice all offsets point
                  past the offset table.
    +8 + 4*NumRecs  Records:
        Each record:
          +0  cb       : UInt16  -- byte count of the record EXCLUDING this
                                    cb field. Total record size = cb + 2.
          +2  leafCode : UInt16  -- LF_* leaf, see jcl JclTD32.pas table:
              $0001 LF_MODIFIER, $0002 LF_POINTER, $0003 LF_ARRAY,
              $0004 LF_CLASS,    $0005 LF_STRUCTURE, $0007 LF_ENUM,
              $0008 LF_PROCEDURE, $0009 LF_MFUNCTION, $000A LF_VTSHAPE,
              $0201 LF_ARGLIST, $0204 LF_FIELDLIST,  $0207 LF_METHODLIST.
              $0030..$003A: Borland extensions (sub-records carried inside
              FIELDLIST entries from older Pascal-aware encodings).
          +4  payload  : (cb-2) bytes -- per-leaf decoding (see DecodeTypeRecord).

  Per-record payload layouts that we currently consume:

    LF_POINTER ($0002, payload 8 bytes):
      +0  attr   : UInt16
      +2  target : UInt32  -- TypeId (compiler-assigned) of the target

    LF_CLASS / LF_STRUCTURE ($0004 / $0005, payload 26 bytes):
      +0  count     : UInt16  -- number of fields in the FIELDLIST
      +2  fieldList : UInt32  -- TypeId of the LF_FIELDLIST record
      +6  property  : UInt16  -- packed property flags
      +8  derived   : UInt32  -- TypeId of LF_DERIVED list (0 if none)
      +12 vshape    : UInt32  -- TypeId of LF_VTSHAPE  (0 if none)
      +16 (4 bytes reserved, always zero so far)
      +20 nameIdx   : UInt32  -- NAMES-section index (Itanium-mangled)
      +24 size      : UInt16  -- instance size in bytes

    LF_ENUM ($0007, payload 18 bytes):
      +0  count     : UInt16
      +2  baseType  : UInt32  -- TypeId of the ordinal base
      +6  fieldList : UInt32  -- LF_FIELDLIST with LF_ENUMERATE sub-records
      +10 (4 bytes reserved)
      +14 nameIdx   : UInt32

    LF_PROCEDURE ($0008, payload 12 bytes):
      +0  retType   : UInt32
      +4  callConv  : UInt8
      +5  funcAttr  : UInt8
      +6  parmCount : UInt16
      +8  argList   : UInt32

  GDATA32 / BPREL32 records reference a TypeId. That TypeId is the
  RECORD-AREA OFFSET of the matching record (not the record index).
  FTypeIdToRecord maps the on-disk TypeId to the index in FTypes.

------------------------------------------------------------------------ }

procedure TTD32FileReader.ParseAllTypeTables;
begin
  SetLength(FTypes, 0);
  FTypeIdToRecord.Clear;
  FNameToTypeIdx.Clear;
  for var I := 0 to Integer(FDirCount) - 1 do begin
    var E: TTD32DirectoryEntry;
    if not ReadDirectoryEntry(I, E) then Continue;
    if (E.SubType = SST_TYPES) or (E.SubType = SST_GLOBAL_TYPES) then
      ParseTypeTable(E);
  end;
  PopulateClassMembers;
end;

procedure TTD32FileReader.PopulateClassMembers;
var
  P: PByte;
  Len: Integer;
begin
  for var I := 0 to High(FTypes) do begin
    if FTypes[I].Kind in [tkClass, tkStructure, tkEnum] then
      if FTypes[I].FieldListId >= $1000 then
        if GetTypeRecordPayload(FTypes[I].FieldListId, P, Len) then
          DecodeFieldList(FTypes[I], P, Len);
  end;
end;

procedure TTD32FileReader.DecodeFieldList(var Owner: TTD32TypeRecord;
  Payload: PByte; Len: Integer);
// Walks a LF_FIELDLIST payload, appending one TTD32TypeMember per LF_MEMBER
// (visible field). Other sub-record kinds are recognised so the cursor
// advances over them, but only fields populate Members today; methods,
// base-class refs, and the VMT table reference do not appear in the
// class-member view yet (separate milestones).
//
// Per-sub-record format (Athens 36, empirically):
//   LF_VFUNCTAB ($040A) -- 8 bytes:
//     leaf(2) pad(2) typeId(4)
//   LF_BCLASS   ($0400) -- 16 bytes + pad to 4-byte alignment:
//     leaf(2) typeId(4) attr(2) offset(4) pad
//   LF_MEMBER   ($0406) -- 16 byte fixed prefix + 2-byte numeric offset
//                          (variable numeric leaf, 2 bytes when < $8000)
//                          + pad to 4-byte alignment:
//     leaf(2) typeId(4) attr(2) nameIdx(4) reserved(4) offset(2) pad
//   LF_METHOD   ($0408) -- 12 bytes (no pad needed):
//     leaf(2) count(2) methodlistTypeId(4) nameIdx(4)
//   LF_ENUMERATE ($0403) -- variable: leaf(2) attr(2) value(numeric) nameIdx(4)
//   LF_STMEMBER ($0407) -- recognised, skipped for now
//   LF_NESTTYPE ($0409) -- recognised, skipped for now
//
// Pad markers $F1..$FF (CodeView padding) are skipped between records.
var
  Pos: Integer;
  M:   TTD32TypeMember;

  function ReadNumericLeaf(var At: Integer; out Value: Int64): Boolean;
  // Variable numeric leaf: bare WORD when value < $8000, otherwise
  // tag prefix indicating the storage width.
  begin
    Result := False;
    if At + 2 > Len then Exit;
    var W := PWord(Payload + At)^;
    if W < $8000 then begin
      Value := W;
      Inc(At, 2);
      Exit(True);
    end;
    // Tagged numeric leaf
    case W of
      $8001: begin // LF_CHAR (signed 8-bit)
        if At + 3 > Len then Exit;
        Value := ShortInt(Payload[At + 2]);
        Inc(At, 3);
      end;
      $8002: begin // LF_SHORT
        if At + 4 > Len then Exit;
        Value := SmallInt(PWord(Payload + At + 2)^);
        Inc(At, 4);
      end;
      $8003: begin // LF_USHORT
        if At + 4 > Len then Exit;
        Value := PWord(Payload + At + 2)^;
        Inc(At, 4);
      end;
      $8004: begin // LF_LONG
        if At + 6 > Len then Exit;
        Value := Integer(PCardinal(Payload + At + 2)^);
        Inc(At, 6);
      end;
      $8005: begin // LF_ULONG
        if At + 6 > Len then Exit;
        Value := PCardinal(Payload + At + 2)^;
        Inc(At, 6);
      end;
      $800A: begin // LF_QUADWORD
        if At + 10 > Len then Exit;
        Value := Int64(PUInt64(Payload + At + 2)^);
        Inc(At, 10);
      end;
    else
      Exit; // unsupported numeric leaf
    end;
    Result := True;
  end;

  procedure SkipPadding;
  begin
    while (Pos < Len) and (Payload[Pos] >= $F1) do
      Inc(Pos);
  end;

begin
  Pos := 0;
  while Pos + 2 <= Len do begin
    SkipPadding;
    if Pos + 2 > Len then Break;
    var SubLeaf := PWord(Payload + Pos)^;
    case SubLeaf of
      $040A: begin // LF_VFUNCTAB
        Inc(Pos, 8);
      end;
      $0400: begin // LF_BCLASS -- base class.
        // leaf(2) + type(4) + attr(2) + offset(numeric, 2 if <$8000) + 2-pad.
        // Capture the parent class TypeId so GetClassMembers can surface
        // INHERITED fields, not just the leaf class's own.
        if (Owner.BaseClassId = 0) and (Pos + 6 <= Len) then
          Owner.BaseClassId := PCardinal(Payload + Pos + 2)^;
        Inc(Pos, 12);
      end;
      $0406: begin // LF_MEMBER -- a struct field, OR a Pascal property.
                   // Borland records both as LF_MEMBER and disambiguates
                   // by the member's offset: real fields land at the
                   // compiler-assigned struct offset, properties land
                   // at offset zero with their type pointing at a
                   // $0030..$003A property descriptor.
        if Pos + 16 > Len then Break;
        M := Default(TTD32TypeMember);
        M.TypeId := PCardinal(Payload + Pos + 2)^;
        M.Attr   := PWord(Payload + Pos + 6)^;
        var NameIdxLocal := PCardinal(Payload + Pos + 8)^;
        M.Name := DecodeFriendlyTypeName(ResolveNameByIndex(NameIdxLocal));
        var CursorAfterPrefix := Pos + 16;
        var OffsetValue: Int64;
        if not ReadNumericLeaf(CursorAfterPrefix, OffsetValue) then
          Break;
        M.Offset := Cardinal(OffsetValue);
        // Walk modifier / property chains so the surfaced TypeName is
        // the actual underlying primitive / class name, not the
        // descriptor record's blank name.
        M.TypeName := GetTypeName(M.TypeId);
        // Detect property: offset=0 inside a class slot AND target
        // record is a tkModifier (Borland $0030..$003A property
        // descriptor).
        if (Owner.Kind = tkClass) and (M.Offset = 0) then begin
          var TgtIdx: Integer;
          if FTypeIdToRecord.TryGetValue(M.TypeId, TgtIdx) and
             (TgtIdx >= 0) and (TgtIdx < Length(FTypes)) and
             (FTypes[TgtIdx].Kind = tkModifier) then begin
            M.IsProperty := True;
            // Indexed (array) property: the descriptor carries a non-zero
            // index-args type at offset +6 (a u16). A plain scalar property
            // -- field- or getter-backed -- leaves it zero. Confirmed against
            // TestTarget: scalar PubCount/Caption have +6 = 0000, while the
            // indexed Item[Index] has +6 = B4B4. An indexed property cannot be
            // read without an index, so the variables view must not auto-call
            // its getter.
            // The index-args type is a u32, not a u16: a typeId whose low word
            // happened to be zero would otherwise read as "not indexed".
            if (FTypes[TgtIdx].PayloadPtr <> nil) and (FTypes[TgtIdx].PayloadLen >= 10) then
              M.IsIndexed := PCardinal(FTypes[TgtIdx].PayloadPtr + 6)^ <> 0;
            // $0035 property descriptor payload (22 bytes):
            //   +0  underlyingType : u32
            //   +4  accessKind     : u16  (4 = read backing field,
            //                              6 = read via getter method;
            //                              bit 0 set = Pascal `default`)
            //   +8  reserved       : u32  (zero)
            //   +12 reserved byte  : u8   (zero)
            //   +13 marker         : u8   ($80 -- variable-numeric tag)
            //   +14 payload        : u32  (field offset if kind=4,
            //                              else NAMES index of the
            //                              getter's fully-qualified
            //                              mangled name)
            //   +18 reserved       : u32  (zero)
            if (FTypes[TgtIdx].PayloadPtr <> nil) and
               (FTypes[TgtIdx].PayloadLen >= 18) then begin
              // accessKind is 16 bits. Reading 32 folded in the index-args
              // typeId that follows at +6, so for an INDEXED property the case
              // below never matched and the getter name was silently dropped -
              // every indexed property lost its TD32 getter binding. Bit 0
              // carries `default` and is masked out here; it is read on its own
              // right below.
              var Raw      := PWord(FTypes[TgtIdx].PayloadPtr + 4)^;
              var Kind     := Raw and $FFFE;
              M.IsDefaultProperty := (Raw and $0001) <> 0;
              var Payload14 := PCardinal(FTypes[TgtIdx].PayloadPtr + 14)^;
              case Kind of
                4: // field-backed: payload is the struct offset
                  M.Offset := Payload14;
                6: // method-backed: payload is the getter's NAMES index;
                   // resolve + demangle so ApplyDot can look up the
                   // method by name at call time.
                  M.GetterName :=
                    DecodeFriendlyTypeName(ResolveNameByIndex(Payload14));
              end;
            end;
            // The underlying value type lives at payload+0 of the
            // descriptor; resolve TypeName through that.
            if (FTypes[TgtIdx].PayloadPtr <> nil) and
               (FTypes[TgtIdx].PayloadLen >= 4) then begin
              var BaseTid := PCardinal(FTypes[TgtIdx].PayloadPtr + 0)^;
              // Keep the exact return-type id so the property's kind/size can be
              // resolved deterministically later (M.TypeId still points at the
              // descriptor record, which is useless downstream).
              M.ReturnTypeId := BaseTid;
              var BaseName := GetTypeName(BaseTid);
              if BaseName <> '' then
                M.TypeName := BaseName;
            end;
          end;
        end;
        Owner.Members := Owner.Members + [M];
        Pos := CursorAfterPrefix;
      end;
      $0408: begin // LF_METHOD
        Inc(Pos, 12);
      end;
      $0407: begin // LF_STMEMBER
        Inc(Pos, 12);
      end;
      $0409: begin // LF_NESTTYPE
        Inc(Pos, 12);
      end;
      $0403: begin // LF_ENUMERATE -- enum value
        // Borland layout (16 bytes incl. pad):
        //   leaf(2) attr(2) nameIdx(4) reserved(4) value(numeric)
        if Pos + 14 > Len then Break;
        M := Default(TTD32TypeMember);
        M.Attr   := PWord(Payload + Pos + 2)^;
        var NameIdxLocal := PCardinal(Payload + Pos + 4)^;
        M.Name := DecodeFriendlyTypeName(ResolveNameByIndex(NameIdxLocal));
        var Cursor := Pos + 12;
        var EnumValue: Int64;
        if not ReadNumericLeaf(Cursor, EnumValue) then Break;
        M.Offset := Cardinal(EnumValue);
        Owner.Members := Owner.Members + [M];
        Pos := Cursor;
      end;
    else
      // Unknown sub-record. Advance conservatively by 4 bytes so we don't
      // get stuck; this also covers Borland's $0030..$003A extensions
      // until they are studied in depth.
      Inc(Pos, 4);
    end;
  end;
end;

function TTD32FileReader.DecodeFriendlyTypeName(const Mangled: string): string;
var
  Inner, Parent, Stripped: string;
begin
  Result := '';
  if Mangled = '' then Exit;
  Stripped := Mangled;
  // Athens 36 prefixes type-record names with Borland-specific markers that
  // the Itanium demangler does not understand: `_ZTRN...` (type record),
  // `_ZTIN...` (type info), `_ZTSN...` (type name string). Strip the
  // 2-letter discriminator so DemangleItanium can read the embedded
  // `_ZN...` form.
  if Stripped.StartsWith('_ZTR') or Stripped.StartsWith('_ZTI') or
     Stripped.StartsWith('_ZTS') or Stripped.StartsWith('_ZTV') or
     Stripped.StartsWith('_ZTT') then
    Stripped := '_Z' + Copy(Stripped, 5, MaxInt);
  if DemangleItanium(Stripped, Inner, Parent) then
    Exit(Inner);
  Result := Mangled;
end;

procedure TTD32FileReader.DecodeTypeRecord(var R: TTD32TypeRecord;
  LeafCode: Word; Payload, PayloadEnd: PByte);
begin
  R.LeafCode := LeafCode;
  R.Kind     := tkUnknown;
  case LeafCode of
    $0001: begin                                    // LF_MODIFIER
      // Standard CV: attr(2) modifiedType(4). Delphi rarely emits
      // const/volatile so we only record the underlying type and
      // expose it as a transparent passthrough through GetTypeName.
      R.Kind := tkModifier;
      if PayloadEnd - Payload >= 6 then
        R.BaseTypeId := PCardinal(Payload + 2)^;
    end;
    $0006: begin                                    // LF_UNION
      // count(2) fieldList(4) property(2) size(variable)
      R.Kind := tkUnion;
      if PayloadEnd - Payload >= 12 then begin
        R.FieldListId := PCardinal(Payload + 2)^;
        // Size at +8 (2-byte numeric leaf), name follows.
        R.Size := PWord(Payload + 8)^;
        if PayloadEnd - Payload >= 14 then
          R.NameIdx := PCardinal(Payload + 10)^;
      end;
    end;
    $000A: R.Kind := tkVtShape;
    $0012: R.Kind := tkVftPath;
    $0205: R.Kind := tkDerivedList;
    $0002: begin                                    // LF_POINTER
      R.Kind := tkPointer;
      if PayloadEnd - Payload >= 6 then
        R.BaseTypeId := PCardinal(Payload + 2)^;
    end;
    $0003: begin                                    // LF_ARRAY
      R.Kind := tkArray;
      // Standard CV layout:
      //   elemtype : u32   -- payload+0
      //   idxtype  : u32   -- payload+4
      //   size     : variable numeric leaf (byte count of the array)
      //   name     : NameIdx (Borland) at payload+10 when size fits in u16
      if PayloadEnd - Payload >= 12 then begin
        R.BaseTypeId := PCardinal(Payload + 0)^;
        // size at +8 (2-byte numeric leaf when < $8000), nameIdx at +10
        var SizeWord := PWord(Payload + 8)^;
        if SizeWord < $8000 then begin
          R.Size := SizeWord;
          if PayloadEnd - Payload >= 14 then
            R.NameIdx := PCardinal(Payload + 10)^;
        end;
      end;
    end;
    $0004, $0005: begin                             // LF_CLASS / LF_STRUCTURE
      if LeafCode = $0004 then R.Kind := tkClass
      else                     R.Kind := tkStructure;
      if PayloadEnd - Payload >= 26 then begin
        R.FieldListId := PCardinal(Payload + 2)^;
        R.NameIdx     := PCardinal(Payload + 20)^;
        R.Size        := PWord(Payload + 24)^;
      end;
    end;
    $0007: begin                                    // LF_ENUM
      R.Kind := tkEnum;
      if PayloadEnd - Payload >= 18 then begin
        R.BaseTypeId  := PCardinal(Payload + 2)^;
        R.FieldListId := PCardinal(Payload + 6)^;
        R.NameIdx     := PCardinal(Payload + 14)^;
      end;
    end;
    $0008: R.Kind := tkProcedure;
    $0009: begin                                    // LF_MFUNCTION
      // Member-function signature:
      //   retType    : u32  -- payload+0
      //   classType  : u32  -- payload+4 (owning class)
      //   thisType   : u32  -- payload+8 (`Self` parameter type)
      //   callConv   : u8   -- payload+12
      //   funcAttr   : u8   -- payload+13
      //   parmCount  : u16  -- payload+14
      //   argList    : u32  -- payload+16
      //   thisAdjust : i32  -- payload+20
      R.Kind := tkMFunction;
      if PayloadEnd - Payload >= 12 then
        R.BaseTypeId := PCardinal(Payload + 0)^; // return type
    end;
    $0201: R.Kind := tkArgList;
    $0204: R.Kind := tkFieldList;
    $0207: R.Kind := tkMethodList;
    // Borland-specific TYPES leaves in $0030..$003A encode Pascal-specific
    // type descriptors. Empirically (TestTarget + SampleApp):
    //   $0030 -- property descriptor (payload+0 = underlying property type)
    //   $0031 -- NAMED ordinal subrange. payload: base(u32) | nameIdx(u32)
    //            | lo(u32) | hi(u32) | size(u16). Used for ByteBool /
    //            WordBool / LongBool (named subranges over the bool base)
    //            and user `type TFoo = lo..hi`.
    //   $0032 -- set type; payload+0 = base type, payload+4 = element type.
    //   $0033 -- NAMED array (ShortString etc). payload: elem(u32) |
    //            count(u32) | nameIdx(u32) | flags. Used for ShortString
    //            (`array[0..N] of AnsiChar` with a declared name).
    //   $0034 -- method pointer (`procedure(...) of object`). payload+0 =
    //            referenced signature; the slot is pointer-sized.
    //   $0035 -- set over enum / subrange.
    //   $0036 -- managed-type wrapper -> RawByteString
    //   $0037 -- managed-type wrapper -> Variant
    //   $0038 -- class-reference / metaclass; payload+0 = referenced class.
    //   $0039 -- managed-type wrapper -> WideString
    //   $003A -- managed-type wrapper -> string (UnicodeString)
    //
    // $0036 / $0037 / $0039 / $003A are how Borland tags parameters /
    // locals of managed types: the 4-byte payload references a runtime
    // type-info record; it does NOT carry the public type name. The leaf
    // code itself is the discriminator.
    $0036: begin
      R.Kind := tkUnknown;
      R.Name := 'RawByteString';
    end;
    $0037: begin
      R.Kind := tkUnknown;
      R.Name := 'Variant';
    end;
    $0039: begin
      R.Kind := tkUnknown;
      R.Name := 'WideString';
    end;
    $003A: begin
      R.Kind := tkUnknown;
      R.Name := 'string';
    end;
    $0031: begin
      // Named subrange. Keep the declared type name (ByteBool / WordBool /
      // LongBool / user subrange) rather than unwrapping to the base int.
      R.Kind := tkUnknown;
      if PayloadEnd - Payload >= 8 then begin
        R.BaseTypeId := PCardinal(Payload + 0)^;
        R.NameIdx    := PCardinal(Payload + 4)^;
      end;
    end;
    $0033: begin
      // Named array (ShortString and friends). nameIdx at payload+8.
      R.Kind := tkUnknown;
      if PayloadEnd - Payload >= 12 then begin
        R.BaseTypeId := PCardinal(Payload + 0)^;
        R.NameIdx    := PCardinal(Payload + 8)^;
      end;
    end;
    $0034: begin
      // Method pointer (`procedure(...) of object`). No public type name
      // in the record; tag the kind so the value formatter can render a
      // nil slot as `nil` and a live slot as a code pointer.
      R.Kind := tkMethodPtr;
      if PayloadEnd - Payload >= 4 then
        R.BaseTypeId := PCardinal(Payload + 0)^;
    end;
    $0030: begin
      // NAMED SET type. payload: base(u32, the element ordinal/enum type)
      // | nameIdx(u32) | ... | size byte. Keep the set name (TManySet)
      // and the base enum so the value formatter can decode membership.
      R.Kind := tkSet;
      if PayloadEnd - Payload >= 8 then begin
        R.BaseTypeId := PCardinal(Payload + 0)^;
        R.NameIdx    := PCardinal(Payload + 4)^;
      end;
      if (PayloadEnd - Payload >= 11) then
        R.Size := (Payload + 10)^;   // set storage size in bytes
    end;
    $0032: begin
      // Borland array descriptor. Two flavors share this leaf:
      //   +0  elemType  : u32
      //   +4  idxType   : u32  ($0031 subrange for static; UInt prim for dynamic)
      //   +8  (unused)  : u32
      //   +12 size      : CV numeric leaf
      //   +N  elemCount : u16
      // STATIC `array[lo..hi] of T`: size is a direct u16 (< $8000), count at
      // +14. DYNAMIC `array of T`: size is an escaped numeric leaf (>= $8000,
      // value -1). For the dynamic descriptor keep the historic transparent
      // passthrough so a `^...` chain still renders as `^^Element`.
      var SizeWord: Word := 0;
      if PayloadEnd - Payload >= 14 then
        SizeWord := PWord(Payload + 12)^;
      if (PayloadEnd - Payload >= 16) and (SizeWord < $8000) then begin
        R.Kind       := tkArray;
        R.BaseTypeId := PCardinal(Payload + 0)^;
        R.IdxTypeId  := PCardinal(Payload + 4)^;
        R.Size       := SizeWord;
        R.ElemCount  := PWord(Payload + 14)^;
      end
      else begin
        R.Kind := tkModifier;   // dynamic-array descriptor: transparent
        if PayloadEnd - Payload >= 4 then
          R.BaseTypeId := PCardinal(Payload + 0)^;
      end;
    end;
    $0035, $0038: begin
      R.Kind := tkModifier;
      if PayloadEnd - Payload >= 4 then
        R.BaseTypeId := PCardinal(Payload + 0)^;
    end;
  end;
  // Skip the generic NameIdx pickup when we already supplied a hard-
  // coded managed-type name above; the descriptor record has no
  // NameIdx field of its own.
  if R.Name = '' then
    R.Name := DecodeFriendlyTypeName(ResolveNameByIndex(R.NameIdx));
end;

procedure TTD32FileReader.ParseTypeTable(const Entry: TTD32DirectoryEntry);
begin
  var Base := FTd32Base + Entry.Offset;
  if (Base < FDebugBase) or (Base + Entry.Size > FDebugEnd) then Exit;
  if Entry.Size < 8 then Exit;
  var NumRecs := PCardinal(Base + 4)^;
  if NumRecs = 0 then Exit;
  var OffTbl: PByte := Base + 8;
  if 8 + UInt64(NumRecs) * 4 > Entry.Size then Exit;
  // TypeId encoding (Athens 36, empirically): sequential record index
  // biased by $1000 (CodeView convention).
  //   TypeId = $1000 + recordIndexInSection
  // TypeIds < $1000 are reserved for predefined primitives (Integer /
  // Cardinal / Boolean / ...) which do NOT live in the type table.
  // GetTypeName for those falls through to '' until a primitive table
  // is added.
  var IndexOffset := Length(FTypes);
  SetLength(FTypes, IndexOffset + Integer(NumRecs));
  for var I := 0 to Integer(NumRecs) - 1 do begin
    var OffWithinSection := PCardinal(OffTbl + I * 4)^;
    if OffWithinSection + 4 > Entry.Size then Continue;
    var Rec := Base + OffWithinSection;
    var Cb := PWord(Rec)^;
    if (Cb < 2) or (OffWithinSection + 2 + UInt64(Cb) > Entry.Size) then Continue;
    var LeafCode := PWord(Rec + 2)^;
    var R: TTD32TypeRecord;
    R := Default(TTD32TypeRecord);
    R.Index      := IndexOffset + I;
    R.PayloadPtr := Rec + 4;
    R.PayloadLen := Integer(Cb) - 2;
    DecodeTypeRecord(R, LeafCode, Rec + 4, Rec + 2 + Cb);
    FTypes[IndexOffset + I] := R;
    // Globally-unique TypeId across all TYPE sections. Bias by IndexOffset
    // so records from a second SST_TYPES section do not collide with the
    // first section's $1000+I keys. BPREL32 TypeIndex references appear
    // to be GLOBALLY biased too (TestTarget covers this -- the same TypeId
    // values seen in BPREL32 records match the post-bias entries).
    var TypeId: Cardinal := $1000 + Cardinal(IndexOffset) + Cardinal(I);
    if not FTypeIdToRecord.ContainsKey(TypeId) then
      FTypeIdToRecord.Add(TypeId, IndexOffset + I);
    if R.Name <> '' then begin
      var Key := AnsiLowerCase(R.Name);
      if not FNameToTypeIdx.ContainsKey(Key) then
        FNameToTypeIdx.Add(Key, IndexOffset + I);
    end;
  end;
end;

// Built-in Borland TD32 primitive TypeIds (TypeId < $1000). Empirically
// derived from TestTarget + SampleApp globals. The hex value encodes the
// primitive directly; there is no record in the TYPES table for these.
function PrimitiveTypeName(TypeId: Cardinal): string;
begin
  case TypeId of
    $0004: Result := 'Currency';
    $0020: Result := 'Byte';
    $0030: Result := 'Boolean';
    $0040: Result := 'Single';
    $0041: Result := 'Double';      // also covers Extended (= Double on Win64)
                                    // and TDateTime aliases
    $0061: Result := 'AnsiChar';
    $0071: Result := 'Char';        // = WideChar on Win64
    $0072: Result := 'SmallInt';
    $0073: Result := 'Word';
    $0074: Result := 'Integer';     // = LongInt
    $0075: Result := 'Cardinal';    // = LongWord / UInt32
    $0076: Result := 'Int64';       // = NativeInt on Win64
    $0077: Result := 'UInt64';      // = NativeUInt on Win64
  else
    Result := '';
  end;
end;

function TTD32FileReader.GetParentClassName(const ClassName: string;
  out Parent: string): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  Parent := '';
  if not FNameToTypeIdx.TryGetValue(AnsiLowerCase(ClassName), Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  if FTypes[Idx].BaseClassId < $1000 then Exit;
  Parent := GetTypeName(FTypes[Idx].BaseClassId);
  Result := Parent <> '';
end;

function TTD32FileReader.ArrayDimLowBound(IdxTypeId: Cardinal): Integer;
var
  Idx: Integer;
begin
  Result := 0;
  if IdxTypeId < $1000 then Exit;
  if not FTypeIdToRecord.TryGetValue(IdxTypeId, Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  if FTypes[Idx].LeafCode <> $0031 then Exit;
  // $0031 subrange index: lo is a 2-byte numeric leaf at payload+8.
  if (FTypes[Idx].PayloadPtr <> nil) and (FTypes[Idx].PayloadLen >= 10) then
    Result := SmallInt(PWord(FTypes[Idx].PayloadPtr + 8)^);
end;

function TTD32FileReader.ArrayElemByteSize(TypeId: Cardinal): Integer;
var
  Idx: Integer;
begin
  Result := 0;
  if TypeId >= $1000 then begin
    if FTypeIdToRecord.TryGetValue(TypeId, Idx) and (Idx >= 0) and (Idx < Length(FTypes)) then
      Result := Integer(FTypes[Idx].Size);
    Exit;
  end;
  // Predefined primitive ids (CodeView): size by class.
  case TypeId of
    $10, $20, $68, $69, $30:           Result := 1;  // Int8/UInt8/Bool8/(Ansi)Char
    $11, $21, $70, $71, $72, $73:      Result := 2;  // Int16/UInt16/WideChar
    $12, $22, $74, $75:                Result := 4;  // Int32/UInt32/Integer/Cardinal
    $13, $23, $76, $77:                Result := 8;  // Int64/UInt64
    $40:                               Result := 4;  // Single
    $41, $42:                          Result := 8;  // Double/Extended(stored 8)
  else
    Result := 0;
  end;
end;

function TTD32FileReader.DescribeTypeChain(TypeId: Cardinal): string;
var
  Idx: Integer;
begin
  Result := '';
  for var Depth := 0 to 8 do begin
    if TypeId < $1000 then
      Exit(Result + Format('[prim $%x = %s]', [TypeId, PrimitiveTypeName(TypeId)]));
    if not FTypeIdToRecord.TryGetValue(TypeId, Idx) or (Idx < 0) or (Idx >= Length(FTypes)) then
      Exit(Result + Format('[$%x = <not found>]', [TypeId]));
    Result := Result + Format('[$%x leaf=$%x kind=%d size=%d name="%s"] -> ',
      [TypeId, FTypes[Idx].LeafCode, Ord(FTypes[Idx].Kind), FTypes[Idx].Size, FTypes[Idx].Name]);
    if FTypes[Idx].BaseTypeId = 0 then Exit;
    TypeId := FTypes[Idx].BaseTypeId;
  end;
end;

function TTD32FileReader.GetTypeName(TypeId: Cardinal): string;
var
  Idx, TgtIdx: Integer;
begin
  // Compiler-predefined primitives live in the TypeId range below $1000
  // and are NOT stored in the type table. Decode them via the static
  // table; fall through to the record-table lookup otherwise.
  if TypeId < $1000 then
    Exit(PrimitiveTypeName(TypeId));
  Result := '';
  if not FTypeIdToRecord.TryGetValue(TypeId, Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  Result := FTypes[Idx].Name;
  // LF_MODIFIER is a transparent qualifier wrapper -- transparently
  // unwrap to the underlying type so callers see `Integer`, not the
  // empty modifier record name.
  if (Result = '') and (FTypes[Idx].Kind = tkModifier) then
    Exit(GetTypeName(FTypes[Idx].BaseTypeId));
  // Method pointer (`procedure(...) of object`) carries no public type
  // name. Surface a generic procedural label so the value formatter can
  // detect a nil slot and the variables view shows a real type instead
  // of the raw `@[rbp+N]` placeholder.
  if (Result = '') and (FTypes[Idx].Kind = tkMethodPtr) then
    Exit('procedure of object');
  // Unnamed set -- compose `set of <Element>` from the base type.
  if (Result = '') and (FTypes[Idx].Kind = tkSet) then begin
    var Elem := GetTypeName(FTypes[Idx].BaseTypeId);
    if Elem = '' then Elem := '<unknown>';
    Exit('set of ' + Elem);
  end;
  if (Result = '') and (FTypes[Idx].Kind = tkArray) then begin
    // Unnamed array. Borland nests one $0032 record per dimension via the
    // element type; flatten them into a single Pascal label
    // `array[lo1..hi1, lo2..hi2, ...] of Elem` using the per-dim element
    // count and the index subrange's lower bound.
    var Dims := '';
    var ElemId: Cardinal := 0;
    var CurIdx := Idx;
    var Guard := 0;
    var Ok := True;
    while (CurIdx >= 0) and (CurIdx < Length(FTypes)) and
          (FTypes[CurIdx].Kind = tkArray) and (Guard < 16) do begin
      Inc(Guard);
      var Cnt := FTypes[CurIdx].ElemCount;
      if Cnt = 0 then begin
        // Standard CV $0003 path carries only byte size; derive the count.
        var ElemSz := ArrayElemByteSize(FTypes[CurIdx].BaseTypeId);
        if ElemSz > 0 then
          Cnt := FTypes[CurIdx].Size div Cardinal(ElemSz);
      end;
      if Cnt = 0 then begin
        Ok := False;
        Break;
      end;
      var Lo := ArrayDimLowBound(FTypes[CurIdx].IdxTypeId);
      if Dims <> '' then Dims := Dims + ', ';
      Dims := Dims + Format('%d..%d', [Lo, Lo + Integer(Cnt) - 1]);
      ElemId := FTypes[CurIdx].BaseTypeId;
      var NextIdx: Integer;
      if not FTypeIdToRecord.TryGetValue(ElemId, NextIdx) then
        NextIdx := -1;
      CurIdx := NextIdx;
    end;
    if Ok and (Dims <> '') and (ElemId <> 0) then begin
      var ElemName := GetTypeName(ElemId);
      if ElemName = '' then ElemName := '<unknown>';
      Result := Format('array[%s] of %s', [Dims, ElemName]);
    end
    else begin
      var Elem := GetTypeName(FTypes[Idx].BaseTypeId);
      if Elem = '' then Elem := '<unknown>';
      if FTypes[Idx].Size > 0 then
        Result := Format('array[0..%d] of %s', [FTypes[Idx].Size - 1, Elem])
      else
        Result := 'array of ' + Elem;
    end;
  end;
  if (Result = '') and (FTypes[Idx].Kind = tkPointer) then begin
    // Unnamed pointer -- look up the target type. In Delphi a "class
    // reference" variable (`Foo: TFoo`) is encoded as a pointer to the
    // class instance record, so the user-facing type is the class name
    // without a leading `^`. Pointers to records / primitives keep the
    // `^TName` shape per the Delphi syntax for pointer types.
    var Target := GetTypeName(FTypes[Idx].BaseTypeId);
    if Target <> '' then begin
      var IsClassRef := False;
      if FTypeIdToRecord.TryGetValue(FTypes[Idx].BaseTypeId, TgtIdx)
         and (TgtIdx >= 0) and (TgtIdx < Length(FTypes)) then
        IsClassRef := FTypes[TgtIdx].Kind = tkClass;
      if IsClassRef then
        Result := Target
      else
        Result := '^' + Target;
    end;
  end;
end;

function TTD32FileReader.GetTypeRecord(TypeId: Cardinal;
  out Rec: TTD32TypeRecord): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if FTypeIdToRecord.TryGetValue(TypeId, Idx) and
     (Idx >= 0) and (Idx < Length(FTypes)) then begin
    Rec := FTypes[Idx];
    Result := True;
  end;
end;

function TTD32FileReader.DiagResolveName(Idx: Cardinal): string;
begin
  Result := ResolveNameByIndex(Idx);
end;

function TTD32FileReader.FindTypeByName(const Name: string;
  out Rec: TTD32TypeRecord): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if FNameToTypeIdx.TryGetValue(AnsiLowerCase(Name), Idx) and
     (Idx >= 0) and (Idx < Length(FTypes)) then begin
    Rec := FTypes[Idx];
    Result := True;
  end;
end;

function TTD32FileReader.GetTypeRecordPayload(TypeId: Cardinal;
  out Payload: PByte; out Len: Integer): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  Payload := nil;
  Len := 0;
  if not FTypeIdToRecord.TryGetValue(TypeId, Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  Payload := FTypes[Idx].PayloadPtr;
  Len     := FTypes[Idx].PayloadLen;
  Result  := (Payload <> nil) and (Len > 0);
end;

function TTD32FileReader.GetTypeSize(const TypeName: string;
  out Size: Integer): Boolean;
var
  Idx: Integer;
begin
  Size   := 0;
  Result := False;
  if TypeName = '' then Exit;
  // Pointer-sized families: class instance, interface, string handle,
  // dyn-array handle, raw pointer. All 8 bytes on Win64.
  if (TypeName[1] = '^') or SameText(TypeName, 'Pointer') or
     ((Length(TypeName) >= 2) and (TypeName[1] = 'I') and
      CharInSet(TypeName[2], ['A'..'Z'])) then begin
    Size := 8;
    Exit(True);
  end;
  // Named record / structure / class: exact byte size from the TYPES
  // record (LF_CLASS / LF_STRUCTURE store Size at decode time).
  if FNameToTypeIdx.TryGetValue(AnsiLowerCase(TypeName), Idx) and
     (Idx >= 0) and (Idx < Length(FTypes)) and (FTypes[Idx].Size > 0) then begin
    Size := Integer(FTypes[Idx].Size);
    Exit(True);
  end;
end;

function TTD32FileReader.GetClassMembers(const TypeName: string;
  out Members: TArray<TClassMember>; PreferInstanceSize: Integer): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  SetLength(Members, 0);
  if not FNameToTypeIdx.TryGetValue(AnsiLowerCase(TypeName), Idx) then begin
    // Compiler-generated closure / helper types: the source, the runtime VMT
    // ClassName and the RSM all use `$` (e.g. `Foo$ActRec`), but TD32's demangled
    // type name uses `_` (the Itanium-mangled form, `Foo_ActRec`). Retry with
    // `$`->`_` so a `$`-named class from the VMT/RSM resolves against TD32 too --
    // this is what lets closure captured fields come from TD32 (and thus a BPL),
    // not only the mono `.rsm`.
    if not (TypeName.Contains('$') and
            FNameToTypeIdx.TryGetValue(AnsiLowerCase(TypeName.Replace('$', '_')), Idx)) then
      Exit;
  end;
  // Two classes can share a bare name (Data.DB.TFields vs the nested
  // System.Classes.TFieldsCache.TFields). FNameToTypeIdx kept only the first,
  // so a caller holding the OBJECT's real instance size (read from its VMT) can
  // pin the right record: scan every same-named class type for the one whose
  // declared Size matches. This is the object's actual size, not a guess; the
  // only case it cannot separate is two records with identical name AND size,
  // which TD32 leaves indistinguishable (it records neither VMT nor unit).
  if PreferInstanceSize > 0 then begin
    var Key := AnsiLowerCase(TypeName);
    // The object's runtime vmtInstanceSize counts the 8-byte VMT self-pointer;
    // the TD32 LF_CLASS Size does not always (observed: Data.DB.TFields is 72 at
    // runtime, 64 in TD32). Accept either, preferring an exact match, so the
    // record is still pinned deterministically to the object's real class.
    var Chosen := -1;
    for var I := 0 to High(FTypes) do begin
      if (FTypes[I].Kind = tkEnum) or (AnsiLowerCase(FTypes[I].Name) <> Key) then
        Continue;
      var Sz := Integer(FTypes[I].Size);
      if Sz = PreferInstanceSize then begin
        Chosen := I;
        Break;   // exact match wins outright
      end;
      if (Sz = PreferInstanceSize - 8) and (Chosen < 0) then
        Chosen := I;
    end;
    if Chosen >= 0 then
      Idx := Chosen;
  end;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  // For enums we don't surface members through IClassMemberProvider;
  // they go via IEnumInfoProvider instead.
  if FTypes[Idx].Kind = tkEnum then Exit;
  // Collect base-class members FIRST (so inherited fields appear above the
  // leaf's own), walking the LF_BCLASS chain. Guard against cycles / depth.
  AppendClassMembersByIdx(Idx, Members, 0);
  Result := Length(Members) > 0;
end;

procedure TTD32FileReader.AppendClassMembersByIdx(Idx: Integer;
  var Members: TArray<TClassMember>; Depth: Integer);
begin
  if (Depth > 16) or (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  // Base class first -> inherited fields precede the leaf's own.
  var BaseId := FTypes[Idx].BaseClassId;
  if BaseId >= $1000 then begin
    var BIdx: Integer;
    if FTypeIdToRecord.TryGetValue(BaseId, BIdx) then
      AppendClassMembersByIdx(BIdx, Members, Depth + 1);
  end;
  for var I := 0 to High(FTypes[Idx].Members) do begin
    var M: TClassMember;
    M := Default(TClassMember);
    M.Name        := FTypes[Idx].Members[I].Name;
    M.TypeName    := FTypes[Idx].Members[I].TypeName;
    M.FieldOffset := Integer(FTypes[Idx].Members[I].Offset);
    if FTypes[Idx].Members[I].IsProperty then
      M.Kind := cmkProperty
    else
      M.Kind := cmkField;
    M.TypeId     := Integer(FTypes[Idx].Members[I].TypeId);
    M.GetterName := FTypes[Idx].Members[I].GetterName;
    M.IsIndexed  := FTypes[Idx].Members[I].IsIndexed;
    M.IsDefaultProperty := FTypes[Idx].Members[I].IsDefaultProperty;
    M.DeclClass  := FTypes[Idx].Name;  // the class at this hierarchy level
    // The effective type id is the property's RETURN-type id when present
    // (M.TypeId for a property still points at the descriptor record), else the
    // field's own type id. Resolve kind/size from that exact id -- deterministic
    // where same-named types would otherwise collide.
    var EffId := FTypes[Idx].Members[I].ReturnTypeId;
    if EffId = 0 then
      EffId := FTypes[Idx].Members[I].TypeId;
    M.TypeKind := TypeKindById(EffId);
    M.TypeSize := TypeSizeById(EffId);
    Members := Members + [M];
  end;
end;

function TTD32FileReader.TypeKindById(TypeId: Cardinal; Depth: Integer): Byte;
var
  Idx: Integer;
begin
  Result := 0;
  // Primitives (id < $1000) have canonical, collision-free names; leave them to
  // the name path (which also routes float -> XMM). Only the named-type space is
  // ambiguous, and that is exactly what FTypeIdToRecord disambiguates.
  if (TypeId < $1000) or (Depth > 8) then Exit;
  if not FTypeIdToRecord.TryGetValue(TypeId, Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  // Follow one alias/modifier level to the underlying type (e.g.
  // `type NullableInteger = type Variant`), mirroring GetTypeName.
  if (FTypes[Idx].Kind = tkModifier) and (FTypes[Idx].BaseTypeId <> 0) then
    Exit(TypeKindById(FTypes[Idx].BaseTypeId, Depth + 1));
  case FTypes[Idx].Kind of
    tkClass:     Result := 7;   // tkClass
    tkStructure: Result := 14;  // tkRecord
    tkEnum:      Result := 3;   // tkEnumeration
    tkSet:       Result := 6;   // tkSet
    tkPointer: begin
      // A Delphi class-typed value is internally a POINTER to the class layout,
      // yet its TTypeKind is tkClass (matching GetTypeName, which strips the
      // caret, and LookupTypeKind by name). Deref one level: a pointee that is a
      // class -> tkClass; anything else (^TRecord, PInteger) stays tkPointer.
      var PtIdx: Integer;
      if (FTypes[Idx].BaseTypeId >= $1000) and
         FTypeIdToRecord.TryGetValue(FTypes[Idx].BaseTypeId, PtIdx) and
         (PtIdx >= 0) and (PtIdx < Length(FTypes)) and
         (FTypes[PtIdx].Kind = tkClass) then
        Result := 7    // tkClass
      else
        Result := 20;  // tkPointer
    end;
  end;
end;

function TTD32FileReader.TypeSizeById(TypeId: Cardinal): Integer;
begin
  // ArrayElemByteSize already resolves primitives by CV id and named types
  // exactly via FTypeIdToRecord -- reuse it as the byte-size-by-id oracle.
  Result := ArrayElemByteSize(TypeId);
end;

function TTD32FileReader.TryGetFreeFunctionParamCount(const FuncName: string;
  out Count: Integer): Boolean;
begin
  Result := False;
  Count  := 0;
  if FuncName = '' then Exit;
  // Name -> RVA -> the GPROC32/LPROC32 range -> its LF_PROCEDURE type id.
  var Rva: UInt64;
  if not FNameToRva.TryGetValue(AnsiLowerCase(FuncName), Rva) then Exit;
  var ProcIdx := FindProcIndex(Rva);
  if (ProcIdx < 0) or (ProcIdx >= Length(FProcs)) then Exit;
  var Tid := FProcs[ProcIdx].TypeId;
  if Tid < $1000 then Exit;
  var Idx: Integer;
  if not FTypeIdToRecord.TryGetValue(Tid, Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  // Only a genuine LF_PROCEDURE signature answers here. parmCount is the u16 at
  // payload+6 (retType u32, callConv u8, funcAttr u8, then parmCount).
  if FTypes[Idx].Kind <> tkProcedure then Exit;
  if (FTypes[Idx].PayloadPtr = nil) or (FTypes[Idx].PayloadLen < 8) then Exit;
  Count  := PWord(FTypes[Idx].PayloadPtr + 6)^;
  Result := True;
end;

function TTD32FileReader.TryGetMethodParams(const ClassName, MethodName: string;
  out Params: TArray<TMethodParam>; out HasSelf: Boolean): Boolean;

  function ResolveClassIdx(out Idx: Integer): Boolean;
  begin
    // Same `$`->`_` retry GetClassMembers uses: the VMT/RSM class name carries
    // `$` (Foo$ActRec) while TD32 demangles it to `_` (Foo_ActRec).
    Result := FNameToTypeIdx.TryGetValue(AnsiLowerCase(ClassName), Idx);
    if not Result and ClassName.Contains('$') then
      Result := FNameToTypeIdx.TryGetValue(
        AnsiLowerCase(ClassName.Replace('$', '_')), Idx);
  end;

  // Walk the class FIELDLIST for an LF_METHOD ($0408) / LF_ONEMETHOD ($040B)
  // named MethodName; yield its LF_MFUNCTION type id. Sub-record sizing mirrors
  // DecodeFieldList. Conservative: an unrecognised leaf stops the walk.
  function FindMethodMFunction(FieldListId: Cardinal; out MFunId: Cardinal): Boolean;
  var
    P: PByte; Len: Integer;
  begin
    Result := False; MFunId := 0;
    if not GetTypeRecordPayload(FieldListId, P, Len) then Exit;
    var Pos := 0;
    while Pos + 2 <= Len do begin
      while (Pos < Len) and (P[Pos] >= $F1) do Inc(Pos);   // CV padding
      if Pos + 2 > Len then Break;
      case PWord(P + Pos)^ of
        $040A: Inc(Pos, 8);                                 // LF_VFUNCTAB
        $0400: Inc(Pos, 12);                                // LF_BCLASS
        $0407, $0409: Inc(Pos, 8);                          // LF_STMEMBER / LF_NESTTYPE
        $0406: begin                                        // LF_MEMBER + numeric offset
          if Pos + 18 > Len then Break;
          var C := Pos + 16;
          if PWord(P + C)^ < $8000 then Inc(C, 2) else Inc(C, 6);
          Pos := C;
        end;
        $0408: begin                                        // LF_METHOD -> methodlist
          if Pos + 12 > Len then Break;
          var Nm := DecodeFriendlyTypeName(ResolveNameByIndex(PCardinal(P + Pos + 8)^));
          if SameText(Nm, MethodName) then begin
            var MP: PByte; var ML: Integer;
            // Borland LF_METHODLIST entry: attr(2) + mfunction(4). First entry wins.
            if GetTypeRecordPayload(PCardinal(P + Pos + 4)^, MP, ML) and (ML >= 6) then begin
              MFunId := PCardinal(MP + 2)^;
              Exit(MFunId <> 0);
            end;
          end;
          Inc(Pos, 12);
        end;
        $040B: begin                                        // LF_ONEMETHOD -> direct mfunction
          if Pos + 12 > Len then Break;
          var Nm := DecodeFriendlyTypeName(ResolveNameByIndex(PCardinal(P + Pos + 8)^));
          if SameText(Nm, MethodName) then begin
            MFunId := PCardinal(P + Pos + 4)^;
            Exit(MFunId <> 0);
          end;
          Inc(Pos, 12);
        end;
      else
        Break;                                              // unknown leaf: stop
      end;
    end;
  end;

  // Decode LF_MFUNCTION -> LF_ARGLIST. Borland ARGLIST: count(u16) + count*type(u32).
  function DecodeMFunction(MFunId: Cardinal): Boolean;
  var
    P: PByte; Len: Integer;
  begin
    Result := False;
    if not GetTypeRecordPayload(MFunId, P, Len) or (Len < 20) then Exit;
    HasSelf := PCardinal(P + 8)^ <> 0;                      // thisType (0 = no Self)
    var AP: PByte; var AL: Integer;
    if not GetTypeRecordPayload(PCardinal(P + 16)^, AP, AL) or (AL < 2) then
      Exit(True);                                           // valid signature, no params
    var N := PWord(AP)^;
    for var I := 0 to Integer(N) - 1 do begin
      if 2 + I * 4 + 4 > AL then Break;
      var Prm := Default(TMethodParam);
      Prm.TypeId   := PCardinal(AP + 2 + I * 4)^;
      // GetTypeName already resolves an object-reference param (modelled as a
      // pointer-to-class, `TWidget` -> `^TWidget`) to the class name, so it
      // displays + expands as the instance.
      Prm.TypeName := GetTypeName(Prm.TypeId);
      Params := Params + [Prm];
    end;
    Result := True;
  end;

begin
  Result := False;
  SetLength(Params, 0);
  HasSelf := False;
  var Idx: Integer;
  if not ResolveClassIdx(Idx) or (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  if FTypes[Idx].FieldListId < $1000 then Exit;
  var MFunId: Cardinal;
  if not FindMethodMFunction(FTypes[Idx].FieldListId, MFunId) then Exit;
  Result := DecodeMFunction(MFunId);
end;

function TTD32FileReader.LookupEnumInfo(const TypeName: string;
  out Info: TRsmEnumInfo): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  Info := Default(TRsmEnumInfo);
  if not FNameToTypeIdx.TryGetValue(AnsiLowerCase(TypeName), Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  // SET type: report Kind=6 (tkSet) AND populate the member names from the
  // base enum directly. The base TypeId may be the enum, or a modifier /
  // subrange wrapping it -- unwrap until an enum (or run out). Populating
  // Names here lets the formatter decode membership without a second
  // name-keyed lookup that can miss when the base has no public name.
  if FTypes[Idx].Kind = tkSet then begin
    Info.Kind     := 6;  // System.TypInfo.tkSet
    Info.IsValid  := True;
    Info.MinValue := 0;
    if FTypes[Idx].Size > 0 then
      Info.MaxValue := Integer(FTypes[Idx].Size) * 8 - 1
    else
      Info.MaxValue := 63;
    var BaseId := FTypes[Idx].BaseTypeId;
    var Guard := 0;
    var BIdx: Integer;
    while (BaseId >= $1000) and FTypeIdToRecord.TryGetValue(BaseId, BIdx) and
          (BIdx >= 0) and (BIdx < Length(FTypes)) and (Guard < 8) do begin
      if FTypes[BIdx].Kind = tkEnum then begin
        Info.BaseTypeName := FTypes[BIdx].Name;
        var EMin := MaxInt;
        var EMax := -MaxInt;
        for var M in FTypes[BIdx].Members do begin
          var V := Integer(M.Offset);
          if V < EMin then EMin := V;
          if V > EMax then EMax := V;
        end;
        if EMin <= EMax then begin
          Info.MinValue := EMin;
          SetLength(Info.Names, EMax - EMin + 1);
          for var M in FTypes[BIdx].Members do
            Info.Names[Integer(M.Offset) - EMin] := M.Name;
        end;
        Break;
      end;
      BaseId := FTypes[BIdx].BaseTypeId;  // unwrap modifier/subrange
      Inc(Guard);
    end;
    Exit(True);
  end;
  if FTypes[Idx].Kind <> tkEnum then Exit;
  Info.Kind     := 3; // System.TypInfo.tkEnumeration
  Info.IsValid  := True;
  Info.MinValue := MaxInt;
  Info.MaxValue := -MaxInt;
  SetLength(Info.Names, Length(FTypes[Idx].Members));
  // LF_ENUMERATE sub-records each carry a name + ordinal value. Walk
  // them, build a contiguous Names[] indexed by (value - MinValue), and
  // record the min/max bounds so the variables view can map ordinals to
  // labels the same way it does for RSM enums.
  for var M in FTypes[Idx].Members do begin
    var V := Integer(M.Offset);
    if V < Info.MinValue then Info.MinValue := V;
    if V > Info.MaxValue then Info.MaxValue := V;
  end;
  if Info.MinValue > Info.MaxValue then Exit;
  SetLength(Info.Names, Info.MaxValue - Info.MinValue + 1);
  for var M in FTypes[Idx].Members do
    Info.Names[Integer(M.Offset) - Info.MinValue] := M.Name;
  Result := True;
end;

function TTD32FileReader.EnumValueToOrdinal(const TypeName, ValueName: string;
  out Ordinal: Integer; out EnumTypeName: string): Boolean;
var
  Info: TRsmEnumInfo;
begin
  Result := False;
  Ordinal := 0;
  EnumTypeName := '';
  // Reuse LookupEnumInfo's contiguous Names[] (built from LF_ENUMERATE members,
  // unwrapping a set to its base enum). Ordinal = MinValue + index.
  if not LookupEnumInfo(TypeName, Info) then Exit;
  for var I := 0 to High(Info.Names) do
    if SameText(Info.Names[I], ValueName) then begin
      Ordinal := Info.MinValue + I;
      if Info.BaseTypeName <> '' then
        EnumTypeName := Info.BaseTypeName
      else
        EnumTypeName := TypeName;
      Exit(True);
    end;
end;

function TTD32FileReader.TryResolveEnumLiteral(const Name: string;
  out Ordinal: Integer; out EnumTypeName: string): Boolean;
begin
  Result := False;
  Ordinal := 0;
  EnumTypeName := '';
  // Unqualified enum literal (e.g. `wmRunning`): scan every enum type's
  // LF_ENUMERATE members; first match wins (mirrors the RSM provider). The
  // member Offset is the ordinal value, the member Name the literal.
  for var I := 0 to High(FTypes) do
    if FTypes[I].Kind = tkEnum then
      for var M in FTypes[I].Members do
        if SameText(M.Name, Name) then begin
          Ordinal      := Integer(M.Offset);
          EnumTypeName := FTypes[I].Name;
          Exit(True);
        end;
end;

// System.TypInfo.TTypeKind ordinal for a built-in scalar type, or 0 if the name
// is not a primitive. A primitive must NEVER be classified as a structure: some
// TD32 type tables carry a STRUCTURE literally named `UInt64` (single field
// `m_value: UInt64`), which otherwise makes a plain UInt64 field (e.g.
// Application.Handle) drill into itself without end.
function PrimitiveTypeKindOrdinal(const Name: string): Byte;
begin
  for var N in ['integer', 'cardinal', 'longint', 'longword', 'smallint',
                'word', 'shortint', 'byte', 'fixedint', 'fixeduint'] do
    if SameText(N, Name) then Exit(1);    // tkInteger
  for var N in ['int64', 'uint64', 'nativeint', 'nativeuint'] do
    if SameText(N, Name) then Exit(16);   // tkInt64
  for var N in ['single', 'double', 'extended', 'currency', 'comp', 'tdatetime'] do
    if SameText(N, Name) then Exit(4);    // tkFloat
  for var N in ['boolean', 'bytebool', 'wordbool', 'longbool'] do
    if SameText(N, Name) then Exit(3);    // tkEnumeration
  for var N in ['char', 'widechar', 'ucs2char'] do
    if SameText(N, Name) then Exit(9);    // tkWChar
  for var N in ['string', 'unicodestring'] do
    if SameText(N, Name) then Exit(18);   // tkUString
  for var N in ['ansistring', 'utf8string', 'rawbytestring'] do
    if SameText(N, Name) then Exit(10);   // tkLString
  if SameText('ansichar',   Name) then Exit(2);    // tkChar
  if SameText('widestring', Name) then Exit(11);   // tkWString
  if SameText('pointer',    Name) then Exit(20);   // tkPointer
  Result := 0;
end;

function TTD32FileReader.LookupTypeKind(const TypeName: string): Byte;
var
  Idx: Integer;
begin
  Result := PrimitiveTypeKindOrdinal(TypeName);
  if Result <> 0 then Exit;
  if not FNameToTypeIdx.TryGetValue(AnsiLowerCase(TypeName), Idx) then Exit;
  if (Idx < 0) or (Idx >= Length(FTypes)) then Exit;
  // System.TypInfo.TTypeKind ordinal mapping.
  case FTypes[Idx].Kind of
    tkClass:     Result := 7;   // tkClass
    tkStructure: Result := 14;  // tkRecord
    tkEnum:      Result := 3;   // tkEnumeration
    tkSet:       Result := 6;   // tkSet
    tkPointer:   Result := 20;  // tkPointer
  end;
end;

end.
