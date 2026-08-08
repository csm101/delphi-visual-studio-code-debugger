# Debug-info format coverage — roadmap TODO

Deferred: start AFTER the current functional-verification phase (the engine working
correctly comes first). Captured 2026-07-18 at the user's request.

## Today (what the engine reads)

Readers (`DebuggerCore\`): `TD32FileReader` (embedded PE `.debug` CodeView
section, the primary source of types/locals/globals/lines), `MapFileReader` (text
`.map`; still required for the nested-proc `_ZZ` parent linkage used by outer-scope
locals), `RsmFileReader` (Embarcadero `.rsm` and the same-format BPL `.dcp`), and
`JclDebugReader` (JCL linked `JCLDEBUG` section / sidecar `.jdbg`; address->location
+ proc-name fallback, registered below TD32 and above MAP -- see P1 below, DONE).
`TD32FileReader` also reads an external `.tds` (dcc64 -VT) via `LoadFromTdsFile` when
the exe has no embedded `.debug` (P3, DONE). No DCU / PDB / DWARF support.

Consequence: a module whose debug info lives ONLY in DCUs, or only as JCL-linked/`.jdbg`
data, is invisible (no line/function/type resolution for it). SampleApp.exe (a large
proprietary Delphi Win64 application on the maintainer's machine, not present in a
fresh clone) notably has
**no `.map`**, which is the gap behind the nested-proc `_ZZ` / outer-scope-locals residual.

---

## P1 — JCL debug info — DONE (2026-07-18)

Implemented in `DebuggerCore\JclDebugReader.pas` (provider) + wired into
`ModuleSymbolLoader` (`EnsureMainJcl` / `EnsureModuleJcl`), registered BELOW TD32
and ABOVE MAP in the provider chain. Opt-in via the `JCL_DEBUG` define, DEFAULT
ON; build with `JCL_DEBUG_OFF` to compile it out entirely (zero JclDebug
dependency, factory returns nil). See "How to enable / disable" at the bottom.

What it does / does not do (verified on SampleAppSingleExe + TestTarget, 2026-07-18):
- ADDRESS -> LOCATION works: `RvaToSourceLine` / `RvaToFunctionName` /
  `RvaToFunctionStart` via `TJclBinDebugScanner`, reading either the linked
  `JCLDEBUG` PE section or a sidecar `.jdbg`. Address convention: scanner Addr =
  imageRVA - ModuleCodeOffset ($1000); a relocated DLL/BPL adds its RVA shift.
- LINE -> ADDRESS is NOT provided (`SourceLineToRva` returns False). TD32 owns BP
  binding; JCL has no public reverse lookup.
- The `_ZZ` nested-proc win did NOT materialise: JCL preserves ZERO
  `_ZZ$pdata$` / `$unwind$` mangled EH publics (confirmed: 0 of 454k symbols on
  SampleAppSingleExe). So `GetEnclosingProcedure*` return False -- JCL cannot rebuild
  the nested-proc parent linkage MAP provides for outer-scope locals. Nested
  procs DO appear demangled (`Unit.Outer.Inner$ActRec.$0$Body`); deriving parent
  linkage by string-parsing those is CLOSED as not worth it (2026-07-18): it has
  NO consumer -- every module that carries JCL data also carries embedded TD32
  (which already supplies nested-proc linkage), and SampleApp.exe (the multi-BPL host
  that lacks `.map`) has no JCL data at all. It would also mean replicating JCL's
  symbol-table decode (the scanner exposes no name enumeration) for a fragile
  `$ActRec` heuristic. Reopen only if a real JCL-only-with-nested-procs target appears.
- Net role: a MAP-equivalent line/proc-name fallback for a module that has JCL
  data but no embedded TD32 and no `.map`. On the main exe / SampleApp (which have
  TD32) it is mostly redundant for lines/funcs (TD32 already wins), and it does
  NOT close the SampleApp nested-proc/outer-scope gap. SampleApp.exe (the multi-BPL
  host) has no JCL data at all; SampleAppSingleExe has a `.jdbg` sidecar.

Staleness: a `.jdbg` sidecar is stale-gated (`SymbolFileIsStale`, skipped if older
than the binary, like `.rsm`/`.map`); a linked `JCLDEBUG` section lives inside the
binary and is never stale.

Smoke test: `DebuggerTests\JclDebugReaderTests.pas` (8 tests) resolves
function + source file + line for TestTarget via the JCL provider, cross-checked
against TD32 as the oracle. `build_jdbg.bat` generates `TestTarget.jdbg` from
`TestTarget.map` (JCL's `ConvertMapFileToJdbgFile`); the tests self-skip when JCL
is absent. Wired into `build_and_run.bat`.

### How to enable / disable
- ENABLED by default (environment-specific: the maintainer has the JCL sources at
  `C:\Athens\jcl\jcl\source`; they are not part of a fresh clone). The
  `JCL_DEBUG` define defaults ON inside `JclDebugReader.pas`; the JCL include/unit
  search paths are added to the three configs that compile `ModuleSymbolLoader`:
  `VisualStudioCodeDelphiDebugger.cfg`, `DebuggerTests\RunTests.cfg`, and
  `build_mcp.bat` (inline). Those paths are harmless when the define is off.
- To DISABLE (e.g. an open-source build without JCL installed): compile with
  `-D JCL_DEBUG_OFF` (or define it in the `.cfg`). The `uses JclDebug` then
  vanishes, so JCL need not be installed and the search paths are ignored.
- Caveat: only the command-line build path (bats + hand-maintained `.cfg`) is
  wired. If you ever build the adapter / MCP / runner from the IDE (msbuild via
  `.dproj`), add the same JCL include/unit search paths and, to disable, the
  `JCL_DEBUG_OFF` define to those project options -- an IDE build regenerates the
  `.cfg` from the `.dproj` and would otherwise drop the search paths.

---

## P1 — JCL debug info (original plan, kept for reference)

JCL (JEDI Code Library) debug info is MAP-derived data stored either as a separate
**`.jdbg`** file (compressed) or **linked directly into the exe** (a `JCLDEBUG`
section/resource inserted by JCL's post-link step). **SampleApp.exe very likely has it
linked in.** It provides unit/source names, line<->address, and procedure names
(MAP-equivalent) -- **including the mangled `_ZZ` nested-proc publics** we currently
need `.map` for (verify). It does NOT carry types/variables (those stay on TD32/RSM).

Why it matters: for the main exe (which HAS embedded TD32 for types/locals) JCL-linked
data supplies the MAP role -- the `_ZZ` nested-proc linkage + a line fallback -- that
SampleApp lacks today. So it directly helps the F11 nested-proc residual and general line
resolution.

API recon done 2026-07-18 (JCL is installed at `C:\Athens\jcl\jcl\source`):
- ADDRESS -> LOCATION is easy and fully covered. `TJclBinDebugScanner` (linked/`.jdbg`)
  and `TJclMapScanner` expose `LineNumberFromAddr`, `ProcNameFromAddr`,
  `SourceNameFromAddr`, `UnitNameFromAddr`; `TJclDebugInfoSource.GetLocationInfo(Addr)`
  returns a `TJclLocationInfo` (unit/proc/source/line). -> `RvaToSourceLine` +
  `RvaToFunctionName` map straight onto these.
- LINE -> ADDRESS (needed for BP binding) is NOT in JCL's public API (the line table
  `FLineNumbers` is private, only reverse-searched via `LineNumberFromAddr`). Not a
  blocker: for a target like SampleApp the embedded TD32 already provides `SourceLineToRva`,
  so JCL only needs to be the ADDRESS->LOCATION + proc-name fallback. If a genuinely
  MAP+TD32-less module ever needs BP binding from JCL, we'd have to scan JCL's line data
  ourselves (or contribute a reverse lookup).
- The `_ZZ` NESTED-PROC linkage (the real F11 outer-scope win) is the uncertain part:
  need to confirm whether JCL's proc-name table preserves the raw `_ZZ` mangled names
  (JCL tends to clean/demangle) so `FInnerToParent`-style linkage can be rebuilt. Verify
  before relying on JCL to replace `.map` for outer-scope locals.
- Cost/risk: touches the BUILD SYSTEM across every config (adapter / MCP / runner /
  DevTools) -- the `JCL_DEBUG` define + JCL search paths (`C:\Athens\jcl\jcl\source\*`)
  must be added to each `.cfg`/`.dpr`/`.dproj`, and JCL either precompiled or compiled
  from source. Getting a path wrong breaks all builds. Do this in a FOCUSED session, not
  bolted onto other work. Default-ON per the user, but flip the default only AFTER all
  builds are verified green with JCL wired in.

Plan:
- Add a `JclDebugReader` unit implementing `ISourceLineProvider` +
  `IFunctionNameProvider` (same contract as `MapFileReader`), sourcing from JCL's
  ready-made scanners in `jclDebug.pas` (`TJclBinDebugScanner` for linked/`.jdbg`;
  `IsCompiledWithBinDebugInfo` / the module-scan helpers to detect it). Gate the whole
  unit body in `{$IFDEF JCL_DEBUG}` so a build with the define off has ZERO JCL
  dependency (the reader compiles to a no-op factory returning nil).
- Detection + priority: if a `.jdbg` exists next to the module OR the module is linked
  with JCL debug info, register this provider with priority ABOVE `.map`.
- **Decision (settled): reuse jclDebug for the `.jdbg` + linked-in-exe formats** (no
  reason to reimplement the JCL binary format), but **keep our own `MapFileReader` for
  plain `.map`** -- it is indexed + background-loaded + tuned for the huge SampleApp map,
  which JCL's map scanner is not. So: JCL owns `.jdbg`/linked; we own `.map`.
- Dependency: add JCL (`jclDebug` + its deps) to the build. Confirm the license fits
  and that `jclDebug` compiles for Win64 in this toolchain.
- Verify: does the linked/`.jdbg` data preserve the `_ZZ` mangled names (needed for
  nested-proc parent linkage)? If yes, this can replace `.map` for SampleApp.

## P2 — DCU debug info — WON'T DO (recon 2026-07-18)

Investigated and closed. A `.dcu` compiled with `{$D+}{$L+}{$Y+}` embeds its debug
info in the proprietary DCU container (magic `4D 23 00 24` = `M#.$`); it is NOT the
TD32/CodeView format (no `FB09` signature anywhere), so `TD32FileReader` cannot be
reused. The container is undocumented and version-specific (changes every compiler
release) -- a reader would be high-effort and perpetually fragile.

More importantly it has ZERO consumer, verified empirically (not just asserted):
a program was linked against a debug-compiled `uSample.dcu` with its SOURCE HIDDEN
(the strongest case -- a source-less third-party debug `.dcu`). The final `useit.exe`
still carries a full `Line numbers for uSample(uSample.pas)` section in its `.map`,
and the engine's own `TTD32FileReader` on `useit.exe` resolves both `NameToRva('DcuAdd')`
and `uSample.pas:7/:8` from the embedded TD32 -- i.e. the linker propagates the `.dcu`'s
debug info (lines + symbols) into the binary the engine already reads. Reading the
`.dcu` directly would gain nothing. There is no realistic scenario where a `.dcu` is
the SOLE debug-info source for code the debugger runs. Reject unless a concrete target
ever requires it. (Verified with a one-off two-unit sample project; conclusion recorded
here.)

**Amendment (2026-07-29): the "zero consumer" claim was too strong.** The linker
propagates the `.dcu`'s LINES and SYMBOLS into the binary's TD32, which is what the
2026-07-18 recon measured — but it does NOT propagate named float ALIASES. Measured
with `DevTools\Td32AliasProbe`: a local declared `TDateTime` carries CV type id
`$0041` (the bare `Double` primitive) on both bitnesses, and `TDateTime` has no
record in the TYPES table at all. See TD32_FORMAT_NOTES.md → "Named float aliases
are FLATTENED at the variable". So there IS something only the compiler's symbol
tables hold.

The verdict does not change, for two reasons:
- The gap is already covered where it matters. `.rsm` keeps the alias, and so does
  the RSM-format `.dcp` we already load for packages (verified on `QBFD29.dcp`:
  `TDateTime` / `Currency` / `Double` / `Extended` come back as distinct hints).
  Uncovered case = a plain exe with no `.rsm`.
- The payoff is rendering only: `TDateTime` shown as a date rather than `45000.5`,
  and `Real` distinguished from `Double`. No value or read-width is affected.

If it is ever wanted for the uncovered case, the cheap option is reading the
DECLARATION from the source (unit + routine + variable name are all known, and the
fallback to the TD32 name is clean) — not a DCU reader, which stays undocumented and
version-specific.

## P2 — DCP linked debug info — CONFIRMED covered, no gap (2026-07-18)

A BPL's debug info is served by TWO providers that both load today (verified on the
two-BPL integration test; adapter log shows `DLL TD32 loaded: testpackage.bpl` AND
`DLL DCP loaded: testpackage.bpl`):
- **Embedded TD32** in the `.bpl` PE `.debug` section — lines / types / locals /
  function names (`EnsureModuleTD32`, RVA-range-scoped + shifted).
