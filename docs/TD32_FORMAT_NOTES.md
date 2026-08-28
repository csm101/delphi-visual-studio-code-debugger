# TD32 format notes (Embarcadero Athens 36)

Embarcadero's Delphi Athens 36 emits debug info into a PE `.debug`
section in a Borland-extended dialect of Microsoft CodeView v4 ("TD32").
The reader for it lives in
`DebuggerCore\TD32FileReader.pas`. This document
captures the parts of the format we have actually validated against
`DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe` and
`C:\Athens\sample_app\Win64\Debug\SampleAppSingleExe.exe` (the second one is
useful precisely because its scale exposes encoding details TestTarget
glosses over).

The container is not pointer-sized: the reader parses `dcc32` (PE32) output
**unmodified**, and `Td32ProcNesting` works on PE32 and PE32+ alike regardless
of its own bitness. The one thing that does differ per compiler is name
mangling — see "Borland demangler" below.

## Container layout

1. PE section `.debug` (raw offset taken from the section header), or — when no
   such section exists — the blob appended past the image with nothing
   describing it. `LoadFromFile` falls back to `FindAppendedDebugBlob`, which
   seeks the trailer at the end of the FILE (signature + distance back to the
   start of the blob) and re-checks the signature there. The section walk still
   always runs: it is what builds the segment → RVA tables and the image base,
   without which no CodeView offset can be translated, so the PE is not
   redundant even when the blob is not in a section.
2. Inside the section: the bytes `46 42 30 39` (`'FB09'` little-endian =
   `$39304246` -- `TD32_SIGNATURE`) mark the start of the TD32 block.
   C++Builder stamps `'FB0A'` (`$41304246`) on an otherwise identical
   container; both are accepted (`IsTD32Signature`) and which one was found is
   kept in `ContainerSignature`. **Container level only** — no C++Builder binary
   has been tested against this reader and C++ demangling is not implemented.
3. Header at TD32 base:

   | offset | size | meaning                                            |
   |-------:|:----:|----------------------------------------------------|
   |   `+0` | u32  | signature `$39304246`                              |
   |   `+4` | u32  | offset from TD32 base to the directory             |

4. Directory header (at the offset above):

   | offset | size | meaning                                            |
   |-------:|:----:|----------------------------------------------------|
   |   `+0` | u16  | `cbDirHeader` (header byte count, ≥ 16)            |
   |   `+2` | u16  | `cbDirEntry`  (per-entry byte count = 12)          |
   |   `+4` | u32  | `cDir` (entry count)                               |

5. Directory entries follow immediately. Each entry is 12 bytes:

   | offset | size | meaning                                             |
   |-------:|:----:|-----------------------------------------------------|
   |   `+0` | u16  | `subType` (`SST_*` constant)                        |
   |   `+2` | u16  | `modIndex` (module ordinal, 0 for global tables)    |
   |   `+4` | u32  | offset of the subsection FROM THE TD32 BASE         |
   |   `+8` | u32  | subsection byte size                                |

Subsection types we read today:

| Code   | Name                | Used for                                        |
|-------:|---------------------|-------------------------------------------------|
| `$120` | `SST_MODULE`        | module / source bookkeeping                     |
| `$121` | `SST_TYPES`         | per-module type table (see below)               |
| `$124` | `SST_SYMBOLS`       | per-module symbol stream                        |
| `$125` | `SST_ALIGN_SYMBOLS` | aligned symbol stream (where LPROC32 / GPROC32  |
|        |                     | / BPREL32 / GDATA32 live in Athens 36)          |
| `$127` | `SST_SOURCE_MODULE` | file / segment / line table                     |
| `$129` | `SST_GLOBAL_SYMBOLS`| global symbol stream                            |
| `$12B` | `SST_GLOBAL_TYPES`  | section-wide type table                         |
| `$130` | `SST_NAMES`         | NAMES string pool                               |

## NAMES section (`SST_NAMES`)

```
+0    u32       count          -- number of names
+4    name[0], name[1], ...
```

Each `name`:

```
+0    u8        len            -- byte length, modulo 256
+1    bytes[len]               -- payload (UTF-8)
...   bytes 256*k              -- additional 256-byte chunks until a NUL
+N    u8 = 0    terminator
```

The "stops at NUL after 256-byte chunks" trick lets the format encode
names longer than 255 bytes without giving up the 1-byte length field.

`BuildNamesIndex` walks the table once at load time and records, per name index,
**where** the name is (`TTD32NameSpan`: offset + length into the mapped
segment) — not what it says. `ResolveNameByIndex` decodes on demand. The walk
must still visit every entry, since an entry can only be found by stepping over
the one before it, but it no longer allocates a managed string for each: a
container holds tens of thousands of names (32 599 in the 64-bit TestTarget) and
a session asks for a fraction of them.

Two properties are load-bearing and must not be traded away for a cache:

