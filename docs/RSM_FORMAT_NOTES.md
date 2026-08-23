# RSM Format Notes

Living specification for Delphi Win64 `.rsm` (Remote Symbol Map) files.
Reverse-engineered through controlled diff experiments. Source of truth is
`DebuggerCore/RsmFileReader.pas`; if this document disagrees with the parser,
the parser wins and this document is corrected.

Companion documents:
- `RSM_RECORD_TYPES.md` — catalog of tag bytes and record kinds.
- `RSM_FIELD_OFFSETS.md` — byte-level layout of each record.
- `KNOWN_UNKNOWNS.md` — open questions blocking further decoding.

## Purpose

The `.rsm` is Embarcadero's own Win64 remote-debug symbol container, emitted
alongside `.exe`/`.map` when the project is built with `-V -VN -VR`. It is
not a PDB / DWARF / STABS dialect: there is no public format spec.

The debugger uses it for everything the `.map` cannot provide:

- Per-procedure list of locals (name, RBP-relative offset, type id).
- Globals discovered by name (RVA still resolved through the `.map`).
- A per-file user-type table that resolves the local/global `typeId` to a
  type name string.

**The RSM does NOT contain a source line-number table on Win64.** The `.map`
file is and will remain the sole source for line→RVA mapping. See
`RSM_RECORD_TYPES.md` for the exhaustive-search conclusion.

## File layout (high level)

```
+--------------------+ offset 0
|  Header            |  4-byte magic "CSH7" + ExePath relative-path string
+--------------------+
|  Imports area      |  unit references (0x65), used type table (0x66),
|                    |  function imports (0x67), interleaved in source-
|                    |  reference order
+--------------------+
|  Symbol records    |  procedures (0x63 0x28), globals (0x63 0x20),
|                    |  locals (0x20 / 0x22), constants (0x25),
|                    |  EH records (0x63 0x9E), main-block locals ($46 marker)
+--------------------+
|  Relocation table  |  4-byte entries (10 0F lo hi), encoding RVAs at
|                    |  128-byte intervals for all modules' embedded code
+--------------------+
|  Module record     |  per-module: source path, startRVA, codeLen, flags
+--------------------+
```

The parser does not walk the file structurally end-to-end; it scans for
recognisable record signatures. This is intentional — it stays robust as
new tag bytes are discovered, at the cost of pattern-match false positives
that have to be filtered out (e.g. the `$46` filter described below).

## Header

```
0x00  4 bytes   magic            "CSH7" (ASCII) — file is rejected if absent
0x04 ... 0x1F   <unstudied>
0x20  N bytes   ExePath (ANSI)   relative path of the source `.dpr`, NUL-terminated;
                                 the basename (extension stripped) is used as the
                                 procedure name attached to the program's main
                                 begin..end block locals
```

`CollectMainBlockLocals` derives the program's "main procedure" name by
reading bytes from offset `0x20` up to the first NUL (capped at 0x400),
ANSI-decoding, then `ChangeFileExt(ExtractFileName(...), '')`.

Bytes between `0x04` and `0x1F` are not yet interpreted.

## Imports area

The imports area starts immediately after the header section the parser
locates by searching for the `65 06 'S' 'y' 's' 't' 'e' 'm' 00 00 00 66 ..`
sequence (the System unit reference followed by its first imported type).
This is the only structural anchor the parser uses to bootstrap; before it,
the file is opaque to us.

After `65 06 System 00 00 00`, records repeat in source-reference order:

| Tag  | Record                                                    |
|------|-----------------------------------------------------------|
| 0x65 | Unit reference: `65 [LEN] [NAME ANSI] [3 bytes payload]`. |
| 0x66 | User type: `66 [LEN] [NAME ANSI] [4 bytes hash]`.         |
| 0x67 | Function import: `67 [LEN] [NAME ANSI] [4 bytes hash]`.   |
| 0x63 | End of imports — first symbol category record.            |

The user type table is the ordered subsequence of `0x66` records. Because
they are interleaved with function imports in source order rather than
laid out as a contiguous block, the parser collects them with index 1
through N as it walks. Local/global records encode their `typeId` as
`2 * position`.

## Symbol records area

Four kinds of records are recognised:

### Procedure (`63 28` or bare `28`)

**Two structural forms** depending on context:

- `63 28 [LEN] [NAME]` — standalone procedures (top-level, nested, Windows API
  imports). The `$63` category prefix is present.
