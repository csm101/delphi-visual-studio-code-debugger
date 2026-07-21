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

## Container layout

1. PE section `.debug` (raw offset taken from the section header).
2. Inside the section: the bytes `46 42 30 39` (`'FB09'` little-endian =
   `$39304246` -- `TD32_SIGNATURE`) mark the start of the TD32 block.
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
`TTD32FileReader.ResolveNameByIndex` walks this once and indexes the
results.

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
| `$0061`   | AnsiChar  |
| `$0071`   | Char      |
| `$0072`   | SmallInt  |
| `$0073`   | Word      |
| `$0074`   | Integer   |
| `$0075`   | Cardinal  |
| `$0076`   | Int64     |
| `$0077`   | UInt64    |

`GetTypeName` decodes these before the record-table lookup.

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

## Pointer-to-class display convention

A Delphi `var Foo: TFoo` is internally a pointer to the class instance
record. The compiler emits an unnamed `LF_POINTER` whose target is the
`LF_CLASS` record. `GetTypeName` strips the synthetic `^` prefix when
the pointer target is a class, so the user-facing TypeHint matches
Delphi source (`TFoo`, not `^TFoo`). Pointers to records / primitives
keep the `^` per Pascal pointer-type syntax (`^Integer`, `^TPoint3D`).

## Verification

The reader is exercised by `DebuggerTests\TD32ReaderTests.pas`. The
type-table tests assert:

- `TStuff` / `TWidget` / `TBareClass` / `TObject` / `Exception` resolve
  to `tkClass` records with non-zero instance size and a fieldlist
  reference.
- `LookupTypeKind` returns the System.TypInfo.TTypeKind ordinal for
  classes (`7`) and `0` for unknown names.
- A pointer-to-record global keeps its `^` prefix.

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
