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

Run a built tool from `Win64\Debug` without typing the path:

```bat
DevTools\devtool.bat TestRsmParser Win64\Debug\Debugme.rsm
```

### Third-party sources

`TdsProbe` and `JclProbe` compile against the upstream JCL sources. When those
sources are absent, `build_all.bat` skips those two tools and builds the rest.
The source roots are resolved by `..\setpaths.bat` and can be overridden from
the environment:

```bat
set JCL_ROOT=D:\src\jcl\jcl\source
set DUNITX_ROOT=D:\src\DUnitX\Source
```

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
DevTools\Win64\Debug\RsmAnalyzer.exe Win64\Debug\Debugme.rsm
```

Reach for this when the RSM parser fails to find a procedure or variable —
inspect the `.analysis.txt` record scan to understand the actual byte layout
near the name.

#### ScanRsmMethods

Searches for a string inside an `.rsm` file and dumps the surrounding bytes
together with the tag context (bytes before the string hit). The search term
defaults to `Create`.

```bat
DevTools\Win64\Debug\ScanRsmMethods.exe Win64\Debug\Debugme.rsm TWidget.Create
```

Reach for this to locate where a class method name appears in the RSM and
verify whether it is preceded by `$63 $28` (standard) or a bare `$28` (class
declared in the `.dpr`).

#### ScanRsmConsts

```bat
DevTools\Win64\Debug\ScanRsmConsts.exe Win64\Debug\Debugme.rsm [name-substring-filter]
```

Scans an `.rsm` for named-constant records (tag `0x25`) and dumps their
trailing value bytes. Reach for this when decoding how a constant's value is
encoded after its name.

#### DumpRsmUses

```bat
DevTools\Win64\Debug\DumpRsmUses.exe Win64\Debug\Debugme.rsm [unit-name-filter]
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
DevTools\Win64\Debug\DumpRsmNames.exe Win64\Debug\Debugme.rsm
```

Prints the total number of procedure names the RSM reader indexed, then lists
the ones matching a set of substring filters. Note: the filters are hardcoded
to test-target identifiers (`testtarget`, `init`, `twidget`, …), so the tool is
a quick "did the parser index anything at all?" check rather than a general
name browser — use `TestRsmParser` for a full listing.

#### DumpRsmClass

```bat
DevTools\Win64\Debug\DumpRsmClass.exe Win64\Debug\Debugme.rsm TWidget
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
DevTools\Win64\Debug\TestRsmParser.exe Win64\Debug\Debugme.rsm
```

Run this after changing `RsmFileReader.pas` to verify the parser still finds
the expected procedures and locals. With no argument it falls back to
`..\Win64\Debug\Debugme.rsm` relative to the executable.

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
DevTools\Win64\Debug\TestTD32Reader.exe Win64\Debug\Debugme.exe
```

Smoke test for `DebuggerCore\TD32FileReader.pas`: loads the `.debug` section,
parses the SOURCE_MODULE entries, reports the total line-pair count, prints the
first and last five RVA→source:line mappings and one reverse lookup. Run it
after changing the TD32 reader.

#### Td32LineLookup

```bat
DevTools\Win64\Debug\Td32LineLookup.exe Win64\Debug\Debugme.exe Debugme.dpr 120
```

Resolves source file + line to the RVA(s) a breakpoint would bind at, from the
TD32 line table. First tool to reach for on "my breakpoint never binds".

#### DumpTd32Globals

```bat
DevTools\Win64\Debug\DumpTd32Globals.exe Win64\Debug\Debugme.exe [name-substring-filter]
```

Lists the global/unit-level symbols a module's TD32 debug info exposes;
answers "which module actually owns this global?".

#### CvProbe

```bat
DevTools\Win64\Debug\CvProbe.exe Win64\Debug\Debugme.exe
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
DevTools\Win64\Debug\DiffTD32RsmNames.exe Win64\Debug\Debugme.exe
```

Takes the EXE path and reads the sibling `.rsm` implicitly. Diffs the procedure
names exposed by `TD32FileReader` against those keyed by the RSM reader's
procedure index, in both directions, and also dumps sample locals and globals.
Reach for this when locals resolve under one reader but not the other: any name
TD32 emits that RSM does not recognize fails the locals lookup downstream.

### MAP files

#### CompareMapTD32

```bat
DevTools\Win64\Debug\CompareMapTD32.exe Win64\Debug\Debugme.exe
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
DevTools\Win64\Debug\TestNested.exe Win64\Debug\Debugme.map
```

Reach for this when debugging step-in / step-out behaviour for nested
procedures. With no argument it falls back to `..\Win64\Debug\Debugme.map`
relative to the executable. Note: the inner-procedure names it probes are a
fixed list (`ThisIsALocalProcedure`, `Increment`, `Inner`, `NotANest`).