- `28 [LEN] [NAME]` — class methods (constructors, regular methods). The bare
  `$28` appears **without** a preceding `$63`. These records live in a
  separate section near the end of the RSM file (after the standalone-procedure
  symbol area), together with class-type declaration records (`$2A [LEN] [NAME]`).

Followed by `[LEN] [NAME ANSI]`, then a variable-length metadata block
(up to ~38 bytes for class methods, up to ~20 bytes for standalone procs),
then a run of local-variable/parameter records.

**Procedure metadata block** (bytes from `AfterName` through first local):

```
[prefix bytes: 3–7 bytes, meaning TBD]
[03|83] [lo] [hi]               ← proc start RVA/32 encoding (confirmed)
[4–5 extra bytes, meaning TBD]
71 1C 00                        ← block terminator (confirmed)
```

**RVA encoding** (confirmed for all 4 Debugme procedures, 4/4 EXACT vs MAP):

```
tag  := byte; must be 0x03 or 0x83
lo   := byte
hi   := byte
encoded := hi*256 + lo          (LE u16)
proc_start_RVA := encoded * 32 + (if tag = 0x83 then 16 else 0)
```

Bit 7 of the tag selects the 16-byte sub-alignment: `0x03` for 32-byte-
aligned starts, `0x83` for starts at 32n+16.  The triplet is located by
scanning backward from the `71 1C 00` terminator (found within 48 bytes of
`AfterName`), looking for the first `03` or `83` byte such that at least
one gap byte separates it from `71`.

Observed examples (historical `Debugme.exe` build; the byte values illustrate
the encoding and shift with every rebuild — they are not tracked against the
current binary):

| Proc                  | tag  | lo   | hi   | encoded | decoded RVA | MAP RVA |
|-----------------------|------|------|------|---------|-------------|---------|
| ThisIsALocalProcedure | 0x03 | 0x95 | 0x17 | 0x1795  | 0x2F2A0     | 0x2F2A0 |
| Increment             | 0x03 | 0x9D | 0x17 | 0x179D  | 0x2F3A0     | 0x2F3A0 |
| Finalization          | 0x83 | 0xA5 | 0x17 | 0x17A5  | 0x2F4B0     | 0x2F4B0 |
| Debugme               | 0x03 | 0xA6 | 0x17 | 0x17A6  | 0x2F4C0     | 0x2F4C0 |

The prefix bytes and extra bytes remain undecoded (see `KNOWN_UNKNOWNS.md`).

### Local variable / parameter (`0x20`, `0x21`, or `0x22`)

Three tag values are now confirmed. Two type-marker variants coexist:

```
classic (FormatFlag=0): 20|21|22 [LEN] [NAME] 62|66 00 00 [TYPEID] [OFFSET]   (8+LEN bytes)
inline  (FormatFlag=1): 20|21    [LEN] [NAME] 62|66 00 01 [?] [TYPEID] [OFFSET] (9+LEN bytes)
```

Tag meanings:

| Tag  | Meaning                                                     |
|------|-------------------------------------------------------------|
| 0x20 | Local variable or value parameter (standalone procedures)   |
| 0x21 | Const or value parameter of a **class method** (confirmed)  |
| 0x22 | `var` / reference parameter — slot holds pointer to caller  |

Type-marker byte (after the name):

| Marker | Context                                              |
|--------|------------------------------------------------------|
| 0x66   | Standard local / value parameter                     |
| 0x46   | Main-block local (variant for program `begin..end`)  |
| 0x62   | Const/managed-ref parameter of a class method        |

Observed: `const AName: string` → tag `$21`, marker `$62`.
Observed: `AValue: Integer` (value param in constructor) → tag `$21`, marker `$66`.

`Offset` is a signed byte whose RBP-relative address is computed differently
depending on the type marker:

| Marker | Formula                              |
|--------|--------------------------------------|
| 0x66   | `(OffByte div 2) + FrameSize`        |
| 0x62   | `(OffByte div 2) + FrameSize`        |
| 0x46   | `OffByte * 2`  (direct slot; no FrameSize adjustment) |

The `$46` variant is used exclusively by the program's main `begin..end` block
(DPR main body). Confirmed empirically: TestTarget.exe `TheWidget` → RSM
`OffByte = 28`, instruction `mov [rbp+0x38], rax` → slot = 56 = 28 × 2 ✓.

### Global variable (`63 20`)

```
63 20 [LEN] [NAME] 66 00 00 [TYPEID] [3 bytes — opaque RVA encoding]
```

