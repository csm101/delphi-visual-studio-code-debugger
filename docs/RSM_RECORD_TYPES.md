# RSM Record Types

Catalog of tag bytes and record kinds recognised in Delphi Win64 `.rsm`
files. Each entry lists the tag, the record's purpose, and a confidence
status:

- **confirmed** — produced consistently by the compiler and parsed in
  production code paths today.
- **inferred** — observed but not fully exercised; parser reads it but
  may treat parts as opaque.
- **conjectured** — suspected to exist based on gaps in the encoding
  space, not yet seen in the wild.

Source of truth is `DebuggerCore/RsmFileReader.pas`. Field-level layouts
live in `RSM_FIELD_OFFSETS.md`. Open questions live in `KNOWN_UNKNOWNS.md`.

## Top-level tag byte map

| Tag    | Where           | Meaning                                       | Status     |
|--------|-----------------|-----------------------------------------------|------------|
| `0x20` | imports + body  | Local variable record (also marks a global when preceded by `0x63`) | confirmed |
| `0x22` | body            | `var` / reference parameter                   | confirmed  |
| `0x25` | body            | Named constant record (Delphi `const`); ordinal value + per-unit owner decoded | confirmed |
| `0x28` | body, after 0x63 or shared | Procedure / function record         | confirmed  |
| `0x46` | body            | Marker variant of `0x66` for main-block locals | confirmed |
| `0x63` | body            | Symbol category prefix (procedures, globals, EH records) | confirmed |
| `0x9E` | body (after 0x63) | EH / unwind symbol record (`$unwind$_`, `$pdata$_`) | inferred |
| `0x65` | imports         | Unit reference                                | confirmed  |
| `0x66` | imports + body  | Type reference / type-marker inside locals    | confirmed  |
| `0x67` | imports         | Function import                               | inferred   |
| `0xC6` | body            | Variant type tag inside global records (Delphi runtime globals) | inferred |
| `0x2A` | imports         | Type-declaration record (typeId ↔ name)       | confirmed  |
| `0x2C` | body (class members) | Class field record                       | confirmed  |
| `0x2E` | body (class members) | Class method record                      | confirmed  |
| `0x2F` | body (class members) | Class constructor record (variant of `0x2E`) | inferred |
| `0x31` | body (class members) | Class property record                    | confirmed  |
| `0x21` | -               | Suspected const-parameter tag                 | conjectured|
| `0x23` | body            | Out parameter (used for `Result` of var-out functions) | confirmed |

`IsVarKindTag` accepts `0x20` and `0x22` only. Other parameter-kind tags,
if they exist, will be silently skipped.

## Record catalog

### Header — magic + ExePath  (status: confirmed)

```
+0   "CSH7"                          (4 bytes ASCII)
+4   <unstudied: 28 bytes>
+0x20 ExePath relative path, NUL-terminated ANSI
```

### Unit reference  (`0x65`, status: confirmed)

```
65 [LEN] [NAME ANSI: LEN bytes] [3 bytes payload]
```

Parser anchors on the literal `65 06 'System' 00 00 00` to find the start
of the imports area. Other unit references after that point are simply
skipped over with the same shape.

### Type reference  (`0x66`, status: confirmed in imports / type-marker in body)

In the imports area:

```
66 [LEN] [NAME ANSI] [4 bytes hash]
```

The ordered list of `0x66` records yields the per-file user type table.
Index is 1-based; locals/globals encode `typeId = 2 * position`.

In a local-var record the same byte begins the type-marker section:

```
... 66 00 00 [TYPEID] [OFFSET]                       (classic local layout)
... 66 00 01 [?] [TYPEID] [OFFSET]                   (inline-var layout)
```

### Function import  (`0x67`, status: inferred)

```
67 [LEN] [NAME ANSI] [4 bytes hash]
```

Same shape as the type reference but uses tag `0x67`. The parser walks
past these in the imports area without storing them. Whether the trailing
4 bytes are a hash, a fixup, or a typeId is not yet established.

### Procedure / function  (`0x28`, status: confirmed)

```
[63] 28 [LEN] [NAME ANSI] [12 or 13 bytes metadata] {local-var records}
```

The leading `0x63` is the category prefix; it may be omitted when the
previous subrecord shares it (the parser handles both forms by tracking
`HeaderLen ∈ {2,3}`). Procedure metadata length is variable and not
fully decoded — the parser scans up to 32 bytes for the first plausible
local-var record start.

