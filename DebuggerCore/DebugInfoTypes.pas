unit DebugInfoTypes;

// Shared types used by all debug-info providers (MAP, RSM, future PDB/DWARF).
// Provider units implement the I*Provider interfaces defined here and are
// aggregated by TDebugInfoSet (see DebugInfoSet.pas).

interface

uses
  System.SysUtils;

type
  TSourceLocation = record
    SourceFile: string; // filename only, no path
    Line:       Integer;
  end;

  TLocalKind = (
    lkLocal,     // body-declared local (RSM tag 0x20)
    lkVarParam   // var/reference parameter (RSM tag 0x22) -- the stack slot holds a pointer to the real storage
  );

  TLocalSymbol = record
    Name:            string;
    RbpOffset:       Integer;    // signed offset from RBP; may be negative (locals) or positive (parameters)
    TypeId:          Integer;    // raw type identifier from the record; references a per-procedure type table (not yet fully decoded). Same for variables of the same type.
    Kind:            TLocalKind;
    TypeHint:        string;     // optional type name, empty if unknown
    UseDirectOffset: Boolean;    // True for TYPEREF_MARKER_MAIN ($46) locals: RbpOffset is the direct RBP slot, not RSM-encoded (no div-2/FrameSize)
    RegId:           Word;       // 0 = stack-allocated (RbpOffset is valid).
                                 // > 0 = register-allocated, RegId encodes
                                 // the CV register code (Borland Athens 36
                                 // uses Microsoft CV register IDs in
                                 // practice; runtime value extraction is
                                 // a separate milestone).
    // Lexical-block scope range [BlockStartRva, BlockEndRva). A Delphi inline
    // `var x := ...` lives in a CV S_BLOCK32 sub-scope; the local is only live
    // when the frame PC is inside this range. 0/0 means function-wide (params,
    // traditional `var`-block locals, and any provider that has no block info).
    BlockStartRva:   UInt64;
    BlockEndRva:     UInt64;
  end;

  TGlobalSymbol = record
    Name:     string;
    RVA:      UInt64;
    TypeId:   Integer;  // index into the user type table (same encoding as locals: 2 * position)
    TypeHint: string;   // resolved type name, empty if unknown
  end;

  // Why a given address does or does not have symbols.
  //
  // A frame the debugger cannot name used to render identically -- an empty
  // function name, or a bare `0x...` -- in three genuinely different situations,
  // each with a different user action. Reporting WHICH one applies turns a silent
  // blank into a diagnosis:
  //   saUnknownModule -- nothing is mapped there as far as the debugger knows
  //                      (module never announced, or already unloaded).
  //   saNoSymbols     -- the module is known but ships no debug information in
  //                      any supported format: rebuild it with debug info.
  //   saIndexing      -- symbols exist and a provider is still building its
  //                      index: retry in a moment.
  //   saLoaded        -- symbols are loaded; a missing name means this address
  //                      simply is not covered by them (e.g. RTL stub code).
  TSymbolAvailability = (
    saUnknownModule,
    saNoSymbols,
    saIndexing,
    saLoaded
  );

// Stable wire spelling of TSymbolAvailability, shared by every frontend so the
// DAP and MCP surfaces never drift into two different vocabularies.
function SymbolAvailabilityName(Availability: TSymbolAvailability): string;