- the span table is complete before the reader is published, and
- `ResolveNameByIndex` only READS it.

An earlier version resolved names lazily by mutating the reader (`SetLength` +
element writes + a dictionary `Add`) from the naming path. The reader has no
lock and is shared by every consumer of a module's symbols, so two threads
naming addresses in the same module raced a dynamic-array realloc and the cache
raised a duplicate-key `EListError` out of a stack trace. Decoding on demand is
safe **because** it allocates only into the result.

Measured (mean of 5, this machine), eager strings → spans:

| binary | names | load | working set held |
|---|---:|---:|---:|
| TestTarget x64 | 32 599 | 45.6 → 41.0 ms | 15 548 → 12 948 KB |
| TestTarget x86 | 30 084 | 35.1 → 29.5 ms | 14 716 → 12 272 KB |
| Debugme x64    | 17 304 | 11.1 → 7.4 ms  | 2 472 → 2 468 KB |

Debugme is the honest counter-example: its load resolves nearly every name it
holds, so only the time moves. `DevTools\Td32LoadBench.exe` produces this table.

Names are Itanium-mangled, optionally with one of the Borland-specific
`_ZT?` prefixes:

- `_ZTR<NESTED>` -- type record (a class / record / enum descriptor).
- `_ZTI<NESTED>` -- type info (the System.TypInfo.TTypeInfo pointer).
- `_ZTS<NESTED>` -- type name string (a UTF-8 form of the qualified
                    Delphi type name).
- `_ZTV<NESTED>` / `_ZTT<NESTED>` -- vtable / VTT.

`DecodeFriendlyTypeName` strips the 2-letter discriminator so the
embedded `_ZN...E` form goes through the standard Itanium demangler
already used for symbol names.

## Type table (`SST_TYPES` / `SST_GLOBAL_TYPES`)

Both subsections share the same layout. `SST_TYPES` is emitted per
module, `SST_GLOBAL_TYPES` once for the whole image. Records from
multiple sections are concatenated into a single `TTD32FileReader.FTypes`
array.

```
+0                 u32   version (= 1)
+4                 u32   NumRecs
+8                 u32[NumRecs]  -- offset of each record FROM THE
                                    SUBSECTION BASE.
+8 + 4*NumRecs     records (variable size)
```

Each record:

| offset | size | meaning                                              |
|-------:|:----:|------------------------------------------------------|
|   `+0` | u16  | `cb` -- byte count EXCLUDING this field. Total = cb+2 |
|   `+2` | u16  | `leafCode` (`LF_*`)                                  |
|   `+4` | bytes| payload (`cb-2` bytes)                               |

### TypeId encoding

`BPREL32` and `GDATA32` records carry a 32-bit `TypeIdx`. The mapping
to a record in the type table is:

```
TypeId = $1000 + recordIndexInSection
```

`TypeId` values below `$1000` are reserved for the compiler-predefined
primitives (Integer / Cardinal / Boolean / ...). They are NOT stored in
the type table; the small-int family currently has no name table on the
TD32 side and is left to fall through to the by-name decorators in the
adapter.

### Leaf decoders we implement

| Leaf    | Name            | Payload                                              |
|--------:|-----------------|------------------------------------------------------|
| `$0001` | `LF_MODIFIER`   | `attr : u16 ; modifiedType : u32`. Transparent       |
|         |                 | passthrough through GetTypeName -- the modifier name |
|         |                 | resolves to the underlying type.                     |
| `$0002` | `LF_POINTER`    | `attr : u16 ; target : u32` (8 bytes)                |
| `$0003` | `LF_ARRAY`      | `elemType : u32 ; idxType : u32 ; size : numeric ;`  |
|         |                 | `nameIdx : u32`. Unnamed arrays render as            |
|         |                 | `array[0..N-1] of ElemType` when size is known.      |
| `$0004` | `LF_CLASS`      | `count : u16 ; fieldList : u32 ; property : u16 ;`   |
|         |                 | `derived : u32 ; vshape : u32 ; reserved : u32 ;`    |
|         |                 | `nameIdx : u32 ; size : u16`                         |
| `$0005` | `LF_STRUCTURE`  | same shape as `LF_CLASS`                             |
| `$0006` | `LF_UNION`      | `count : u16 ; fieldList : u32 ; property : u16 ;`   |
|         |                 | `size : numeric ; nameIdx : u32`                     |
| `$0007` | `LF_ENUM`       | `count : u16 ; baseType : u32 ; fieldList : u32 ;`   |
|         |                 | `reserved : u32 ; nameIdx : u32`                     |
| `$0008` | `LF_PROCEDURE`  | `retType : u32 ; callConv : u8 ; funcAttr : u8 ;`    |
|         |                 | `parmCount : u16 ; argList : u32`                    |
| `$0009` | `LF_MFUNCTION`  | `retType : u32 ; classType : u32 ; thisType : u32 ;` |
|         |                 | `callConv : u8 ; funcAttr : u8 ; parmCount : u16 ;`  |
|         |                 | `argList : u32 ; thisAdjust : i32`. Return type      |
|         |                 | exposed; rest still opaque.                          |
| `$000A` | `LF_VTSHAPE`    | recognised; payload not surfaced                     |
| `$0012` | `LF_VFTPATH`    | recognised; payload not surfaced                     |
| `$0201` | `LF_ARGLIST`    | recognised; payload not surfaced                     |
| `$0204` | `LF_FIELDLIST`  | container of sub-records (see below)                 |
| `$0205` | `LF_DERIVED`    | recognised; class hierarchy ancestors not surfaced   |
| `$0207` | `LF_METHODLIST` | recognised; payload not surfaced                     |