A variant uses `0xC6` instead of `0x66` for some Delphi runtime globals
(`ModuleIsLib` and similar) and carries a longer opaque payload; the
parser preserves the name but does not decode the type for that variant.
The RVA itself is *not* recovered from the `.rsm` — the global's address
is resolved through the `.map` file's PUBLICS section.

### Named constant (`0x25`)

Observed after the local-variable run of `ThisIsALocalProcedure` for
`const FOO = 'foo'`. Format:

```
25 [LEN] [NAME ANSI] [~13 bytes opaque] [VALUE_LEN: u4 LE] [value bytes]
```

The opaque block between name and value likely encodes type information.
Value bytes contain the string content; the exact encoding (ANSI / UTF-16)
is not fully established. The parser does not handle this record type today.

### EH records (`63 9E`)

Fill the inter-procedure gaps after each procedure's local-variable run.
Encode compiler-generated `$unwind$_` and `$pdata$_` C++ EH symbols (the
Win64 unwind metadata Delphi generates to satisfy the OS exception tables).

```
63 9E [opaque sub-structure] [mangled name ANSI]
```

The `9E FE` prefix also appears before the extended locals run of
`Increment` (which has a `var` parameter). The exact role of `9E` in this
second context is not yet resolved.

### Main-block locals (`0x46` marker)

Locals declared inside the program's main `begin..end` block are emitted
with the variant marker `$46` instead of `$66`. Their payload is otherwise
identical to the inline-format local-var record. They live in a separate
area of the file that is not physically adjacent to the main procedure
record, so the parser does a second sweep:

1. Find every `20 [LEN] [NAME] 46 00 01 [?] [TYPEID] [OFFSET]` record in
   the file.
2. Filter to `FormatFlag = 1` so RTL globals that happen to use the byte
   `0x46` for unrelated reasons are skipped.
3. Attach the harvested locals to the procedure named after the
   ExePath basename.

**`$46` locals appear inside an anonymous proc record** (`28 00`, NameLen=0)
immediately before the named program proc record in the RSM. The named proc
record (e.g. `28 0A TestTarget`) contains no locals of its own. The parser
handles this by: (a) allowing NameLen=0 in `TryParseProcedureAt`; (b) if a
named procedure's local list is empty, searching backward up to 256 bytes for
a `$28 $00` anonymous proc and using its locals instead.

**Offset formula for `$46` locals**: `OffByte * 2` (not `(OffByte div 2) +
FrameSize`). See the table under the local variable section above.

## Conventions and quirks

- Identifiers are length-prefixed ANSI; `LEN` is one byte and is bounded
  to `[1..63]` by the parser as a sanity check.
- Type names are looked up from the user type table by index
  `(typeId div 2) - 1` (1-based encoding).
- Scope is implicit: the locals between two procedure records belong to
  the first one. There is no closing tag.
- A bare `0x20` byte does not start a local record unless preceded by
  something other than `0x63` (which would make it a global).

## Reading order for tools and humans

To pull useful data out of an `.rsm` from scratch, the parser does:

1. Validate magic `CSH7`.
2. `ParseUserTypeTable` — anchor on the System unit, walk imports.
3. `Parse` — sweep the rest of the file for procedures and globals.
4. `CollectMainBlockLocals` — second sweep for `$46` records.

That order is reflected in `TRsmFile.LoadFromFile`.

## What still isn't understood

See `KNOWN_UNKNOWNS.md`. The big buckets:

- Prefix bytes (3–7) and extra bytes (4–5) in the procedure metadata block.
- Bytes `0x04..0x1F` of the header.
- Type descriptor encoding beyond a flat name lookup (records, classes,
  arrays, generics).
- Whether other parameter-kind tags (0x21, 0x23, …) exist and what they mean.
- The `0xC6` global variant payload.

## What the main-block table does NOT contain

The program main block's locals are the `$20` records carrying the `$46`
(`TYPEREF_MARKER_MAIN`) type reference, and they cover the block's inline
`var`s -- `localdata`, `foo`, `TheWidget`, `TheStuff`. They do **not** cover the
alias of an `on E: ... do` handler written in that main block, and no amount of
scope-walking will make them: dcc does not give that alias a stack slot at all.
It allocates a module-level static instead, which lands in TD32 as an LDATA32
global and in the RSM outside the main-block local table.

Recorded because the shape of the symptom -- "`E` is missing from the main
block's locals" -- invites a search for a missing RSM record. There is nothing
to find. See `EH_FORMAT_NOTES.md`, "The `on` alias, and where the compiler puts
it".