### Global variable  (`63 20`, status: confirmed for `0x66` payload, inferred for `0xC6`)

```
63 20 [LEN] [NAME ANSI] {66 | C6} ...
```

Two payload variants:

- `66 00 00 [TYPEID] [3 bytes opaque RVA encoding]`
  — standard user globals; `TYPEID` resolves through the user type table.
  RVA is not derived from these bytes; it comes from the `.map` PUBLICS
  section.
- `C6 ...` — Delphi runtime globals (e.g. `ModuleIsLib`). Parser captures
  the name but stores `TypeId = 0` and an empty `TypeHint`. The remaining
  payload is opaque.

### Local variable, classic  (`0x20`, status: confirmed)

```
20 [LEN] [NAME ANSI] 66 00 00 [TYPEID] [OFFSET]
```

Total record size: `2 + LEN + 5` bytes. `OFFSET` is a signed byte that
yields the local's address via `(OFFSET div 2) + FrameSize`, added to RBP.

### Local variable, inline  (`0x20`, status: confirmed)

```
20 [LEN] [NAME ANSI] 66 00 01 [?] [TYPEID] [OFFSET]
```

Total record size: `2 + LEN + 6` bytes. Emitted by Delphi 10.3+ for inline
variables declared inside the statement block. Byte `[?]` between the
flag and the type id is observed but its meaning is not pinned down — the
parser ignores it.

### Var / reference parameter  (`0x22`, status: confirmed)

Same payload layouts as the classic and inline local records but with the
leading tag set to `0x22`. The stack slot holds a pointer to the caller's
storage; reads must follow the pointer to recover the actual value.
`setVariable` writes through this pointer; if it overwrote the slot the
caller would not see the change.

### Main-block local  (`0x20` ... `0x46`, status: confirmed)

```
20 [LEN] [NAME ANSI] 46 00 01 [?] [TYPEID] [OFFSET]
```

Identical to the inline-format local-var record except that the
type-marker byte is `$46` rather than `$66`. The parser additionally
filters on `FormatFlag = 1` because some RTL global records also contain
the byte `0x46` in non-marker positions; restricting to inline-format
avoids those false positives.

These records live in a separate file region from the program's main
procedure record. They are picked up in the `CollectMainBlockLocals`
second sweep and attached to the procedure named after the ExePath
basename.

### Named constant  (`0x25`, status: header confirmed; ordinal value decoded)

Emitted for every Delphi `const` declaration (unit-level and in-procedure),
including the System unit's predefined consts.

```
25 [LEN] [NAME ANSI] 8A 00 00 [4-byte NameHash] [TypeId u1] 00 00 [value leaf]
```

The `8A 00 00` marker is constant across all records and is used to validate
the record. `TypeId` is `0x02` for Boolean, `0x0C` for Integer, etc. The value
leaf for an ordinal is `value shl 1` in one byte when it fits (low bit 0), or
an escape `0x0F` followed by a little-endian Int32. String/float/wide leaves are
not decoded yet. Full byte layout and confirmed sample values:
`RSM_FIELD_OFFSETS.md` -> "Named constant (tag 0x25)".

Parsed by `TRsmFile.EnsureUnitConstsParsed` (ordinal leaves) and attributed to
the owning unit via the surrounding `63 35` cluster owner, for per-unit-scoped
constant resolution in watches (`IUnitScopedConstProvider`).

NB: `0x25` is also used as a SUB-tag inside `63 25` / cluster contexts (enum
reference); the standalone `25 [LEN] [name] 8A 00 00 ...` named-constant record
is distinct and identified by the `8A 00 00` marker.

### EH / unwind symbol  (`63 9E`, status: inferred)

Emitted by the compiler for C++ EH metadata symbols:
`$unwind$_<mangled>` and `$pdata$_<mangled>` entries.

```
63 9E [bytes opaque] [mangled name ANSI]
```

These appear in the inter-procedure gaps of the symbol area, after the
local-variable run of each procedure. The exact sub-structure after the
`63 9E` prefix is not decoded; the parser walks past them as unrecognised
bytes.

The `9E FE` two-byte sequence also appears as a prefix before the extended
local-variable run in `Increment` (which has a `var` parameter). Whether
`9E` is a standalone record-type marker in both contexts or a different
overloaded byte is not resolved.

### Relocation / fixup table entries  (`10 0F lo hi`, status: inferred)

4-byte entries scattered through the RSM, covering all modules. Each entry
encodes an RVA at a 128-byte interval:

