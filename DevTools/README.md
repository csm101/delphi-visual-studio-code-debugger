# DevTools

Diagnostic and development tools for the Win64Debugger project.
These tools inspect binary debug-info formats, validate the parsers in
`DebuggerCore`, disassemble target functions, and probe live processes.
They are versioned here so they can be built and used on any machine without
relying on external paths.

All tools are Win64 console applications and print to stdout.

## Build

```bat
DevTools\build_all.bat
```

`build_all.bat` **discovers** the tools: every `*.dpr` in this folder is built,
so adding a tool means dropping the `.dpr` here — there is no list to keep in
sync. Binaries land in `DevTools\Win64\Debug\`.

Build a single tool:

```bat
DevTools\build_one.bat StepPerf
DevTools\build_one.bat StepPerf X:\Temp\privatebuild
```

The optional second argument is the output directory (default
`.\Win64\Debug`); use a private directory when several builds may run
concurrently, so they do not race on the shared DCU cache.

A few probes exist to measure what the **32-bit** compiler emits and contain x86
assembly, so they cannot build under `dcc64` at all. `build_all.bat` skips them
(its `WIN32_ONLY` list); build those with:

```bat
DevTools\build_one32.bat Win32FloatAbiProbe.dpr
```

Binaries land in `DevTools\Win32\Debug\`.

Run a built tool from `Win64\Debug` without typing the path:

```bat
DevTools\devtool.bat TestRsmParser samples\Debugme\Win64\Debug\Debugme.rsm
```

### Third-party sources

`TdsProbe` and `JclProbe` compile against the upstream JCL sources. When those
sources are absent, `build_all.bat` skips those two tools and builds the rest.
The source roots are resolved by `..\scripts\setpaths.bat` and can be overridden from
the environment:

```bat
set JCL_ROOT=D:\src\jcl\jcl\source
set DUNITX_ROOT=D:\src\DUnitX\Source
```

### Tools that start a target

No target a probe starts may show a dialog (`CLAUDE.md`, "A test never opens a
dialog and never takes the focus"). Every tool that starts one -- directly, or
through the engine, the adapter or the MCP server (`BreakpointHitCost`,
`DapSessionTiming`, `DataBpProbe`, `Disasm`, `ExcHandlerProbe`,
`ExceptionStopProbe`, `LineProbeCost`, `LiveSessionProbe`, `LoaderTimingProbe`,
`McpStdioProbe`,
`PatchFeasibilityProbe`, `ProbeCostProbe`, `SessionEndLockProbe`, `StepPerf`,
`Win32SessionProbe`, `Wow64RegWriteProbe`, `Wow64StackProbe`) -- calls
`SetErrorMode(GetErrorMode or SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or
SEM_NOOPENFILEERRORBOX)` as the first statement of its main block, and every
process below it inherits that mode. A new tool that starts a target does the
same. The fixtures in `Fixtures\` use `FixtureQuiet` like every test fixture
(`docs\TRAPS.md`, "Fixture design").

## Tools

Grouped by what you are investigating.

### RSM format (`.rsm` remote symbol map)

#### RsmAnalyzer

Analyzes a Delphi `.rsm` file and produces three output files next to the input:

| Output | Content |
|--------|---------|
| `.analysis.txt` | Magic, header fields, byte histogram, region map, record scan |
| `.strings.txt`  | All printable ASCII runs of 4+ chars with file offsets |
| `.hex.txt`      | Full hex + ASCII dump |

```bat
DevTools\Win64\Debug\RsmAnalyzer.exe samples\Debugme\Win64\Debug\Debugme.rsm
```

Reach for this when the RSM parser fails to find a procedure or variable —
inspect the `.analysis.txt` record scan to understand the actual byte layout
near the name.

#### ScanRsmMethods

Searches for a string inside an `.rsm` file and dumps the surrounding bytes
together with the tag context (bytes before the string hit). The search term
defaults to `Create`.

```bat
DevTools\Win64\Debug\ScanRsmMethods.exe samples\Debugme\Win64\Debug\Debugme.rsm TWidget.Create
```

Reach for this to locate where a class method name appears in the RSM and
verify whether it is preceded by `$63 $28` (standard) or a bare `$28` (class
declared in the `.dpr`).

#### ScanRsmConsts

```bat
DevTools\Win64\Debug\ScanRsmConsts.exe samples\Debugme\Win64\Debug\Debugme.rsm [name-substring-filter]
```

Scans an `.rsm` for named-constant records (tag `0x25`) and dumps their
trailing value bytes. Reach for this when decoding how a constant's value is
encoded after its name.

#### DumpRsmUses

```bat
DevTools\Win64\Debug\DumpRsmUses.exe samples\Debugme\Win64\Debug\Debugme.rsm [unit-name-filter]
```

Dumps the unit-dependency ("uses") clusters recorded in an `.rsm`. Reach for
this when you need to know which units a module's RSM claims to depend on, or
to map a type id back to the unit that exported it.

#### RsmDiff

```bat
DevTools\Win64\Debug\RsmDiff.exe old\Debugme.rsm new\Debugme.rsm all
```

Differential comparison of two `.rsm` files; the optional last argument selects
the comparison mode (`prefix`, `suffix`, `insertion`, `all`). This supports the
standard method for decoding an unknown RSM record: compile the same project
twice with one small source change and see which bytes moved.

#### DumpRsmNames

```bat
DevTools\Win64\Debug\DumpRsmNames.exe samples\Debugme\Win64\Debug\Debugme.rsm
```

Prints the total number of procedure names the RSM reader indexed, then lists
the ones matching a set of substring filters. Note: the filters are hardcoded
to test-target identifiers (`testtarget`, `init`, `twidget`, …), so the tool is
a quick "did the parser index anything at all?" check rather than a general
name browser — use `TestRsmParser` for a full listing.

#### DumpRsmClass

```bat
DevTools\Win64\Debug\DumpRsmClass.exe samples\Debugme\Win64\Debug\Debugme.rsm TWidget
```

Dumps the members (fields, methods, properties) the RSM reader resolves for a
class, with type id, resolved type name, field offset and name hash. Reach for
this when a class member is missing or mistyped in the Variables view. Note:
before the member dump it also prints a fixed block of type-id resolution
diagnostics (`SysUtils` imports around index 360-370, hash candidates for type
id `$2DD`) left over from the type-id decoding work.

#### TestRsmParser

Smoke-tests `DebuggerCore\RsmFileReader.pas` against a `.rsm` file. Prints the
globals, the user types, and every procedure discovered by the parser with its
local variables (name, RBP offset, type id, type hint).

```bat
DevTools\Win64\Debug\TestRsmParser.exe samples\Debugme\Win64\Debug\Debugme.rsm
```

Run this after changing `RsmFileReader.pas` to verify the parser still finds
the expected procedures and locals. With no argument it falls back to
`..\..\..\samples\Debugme\Win64\Debug\Debugme.rsm` relative to the executable.

#### PrebuildIdx

Builds the `.idx` symbol-index sidecars for a whole directory up front, so a
debug session never pays the cold build. `TRsmFile` caches its parsed index next
to the input and reloads it in 1-18 ms; without the sidecar it has to scan the
container (~520 ms for a 45 MB `.dcp`), on the thread the debugger is waiting
on. The RTL / third-party corpus never changes between builds, so its sidecars
can be built once, offline.

```bat
rem the whole Delphi DCP corpus (~620 files here), 2 files in flight
DevTools\Win64\Debug\PrebuildIdx.exe "C:\Users\Public\Documents\Embarcadero\Studio\23.0\Dcp\Win64" -j 2

rem prove a parser change kept the sidecar format byte-identical
DevTools\Win64\Debug\PrebuildIdx.exe X:\scratch\rsm -verify
```

| Flag | Meaning |
|---|---|
| `-r` | recurse into subdirectories |
| `-j N` | N files in flight (default 2). Each build already fans its scans across cores, so a large N oversubscribes and can be slower. |
| `-verify` | rebuild every sidecar and SHA-256-compare against the one that was there; exit code 1 on any mismatch |
| `-force` | rebuild even when the existing sidecar is fresh |

Freshness is mtime-only (`idx` mtime >= source mtime) and reader-independent, so
a sidecar built here is exactly the one the debugger would have built itself.
It does **not** help your own packages: they are recompiled constantly and their
sidecars are invalidated on every build. It also cannot make a stack frame show
a *name* - frame names come from TD32/MAP/JCL providers, which have no sidecar.

The tool probes the target directory for writability first, because
`SaveProcIndexToSidecar` swallows write failures: on a read-only directory the
debugger silently rebuilds the index forever.

### TD32 / CodeView symbols (embedded `.debug` section)

#### TestTD32Reader

```bat
DevTools\Win64\Debug\TestTD32Reader.exe samples\Debugme\Win64\Debug\Debugme.exe
```

Smoke test for `DebuggerCore\TD32FileReader.pas`: loads the `.debug` section,
parses the SOURCE_MODULE entries, reports the total line-pair count, prints the
first and last five RVA→source:line mappings and one reverse lookup. Run it
after changing the TD32 reader.

#### Td32LoadBench

```bat
DevTools\Win64\Debug\Td32LoadBench.exe <exe-or-bpl> [more paths...] [-n <iterations>]
```

What a TD32 load costs: per file, the number of names the container holds, the
mean wall time of a load, and the working set a loaded reader holds. Run it on
the SAME binaries before and after a change to the loader, so a claim about
memory or load time is a measurement rather than an argument. The numbers behind
the NAMES-table change are in `docs/TD32_FORMAT_NOTES.md`.

#### LiveSessionProbe

```bat
DevTools\Win64\Debug\LiveSessionProbe.exe ^
  "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\bds.exe" ^
  C:\Athens\qbflibraries\qbfdesign ^
  qbfDelphiMenu.pas:378,TemplateDsgnTableFrmU.pas:63 ^
  -seconds 3600 -eval Application
```

Drives a real `TDebugSession` against a long-lived HOST application and keeps it
running, so a human can trigger the breakpoints from the target's own UI while
the probe reports what the debugger saw. Written for the design-time-package
case, where the interesting stops cannot be provoked from a fixture: they need
somebody to open a form in the IDE.

On every stop it dumps the call stack, the locals and any `-eval` expressions,
then **continues**, so the target stays usable and the same breakpoint can fire
again. It also reports every breakpoint verification transition (`[bp] ...
verified=True`), which is the only way to see that a breakpoint in a package
bound LATER, when its module loaded.

`-script <file>` runs one command per line at each stop. Beyond `stack`,
`locals`, `frame`, `threads`, `step*`, `eval`, `set` and `expand`, two commands
exist to ask the runtime a question the static tables cannot answer:

| Command | What it shows |
|---|---|
| `rtti <expr>` | the runtime class of a value plus its RTTI properties and fields — the measurement that says whether RTTI carries INSTANTIATED generic types where dcc32's debug info carries only `%TList__1` |
| `imt <expr>` | every link of the interface→object chain (`IfacePtr` → IMT → adjustor thunk bytes), plus the `IsClassInstance` result the display path gates the concrete-class label on |

`imt` exists because "the interface shows no class" has four possible causes —
an unreadable link, an unrecognised thunk encoding, a gate that rejected the
value, or a stale build — and printing each link tells them apart instead of
leaving one guess per attempt.

#### ExceptionStopProbe

```bat
rem The ordinary Delphi raise path
DevTools\Win64\Debug\ExceptionStopProbe.exe ^
  DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe ^
  DebuggerTests\TestTarget -args "--run-deep-nested-raise" -frames 4

rem A hardware fault inside OS code (works against the Win32 build too)
DevTools\Win64\Debug\ExceptionStopProbe.exe ^
  DebuggerTests\TestTarget\Win32\Debug\NoSourceStop.exe ^
  DebuggerTests\TestTarget -args "-os"
```

Drives a real `TDebugSession` to the FIRST exception stop and prints, side by
side, the three answers a stop has to keep apart: the RAW walk (every frame the
engine produced), the REPORTED stack (after the raise-plumbing trim), the locals
served with no frame selected, and the locals of each of the first N frames when
one IS selected.

"The exception stopped on the wrong frame" and "the locals came from the wrong
frame" look identical from a failing assertion and have different causes; this
is the view that tells them apart. `-filters` takes the same wire names as the
launch config (`delphi,av,all,unhandled`; default `delphi,av,unhandled`).

Not a duplicate of `ExcHandlerProbe`: that one measures where an exception is
DISPATCHED to (scope tables, handler funclets, whether the trap flag survives
delivery), this one measures what the session REPORTS at the stop — the stack,
the default frame, and the locals each frame yields.

#### Td32AliasProbe

```bat
rem Are the named float aliases in the TYPES table? (default name list)
DevTools\Win64\Debug\Td32AliasProbe.exe DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe

rem What raw CV type id does each local of a routine actually carry?
DevTools\Win64\Debug\Td32AliasProbe.exe <exe> -proc ComputeNested
DevTools\Win64\Debug\Td32AliasProbe.exe <exe> -class TWidget

