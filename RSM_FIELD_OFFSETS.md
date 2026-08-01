# RSM Field Offsets

Byte-level layout of every record kind the parser handles. Offsets are
relative to the start of the record. All multi-byte fields observed so
far are little-endian. See `RSM_FORMAT_NOTES.md` for context and
`RSM_RECORD_TYPES.md` for the record catalog.

The parser this document tracks is `DebuggerCore/RsmFileReader.pas`.

Notation:

- `u1`, `u2`, `u4` — unsigned little-endian, 1/2/4 bytes.
- `i1` — signed byte (`ShortInt`).
- `ANSI(N)` — `N` bytes of ANSI text, no NUL terminator (length prefix is
  the previous field).
- `?` — known to be present but not yet interpreted.

## Header

| Offset | Size  | Field         | Notes                                       |
|--------|-------|---------------|---------------------------------------------|
| 0x00   | u4    | Magic         | ASCII "CSH7"; reject if absent              |
| 0x04   | 28    | ?             | Unstudied                                   |
| 0x20   | up to 0x400 | ExePath | NUL-terminated ANSI; basename → main proc name |

The parser caps the ExePath scan at 0x400 to avoid reading past header
data into the imports area when the file is malformed.

## Unit reference (tag 0x65)

| Offset | Size  | Field    | Notes                                            |
|--------|-------|----------|--------------------------------------------------|
| 0      | u1    | Tag      | `0x65`                                           |
| 1      | u1    | NameLen  | `LEN`                                            |
| 2      | LEN   | Name     | ANSI(LEN), validated as a Pascal identifier      |
| 2+LEN  | 3     | Payload  | `00 00 00` for `System`; meaning unconfirmed     |

Total: `2 + LEN + 3` bytes.

## Type reference, imports area (tag 0x66)

| Offset | Size  | Field    | Notes                                            |
|--------|-------|----------|--------------------------------------------------|
| 0      | u1    | Tag      | `0x66`                                           |
| 1      | u1    | NameLen  | `LEN`                                            |
| 2      | LEN   | Name     | ANSI(LEN)                                        |
| 2+LEN  | 4     | Hash     | Suspected hash; not interpreted by parser        |

Total: `2 + LEN + 4` bytes. Order in the imports area defines the user
type table: position 1 is the first such record after the System unit.

## Function import (tag 0x67)

Same layout as `0x66` (different tag).

| Offset | Size  | Field    | Notes                                            |
|--------|-------|----------|--------------------------------------------------|
| 0      | u1    | Tag      | `0x67`                                           |
| 1      | u1    | NameLen  | `LEN`                                            |
| 2      | LEN   | Name     | ANSI(LEN)                                        |
| 2+LEN  | 4     | Hash     | Not interpreted                                  |

Total: `2 + LEN + 4` bytes.

## Procedure / function record (tag 0x28)

| Offset      | Size  | Field        | Notes                                  |
|-------------|-------|--------------|----------------------------------------|
| 0           | u1    | CategoryTag  | `0x63` if present (`HeaderLen=3`); absent → `HeaderLen=2` |
| 0 / 1       | u1    | SubTag       | `0x28`                                 |
| 1 / 2       | u1    | NameLen      | `LEN`                                  |
| 2 / 3       | LEN   | Name         | ANSI(LEN)                              |
| 2+LEN / 3+LEN | 3–7  | MetaPrefix  | Meaning TBD; length varies per proc            |
| varies        | u1   | RvaTag      | `0x03` (32-byte aligned) or `0x83` (+16 bytes) |
| varies+1      | u1   | RvaLo       | Low byte of encoded RVA/32                     |
| varies+2      | u1   | RvaHi       | High byte of encoded RVA/32                    |
| varies+3      | 4–5  | MetaExtra   | Meaning TBD                                    |
| end−3         | 3    | Terminator  | `71 1C 00` — end of metadata block             |

**Proc start RVA** = `(RvaHi * 256 + RvaLo) * 32 + (RvaTag = 0x83 ? 16 : 0)`.
This is the image-relative virtual address (RVA) of the first instruction.
Total metadata length from `AfterName` to end of `71 1C 00`: 10–14 bytes observed.

The `RvaTag / RvaLo / RvaHi` triplet is found by scanning backward from
`71 1C 00` — the first `0x03` or `0x83` byte with at least one gap byte
before `71` is the tag. Confirmed against MAP for all 4 Debugme procedures.