### Field-list sub-records (decoded)

`LF_FIELDLIST` carries per-class / per-struct member descriptors. The
walker advances past one sub-record at a time, honouring the
CodeView `$F1..$FF` padding markers between records:

| Sub-leaf | Name            | Record size                                         |
|---------:|-----------------|-----------------------------------------------------|
| `$0400`  | `LF_BCLASS`     | 12 bytes (leaf+type+attr+offset+2-pad)              |
| `$0403`  | `LF_ENUMERATE`  | variable: leaf(2) attr(2) value(numeric) nameIdx(4) |
| `$0406`  | `LF_MEMBER`     | 16 byte prefix + 2-byte numeric offset + pad        |
| `$0407`  | `LF_STMEMBER`   | 12 bytes (advanced over)                            |
| `$0408`  | `LF_METHOD`     | 12 bytes (leaf+count+methodList+nameIdx)            |
| `$0409`  | `LF_NESTTYPE`   | 12 bytes (advanced over)                            |
| `$040A`  | `LF_VFUNCTAB`   | 8 bytes (advanced over)                             |

`LF_MEMBER` records produce one entry in `TTD32TypeRecord.Members`.
On `tkClass` records, sub-records whose decoded offset is zero are
filtered out -- the slot is reserved for the VMT pointer, never a
user field, and Borland emits Pascal property descriptors as
LF_MEMBER-with-offset-zero pointing at the `$0030..$003A` Borland
TYPES extensions.

`LF_ENUMERATE` records populate the same Members array; the value
is read from the numeric leaf and the name from the trailing
NameIdx. `LookupEnumInfo` exposes the min/max bounds and names for
ordinal lookup.

### Borland Pascal TYPES extensions ($0030..$003A)

Top-level type records in this range carry Pascal-specific
descriptors that don't exist in standard CodeView. We treat them as
transparent modifier-style passthroughs: payload+0 holds the
underlying TypeId, and `GetTypeName` follows the chain so the
formatter sees the real primitive / class / record. Empirically:

| Leaf    | Use                                                       |
|--------:|-----------------------------------------------------------|
| `$0030` | property descriptor (paired with LF_MEMBER offset=0)      |
| `$0031` | subrange of an ordinal base                               |
| `$0032` | set type (base + element)                                 |
| `$0033` | non-integer ordinal range (`'A'..'Z'`, ...)               |
| `$0034` | generic parameter slot                                    |
| `$0035` | property descriptor on Athens (36) -- see below            |
| `$0036` | 1-typeId alias                                            |
| `$0038` | class-reference / metaclass                               |
| `$0039` | rare                                                      |
| `$003A` | rare                                                      |

**Measured 2026-07-21, Athens (compiler 36):** the property descriptor
paired with an offset-0 `LF_MEMBER` is leaf **`$0035`**, not `$0030`, in
every binary checked (`TestTarget.exe`, `TestHost.exe`). The earlier
"`$0035` = set over enum / subrange" reading is not confirmed and may
have come from an older compiler. The reader does not depend on which one
it is -- it accepts the whole `$0030..$003A` range as a descriptor -- so
this is a documentation correction, not a behavioural one.

#### `$0035` property descriptor payload (22 bytes)

| Offset | Size | Meaning                                                     |
|-------:|-----:|-------------------------------------------------------------|
| `+0`   | u32  | underlying property type                                    |
| `+4`   | u16  | access kind: `4` = read backing field, `6` = read via getter. **Bit 0 = Pascal `default`** (so `7` = getter-backed default property) |
| `+6`   | u32  | index-args ARGLIST TypeId; `0` for a non-indexed property   |
| `+10`  | u16  | zero                                                        |
| `+12`  | u8   | zero                                                        |
| `+13`  | u8   | `$80` variable-numeric tag                                  |
| `+14`  | u32  | field offset when kind = 4, else NAMES index of the getter's mangled name |
| `+18`  | u32  | zero                                                        |