- **`.dcp` sidecar** (RSM-format, read by `RsmFileReader` via `EnsureModuleDcp`) —
  the package's rich RSM-format metadata.
The whole DAP suite runs a second time in the BPL scenario (`TDebuggerTestsBpl`
launches `TestHost.exe` + `TestSubject.bpl`); breakpoints, locals, call stacks and
types all resolve in package code, so there is no gap. No work needed.

## P3 — External `.tds` — DONE (2026-07-18)

Implemented. `TTD32FileReader.LoadFromTdsFile(TdsPath, ExePath, OutputRvaShift)` reads
the standalone `.tds` (dcc64 -VT) as the CodeView blob while taking the PE section
table + import directory from the companion exe (a second read-only file mapping;
`FBase` = exe, `FDebugBase` -> the `.tds`). Wired into `ModuleSymbolLoader`:
`LoadMainTds` (fallback when the exe has no embedded `.debug`: `if not LoadMainTD32
then LoadMainTds`) and `EnsureModuleTds` (per runtime module, after `EnsureModuleTD32`);
`MainTD32` falls back to the `.tds` reader so the variable expander still binds.

STALENESS (as requested): a `.tds` older than the binary it describes is skipped via
`SymbolFileIsStale` (same policy as `.rsm`/`.map`/`.jdbg`) -- both `LoadMainTds` and
`EnsureModuleTds` gate on it.

