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

#### DisasmProbe

```bat
DevTools\Win64\Debug\DisasmProbe.exe DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe 167FC0 10
DevTools\Win64\Debug\DisasmProbe.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe F4E78 10
```

Proves the Zydis dependency end to end (`DISASSEMBLY_PLAN.md` increment 1):
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

Exercises the real feature (`DISASSEMBLY_PLAN.md` increment 2): the
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

Differential coverage sweep (`DISASSEMBLY_PLAN.md` increment 3): feeds the
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
divergence in `DISASSEMBLY_PLAN.md` "Verified in increment 3 — Half B":**

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
full write-up in `DISASSEMBLY_PLAN.md`.

**To reproduce or extend this baseline**: rebuild `DevTools` (`build_all.bat`
already includes `DisasmCoverage`), then re-run the invocations above and
compare against this table — a change that adds a real Zydis gap should show
up as a NEW `mnemonic` divergence; a change to the normalisation table
should be justified by a measured example the same way every entry above is.

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

**Q1 — the trap flag.** `-tf` sets TF on the faulting thread, reads the context
back to prove the write took, and resumes with the chosen status. `-cont
handled` is the control: same stop, same thread, same arming code, only the
continue status differs, so a step there and none with `notHandled` isolates the
dispatch path rather than the arming. Measured, two runs each:

| target | exception | resume | next event |
|---|---|---|---|
| x64 | Delphi raise | deliver | **none** — ran to exit |
| x64 | Delphi raise | swallow (control) | single step at the stop RIP + 5 |
| x64 | access violation | deliver | **none** |
| x86 WOW64 | Delphi raise | deliver | **`STATUS_WX86_SINGLE_STEP` at `ntdll32!KiUserExceptionDispatcher+1`** |
| x86 WOW64 | Delphi raise | swallow (control) | single step at the stop EIP + 4 |
| x86 WOW64 | access violation | deliver | **none** |

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
does not match. Build it with `DevTools\build_exc_fixture.bat` (both bitnesses,
`-$O- -V -VN -VR -GD`). It is a **GUI-subsystem** app with no output, and the
probe launches it with `CREATE_NO_WINDOW` and all three standard handles
redirected to `NUL`: a console debuggee pops a window that steals the keyboard
focus on every one of the dozens of launches a measurement run makes. Those
flags are legitimate in a stand-alone probe and are **banned in the adapter** —
an `SW_HIDE` in the adapter's own `CreateProcess` once hid the VCL main forms of
the applications being debugged (`TRAPS.md`). Nothing in that block may be
carried across into `DebuggerCore`.

Nothing in the probe is fixture specific: every path, address and count comes
from the command line, and it works against any executable of either bitness.

## Source layout

| File | Purpose |
|------|---------|
| `<Tool>.dpr` | One self-contained entry point per tool; there are 48 of them and no shared units other than `RsmReader.pas` |
| `Fixtures\*.dpr` | Debuggees, not tools. In a subfolder so `build_all.bat`'s `*.dpr` discovery does not pick them up, and built with their own script because they need full debug info |
| `RsmReader.pas` | Standalone binary RSM analyzer, used only by `RsmAnalyzer` (separate from `DebuggerCore\RsmFileReader.pas`, which is the parser the adapter actually ships) |
| `build_all.bat` | Builds every `*.dpr` in this folder |
| `build_one.bat` | Builds a single tool, optionally into a private output directory |
| `build_exc_fixture.bat` | Builds `Fixtures\ExcNestFixture.dpr` for both bitnesses with full debug info, for `ExcHandlerProbe` |
| `build_wow64stackprobe.bat` | Builds only `Wow64StackProbe` (64-bit by construction: the probe *is* the 64-bit debugger side) |
| `run_wow64probe.bat` | Runs `Wow64StackProbe` with its output tee'd to a log file |
| `run_disasm_coverage.bat` | Runs `DisasmCoverage` with the Visual Studio toolset initialised first, so `dumpbin.exe` is on `PATH` |
| `devtool.bat` | Runs a built tool from `Win64\Debug` |
| `..\setpaths.bat` | Resolves the JCL / DUnitX source roots |

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

Built for increment 1 of `DATA_BREAKPOINTS_PLAN.md`, and kept because it is the
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