The `default` bit was established with a fixture carrying two array
properties that differ only in that marker (`TestTargetCore.TIndexProbe`),
and cross-checked against the RTL: `TStrings.Values` (string index, NOT
default) reads `0006` while `TStrings.Strings` (Integer index, default)
reads `0007` -- index type and the flag vary independently, so the bit is
not an artefact of the index type. Census: 45 of 1027 descriptors in
`TestTarget.exe` carry it, never more than one per class.

Note the width: access kind is **16** bits. Reading 32 folds in the
ARGLIST TypeId at `+6`, which for an indexed property makes the value
match neither 4 nor 6.

The exact payload layout for the others is not extracted yet -- only the
first 4 bytes (underlying TypeId) are read.

### Directory chain (lfoNextDir)

CodeView v4 allows the directory header to chain to a successor
block via `lfoNextDir` at header offset +8. `ReadDirectory` walks
the chain (capped at 16 blocks for safety) and accumulates all
entries into a single flat list. Athens 36 has been observed
emitting a single block even for SampleApp (21718 entries); the chain
walk is in place for forward-compatibility.

### Symbol stream kinds (ALIGN_SYMBOLS / GLOBAL_SYMBOLS)

The walker decodes:

| Code    | Name           | Used for                                       |
|--------:|----------------|------------------------------------------------|
| `$0002` | S_REGISTER     | register-allocated local                       |
| `$0006` | S_END          | pop scope stack                                |
| `$0200` | S_BPREL32      | locals + params                                |
| `$0202` | S_GDATA32      | global data                                    |
| `$0203` | S_PUB32        | public symbols                                 |
| `$0204` | S_LPROC32      | local procedure                                |
| `$0205` | S_GPROC32      | global procedure                               |
| `$0207` | S_BLOCK32      | push scope stack                               |

And recognises (advances past, no semantic):

| Code    | Name              | Notes                                       |
|--------:|-------------------|---------------------------------------------|
| `$0001` | S_COMPILE         | compile flags                               |
| `$0004` | S_UDT             | user-defined type alias                     |
| `$0005` | S_SSEARCH         | search marker                               |
| `$0020`, `$0024..$0027`, `$0230` | Borland extensions      |
| `$0201` | S_LDATA32         | local data symbol                           |
| `$0206` | S_THUNK32         | thunk                                       |

#### Telling a routine's PARAMETERS from its body locals — confirmed

S_BPREL32 does not say which it is, and the offset cannot be made to say it
either. Measured on `TWidget.Sum5(A, B, C, D, E: Integer)` with
`DevTools\LocalsLookupProbe`:

| | Self | A | B | C | D | E | Result |
|---|---:|---:|---:|---:|---:|---:|---:|
| x64 | +16 | +24 | +32 | +40 | +48 | +56 | −4 |
| x86 | −4 | −8 | −12 | +16 | +12 | +8 | −16 |

On x64 every parameter is positive and the result negative, which is what makes
a sign test look correct. On x86 the register-passed parameters (`Self`, `A`,
`B` in EAX/EDX/ECX) are spilled to NEGATIVE offsets sitting among the body
locals, and only the stack-passed tail stays positive.

Two things ARE reliable on both, and together they answer it:

- the declared parameter **count**, from the routine's own signature record —
  `LF_PROCEDURE` `parmCount` at payload+6, or `LF_MFUNCTION` `parmCount` at
  payload+14 with an implicit `Self` whenever `thisType` (payload+8) is nonzero;
- the **order** of the symbol stream, which emits a routine's symbols in
  declaration order: `Self`, the declared parameters, then the body locals and
  the function `Result`.

`TTD32FileReader.MarkParametersByDeclaredCount` marks the first
`parmCount + Ord(HasSelf)` symbols and nothing else. When the signature claims
more parameters than the routine has symbols it marks none: a routine shaped
unlike this understanding is better left unclassified than labelled
confidently and wrongly.

A routine's DECLARED parameter list is a separate question with a separate
answer, and it survives where the symbols do not: `LF_PROCEDURE` holds its
argList id at payload+8, `LF_MFUNCTION` at payload+16 (with `Self` implied by a
nonzero `thisType` at payload+8), and both point at the same Borland ARGLIST —
`count` (u16) followed by that many type ids.
`TryGetProcSignatureByRva` decodes it. Types only: an ARGLIST carries no
parameter names at all.

Measured while looking for a fixture, and worth recording because it is the
obvious thing to try: **`{$LOCALSYMBOLS OFF}` does not remove the BPREL32
records** when the build passes `-V`. A unit compiled with that directive still
reported its parameters and locals through the reader, so "type records without
local symbols" cannot be produced on demand from source.

RSM, for contrast, tags only `var`/`out` parameters ($22/$23 records) and calls
every by-value parameter a local, which is why the merge in `DebugInfoSet` takes
a "parameter" claim from any provider but never lets a "local" claim overwrite
one.

#### S_GPROC32 / S_LPROC32 record layout (Borland)

The fields the walker reads (offsets are from the record payload start, i.e.
after the `len`+`kind` u16 pair):