type
  ISourceLineProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0001}']
    function RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
    function SourceLineToRva(const FileName: string; Line: Integer;
      out Rva: UInt64): Boolean;
    function SortedRvas: TArray<UInt64>;
  end;

  IFunctionNameProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0002}']
    function RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
    // Returns the RVA of the function entry that contains the given RVA.
    function RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
    // Reverse lookup: given a public symbol name, returns its RVA.
    function NameToRva(const Name: string; out Rva: UInt64): Boolean;
    // For nested procedures (declared inside another procedure), returns the
    // immediate enclosing procedure's simple name. Used to walk up to the
    // parent's locals via the hidden parent-frame parameter.
    function GetEnclosingProcedure(const Inner: string;
      out Parent: string): Boolean;
    // RVA-keyed parent lookup. Disambiguates same-named nested procs
    // across multiple units (SampleApp: multiple units each declare a
    // CreateNodes nested in a different parent; lookup-by-name would
    // collide, lookup-by-RVA is unique).
    function GetEnclosingProcedureByRva(InnerRva: UInt64;
      out Parent: string): Boolean;
    // RVA-keyed parent BODY RVA. Resolves the enclosing proc's address
    // directly (within the inner proc's own unit), avoiding a name
    // round-trip that collides when a bare parent name (e.g. `Mid`)
    // exists in more than one unit.
    function GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
      out ParentRva: UInt64): Boolean;
  end;

  // Optional: a provider that builds its name/symbol index on a background
  // thread (e.g. TMapFile parses the large Publics section asynchronously).
  // Returns True while that build is still in progress, so callers can wait
  // for a possibly-resolvable name ONLY while something is actually indexing,
  // instead of blind-sleeping a fixed window on every miss. Providers whose
  // index is ready synchronously (TD32, RSM) do not implement it (treated as
  // never pending).
  IBackgroundIndexProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB000A}']
    function BackgroundIndexingPending: Boolean;
  end;

  ILocalSymbolProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0003}']
    function GetLocalsForFunction(const FunctionName: string;
      out Locals: TArray<TLocalSymbol>): Boolean;
    // RVA-keyed locals lookup. Disambiguates same-named procs across
    // units (SampleApp: multiple CreateNodes nested in different methods
    // across different .pas units all share the lowercase short name
    // "createnodes"; the by-name dict last-wins and surfaces locals
    // from the WRONG CreateNodes, with bogus offsets/types).
    function GetLocalsForFunctionByRva(InnerRva: UInt64;
      out Locals: TArray<TLocalSymbol>): Boolean;
    // Diagnostic: full list of known procedure names (lowercase). Empty for
    // providers that don't enumerate procs.
    function AllProcedureNames: TArray<string>;
  end;

  // Optional: disambiguate a same-named proc by the UNIT that owns it. A proc
  // name can collide across units in ONE binary; a provider whose by-name index
  // is many-to-one (RSM: name -> last offset wins) implements this to pick the
  // proc declared in UnitHint (the frame's source unit). Returns False when the
  // name is not found within that unit (caller then falls back to the plain
  // by-name lookup). Only providers that can collide need implement it.
  IUnitScopedLocalProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0005}']
    function GetLocalsForFunctionInUnit(const FunctionName, UnitHint: string;
      out Locals: TArray<TLocalSymbol>): Boolean;
    // O(1) after a one-time lazy scan: True when FunctionName is declared in
    // more than one unit of this binary (so a plain by-name lookup is ambiguous
    // and the unit-scoped path above is worth the section scan).
    function NameCollidesAcrossUnits(const FunctionName: string): Boolean;
  end;

  IGlobalSymbolProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0004}']
    function GetGlobals: TArray<TGlobalSymbol>;
    function FindGlobal(const Name: string; out Global: TGlobalSymbol): Boolean;
  end;

  // Optional: disambiguate a same-named GLOBAL by the UNIT that declares it.
  // A global var name can collide across units in ONE binary; the plain
  // FindGlobal (first-hit) then returns the wrong unit's metadata (type). A
  // provider whose by-name index is ambiguous implements this to pick the
  // global declared in UnitHint (the frame's source unit). Mirrors
  // IUnitScopedLocalProvider for globals. Only providers that can collide need
  // implement it.
  IUnitScopedGlobalProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0006}']
    function FindGlobalInUnit(const Name, UnitHint: string;
      out Global: TGlobalSymbol): Boolean;
    // O(1) after a one-time lazy scan: True when a global named Name is
    // declared in more than one unit of this binary.
    function GlobalNameCollidesAcrossUnits(const Name: string): Boolean;
  end;

  // Per-unit uses clause (the units a given unit depends on, as recorded by the
  // compiler in the RSM `63 35` clusters). Used to scope an unqualified
  // identifier resolved at a frame to the symbols visible from the frame's
  // source unit, so a same-named symbol in an unrelated unit cannot be picked.
  IUnitUsesProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0007}']
    // Lowercased basenames of the units `UnitName` uses (excluding itself).
    // False when the unit is unknown / has no recorded uses.
    function GetUnitUses(const UnitName: string; out AUses: TArray<string>): Boolean;
  end;

  // Resolve a free procedure/function by name WITHIN a specific unit. The plain
  // NameToRva index is name-keyed (one RVA per name), so a same-named proc in
  // several units collapses to one; this exposes the per-unit copy so resolution
  // can pick the one visible from the frame's unit. Implemented where per-unit
  // proc attribution exists (TD32 via SOURCE_MODULE / ModIndex).
  IUnitScopedFuncProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0008}']
    function FindFuncRvaInUnit(const Name, UnitHint: string; out Rva: UInt64): Boolean;
  end;

  // Resolve a named CONSTANT by name, optionally within a specific unit. Untyped
  // ordinal consts (`const X = 1`) are compile-time inlined: no runtime storage,
  // no public symbol -- the only source of the value is the RSM `$25` constant
  // record. Per-unit attribution lets a colliding const be scoped to the frame's
  // uses (mirrors IUnitScopedFuncProvider). FindConstInUnit('') = any-unit /
  // first-wins flat lookup.
  IUnitScopedConstProvider = interface
    ['{2F5A6C01-1111-4A42-8C3D-53ABAABB0009}']
    function FindConstInUnit(const Name, UnitHint: string;
      out Value: Int64; out TypeHint: string): Boolean;
  end;

  // Enum/set type metadata extracted from the RSM's embedded Delphi TypeInfo.
  TRsmEnumInfo = record
    Kind:         Byte;           // 3 = tkEnumeration, 6 = tkSet
    MinValue:     Integer;        // enum: minimum ordinal (usually 0)
    MaxValue:     Integer;        // enum: maximum ordinal
    Names:        TArray<string>; // enum: value names indexed [0..MaxValue-MinValue]
    BaseTypeName: string;         // set: name of base enum type
    IsValid:      Boolean;
  end;

  IEnumInfoProvider = interface
    ['{B4C7A531-0F92-4E31-9D86-7A2C1F3E8B40}']
    function LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
    // Reverse lookup: given an enum-value identifier (e.g. `wmPaused`), find
    // any enum type that contains it and return the ordinal + the enum type
    // name. Used by the expression evaluator for unqualified enum literals.
    function TryResolveEnumLiteral(const Name: string;
      out Ordinal: Integer; out EnumTypeName: string): Boolean;
    // Delphi TTypeKind byte for any type that appears in a TTypeInfo
    // record (0 = no TypeInfo). Drives the variables-view decision
    // between primitive formatting and class/record decoration.
    function LookupTypeKind(const TypeName: string): Byte;
  end;

  // Class member metadata extracted from $2C/$2E/$31 RSM records.
  // Lets the expression evaluator resolve `Obj.Name` without depending on
  // {$M+}/published TPropInfo (the standard RTTI table is incomplete for
  // private/public members of plain TObject descendants).
  TClassMemberKind = (cmkField, cmkMethod, cmkProperty);

  TClassMember = record
    Kind:        TClassMemberKind;
    Name:        string;
    Visibility:  Byte;        // 00=private 02=public 0A=published
    TypeId:      Integer;     // RAW VLE-decoded value (class-hash / FTypeIdToName key)
    ImportTypeId: Integer;    // per-unit import index source: TypeId shr 1 for
                              // multi-byte VLE (the owning unit's $66 import at
                              // (ImportTypeId div 2)-1 is the type); == TypeId
                              // for 1-byte ids. Imported types/aliases resolve
                              // through this; local class refs fall back to TypeId.
    TypeName:    string;      // resolved through the same type tables locals use
    // cmkField:
    FieldOffset: Integer;     // byte offset within instance (decoded)
    // cmkField & cmkMethod: per-record hash used as binding target
    Hash:        Word;        // field's `9C 09 XX YY` hash, or method's `E2 XX YY` body-hash
    // cmkProperty:
    GetterHash:  Word;        // 16-bit hash referenced by `80 XX YY` -- points at a field or method
    // True for the class's `default` array property, i.e. the one `Obj[X]`
    // means. Both formats record it: TD32 in bit 0 of the u16 at +4 of the
    // $0035 property descriptor, RSM in bit $40 of the byte before Visibility.
    // Verified across four binaries, with controls that separate it from the
    // index type: TStrings.Values (string index, not default) and
    // TStrings.Strings (Integer index, default) sit on opposite sides of the
    // flag in both formats.
    IsDefaultProperty: Boolean;
    GetterName:  string;      // TD32-derived getter method name (demangled)
                              // for method-backed properties. Empty for
                              // RSM-sourced properties (which bind via
                              // Hash<->GetterHash).
    DeclClass:   string;      // class that DECLARES this member (TD32: the class
                              // at the hierarchy level it was collected from). For
                              // an inherited getter the getter symbol lives under
                              // DeclClass, not the runtime leaf class. Empty for
                              // RSM-sourced members.
    // cmkProperty:
    IsIndexed:   Boolean;     // True for an indexed (array) property
                              // (`property P[I]: T`). Its getter needs an index
                              // argument, so the variables view must not
                              // auto-evaluate it (no standard index type / count).
    // Deterministic, id-resolved counterparts of TypeName. The provider that
    // produced this member fills them from the member's EXACT type id (for a
    // property, its return-type id), within its own id namespace -- so no
    // cross-provider id confusion and no lossy re-lookup by name. 0 means "not
    // resolved"; the consumer then falls back to the (first-wins) TypeName path.
    // Prefer these over re-deriving from TypeName when they are non-zero.
    TypeKind:    Byte;        // Delphi System.TypInfo.TTypeKind ordinal (0 = unknown)
    TypeSize:    Integer;     // declared type's byte size (0 = unknown)
  end;

  IClassMemberProvider = interface
    ['{B4C7A531-0F92-4E31-9D86-7A2C1F3E8B41}']
    // PreferInstanceSize > 0 disambiguates two classes that share a bare name:
    // the record whose declared instance size matches is chosen. 0 keeps the
    // first-indexed record (the historical behaviour).
    function GetClassMembers(const ClassName: string;
      out Members: TArray<TClassMember>; PreferInstanceSize: Integer = 0): Boolean;
  end;

  // Class hierarchy: the immediate parent (base) class of a named class.
  // Backed by TD32's LF_BCLASS chain. Used by the expression evaluator to
  // resolve `inherited Method` to the ancestor that declares it.
  IClassHierarchyProvider = interface
    ['{6E2D9A14-7C53-4B8E-9F21-3A5D0C8E1B48}']
    function GetParentClassName(const ClassName: string; out Parent: string): Boolean;
  end;

  // Byte size of a named type (record / structure / class / primitive).
  // Used to compute dynamic-array element stride when the array is a
  // local whose TD32 type is `^Element` (no RTTI dyn-array TypeInfo).
  ITypeSizeProvider = interface
    ['{6E2D9A14-7C53-4B8E-9F21-3A5D0C8E1B47}']
    function GetTypeSize(const TypeName: string; out Size: Integer): Boolean;
  end;

  // One declared parameter of a procedure / method signature.
  TMethodParam = record
    Name:     string;   // '' when debug info carries no name (a CV ARGLIST is a
                        // bare list of type ids -- no parameter names). The caller
                        // then labels it positionally (arg1, arg2, ...).
    TypeId:   Cardinal; // CV type id of the parameter's declared type
    TypeName: string;   // resolved type name (e.g. 'Integer'), '' if unknown
  end;

  // Decode a class method's DECLARED parameters from the type tables (TD32:
  // LF_METHOD -> LF_METHODLIST -> LF_MFUNCTION -> LF_ARGLIST). The implicit Self
  // is NOT included in Params; HasSelf reports whether the method takes one (so
  // the caller knows Self occupies Win64 ABI slot 0 and the declared params start
  // at ABI slot 1). Used to surface the parameters of a frame no local/param
  // provider describes -- notably an anonymous-method body (`...$ActRec.$0$Body`),
  // whose stack slots exist in no BPREL/local record but whose signature does.
  IMethodSignatureProvider = interface
    ['{9D4B1C6E-2A73-4F58-B1E0-5C8A9F2D6041}']
    function TryGetMethodParams(const ClassName, MethodName: string;
      out Params: TArray<TMethodParam>; out HasSelf: Boolean): Boolean;
    // Declared parameter count of a FREE function/procedure (no class), from its
    // LF_PROCEDURE signature. Lets the evaluator refuse to auto-call a bare
    // `Foo` when Foo actually takes arguments -- a zero-arg synthetic call would
    // read garbage argument registers and return a plausible-but-wrong value.
    // False when the name is not a known free proc or its signature is absent.
    function TryGetFreeFunctionParamCount(const FuncName: string;
      out Count: Integer): Boolean;
  end;

implementation

function SymbolAvailabilityName(Availability: TSymbolAvailability): string;
begin
  case Availability of
    saNoSymbols: Result := 'noSymbols';
    saIndexing:  Result := 'indexing';
    saLoaded:    Result := 'loaded';
  else
    Result := 'unknownModule';
  end;
end;

end.