#### RvaLookup

```bat
DevTools\Win64\Debug\RvaLookup.exe Win64\Debug\Debugme.map Win64\Debug\Debugme.rsm 2CCA0 2CD10
```

Resolves a list of RVAs against a MAP + RSM pair, producing
`name+0xNN (Unit.pas:line)` for each. RVAs are accepted as hex (with or without
a `0x` / `$` prefix). Reach for this to interpret stack frames dumped by
WinDbg/cdb, which show Delphi binaries as huge offsets from the single
`_dbk_fcall_wrapper` export. The MAP is loaded at the preferred base
`$400000`, so pass RVAs, not runtime VAs.

### PE / raw binary

#### DumpFunc

Dumps N bytes of machine code from a PE file at a given RVA, after printing the
section table and the RVA→file-offset translation. Useful for manual
disassembly of a specific function's prologue/epilogue.

```bat
DevTools\Win64\Debug\DumpFunc.exe Win64\Debug\Debugme.exe 2CCA0 64
```

Arguments: `<exe-path> <hex-RVA> <byte-count>`.

#### HexDump

```bat
DevTools\Win64\Debug\HexDump.exe Win64\Debug\Debugme.rsm 1A40 128
```

Hex + ASCII dump of any file. Arguments: `<file> <hex-offset> <byte-count>`.
Reach for this to read the bytes around an offset another tool reported.

#### FindBytes

```bat
DevTools\Win64\Debug\FindBytes.exe Win64\Debug\Debugme.rsm 6328 20
```

Scans any binary for a hex byte pattern and lists every hit offset; the
optional third argument caps the number of hits reported.

### JCL and TDS debug info

Both tools in this group need the upstream JCL sources (see
[Third-party sources](#third-party-sources)); `build_all.bat` skips them when
the JCL is absent.

#### JclProbe

```bat
DevTools\Win64\Debug\JclProbe.exe Win64\Debug\Debugme.exe
```

Reports whether a PE image carries JCL debug info (linked JCLDEBUG section or
`.jdbg` sidecar) and enumerates its proc-name table. Accepts either the PE or
the `.jdbg` file.

#### TdsProbe

```bat
DevTools\Win64\Debug\TdsProbe.exe Win64\Debug\Debugme.exe
```

Parses the embedded TD32 (`.debug` section, `FB09` magic) of a Delphi-built EXE
using JCL's `TJclTD32InfoParser`, and reports module / source-module / symbol /
proc-symbol / name counts with samples. Reach for this to compare JCL's TD32
parser against our own `TD32FileReader` on the same binary.

### Live process and adapter

#### ProcessEnumProbe

```bat
DevTools\Win64\Debug\ProcessEnumProbe.exe SampleApp
```

Lists processes the debugger can attach to (pid, parent, session,
architecture, image path, command line); no argument lists all.

#### StackDump

```bat
DevTools\Win64\Debug\StackDump.exe 12345 Win64\Debug\Debugme.map Win64\Debug\Debugme.rsm
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
  Win64\Debug\Debugme.exe Debugme.dpr 120 -n20 MyVar
```

Measures per-phase step latency (step, `stackTrace`, `scopes`, `variables`, and
each watch expression) over N iterations, reporting min/avg/max. Arguments:
`<adapter.exe> <target.exe> <source-file> <line> [-n<count>] [watch-expr ...]`.

**Caveat:** every phase bottoms out near 30 ms because of the response-polling
granularity in `DebuggerTests\DapClient.pas`. The tool cannot resolve costs
below that floor — treat sub-30 ms readings as noise.

## Source layout

| File | Purpose |
|------|---------|
| `<Tool>.dpr` | One self-contained entry point per tool; there are 24 of them and no shared units other than `RsmReader.pas` |
| `RsmReader.pas` | Standalone binary RSM analyzer, used only by `RsmAnalyzer` (separate from `DebuggerCore\RsmFileReader.pas`, which is the parser the adapter actually ships) |
| `build_all.bat` | Builds every `*.dpr` in this folder |
| `build_one.bat` | Builds a single tool, optionally into a private output directory |
| `devtool.bat` | Runs a built tool from `Win64\Debug` |
| `..\setpaths.bat` | Resolves the JCL / DUnitX source roots |

The tools that exercise the debugger's parsers reference the shared engine
units in `..\DebuggerCore\` (`RsmFileReader.pas`, `TD32FileReader.pas`,
`MapFileReader.pas`, `DebugInfoTypes.pas`) via relative paths in their `uses`
clauses, so they always test the current version of the code the adapter ships.
`build_all.bat` and `build_one.bat` pass `-U..\DebuggerCore` to resolve the
transitive dependencies.