KEY FORMAT QUIRK (found + handled): unlike the embedded `.debug` section (whose
CodeView segment offsets are pure segment-relative), an external `.tds` stores each
offset as `(segment-relative - ImageBase)`. Verified: embedded `Foo` -> RVA `$DF70`;
the `.tds` stored the offset `$400000` lower. Fix: capture the PE ImageBase in
`FindDebugSection`; the `.tds` path folds it into `FSegmentVAs`, and every CV address
is now computed through `SegOffsetToRva` which truncates the segment+offset sum to
32 bits (a PE RVA is 32-bit) so the ImageBase bias cancels. Embedded path unaffected.

Tests: `TD32ReaderTests.Tds_ResolvesFunctionAndLine` / `Tds_NameToRva_RoundTrips`
(reader, function + forward/reverse line round-trip) and
`DebugSessionTests.Tds_MainModule_LoadsExternalTds` / `Tds_StaleTds_Ignored` (loader
integration + the staleness gate). New target `TdsSample.dpr` built `-VT` (external
`.tds`, no embedded `.debug`) in build_target.bat + build_and_run.bat.

---

### Original investigation (kept for reference)

**Win64/dcc64 DOES emit external `.tds`** (the old "32-bit only" assumption was wrong).
`dcc64 --help` lists `-VT = Debug information in TDS` and `-VN = TDS symbols in
namespace`. Compiling a trivial program with `-VT -VN` produced a `tt.tds` whose
header is `46 42 30 39 ...` = **`FB09`** -- the SAME TD32/CodeView signature
`TD32FileReader` already looks for (`TD32_SIGNATURE = $39304246`). So `.tds` is the
exact same CodeView payload as the embedded `.debug` section, just written to a
standalone file (the whole file is the CV blob, `FB09` at offset 0).

