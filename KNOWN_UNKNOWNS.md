# Known Unknowns

Open questions, unresolved assumptions, and missing knowledge that block
or condition the work. Move resolved items out of this file into
whichever document now holds the answer (`RSM_*`, `DAP_DEBUGGER_*`,
`PROJECT_STATE.md`) — do not leave them here as historical record.

## Embedded TD32 (`.debug` PE section)

Single-file debug-info source. Format is Borland proprietary TD32
(magic `FB09`), not Microsoft CodeView. We implement a native reader
in `DebuggerCore/TD32FileReader.pas`; JCL's layout
descriptions are partly stale on Athens 36 (see code comments for
deltas). The reader is wired alongside MAP/RSM and currently runs as
the primary line + function provider.

Implemented:

- ISourceLineProvider — SOURCE_MODULE $127 line tables, segment-VA
  adjusted to image RVA via PE section table.
- IFunctionNameProvider — LPROC32/GPROC32 ($204/$205) + PUB32 ($203)
  records from ALIGN_SYMBOLS, with an Itanium-style demangler that
  matches MAP file naming conventions (drops unit prefix on 2-part
  names, keeps `TClass.Method` for 3-part, special-cases
  `initialization`/`finalization` to the owning unit name, demangles
  `C1/C2/C3` to `Create` and `D0/D1/D2` to `Destroy`).
- IGlobalSymbolProvider — GDATA32 ($202) records from both
  ALIGN_SYMBOLS and GLOBAL_SYMBOLS ($129, 32-byte header on Athens 36).
- ILocalSymbolProvider — BPREL32 ($200) records inside
  LPROC32/GPROC32 scopes. Gated by `ExposeLocals` (default off)
  because TD32 lacks rich type metadata; RSM stays primary.

Still open:

- **Full Itanium demangler**. Current demangler handles plain `_ZN`
  qualified names, `_ZZ` nested-proc scopes, and ctor/dtor `C1-3` /
  `D0-2`. Does NOT handle: template parameters, substitution
  references (`S_`, `S0_`), specific parameter encodings, return-type
  decoding. Adequate for current test surface.

- **REGISTER ($0002) RegId calibration on edge cases**. Decoder lives,
  TLocalSymbol / TLocalValue carry RegId, CollectLocalsForFrame reads
  values via Microsoft CV register codes ($11..$18 for 32-bit subregs,
  $148..$157 for the Win64 64-bit register file). Codes outside those
  ranges surface as `<register $%x>` (Borland may emit smaller codes
  $01..$08 for 8-byte registers in some contexts; needs verification
  against isolated register-allocated locals). 8-bit / 16-bit subreg
  codes are not yet mapped. Float / SIMD registers (XMM0..XMM15) are
  out of scope for the current TLocalValue UInt64 RawValue.

  (Resolved and documented in `TD32_FORMAT_NOTES.md`:
  container layout, NAMES, TYPES / GLOBAL_TYPES, top-level leaf
  kinds LF_CLASS / LF_STRUCTURE / LF_UNION / LF_ENUM / LF_POINTER /
  LF_ARRAY / LF_PROCEDURE / LF_MFUNCTION / LF_MODIFIER /
  LF_VTSHAPE / LF_VFTPATH / LF_DERIVED, the Borland \$0030..\$003A
  Pascal extensions (passthrough decoded), FIELDLIST sub-records
  (LF_BCLASS / LF_MEMBER / LF_METHOD / LF_ENUMERATE / LF_STMEMBER /
  LF_NESTTYPE / LF_VFUNCTAB), the predefined primitive TypeIds
  below \$1000, the Borland `_ZTR` / `_ZTI` / `_ZTS` / `_ZTV` /
  `_ZTT` mangled-name prefixes, Itanium template arguments /
  substitution back-references / operator names, the
  `TypeId = \$1000 + recordIndex` encoding, the lfoNextDir
  directory chain walk, and the auxiliary symbol kinds
  COMPILE / REGISTER / UDT / SSEARCH / LDATA32 / THUNK32 plus the
  Borland-extension symbol kinds `$0020`, `$0024..$0027`, `$0230`.)

## Per-unit / per-binary type resolution

- **Dynamic-array bounds are not applied to an array reached indirectly** —
  bounds checking requires a POSITIVE identification that the value is a
  dynamic array, which comes from the declared type of a symbol
  (`TLocalSymbol.TypeKind`, resolved by the provider owning the type table).
  A value obtained by INDEXING, field access or a call carries no resolved
  kind, so `MDyn[0][9]` on a `TArray<TArray<Integer>>` reads past the inner
  array's end instead of refusing. Deliberately left unchecked rather than
  inferred from the memory at the pointer: TD32 spells the element `^Integer`,
  which a plain pointer also is, and a header-shaped read is not evidence of a
  header. Closing it means carrying the element / member type kind through
  indexing and field resolution the way locals already do.
  The related open-array hazard IS handled -- see `MayReadDynArrayHeader`: an
  open array only ever occurs as a parameter symbol, so a derived value can
  never be one, which is why `Length()` still answers for a property-reached
  array while refusing for an open-array parameter.

- **Closure-captured variables can vanish while the symbol index is cold** —
  measured 2026-08-02: the same test, same binary, listed `CapStr` and `CapInt`
  on some runs, only `CapStr` on others, and neither on one. Not a stale
  `$ActRec`: resolving the captured set needs that class's members from the
  symbol index, every interactive read waits only `INTERACTIVE_WAIT_BUDGET_MS`
  for it (the F14 hang guard), and on a cold index the lookup simply returns
  nothing. The WATCH path recovers because the frontend warms and retries on a
  miss; the LOCALS path has no equivalent, so the variables view can show a
  closure as having captured nothing.
  Mitigated, not fixed: `AppendClosureCapturedLocals` now emits a visible
  `<captured> = <symbols not ready -- refresh to retry>` row instead of an
  empty list, so the state is at least distinguishable from the truth. The
  real fix is a warm-up + retry on the locals path to match the watch path.

- **dcc32 emits generics UN-INSTANTIATED — FIELDS now recovered via RTTI, the
  PROPERTY node still wrong on Win32.** Largely closed 2026-08-02: runtime RTTI
  reports `FItems: TArray<System.Integer>` correctly on BOTH bitnesses now that
  the field-table header size is right (it is 2 + a pointer, and hardcoding 10
  shifted the whole walk on x86 into garbage). So the element type of a generic
  container is available again despite the static tables being
  un-instantiated. What remains wrong on Win32 is the PROPERTY node --
  `Items` -> `PExpectedMemoryLeaks`, `List` -> `TCloProc` -- and that is NOT an
  RTTI problem: `GetClassProperties` returns nothing on either bitness, so
  those names come from the static tables and are an instance of the RSM
  Win32 type-id mis-resolution described in the next entry. The original
  finding follows.
  measured 2026-08-01 on TestTarget's `GenList: TList<Integer>`.
  dcc64 emits a record per instantiation, `TList__1<Integer>`, whose `FItems`
  is correctly `^Integer`. dcc32 emits ONE shared record named `%TList__1`
  (methods appear as `%TList__1.GetList$qqrv`), and its `FItems` is typed
  `^TComponent` -- the element type of a DIFFERENT instantiation that was
  merged into the same name. The RSM side is no better: it answers `PWord`,
  `TCloProc`, `PExpectedMemoryLeaks` and `RunClosureSampler$ActRec` for
  `FItems` / `List` / `Items` / `PList`, which are coincidental hits in the
  user-type table (see the sibling entry on nested types below).
  Values are read correctly today because the pointer widths happen to agree;
  the risk is an expansion that trusts the element type and walks with the
  wrong stride.
  A recovery route exists and is NOT yet taken: runtime RTTI does know the
  instantiated name -- the same local already renders as
  `$33EF4E0 (TList<System.Integer>)` through the VMT -- so a class whose static
  name is a `%X__1` placeholder could prefer the runtime name, and its member
  element types could be derived from the instantiated RTTI rather than the
  shared static record.

- **RSM resolves a type id that does not belong to it, on Win32** — a type
  declared inside a routine is absent from the Win32 RSM module type map
  entirely (`TColor` is simply not there, where the Win64 RSM has it as
  `$0239`). The local's id `$00CA` then lands in the user-type table at index
  100 and yields `PPCharArray`: a confident wrong name from a coincidental hit
  in the wrong table -- the same failure mode already fixed for main-block
  locals. Harmless in practice today only because TD32 wins at runtime for
  these (see the nested-type demangler fix), so a binary carrying RSM without
  TD32 would show it. The fix needs a way to tell "this id belongs to that
  table" from "this index happens to exist".

- **A type's SIZE cannot be uses-scoped** — `TDebugInfoSet.GetTypeSize` is flat
  first-wins across providers, so when two used units declare the same type
  name the wrong width can win. `SizeOf(TDupRec)` answers 4 (unit A) where the
  frame's uses list makes unit B's 8 correct. The two formats each hold half of
  what a scoped lookup needs: RSM has the uses graph (and drives
  `TryResolveConstScoped` / `TryResolveClassVmtScoped`) but implements no
  `ITypeSizeProvider`; TD32 implements it but is flat, with no per-unit
  attribution to scope by. Closing this means adding sizes to the RSM provider
  or unit attribution to the TD32 one. Asserted by the TODO-RED test
  `Test_UsesScope_TypeSize_PicksUsedUnit`.
  Note this was invisible until `SizeOf` started reporting declared widths:
  the old pointer-size fallback returned 8 for every unrecognised name, which
  happened to equal the expected answer on a 64-bit target.