| Offset | Size | Meaning                                                    |
|-------:|-----:|------------------------------------------------------------|
| `+12`  | u32  | proc length (code size)                                    |
| `+24`  | u32  | offset (segment-relative code offset)                      |
| `+28`  | u16  | segment                                                    |
| `+32`  | u32  | **proctype** — the `LF_PROCEDURE` ($0008) type id          |
| `+36`  | u32  | name index (into `SST_NAMES`)                              |

The layout is Borland's, NOT Microsoft's S_GPROC32 (which puts `typind` at
`+24`). The `proctype` offset was pinned empirically: a u32 read at `+30`
comes out two bytes low (two pad bytes follow the u16 segment), while `+32`
resolves to a valid `LF_PROCEDURE` record. `LF_PROCEDURE` carries `parmCount`
as the u16 at payload `+6`, so a free function's declared arity is
`proctype -> LF_PROCEDURE.parmCount`. `TryGetFreeFunctionParamCount` uses this
to refuse auto-calling a bare `Foo` that actually takes arguments.

### Primitive TypeIds (TypeId < $1000)

The compiler-predefined primitives don't live in the TYPES table.
The mapping observed across TestTarget + SampleApp globals:

| TypeId    | Type      |
|----------:|-----------|
| `$0004`   | Currency  |
| `$0020`   | Byte      |
| `$0030`   | Boolean   |
| `$0040`   | Single    |
| `$0041`   | Double    |
| `$0042`   | Extended (32-bit only; a true 10-byte x87 type) |
| `$0044`   | Real48    |
| `$0061`   | AnsiChar  |
| `$0071`   | Char      |
| `$0072`   | SmallInt  |
| `$0073`   | Word      |
| `$0074`   | Integer   |
| `$0075`   | Cardinal  |
| `$0076`   | Int64     |
| `$0077`   | UInt64    |

`GetTypeName` decodes these before the record-table lookup.

#### Named float aliases are FLATTENED at the variable — measured, not inferred

`DevTools\Td32AliasProbe` (`-proc <name>` dumps a routine's locals with the raw
TypeId; `<exe>` alone looks the alias names up in the TYPES table). Against
`TestTarget`'s `ComputeNested`, which declares `D1: TDateTime`, `Ext1: Extended`
and `R48: Real48`:

| declared | Win64 TypeId | Win32 TypeId |
|---|---|---|
| `TDateTime` | `$0041` → `Double` | `$0041` → `Double` |
| `Extended`  | `$0041` → `Double` (correct: a true alias there) | `$0042` → `Extended` |
| `Real48`    | `$0044` | `$0044` |

And `TDateTime` / `TDate` / `TTime` / `Real` / `Extended` / `Double` / `Currency`
/ `Single` are **all absent from the TYPES table** — they are primitives, so no
name record exists for any of them.

So the compiler resolves the alias when it WRITES the variable record: the id is
the underlying primitive and nothing points back at the declared name. This is
not a missing type dictionary — the *link* from variable to declared type is
gone, so no external name source can rebuild it. Only a provider that stores
per-variable type identity can: `.rsm` does (`hint=TDateTime`), and so does the
RSM-format `.dcp` (verified on a real Win32 package: `QBFD29.dcp` reports
`hint=TDateTime` / `Currency` / `Double` / `Extended` as distinct hints), which
is why a BPL needs no DCU reader for this. `Real48` is different and IS
recoverable: it is a distinct primitive id, not a `Double` alias.

Corollary for BPLs: the `.rsm` emitted beside a package can be nearly empty
(`QBFDesignD29.rsm` is 51 KB for a 10.9 MB BPL and exposes **no locals at all**);
the `.dcp` is the real RSM-format provider there.

### Itanium demangler (Borland-augmented)

Beyond the basic `_ZN ... E` shape, the demangler now handles:

- Source names (length-prefixed identifiers)
- Constructor / destructor markers (`C0..C3` -> `Create`,
  `D0..D2` -> `Destroy`)
- Templates: an `I ... E` block after a length-prefixed name
  becomes `Name<arg1, arg2, ...>`. Argument types are decoded via
  the standard Itanium `<type>` production (substitutions,
  built-in single-letter codes, nested-name blocks, pointer /
  reference qualifiers).
- Substitution back-references `S_`, `S0_`, `S1_`, ... reference
  previously seen components.
- Operator names (`pl` -> `operator+`, `mi` -> `operator-`,
  `ml` -> `operator*`, `dv` -> `operator/`, `eq` -> `operator=`,
  `ne` -> `operator<>`, ...).
- Borland's `_ZTR` / `_ZTI` / `_ZTS` / `_ZTV` / `_ZTT` prefixes are
  stripped before parsing the embedded name (typeref / typeinfo /
  type-name string / vtable / VTT respectively).

#### Unanchored names: an IDE-built package drops the unit component