Locals follow immediately after `71 1C 00`. There is no closing tag; the run
ends at the first byte that is not a valid local-var record start.

## Local variable, classic format (tag 0x20)

| Offset      | Size  | Field        | Notes                                  |
|-------------|-------|--------------|----------------------------------------|
| 0           | u1    | Tag          | `0x20`                                 |
| 1           | u1    | NameLen      | `LEN`, must be in `[1..63]`            |
| 2           | LEN   | Name         | ANSI(LEN)                              |
| 2+LEN       | u1    | TypeMarker   | `0x66` (or `0x46` for main-block)      |
| 2+LEN+1     | u1    | Reserved     | `0x00` — rejected if non-zero          |
| 2+LEN+2     | u1    | FormatFlag   | `0x00` for classic                     |
| 2+LEN+3     | u1    | TypeId       | Index encoding (= 2 × position in user type table) |
| 2+LEN+4     | i1    | RbpOffset    | Signed byte; address = `(RbpOffset div 2) + FrameSize` from RBP |

Total: `2 + LEN + 5` bytes.

## Local variable, inline format (tag 0x20)

| Offset      | Size  | Field        | Notes                                  |
|-------------|-------|--------------|----------------------------------------|
| 0           | u1    | Tag          | `0x20`                                 |
| 1           | u1    | NameLen      | `LEN`                                  |
| 2           | LEN   | Name         | ANSI(LEN)                              |
| 2+LEN       | u1    | TypeMarker   | `0x66` (or `0x46` for main-block)      |
| 2+LEN+1     | u1    | Reserved     | `0x00`                                 |
| 2+LEN+2     | u1    | FormatFlag   | `0x01` for inline                      |
| 2+LEN+3     | u1    | ?            | Unknown byte; parser ignores it        |
| 2+LEN+4     | u1    | TypeId       | Same encoding as classic               |
| 2+LEN+5     | i1    | RbpOffset    | Signed byte                            |

Total: `2 + LEN + 6` bytes.

## Var / reference parameter (tag 0x22)

Identical to the local variable record, classic or inline, but with
`Tag = 0x22`. The 8-byte slot at `RBP + offset` holds a pointer to the
caller's storage rather than the value.

## Main-block local (tag 0x20, marker 0x46)

| Offset      | Size  | Field        | Notes                                  |
|-------------|-------|--------------|----------------------------------------|
| 0           | u1    | Tag          | `0x20`                                 |
| 1           | u1    | NameLen      | `LEN`                                  |
| 2           | LEN   | Name         | ANSI(LEN)                              |
| 2+LEN       | u1    | TypeMarker   | `0x46`                                 |
| 2+LEN+1     | u1    | Reserved     | `0x00`                                 |
| 2+LEN+2     | u1    | FormatFlag   | `0x01` (parser filters out `0x00`)     |
| 2+LEN+3     | u1    | ?            | Unknown                                |
| 2+LEN+4     | u1/u2 | TypeId       | VLE: bit 0 clear = 1 byte, set = 2 bytes (LE) |
| 2+LEN+5/6   | i1    | RbpOffset    | follows the TypeId, so the record is 6 or 7 bytes past the name |

Total: `2 + LEN + 6` for the narrow form, `2 + LEN + 7` for the wide one.
Filtering on `FormatFlag = 1` is required to exclude RTL globals whose bytes
happen to contain `0x46` in the same spot.

The variable width was measured directly (hexdump of `TestTarget.rsm` at
`0xB4B888`), which is why it is stated as confirmed rather than inferred:

```
20 09 "TheWidget" 46 00 01 04 01 04 E0     <- 7-byte tail, TypeId $0401
20 08 "TheStuff"  46 00 01 04 05 04 F0     <- 7-byte tail, TypeId $0405
20 03 "Res"       46 00 01 04 06    D8     <- 6-byte tail, TypeId $0006
20 01 "X"         46 00 01 04 06    D0     <- 6-byte tail, TypeId $0006
```

The `RbpOffset` bytes (`E0 F0 D8 D0`, i.e. -32/-16/-40/-48) land correctly in
both forms, which independently confirms the widening.

**Narrow TypeId resolves; wide TypeId does not.** `Res`/`X` carry `$0006`,
which is `Idx = TypeId div 2 - 1` = 2 = `Integer` in the user-type table, and
that is right. `TheWidget: TWidget` carries `$0401` = 1025, but that table
holds 246 entries (highest valid TypeId `$01EC`): `shr 1` gives index 255
(past the end) and `shr 2` gives index 127, which is `PVariant`. `TWidget` is
absent from the table entirely — its module type id is `$62C9` — and it is
also absent from the unit's `$66` import list. Win32 shows the same shape with
different values (`$03ED`/`$03F1`), so it is not a 64-bit quirk.