RSM TypeIds are **per-unit**, not global. A symbol's type must be resolved
against its OWNING unit's import list (`ResolveTypeIdInUnit` / `OwningUnitContext`
in `RsmFileReader.pas`), then the global map. This is now applied uniformly to
members, locals, unit/program globals and main-block locals. Each binary
(main exe + each BPL/DLL) has its OWN `TRsmFile`/`TTD32FileReader` with its own
unit tables, so resolution is per-binary correct.

Still open:

- **TD32 omits INLINE-VAR locals in constructor-nested procs (RESOLVED as a
  hard compiler limitation — RSM must stay).** In SampleApp — a large proprietary
  Delphi Win64 application on the maintainer's machine, not present in a fresh
  clone — `frmMainMdiU`
  `LoadMenu` (nested in `TfrmMainMdi.Create`, `var v := dbConn.DoSQLFmt(...)`)
  is a GPROC32 whose body is only a `$0230` record + END — zero BPREL32, so TD32
  has NO `v`. Decisively diagnosed (a one-off TD32 symbol probe on the -O- Win64\Debug build, so NOT
  an optimization artifact):
    * 99/99 normal `TfrmMainMdi` methods HAVE TD32 locals (TD32 is a
      complete locals source for ordinary procs -- not a parser gap).
    * `PosizionaForm`, ALSO nested in the same constructor but using a TRADITIONAL
      `var c,s,n` block, HAS TD32 locals (c/s/n).
    * `LoadMenu`, nested in the same constructor but using an INLINE `var v := ...`,
      has NONE; `v` is not under the constructor either.
  So the compiler emits no TD32 debug record for an inline var in a
  constructor-nested proc; RSM is the only source. `$0230` (4-byte payload) is too
  small to be the local. The data is genuinely absent from TD32 -- unrecoverable.
  CONCLUSION: **RSM cannot be dropped.** Doing so would lose these locals (and
  program-main-block inline vars, also TD32-absent) and regress the SampleApp `v`
  fix. RSM stays as the TD32 fallback; the two are complementary. Only pursue
  "drop RSM" if a future compiler emits these locals in TD32.

- **Multi-binary RSM by-name collision — CROSS-BINARY addressed.** `TRsmFile.
  GetLocalsForFunctionByRva` is still a stub (RSM has no RVA index), so RSM
  resolution falls back to by-name. The CROSS-BINARY case (two BPLs each with a
  same-named proc) is now handled: `TDebugInfoSet.AddProviderForModule` records
  each DLL/BPL provider's RVA range, and `GetLocalsForFunctionByRva` routes the
  by-name fallback to the provider(s) of the binary that OWNS InnerRva before the
  generic cross-provider merge (`DllModuleRvaRange` supplies the range from
  Module.Base/ImageSize). The CROSS-UNIT, SAME-BINARY case (two units in ONE
  binary with the same proc name, where TD32 lacks the proc) is now handled too:
  `IUnitScopedLocalProvider` / `TRsmFile.GetLocalsForFunctionInUnit` scopes the
  by-name lookup to the frame's source unit (resolved via `RvaToSourceLine`),
  gated by `NameCollidesAcrossUnits` (O(1) after a one-time lazy scan, so
  non-colliding names cost nothing). Wired into `GetLocalsForFunctionByRva`'s
  miss-path. No RVA index is needed -- the RSM section scan scopes by unit
  anchors, not RVA. See DAP_DEBUGGER_ARCHITECTURE.md "Cross-unit local
  disambiguation". The (TD32 by-RVA miss AND name collides) intersection is now
  reproduced deterministically in TestTarget: `SharedConflictProc` is declared in
  both TestTargetConflict1/2 as a CONSTRUCTOR-NESTED proc with an INLINE var --
  the exact shape TD32 emits no locals for (mirrors SampleApp LoadMenu; verified:
  `TTD32FileReader.GetLocalsForFunction('SharedConflictProc')` returns NONE while
  the RSM unit-scoped lookup returns the per-unit Marker). Covered end-to-end by
  the adapter integration tests `Test_CrossUnitNestedLocal_Unit1/2_PicksOwnMarker`
  (RED-proven: disabling the wiring breaks the unit-1 case) plus the RSM-method
  test `UnitScopedLocals_PicksRightUnitForCollidingProc`. Fully closed.

- **Cross-binary GLOBAL resolution — CLOSED (all four tiers).**
  `TDebugInfoSet.FindGlobalForRva` resolves globals the way Delphi scope rules
  would at the stop (see DAP_DEBUGGER_ARCHITECTURE.md "Cross-unit / cross-binary
  global disambiguation"): (1) cross-unit same-binary via
  `IUnitScopedGlobalProvider` (Layer 1, TD32 per-unit attribution); (2)
  cross-binary collision via `FRangedGlobals` — the frame's owning binary (RVA
  range contains the stop) is queried before any fallback, so the in-scope
  binary's copy wins regardless of load order; (3) **uses-graph**
  (`TryRequiresClosureGlobal`) — when the global is not in the frame's own
  binary, the binaries it `requires` (transitively, from PACKAGEINFO) are
  queried before the flat fallback, so a required package's global beats an
  unrelated module's (e.g. the always-loaded main exe) same-named one; (4) flat
  first-hit. Required modules' symbol providers are warmed on demand for
  identifier watches in a package frame (`WarmupRequiresClosureForPC`), so a
  required-package global is loaded even when the debuggee never stopped in that
  package. Tested: `Test_Bpl_UniqueGlobal_ResolvesFromExeFrame`,
  `Test_Bpl_CrossBinaryGlobalCollision_PicksOwnBinary`,
  `Test_Bpl_UsesGraphGlobal_PrefersRequiredPackage`.
  Remaining finer point (not a correctness gap today): when two DIFFERENT
  required packages both declare the colliding name, tier 3 returns the first in
  requires order rather than the frame source-unit's exact uses last-wins. Needs
  the per-unit cross-binary uses list; not observed in the wild.

## RSM unit sections — partial reverse-engineering

Structural findings from probes on `DebuggerTests/TestTarget/Win64/Debug/TestTarget.rsm`
(one-off structural walkers over the raw RSM byte stream; the findings below are
the retained record — such walkers can be recreated from the record layouts in
`RSM_FIELD_OFFSETS.md`):

### Unit-section boundaries (confirmed)

The RSM is partitioned into unit-owned sections. Each section starts with a
**uses-clause cluster**: a contiguous run of `63 35 [LEN] [Name] [payload]`
records, one per unit referenced by the owning unit. Records in a cluster are
*adjacent* (no large gaps); the cluster terminates when the next non-`63 35`
byte appears.

### Owning-unit detection (confirmed)

One entry in each cluster is the **SELF entry** carrying the cluster's owning
unit. SELF entries are distinguished by the trailing two bytes `02 63` at the
end of their payload (before the next record). Two SELF payload shapes:

- **Direct**: `XX 00 00 00 00 00 00 02 63` (9 bytes). The cluster's owning
  unit IS the record's `[Name]` field. (Example: `SysUtils` entry at
  $2B119C in TestTarget.rsm.)
- **Indirect**: payload contains an embedded `04 35 [LEN] [ActualName] ...
  00 00 00 02 63` sub-record. Owning unit = `ActualName`, not the outer
  record's name. (Example: cluster at $0AB737, outer `System`, embedded
  `04 35 05 Types ...02 63` → owner is `Types`.)

For TestTarget.rsm the recovered ownership is:

| Cluster start | Owner       | Section range          |
|---------------|-------------|------------------------|
| $0E84         | System      | $E84..$A5080           |
| $A5081        | SysInit     | (then variants)        |
| $AB737        | Types       |                        |
| $CF7CF        | UITypes     |                        |
| ...           | ...         |                        |
| $2B111A       | **SysUtils**| $2B111A..$3A695B       |
| $3A695C       | VarUtils    |                        |
| $3ADD25       | Variants    |                        |
| $3ECF93       | TestTarget  | $3ECF93..EOF           |

Exception's `$2A` declaration at $2B1AB2 and its `$2C FMessage` field at
$31AAFD both fall in the SysUtils-owned range, confirming Exception is in
`SysUtils` for ownership purposes.

### TypeId encoding — RESOLVED (per-unit imports tables)

Each Delphi unit compiled into the EXE emits its own `$66`-style imports
area in the RSM, anchored by `$64 $06 'System' $00 $00 $00 [first record]`.
The EXE main module uses `$65` instead of `$64` for the same anchor. The
imports area is preceded by a `$70 LEN Path` record naming the unit's
source file (`System.SysUtils.pas`, `TestTarget.dpr`, etc.); the unit
identity is the basename without extension and without any leading
`<dotted.namespace>.` prefix.

Class-member (`$2C` field, `$2E` method, `$31` property) TypeIds are
1-byte VLE indices into the OWNING unit's $66 list (`TypeId = (idx+1)*2`).
This is per-unit, not global. Symptom of resolving against the wrong
table: `Exception.FMessage` (TypeId $12 in SysUtils, where idx 8 is
`UnicodeString`) shows up as `Boolean` because the EXE-global imports at
$3E28CF puts `Boolean` at idx 8.

Implementation in `RsmFileReader`:

- `ParsePerUnitImports` walks the file for `$64|$65 06 'System' 00 00 00`
  anchors, extracts the unit name from the preceding `$70` path record
  (`.pas` or `.dpr` suffix), and collects the ordered $66 type list into
  `FUnitImports[unitName]`.
- `FUnitAnchors` stores the sorted (anchor offset, unit name) list. A
  binary search on offset identifies the owning unit for any file offset.
- `ResolveMemberTypesPerUnit` walks `$2A` class declarations, records
  `FClassUnit[className]` via anchor lookup, then re-resolves every
  member's `TypeName` against the owning unit's imports list. RTL classes
  like `Exception` now resolve to `string` correctly without falling back
  to runtime extended RTTI.

The `$2C` field records' TypeId byte does NOT cleanly index into:

1. The global `$66`-imports area at $3E28CF (TestTarget's combined imports).
2. The per-unit TypeInfo (`$08`-prefix) records found within each section.
3. Raw `TTypeKind` enum values (matches FMessage's string=$12=tkUString but
   not Boolean=$1C, Pointer=$26, Integer=$A — those don't line up with any
   tk).

Each unit-section apparently lacks a `$66`-style imports area at its start.
Only one `$66`-record run exists in the SysUtils-owned range, at $3A5E72,
and its ordering (idx 8 = Double, not string) doesn't match what FMessage's
TypeId $12 demands either.

RESOLVED. Per-unit imports tables now drive member-type resolution
(see `RsmFileReader.ParsePerUnitImports` / `ResolveMemberTypesPerUnit`).
`Exception.FMessage` resolves to `UnicodeString` and
`Test_Hover_ExceptionInHandler_Message` passes in the 144/144 suite.

Residual gap: class-typed fields (`FInnerException` TypeId=$2DD,
odd → module-local) still show empty TypeName because module-local
type resolution doesn't traverse the type tables for class
identifiers. Not blocking any current test.

## RSM format

- **Header bytes 0x04..0x1F** — never inspected. Contents and ordering
  unknown. Do they include version, build options, target platform?
- **Procedure metadata block — prefix and extra bytes** — the
  metadata block between proc name and `71 1C 00` terminator is 10–14
  bytes. The `[03|83][lo][hi]` RVA/32 triplet is **confirmed** (see
  `RSM_FORMAT_NOTES.md`). What remains unknown: (a) the 3–7 prefix bytes
  before the tag, (b) the 4–5 extra bytes after `[hi]` and before `71`.
  Candidates: proc size, source-line range, frame size, parameter count.
- **Inline-format local "?" byte** — at offset `2+LEN+3` inside an
  inline-format local-var record sits a single byte we ignore. May be a
  scope flag, ordinal counter, or alignment byte.
- **Type descriptor encoding beyond the flat name table** — records,
  classes, dynamic arrays, sets, generics, anonymous methods all need
  layout / member metadata to expand in the Variables tree. The current
  user type table only exposes a name string per type. Where do the
  fields live?
- **Wide TypeId space in main-block locals (tag `0x20` / marker `0x46`)** —
  the record's TypeId is VLE-encoded, and the *narrow* form resolves against
  the user-type table by the usual `Idx = TypeId div 2 - 1` rule (`Res: Integer`
  carries `$0006` → idx 2 → `Integer`, verified). The *wide* form does not
  resolve against any table found so far: `TheWidget: TWidget` carries `$0401`
  = 1025 while the table holds 246 entries, and neither `shr 1` (idx 255, out
  of range) nor `shr 2` (idx 127 = `PVariant`) lands on `TWidget`. `TWidget` is
  in neither the user-type table nor the unit's `$66` import list; its module
  type id is `$62C9`. Same shape on Win32 with different values (`$03ED`), so
  not a bitness artifact. Byte-level evidence is in `RSM_FIELD_OFFSETS.md`.
  Candidates not yet dumped: the EXE-wide `$65`-anchored import table, and
  whether the wide id is an offset rather than an index. Until this is
  answered the parser leaves the hint empty rather than emitting a wrong name.
- **`0xC6` global variant payload** — used for Delphi runtime globals
  (`ModuleIsLib`, …). Length and meaning of the payload after the tag
  are unknown; the parser captures the name and abandons the rest.
- **Parameter-kind tags** — `0x20` (local), `0x22` (var/ref parameter),
  and `0x23` (out parameter, used for the hidden `Result` slot of
  var-out functions) are confirmed. `0x21` is suspected to be `const`
  parameter; not yet observed in the wild.
- **Trailing 4-byte hash on `0x66` / `0x67` records** — assumed to be a
  hash. Algorithm (CRC32? FNV?) and what it hashes (the name? the
  unit?) are unverified.
- **System unit's 3-byte payload** — `00 00 00` for System; meaning
  unconfirmed and probably matters for non-System unit references.
- **`$2E` method record — direct return-type byte location is moot.**
  The `8C/9C` byte at +N+7 encodes "has arguments" vs "parameterless",
  not the return ABI. The extended trailer's `02 <byte>` doesn't
  segregate by ABI either. The return type does not appear to live
  inside the `$2E` record at all.

  HOWEVER the actual return type IS present in the matching `$28`
  procedure record — every Delphi function emits its result as a
  local variable named `Result` with a normal typeId reference.
  Var-out functions (string / Variant / dyn-array / large record) tag
  `Result` as `$23` (out parameter) instead of `$20` (local) — the
  parser accepts both. `ExprEval.ApplyMethodCall` reads `Result` out
  of the function's `$28` locals to drive RAX vs XMM0 vs hidden
  var-out dispatch. Same path covers free-procedure / function calls
  too. So the original blocker is resolved end-to-end without needing
  to decode the `$2E` byte that gave the file its name.

  Field/property/constructor record decoding lives in
  `RSM_RECORD_TYPES.md` and `RSM_FIELD_OFFSETS.md` and is wired into
  `RsmFileReader.ParseClassMemberSection` /
  `ExprEval.TryResolveViaRsm` / `ExprEval.ApplyMethodCall`.

## Wrong-data heuristics — audit 2026-07-19

An adversarial audit of the value/object-guessing heuristics (8 suspects, each
analysed then adversarially refuted). One MEDIUM was fixed; five were refuted
(the debugger correctly reports current target memory; non-optimised-target
invariants + Delphi ARC zero-init defeat the rest). Two LOW risks survived
refutation but only in narrow forms; deferred because a careless fix would
regress shipped closure/array display. Fix carefully (with the new `TFakeMemTarget`
in `ValueReaderTests.pas` for deterministic memory-pattern unit tests):

- **FIXED (medium): Variant auto-detect accepted varInt64/varUInt64 unconditionally**
  (`DelphiValueReaders.LooksLikeVariantAt`). Any untyped local whose 8-byte value was
  exactly 20/21 ($0014/$0015) was shown as a Variant reading the NEIGHBOURING slot as
  the payload — silently wrong type AND value. Now falls through to False like
  varSmallint/varInteger already do (a real typed Variant is unaffected; a mis-typed
  varInt64 renders as its raw integer — the strictly safer failure). Tests
  `ValueReaderTests.VariantAutoDetect_*`.

- **DEFERRED (low): closure-object recovery has no reverse link**
  (`VariableExpander.TryRecoverClosureObject`, call site ~line 340). The site does not
  check `LV.TypeHint`, so any Pointer/Int64/PChar local ≥64 KB enters the scan; the
  backward `InterfaceRef - K*8` scan (K=0..8) can latch an UNRELATED nearby `$ActRec`
  (dense in a closure-heavy target) and expand a FOREIGN closure's captured fields.
  Producer via an unassigned closure local is refuted (managed locals zero-init to
  nil → EffVal 0). Fix needs a real reverse-validation that `InterfaceRef` points at a
  genuine interface field inside the recovered object (a plain `offset < InstanceSize`
  check is too weak), OR a reliable closure-TypeHint gate — both need the actual TD32
  closure-type rendering pinned down first, without regressing the shipped increment-A
  expansion (`Test_Closure_ExpandsCapturedFields`).

- **FIXED (2026-08-03): dyn-array `^T` header heuristic** — a `^T` now renders as
  an array only when the provider that owns the type table SAYS it is one. The
  entry below is kept because the investigation took three wrong turns and the
  measurements are worth having.

  The signal was there all along. `Td32AliasProbe -class TManagedRec` shows the
  member `Tags` arriving with `kind=17` (tkDynArray) on both bitnesses, and
  `MemberFieldToSession` threw it away one line before use by re-deriving the
  kind from the type NAME — `LookupTypeKind('^Integer')` — which is precisely
  the ambiguous spelling the kind existed to disambiguate.

  Removing the heuristic then exposed the kind being dropped at two more points
  on the evaluate path. The last was the instructive one: `TDebugSession.
  FormatExprValue` was a byte-identical COPY of the expander's, and the two had
  drifted, so expanding `MRec.Tags` rendered `[4, 5, 6]` while evaluating the
  same field rendered a bare address. The copies are now one method.

  One narrowing was needed: carrying the kind WHOLESALE broke `var` parameters,
  whose kind describes the declared type (`^Integer`) while RawValue already
  holds the dereferenced value — the formatter printed the right number in
  pointer style, `0x5E` instead of `94`. Only the dynamic-array fact travels.

  Pinned by `DynArrayRendering_NeedsAStatedKindOnBothBitnesses`: `PI`, a genuine
  `^Integer`, is aimed at the DATA of the live `MRec.Tags` array, so the bytes
  behind it are an authentic dynamic-array header — the case a byte-shape test
  cannot refuse. Without the gate it renders `[4, 5, 6]` as if it were the
  array; with it, a pointer.

  A SHARPER fixture was attempted three times and abandoned, which is worth
  knowing on its own. A `^Word` aimed at an `array of Integer` demonstrates the
  corruption outright: `[1000, 2000, 3000]` read Word-strided came out as
  `[1000, 0, 2000]`, on both bitnesses. It cannot be kept as a fixture:

    * declaring the two locals it needs SHIFTS the RSM per-unit import indices,
      and `ClassTypedField_ResolvesViaClassHashCandidates` then resolves
      `Exception.FInnerException` to
      `{System.Generics.Collections}TList<System.Integer>.UpdateNotify.:2<...>`;
    * declaring ONE local of an already-present type (`^Integer`) shifts them
      too;
    * reusing an existing local breaks the three tests that assert `PI^ = 2`.

  So TWO ORDINARY VARIABLES are enough to silently re-resolve an unrelated class
  field elsewhere in the binary. That is the class-member typeId weakness below,
  and this is a sharper measure of it than anything recorded there: it is not a
  large-type-space-only problem, it is reachable by editing a test target.

  Tried and reverted while chasing that: scoping the class-hash candidate choice
  by the referencing unit instead of taking `Candidates[0]`. The reasoning is
  sound (position is a guess, scope is a fact) but it made no difference to the
  failure, because the wrong name arrives from the import-index step BEFORE the
  hash fallback is reached. Unverified and inert, so not shipped.

- **(historical) DEFERRED (low): dyn-array `^T` header heuristic can alias a real header**
  (`DelphiValueReaders.FormatDynArrayLocal` / `VariableExpander.TryMakeDynArray`). The
  common vectors are refuted (non-optimised codegen finalises a managed `array of T`
  local to nil at scope exit, so a later `^T` reading the same slot shows `[]`). The
  survivor is cross-type aliasing: a `^T2` pointing at a live `array of T1` passes the
  header bounds (it IS a real header) and renders `T2[len_of_T1]`, striding sizeof(T2)
  past the buffer.

  ATTEMPTED and reverted (2026-08-02). The intended fix is right and is not a
  bounds tweak: accept `^T` as a dynamic array only on a POSITIVE statement from
  whoever owns the type table, never on the pointed-to memory resembling a
  header. `TSymbol` already carries `TypeKind` and `PointeeKind` for exactly
  this, TD32 fills both, and `TLocalValue` now carries `PointeeKind` too (that
  plumbing LANDED, along with merging both kinds across providers — previously
  whichever provider happened to be the base decided, the same defect that was
  fixed for `ParamStatus` and `lkVarParam`).

  What blocked it: the kind does not REACH the renderer on the paths that matter.
  Gating on it turned `MRec.Tags` — a real `array of Integer` — into a raw
  pointer on both bitnesses (`Win32_RecordAndDynArrayExpansion_MatchWin64`).
  `Tags` is a record FIELD, and the field paths build a `TLocalValue` through
  `VariableExpander.SyntheticLocal`, which carries a name, a type spelling and
  an address and nothing else. `MemberFieldToSession` does consult the live
  object's RTTI at the same byte offset, but only AFTER formatting and only to
  fix expandability and the type label; hoisting that lookup above the format
  call was tried and changed nothing, so `Tags` is not reaching that function
  either.

  STATE OF THE INVESTIGATION (2026-08-03), after two wrong turns worth recording
  so they are not repeated:

  1. TD32 CAN tell the two apart. `Td32AliasProbe -class TManagedRec` shows the
     member `Tags` as `$AD28 leaf=$2 kind=1 -> $AD2A leaf=$32 kind=13 -> prim
     $74 Integer` on both bitnesses. A genuine `^Integer` goes from the pointer
     node straight to the primitive; the dynamic array has the extra
     `$32/kind=13` hop. `PointeeKindById` is the existing decoder for exactly
     that shape. So an earlier note here claiming "no provider says dynamic
     array" was too pessimistic.

  2. But promoting it at the member level did NOT change the rendering. Adding
     `PointeeKind` to `TClassMember`, filling it from `PointeeKindById` in
     TD32's `GetClassMembers`, and treating `PointeeKind = TK_DYNARRAY` as
     dynamic in `MemberFieldToSession` left `MRec.Tags` rendering exactly as
     before -- `[4, 5, 6]`, i.e. still through the header heuristic, not through
     `FormatMemberValue`'s TK_DYNARRAY branch (which would print `^Integer[3]`).
     Those edits were REVERTED rather than shipped, because shipping a change
     whose lack of effect is unexplained is worse than not shipping it.

  So the next step is a measurement, not a design: find out which provider
  actually supplies `TManagedRec`'s members in a live session, and whether that
  child reaches `MemberFieldToSession` at all. `Tags` renders CORRECTLY today,
  so there is no urgency and no excuse for guessing.

  The trade, if it ever has to be made: keep the header check and a `^T2` aimed
  at a live `array of T1` renders a wrong length and strides past the buffer;
  gate without a working positive signal and a correct render becomes a bare
  pointer.

## Wrong-data heuristics — audit round 2, 2026-07-19 (value/type computation)

Round 1 audited "guess an OBJECT" heuristics; round 2 audited "compute a VALUE"
paths (8 suspects, analyse + adversarially refute). 6 confirmed, 2 refuted. All 4
of the actionable ones are FIXED; the remaining 2 are recorded below.

FIXED:
- **setVariable wrote past a set's slot (neighbour corruption).** `ValueEncoders.
  TryEncodeEnumOrdinal.StorageWidth` discarded an accurate provider size for SETS
  (guard `Sz in [1,2,4]`) and its packing table rounded 3→4, so a `set of (c0..c19)`
  (exactly 3 bytes) got a 4-byte write that zeroed the first byte of the physically
  adjacent variable — silent corruption of the DEBUGGEE, reported as success. Sets
  are byte-granular: exact provider size is now trusted, the derived width is
  `(HighOrd div 8)+1`, and the `case 1,2,4` store (which could not emit 3/5/6/7 and
  silently wrote zeros) is a little-endian loop. Enum widths (1/2/4) unchanged.
  Tests `ValueEncoderTests.*`.
- **AnsiString decoded with the system code page.** `ReadDelphiAnsiString` used
  `TEncoding.ANSI` regardless of the code page in the string's own header
  (`TStrRec.codePage`, a Word at `Ptr-12`), so a `UTF8String` (CP 65001) or any
  non-default-code-page AnsiString rendered as mojibake. Now decoded via
  `AnsiEncodingFor` (CP_ACP/CP_NONE→ANSI, 65001→UTF8, else `TEncoding.GetEncoding`
  with an ANSI fallback; non-standard encodings freed). Tests
  `ValueReaderTests.AnsiString_*`.
- **Enum ordinal display folded in the neighbouring local.** `FormatTyped`'s
  `TK_ENUM` branch masked a fixed 4 bytes although the local is READ as 8 and a
  Delphi enum is normally 1 byte, so an out-of-range/UNINITIALISED enum (enums are
  not zero-initialised) displayed a 4-byte number carrying the adjacent local's
  bytes. Now masked to the enum's real storage width (provider size, else derived
  from MaxValue, default 1).
- **Enum member name aliased above ordinal 255.** The enum-name path masked
  `and $FF`, so any ordinal 256..511 resolved to a DIFFERENT, valid-looking member
  (`e260` displayed as `e4`). Now masked to the enum's real storage width. Tests
  `ValueReaderTests.Enum_*`.
- **Small POD record results read a zeroed slot.** `ExprEval.ApplyMethodCall`
  routed every `TK_RECORD` return through the hidden var-out slot, but the Win64
  ABI returns a POD record of size ≤8 bytes PACKED IN RAX — so the callee never
  wrote the slot and the watch showed a bogus zero (inserting the slot also shifted
  the user args by one register). Now size-routed: ≤8 bytes takes no slot argument
  and reads RAX (presented as a packed `Int64`); managed records and >8 bytes keep
  the slot; unknown size keeps the previous behaviour. Test
  `Test_Eval_SmallRecordReturn_NotZero`. FOLLOW-UP: expanding such a
  register-returned record field-by-field (it currently shows as a packed integer).

FIXED (was: typeless MAP-only global reads 8 bytes) — 2026-08-02. Confirmed on a
purpose-built fixture rather than argued from the code: `MapOnlyGlobals.dpr` is
compiled with a detailed MAP (`-GD`) and NO embedded debug info, which is the
realistic release-build shape and the only one where an address is known and a
type is not. Its globals are packed at +0/+1/+2/+4, and a `Byte` holding 5 read
back as `-1091589627` ($BEEFAA05) on BOTH bitnesses — the three following
variables folded into the value, with nothing marking it unreliable.

The read is now bounded by the distance to the next symbol
(`ISymbolExtentProvider`, answered by the MAP, which is the only reader that
enumerates publics by address). That is a fact, not an estimate: two symbols
cannot overlap, so whatever lives at an address ends before the next one starts.
On the fixture the bound is exactly 1, 1 and 2 bytes and the values read 5, 170
and 48879. The cap only ever NARROWS — a type that already settles the width
wins. The query blocks on the publics parse deliberately, because an answer that
depended on whether a background thread had finished would make the VALUE depend
on timing. Test `TypelessGlobals_ReadTheirOwnBytesOnBothBitnesses`.

REFUTED in round 2: ExprEval `MaskByType`/casts (the RTL fixed-width aliases never
reach it as TypeHints, and the local read is already width-limited) and RSM
per-unit typeId resolution (the claimed local-vs-member asymmetry does not exist —
an odd typeId always takes the same `shr 1` import retry in both paths).

## Wrong-PLACE audit — round 3, 2026-07-19 (location / attribution)

Rounds 1-2 audited "guess an object" and "compute a value". Round 3 audited
LOCATION / ATTRIBUTION: the datum is read correctly but belongs to, or is reported
at, the WRONG place. 8 suspects, analyse + adversarially refute — **8 confirmed,
0 refuted**: this axis had never been examined. 7 fixed, 1 documented below.

FIXED:
- **(HIGH) Frame selection read another thread's stack.** A frame INDEX is only
  meaningful with its thread. `GetCallStack(tid)` deliberately does not cache a
  non-stopped thread's frames, but `SelectFrame(Index)` indexed the STOPPED
  thread's cache, and DAP frame ids are bare indices while `scopes`/`evaluate`
  carry no threadId. Clicking a frame of another thread showed a complete,
  plausible set of locals from a DIFFERENT thread. Cache is now thread-qualified
  (`FLastFramesTid`), `SelectFrame(Index, ThreadId)` re-walks on mismatch, a
  foreign thread's frame 0 is selectable, and the DAP passes the last
  stackTrace's thread. Test `SelectFrame_OnOtherThread_ReadsThatThreadsLocals`.
- **MAP attributed foreign addresses.** `RvaIsInImage` used a blanket 1 GB window
  instead of the module's real `SizeOfImage` (now set by the loader).
- **MAP named addresses it did not own.** `RvaToFunctionName`/`RvaToFunctionStart`
  did an unbounded nearest-preceding public search with no function end and no
  code/data split (`FDataRvas` was parsed but unused), so an address in a gap took
  the name — and the entry RVA — of a DATA symbol or a far-away routine. New
  `PublicCanContain` rejects a data public and a gap above 256 KB.
- **A line was borrowed from another unit.** `TTD32FileReader.RvaToSourceLine`'s
  4 KB gap cap did not catch an inter-function gap, so an Rva past a function's
  end inherited the previous function's last line — often a different unit, which
  the resolver turned into a real path VS Code opens. Now bounded by the `EndRva`
  of the proc owning the candidate line.
- **A watch ran the wrong module's copy.** `NameToRvaScoped` scoped by UNIT only,
  but the same unit can be linked into the host exe AND a package, so a watch could
  invoke/read another binary's function or global. Both tiers now prefer a
  candidate inside the frame's module RVA window.
- **A step ended in a deeper recursive frame.** The run-to-return one-shot BP sits
  at the call's return address, and in a recursive function every nested return
  targets that SAME address, so the innermost incarnation tripped it: the step
  reported the right LINE while execution sat frames deeper, with locals from the
  wrong incarnation. The expected post-return RSP is now recorded; a hit at a
  smaller RSP re-arms the BP and keeps running.
- **A breakpoint bound to the wrong module's same-basename file.** Line keys are
  basename-based, so two files sharing a basename (or one unit linked into exe +
  package) both answer; taking the first hit bound the BP to the wrong copy while
  still reporting it verified — it then never fired, or stopped in the other file
  while the UI highlighted the user's. New
  `TDebugInfoSet.SourceLineToRvaCandidates`; `DoSetBreakpoints` plants every
  distinct candidate.

STILL OPEN (low) — **same-basename SOURCE FILE cannot be disambiguated**:
a frame in `...\DOA\Oracle.pas` can open `...\DGOdac\Oracle.pas` at the same line
(`SourceResolver` is basename-keyed, first-match-wins across roots). This is a
HARD limit, not an oversight: TD32 NAMES stores only the BASENAME with no
directory (established while diagnosing the DGOdacTests breakpoint report, against
the maintainer's proprietary DGOdac component set — not present in a fresh clone), so the
debugger has nothing to disambiguate WITH for TD32-fed modules. Available
mitigations, none implemented: keep the rooted path when a provider does supply one
(MAP/JCL sometimes do — but `Loc.SourceFile` is consumed as a basename in several
places, so this needs care), and detect during the root scan that a basename
matches more than one file and warn once (`TSourceResolver` currently has no log
channel; `TDebugSession.OnConsole` would be the sink).

## DAP adapter / debugger
- **Per-thread inspection + stepping — DONE.** `threads` lists every live
  thread; `stackTrace` / `scopes` / `variables` honour the request `threadId`
  (any thread's stack + locals resolve read-only at a stop); and step
  over/into/out act on the selected thread while the others are frozen (see
  `DAP_DEBUGGER_ARCHITECTURE.md` "Stepping" and `PROJECT_STATE.md`). Only the
  synthetic-call evaluator still runs on the stopped thread (frame-independent).
- **Disassembly view** — `disassemble` request is unimplemented; need
  a disassembler we can ship (zydis? capstone?) or a hand-rolled
  Delphi-prologue-aware one.
- **Child process tracking** — debug API can follow children; we don't.
- **`%TEMP%\dap_adapter.log` opt-in** — currently always-on. No
  configuration knob in the launch schema yet.

## Win32 targets — what is still open

32-bit targets are implemented (launch, breakpoints, stepping, stack, locals,
object expansion, evaluation, multi-BPL). See "Target architecture" in
`DAP_DEBUGGER_ARCHITECTURE.md`. These remain unanswered:

- **A synthetic call's argument kinds come from the CALLING EXPRESSION, not the
  callee's declared parameter types**, which the debug info does not surface.
  Passing `0.25` — typed `Double` by the evaluator — to a `Single` parameter
  therefore places 8 bytes where the callee reads 4. This is not new and not
  x86-specific: on x64 the same expression puts Double bits in XMM0 for a callee
  that reads the low 4 bytes as a Single. Integer literals are the case that had
  to be worked around immediately, since the evaluator types them `Int64`:
  `TExprValue.IsIntLiteral` marks them and a literal that fits 32 bits is passed
  as an ordinal. The real fix is parameter types in the debug info.
  (Float and `Int64` arguments and returns otherwise work on both
  architectures — see `DAP_DEBUGGER_ARCHITECTURE.md`.)
- **A constructor's declared name is unavailable from TD32 alone.** dcc32
  mangles it as `@Unit@TClass@$bctr$qqrv` with the name component EMPTY — only
  the `$bctr` / `$bdtr` marker is recorded, so `Create` is genuinely not in the
  symbol. The declared name is currently taken from the MAP, which stores it in
  plain text (see `TD32_FORMAT_NOTES.md`). With TD32 and no MAP, the mangled
  form is all the stack can show. A class's TD32 member list does record methods
  by their source names, so the name IS reachable — walking from a procedure
  record to the owning class's member list has not been implemented. Mapping
  `$bctr` onto `Create` is not an option: a constructor may be declared with any
  name, and the guess would print something the source does not contain.
- **Does `dcc32 -$O+` emit usable local symbols?** Win32 locals/params are
  declared supported for `-$O-` builds only, because `-$O+` omits the frame
  pointer routinely. Whether the debug info of an optimised 32-bit build still
  carries offsets that can be anchored to something else has not been measured.
- **Threadvars are not resolved (both bitnesses).** A `threadvar` has NO address
  in the image: it lives in the per-thread TLS block. The question was
  previously filed as "what is the TLS segment base", which has no answer —
  there is no single base, only one per thread.

  What WAS wrong and is now fixed: the MAP's TLS segment resolved to base RVA 0
  on both platforms (Win32 prints `Start` as 0; Win64 prints the preferred base,
  which subtracts to the same thing), so a threadvar resolved to a low RVA and
  the debugger read the **PE headers** and reported those bytes as the value.
  Measured on the `GTlsMarker` fixture: the debugger answered `0  (0x0)` for a
  variable holding `$5A5A5A5A`, on x64 and x86 alike, with nothing marking the
  answer as wrong. TLS-segment symbols now get no RVA at all, and a lookup says
  `threadvar -- per-thread storage is not resolved yet`. Asserted by
  `ThreadVar_IsNeverSilentlyWrongOnBothBitnesses`, which accepts the right value
  OR an honest refusal and rejects a wrong number, so it stays valid once
  resolution lands.

  What is still needed to actually READ one:
    * `TlsIndex` — from the module's PE TLS directory (`IMAGE_DIRECTORY_ENTRY_TLS`,
      index 9), whose `AddressOfIndex` field points at the DWORD holding it.
      Static, per module, readable from the target.
    * the thread's TEB — `NtQueryInformationThread(ThreadBasicInformation)` gives
      `TebBaseAddress`. For a WOW64 target seen from a 64-bit debugger the
      32-bit TEB is NOT that address; where it sits must be MEASURED before it
      is relied on, exactly as the VMT offsets and the IMT thunk encodings were.
    * `ThreadLocalStoragePointer` inside the TEB, then
      `block := [TlsPointer + TlsIndex * PointerSize]`, and finally
      `address := block + segmentOffset`.

  Note the answer is PER THREAD, so whatever resolves it has to take the frame's
  thread — a value cached against an address, as the current global path does,
  would be wrong the moment another thread is selected.

### Measured scope of the RSM typeId mis-resolution (2026-08-02)

The defect is wider than "nested type names": past a certain typeId, RSM names
almost every local wrongly, and it does so on BOTH bitnesses. Measured with
`Td32AliasProbe -rsmproc RunTypeSampler` against `TestTarget.rsm`, compared with
the source declarations:

| Local | Declared | RSM says (x64) | RSM says (x86) |
|---|---|---|---|
| `Cnt` | `ICounter` | `TClassHelperBaseClass` | `TContainedObject` |
| `ClsRef` | `TClassRef` | `UTF8String` | `TUCS4CharArray` |
| `GenList` | `TList<Integer>` | `TInfoFlags` | `PError` |
| `PI` | `^Integer` | `TThreeByteData` | `PPUnknown` |
| `RecP` | `^TPackedRec` | `TBaseType` | `PInterface` |

Everything up to `TGUID` (small ids) resolves correctly, so the failure begins
where the id encoding does. The names it produces are real RTL type names from
an unrelated part of the table, which is why nothing about them looks wrong.

NOT user-visible in these binaries: verified live on both bitnesses that the
displayed types are correct (`ICounter`, `TBase`, `TList<System.Integer>`,
`^Integer`, `^TPackedRec`), because TD32 answers first wherever it is present.
The exposure is a module where RSM/DCP is the ONLY provider -- a package built
without TD32, which is the multi-BPL shape the debugger has to support. There
each of the names above would be shown as the variable's type, and expansion
would follow the wrong type's layout.

No cheap containment exists: the wrong names are structurally indistinguishable
from right ones, so "refuse when unreliable" needs the same decoding the fix
needs.

### FIXED: Win32 nested procedures now see the parent scope

Kept for the measurements, which took several wrong turns to get right. The fix
was NOT where the investigation started (the frame pointer) but two levels up:
nothing knew the routines were related at all. `pParent` supplied it; see
`TD32_FORMAT_NOTES.md`.

### (historical) Win32: a nested procedure cannot see its parent's variables

Standing at `INNER_BODY` inside `ComputeNested.Inner`, the locals view differs
completely by bitness:

    x64:  S, ComputeNested.X, ComputeNested.D1, ComputeNested.Ext1,
          ComputeNested.R48, ComputeNested.D
    x86:  S

The whole enclosing scope is missing on Win32 -- not merely `evaluate`, the
LOCALS list too. A nested routine reading its parent's variables is ordinary
Delphi structure, so this is a real gap rather than an edge case. Note the
existing `FrameScopedEvaluation_...` test does NOT cover it: it selects the
parent FRAME explicitly with `EvaluateForFrame`, which works on both bitnesses.
What fails is Delphi's LEXICAL scoping -- the parent's locals reachable from the
child by bare name.

Cause: `TWinDebugger.ReadParentFramePointer` is hardcoded to the Win64 ABI --
the static link arrives in RCX and is spilled to the first home slot at
`RBP + frameSize + extraPushes + 16`. Win32 has no home slots, so the read
returns whatever is at that address and the climb produces nothing. It is an
architecture seam that was never overridden for the 32-bit target.

MEASURED (`DevTools\Win32NestedLinkProbe.dpr`, four shapes): dcc32 passes the
static link as a hidden STACK parameter pushed LAST, so it sits immediately
above the declared stack parameters:

| Nested routine | Static link at |
|---|---|
| `procedure Inner` (no params) | `[EBP+8]` |
| `procedure Inner(Depth: Integer)` (1 register param) | `[EBP+8]` |
| `procedure Inner(A, B, C, D: Integer)` (1 stack param) | `[EBP+12]` |

i.e. `[EBP + 8 + declaredStackParamBytes]`. The probe needed a RECURSIVE shape
to establish that: when the nested routine is called directly by its parent --
every other shape -- the saved caller EBP at `[EBP+0]` also equals the parent's
EBP, and that coincidence looks exactly like a match.

TD32 does NOT record the link as a symbol on either bitness (checked with
`Td32AliasProbe -proc Inner`), so the address has to be computed.

NOT implemented, and deliberately not rushed: getting
`declaredStackParamBytes` wrong yields a plausible WRONG parent frame, i.e.
confident wrong values for every parent local. Whatever computes it must be
VERIFIED before use -- the candidate has to match the nearest frame on the walked
stack whose function is the enclosing routine, and the climb must decline (and
show only the child's own locals, as today) when it does not.

### A non-virtual getter in a symbol-less module cannot be invoked

Measured in the same real-application session. On a live `TfrmMain`:

| Expression | Result |
|---|---|
| `Self.ClassName` | `'TfrmMain'` |
| `Self.Caption` | `'Gestione Allestimenti Container in Magazzino'` |
| `Self.Name` | `'frmMain'` |
| `Self.Width` | `1081` (field-backed, read directly) |
| `Self.Owner` | `$21D9E8B0 (TComponent)` |
| `Self.ComponentCount` | `<method invocation failed>` |
| `Self.ControlCount` | `<method invocation failed>` |

The pattern that fits: the ones that work are VIRTUAL getters, whose address
comes from the object's VMT, or fields. `TComponent.GetComponentCount` and
`TWinControl.GetControlCount` are not virtual, so invoking them needs a SYMBOL —
and the VCL in this application is linked without debug info.

That makes the failure honest rather than wrong, and no fix is obvious short of
symbols for the VCL. Recorded because "why does Caption work and ComponentCount
not" is otherwise a puzzling report.

The suspicious `Self.Handle` value noted alongside this turned out to be a
DIFFERENT and worse defect, since fixed: `Obj.Member` fell back to resolving the
leaf name as a global, so `Self.HandleAllocated` and a bare `HandleAllocated`
answered the same number. See "a member lookup stays scoped to its receiver" in
`DAP_DEBUGGER_ARCHITECTURE.md`.

STILL UNVERIFIED after that fix: `Self.Handle` itself. It is an RTTI property,
so it takes the property path rather than the leaf fallback, and it has not been
re-measured. Do not treat it as a known defect without doing so.

### A bare identifier can resolve to an enum member of a NESTED type

Found by running the debugger against a real 32-bit VCL application
(`hydra_2\ExtApps\AppContainer`), which is the only way it would have surfaced:
the target has TD32 for 5 source files, an `.rsm`, and no MAP, so the VCL's
`Application` variable is in none of them.

Evaluating `Application` answers with the member of DevExpress's
`TPopupMenuKind = (External, VCL, Application)` — declared INSIDE a class in
`dxPopupMenus.pas`. `Ord(Application)` returns 2, consistent with that. The
value is not fabricated: the symbol exists. It is simply not the one the user
asked for, and Pascal says so — the members of a NESTED type are not reachable
by a bare name from anywhere. `ExprEval` falls back to
`TryResolveEnumLiteral(Name, ...)` after `ResolveIdent` misses, and that lookup
applies no scoping at all.

Contrast `Screen`, which honestly answers "not found" in the same session.

CONFIRMED ON A SECOND REAL APPLICATION (Hydra2, 2026-08-03), so it is not a
quirk of one binary.

AND NARROWED, by an attempt that FAILED and was reverted. Reading CodeView's
`LF_NESTTYPE` ($0409) — which the field-list parser recognises and skips — to
build the set of class-nested type names, then refusing enum literals from
those, changed NOTHING. The reason is worth more than the attempt: searching
both of `AppContainer.exe` and `AppContainer.rsm` for the string
`PopupMenuKind` finds it in NEITHER. The enum is not in the application's own
debug info at all — it comes from the type tables of ANOTHER LOADED MODULE.

So this is not a TD32 field-list gap. A bare identifier is resolved against
every loaded module's types, and the fix has to be about WHICH MODULE AND SCOPE
may answer, not about one reader's parse. Enums nested in a ROUTINE must keep
working either way: those ARE bare-visible inside that routine, and the test
target depends on it (`TColor = (Red, Green, Blue)` in RunTypeSampler).

Fix direction, in order of preference:
  * Do not let an enum member satisfy a bare identifier when its enum type is
    NESTED. That is a language fact, not a preference. Needs the provider to
    report the nesting — `TryResolveEnumLiteral` currently returns only the leaf
    type name (`TPopupMenuKind`), with the qualification already lost.
  * Failing that, apply the frame's uses scope, as `TryResolveConstScoped`
    already does for constants. Weaker here, because a `.dpr` transitively uses
    almost everything.

## Class-member field typeId encoding on large type spaces (BLOCKS #2)

On SampleApp the type NAME shown for a class field/property is wrong whenever the
field's typeId VLE needs more than 1 byte. `TApplication.HintColor` (a
field-backed `TColor`) expanded in the variables view as a `TVarData` record
(garbage) because its type resolved wrong.

### CRACKED via controlled experiment (ground truth)

A controlled target (a generated `.dpr` emitting 17000 named
record types `T00001..T17000` and a class with one field per type, so typeIds
cross the 16-bit boundary) gives the typeId↔type correspondence WITHOUT
inference. Result — the field typeId VLE width is selected by the low bits of
byte0:

| byte0 bits   | width | typeId value                    |
|--------------|-------|---------------------------------|
| bit0 = 0     | 1     | `B`                             |
| bit0=1,bit1=0| 2     | `B or B2<<8`            (direct) |
| bit0=1,bit1=1| 3     | `(B or B2<<8 or B3<<16) shr 1`  |

Verified: T16129 (real typeId 65537) encodes `03 00 02` → `$020003 shr 1` =
65537; T17000 (69021) → `3B 1B 02` → 69021. The OLD decoder read at most 2
bytes, so any typeId > 65535 was TRUNCATED to garbage. On a single small unit
the truncation was self-consistent (decl and field truncated to the same value,
so it "resolved" by coincidence); on SampleApp's many units the truncated values
collide in the global typeId→name map → wrong type.

The earlier "`*2+1`/`shr 1` = import index" idea is dead (it matched a desynced
naive parse). The `$9F` record (5 bytes: tag + 4-byte payload, no name) and the
`$63$35`/`$35` uses-clusters are real and were obstacles to enumerating the
import area, but the import-POSITION theory is not how typeIds map.

### LANDED (A): 3-byte typeId VLE decode

`ClassMember_ReadTypeIdVLE` now decodes the 1/2/3-byte form above; M.TypeId for
3-byte ids is correct (65537 instead of 3). `RSM_SIDECAR_MAGIC` bumped to `RSI8`
so pre-fix `*.rsm.idx` caches regenerate. Suite green (332). This alone does NOT
yet fix SampleApp display — see remaining work.

### LANDED (full mapping): decode + import-index resolution

A controlled MULTI-unit experiment (UTypes declares records + aliases; a second
unit's class has one field per imported type) pinned the resolution with ground
truth: the field's **import-table index = (ImportTypeId div 2) - 1**, where
**ImportTypeId = raw VLE value shr 1** (for ≥2-byte ids). Verified exactly:
T001 importIdx 255 ↔ fieldTypeId raw 1025 (`shr1`=512, `(512/2)-1`=255); T200
→454; TAliasInt →455; TAliasStr →456 (aliases resolve too).

Implemented:
- `ClassMember_ReadTypeIdVLE` returns the RAW LE value; `ClassMember_TryDecode`
  also sets `ImportTypeId = TypeId shr 1` (multi-byte) / `= TypeId` (1-byte).
- `DecodeClassMembers` resolves `ResolveTypeNameForUnit(ImportTypeId)` first
  (owning unit's `$66` imports), then falls back to `LookupTypeName(TypeId)`
  (raw) for LOCAL class refs not in the import list (e.g. `Exception` via the
  class-hash registry — keeps `ClassTypedField_…` green).

The earlier "shr 1 is disproven" note was itself WRONG: shr 1 IS correct; the
disproof compared against a mis-counted import list. Verified green (332) and on
the controlled target (imported records + aliases all resolve).

### LANDED for SampleApp: `$9F` handling in the import parse

`CollectImportsAt` now advances over the `$9F` record (5 bytes, no name, no
slot). Forms' import list went 119 → **377**, and the low-to-mid fields now
resolve correctly on SampleApp:
`HintColor` → **TColor** (was `TComparer`), `FDefaultFont` → TFont,
`FIcon` → TIcon, `FHint` → UnicodeString. `RSM_SIDECAR_MAGIC` bumped to `RSI9`.
The originally-reported bug (HintColor expanding as a TVarData record) is fixed.

### LANDED: principled import parse + resolution that keeps the suite green

`CollectImportsAt` drops the heuristic band-aids ($9F 5-byte record handled;
uses-cluster `[$63]* $35 LEN Name` extent is the smallest one landing on a
structurally-valid next record via `IsImportRecordStart`, else STOP; the 32-byte
skip-1 resync is gone — unknown tag STOPs the walk). Kept.

Member-type resolution (`RsmFileReader.DecodeClassMembers`), current and green:

1. `ResolveTypeNameForUnit(UnitName, M.TypeId, UnitImports, FUserTypes)` — the
   declared/1-byte path (`ResolveTypeNameForUnit` needs an EVEN id; 1-byte
   typeIds are even). Resolves single-unit declared types.
2. if empty AND multi-byte (`ImportTypeId <> TypeId`):
   `ResolveTypeNameForUnit(UnitName, M.ImportTypeId, UnitImports, nil)` — the
   import-index path. `ImportTypeId = raw VLE shr 1` is even and selects the
   owning unit's `$66` entry. Tried BEFORE the global lookup.
3. if still empty: `LookupTypeName(M.TypeId)`.

> The earlier attempt that used ImportTypeId-only + dropped `FUserTypes` + a
> class-hash candidate fallback REGRESSED the suite (`High(TWorkMode)`→Pointer,
> dyn-array eval hang) — it was validated only against a stale adapter
> (build_runner does not rebuild the EXE). Reverted in `3248e0e`; the green
> reorder above landed in `9726203`. The `FClassHashCandidates` fallback is no
> longer in this path.

Verified on SampleApp (`9726203`): `HintColor` → **0 [TColor]** (the originally
reported bug), `HelpSystem` → IHelpSystem, `DefaultFont` → TFont, `HintControl`
→ TControl, `Icon` → TIcon — correct via the import-index path.

`RSM_SIDECAR_MAGIC` stays `RSIB`: member-type resolution runs at evaluate time,
not in the sidecar, and the import parse is unchanged — no bump needed for the
resolution reorder.

### LANDED: drill-down gated by member TypeKind (no garbage expansion)

`DapServer.FieldDrillDownRef` now takes the member's `TypeKind` and refuses to
allocate an expansion unless the kind can hold sub-members (class / record /
interface / dyn-array / array), or is unknown (so the RTTI-offset fallback can
still type an RSM-untyped field — that path keys on the real RTTI field's own
expandability). Killed the pervasive bug where every ordinal property expanded
into bogus class members (e.g. `Application.Active` → `SerialNumber
[TCustomAttributeClass]`, `FZoomInCursor [WordBool]`). Suite green (332).

### LANDED: getter-call hang guard (was the "dyn-array hang")

`ResolveRsmMethodProp` (ExprEval) defaulted an unresolved property type to
'Pointer' before invoking the getter. For a managed/var-out return (dyn-array /
string / Variant / large record) that guess mis-sets the calling convention; the
synthetic call never returns to the INT3 trap, so `RunMethodCall`'s
`WaitForDebugEvent(INFINITE)` blocks forever and the adapter hangs. It now
refuses the call when the return type is unknown
(`<name: getter return type unknown>`). PROVEN by gating type resolution so the
dyn-array getter property resolves empty: the two dyn-array tests then fail
GRACEFULLY instead of timing out. This was the real cause of the "dyn-array eval
hang" the earlier ImportTypeId-only attempt hit — not the resolution itself.

### REMAINING (gaps, in fix order)

> **SUPERSEDED for the variables view (commit `fd4be94`).** The variables-view
> member display now resolves class members through the embedded **TD32** first
> (`TDapServer.GetDisplayMembers`), which carries correct member types AND byte
> offsets for the full class hierarchy. On SampleApp this fixed every member that
> the RSM index mis-typed or mis-offset (FMainForm [TForm], BiDiMode
> bdLeftToRight, ModalLevel 0, HelpSystem [IHelpSystem], Title 'Sample App', ...)
> WITHOUT extending the RSM declaration-section parse at all. So gap #1 below
> (reverse-engineering the RSM type-declaration block to push the import index
> past 377) is **no longer worth doing for the variables view** -- TD32 is the
> source of truth there. It would only matter if RSM had to stand alone (remote
> debugging without a `.debug` section); RSM stays as the fallback + ExprEval
> source. The full goal is to drop RSM entirely (see "Drop RSM" below): that
> needs ExprEval ported to TD32, not more RSM parsing.

1. ~~**Extend the import parse through the unit's type-declaration block.**~~
   (Superseded -- see the note above. Kept for reference / the RSM-only path.)
   Forms' `$66` import list reaches idx **377** (commit `8c2fe61`
   added handlers for `$63$65` inner-uses, `$25` enum members, `$9C 08` doc
   comments, `$37` class-init fields, and hardened `IsImportRecordStart` against
   `$64/$65` and stray-`$9F` false matches). Member typeIds resolve as: index =
   `(ImportTypeId div 2) - 1`, ImportTypeId = raw VLE shr 1. Confirmed via a
   `MEMTYPE` probe on TApplication:

   | member                | ImportTypeId | index | result                |
   |-----------------------|-------------:|------:|-----------------------|
   | FHintColor            | 450          | 224   | TColor ✓ (idx<377)    |
   | FBiDiMode             | 420          | 209   | TBiDiMode ✓           |
   | FMouseControl         | 490          | 244   | TControl ✓            |
   | FInitialMainFormState | 334(approx)  | 166   | TWindowState ✓        |
   | FDefaultRoundedCorners| 756          | 377   | WRONG (idx = nImports)|
   | FModalPopupMode       | 784          | 391   | WRONG                 |
   | FMainForm             | 790          | 394   | WRONG (→ IEnumerator) |
   | FOnGetMainFormHandle  | 888          | 443   | WRONG                 |

   So everything with index < 377 is correct; index ≥ 377 falls to
   `LookupTypeName(rawOdd)` = a colliding wrong type. The `$66` type-refs DO
   continue past 377 (to ≥444), but they sit AFTER a long type-declaration block
   that the parse cannot yet size. The same unreached range also yields wrong
   field OFFSETS → garbage VALUES (`ModalLevel`=20654968, `HintPause`=17601024,
   recurring 0x13B2B78).

   The blocking block is the unit's own type declarations, interleaved:
     - `$2A LEN Name <core>` type definition (TScrollBarKind, TFormBorderStyle…)
     - `$26 LEN .Name <core>` forward-ref (name has a leading '.')
     - core is 10 OR 13 bytes (first payload byte differs: `A8/E0/A0` ⇒ 13,
       `80/88` ⇒ 10 — hypothesis from 5 samples, NOT confirmed), optionally
       followed by a `$9C` doc.
     - `$9C` doc subkinds seen: `9C 08`, `9C 01`, `9C 13`, all `</summary>` text
       terminated by `$FF`. PROBLEM: `9C` is overloaded — `9C 1D` appears as
       DATA inside `$25` enum payloads, so a doc cannot be recognised by `9C`
       alone (relaxing the `9C 08` guard regressed the parse). Disambiguation
       likely needs the preceding record's context (a doc only follows a $2A/$26
       core), not a global tag test.

   A tried `$2A/$26` handler (smallest-valid-landing) parsed several type decls
   but stopped at `$2A PHintInfo`'s `9C 01` doc and added zero `$66` (the type
   slot count stayed 377), so it was reverted as net-zero + desync surface. The
   real fix needs the type-decl core-length and the doc-vs-data `9C`
   disambiguation worked out from format notes / controlled targets, NOT
   per-obstacle landing guesses.

   DEEPER FINDING (second push, also reverted): the block past idx 377 is the
   unit's FULL declaration table, not a list of compact type refs. It contains
   `$2A` type definitions (incl. nested/anonymous names like
   `TApplication.TBiDiKeyboard`, `:TApplication.:1` — leading `.`/`:` and
   embedded `$`, so a `ValidDeclName` looser than `ValidUnitName` is needed),
   `$26` forward-refs, `$25` enum members, `$9C` docs (subkinds 01/08/13/17, all
   `</summary>` text + `$FF`), AND full class definitions with member records
   (`$20` var / `$2C` field / `$2E` method / `$31` property — e.g. right after
   `$2A TApplication` comes `$20 0B Application`, the global var). The type-decl
   cores are variable-length (a bit5-of-first-byte rule was DISPROVEN: two `80`
   cores were 9 and 10 bytes). nImports stays 377 through the whole block.

   So the unit type table is almost certainly `[$66 imports] + [type decls]` with
   ONE numbering: FMainForm's index 394 = 377 + ~17th type decl, which should be
   TForm. To confirm + fix: parse the declaration section counting `$2A`/`$26`
   as type slots (append their names to the per-unit list) while SKIPPING the
   var/member/doc records between them (member extents via the existing
   `ClassMember_FindRecordEnd`). VERIFY with the MEMTYPE probe that FMainForm ->
   TForm before trusting it. This is a substantial declaration-section parser,
   not a landing guess — do it deliberately. A doc-aware smallest-valid-landing
   `$2A/$26` skip + `ValidDeclName` got the walk through several nested type
   decls before stalling on the `$20` global-var record; that code is the
   starting point (reverted, small to redo).

   Once import indices ≥377 resolve, the `LookupTypeName(rawOdd)` collision guess
   can be dropped (correct-or-unknown) — but NOT before: it is load-bearing on
   single-unit targets (TestTarget's `TWorkMode` enum and
   `Exception.FInnerException` resolve only through it; the import-index path
   can't reach them, so dropping it fails High(TWorkMode) and
   ClassTypedField_ResolvesViaClassHashCandidates).

   A `DAP_LOG`-gated `IMPORTSTOP` probe (logs the stop offset + bytes for the
   Forms unit) and a `MEMTYPE` probe are the tools for this; re-add the MEMTYPE
   one when resuming.
2. **RSM getter→method hash linkage for non-field-backed getters.** On SampleApp,
   getter-backed properties whose getter is not field-backed fail to link:
   `HintControl` / `ActiveFormHandle` / `DialogHandle` / `MainFormHandle` show
   `<.HintControl not found>` when expanded, while string getters work
   (`ExeName`, `Title`, `CurrentHelpFile`). In RsmDot's cmkProperty branch the
   property's `GetterHash` matches no decoded method member (FieldOffset=0,
   GetterName='' on the RSM-only path) → falls through to `<.%s not found>`
   (ExprEval.pas:1354). Work out why some getters link and others do not (getter
   method record not decoded / hash algorithm mismatch). NOTE: the variables
   view no longer hits this (TD32 supplies the getter name + the on-demand node);
   this remains only for the RSM/ExprEval path.

### RSM dependency removed -- RESOLVED (2026-07-01)

The `.rsm` file is no longer required. See PROJECT_STATE.md ("RSM is optional")
for the shipped behaviour. Summary of what the investigation actually found
(corrected against the earlier, partly-wrong hypothesis above):

- **The `.dcp` is RSM-format** (both parsed by `TRsmFile`) and is NOT gated. So a
  BPL target never needed `.rsm` at all -- its `.dcp` supplies the rich Pascal
  type/member/property/enum/uses data. Only a MONOLITHIC exe (no `.dcp`) used
  `.rsm` as its sole RSM-format sidecar.
- Measured with a `NO_RSM=1` gate: 85 mono failures, 0 BPL failures. **~73
  cascaded from ONE root** -- the eval tests used `TheWidget`/`TheStuff`, the
  `.dpr` program-main-block inline vars, as the receiver. A one-off probe that
  walked the TD32 main-block scope proved those inline vars are **genuinely ABSENT from
  TD32** in every record kind -- NOT a decodable parser gap (the earlier "decode
  the main-block scope" plan was moot). Resolution: the eval tests were
  **realigned** to a portable named-proc receiver (`W`/`S` created in
  `RunEvalTests`, marker `EVAL_BODY`, runs in both scenarios) -- TD32 resolves
  those. A one-off TD32-vs-RSM parity probe confirmed TD32 already carries full class members
  (offsets+types incl. NonRtti), enum/set metadata, getter `Result` locals, and
  the class hierarchy for a mono exe -- so property/method/enum/is-as eval work
  WITHOUT `.rsm` once the receiver is TD32-visible.
- **5 capabilities remain RSM-format-only** (data absent from TD32; each guarded
  by `SkipIfNoRsm`, which skips ONLY in the mono scenario when `.rsm` is off --
  a BPL keeps them via `.dcp`, a mono exe keeps them with a fresh `.rsm`):
  1. `.dpr` program-main-block inline-var locals (compiler emits no TD32 record).
  2. Date/time alias fidelity -- TD32 flattens `TDate`/`TTime`/`TDateTime` to
     `Double` (`LookupTypeKind('TDate')=$00`); the alias survives only via RSM.
  3. Cross-unit uses-scope resolution (`IUnitUsesProvider`) -- TD32 has no
     uses-graph to pick the used unit for ambiguous names.
  4. Unit-scoped consts (`IUnitScopedConstProvider`/`FindConstInUnit`) -- const
     values are not in the TD32 symbol table.
  5. Nested-proc inline `Variant` local (`vnest`) -- absent from TD32.
- Enum/set + free-proc/method return-ABI (old gaps #3/#4) turned out to be part
  of the receiver cascade, not standalone TD32 gaps -- fixed by the realignment.

Probes: one-off walkers — a TD32 main-block scope dumper and a TD32/RSM parity
dumper (not retained; the findings above are the record).

### Also landed earlier (independent correctness): `ValidUnitName`

`CollectImportsAt` gates `$63$64 / $64 / $65 / $6E` records on a
printable-identifier name so a stray byte cannot masquerade as a unit-ref and
swallow following records. Kept (correct on its own). The earlier import-area
truncation analysis ($9F 5-byte record, `$63$35`/`$35` uses-clusters, the
32-byte stall) is now secondary — it mattered only to the dead import-position
theory; the live work is (B)/(C) above.

**Sidecar caveat:** `*.rsm.idx` is NOT auto-invalidated on parser changes, so a
parse-changing fix is masked until the magic bumps. `RSM_SIDECAR_MAGIC` is now
`RSIB`. Bump it again on any future change to what `CollectImportsAt` /
`ParsePerUnitImports` write into the sidecar (member-type resolution itself runs
at evaluate time and does NOT need a bump).

Probe scaffolding for this diagnosis was a set of one-off dumpers (not retained;
recreatable from the record layouts in `RSM_FIELD_OFFSETS.md`): a field→raw
bytes→expected type dumper, per-unit import dumps for a single unit and for all
units (the latter with no-truncation resync), a `$08` TypeInfo enumeration, and a
stall finder that locates the import-parse stall offset + bytes.

## Large-project scale (SampleApp / 780 MB RSM)

- **Cold-start scan duration** — MAP and RSM sidecar index files (`.map.idx`,
  `.rsm.idx`) are written on the first run and loaded in milliseconds on
  subsequent runs. The one-time cold-start sequential scan of 780 MB RSM
  duration under SampleApp has not been measured. Does it noticeably delay the
  first debug session?
- **Memory footprint** — with hundreds of modules lazily cached, total
  resident set of the adapter under real use on SampleApp is unknown.
- **Symbol lookup latency** — at 780 MB, even a binary search over the
  module index may be slow if the index itself is large. Not yet measured.

## Process / repo

- **VS Code extension publishing** — currently a manual local copy
  to `%USERPROFILE%\.vscode\extensions\local.delphi-win64-debug\`.
  Marketplace publishing path is undecided.