```
10 0F [lo u1] [hi u1]
RVA = (hi * 256 + lo) * 32 + 16
```

These decode to the embedded stripped proc-code RVAs at 128-byte boundaries
and are consistent with a relocation/fixup table for the stripped code
copies. They are not a structured contiguous block; the first byte `0x10`
acts as the entry tag.

### Module record  (end-of-file, status: inferred)

One module record exists near the end of the RSM (observed at approximately
RSM[0x40C7B2] for a single-unit exe). Format:

```
31 02 ED ED [flags: 1-2 bytes] [PathLen: u1] [Path: ANSI PathLen bytes]
[StartRVA: u4 LE] [CodeLen: u4 LE] [further fields: opaque]
```

`Path` is the source directory without a NUL terminator (length-prefixed by
`PathLen`). `StartRVA` and `CodeLen` describe the module's code extent in
the image. The fields that follow are not yet decoded.

### Source line number table — absent on Win64

**The Win64 RSM does NOT contain a source line-number-to-RVA table.**

This was established by exhaustive search across the entire RSM (4.2 MB for
the Debugme test target) testing every plausible encoding:
`(line u16, rva u32)`, `(line u16, rva u16)`, `(line u32, rva u32)`, delta
encodings, and several address-compression variants. No format matched the
ground-truth line→RVA pairs from the MAP file.

The `.map` file is the sole source for line-number mapping on Win64 Delphi.
This will not change: the RSM simply was not designed to carry line info on
this platform.

### Type declaration  (`0x2A`, status: confirmed)

```
2A [LEN] [NAME ANSI: LEN bytes] [flags(1)] [00] [00] [TypeIdLo] [TypeIdHi] <variant trailer>
```

Three trailer variants observed:

- **Variant A (simple types)** — `1E` at +N+7 followed by 1 extra byte;
  total record size `2 + N + 10`.
- **Variant B (generic instantiations)** — `00` at +N+5; total record size
  `2 + N + 6` (compact, no trailer beyond TypeId).
- **Variant C (classes, e.g. TStuff `{$M-}`, TWidget `{$M+}`)** — `1F`
  at +N+7; total record size `2 + N + 8`.

The 16-bit TypeId at +N+3..+N+4 is the canonical key into the
per-module type table. For classes it is also the value that appears
in the trailing `08 <classHash> FF` block of every `$2C/$2E/$2F/$31`
member record, allowing members to be grouped back to their class.