Whatever space the wide ids address has not been identified. Until it is,
`CollectMainBlockLocals` deliberately leaves `TypeHint` empty for the wide
form: resolving it against the user-type table yielded a confidently wrong
name (`EPrivilege` on Win32, `RunClosureParamSampler$2$Intf` on Win64). The
value still renders from the runtime VMT, so class-typed main-block locals
display as `$28CB370 (TWidget)` rather than carrying a false declared type.

## Named constant (tag 0x25)

Emitted for every Delphi `const` declaration (unit-level and in-procedure),
including the System unit's predefined consts (`False`, `True`, `MaxInt`,
`varInteger`, ...). The fixed-shape header was decoded by diffing many records
of known value. Tool: `DevTools\ScanRsmConsts.exe <rsm> [filter]`.

| Offset      | Size       | Field         | Notes                                                       |
|-------------|------------|---------------|-------------------------------------------------------------|
| 0           | u1         | Tag           | `0x25`                                                      |
| 1           | u1         | NameLen       | `LEN`, same bounds as local-var records                     |
| 2           | LEN        | Name          | ANSI(LEN)                                                   |
| 2+LEN       | 3          | Marker        | always `8A 00 00` (validates the record / rejects false 0x25)|
| 5+LEN       | 4          | NameHash      | per-name hash (varies per record; not needed for the value) |
| 9+LEN       | u1         | TypeId        | `0x02`=Boolean, `0x0C`=Integer, others observed (`0x52`...)  |
| 10+LEN      | 2          | (reserved)    | always `00 00`                                              |
| 12+LEN      | var        | Value leaf    | numeric leaf (see below)                                    |

Value leaf (ordinal constants):
- If `leaf[0] and 1 = 0`: single byte, `value = leaf[0] shr 1`. Covers the
  common `const X = <small int>` (e.g. `02`->1, `04`->2, `06`->3; `00`->0).
- Escape `0x0F`: the next 4 bytes are a little-endian `Int32`
  (`MaxInt` = `0F FF FF FF 7F` = `$7FFFFFFF`).
- Larger/other leaves (wide ints, strings, floats) are not decoded yet.

Confirmed values: `False`=0, `True`=1, `varInteger`=3, `varRecord`=36,
`MaxInt`=$7FFFFFFF, and the test fixtures `TestTargetUsesA/B/C.DupConst` = 1/2/3.

Parsed today by `TRsmFile.EnsureUnitConstsParsed` (ordinal leaves only) for
per-unit-scoped constant resolution in watches; other leaf types are skipped
(the constant then reports as unresolved rather than returning a wrong value).

## EH / unwind record (tag `63 9E`)

| Offset | Size | Field   | Notes                                                          |
|--------|------|---------|----------------------------------------------------------------|
| 0      | u1   | Cat     | `0x63`                                                         |
| 1      | u1   | SubTag  | `0x9E`                                                         |
| 2      | ?    | Body    | Opaque; contains a C++ mangled name (`$unwind$_` / `$pdata$_`) |

Total: variable. Full sub-structure not decoded.

## Relocation/fixup table entry (`10 0F lo hi`)

| Offset | Size | Field  | Notes                                |
|--------|------|--------|--------------------------------------|
| 0      | u1   | Tag    | `0x10`                               |
| 1      | u1   | SubTag | `0x0F`                               |
| 2      | u1   | AddrLo | Low byte of encoded address          |
| 3      | u1   | AddrHi | High byte of encoded address         |

**RVA** = `(AddrHi * 256 + AddrLo) * 32 + 16`.

## Module record (`31 02 ED ED ...`)

| Offset     | Size    | Field    | Notes                                                 |
|------------|---------|----------|-------------------------------------------------------|
| 0          | 4       | Signature | `31 02 ED ED`                                        |
| 4          | ~2      | Flags    | Version/flag bytes; meaning TBD                       |
| ~6         | u1      | PathLen  | Byte length of source path                            |
| ~7         | PathLen | Path     | ANSI source directory (no NUL terminator)             |
| ~7+PathLen | u4      | StartRVA | Module start RVA (image-relative)                     |
| +4         | u4      | CodeLen  | Module code length in bytes                           |
| +8         | ?       | Tail     | Further fields; opaque                                |