Implementation recipe (a thin `TD32FileReader` variant, when a real `-VT` target
appears -- there is NO current consumer; every build here uses `-V` embedded):
- Add `LoadFromTdsFile(TdsPath, ExePath, OutputRvaShift)`. Map the `.tds` for the CV
  blob: set `FDebugBase` to the file start (skip the PE `.debug` lookup) and let
  `FindTD32Header`/`ReadDirectory`/`ParseAll*` run unchanged -- they already operate
  on `FDebugBase`.
- CAVEAT (found by reading the code): the CV line tables are SEGMENT-relative and the
  reader maps segment->RVA via `FSegmentVAs` / `FSecRvaStart/End`, which
  `FindDebugSection` builds from the **companion PE's section table** (line ~768). A
  standalone `.tds` has no section table, so the `.tds` path must still read the PE
  section headers from `ExePath` (the debugger always has the exe). So refactor
  `FindDebugSection` into (a) parse-PE-sections and (b) locate-debug-blob; the `.tds`
  path uses (a) on `ExePath` + file-as-blob instead of (b).
- Test target: build a fixture with `-VT` (strip/omit `-V`) so its debug info lives
  ONLY in the `.tds`, then reuse the TD32 reader assertions.
Low priority: speculative until a real target ships `-VT` binaries.

