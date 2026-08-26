# Delphi-PRAXiS review feedback — plan

Status: **OPEN** (filed 2026-08-26). Five items, none started.

After the release announcement on Delphi-PRAXiS
([thread](https://en.delphipraxis.net/topic/15822-i-built-a-freeopen-source-delphi-debugger-for-vs-code-also-works-as-an-mcp-server-for-ai-agents/)),
Kas Ob. read the TD32 reader and the call-stack screenshot and returned six
concrete points. Five of them are work; they are filed as GitHub issues #2-#6 and
summarised here so the reasoning survives outside the tracker. The sixth is a
design change large enough to belong to its own plan, and is recorded at the end
as not-yet-filed.

Nothing below is speculative reading of someone's intent: each item was checked
against the code before being filed, and where the report's premise was partly
wrong, the entry says so rather than agreeing politely.

## #2 — NAMES table: offsets instead of strings

`BuildNamesIndex` materialises every SST_NAMES entry into `TArray<string>` at
load time; `ResolveNameByIndex` is the only consumer. Tens of thousands of
managed allocations per module on a multi-BPL target, most never read.

The eager build is not naive, and this is the part the report could not see: it
exists so the reader is **immutable once published**. A lazy version mutated the
shared reader from the naming path and two threads raced a dynamic-array
realloc. The fix therefore has to be an array of *offsets* built by the same
single walk, decoded on demand — still a pure read, so the thread-safety
property is untouched, while the per-name cost drops from a 32-byte-minimum
managed string to 4-8 bytes.

Measure before claiming the win: if the load already resolves most names, it is
smaller than it looks.

## #3 — Name OS frames from the export directory

The top frames (`BaseThreadInitThunk`, `RtlUserThreadStart`) come out correct and
anonymous. The unwind is fine: `StackWalk64` reaches them and the modules are
registered with dbghelp. There is simply no name lookup — no `SymFromAddr`
anywhere, and `RvaToFunctionName` has nothing to say about a module with no
Delphi debug info.

The fallback is the module's own PE export directory: largest exported RVA <=
target, rendered `Name +$offset`. No symbol server, no PDB, no dependency, and it
generalises to every DLL without debug info, which is the actual value — the two
frames that prompted the report are the least of it.

## #4 — C++Builder TDS signature

`TD32_SIGNATURE` becomes a pair (`FB09` Delphi, `FB0A` C++Builder). Nearly free,
and the container is reportedly identical; only demangling differs. No
C++Builder binary is available here, so the demangler stays marked unverified
instead of being advertised.

## #5 — Locate the blob from EOF, section walk as fallback

`LocateTd32Base` already does the trailer dance the Borland debugger does. What
is PE-dependent is one step earlier: the blob is found by walking section headers
for `.debug`. Seeking from EOF first removes that dependency and additionally
finds a blob simply appended with no section describing it, which today is
invisible.

Also from the report, to be verified and then written into
`TD32_FORMAT_NOTES.md`: PDB and TDS can coexist in one PE as long as the TDS
block stays last.

## #6 — Map the blob, not the whole image

`TTD32FileReader` maps the entire executable and holds the view for its lifetime;
`RsmFileReader` and `MapFileReader` do the same. The view must stay alive (records
and names are read out of mapped memory, and #2 depends on that), so the change
is to read the header conventionally, locate the blob per #5, and map only that
region at allocation granularity.

Scope kept honest: a mapping costs address space and page cache, not committed
memory, so on a 64-bit host the current cost is smaller than the report implies.
Mapping a whole multi-megabyte image to read two trailers is still wrong.

## Not filed: rebuild the full signature from the Borland mangling

The sixth point, and the most valuable one. `DemangleBorland` truncates at `$`,
so the call stack shows `Increment` where it could show
`Increment Proc(var x: Integer)` — the tail is a parameter list, not noise. The
truncation dates from chasing a narrower bug (entities declared inside a routine
losing their type on 32-bit) and stopped where that bug stopped hurting.

This is more work than #2-#6 together: it needs the Borland type encoding
decoded, a rendering decision for the DAP frame label, and a decision about
whether the signature belongs in the frame name or in a separate field. It gets
its own plan document before any code.

One clarification the thread raised, worth keeping: `DemangleItanium` is not a
misnomer or a stray C++ import. `dcc64` genuinely emits Itanium-style names in
TD32 for Win64 (`_ZN...E`, `C0..C3`/`D0..D2`, `S_` substitutions, and bare
length-prefixed source names such as `15frmSplashScreen` with no `_Z` wrapper for
unqualified globals). Borland `$qqr` mangling is what 32-bit targets emit. The two
demanglers are the two schemes for the two bitnesses, not two attempts at one
job — which does not read that way from outside the code, so the unit needs a
comment saying it.