Total: variable. One module record per compilation unit near the end of the RSM.

## Global variable, standard payload (`63 20` + `66`)

| Offset      | Size  | Field        | Notes                                  |
|-------------|-------|--------------|----------------------------------------|
| 0           | u1    | CategoryTag  | `0x63`                                 |
| 1           | u1    | SubTag       | `0x20`                                 |
| 2           | u1    | NameLen      | `LEN`                                  |
| 3           | LEN   | Name         | ANSI(LEN)                              |
| 3+LEN       | u1    | TypeTag      | `0x66`                                 |
| 3+LEN+1     | u1    | Reserved     | `0x00`                                 |
| 3+LEN+2     | u1    | Reserved     | `0x00`                                 |
| 3+LEN+3     | u1    | TypeId       |                                        |
| 3+LEN+4     | 3     | Payload      | Opaque RVA encoding; not parsed (RVA from `.map`) |

Total: `3 + LEN + 7` bytes.

## Global variable, runtime variant (`63 20` + `0xC6`)

| Offset      | Size  | Field        | Notes                                  |
|-------------|-------|--------------|----------------------------------------|
| 0           | u1    | CategoryTag  | `0x63`                                 |
| 1           | u1    | SubTag       | `0x20`                                 |
| 2           | u1    | NameLen      | `LEN`                                  |
| 3           | LEN   | Name         | ANSI(LEN)                              |
| 3+LEN       | u1    | TypeTag      | `0xC6`                                 |
| 3+LEN+1     | ?     | Payload      | Longer than the standard variant; opaque |

The parser advances by exactly `3 + LEN + 1` bytes for this variant
(i.e. only past the type tag) and falls back on the next-record
heuristic for what follows. Effectively the rest of the record is lost.

## Type declaration (tag 0x2A)

| Offset       | Size  | Field        | Notes                                       |
|--------------|-------|--------------|---------------------------------------------|
| 0            | u1    | Tag          | `0x2A`                                      |
| 1            | u1    | NameLen      | `LEN` (max observed 30+ for generic insts)  |
| 2            | LEN   | Name         | ANSI(LEN); may carry `{Unit}` prefix        |
| 2+LEN        | u1    | Flags        | `$20` simple, `$40` generic, `$60` meta, ...|
| 2+LEN+1      | u2    | Reserved     | `00 00` (or `00 08` for some generics)      |
| 2+LEN+3      | u2    | TypeId       | Canonical 16-bit type identifier, LE        |
| 2+LEN+5      | ...   | Trailer      | Variant; see below                          |

Three trailer variants observed (each with its own advance width):

- **Variant B — generic instantiation.** `$00` at offset `2+LEN+5`;
  next record starts immediately at `2+LEN+6`. Total record: `2 + LEN + 6`.
  **This must be checked first** — Variants A and C key off a single byte
  (`$1E` / `$1F`) at `2+LEN+7` which can coincidentally match the NameLen
  byte of an immediately-following record. If A/C runs before B, the
  parser overshoots a generic-instantiation record by ~2 bytes and the
  next type-decl entry is silently dropped from the type table.
- **Variant A — simple type.** `$1E` at offset `2+LEN+7` (with no `$00`
  at `2+LEN+5`). Total record: `2 + LEN + 8` (parser advances by N+8;
  any extra trailer bytes get re-discovered by the per-byte fallback).
- **Variant C — class type** (e.g. `TStuff`, `TWidget`). `$1F` at offset
  `2+LEN+7` (with no `$00` at `2+LEN+5`). Total record: `2 + LEN + 8`.

For class types, the `TypeId` at +N+3..+N+4 is also the value that
appears in the trailing `08 <classHash> FF` block of every member
record (`$2C`/`$2E`/`$2F`/`$31`), letting the parser group members
back to their class.

## Class field record (tag 0x2C)