A package built by the IDE stores method names with **no leading `@`**, i.e. with
no unit component at all:

```
TFrmColumns@Create                     class + method, no unit
```

The leading `@` is what marks the first component as the unit, so the two shapes
cannot share one rule: anchored `@Unit@Proc` drops its first component, while
unanchored `TClass@Method` must keep both. `DemangleBorland` handles both;
a name with no `@` anywhere is still rejected as unmangled, which is what keeps
plain symbols untouched.

Measured on `QBFDesignD29.bpl` (`Td32AliasProbe -rvaname 24688 <bpl>`), where the
anchored-only rule let the raw name through and a call-stack frame read
`TFrmColumns@Create`. `@` is not legal in a Pascal identifier, so its presence is
always a mangling separator.

### Borland demangler (what `dcc32` emits) — confirmed

`dcc64` mangles Itanium-style; `dcc32` mangles **Borland-style**, and the two
never mix inside one image. `TTD32FileReader.DemangleBorland` handles the two
shapes observed in `dcc32` output:

```
@Testtargetedge@EdgeFactorial$qqri      unit + routine
@Forms@TApplication@Run$qqrv            unit + class + method
```

The `$` introduces the parameter encoding (`$qqr…`) and carries no name, so the
name ends there. It is tried **only after** the Itanium demangler declines, so
nothing about the x64 path changes.

Presentation deliberately mirrors the Itanium demangler rather than inventing
its own, because a 32-bit call stack must read identically to a 64-bit one — a
difference between them then means something:

- the unit prefix is dropped for a plain routine (`EdgeFactorial`);
- a method keeps its `Class.Method` form (`TApplication.Run`);
- a unit's `initialization` / `finalization` section is presented as the
  **owning unit's** name, the same special case the Itanium branch already
  makes. Without it the program main block reads `initialization` on x86 where
  x64 shows the unit name.

Confirmed by comparing the same recursive stack on both bitnesses name for name
(`Win32_StackFrameNames_MatchWin64`, which caught the missing
`initialization` case on its first run).

### Nested procedures: `pParent` is the only record dcc32 emits — confirmed

A proc record (`$0204` LPROC32 / `$0205` GPROC32) carries CodeView's `pParent`
back-pointer at **payload+0**, and it is a byte offset from the **subsection
base** — not from the first record, which starts at +4 (sstAlignSym) or +32.
Measured with `DevTools\Td32ProcNesting.exe` on a 32-bit build: 196 of 196
resolve against the subsection base and 0 of 196 against the first record.

This is load-bearing on Win32 and nowhere else, because dcc32 records nesting
in no other way:

| Source | dcc64 | dcc32 |
|---|---|---|
| symbol-stream lexical nesting (scope stack) | present | **none** — every proc at top level |
| MAP | `$pdata$_ZZ...` mangled, parent recoverable | flat `Unit.Inner` |
| TD32 `pParent` | present | **present** |

The `_ZZ` correlation in `MapFileReader` is an Itanium (dcc64) spelling, so
before `pParent` was read, nothing on a 32-bit target knew that `Inner` is
nested inside `ComputeNested`. The visible effect was that a nested procedure's
locals showed only its OWN variables, while the identical source built for
Win64 also showed the enclosing routine's — measured at `INNER_BODY`:

    x64:  S, ComputeNested.X, ComputeNested.D1, ComputeNested.Ext1, ...
    x86:  S

Resolution happens after the whole subsection is walked, because a parent may
appear AFTER its child in the stream. The parent's NAME is then taken from the
ordinary name lookup rather than from the proc record's own spelling: using the
record's spelling made the locals prefix read `computenested.Ext1` where every
other path says `ComputeNested.Ext1`, on x64 too, since this provider answers
first.

#### Constructors and destructors carry NO declared name — confirmed

A third shape exists that the demangler **cannot** decode, because the name is
genuinely absent from the symbol:

```
@Testtargetedge@TCtorProbe@$bctr$qqrv    constructor
@Testtargetedge@TCtorProbe@$bdtr$qqrv    destructor
```

The component where a method name would sit is EMPTY; all that is recorded is
the `$bctr` / `$bdtr` marker. `Create` is not in there, and mapping the marker
onto `Create` / `Destroy` would be a guess — a constructor may be declared with
any name (`CreateFromFile`), and the guess would then print a name the source
does not contain.

So `DemangleBorland` declines, and the DECLARED name is taken from another
provider instead: `TDebugInfoSet.RvaToFunctionName` treats a result that is
still mangled (leading `@` plus a `$`) as "not an answer" and keeps asking, so
the MAP — which stores `TestTargetEdge.TCtorProbe.Create` in plain text —
supplies it. A mangled name is kept only if no provider offers a decoded one,
since it still beats no name at all. An Itanium-demangled name never has that
shape, so x64 is unaffected.