rem Same question asked of an RSM-format provider (.rsm or a package's .dcp)
DevTools\Win64\Debug\Td32AliasProbe.exe <file.dcp> -rsmproc ComputeNested
DevTools\Win64\Debug\Td32AliasProbe.exe <file.dcp> -rsmscan TDateTime 10
```

Answers "why does this variable report `Double` when it is declared
`TDateTime`?". Prints the raw TypeId next to the resolved name, so a flattened
alias (id `$0041`, no name record anywhere) is distinguishable from a decoding
gap. The `-rsm*` modes ask the same of `.rsm` / `.dcp` — use `-rsmscan` to FIND a
subject in a real package instead of guessing a routine name. Findings are
recorded in `docs/TD32_FORMAT_NOTES.md` → "Named float aliases are FLATTENED at the
variable".

#### Td32LineLookup

```bat
DevTools\Win64\Debug\Td32LineLookup.exe samples\Debugme\Win64\Debug\Debugme.exe Debugme.dpr 120
```

Resolves source file + line to the RVA(s) a breakpoint would bind at, from the
TD32 line table. First tool to reach for on "my breakpoint never binds".

#### DumpTd32Globals

```bat
DevTools\Win64\Debug\DumpTd32Globals.exe samples\Debugme\Win64\Debug\Debugme.exe [name-substring-filter]
```

Lists the global/unit-level symbols a module's TD32 debug info exposes;
answers "which module actually owns this global?".

#### CvProbe

```bat
DevTools\Win64\Debug\CvProbe.exe samples\Debugme\Win64\Debug\Debugme.exe
```

Probes a PE file's embedded CodeView debug section through the Windows
`DbgHelp.dll`: whether DbgHelp recognizes Delphi's CodeView output at all,
whether it resolves source/line for an RVA, and how many symbols it classifies
as functions / locals / parameters / register-relative / frame-relative. Reach
for this when evaluating whether DbgHelp could substitute for our own readers.
The probe RVAs are a fixed hand-picked set (`$1000`…`$40000`), so treat the
per-RVA lines as a sample, not a full scan.

#### DiffTD32RsmNames

```bat
DevTools\Win64\Debug\DiffTD32RsmNames.exe samples\Debugme\Win64\Debug\Debugme.exe
```

Takes the EXE path and reads the sibling `.rsm` implicitly. Diffs the procedure
names exposed by `TD32FileReader` against those keyed by the RSM reader's
procedure index, in both directions, and also dumps sample locals and globals.
Reach for this when locals resolve under one reader but not the other: any name
TD32 emits that RSM does not recognize fails the locals lookup downstream.

#### Td32ProcNesting

```bat
DevTools\Win64\Debug\Td32ProcNesting.exe samples\Debugme\Win64\Debug\Debugme.exe [name-substring]
```

Answers whether the TD32 symbol stream expresses nested (inner) procedures as a
lexical scope — an `LPROC32` / `GPROC32` opened while another proc scope is
still open — and/or through the CodeView `pParent` back-pointer. This is the
architecture-neutral alternative to the MAP-based mechanism, which recovers
nesting by correlating `_ZZ…$pdata$…` mangled exception publics and therefore
only works where the compiler emits `.pdata` (x64).

The probe asserts nothing: it walks every symbol stream keeping a scope stack
and reports, per procedure record, the depth, the enclosing procedure implied by
the stack, and the raw `pParent` field. With no filter it prints only the
aggregate counts. Works on PE32 and PE32+ images regardless of its own bitness —
nothing in the TD32 container is pointer-sized.

### MAP files

#### CompareMapTD32

```bat
DevTools\Win64\Debug\CompareMapTD32.exe samples\Debugme\Win64\Debug\Debugme.exe
```

Takes the EXE path and reads the sibling `.map` implicitly. Cross-validates
`TD32FileReader` against `MapFileReader` on the same image: for every RVA the
TD32 line table knows, it asks MAP the same forward and reverse question and
reports divergences, plus a function-name spot check. Reach for this when the
two readers disagree about where a line lives.

#### TestNested

Tests that the MAP file reader correctly identifies nested (inner) procedures
and resolves their enclosing parent.

```bat
DevTools\Win64\Debug\TestNested.exe samples\Debugme\Win64\Debug\Debugme.map
```

Reach for this when debugging step-in / step-out behaviour for nested
procedures. With no argument it falls back to `..\..\..\samples\Debugme\Win64\Debug\Debugme.map`
relative to the executable. Note: the inner-procedure names it probes are a
fixed list (`ThisIsALocalProcedure`, `Increment`, `Inner`, `NotANest`).

#### RvaLookup

```bat
DevTools\Win64\Debug\RvaLookup.exe samples\Debugme\Win64\Debug\Debugme.map samples\Debugme\Win64\Debug\Debugme.rsm 2CCA0 2CD10
```

Resolves a list of RVAs against a MAP + RSM pair, producing
`name+0xNN (Unit.pas:line)` for each. RVAs are accepted as hex (with or without
a `0x` / `$` prefix). Reach for this to interpret stack frames dumped by
WinDbg/cdb, which show Delphi binaries as huge offsets from the single
`_dbk_fcall_wrapper` export. The MAP is loaded at the preferred base
`$400000`, so pass RVAs, not runtime VAs.

#### MapSegBaseProbe

```bat
DevTools\Win64\Debug\MapSegBaseProbe.exe samples\Debugme\Win64\Debug\Debugme.exe samples\Debugme\Win64\Debug\Debugme.map [seg:offset ...]
```

Determines how a MAP's segment table must be converted into image RVAs, and
**verifies** the result against the PE section table: it reads however many hex
digits the `Start` column actually has (8 for PE32, 16 for PE32+), derives
`LinearStart − ImageBase`, then looks for a PE section whose `VirtualAddress`
equals that value and whose name equals the MAP's `Name` column. That identity
check is what makes the answer trustworthy on a platform whose constants are not
known in advance.

It also replays the old fixed-16-hex-digit parse, so the two can be compared
side by side. Reach for this when MAP-derived addresses are off by a constant,
or when adding support for a new image format.

#### MapLineRvaProbe

```bat
DevTools\Win64\Debug\MapLineRvaProbe.exe <image.exe|dll|bpl> <file.map> [maxSamples]
```

Checks `TMapFile`'s line ↔ RVA mapping against the PE section table, on a real
MAP of any size. The address of a `line SSSS:offset` record is the
`VirtualAddress` of the PE section named like segment SSSS plus the offset,
derived without `TMapFile`. The owner of every address comes from the MAP's
"Detailed map of segments". A record lying in another unit's code is a
**ghost**, which `TMapFile` drops.

What it checks:
- The first record of sections spread over the whole MAP (default 300, always
  including the farthest section of each segment) and every address carrying
  several records. `RvaToSourceLine` must return one of the real records there.
  For a single record, `SourceLineToRva(file, line)` must return an RVA that
  maps back to it.
- Every ghost address. `RvaToSourceLine` must not return the ghost.
- The first byte of every unit's code. `RvaToSourceLine` must return a real
  record at that very address, or nothing when there is none.

It also counts sections whose records are not in ascending address order,
which `TMapFile` relies on to bound a section by its first and last records.
Exit code: 0 = all agreed, 1 = a mismatch, 2 = bad input.

Like the adapter, `TMapFile` writes `<map>.idx` beside the MAP, so a second run
exercises the sidecar fast path. **Run it against a large real MAP after any
`MapFileReader` change.** Synthetic tests cannot build a `.text` past 4 MB, and
on the 139 MB Hydra2 MAP this probe found three defects that every synthetic
test and the whole suite had passed (see `docs/TRAPS.md`).

### PE / raw binary

#### DumpFunc

Dumps N bytes of machine code from a PE file at a given RVA, after printing the
section table and the RVA→file-offset translation. Useful for manual
disassembly of a specific function's prologue/epilogue.

```bat
DevTools\Win64\Debug\DumpFunc.exe samples\Debugme\Win64\Debug\Debugme.exe 2CCA0 64
```

Arguments: `<exe-path> <hex-RVA> <byte-count>`.

#### DisasmProbe

```bat
DevTools\Win64\Debug\DisasmProbe.exe DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe 167FC0 10
DevTools\Win64\Debug\DisasmProbe.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe F4E78 10
```

Proves the Zydis dependency end to end (`docs/DISASSEMBLY_PLAN.md` increment 1):
loads `ThirdParty\Zydis\bin\x64\Zydis.dll`, reads real bytes out of a real PE
image at a given RVA, and decodes a run of instructions through
`DebuggerCore\ZydisApi.pas`. No feature lives here — `IDisassembler` and
symbolication are increment 2; this only shows the pipeline decodes.

Arguments: `<exe-or-dll> <hex-RVA> [count] [-mode long64|legacy32] [-zydisdll <path>]`.
`count` defaults to 10 instructions. The machine mode is read from the image's
own PE header (`IMAGE_FILE_HEADER.Machine`) unless `-mode` overrides it —
never assumed from the host, matching how the real `IDisassembler` will derive
it from `IDebugTarget.TargetLayout`. `Zydis.dll` is located via the normal
Windows search order (next to this exe, then `PATH`); if that fails, the probe
falls back to the repo-relative `ThirdParty\Zydis\bin\x64\Zydis.dll` so a fresh
build works without copying anything, unless `-zydisdll` gives an explicit
path.

Run once against the 64-bit `TestTarget.exe` and once against its 32-bit
sibling (each auto-detects its own mode) to see the SAME x64 `Zydis.dll`
decode both machine modes — the case that matters for this project, since the
adapter is one 64-bit process debugging either bitness. Measured output at the
two binaries' entry points, both showing the standard Delphi prologue:

```
$00167FC0  55                        push rbp
$00167FC1  53                        push rbx
$00167FC2  48 81 EC 98 00 00 00      sub rsp, 0x98
$00167FC9  48 8B EC                  mov rbp, rsp
```

```
$000F4E78  55                        push ebp
$000F4E79  8B EC                     mov ebp, esp
$000F4E7B  83 C4 C8                  add esp, 0xFFFFFFC8
$000F4E7F  53                        push ebx
```

#### Disasm

```bat
rem static mode: decode straight out of a PE file at an RVA, no live process
DevTools\Win64\Debug\Disasm.exe DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe 167FC0 12
DevTools\Win64\Debug\Disasm.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe F4E78 12

rem live mode: launch through a real TDebugSession, break at a source marker,
rem disassemble from the stop PC through IDebugTarget.ReadCodeMemoryAt
DevTools\Win64\Debug\Disasm.exe -live ^
  DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe ^
  DebuggerTests\TestTarget\Win64\Debug\TestTarget.map ^
  DebuggerTests\TestTarget\Win64\Debug\TestTarget.rsm ^
  DebuggerTests\TestTarget TestTargetCore.pas EVAL_BODY 12
```

Exercises the real feature (`docs/DISASSEMBLY_PLAN.md` increment 2): the
`IDisassembler` seam (`DebuggerCore\Disassembler.pas`), the Zydis backend
behind it (`DebuggerCore\ZydisDisassembler.pas` — the only unit besides
`ZydisApi.pas` itself allowed to reference Zydis), and symbolication of the
output through the SAME provider set (`TDebugInfoSet`: MAP + RSM + TD32) the
adapter queries when naming a stack frame. `DisasmProbe` (above) only proves
the raw Zydis pipeline decodes bytes; this tool proves the actual feature,
including the two live-session traps the plan calls out:

- **Planted breakpoints don't corrupt the view.** Live mode prints the raw
  byte at the stop PC (via `ReadProcessMemoryAt`, which shows the debugger's
  own `$CC`) next to the same byte through `ReadCodeMemoryAt` (what the
  disassembler is actually fed), so the fix is visible in the tool's own
  output, not just asserted.
- **A window near the end of a section truncates, not fails.** Static mode
  clamps the file read at EOF; live mode clamps at the `VirtualQueryEx`
  region boundary inside `ReadCodeMemoryAt` — neither raises past that edge.

Static-mode arguments: `<exe-or-dll> <hexRVA> [count] [-zydisdll <path>]`.
Symbolication is best-effort from the file's sibling `.rsm`/`.map` (loaded in
the same RSM-then-TD32-primary-then-MAP order `ModuleSymbolLoader` uses for a
main exe); missing sidecars just mean no symbolication, not an error.

Live-mode arguments: `-live <exe> <map> <rsm> <sourceRoot> <sourceBaseName>
<marker> [count] [-args <targetArgs>] [-zydisdll <path>]`, where `<marker>` is
the text inside a `{BP:...}` tag in the source file (same convention as
`Win32SessionProbe`). Symbolication uses the session's OWN `TDebugInfoSet`
(multi-module aware), and machine mode comes from
`IDebugTarget.TargetLayout.PointerSize` — never assumed from the host.

A direct `call`/`jmp`/`jcc` with a resolvable static target gets an inline `;
Name+offset` comment appended to its `Text`; an unresolvable one keeps the
bare address Zydis printed, matching the plan's "a call into a module with
symbols shows a name and one without shows an address". The match is a CLOSED
whitelist of the actual Zydis control-transfer mnemonics, not a bare
`<word> 0x<hex>` pattern — measured during development that a plain `push
0x2A` formats identically to a direct branch and would otherwise be
mislabelled as a resolved call target.

#### DisasmCoverage

```bat
rem drives the Visual Studio toolset first so dumpbin.exe is found without -dumpbin
DevTools\run_disasm_coverage.bat <module1> [<module2> ...] [-maxspan N] [-sample N] [-maxdivs N]

rem examples
DevTools\run_disasm_coverage.bat DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe
DevTools\run_disasm_coverage.bat "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rtl290.bpl"
DevTools\run_disasm_coverage.bat C:\Athens\hydra_2\Win32\Debug\Hydra2SingleEXE.exe -sample 3
```

Differential coverage sweep (`docs/DISASSEMBLY_PLAN.md` increment 3): feeds the
SAME bytes to Zydis (via the real `IDisassembler`/`TZydisDisassembler`
production backend) and to an INDEPENDENT oracle — dumpbin `/DISASM:BYTES`
from the Visual Studio 2026 MSVC toolset — over real compiled binaries, and
reports every case where the two decoders disagree about WHAT AN
INSTRUCTION IS, not just formatting. This is the tool `X86DecodeProbe`
already validates instruction LENGTHS against ground truth without any
second decoder; `DisasmCoverage` is the equivalent check for Zydis's actual
mnemonic identity, against a genuinely independent implementation.

**Why dumpbin, not XED.** XED (`intelxed/xed`), the plan's other named
candidate, is not installed on this machine and building it needs a
Python + `mbuild` toolchain this project does not otherwise depend on.
dumpbin ships with Visual Studio, is already used elsewhere in this repo
(`dumpbin /exports`), and is reachable from a `.bat` via `VsDevCmd.bat` —
`run_disasm_coverage.bat` does exactly that so `dumpbin.exe` is on `PATH`
before `DisasmCoverage.exe` runs (pass `-dumpbin <path>` to override,
or invoke `DisasmCoverage.exe` directly if `dumpbin.exe` is already on
`PATH`).

**Why not a blind whole-image dumpbin run.** `dumpbin /DISASM` disassembles
an entire section LINEARLY with no notion of instruction boundaries beyond
its own decode. Delphi binaries embed real DATA directly inside `.text`
(RTTI/typeinfo string literals, jump tables, exception-handler tables), so a
blind run walks into that data, decodes garbage, and its address cursor
desyncs from real code PERMANENTLY — nothing tells it where to resync. The
tool instead anchors every span it feeds to BOTH decoders at a KNOWN
instruction boundary:

- **Line-verified spans**, when the module carries embedded TD32 debug
  info: every line-table RVA is a proven boundary (the compiler emitted a
  source line for it), so consecutive RVAs within one routine bound a span
  whose START and END are both real code. Highest confidence — this is the
  SAME anchor set `X86DecodeProbe` already uses.
- **Export-anchored spans**, when the module has NO debug info at all (the
  shipped RTL/VCL runtime packages, `rtl290.bpl`/`vcl290.bpl`): a PE export
  is a proven function START, but the END is NOT verified — capped at the
  next export or `-maxspan` bytes (default 256), whichever is smaller, so
  the window may still run into data before either decoder would stop on
  its own. Reported as its own row, lower confidence, never conflated with
  line-verified spans.

Every selected span's bytes are copied verbatim out of the real module and
concatenated into ONE synthetic in-memory buffer, each span followed by 20
bytes of `$CC` (`INT3`). `$CC` as the FIRST byte of any decode attempt is
unconditionally a 1-byte instruction in both engines — there is no
multi-byte opcode beginning with `$CC` — so a run more than the 15-byte
legal x86/x64 instruction-length ceiling guarantees both decoders
resynchronise to the same address by the next span's start, regardless of
how far either one drifted decoding the span itself. The buffer is wrapped
in a minimal hand-built PE (DOS header, one `.text` section) so dumpbin has
something to load; addresses in that file are therefore synthetic — only
mnemonic identity and instruction LENGTH are ever compared, never the
resolved operand address.

**Divergence classes**, printed with the real module RVA (not the synthetic
address) so a hit can be inspected with `DumpFunc.exe`:

| class | meaning |
|---|---|
| `boundary` | at a Zydis instruction's own address, dumpbin has no instruction starting there at all — its own walk disagreed with Zydis's on an EARLIER instruction's length within this span |
| `length` | both start at the same address but disagree on how many bytes the instruction occupies |
| `refusal` | one decoder produced a mnemonic, the other refused (Zydis `db XX` / dumpbin's bytes-only line with no mnemonic) |
| `mnemonic` | both decoded the SAME length but named it differently after alias normalisation |

Formatting differences are normalised away BEFORE counting a mnemonic
divergence — condition-code synonyms (`sete`/`setz`), the string-op family
(`stosq`/`stos qword ptr [rdi]`), `sal`/`shl` (genuinely the same opcode),
x87 duplicate-encoding digit suffixes (`fcomp3`/`fcomp5`/`fcomp`), legacy
8087/80287 no-op opcodes (`feni8087_nop`/`feni`), `int3`/`int 3`,
`ret far`/`retf`, and a few more — every entry built from a REAL measured
divergence, documented with that example at its definition in
`DisasmCoverage.dpr`, never guessed ahead of evidence.

**dumpbin is driven through a FILE, never an in-process pipe capture.** A
full sweep of a 500+ MB binary makes dumpbin emit gigabytes of text; the
first implementation captured its stdout through a pipe into one Delphi
string and failed outright at that scale (`EEncodingError: Invalid count
(-1158168115)`, an overflowed string length). `RunToFile` redirects
dumpbin's stdout straight to a temp file via `CreateProcess`, and
`ParseDumpbinFile` streams it back with `TStreamReader` one line at a time —
no in-memory ceiling.

Arguments: `-maxspan N` caps an export-anchored span's window (default 256
bytes). `-sample N` keeps every Nth span (default 1: full sweep — sampling
is an explicit opt-in, never a silent cap; the summary line always states
`full sweep: N spans (no sampling)` or `SAMPLED: N of M spans (every Kth
span, X% of total)`). `-maxdivs N` caps how many divergences of EACH class
are printed (default 25; the summary counts and percentages are never
capped, only the listing). `-dumpbin <path>` / `-zydisdll <path>` override
the normal search order.

**Measured baseline (2026-08-08), full detail and classification of every
divergence in `docs/DISASSEMBLY_PLAN.md` "Verified in increment 3 — Half B":**

| binary | bitness | methodology | spans | positions compared | clean spans | boundary | length | refusal | mnemonic |
|---|---|---|---|---|---|---|---|---|---|
| `TestTarget.exe` | x64 | line-verified, full | 1 303 | 7 812 | 100.00% | 0 | 0 | 0 | 0 |
| `TestTarget.exe` | x86 | line-verified, full | 1 253 | 8 248 | 99.92% | 0 | 0 | 1 | 0 |
| `TestSubject.bpl` | x64 | line-verified, full | 1 276 | 7 509 | 99.84% | 0 | 2 | 0 | 0 |
| `TestSubject.bpl` | x86 | line-verified, full | 1 233 | 8 190 | 100.00% | 0 | 0 | 0 | 0 |
| `rtl290.bpl` | x86 | export-anchored, full | 49 564 | 1 535 973 | 81.22% | 0 | 8 902 | 396 | 0 |
| `vcl290.bpl` | x86 | export-anchored, full | 13 922 | 503 753 | 90.18% | 0 | 1 262 | 384 | 0 |
| `Hydra2SingleEXE.exe` (505 MB) | x86 | line-verified, 33% sample | 792 554 / 2 377 660 | 5 294 297 | 99.98% | 0 | 76 | 101 | 0 |
| `Hydra2SingleEXE.exe` (582 MB) | x64 | line-verified, 33% sample | 803 805 / 2 411 415 | 5 807 612 | 99.99% | 0 | 66 | 7 | 0 |

**13 173 394 instruction positions compared, zero mnemonic-identity
divergences**, after normalisation converged. Every `length` divergence
manually inspected is data in the code stream (an inline exception-handler
table on the Delphi fixtures; RTTI name-string literals past a short
exported RTL routine's real end); every `refusal` is Zydis correctly naming
an undocumented legacy opcode (`$D6` SALC, `$F1` INT1/ICEBP) dumpbin's own
table does not know at all. A single UNSAMPLED full sweep of
`Hydra2SingleEXE.exe` x86 (2 377 660 spans) also surfaced 478 083 `boundary`
divergences that vanish entirely at the 33% sample — traced to dumpbin
itself silently omitting output beyond an internal capacity threshold on
the ~100+ MB synthetic image the full sweep produces, not a Zydis defect;
full write-up in `docs/DISASSEMBLY_PLAN.md`.

**To reproduce or extend this baseline**: rebuild `DevTools` (`build_all.bat`
already includes `DisasmCoverage`), then re-run the invocations above and
compare against this table — a change that adds a real Zydis gap should show
up as a NEW `mnemonic` divergence; a change to the normalisation table
should be justified by a measured example the same way every entry above is.

#### LineSiteSurvey

```bat
DevTools\Win64\Debug\LineSiteSurvey.exe <exe-or-bpl> [-out <dir>] [-src <dir>]... [-compare <other>] [-sample N] [-maxlist N] [-zydisdll <path>]

rem examples
DevTools\Win64\Debug\LineSiteSurvey.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe -out %TEMP%\lss
DevTools\Win64\Debug\LineSiteSurvey.exe DebuggerTests\TestHost\Win64\Debug\TestSubject.bpl -compare DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe
```

Static survey of the places a line probe could go: the static half of
"Increment 0" of `docs/PROFILER_COVERAGE_PLAN.md` (assumptions 1, 8, 9, 17 and
18). The binary is read as a file and never executed. A 64-bit tool that
analyses both bitnesses; the Zydis machine mode comes from the PE header.

The line table and the procedure ranges come from `TTD32FileReader`, so the
numbers describe what the engine sees. Everything else is read from the PE
file: sections, base relocations, imports (delay-load included), `.pdata` and
the Delphi scope and clause tables behind `_DelphiExceptionHandler`.

**How a record is confirmed.** Never by decoding FROM it: x86 decoding falls
back into step within a few instructions, so a record in the middle of an
instruction would pass. Each routine is decoded by following control flow from
proven places, added in stages so the report can say what each source buys:

| stage | proven places |
|---|---|
| 0 | the routine entry, direct branch targets, in-routine call targets |
| 1 | x64: `.pdata` function starts, scope-table targets (finally funclets, bare `except` blocks), clause-table blocks |
| 2 | entries of recognised jump tables |
| 3 | x86: handler stubs named by a `push imm32`, the code or the clause table behind a stub, the continuation a `try..finally` pushes |

A record is confirmed when such a decode arrives exactly at it. An unconfirmed
record is listed with its reason: inside an instruction the proven decode
reached, inside a table, or unreached after a `ret` / `jmp` / indirect jump.

**Sections of the report** (the summary goes to stdout; `-out` adds one listing
per section, capped by `-maxlist`):

| # | content |
|---|---|
| 1 | records, distinct (file, line), routines, source files |
| 2 | records outside every TD32 procedure range and what they are; on x64 where finally funclets, `except` blocks and clause tables sit relative to the TD32 range of their procedure |
| 3 | records confirmed after each stage; the unconfirmed ones by reason |
| 4 | records that point into a recognised jump table or clause table; on x86 the handler stubs by RTL handler |
| 5 | source lines with more than one record in one routine, by the first token of the source line when the source is found (`-src`, or next to the binary) |
| 6 | code length per record, return addresses, x64 unwinder windows, and the probe form each record and each routine exit could take |
| 7 | every indirect jump by shape, with the instructions before it and the table after it |
| 8 | `-compare`: per shared source file, the lines only one of the two binaries names, and whether their routine exists in the other |

Section 6 follows the plan's rules literally (retargeted direct call in the
line's first straight-line block, then a five-byte jump, then the call form,
else a `$CC`) and prints a second column for "a span may contain later line
starts", which is what merged spans would buy.

**Simplifications**, all of them also in the source header:

- only routines owning a line record are decoded, so an indirect jump in code
  with no line record is never seen;
- a procedure range is assumed contiguous; its end is found by bisection on
  `RvaToFunctionStart`;
- every call is assumed to return, except a call to `System.@Halt0`;
- an instruction is relocatable unless it is `int3` / `int n`;
- an indirect jump that is neither an import thunk, a recognised table nor the
  x86 finally exit makes its routine "incomplete", as the plan says;
- the x64 window of a return address is an optional `add rsp` / `lea rsp`, any
  number of `pop`, and the one instruction after them;
- rule 5 of the jump rule (breakpoints, thread positions) and flags liveness are
  dynamic and not modelled;
- the reader keeps ONE line per distinct RVA and identifies a source file by
  base name, so the raw number of line pairs is not available.

**Baseline (2026-11-26, Delphi 12 Athens, compiler 36.0).** Full passes, no
sampling; the 500 MB images take about 21 s each.

| module | records | routines | outside every range | unconfirmed | retargeted call | jump | call form | left to `$CC` | exits: jump / call form / `$CC` |
|---|---|---|---|---|---|---|---|---|---|
| `TestTarget.exe` x64 | 1 904 | 301 | 28 | 0 | 39.98 % | 50.43 % | 6.50 % | 3.09 % | 59.47 / 40.53 / 0.00 % |
| `TestTarget.exe` x86 | 1 974 | 425 | 32 | 4 | 33.68 % | 57.31 % | — | 8.81 % | 69.10 / — / 30.90 % |
| `TestSubject.bpl` x64 | 1 863 | 300 | 29 | 0 | 40.68 % | 49.78 % | 6.54 % | 3.00 % | 59.67 / 40.33 / 0.00 % |
| `TestSubject.bpl` x86 | 1 953 | 440 | 28 | 4 | 34.08 % | 56.99 % | — | 8.73 % | 69.77 / — / 30.23 % |
| `Hydra2SingleEXE.exe` x64 (620 MB) | 2 880 014 | 411 229 | 14 468 | 2 203 | 41.52 % | 48.94 % | 5.57 % | 3.89 % | 54.49 / 44.08 / 1.43 % |
| `Hydra2SingleEXE.exe` x86 (530 MB) | 2 791 210 | 398 810 | 14 740 | 22 549 | 37.07 % | 51.99 % | — | 10.13 % | 55.41 / — / 44.59 % |

The form shares are of the records inside TD32 procedure ranges.

What the first runs established, and what to look for when a number moves:

- **dcc32 leaves a finally block with `pop eax; jmp eax`, not `ret`.** The
  handler stub follows it directly. It is an indirect jump in every routine
  with a `try..finally`, explicit or implicit (123 008 in the x86 Hydra image),
  so a routine analysis that treats every unrecognised indirect jump as a break
  loses a fifth of the routines. The tool recognises the shape; `x86 finally
  exit` in section 7 counts it.
- **dcc64 emits no jump tables.** The only table found in 21.4 million decoded
  instructions is hand-written assembly (`System._FillChar`). dcc32 emits two
  forms, both of absolute relocated addresses: `jmp [reg*4+T]` with `T` right
  after the jump, and the same with a byte index table between the jump and
  `T`, loaded by `mov reg8, [reg+idx]` or `movzx reg, byte ptr [reg+idx]`.
- **Anonymous-method bodies have no TD32 procedure record** on either bitness
  (the MAP names them `...$ActRec.$0$Body`; `Td32ProcNesting` finds no proc
  record). On x64 they are reachable through `.pdata`; on x86 nothing proves
  their entry.
- A TD32 procedure range holds more than code: about a fifth of its bytes are
  never reached by a decode (string literals, padding, tables), and on x86 a
  `push imm32` of such a literal looks like the push of a handler stub. Only
  an address whose bytes are a `jmp` out of the routine is taken for a stub.
- The unconfirmed records are real: line records of generic instantiations
  that land inside an instruction, dead code behind a `raise` compiled as a
  jump, `System.Character.inc`'s `bin_data` (a procedure whose body is data,
  1 579 records), and on x86 the static functions of linked C objects, which
  share one TD32 range with the public symbol in front of them.

#### RoutineAnalysisSweep

```bat
DevTools\Win64\Debug\RoutineAnalysisSweep.exe <exe-or-bpl> [-all] [-out <dir>] [-maxlist N] [-routine <name>] [-without <rules>] [-decodebench] [-zydisdll <path>]

rem examples
DevTools\Win64\Debug\RoutineAnalysisSweep.exe DebuggerTests\TestTarget\Win32\Debug\AnalysisSample.exe -routine IndexedCase
DevTools\Win64\Debug\RoutineAnalysisSweep.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe -without finally
```

Runs the routine analysis (`DebuggerCore\RoutineAnalysis.pas`,
`docs/PROFILER_COVERAGE_PLAN.md` increment 4) over a whole binary and prints
what it found. Static: the binary is read as a file through `TPeImageFile` and
never executed. A 64-bit tool for both bitnesses. The code map comes from the
binary's TD32, so the numbers describe what the engine would see.

For the routines of the code map, then for the x64 functions only `.pdata`
knows (anonymous-method bodies), then for the records in neither:

- line records **confirmed** as an instruction boundary, shown to be **not
  code**, and **unconfirmed**, each with its reasons;
- ranges **not analysed completely**, by reason, and the records they hold;
- bytes that are proven instructions, tables, never reached;
- what ends the first straight-line block of each confirmed record;
- call sites; exits by kind; the `ret`s and jumps that are NOT exits (x86
  finally exits and handler stubs, x64 funclet returns);
- **indirect jumps by kind**: through a fixed slot (an import or another slot),
  through a recognised table (entries, byte-index form, directly after the
  jump), the x86 finally exit, unexplained;
- exception-handler entries by kind, x86 stubs by RTL handler, clause tables;
- the time: TD32 load, code map, analyzer set-up, **analysis**, checks.

Probe forms are not its job; `LineSiteSurvey` has those.

**It is also the analysis' consistency check.** For every analysed range it
asserts that no two decoded instructions overlap (each boundary is followed by
exactly the interior bytes of an instruction whose length a second decode
reports, and no analysed range overlaps another), that confirmed records and
boundary bytes are the same set, and that a "not code" record is on an interior
byte, a table byte, or an unreached zero or undecodable byte. A violation is
printed and the exit code is 1.

| option | effect |
|---|---|
| `-all` | analyse every routine of the code map, not only the ones that own a line record |
| `-out <dir>` | detail listings: the records that are not confirmed, the ranges not analysed completely, and (x64) the functions inside a routine range that are not funclets |
| `-routine <name>` | print the analysis of the routines of that name byte by byte: instructions with their flags, line records with verdict and block, call sites and windows, tables, handler entries, exits. `.pdata` prints the functions known from `.pdata` only |
| `-without <rules>` | switch off sources of proven places, comma separated, to see what each buys: `noreturn`, `tables`, `finally` (x86), `stubs` (x86), `ehtables` (x64) |
| `-decodebench` | also time the decoder alone over the instructions the analysis decoded |

**Baseline (2026-11-27, Delphi 12 Athens, compiler 36.0).** Every routine that
owns a line record; "ranges" adds the x64 `.pdata`-only functions after the
plus sign. The three verdict columns cover ALL line records of the module.

| module | ranges | instructions | records | confirmed | not code | unconfirmed | not completed | analysis |
|---|---|---|---|---|---|---|---|---|
| `AnalysisSample.exe` x64 | 17 + 1 | 557 | 130 | 127 | 1 | 2 | 0 | — |
| `AnalysisSample.exe` x86 | 17 | 469 | 123 | 117 | 1 | 5 | 0 | — |
| `TestTarget.exe` x64 | 301 + 10 | 12 464 | 1 904 | 1 904 | 0 | 0 | 0 | 2 ms |
| `TestTarget.exe` x86 | 425 | 15 602 | 1 974 | 1 938 | 4 | 32 | 0 | 2 ms |
| `TestSubject.bpl` x64 | 300 + 10 | 12 160 | 1 863 | 1 862 | 1 | 0 | 0 | 2 ms |
| `TestSubject.bpl` x86 | 440 | 15 701 | 1 953 | 1 921 | 0 | 32 | 0 | 2 ms |
| `Hydra2SingleEXE.exe` x64 (620 MB) | 411 229 + 2 723 | 21 568 704 | 2 880 014 | 2 876 724 (99.89 %) | 1 182 | 2 108 | 27 (51 records) | 3.1 s |
| `Hydra2SingleEXE.exe` x86 (530 MB) | 398 810 | 18 934 941 | 2 791 210 | 2 753 921 (98.66 %) | 2 607 | 34 682 | 14 (608 records) | 2.6 s |

The analysis costs 140 to 145 ns an instruction on the large images, of which
the decoder alone is 75 to 90 (`-decodebench`); loading the TD32 of the same
image takes 5 s. Inside the routines of the code map the share confirmed is
99.92 % (x64) and 99.19 % (x86), as `LineSiteSurvey` measured.

Indirect jumps on the large images: x64 1 279 — 1 251 through a fixed slot,
one table (hand-written, `System._FillChar`), 27 unexplained; x86 127 875 —
1 222 through a fixed slot, 3 628 tables (59 050 entries; 2 719 directly after
the jump, 839 with a byte index table), 123 008 finally exits, 17 unexplained.
The routines left incomplete are hand-written assembly that jumps through a
register: on x86 RTL routines (`@System@@CallDynaInst`,
`@System@@HandleAnyException`, `@System@@LStrCatN`, `TObject.Dispatch`), on x64
the delay-load helper stubs (`user32_dll`, `kernel32_dll`, …: `pop; pop; pop;
jmp rax`), `_ExitDllLongJump` and one event thunk.

**What each rule buys** (`-without`, `TestTarget.exe`): without `finally`, 87
of the 425 x86 routines are not completed; without `stubs` the confirmed x86
records fall from 1 938 to 1 798; without `ehtables` the x64 ones from 1 876 to
1 767; without `noreturn` the x86 main block decodes two instructions into
data and stops on a byte that is not one.

**Reconciled with `LineSiteSurvey`**, which is the prototype this analysis was
built from. On all eight binaries the two agree to the record on what matters:
ranges analysed, instructions decoded in them, proven / table / unreached
bytes, records confirmed, tables and their entries, finally exits, stubs by
handler, continuations, return-address records. They differ here, and only
here:

| | `LineSiteSurvey` | `RoutineAnalysisSweep` | why |
|---|---|---|---|
| unconfirmed records | one state (x64 2 203, x86 22 549 inside routines) | two: not code (669 / 1 618) and unconfirmed (1 534 / 20 931) | an unreached record whose own byte is zero (216 / 224) or whose bytes are no instruction (322 / 206) is shown to be data; the survey filed them under "follows a ret / jmp" |
| x64 `.pdata`-only functions | 3 315 ranges, 146 252 instructions | 2 723 ranges, 155 649 instructions | the survey analysed each `.pdata` function that holds a record from its own start; the analysis takes a function TOGETHER with the funclets that follow it (1 343), whether they hold a record or not. Same 13 388 records, same 13 381 confirmed |
| records in no routine and no `.pdata` function | x64 392 zero / 486 data / 202 code; x86 923 / 187 / 13 630 | x64 466 zero byte / 47 undecodable / 567 unconfirmed; x86 968 / 21 / 13 751 | the survey guessed: two zero bytes, or a linear decode of up to 48 instructions that fails. The analysis calls a record "not code" only on its own bytes — one zero byte (the 0.9.3 rule) or no instruction — because a later step refuses breakpoints on that verdict |
| x86 ranges not completed | 22 | 14 | seven are `jmp [slot]` through a slot that is not an import: an exit through a pointer, not a break. One is a pushed address whose five bytes cross the routine's end: the survey took it for a stub ("unnamed target") and then reported an instruction crossing the end; a stub must fit in its routine, so it is data (pushed data 57 202 against 57 201, stubs 130 435 against 130 436) |
| jumps through an import slot | x64 1 251, x86 1 215 | "fixed slot" 1 251 / 1 222, of which an import 1 247 / 1 211 | the survey also reads the delay-load directory (4 on each); the analysis needs no import table for this rule — any fixed slot outside the routine is an exit — and the tool names only ordinary imports |
| routine exits | x64 411 250, x86 404 557 | 411 259, 404 594 | conditional jumps out of the routine (9 / 37) are exits here and were listed apart there |
| x64 records inside a window | 721 749 | 721 746 | the stack-adjust test is exact (`48 83/81 C4`, `48`/`49 8D` with `rsp` as destination); the survey accepted any REX.W prefix |
| block ending in a direct call / "retargeted call" | 1 189 903, 1 029 191 | 1 189 928, 1 029 233 | the survey's is a probe form: a five-byte call in a completed routine. The sweep reports what ends the block |
| handler entries | over every `.pdata` entry of the image | over the routines that own a line record | — |

One difference was a defect of the first version of the analysis, found by this
reconciliation: 289 x64 `ret`s were counted as routine exits. They are in the
handler funclets of `safecall` routines, which a scope entry names with
`Handler` = 1 (`docs/EH_FORMAT_NOTES.md`); the funclet rule now covers them and
the exits agree.

#### BreakpointPlanProbe

```bat
DevTools\Win64\Debug\BreakpointPlanProbe.exe <exe-or-bpl> [-map <file.map>] [-zydis <Zydis.dll>] [-line <source file>:<line>]... [-notcode] [-lastlines [-listlast] [-src <dir>]...]

rem examples
DevTools\Win64\Debug\BreakpointPlanProbe.exe DebuggerTests\TestTarget\Win64\Debug\BreakpointSample.exe -line BreakpointSample.dpr:56
DevTools\Win64\Debug\BreakpointPlanProbe.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe -map DebuggerTests\TestTarget\Win32\Debug\TestTarget.map -notcode
DevTools\Win64\Debug\BreakpointPlanProbe.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe -map DebuggerTests\TestTarget\Win32\Debug\TestTarget.map -lastlines -src DebuggerTests\TestTarget
```

Answers, for one binary read as a FILE (nothing is launched), the two
questions the engine asks before it plants a source breakpoint
(`docs/DAP_DEBUGGER_ARCHITECTURE.md`, "Breakpoints") — through
`DebuggerCore\LiveCodeAnalysis.pas`, the class a session uses for a live
process, so the answers and the timings are the session's.

- **What the first breakpoint in the module costs.** The first question builds
  the code map and the analyzer; the tool prints that time, its two parts, the
  growth of the process's private bytes, and what the same address costs when
  asked again. The time to load the debug information is printed apart: a
  session pays it at start, breakpoint or not. With `-map` the MAP is loaded
  as the session loads one that lies beside the binary, and on a 32-bit image
  it becomes the second routine provider of the code map. The tool waits for
  the MAP's background index before asking; a session never does.
- **`-line <file>:<n>`**: every line record of the line, the routine and (x64)
  the piece of it each is in — `body` or `FUNCLET` — the verdict of the
  routine analysis, and which of them get a breakpoint: `BP` for the address a
  line-table provider answers with, `COPY` for a record in another piece of
  the same routine.
- **`-notcode`**: the source lines that have a record the analysis shows NOT to
  be the start of an instruction, with the reason. A breakpoint on such a
  record is refused. Analyses every routine: seconds on a large image.
- **`-lastlines`**: the evidence for the rule that calls a record "the unit's
  final `end.`" (`TRoutineAnalyzer.IsFinalEndOfUnit`). Of the records outside
  every routine it counts those on the last line of their file (and, on x64,
  those of them inside a `.pdata` function), then those the rule takes -- the
  ones in the own file of their unit -- each split by what the bytes are: a
  zero byte, no instruction, bytes that decode. A record on the last line of
  its file that the rule does NOT take is printed with the unit it belongs to.
  With `-src <dir>` (repeatable, searched recursively by file name) the source
  line of every record taken is read and compared with `end.`; the ones that
  say something else are printed. A source newer than the binary gives a false
  "something else": the line number is the old file's last line. `-listlast`
  adds, per record taken, the distance to the routine below it and whose unit
  that routine is.
- `-map` must name a file that exists: a `TMapFile` over a missing file reports
  its index as pending for ever, and the tool would only wait.

`-zydis` defaults to the DLL beside the tool, else the repository's
`ThirdParty\Zydis\bin\x64` copy.

Measured 2026-11-27 on a 620 MB x64 and a 530 MB x86 image: first verdict 485
and 438 ms (code map 425 and 413, analyzer 60 and 24), 103 and 88 MB; with the
x86 image's 145 MB MAP 648 ms, 2 694 routines taken from it. `-notcode`: 1 182
and 2 607 records, the same 2 607 with and without the MAP.

#### CodeMapDump

Builds the code map of one binary from its TD32 (`DebuggerCore\CodeMap.pas`,
`TModuleCodeMap`) and prints what it holds: routines, line records, the records
that lie outside every routine range, files, units, the time the build took and
the memory the map keeps. Static: the binary is read as a file and never run.

```powershell
DevTools\Win64\Debug\CodeMapDump.exe <exe-or-bpl> [-tds <file.tds>] [-shift <hex>]
                                     [-lines <source file>] [-routine <name>]
```

- `-lines <source file>` lists the line records of one source file, `-routine
  <name>` those of one routine.
- `-shift <hex>` loads the reader with that RVA shift, as a runtime module of a
  session is loaded; the map must come out the same, which is what makes it
  comparable across runs.

Baseline, 2026-11-27 (records outside every routine in brackets): the x64
fixture executable 1 904 line records [28], the x86 one 1 974 [32]; a 620 MB
x64 image 2 880 014 [14 468], built in 0.43 s after a 5.2 s TD32 load, 90 MB of
tables. The bracketed numbers are the ones `LineSiteSurvey` reports for the
same binaries.

#### HexDump

```bat
DevTools\Win64\Debug\HexDump.exe samples\Debugme\Win64\Debug\Debugme.rsm 1A40 128
```

Hex + ASCII dump of any file. Arguments: `<file> <hex-offset> <byte-count>`.
Reach for this to read the bytes around an offset another tool reported.

#### FindBytes

```bat
DevTools\Win64\Debug\FindBytes.exe samples\Debugme\Win64\Debug\Debugme.rsm 6328 20
```

Scans any binary for a hex byte pattern and lists every hit offset; the
optional third argument caps the number of hits reported.

#### PrologProbe

Self-contained prologue-shape probe. It contains deliberately shaped routines
(parameterless, eight integer parameters, large local array, high register
pressure, method with hidden `Self`, nested procedure, `try/finally`,
`try/except`, managed and record results) and dumps the first 32 bytes at each
routine's own entry address together with a decode.

It also *measures* four frames at run time: each measured routine records the
address of one of its own locals, the value of `ReturnAddress` and the address
of every parameter, then locates the return-address slot on the stack **by
searching for it**. The prologue decoder's predictions are checked against
those measurements rather than asserted, so a wrong decoder shows up as a
mismatch instead of a plausible number.

Unlike the other tools this one must be compiled **four ways** — `dcc32 -$O-`,
`dcc32 -$O+`, `dcc64 -$O-`, `dcc64 -$O+` — and the columns compared. The dcc64
columns replicate `TWinDebugger.ReadPrologInfo`'s byte-pattern matcher verbatim,
so they act as the self-check: if they stop reproducing the Win64 parameter-home
formula, the probe is wrong, not the shipping code.

```bat
DevTools\Win64\Debug\PrologProbe.exe        REM full dump
DevTools\Win64\Debug\PrologProbe.exe -q     REM decodes only, no raw hex
```

Takes no target: the binary under inspection is itself.

#### VmtProbe

```bat
DevTools\Win64\Debug\VmtProbe.exe        REM full dump
DevTools\Win64\Debug\VmtProbe.exe -q     REM omit the raw VMT window dumps
```

Locates the Delphi VMT metadata slot offsets empirically, by searching the
−256..0 byte window in front of a live VMT for every offset that satisfies an
identity predicate whose ground truth comes from the compiler rather than from
any `vmt*` constant: the class reference **is** the VMT address (SelfPtr); a
compile-time string literal (ClassName); the parent class reference (Parent);
the `TypeInfo()` intrinsic (TypeInfo); the declared field layout (InstanceSize);
and declared published fields (FieldTable). Every matching offset is reported,
not just the first.

Like `PrologProbe` it must be compiled with **both** `dcc32` and `dcc64`: the
`dcc64` column has to reproduce the values already in `TargetLayout.pas` before
the `dcc32` column can be trusted. Takes no target — the binary under inspection
is itself.

### JCL and TDS debug info

Both tools in this group need the upstream JCL sources (see
[Third-party sources](#third-party-sources)); `build_all.bat` skips them when
the JCL is absent.

#### JclProbe

```bat
DevTools\Win64\Debug\JclProbe.exe samples\Debugme\Win64\Debug\Debugme.exe
```

Reports whether a PE image carries JCL debug info (linked JCLDEBUG section or
`.jdbg` sidecar) and enumerates its proc-name table. Accepts either the PE or
the `.jdbg` file.

#### TdsProbe

```bat
DevTools\Win64\Debug\TdsProbe.exe samples\Debugme\Win64\Debug\Debugme.exe
```

Parses the embedded TD32 (`.debug` section, `FB09` magic) of a Delphi-built EXE
using JCL's `TJclTD32InfoParser`, and reports module / source-module / symbol /
proc-symbol / name counts with samples. Reach for this to compare JCL's TD32
parser against our own `TD32FileReader` on the same binary.

### Win32 ABI

#### Win32FloatAbiProbe

```bat
DevTools\Win64\Debug\Win32FloatAbiProbe.exe          rem sizes only
DevTools\build_one32.bat Win32FloatAbiProbe.dpr
DevTools\Win32\Debug\Win32FloatAbiProbe.exe          rem sizes + return ABI
```

Takes no arguments. Dual-compiles on purpose: the size table is only meaningful
with both columns, while the return-ABI half needs x86 asm and is skipped under
dcc64.

Reports the true byte width of every float-family type, then calls a function
returning each one and immediately snapshots EAX, EDX and the whole x87 state to
show which register actually carried the result. Answers the two questions the
debugger's value-read and synthetic-call paths depend on, without trusting
documentation for either.

Measured on Athens 36:

| Type | Win32 | Win64 |
|---|---|---|
| `Single` | 4 | 4 |
| `Double` / `Real` / `Currency` / `TDateTime` / `Comp` | 8 | 8 |
| `Real48` | 6 | 6 |
| `Extended` | **10** | **8** |
| `Extended80` | 10 | **10** |

So `Real` is a `Double` alias on both, and the 6-byte pre-8087 software float is
still there under the name `Real48`. On Win32 **every** float-family type returns
in `ST(0)` — `Currency` included, where Win64 returns a scaled `Int64` in RAX —
and `Currency` arrives already **scaled** (`19.95` → `199500`). That last fact is
why `TExprEvaluator.NormaliseFloatReturn` rounds rather than rescales.

#### Win32FloatArgProbe

```bat
DevTools\build_one32.bat Win32FloatArgProbe.dpr
DevTools\Win32\Debug\Win32FloatArgProbe.exe
```

Takes no arguments; 32-bit only. Reports where a Win32 routine actually
*receives* each parameter, by printing `@Param - EBP` for a set of deliberately
mixed signatures. Under `-$O-` the register three are spilled to **negative**
offsets and genuine stack parameters sit at **positive** ones, so the sign
classifies each parameter and the spacing between consecutive positive offsets
gives each type's stack footprint.

Measured on Athens 36: a floating-point parameter consumes **no** register slot —
in `Foo(A: Integer; B: Double; C: Integer)`, `A` takes EAX, `B` goes on the
stack, and `C` still takes EDX. Stack footprints are `Single` 4, `Double` 8,
`Currency` 8, `Extended` **12** (10 padded to a 4-byte boundary), pushed left to
right so the first declared lands highest.

Gotcha worth keeping: do **not** name the local that captures the frame pointer
`Ebp`. The inline assembler resolves that to the register and emits a no-op
`mov ebp, ebp`, so every offset comes out as an absolute address.

#### Win32ImtThunkProbe

```bat
DevTools\build_one32.bat Win32ImtThunkProbe.dpr
DevTools\Win32\Debug\Win32ImtThunkProbe.exe
```

Takes no arguments; 32-bit only, because it must be COMPILED BY dcc32 to observe
dcc32 output. Prints how the compiler encodes the IMT **adjustor thunk**, which
is what lets the debugger label an interface reference with the class behind it.

The mechanism is deliberately bounded — three reads at addresses the reference
itself supplies, no search:

```
IfacePtr -> [IfacePtr] = interface method table (IMT)
         -> [IMT]      = first method = the adjustor thunk
         -> the thunk's immediate is -IOffset, so Obj = IfacePtr + immediate
```

Measured on Athens 36 over four IOffsets (12, 16, 12, 316):

| Compiler | Encoding | Meaning |
|---|---|---|
| dcc64 | `48 83 C1 ib` / `48 81 C1 id` | `add rcx, imm` |
| dcc64 | `48 8D 49 ib` / `48 8D 89 id` | `lea rcx,[rcx+imm]` |
| dcc32 | `83 44 24 04 ib` | `add dword ptr [esp+4], imm8` |
| dcc32 | `81 44 24 04 id` | `add dword ptr [esp+4], imm32` |

The two compilers adjust Self in different places — RCX versus the stack slot at
`[esp+4]` — but the immediate is `-IOffset` in both, exactly. Only the x64 forms
were decoded until this was measured, which is why a 32-bit target used to show
an interface as a bare pointer.

To see the same chain in a LIVE target rather than in this probe's own process,
`LiveSessionProbe` has an `imt <expr>` script command that walks and prints every
link, including the `IsClassInstance` result the display path gates on.

#### X86DecodeProbe

```bat
DevTools\Win64\Debug\X86DecodeProbe.exe <exe-or-bpl> [-v] [-max N]
```

Validates `DebuggerCore\X86Decode.pas` — the instruction-length decoder the x86
stack walker uses to prove that a stack word follows a `call` — against real
dcc32 output. Needs no reference disassembler, because the binary already
carries ground truth: **every line-table address is an instruction boundary**,
so decoding must land on each one. A single wrong length desynchronises the
stream and the probe sees the misses.

Two measures are reported. *Line-to-line spans* is what the walker actually
relies on (it decodes a short span from a known boundary, never a whole
routine). *Whole-routine decode from entry* is stricter than needed and will
always show some failures, because dcc32 emits the exception-handler table
inline in the code stream after `jmp @HandleAnyException`:

```
E9 7C BF F2 FF   jmp @HandleAnyException
01 00 00 00      handler count
70 A3 41 00      Exception VMT
C8 D6 4D 00      handler address    <- also a line-table address
89 45 FC         handler body
```

That is data, and no linear decode can cross it. The decoder reports
undecidable there, which is the correct answer.

**Read it as a comparison, not as a pass/fail.** Neither count reaches zero on a
real binary, because the exception table is not the only data in the code
stream: every large `case` has its jump table there too, and a jump table is
indistinguishable from an unknown instruction to a linear decoder. What the two
numbers say together is the useful part — a change that ADDS coverage lowers the
unknown count without raising broken spans, while a change that gets a length
WRONG desynchronises and RAISES broken spans.

Run at two scales, because they find different things:

| Module | Routines | Spans | Broken | Unknown opcodes |
|---|---|---|---|---|
| test targets + `hydra_2\ExtApps\*\Win32\Debug` | 9 940 | 70 476 | 588 (0.8 %) | 0 |
| `hydra_2\Win32\Debug\Hydra2SingleEXE.exe` (497 MB) | 393 124 | 2 354 868 | 6 502 (0.28 %) | 48 |

The small set said "zero unknown opcodes" and that was misleading: the 497 MB
binary surfaced 61, and one of them was a real gap rather than data —
`System.Move` opens with `C5 FC 10 08` (`vmovups xmm1,[eax]`) and ends with
`C5 F8 77` (`vzeroupper`), so the Athens RTL **does** emit AVX. Decoding VEX
brought unknowns to 48 and broken spans DOWN (6 528 → 6 502), which is what
confirms the added lengths are right. Every remaining case inspected is data:
repeated small values, or pairs of in-image addresses.

### Live process and adapter

#### McpStdioProbe

```bat
DevTools\Win64\Debug\McpStdioProbe.exe <serverExe> <program> [args|-] [filters|-] [timeoutMs]
```

Drives `DelphiDebuggerMcp.exe` over stdio the way an MCP client does: initialize,
`launch_debuggee`, `continue_and_wait`, then `terminate_debuggee`. For every line
the server writes it prints when the line arrived, how long it is, and whether
it parses as JSON-RPC, so it settles a "the tool call never returned" report: no
answer at all, a late answer, or an answer something else wrote over. When
`continue_and_wait` gets no reply it asks `get_debug_session_status`, which is
how such a report usually describes the session. `-` stands for no arguments
(an empty `""` may be dropped by PowerShell, which shifts every later argument).
The filters are a comma-separated `exceptionFilters` list, `delphi,av,unhandled`
by default; `-` sends an empty list. Exit code 2 when a call went unanswered.

#### WindowWatch

```bat
DevTools\Win64\Debug\WindowWatch.exe [-seconds <n>] [-pid <process id>] [-root <dir>]
```

Lists every top-level window that is shown, and every change of the foreground
window, on the desktop it runs on, while it runs: start it, run the suite or a
probe beside it, then read which processes showed a window or took the focus.
It hooks the events (`SetWinEventHook`, out of context) instead of polling, so a
console window or a box that lives for a few milliseconds is listed too. One
line per event: seconds since start, `SHOW` or `FOREGROUND`, process id,
executable, window class, title; `-root` marks with `*` the processes whose
executable lies under that directory. It stops after `-seconds` (600 by default)
or as soon as the `-pid` process has ended. A console window is reported under
the console program's own process id (class `ConsoleWindowClass`); Windows Error
Reporting dialogs come from `WerFault.exe`. Windows on other desktops are out of
its view -- as they are out of the user's.

#### SessionEndLockProbe

```bat
DevTools\Win64\Debug\SessionEndLockProbe.exe <fixture.exe> [end|terminate]
```

Finds what keeps a debuggee's files locked after its debug session ended. It
debugs a copy of the exe (with its `.map` / `.rsm`) in a fresh folder, ends
the session (the program runs to its end, or is terminated at its entry stop),
and with the session object still alive reports:

- which files cannot be opened for exclusive writing;
- every view of them mapped into this process (`IMAGE` or `MAPPED`);
- this process's handles on them and on the debuggee's process and threads,
  via Sysinternals `handle.exe` when it is on the PATH;
- how long the `.exe` takes to become free.

It repeats the report after freeing the session, which separates what the
session holds from what outlives it. A lock with no view and no handle, that
clears within a second, is the kernel tearing the exited process down, not a
leak (`docs/TRAPS.md`).

#### ProcessEnumProbe

```bat
DevTools\Win64\Debug\ProcessEnumProbe.exe SampleApp
```

Lists processes the debugger can attach to (pid, parent, session,
architecture, image path, command line); no argument lists all.

#### StackDump

```bat
DevTools\Win64\Debug\StackDump.exe 12345 samples\Debugme\Win64\Debug\Debugme.map samples\Debugme\Win64\Debug\Debugme.rsm
```

Attaches read-only to a running process (no `DebugActiveProcess`, so it does
not steal debug ownership from another debugger), walks one or all threads via
`StackWalk64`, and resolves frames through the MAP + RSM pair. Arguments:
`<pid> <map> <rsm> [tid]` — omit the tid to dump every thread. Reach for this
to inspect a target currently held by VS Code plus our adapter, for instance
when a step appears to hang.

#### StepPerf

```bat
DevTools\Win64\Debug\StepPerf.exe ^
  VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe ^
  samples\Debugme\Win64\Debug\Debugme.exe Debugme.dpr 120 -n20 MyVar
```

Measures per-phase step latency (step, `stackTrace`, `scopes`, `variables`, and
each watch expression) over N iterations, reporting min/avg/max. Arguments:
`<adapter.exe> <target.exe> <source-file> <line> [-n<count>] [watch-expr ...]`.

**Historic caveat, now fixed:** every phase used to bottom out near 30 ms
because `DapClient.Dequeue` polled on a 15 ms sleep and the adapter's idle loop
slept another 10 ms. Both are event-driven now, and simple round trips resolve
at ~1 ms — readings below 30 ms are meaningful again.

#### DapSessionTiming

```bat
DevTools\Win64\Debug\DapSessionTiming.exe 20 EVAL_BODY
```

Times the fixed cost of ONE integration-test debug session, phase by phase:
adapter spawn, `initialize`, `setBreakpoints`, `launch` (debuggee spawn +
symbol load), `configurationDone`, run-to-breakpoint, `stackTrace`, `scopes`,
`variables`, `disconnect` and teardown. Uses the suite's own
`DebuggerTests\DapClient.pas`, so what it measures is exactly what ~1200 tests
each pay. Arguments: `[iterations] [bp-marker]` (defaults 10 and `EVAL_BODY`);
one warm-up session runs first and is excluded from the average.

Reach for it before optimising the suite: the per-test timings in
`TestResults.xml` say WHICH tests are slow, this says WHERE inside a test the
time goes.

#### Wow64StackProbe

```bat
DevTools\Win64\Debug\Wow64StackProbe.exe C:\path\To\Win32App.exe -rva DD83C
```

Answers whether a **64-bit** debugger can unwind a **32-bit (WOW64)** target
with dbghelp. Launches the executable under `DEBUG_ONLY_THIS_PROCESS`,
classifies it with `IsWow64Process2`, then walks the stopped thread with
`StackWalk64` using `IMAGE_FILE_MACHINE_I386` + `TWow64Context` for a WOW64
target, or `IMAGE_FILE_MACHINE_AMD64` + `TContext` for a native one — the same
code path, so a run against a known-good x64 executable validates the harness.

Arguments: `<exe> [-rva <hex>] [-maxstops <n>] [-step] [-nopatch]`. With `-rva`
the probe plants an INT3 at `ImageBase + RVA` and walks there, giving an
application-code stack instead of the loader's. `-step` sets EFLAGS.TF through
`Wow64SetThreadContext` and reports which exception code the resulting single
step raises. `-nopatch` walks with the INT3 still planted, which corrupts an
i386 walk — an artificial state the adapter is never in, since it restores the
byte and rewinds the program counter before any walk.

Each stop is walked three ways — dbghelp invade-only, dbghelp with every module
explicitly registered via `SymLoadModuleExW`, and with no dbghelp callbacks at
all — which separates "`StackWalk64` cannot do this" from "dbghelp was not told
about the modules".

`run_wow64probe.bat <logfile> <exe> [args]` runs it with output tee'd to a file,
so partial progress is visible while the probe is still running.

This probe established the WOW64 facts the adapter is built on — the exception
codes, the unwindability of the first stop, and that dbghelp contributes nothing
to an i386 walk. They are recorded in "Target architecture" in
`docs/DAP_DEBUGGER_ARCHITECTURE.md`; re-run the probe to re-measure them rather than
trusting either document.

#### Win32SessionProbe

```bat
DevTools\Win64\Debug\Win32SessionProbe.exe ^
  DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe ^
  DebuggerTests\TestTarget\Win32\Debug\TestTarget.map ^
  DebuggerTests\TestTarget\Win32\Debug\TestTarget.rsm ^
  DebuggerTests\TestTarget TestTargetEdge.pas RECURSION_BASE_BODY
```

Drives a real `TDebugSession` end to end and reports what happened: whether the
breakpoint bound, whether it fired, where the session stopped, what the call
stack looks like, and the frame's locals, their expansion and an evaluation.
Arguments: `<exe> <map> <rsm> <sourceRoot> <sourceBaseName> <marker>`, where
`<marker>` is the text inside a `{BP:…}` tag in the source file.

Nothing in it is 32-bit specific, and that is the point: pointed at a 64-bit
target it exercises exactly the same path, so the two runs are directly
comparable and a difference between them is a real difference rather than an
artefact of testing them differently. The adapter picks `TWinDebugger` or
`TWin32Debugger` from the target's PE header, so the probe needs no switch of
its own.

#### ExcHandlerProbe

```bat
rem Q2: where would a one-shot breakpoint have to go to land in the user's handler?
DevTools\Win64\Debug\ExcHandlerProbe.exe DevTools\Fixtures\Win64\Debug\ExcNestFixture.exe -plant
DevTools\Win64\Debug\ExcHandlerProbe.exe DevTools\Fixtures\Win32\Debug\ExcNestFixture.exe -plant

rem Q1: does EFLAGS.TF survive exception dispatch?  (-cont handled is the control)
DevTools\Win64\Debug\ExcHandlerProbe.exe <target.exe> -tf -cont notHandled
DevTools\Win64\Debug\ExcHandlerProbe.exe <target.exe> -tf -cont handled
```

Answers two questions about what a debugger can do at a **first-chance
exception stop**, against a live debuggee through the raw Windows Debug API,
on a native x64 target and on a WOW64 x86 target from the same 64-bit probe.

| Flag | Meaning |
|---|---|
| `-args "<...>"` | command line handed to the debuggee |
| `-map <file>` | explicit `.map` (default: the exe's sibling) |
| `-code <hex>` | stop only on this exception code (default `$0EEDFADE` and `$C0000005`) |
| `-skip N` | ignore the first N matching first-chance exceptions |
| `-frames N` | x64 stack frames to analyse (default 12) |
| `-tf` | arm `EFLAGS.TF` at the stop, read it back, and report the next debug event |
| `-cont handled\|notHandled` | resume with `DBG_CONTINUE` or `DBG_EXCEPTION_NOT_HANDLED` (default) |
| `-events N` | debug events to report after the resume (default 4) |
| `-plant` | plant an `INT3` at every discovered candidate and report which is reached |
| `-allscopes` | make every scope-table entry a candidate, not only the one covering the frame |
| `-timeout MS` | `WaitForDebugEvent` timeout (default 20000) |

**Everything this probe measured now lives in `docs/EH_FORMAT_NOTES.md`** — the trap-flag
result table, the x64 `.pdata` / `UNWIND_INFO` / scope-table / clause-table layout,
the x86 `fs:[0]` stub classification, and the two traps. That document is the
reference the shipped planner (`TWinDebugger.PlanExceptionStep` and its x86
override) is written against; this section describes only how to RUN the probe.

**Q1 — the trap flag.** `-tf` sets TF on the faulting thread, reads the context
back to prove the write took, and resumes with the chosen status. `-cont
handled` is the control: same stop, same thread, same arming code, only the
continue status differs, so a step there and none with `notHandled` isolates the
dispatch path rather than the arming.

**Q2 — finding the user's block.** On x64 the probe walks the stack with
`StackWalk64`, looks up each frame's `RUNTIME_FUNCTION` in that module's
`.pdata`, decodes `UNWIND_INFO`, and — when the language handler is Delphi's
`_DelphiExceptionHandler` — decodes the scope table that follows the unwind
codes. On x86 there is no `.pdata`, so it walks the `fs:[0]` registration chain
(FS base from `Wow64GetThreadSelectorEntry`, falling back to `TEB64+$2000`
verified through the 32-bit TEB's own `Self` field) and decodes the clause table
that follows each `jmp @HandleOnException` stub. Every address that resolves to
a source line through the engine's own TD32/MAP readers becomes a **candidate**;
`-plant` then puts an `INT3` on each and reports which is actually reached,
which is what proves the address is the user's block and not an RTL funclet.

The clause-table decoding is deliberately gated on the language handler being
Delphi's: under MSVC's `__C_specific_handler` the same field is a **filter
function** RVA, and decoding one as the other produces confident nonsense. The
probe prints `not decoded` for those frames (visible on the `ntdll` frame of any
run).

`DevTools\Fixtures\ExcNestFixture.dpr` is the debuggee it was written against —
a raise inside a `try/finally` inside a `try/except`, with `-bare` and `-two`
variants for a clause-less `except` and for two `on` clauses of which the first
does not match, and `-av` to fault instead of raising. `-nofinally` is
orthogonal to all of them and drops the intervening `try/finally`, which is
otherwise always the handler the exception reaches first — so it is what makes
the three `except` shapes reachable as a landing site. Build it with
`DevTools\build_exc_fixture.bat` (both bitnesses, `-$O- -V -VN -VR -GD`);
`DebuggerTests\build_and_run.bat` and `build_target.bat` call that script too,
because `DebuggerTests\ExceptionStepTests.pas` uses the same fixture rather than
adding exception scenarios to `TestTarget`. It is a **GUI-subsystem** app with no output, and the
probe launches it with `CREATE_NO_WINDOW` and all three standard handles
redirected to `NUL`: a console debuggee pops a window that steals the keyboard
focus on every one of the dozens of launches a measurement run makes. Those
flags are legitimate in a stand-alone probe and are **banned in the adapter** —
an `SW_HIDE` in the adapter's own `CreateProcess` once hid the VCL main forms of
the applications being debugged (`docs/TRAPS.md`). Nothing in that block may be
carried across into `DebuggerCore`.

Nothing in the probe is fixture specific: every path, address and count comes
from the command line, and it works against any executable of either bitness.

#### ProbeCostProbe

```bat
rem what one line probe costs when it goes through a debug event
DevTools\Win64\Debug\ProbeCostProbe.exe -hits -n 10 DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe -run-real-scenario
DevTools\Win64\Debug\ProbeCostProbe.exe -hits -keeprwx -inroutine DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe
DevTools\Win64\Debug\ProbeCostProbe.exe -hits -bisect -timeout 5 DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe

rem what one raw stack capture costs at a stop, at a depth of your choosing
DevTools\Win64\Debug\ProbeCostProbe.exe -walk DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe ^
  DebuggerTests\TestTarget\TestTargetEdge.pas:RECURSION_BASE_BODY
DevTools\Win64\Debug\ProbeCostProbe.exe -walk DevTools\Win32\Debug\ProbeCostProbe.exe ^
  DevTools\ProbeCostProbe.dpr:RECURSE_BOTTOM -recurse 56

rem what suspending a running thread and reading its context costs
DevTools\Win64\Debug\ProbeCostProbe.exe -suspend DevTools\Win64\Debug\ProbeCostProbe.exe -spin 0 60

rem does a thread's cycle counter move while it runs on another core
DevTools\Win64\Debug\ProbeCostProbe.exe -cycles
```

The measurements `docs\PROFILER_COVERAGE_PLAN.md` asks for before the profiler
and the coverage are built (increment 0, assumptions 2, 10 and 15). Four modes,
one per question; every target, source line and count comes from the command
line. Options of the tool come first, the first word that is not one of them is
the target, and everything after it is passed to the target.

| Mode | What it does | What it reports |
|---|---|---|
| `-hits <exe> [args]` | Raw Windows debug loop, no engine. Reads the main module's line records with `TTD32FileReader`, plants a `$CC` on every one at the first breakpoint event (one read and one write per page), and on each hit restores the byte, rewinds the program counter and continues. Each repetition also runs the target unprobed under the same loop. | Records planted, pages touched, time to plant, hits, stale hits (a second thread that ran into a `$CC` already taken out), both wall times, `(probed - baseline) / hits`, the time between consecutive hits, and how much of a hit is spent restoring the byte, reading the context and writing it back. |
| `-walk <exe> <source:line\|source:MARKER> [args]` | Drives a real `TDebugSession` to a breakpoint (`MARKER` is the text inside a `{BP:...}` tag) and walks the stopped thread N times per variant. | Microseconds per walk for the engine's `WalkRawFrames` (reached through a descendant class, so the per-stop frame cache and the 30-frame cap of `GetStackFrames` are out of the way), for `StackWalk64` called directly, with the stack read once, and with every other page cached; for a 32-bit target also a bare EBP chain. Plus how many reads one dbghelp walk makes. |
| `-suspend <exe> [args]` | Runs the target under the raw debug loop and, between events, suspends its busiest thread and one that does not run, reads the context and resumes. | Each of the three calls separately, and how far the thread's cycle counter moved since the previous sample. |
| `-cycles` | Starts a child copy of itself that spins on one core, and reads that thread's cycle counter and `GetThreadTimes` from another core: on a 1 ms high-resolution timer, on `Sleep(1)` at the default timer resolution, and on a busy wait of 1 ms and of `-finetick` microseconds. A thread blocked in `Sleep(INFINITE)` is the control. | Readings that did not change, the longest run of them, and the distribution of the deltas. |

`-hits` checks what it measures: the probed run must end with the baseline's
exit code, its output must match (`-maskdigits` masks numbers, for a target
that prints timings), and at the exit event every patched page must read as it
did before planting, except for a `$CC` on each record that never fired. Exit
code 3 when any of that fails.

A `$CC` on **every** line record is not safe on a 32-bit target: dcc32 emits a
record for a unit's final `end.` that belongs to no routine and can point at
data inside `.text`. `-bisect` finds such records one at a time (it measures
nothing), `-skip <rva,...>` leaves the listed ones out, and `-inroutine` leaves
out every record the TD32 reader attributes to no routine. A run that faults
for ever is ended after `-floodlimit` exceptions (20000) instead of at the
timeout.

The tool is also its own fixture, so that a deep stack and a busy thread exist
on both bitnesses without a change to the test targets: `-recurse <depth>` stops
making calls at a line tagged `RECURSE_BOTTOM`, and `-spin <maskhex> <seconds>`
keeps one thread in user mode and one blocked. `ProbeCostProbe.cfg` adds `-V`, so
the executable carries the TD32 line records a breakpoint needs. Built with
`build_one32.bat ProbeCostProbe.dpr` only those two modes exist: the 32-bit
build is a debuggee.

Measuring a real program needs one that carries TD32 line records. The tools
here are built without them; build a private copy with the fixtures' flags
(`-$O- -V -VN -VR -GD`) into a directory of its own. For `PrebuildIdx`, copy a
few `.rsm` files to a scratch directory and pass `-verify -j 1`: it rebuilds
every sidecar and compares hashes, so its exit code says whether the probed run
produced the same bytes (`-force` on a fresh sidecar only reloads it).

#### LineProbeCost

```bat
rem nothing launched: which line records would carry a one-shot probe, and what arming them costs
DevTools\Win64\Debug\LineProbeCost.exe -file <exe-or-bpl> [-map <file.map>] [-zydis <Zydis.dll>]

rem one first hit, measured on a running program: every confirmed line armed at the entry stop
DevTools\Win64\Debug\LineProbeCost.exe -live -n 7 DebuggerTests\TestTarget\Win64\Debug\ProfilerSample.exe

rem the writes alone at scale: a probe every <stride> bytes of code, the program never runs again
DevTools\Win64\Debug\LineProbeCost.exe -synthetic 4 DebuggerTests\Win64\Debug\RunTests.exe
```

The measurements of `docs\PROFILER_COVERAGE_PLAN.md`, increment 5 (the patch map
and the one-shot form; `DebuggerCore\CodePatchMap.pas`, `LineProbes.pas`). In
`-live` and `-synthetic` the first word that is not an option is the program and
everything after it is passed to it; in `-file` every option may follow the
binary. Set `DAP_LOG=0` first: the engine's log costs more than a hit.

| Mode | What it does | What it reports |
|---|---|---|
| `-file <binary>` | Reads the binary's TD32 (and the MAP, the second routine provider on x86), calls `TLiveCodeAnalysis.ConfirmedLineRecords` for every record -- the call a session makes, over the file -- and arms the confirmed records in a `TCodePatchMap` whose reads come from the file and whose writes are counted and dropped. A region is a section: a live `VirtualQueryEx` merges neighbouring sections of equal protection, so this can count more runs than a process would, never fewer. | Records, confirmed / not code / unconfirmed, routines analysed and not completed, the verdict time with and without building the code map, the probes armed, the program's own `int 3` refused, runs, write calls, bytes the writes cover, pages they would make private, the map's time, and the lookup cost of a hit address. |
| `-live <exe> [args]` | Runs the program to its end under `TDebugSession`, alternately unprobed and with a whole-module request (`TLineProbeHost`) armed at the entry stop. | Records and verdicts, probes armed, analysis and write time, hits recorded, late traps, both median run times, and `(probed - plain) / hits`: one first hit. |
| `-synthetic <stride> <exe> [args]` | Stops the program at its entry point, arms a probe every `<stride>` bytes of every executable section through `ICodePatchTarget` (not instruction boundaries: the program is killed without running), then takes them all away. | Probes armed, runs and write calls, bytes covered, the time in the map and on the wall clock (threads held), and the disarm. |

Measured on 2026-11-27 (16C/32T, Windows build 26300):

| | x64 | x86 |
|---|---|---|
| `ProfilerSample`, `-live -n 7`: armed / first hits / one first hit | 498 / 350 / 54-62 µs | 488 / 348 / 54-62 µs |
| the same: analysis + writes at the entry stop | 3.3 ms + 0.1 ms in 1 write | 1.3 ms + 0.1 ms in 2 writes |
| `Hydra2SingleEXE.exe`, `-file`: records / armed | 2 880 014 / 2 876 724 | 2 791 210 / 2 766 575 (with its MAP; 4 own `int 3` refused) |
| the same: verdicts for all of them | 3.4 s (4.0 s with the code map) | 2.9 s (3.6 s with the code map) |
| the same: runs = write calls / bytes covered / pages made private | 4 781 / 106.7 MB / 31 519 (123 MB) | 3 643 / 73.8 MB / 22 194 (87 MB) |
| the same: time in the map / lookup of a hit address | 288 ms / 81 ns | 288 ms / 88 ns |
| `RunTests.exe` (8.9 MB of code), `-synthetic 4`: 2 287 727 probes | armed in 215 ms with 142 write calls (0.09 µs a probe), taken away in 34 ms | |

#### BreakpointHitCost

```bat
DevTools\Win64\Debug\BreakpointHitCost.exe -count 20000 -n 5 ^
  DebuggerTests\TestTarget\ProfilerSample.dpr:PS_SPIN_BODY ^
  DebuggerTests\TestTarget\Win64\Debug\ProfilerSample.exe -spin 20000
```

What a breakpoint that does not stop costs per pass: the program runs to its
end under `TDebugSession`, alternately without a breakpoint and with one whose
hit condition never holds (`>= 2000000000`), so every pass is a debug event, the
host's decision, the restore and the single step that plants the byte again.
`(median with - median without) / passes`. It uses nothing a released
`DebuggerCore` lacks, so that it can be built against two versions of the
engine and the two compared: that is how increment 5 showed that a session
without probes pays nothing measurable in the breakpoint path (per pass, x64:
140 and 141 µs before, 137 and 148 µs after; x86: 204 and 171 µs before, 176
and 202 µs after -- the spread of one build between two rounds is larger than
the difference between the builds). `-count` is the number of passes the
program makes through the line (`ProfilerSample -spin <n>` makes `n`).

#### LoaderTimingProbe

```bat
rem static: PE flags, .reloc, fixups, the instruction the tool would watch
DevTools\Win64\Debug\LoaderTimingProbe.exe -pe [-zydisdll <path>] <image> [<image>...]

rem launch: every debug event in order, one-shot $CC bytes planted as modules are mapped
DevTools\Win64\Debug\LoaderTimingProbe.exe -run [-entries all|own|none] [-lines <module>]... ^
  [-reloc <module>]... [-plantsite] [-jmppatch] [-anyrecord] [-baseline] [-quiet] ^
  [-path <dir>]... [-timeout <s>] <exe> [args...]

rem attach: the synthesised events and the break-in, with a counter of the target read at each
DevTools\Win64\Debug\LoaderTimingProbe.exe -attach [-quiet] [-path <dir>]... [-timeout <s>] <exe> [args...]

rem everything, against the fixtures, both bitnesses; one report per run in %TEMP%\LoaderTimingProbe
DevTools\build_loader_fixtures.bat
DevTools\run_loader_timing.bat
```

What the Windows loader has done, and what code has run, at each debug event of
a process start or of an attach: "Increment 1" of
`docs/PROFILER_COVERAGE_PLAN.md`, assumptions 3, 4 and 5. A raw debug loop with
no engine in it; a 64-bit tool that drives 64-bit and 32-bit (WOW64) targets.
Line records come from `TTD32FileReader`, instruction lengths from Zydis, the
rest from the PE file and from the target's memory.

| mode / option | what it does |
|---|---|
| `-pe` | per image: `DYNAMIC_BASE`, `HIGH_ENTROPY_VA`, `RELOCS_STRIPPED`, the `.reloc` section, fixups by kind and by section, and the instruction it would watch: one reached from a TD32 line record whose operand is a relocated absolute address |
| `-run` | lists module loads (preferred and actual base, the `ImageBase` field of the mapped header), thread starts, breakpoint exceptions (native `$80000003` and WOW64 `$4000001F`) with the module they belong to and the modules mapped at that moment, debug strings, and its own one-shots |
| `-entries` | one-shot on the entry point of every module (default), of the modules in the executable's directory (`own`), or of none. Planted when the module is mapped: the executable at `CREATE_PROCESS_DEBUG_EVENT`, a DLL at its `LOAD_DLL_DEBUG_EVENT` |
| `-lines <module>` | a one-shot on every TD32 line record of the module that lies in a routine, so the listing shows the order in which its lines first ran, and flags anything that ran before its entry point |
| `-reloc <module>` | reads an instruction with a relocated operand, one relocated slot in a code section and one in a data section at the load event, at the entry-point one-shot and at process exit, next to the file's bytes and to what a relocated image must hold |
| `-plantsite` | with `-reloc`: a one-shot on the first byte of the watched instruction, planted at the load event |
| `-jmppatch` | with `-reloc`: writes `E9 00 01 00 00` over the watched instruction at the load event, reads it back at the entry point, repairs it before anything runs it |
| `-anyrecord` | with `-lines`: also the records in no TD32 routine. Negative control; the target is expected to fault |
| `-baseline` | runs the target first with nothing planted and compares exit code, stdout and debug strings |
| `-attach` | starts the target without a debugger, waits for `counter=<hex> release=<hex>` on its stdout, attaches, lists the events with the counter read at each, and writes 1 to the release flag 300 ms after the break-in. Plants nothing |

At process exit every code section of a module that carried one-shots or a
`-reloc` watch is compared with the file relocated by the actual delta, and every
saved byte with the file's byte.

The fixtures are in `Fixtures\LoaderTiming\` (`build_loader_fixtures.bat`):
`LtHost.exe` requires `rtl` and its own package `LtPkgStatic.bpl`, imports
`LtDllStatic.dll`, and loads what `-pkg <bpl>` / `-dll <dll>` name, in order;
`-wait` makes it spin on a counter for the attach. `LtFixA.dll` / `LtFixB.dll`
share one fixed image base with no dynamic base, so the second one loaded must
move; `LtDynA.dll` / `LtDynB.dll` are the same with a dynamic base. Every unit
`initialization`, DLL `begin..end` block and `DllProc` notification announces
itself with `OutputDebugString`. `LtHost.exe` needs `rtl290.bpl`: pass
`-path <BDS>\bin64` or `-path <BDS>\bin`.

What the first runs established (2026-11-27, Windows build 26300, Delphi 12):

- **A colliding image without a dynamic base is relocated in user mode, after
  its `LOAD_DLL_DEBUG_EVENT` and before its entry point**, on both bitnesses.
  With a dynamic base the bytes are already relocated at the event, and the
  mapped header's `ImageBase` field already holds the actual base.
- **That same image is mapped twice.** The debugger sees `LOAD_DLL`, `UNLOAD_DLL`
  and `LOAD_DLL` again at the same address, with or without anything planted. A
  `$CC` written at the first event goes with the first mapping. The parallel
  loader does the like with system DLLs: a second mapping of the same file at
  another address, unmapped at once.
- A `$CC` planted at the load event of the mapping that stays survives the
  relocation, and so does the saved byte. A five-byte jump planted there does
  not: the loader adds its delta to the fixup field under it. The delta is a
  multiple of 64K, so only the bytes of the field above its low two change.
- dcc64 code has no instruction with a relocated operand; the fixture carries a
  hand-written `mov rax, offset` so that x64 has one to watch.
- The record of a unit's final `end.` lies in no TD32 routine and points at data.
  A `$CC` there (`-anyrecord`) makes `LoadPackage` fault inside `rtl290.bpl`.

#### PatchFeasibilityProbe

```bat
rem build the fixture for both bitnesses, then run every experiment on both
DevTools\build_trampoline_fixture.bat
DevTools\Win64\Debug\PatchFeasibilityProbe.exe ^
  DevTools\Fixtures\Win64\Debug\TrampolineFixture.exe DevTools\Fixtures\Win32\Debug\TrampolineFixture.exe

rem one experiment, one bitness
DevTools\Win64\Debug\PatchFeasibilityProbe.exe -only e3 DevTools\Fixtures\Win32\Debug\TrampolineFixture.exe
```

Hand-built code patches in a live debuggee, to settle whether the line probes of
`docs\PROFILER_COVERAGE_PLAN.md` are feasible as designed (increment 1,
assumptions 6, 7, 14 and 16). No engine: a raw debug loop, memory allocated in
the target with `VirtualAllocEx` (on x64 in the first free region within rel32
reach of the image, found with `VirtualQueryEx`) and trampolines written by
hand. Both fixtures are driven from the one 64-bit probe.

| Flag | Meaning |
|---|---|
| `-only e1,e3,...` | run the listed experiments only (`e1` .. `e7`) |
| `-timeout <s>` | seconds one launch may take before it is killed (default 15) |
| `-floodlimit <n>` | exceptions one launch may produce before it is killed (default 300) |
| `-src <file>` | the fixture's source; default `<exe name>.dpr` in the executable's directory or one of its three parents |
| `-zydisdll <path>` | `Zydis.dll` to load |

**How a result is decided.** Every experiment first runs the fixture PLAIN,
under the same loop, and keeps its transcript: the fixture's `PF: ...`
`OutputDebugString` lines (addresses in them are module relative, so two
launches compare equal under ASLR) and its exit code. A patched run "behaves as
plain" exactly when both are equal. A run that crashes or loops is an expected
outcome: the debuggee is killed and waited for, and the report says how it
ended (second-chance exception with code and address, timeout, flood).

**Where the addresses come from.** `DevTools\Fixtures\TrampolineFixture.dpr` has
one small routine per experiment with `{BP:NAME}` markers; the probe resolves
them through `TTD32FileReader`, decodes the code there with Zydis out of the
live process, and REFUSES a variant, saying why, when the bytes are not the
shape it needs (a row then reads `not run: ...`).

| Experiment | What is patched | Question |
|---|---|---|
| `e1` | the return address R of a call whose callee raises: `jmp rel32`, one-shot `$CC`, the call form, a `jmp` on the second instruction after R; also with the raise two calls below and with the patched frame having no handler | does the x64 unwinder take a `jmp` at R for a tail call (rule 6) |
| `e2` | an epilogue that starts at R, in three compiled shapes: `jmp` behind the stack adjustment, over the last pops and the `ret`, at R; the same as a call; a `$CC` | the second shape of rule 6, and the call form at an exit |
| `e3` | a statement that faults in its first bytes, displaced into a trampoline; then a payload that itself faults | a fault "sent back" to the original address, or to the site with the payload's stack pointer undone, against passing it on |
| `e4` | the rel32 of a direct call, to a trampoline that counts and jumps on; as a contrast a trampoline that CALLS the callee | handler, hit count and the program's own stack trace |
| `e5` | `FF 15` re-encoded as `E8 rel32, 90` and as `90, E8 rel32`, the call being the last instruction of a `try` body, in its middle, and the last instruction before it | does dispatch or a tracer's call-site test notice |
| `e6` | R of `e1` (`jmp`, call form, `$CC`), stop in the callee | three `StackWalk64` walks: read routine `nil`, one serving memory as it is, one serving the original bytes; which code dbghelp reads through the routine |
| `e7` | the first line of a routine the program then hooks with its own detour | a `jmp` and an armed `$CC` under a hook that copies the first bytes |

**Baseline (2026-11-27, Ryzen 9 5950X, Windows 11 build 26300.10075):** 108 rows,
70 confirmed, none refuted, 20 measured without a stated expectation, 18 not
run because the compiled shape does not allow the variant (an x86 epilogue of
one or three bytes takes neither a jump nor a call). The whole run takes three
seconds. `docs\PROFILER_COVERAGE_PLAN.md` owns the conclusions (increment 1);
the ones that are easy to get wrong:

- x64, a `jmp rel32` anywhere in the window of a return address (at R, behind
  `lea rsp`, behind three pops, over `add rsp; ret`): the exception is never
  handled, by any frame, and comes back as a second-chance event. A `$CC`, an
  `E8` and a `jmp` one instruction later are indistinguishable from plain. On
  x86 the same `jmp` is harmless.
- x64, a fault in a trampoline that is passed on does three different things
  depending on the frame: the process dies; a `finally` is skipped and the outer
  handler runs; or the right handler runs with a foreign `ExceptAddr`. Sent
  back, all of them are identical to plain, on both bitnesses.
- x64: dbghelp reads the code at every frame's PC through the read routine it
  is given, a byte at a time, and with `nil` reads the patched memory: only a
  routine that serves the original bytes walks past a `jmp` at a return address
  (three frames instead of seven). On x86 it reads the eight bytes in front of
  candidate return addresses instead, and the three walks agree.
- `90, E8 rel32` keeps the return address of a re-encoded indirect call where it
  was; `E8 rel32, 90` moves it one byte back, which only the program's own stack
  trace can see.

**A 32-bit fixture may not be called "PatchFixture".** A 32-bit executable
without a manifest whose file name contains `patch`, `setup`, `install` or
`update` is taken for an installer: `CreateProcess` fails with error 740 and
nothing is launched. This fixture hit it; the 64-bit build is not affected.

## Source layout

| File | Purpose |
|------|---------|
| `<Tool>.dpr` | One self-contained entry point per tool; there are 58 of them and no shared units other than `RsmReader.pas` |
| `ProbeCostProbe.cfg` | Adds `-V` to that one tool, which is also its own debuggee and needs TD32 line records in its executable |
| `Fixtures\*.dpr` | Debuggees, not tools. In a subfolder so `build_all.bat`'s `*.dpr` discovery does not pick them up, and built with their own script because they need full debug info |
| `RsmReader.pas` | Standalone binary RSM analyzer, used only by `RsmAnalyzer` (separate from `DebuggerCore\RsmFileReader.pas`, which is the parser the adapter actually ships) |
| `build_all.bat` | Builds every `*.dpr` in this folder |
| `build_one.bat` | Builds a single tool, optionally into a private output directory |
| `build_exc_fixture.bat` | Builds `Fixtures\ExcNestFixture.dpr` for both bitnesses with full debug info, for `ExcHandlerProbe` |
| `build_trampoline_fixture.bat` | Builds `Fixtures\TrampolineFixture.dpr` for both bitnesses with full debug info, for `PatchFeasibilityProbe` |
| `Fixtures\LoaderTiming\` | The debuggees of `LoaderTimingProbe`: a host, two packages and six plain DLLs sharing one unit |
| `build_loader_fixtures.bat` | Builds `Fixtures\LoaderTiming\` for both bitnesses with TD32 debug info in every image |
| `run_loader_timing.bat` | Runs every `LoaderTimingProbe` measurement against those fixtures, one report per run in `%TEMP%\LoaderTimingProbe` |
| `build_wow64stackprobe.bat` | Builds only `Wow64StackProbe` (64-bit by construction: the probe *is* the 64-bit debugger side) |
| `run_wow64probe.bat` | Runs `Wow64StackProbe` with its output tee'd to a log file |
| `run_disasm_coverage.bat` | Runs `DisasmCoverage` with the Visual Studio toolset initialised first, so `dumpbin.exe` is on `PATH` |
| `devtool.bat` | Runs a built tool from `Win64\Debug` |
| `..\scripts\setpaths.bat` | Resolves the JCL / DUnitX source roots |

The tools that exercise the debugger's parsers reference the shared engine
units in `..\DebuggerCore\` (`RsmFileReader.pas`, `TD32FileReader.pas`,
`MapFileReader.pas`, `DebugInfoTypes.pas`, and for `Win32SessionProbe` the
whole `DebugSession.pas` facade) via relative paths in their `uses`
clauses, so they always test the current version of the code the adapter ships.
`build_all.bat` and `build_one.bat` pass `-U..\DebuggerCore` to resolve the
transitive dependencies.

## `CompareMapTD32` — expected residual (baseline, 2026-08-08)

The tool is only readable against a baseline, otherwise a normal run cannot be
told from a regression. Measured after the MAP segment-column fix, with DevTools
rebuilt against the fixed reader:

| target | TD32 entries | forward divergences | reverse divergences |
|---|---|---|---|
| Win32, before the fix | 1568 | **all** (constant `$1000`) | **all** |
| Win32, after the fix | 1568 | 9 | 10 |
| Win64 (control) | 1487 | 6 | 9 |

Win32 sits at the same residual level as the always-correct x64 control, so the
leftovers are ordinary MAP-vs-TD32 granularity — one source line owning many RVAs
in instantiated generics — and not a bitness defect.

**To prove any MAP/TD32 reader change**: rebuild DevTools against the changed
reader, then run `CompareMapTD32.exe <exe> <map>` on a 32-bit target AND a 64-bit
control, and compare against this table.

### `build_all.bat` wildcard guard

In a cmd batch a `*.dpr` wildcard also matches `*.dproj` through 8.3 short names,
so the auto-discovery must keep its `%~xF` extension guard.

## `DataBpProbe` — hardware watchpoint feasibility (2026-08-08)

```
DataBpProbe.exe <exe> [-maxhits <n>] [-tfstep] [-tfwalk <n>]
```

Launches the target, arms `DR0` for write on a known global, and reports each
trap: which `DR6` bit fired, whether the watched write was already visible in
target memory, and whether `DR7` survived. Works against both a native x64 and a
WOW64 x86 target from the same 64-bit probe.

Built for increment 1 of `docs/DATA_BREAKPOINTS_PLAN.md`, and kept because it is the
fastest way to re-check debug-register behaviour after any change to the thread
context funnel.

**The finding it exists to record**: arming at `CREATE_PROCESS_DEBUG_EVENT` never
fires, on EITHER bitness — the initial thread has not run user code yet. Arm
after the process's own initial system breakpoint (`$80000003` native,
`$4000001F` for the WOW64 target's own, which follows the native one).

`-tfstep` and `-tfwalk` answer the question increment 2 turned on: a watchpoint
hit and a completed single step arrive as the SAME exception, so can the pump
separate them from `DR6` alone?

- `-tfstep` sets the trap flag once after arming and reports the `DR6` of the
  step it produces. Measured on both bitnesses: `BS` (bit 14) set, slot bits
  clear.
- `-tfwalk <n>` keeps stepping with the trap flag armed until one stepped
  instruction also writes the watched cell — the combined case. Measured on both
  bitnesses: `DR6` carries `BS` **and** the slot bit (`$FFFF4FF1`).

So the disambiguation needs no state of its own. Note that `DR6` reads back with
its reserved bits SET (`$FFFF4FF0` for a plain step), so it must be masked field
by field rather than compared or tested for zero.