---

## Cross-cutting: "no debug info" diagnostic — DONE (2026-07-18)

The debugger now reports, once per module, when it can find NO debug info in ANY
supported format, instead of silently producing no lines/locals:
- **Runtime module** (`TModuleSymbolLoader.LoadModuleSymbols`): after probing every
  format, if `TModuleSymbols.HasAnySymbols` is false and no retry is pending, emits
  `No debug info for module <name> -- symbols unavailable (looked for embedded TD32 /
  .map / .rsm / .dcp / .jdbg)` (guarded by `NoSymbolsReported` so a per-stop sweep
  does not repeat it). Fires when execution first lands in the blind module
  (`EnsureModuleForPC`).
- **Main exe** (`LoadMainModule`): if no main provider registered
  (`FMainProviderCount = 0`), emits the same for the exe with a hint to build with
  `-V -VN -VR`.
Delivered through the loader's `OnConsole` sink. `TDebugSession` now wires that sink
by default (`HandleLoaderConsole`) to append to its debugger-output buffer +
`OnSessionOutput`, so BOTH frontends surface it: the DAP overrides `OnConsole` with
its own console-event sink; the MCP does not override, so the message (and other
loader notices: RSM/TD32/JCL load, stale-file warnings) now appears in
`get_debugger_output`. Regression:
`DebugSessionTests.MainModule_NoDebugInfo_ReportsDiagnostic` launches `NoDebugExe.exe`
(built with no debug switches) and asserts the message via `DrainDebuggerOutput` (the
exact MCP path).

Latent issue noted (NOT fixed -- pre-existing, out of scope): `ReleaseSymbolProviders`
recreates `FLoader` and re-wires only `OnSymbolsLoaded` + (now) `OnConsole`, dropping a
frontend's `ModuleClass` / `ShouldRetryModule` / `RequiresFor` / `OnLog` overrides. Not
triggered today because the MCP creates a fresh session per launch and the DAP runs one
session per adapter process. Fix later by preserving all loader hooks across the
recreate.

## JCL provider integration rules (recovered from the task journal, 2026-08-08)

Two constraints that are not optional, both learned from the adapter's threading
and range checking:

- `TJclBinDebugScanner` with `CacheData=True` lazily MUTATES its caches on the
  first query, so it must be lock-serialized and primed eagerly at load. The
  adapter queries providers from two threads.
- It must be range-guarded (`InModuleCodeRange`: answer only within
  `[shift, shift+ImageSize)` at or above the `$1000` code base), because JCL clamps
  an out-of-range address to a wrong symbol and range-errors under `{$R+}`. TD32
  and MAP bounds-check internally; JCL does not.