> **Collision on large targets (confirmed).** The class-member grouping
> key is only **16 bits** (`TypeId and $FFFF`). On modules with more than
> 65536 types (e.g. SampleApp's single-EXE, > 64k types) two unrelated classes
> can share those low 16 bits, so a member-by-class lookup keyed on it alone
> pulls in foreign members — observed as `TApplication` reporting 452 members
> with `TObjectList.FOwnsObjects` and `PICTDESC.cbSizeofstruct` mixed in, which
> made inspecting `Application` render garbage. Member records are emitted
> inside their class's own unit section, so the owning unit
> (`FindOwningUnit` over `FUnitAnchors`) disambiguates the collision:
> `DecodeClassMembers` keeps only candidates whose owning unit matches the
> class's unit (see `MemberMatchesClassUnit` in `RsmDecoders.pas`). Members
> with an unknown unit on either side are kept (conservative).

Names with a leading `{Unit}` prefix (e.g. `{System}TArray<System.Integer>`)
are stored unprefixed in the type table.

### Class field  (`0x2C`, status: confirmed)

```
2C [NameLen] [Name ANSI] [flags(1)] [vis(1)] [reserved(1)]
   [typeId VLE(1-3)] [offset VLE(1-2)]
   9C [tag(1)] [hash16 LE] <opaque tail> 08 [classHash 1 or 2 bytes] FF
```

- `vis`: `$00 = private`, `$02 = public`, `$0A = published`.
- `typeId`: LSB-VLE (1/2/3 bytes), low bits of byte0 select the width — same
  encoding `ClassMember_ReadTypeIdVLE` uses. Resolves through the user /
  module type table the same way local-var typeIds do.
- `offset`: byte offset within the instance, encoded as the SAME LSB-VLE as
  local-var RBP offsets — **not** a plain `byte × 2`:
    - byte0 LSB = 0 → 1 byte, `offset = byte0 shr 1` (offsets ≤ 127).
      Worked: `FCount byte = $10 → 8`, `FLabel byte = $20 → 16`.
    - byte0 LSB = 1 → 2 bytes, `offset = (byte0 | byte1 shl 8) shr 2`.
      Worked: `TWideFields.FTailA bytes = 01 04 → $0401 shr 2 = 256`,
              `FTailB bytes = 11 04 → $0411 shr 2 = 260`.
  The hash-marker scan must start after the offset's ACTUAL byte count
  (1 or 2), not a fixed +1. Decoding the offset as a single `byte div 2`
  truncated every field past offset 127 to garbage (it cannot represent the
  2-byte form). Decoder: `ClassMember_ReadOffsetVLE`.
- `hash16`: per-record 16-bit hash (LE). Property records reference this
  value to bind the property to its backing field. The hash is preceded by
  the marker `9C` and a one-byte `tag`. **The tag is not fixed** — `$09` and
  `$01` are common on small targets, but real VCL fields use other values
  (e.g. `TApplication.FHintColor` is `9C 17 B9 8D`, hash `$8DB9`). The decoder
  must take the first `9C` after the offset byte regardless of the tag, then
  read `hash16` from the two bytes following the tag. Gating on a fixed tag
  set silently dropped such fields, breaking property→field binding.
- `classHash`: 1- or 2-byte raw class identifier; same value as the
  `TypeId` of the corresponding `$2A` record.

### Class method  (`0x2E`, status: confirmed)

```
2E [NameLen] [Name ANSI] [flags(1)] [vis(1)] [reserved(1)]
   E2 [bodyHash16 LE] 01 [8C|9C] 9C 01 [perRecHash16 LE]
   <opaque tail> 08 [classHash] FF
```

- `vis`: same encoding as field records.
- `bodyHash16`: 16-bit method-body hash (LE) immediately after the `E2`
  marker. Property records bind to a method getter by matching their
  `getterHash16` to this `bodyHash16`.
- `perRecHash16`: a separate per-record sequence index, used elsewhere.
- The byte after the `01` is `8C` when the method has arguments and
  `9C` when it is parameterless. It does NOT encode the return ABI
  class — see `KNOWN_UNKNOWNS.md` for how the evaluator infers the
  return type via the bound property's `TypeIdByte` instead.

### Class constructor  (`0x2F`, status: inferred)

Same surface layout as `0x2E`. Distinguished only by the leading tag.
Treat as a method for the purpose of member enumeration; constructors
are typically resolved through the MAP `Class.Create` symbol when
invoked from the evaluator.

### Class property  (`0x31`, status: confirmed)

```
31 [NameLen] [Name ANSI] [flags(1)] [vis(1)] [reserved(1)]
   [typeIdByte(1)] FE 0F 00 00 00
   80 [getterHash16 LE] <opaque tail> 08 [classHash] FF
```

- `flags`: bit `$40` marks the class's **`default`** array property -- the
  one `Obj[X]` resolves to -- and nothing else. The parenthetical "also
  marks indexer-style accessors" that stood here was **wrong**: a plain
  indexed property that is not declared `default` reads `$00`
  (`TMenuCache.Level`, `TStrings.Objects`, `TStrings.Names`,
  `TStrings.ValueFromIndex`), while `default` ones read `$40` regardless of
  whether their index is an Integer or a string, and regardless of having a
  setter. Measured 2026-07-21 across `TestTarget.rsm` and `Debugme.rsm`
  (60 of 1228 property records, never more than one per class), with a
  fixture carrying two otherwise-identical array properties
  (`TestTargetCore.TIndexProbe`). Bit-test it rather than comparing the
  whole byte: the remaining bits are not understood.
- `vis`: same encoding as field records.
- `typeIdByte`: low byte of the property's declared type.
- `getterHash16`: 16-bit hash (LE) immediately after the first `80`
  separator. Matches either a sibling `$2C` field's `hash16` (field-
  backed property) or a sibling `$2E`/`$2F` method's `bodyHash16`
  (method-backed property).

The first `80` after the `FE 0F 00 00 00` marker carries the get
accessor; subsequent `80` markers (when present) belong to other
accessor slots and are not currently decoded.

### Conjectured: `const` / `out` parameters  (status: conjectured)

The Win64 ABI distinguishes `const` (caller-side immutability) from
`var` (reference) and `out` (write-only reference). It seems likely that
the compiler emits a different leading tag (e.g. `0x21`, `0x23`) for
those, but no example has been confirmed. If we ever debug a routine
that exposes a `const` reference parameter and the locals scan misses
it, that's the trigger to confirm.