Before this, a 32-bit call stack stopped in a constructor read
`@Testtargetedge@TCtorProbe@$bctr$qqrv` where the 64-bit one read
`TCtorProbe.Create`. Asserted by
`StoppedInCtorPreamble_StackStillReachesTheCallerOnBothBitnesses`.

STILL OPEN: with TD32 but no MAP, the mangled form is all there is. The
declared name is recoverable — a class's TD32 member list records methods by
their source names — but reaching it from a procedure record has not been
implemented.

Three call sites, because Borland mangling is not confined to procedure names:

| Site | What it demangles |
|---|---|
| the procedure-record decode | routine / method names in the symbol stream |
| `GetTypeName` | **type** names — a 32-bit target otherwise shows `@Testtargetcore@TWidget` |
| `DecodeFriendlyTypeName` | class **member** names (the innermost component is the answer; the owning class is already known from the record that contains it) |

The type-name index registers **both** spellings, mangled and demangled.
Callers hold the source name — from a runtime VMT, from the `.rsm`, or from a
user's watch expression — while the stored one is mangled, so registering only
the clean form would break every lookup.

## Runtime VMT slot offsets per target bitness — confirmed

The adapter reads a live VMT to recover a class identity, so it needs the slot
offsets of the **target**, not of itself. They are measured, not taken from
`System.pas`, whose formula does not describe what the Athens compiler emits
(see also the Win64 note in `PROJECT_STATE.md`). `DevTools\VmtProbe.dpr`
searches the −256..0 window in front of a live VMT for offsets satisfying an
identity predicate the compiler can verify (the class reference **is** the VMT
address; `ClassName` against a compile-time literal; `InstanceSize` against the
declared field layout; `TypeInfo` against the `TypeInfo()` intrinsic), and is
compiled with both `dcc32` and `dcc64` so the `dcc64` column has to reproduce
the values already in the shipping code before the `dcc32` column is trusted.
No 32-bit constant is a scaled 64-bit one.

| Slot | Win32 | Win64 |
|---|---:|---:|
| SelfPtr | −88 | −176 |
| TypeInfo | −72 | −168 |
| FieldTable | −68 | −160 |
| ClassName | −56 | −112 |
| InstanceSize | TypeInfo + 20 | TypeInfo + 40 |
| CPP_ABI shift | 0 | 24 |

Two consequences that are easy to get wrong:

- **A VMT slot is one TARGET pointer wide.** Reading a fixed 8 bytes on a
  32-bit target splices the adjacent slot into the high half and yields a
  plausible address pointing nowhere — a credible wrong value rather than an
  error. The same applies to the VMT pointer read from the object itself, which
  is its first field.
- **The CPP_ABI shift is 0 on Win32.** On Win64 two layouts coexist in one
  image (RTL units built with `CPP_ABI_SUPPORT` shift every negative slot by
  24), so the reader probes two self-pointer positions to decide which layout a
  VMT follows. `CPP_ABI_SUPPORT` is defined for WIN64/EXTERNALLINKER only, so on
  Win32 that detection collapses to a no-op instead of a second read that could
  never match.

The numbers live in `DebuggerCore\TargetLayout.pas` (`TTargetLayout.For32Bit` /
`For64Bit`), which is the source of truth; the table above records what was
measured and how.

## Pointer-to-class display convention

A Delphi `var Foo: TFoo` is internally a pointer to the class instance
record. The compiler emits an unnamed `LF_POINTER` whose target is the
`LF_CLASS` record. `GetTypeName` strips the synthetic `^` prefix when
the pointer target is a class, so the user-facing TypeHint matches
Delphi source (`TFoo`, not `^TFoo`). Pointers to records / primitives
keep the `^` per Pascal pointer-type syntax (`^Integer`, `^TPoint3D`).

## Runtime identity ⇄ TD32 type-id: name (+ size) only

There is **no** deterministic bridge from a runtime class identity (the VMT /
its `TypeInfo`) to a TD32 type-id. Established by inspection + enumeration of
`TestTarget.exe`:

- A TD32 type record (`LF_CLASS`) stores fieldlist + name + size + vshape — all
  type indices, **no runtime address**. A type table carries no VMT/`TypeInfo`
  RVA by design.
- Of the 477 globals, the 35 class-typed ones are all *variables that hold an
  instance* (`TEncoding.FUnicodeEncoding`, `TFieldsCache.FGlobal`, …); their RVA
  is the data slot, not a VMT. **No per-class VMT/`TypeInfo` symbol carries a
  type-id.**
- At runtime the VMT/`TypeInfo` yields the class **name** (a string) and the
  **instance size** (`vmtInstanceSize`), never a TD32 type-id — those indices
  are internal to the debug blob.

Consequence: the only linkage is **name, disambiguated by instance size** (what
`GetClassMembers(..., PreferInstanceSize)` does). Two classes sharing **both**
name and size are indistinguishable — a hard TD32-format limit, not an
implementation gap.

