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
recorded in `TD32_FORMAT_NOTES.md` → "Named float aliases are FLATTENED at the
variable".

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

#### Td32ProcNesting

```bat
DevTools\Win64\Debug\Td32ProcNesting.exe Win64\Debug\Debugme.exe [name-substring]
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

#### MapSegBaseProbe

```bat
DevTools\Win64\Debug\MapSegBaseProbe.exe Win64\Debug\Debugme.exe Win64\Debug\Debugme.map [seg:offset ...]
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
`DAP_DEBUGGER_ARCHITECTURE.md`; re-run the probe to re-measure them rather than
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

## Source layout

| File | Purpose |
|------|---------|
| `<Tool>.dpr` | One self-contained entry point per tool; there are 31 of them and no shared units other than `RsmReader.pas` |
| `RsmReader.pas` | Standalone binary RSM analyzer, used only by `RsmAnalyzer` (separate from `DebuggerCore\RsmFileReader.pas`, which is the parser the adapter actually ships) |
| `build_all.bat` | Builds every `*.dpr` in this folder |
| `build_one.bat` | Builds a single tool, optionally into a private output directory |
| `build_wow64stackprobe.bat` | Builds only `Wow64StackProbe` (64-bit by construction: the probe *is* the 64-bit debugger side) |
| `run_wow64probe.bat` | Runs `Wow64StackProbe` with its output tee'd to a log file |
| `devtool.bat` | Runs a built tool from `Win64\Debug` |
| `..\setpaths.bat` | Resolves the JCL / DUnitX source roots |

The tools that exercise the debugger's parsers reference the shared engine
units in `..\DebuggerCore\` (`RsmFileReader.pas`, `TD32FileReader.pas`,
`MapFileReader.pas`, `DebugInfoTypes.pas`, and for `Win32SessionProbe` the
whole `DebugSession.pas` facade) via relative paths in their `uses`
clauses, so they always test the current version of the code the adapter ships.
`build_all.bat` and `build_one.bat` pass `-U..\DebuggerCore` to resolve the
transitive dependencies.