| Offset     | Size | Field         | Notes                                       |
|------------|------|---------------|---------------------------------------------|
| 0          | u1   | Tag           | `0x2C`                                      |
| 1          | u1   | NameLen       | `LEN`                                       |
| 2          | LEN  | Name          | ANSI(LEN), field identifier                 |
| 2+LEN      | u1   | Flags         | `$00` observed for plain fields             |
| 2+LEN+1    | u1   | Visibility    | `$00` private / `$02` public / `$0A` published |
| 2+LEN+2    | u1   | Reserved      | `$00`                                       |
| 2+LEN+3    | 1–2  | TypeId        | VLE-encoded: LSB=0 → 1-byte typeId; LSB=1 → 2-byte typeId LE. Low byte alone is **not** sufficient. |
| 2+LEN+3+T  | u1   | OffsetByte    | `actualOffset × 2`; halve to recover offset (`T` = typeId byte width, 1 or 2) |
| 2+LEN+4+T  | 2    | Marker        | `9C 09` for fields with a 1-byte TypeId, `9C 01` for fields with a 2-byte TypeId |
| 2+LEN+6+T  | u2   | FieldHash16   | Per-record hash (LE); referenced by `$31`   |
| 2+LEN+8+T  | ...  | Opaque tail   | Several bytes ending in `08 <classHash> FF` |

The class-hash trailer is 1 or 2 bytes wide depending on its magnitude;
walk backward from the terminating `$FF` to the first `$08` to find it.

## Class method record (tag 0x2E)

| Offset     | Size | Field         | Notes                                       |
|------------|------|---------------|---------------------------------------------|
| 0          | u1   | Tag           | `0x2E`                                      |
| 1          | u1   | NameLen       | `LEN`                                       |
| 2          | LEN  | Name          | ANSI(LEN), method identifier                |
| 2+LEN      | u1   | Flags         | `$00` typical                               |
| 2+LEN+1    | u1   | Visibility    | Same encoding as fields                     |
| 2+LEN+2    | u1   | Reserved      | `$00` typical (`$22` observed for some sigs)|
| 2+LEN+3    | u1   | Marker        | `$E2`                                       |
| 2+LEN+4    | u2   | BodyHash16    | 16-bit hash (LE); property getter binding   |
| 2+LEN+6    | u1   | `$01`         |                                             |
| 2+LEN+7    | u1   | `$8C` / `$9C` | Does **not** encode return-class            |
| 2+LEN+8    | 2    | `9C 01`       | Sequence marker                             |
| 2+LEN+10   | u2   | PerRecHash16  | Per-record sequence index (LE)              |
| ...        | ...  | Opaque tail   | `08 <classHash> FF`                         |

The method's return type is **not** decoded from these bytes; the
heuristic in `ExprEval.ApplyMethodCall` falls back on guessing.
`KNOWN_UNKNOWNS.md` tracks this gap.

## Class constructor record (tag 0x2F)

Identical to `0x2E` apart from the leading tag.

## Class property record (tag 0x31)

| Offset     | Size | Field          | Notes                                       |
|------------|------|----------------|---------------------------------------------|
| 0          | u1   | Tag            | `0x31`                                      |
| 1          | u1   | NameLen        | `LEN`                                       |
| 2          | LEN  | Name           | ANSI(LEN), property identifier              |
| 2+LEN      | u1   | Flags          | bit `$40` = the class's `default` array property; `$00` otherwise, INCLUDING a non-default indexed one |
| 2+LEN+1    | u1   | Visibility     | Same encoding as fields/methods             |
| 2+LEN+2    | u1   | Reserved       | `$00`                                       |
| 2+LEN+3    | 1–2  | TypeId         | VLE-encoded same as `$2C.TypeId` (LSB rule). |
| 2+LEN+3+T  | 5    | Marker         | `FE 0F 00 00 00`                            |
| 2+LEN+8+T  | u1   | `$80`          | Getter slot                                 |
| 2+LEN+9+T  | u2   | GetterHash16   | 16-bit hash (LE); matches `$2C.FieldHash16` or `$2E.BodyHash16` |
| ...        | ...  | Opaque tail    | `08 <classHash> FF`                         |

A second `$80` marker may appear later in the tail (setter / per-rec
hash); the parser only consumes the first one.

## Field-derivation rules used by the debugger

- **Local address**: `RBP + ((RbpOffset div 2) + FrameSize)`, where
  `FrameSize` is the prologue's `sub rsp, NN` immediate (or the imm32
  variant). Computed in `Win64Debugger.CollectLocalsForFrame` as a signed
  add to avoid `EIntOverflow` under `{$Q+}`.
- **Type name**: `UserTypes[(TypeId div 2) - 1]`, empty when out of range.
- **Var-param storage**: the 8-byte slot at the local's address holds a
  pointer; the real value lives at `*slot`. Both `RawValue` (slot) and
  `DerefValue` (`*slot`) are surfaced to the caller.