`inherited` (resolving the ancestor of the *declaring* class) cannot use this
size disambiguation at all: the object's size is the **leaf** class's, not the
declaring ancestor's. Cross-module `inherited` with duplicate class names is
therefore resolved by bare name (first-wins) and shares this limit. Pinning it
would require decoding the per-procedure type reference of the `Self` local into
a global class id — not currently done.

## Verification

The reader is exercised by `DebuggerTests\TD32ReaderTests.pas`. The
type-table tests assert:

- `TStuff` / `TWidget` / `TBareClass` / `TObject` / `Exception` resolve
  to `tkClass` records with non-zero instance size and a fieldlist
  reference.
- `LookupTypeKind` returns the System.TypInfo.TTypeKind ordinal for
  classes (`7`) and `0` for unknown names.
- A pointer-to-record global keeps its `^` prefix.
- A property member carries its RETURN type's kind/size, resolved by the
  exact type id (record → 14 + size, set → 6, class → 7); a primitive field
  keeps kind `0` but still resolves a byte size.
- `TryGetFreeFunctionParamCount` returns the declared arity from the
  `LF_PROCEDURE` signature (`FreeAdd` → 2, `FreeWrap` → 1) and misses cleanly
  on an unknown name.

Against `SampleAppSingleExe.exe`, manual probing confirmed:

- `Globals` (`GlobalsU.Globals : TGlobals;`) has `TypeId = 1195167`
  (= `$123A1F`), resolves to `^TGlobals` -> displayed as `TGlobals`
  through the class-ref unwrapping rule.
- `TGlobals` itself is record index 1191072 with size 16, fieldlist
  `$123CA1`.
- `TfrmMainMdi` is 2688 bytes (matches the form layout).
- `TStrings` is at index 47002.

These numbers move with every recompile of SampleApp, but the encoding
formula does not.

## Recovered from the task journal (2026-08-08)

### dcc32 Borland mangling: the type name continues AFTER the `$` marker

A type declared inside a routine is mangled `@Unit@Proc$qqrv@TColor` — the TYPE
NAME follows the `$` signature marker, so truncating at `$` renames the type to
the routine. Enums and sets then lose their identity: `Big` printed 10 instead of
`beK`, and an EMPTY set printed `Red`. Signature-internal `@` (a class-typed
argument is `$qqrx20System@UnicodeString`) is skipped by consuming length-prefixed
runs.

### Method-signature decode chain (`TryGetMethodParams`)

class FIELDLIST -> `LF_METHOD` / `LF_ONEMETHOD` by name -> `LF_METHODLIST`, whose
entry is `attr(2) + mfunction(4)` -> `LF_MFUNCTION` (`parmCount@14`,
`argList@16`, `thisType@8`) -> `LF_ARGLIST` in Borland form: `count(u16)` then
`count * type(u32)`. The class-name lookup retries with `$` replaced by `_`. A CV
ARGLIST carries no parameter names, which is why anonymous-method parameters
surface positionally.

### Locals storage: append-only store plus linked index chains

`AppendLocalToScope` was quadratic (an array realloc and copy per local, into two
dictionaries). It is now one append-only `FLocalsStore` plus two `-1`-terminated
linked index chains (`FLocalNextByName` / `FLocalNextByRva`) with heads and tails
in `FProcLocalChains` / `FRvaLocalChains`: amortised O(1), each local stored once,
chain order equal to the old parse order. **The gain is only -13..-16 %**
(cxLibraryRS29 585 -> 494 ms) — the rest is byte-walking, not container churn.

### Measured before widening `ArrayElemByteSize` for `$42` (Extended), 8 -> 10

The blast radius was MEASURED rather than assumed: `TypeSizeById`'s only
size-sensitive consumers are the SET and RECORD return paths in `ApplyMethodCall`
(`ExprEval.pas:1477`, `:1501`), and a float reaches neither. That is what made the
change safe after it had been deferred in an earlier round for fear of widening a
read into an 8-byte slot. The same fear will recur for every other primitive whose
recorded size is wrong; this is how to answer it.

### Rejected on measurement: a TD32 sidecar

A TD32 sidecar mirroring the RSM `.idx`, for the PE `.debug` section, was
investigated and rejected: only 2.1-2.4x faster than a full TD32 parse, and the
sidecar is 2.6-3.8x LARGER than the section it replaces (105 MB for a 44 MB
package). Do not revisit without a new argument.

### Rejected: moving `LoadFromFile` off the main thread

`TD32FileReader.LoadFromFile` is fully SYNCHRONOUS with no `WaitForIndex` gating,
unlike the RSM and MAP readers. Moving it to a background thread would require
adding `WaitForIndex` to ~20 consumers — missing one yields incomplete-data
corruption — and the first `stackTrace` needs TD32 immediately, so the stall
relocates rather than disappears. Deliberately descoped.
