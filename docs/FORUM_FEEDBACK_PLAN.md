# Delphi-PRAXiS review feedback — plan

Status: **four of five done** (2026-08-26). #2, #3, #4 and #5 are implemented,
tested and measured; #6 is answered with numbers instead of code and needs a
decision (see its section). The sixth report item still has no plan.

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

## #2 — NAMES table: offsets instead of strings — DONE

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

Measured with `DevTools\Td32LoadBench.exe` (new), mean of 5 loads:

| binary | names | load | working set held |
|---|---:|---:|---:|
| TestTarget x64 | 32 599 | 45.6 → 41.0 ms | 15 548 → 12 948 KB |
| TestTarget x86 | 30 084 | 35.1 → 29.5 ms | 14 716 → 12 272 KB |
| Debugme x64    | 17 304 | 11.1 → 7.4 ms  | 2 472 → 2 468 KB |

10-17% off the load and about 17% off what a loaded module holds, except on
Debugme, whose load resolves nearly every name it has and therefore gains only
time. Real, not dramatic — which is what the numbers were for.

## #3 — Name OS frames from the export directory — DONE

The top frames (`BaseThreadInitThunk`, `RtlUserThreadStart`) come out correct and
anonymous. The unwind is fine: `StackWalk64` reaches them and the modules are
registered with dbghelp. There is simply no name lookup — no `SymFromAddr`
anywhere, and `RvaToFunctionName` has nothing to say about a module with no
Delphi debug info.

The fallback is the module's own PE export directory: largest exported RVA <=
target, rendered `module!Name+$offset`. No symbol server, no PDB, no dependency,
and it generalises to every DLL without debug info, which is the actual value —
the two frames that prompted the report are the least of it.

Built as `NameFromModuleExports` / `ExportedSymbolAt` / `ExportIndexOf` in
`WinDebuggerBase.pas`, reading the live image, one read per module, cached per
module base. Mechanism and limits in `DAP_DEBUGGER_ARCHITECTURE.md` under "Naming
a frame from the module's export table".

What the 32-bit half of the test taught, and what the report did not anticipate:
an export table says where each **exported** routine starts, and the 32-bit ntdll
of a WOW64 process does not export its thread starter. So the outermost frame
there reads `ntdll.dll!RtlGetAppContainerNamedObjectPath+$230` — the nearest
export, plus the distance to it. Coarse but not false, and the `+$offset` is what
keeps it honest. Deriving the true function start from `.pdata` would fix the x64
half exactly; it is not done.

One thing deliberately unchanged: `Symbols` stays `saNoSymbols` for such a frame.
A name from an export table is not symbols, and the pre-existing F23 distinction
(unknown address / no debug info / still indexing) had to survive the frame
acquiring a label.

## #4 — C++Builder TDS signature — DONE

`TD32_SIGNATURE` becomes a pair (`FB09` Delphi, `FB0A` C++Builder). Nearly free,
and the container is reportedly identical; only demangling differs. No
C++Builder binary is available here, so the demangler stays marked unverified
instead of being advertised.

Done as `IsTD32Signature` plus a `ContainerSignature` property that records which
dialect was found. Tested by restamping a Delphi container to `FB0A`
(`CppBuilderSignature_IsAccepted`), which is the only C++Builder-shaped input
available here. The demangler is untouched and the property's own comment says
the support is container-level.

## #5 — Locate the blob from EOF, section walk as fallback — DONE, with a
correction

`LocateTd32Base` already does the trailer dance the Borland debugger does. What
is PE-dependent is one step earlier: the blob is found by walking section headers
for `.debug`. Seeking from EOF first removes that dependency and additionally
finds a blob simply appended with no section describing it, which today is
invisible.

The correction: the order could not simply be inverted. `FindDebugSection` does
double duty — besides finding the section it builds `FSegmentVAs`, `FSecRva*` and
`FImageBase`, and without those no CodeView offset can be turned into an RVA. So
the section walk still always runs, and `FindAppendedDebugBlob` is the fallback
for LOCATING the blob. The PE is not redundant here, whatever the Borland
debugger does with its own.

Tested for real rather than by inspection: the fixture is a copy of
TestTarget.exe with the `.debug` section HEADER deleted and NumberOfSections
decremented, which leaves the bytes exactly where they were. It asserts an
identical line table, not merely a successful load.

Also from the report, still to be verified before it goes into
`TD32_FORMAT_NOTES.md`: PDB and TDS can coexist in one PE as long as the TDS
block stays last.

## #6 — Map the blob, not the whole image — MEASURED, NOT DONE

`TTD32FileReader` maps the entire executable and holds the view for its lifetime;
`RsmFileReader` and `MapFileReader` do the same. The proposed change was to read
the header conventionally, locate the blob per #5, and map only that region.

What the numbers say, before writing any of it:

- In a Delphi binary with embedded debug info the blob IS most of the file. In
  the 64-bit TestTarget: `.debug` is 3 858 485 bytes of a 5 708 853-byte image,
  68%. Mapping "only the blob" would drop 1.8 MB of address space per module.
- The view is file-backed and demand-paged. The load touches essentially the
  whole blob (types, symbols, source modules) and, outside it, the PE header and
  the import directory — a handful of pages, during the load only. So the pages
  that become resident are the ones we would map either way.
- The measured cost of a loaded module (12 948 KB for TestTarget x64) is parsed
  structures, not the mapping.

So the literal proposal saves address space on a 64-bit host and close to nothing
else, in exchange for rebasing every pointer that survives the load
(`FDebugBase`, `FDebugEnd`, `FTd32Base`, `FNamesBase` — and #2 made the last of
these load-bearing after the load, not just during it). Not worth it as stated.

**There is an adjacent change that IS worth deciding on**, and it is a different
trade: copy the blob into a heap buffer and drop the mapping entirely. A mapped
view keeps the file object alive, so today a loaded reader keeps the debuggee's
binary locked against rebuilds for as long as it lives. Trading demand-paged
mapping for a resident copy (~3.8 MB per module for TestTarget) would remove
that lock. That is a product decision, not a cleanup, so it is not made here.

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
