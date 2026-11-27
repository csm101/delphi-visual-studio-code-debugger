unit RoutineAnalysis;

// The analysis of ONE routine's code: where its instructions start, which of
// its line records can be trusted, and what a patch written into it has to
// respect (docs/PROFILER_COVERAGE_PLAN.md, "Routine analysis").
//
// The routine is decoded by FOLLOWING CONTROL FLOW from proven places and never
// by starting at a line record: x86 decoding falls back into step within a few
// instructions, so a decode started in the middle of an instruction would
// "confirm" it. The proven places are
//
//   * the routine's entry, its direct branch targets and in-routine call
//     targets;
//   * the entries of the jump tables it recognises: dcc32's table directly
//     after the `jmp`, its byte-index form, and the hand-written forms found by
//     trying the routine's own address literals as table bases;
//   * x64: the functions `.pdata` lists inside the routine (its funclets) and
//     the blocks named by the scope and clause tables behind
//     `_DelphiExceptionHandler`;
//   * x86: the handler stubs found through their `push imm32`, the code or the
//     clause table at stub + 5 (where the RTL's handlers enter the routine, see
//     docs/EH_FORMAT_NOTES.md), and the continuation a `try..finally` pushes
//     for the `pop reg; jmp reg` that ends its finally block.
//
// What comes out, per routine: one flag word per byte (boundary, target,
// address reference, table, return address, unwinder window, handler entry),
// the call sites with their return addresses, the exits, the tables, and for
// every line record one of three verdicts -- CONFIRMED as a boundary, shown to
// be NOT CODE, or UNCONFIRMED. The last two are different claims and are never
// merged: a probe needs the first, a breakpoint is refused only on the second.
//
// The unit works on a file and on a live process alike: bytes come through a
// reader callback. It depends on CodeMap, Disassembler and ZydisApi and on
// nothing else of the engine: no session, no process handle. Zydis is optional
// at run time; without it every routine is reported "not analysed, decoder
// unavailable" and every record stays unconfirmed.
//
// An analyzer keeps scratch buffers between routines and is NOT thread safe:
// one analyzer per thread.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  CodeMap, Disassembler, ZydisApi;

const
  // One flag word per byte of an analysed routine (TRoutineAnalysis.Flags).
  /// <summary>First byte of an instruction a proven decode reached.</summary>
  rbfBoundary     = $0001;
  /// <summary>Any other byte of such an instruction.</summary>
  rbfInterior     = $0002;
  /// <summary>Control can arrive here other than by falling through: the
  /// entry, a branch or call target, a table entry, a handler entry.</summary>
  rbfTarget       = $0004;
  /// <summary>The address appears in the routine as an immediate or a
  /// displacement: a POSSIBLE target, never a place decoding started from.</summary>
  rbfAddressRef   = $0008;
  /// <summary>Inside a recognised jump table or its byte-index table.</summary>
  rbfJumpTable    = $0010;
  /// <summary>Inside an exception clause table.</summary>
  rbfClauseTable  = $0020;
  /// <summary>The instruction that ends here is a call.</summary>
  rbfReturnAddr   = $0040;
  /// <summary>x64: an instruction the system unwinder may read from a return
  /// address (the window of that address).</summary>
  rbfWindow       = $0080;
  /// <summary>An exception-handler entry: x64 funclet, <c>except</c> or
  /// <c>on</c> block; x86 handler stub, what follows it, clause block, the
  /// continuation of a <c>finally</c>.</summary>
  rbfHandlerEntry = $0100;
  /// <summary>x86: a handler stub (<c>jmp</c> to an RTL handler).</summary>
  rbfStub         = $0200;
  /// <summary>Target of a recognised jump-table entry.</summary>
  rbfTableEntry   = $0400;
  /// <summary>A line record of the routine names this address.</summary>
  rbfLine         = $0800;
  /// <summary>The instruction kind (<c>TRoutineInsnKind</c>) of a boundary
  /// byte is in the bits above this shift.</summary>
  rbfKindShift    = 12;
  /// <summary>Either kind of table.</summary>
  rbfData         = rbfJumpTable or rbfClauseTable;
  /// <summary>What ends a straight-line block and may not sit strictly inside
  /// a patched span.</summary>
  rbfBarrier      = rbfTarget or rbfAddressRef or rbfHandlerEntry or rbfTableEntry;

type
  /// <summary>What an analysed instruction does to control flow.</summary>
  TRoutineInsnKind = (
    /// <summary>Falls through.</summary>
    rikOther,
    /// <summary>Direct call.</summary>
    rikCall,
    /// <summary>Indirect or far call.</summary>
    rikCallIndirect,
    /// <summary>Direct unconditional jump.</summary>
    rikJump,
    /// <summary>Direct conditional jump (Jcc, LOOPx, JxCXZ).</summary>
    rikJumpConditional,
    /// <summary>Indirect jump the analysis could not explain.</summary>
    rikJumpIndirect,
    /// <summary><c>ret</c>, <c>retf</c>, <c>iret</c>.</summary>
    rikReturn,
    /// <summary><c>int3</c>.</summary>
    rikInt3,
    /// <summary><c>int n</c>, <c>into</c>, <c>hlt</c>, <c>ud2</c>.</summary>
    rikTrap,
    /// <summary>Indirect jump through a recognised table.</summary>
    rikJumpTable,
    /// <summary>Indirect jump through one fixed memory slot outside the
    /// routine: an import thunk or a procedure variable.</summary>
    rikJumpSlot,
    /// <summary>Far jump.</summary>
    rikJumpFar,
    /// <summary>x86: the <c>pop reg; jmp reg</c> that leaves a finally block.</summary>
    rikJumpFinally
  );

  /// <summary>Why a routine was not analysed completely.</summary>
  TRoutineIncompleteReason = (
    /// <summary>Zydis is not loaded: nothing was decoded.</summary>
    rirDecoderUnavailable,
    /// <summary>The routine's bytes could not be read.</summary>
    rirUnreadable,
    /// <summary>A byte on a proven path does not decode.</summary>
    rirUndecodable,
    /// <summary>Two proven decodes disagree about instruction boundaries, or a
    /// decode runs into a table.</summary>
    rirConflict,
    /// <summary>An instruction crosses the routine's end.</summary>
    rirCrossesEnd,
    /// <summary>An indirect jump that is neither through a recognised table,
    /// nor through a fixed slot, nor the x86 finally exit.</summary>
    rirIndirectJump,
    /// <summary>An exception table of the routine could not be read or does
    /// not have the expected shape, so its handler entries are unknown.</summary>
    rirHandlerTable
  );
  TRoutineIncompleteReasons = set of TRoutineIncompleteReason;

  /// <summary>What the analysis says about one line record.</summary>
  TLineVerdict = (
    /// <summary>A decode that started at a proven place arrives exactly here.</summary>
    lvConfirmed,
    /// <summary>Shown to be something else: inside an instruction, inside a
    /// table, on data.</summary>
    lvNotCode,
    /// <summary>Not reached, and nothing proves it either way. It can be
    /// perfectly good code.</summary>
    lvUnconfirmed
  );

  /// <summary>The reason behind a <c>TLineVerdict</c>.</summary>
  TLineVerdictReason = (
    /// <summary>Confirmed: an instruction boundary.</summary>
    lvrBoundary,
    /// <summary>Not code: inside an instruction a proven decode reached.</summary>
    lvrInsideInstruction,
    /// <summary>Not code: inside a recognised jump table.</summary>
    lvrInJumpTable,
    /// <summary>Not code: inside an exception clause table.</summary>
    lvrInClauseTable,
    /// <summary>Not code: not reached, and the byte there is zero, which no
    /// statement dcc32 or dcc64 compiles starts with.</summary>
    lvrZeroByte,
    /// <summary>Not code: not reached, and the bytes there are not an
    /// instruction.</summary>
    lvrUndecodable,
    /// <summary>Not code: the record is on the last line of its unit's own
    /// source file and outside every routine -- the unit's final <c>end.</c>
    /// (or an empty <c>finalization</c>), which has no code. Its bytes can
    /// decode: they are whatever follows the unit's last routine.</summary>
    lvrFinalEndOfUnit,
    /// <summary>Unconfirmed: follows an indirect jump.</summary>
    lvrAfterIndirectJump,
    /// <summary>Unconfirmed: follows a <c>ret</c> or an unconditional
    /// <c>jmp</c>, and no known branch leads to it.</summary>
    lvrAfterReturnOrJump,
    /// <summary>Unconfirmed: follows <c>int3</c>, <c>int n</c>, <c>hlt</c>,
    /// <c>ud2</c> or a far jump.</summary>
    lvrAfterTrap,
    /// <summary>Unconfirmed: the decode before it stopped (an undecodable
    /// byte, a conflict, a call that does not return).</summary>
    lvrAfterStoppedDecode,
    /// <summary>Unconfirmed: follows a recognised table.</summary>
    lvrAfterTable,
    /// <summary>Unconfirmed: nothing before it in the routine is proven.</summary>
    lvrNothingProvenBefore,
    /// <summary>Unconfirmed: outside every routine range, and on x64 outside
    /// every <c>.pdata</c> function too: nothing proves an entry.</summary>
    lvrOutsideEveryRoutine,
    /// <summary>Unconfirmed: the routine's bytes could not be read.</summary>
    lvrUnreadable,
    /// <summary>Unconfirmed: Zydis is not loaded.</summary>
    lvrDecoderUnavailable
  );

  /// <summary>What ends the first straight-line block of a line.</summary>
  TLineBlockEnd = (
    /// <summary>The record is not confirmed: it has no block.</summary>
    lbeNone,
    /// <summary>A direct call, included as the block's last instruction.</summary>
    lbeCall,
    /// <summary>An indirect call, included.</summary>
    lbeCallIndirect,
    /// <summary>A jump of any kind, included.</summary>
    lbeBranch,
    /// <summary>A <c>ret</c>, included.</summary>
    lbeReturn,
    /// <summary><c>int3</c> / <c>int n</c> / <c>hlt</c> / <c>ud2</c>, included.</summary>
    lbeTrap,
    /// <summary>The next address is one a branch can reach (or is named as an
    /// address): the block stops before it.</summary>
    lbeTarget,
    /// <summary>The next line record starts: the block stops before it.</summary>
    lbeNextLine,
    /// <summary>The bytes that follow are not proven instructions.</summary>
    lbeUnproven,
    /// <summary>The routine ends.</summary>
    lbeRoutineEnd
  );

  /// <summary>One line record of an analysed routine.</summary>
  TRoutineLine = record
    /// <summary>Index into <c>TModuleCodeMap.Lines</c>.</summary>
    LineIndex: Integer;
    /// <summary>Address of the record, module-relative.</summary>
    Rva: Cardinal;
    /// <summary>Confirmed, not code, or unconfirmed.</summary>
    Verdict: TLineVerdict;
    /// <summary>Why.</summary>
    Reason: TLineVerdictReason;
    /// <summary>Confirmed records only: one past the last instruction of the
    /// line's first straight-line block. Every instruction in
    /// <c>[Rva, BlockEndRva)</c> runs exactly once per entry into the line.</summary>
    BlockEndRva: Cardinal;
    /// <summary>What ended the block.</summary>
    BlockEnd: TLineBlockEnd;
  end;

  /// <summary>One call instruction of an analysed routine.</summary>
  TRoutineCallSite = record
    /// <summary>Address of the call instruction.</summary>
    CallRva: Cardinal;
    /// <summary>Address the callee returns to. May equal the routine's end.</summary>
    ReturnRva: Cardinal;
    /// <summary>True for a call through a register or memory.</summary>
    Indirect: Boolean;
    /// <summary>Direct calls: the target, module-relative (it can lie outside
    /// the image). -1 for an indirect call.</summary>
    TargetRva: Int64;
    /// <summary>x64: one past the last instruction of the window of the return
    /// address -- the optional <c>add rsp</c> / <c>lea rsp</c>, the
    /// <c>pop</c>s, and the one instruction after them. Equal to
    /// <c>ReturnRva</c> on x86, and where the return address is not a proven
    /// instruction.</summary>
    WindowEndRva: Cardinal;
  end;

  /// <summary>How control leaves through an exit instruction.</summary>
  TRoutineExitKind = (
    /// <summary><c>ret</c>.</summary>
    rekReturn,
    /// <summary>Direct jump to an address outside the routine.</summary>
    rekJump,
    /// <summary>Conditional jump to an address outside the routine.</summary>
    rekJumpConditional,
    /// <summary>Indirect jump through a fixed memory slot.</summary>
    rekJumpSlot,
    /// <summary>Indirect jump the analysis could not explain.</summary>
    rekJumpIndirect
  );

  /// <summary>What an exit instruction is to the routine.</summary>
  TRoutineExitRole = (
    /// <summary>An exit of the routine.</summary>
    rerRoutineExit,
    /// <summary>x86: the end of a finally block (<c>pop reg; jmp reg</c>, or a
    /// <c>ret</c> directly in front of a handler stub). It continues inside
    /// the routine or returns to the RTL: not an exit of the routine.</summary>
    rerFinallyExit,
    /// <summary>x64: inside a funclet. It returns to the unwinder or to the
    /// routine's body: not an exit of the routine.</summary>
    rerFuncletReturn,
    /// <summary>x86: a handler stub, the <c>jmp</c> to an RTL handler. Never
    /// executed by the routine itself.</summary>
    rerHandlerStub
  );

  /// <summary>One <c>ret</c> or leaving jump of an analysed routine.</summary>
  TRoutineExit = record
    /// <summary>Address of the instruction.</summary>
    Rva: Cardinal;
    /// <summary>The instruction.</summary>
    Kind: TRoutineExitKind;
    /// <summary>Whether it is an exit of the routine, and if not what it is.</summary>
    Role: TRoutineExitRole;
  end;

  /// <summary>How the entries of a jump table are stored.</summary>
  TRoutineTableKind = (
    /// <summary>32-bit absolute addresses.</summary>
    rtkAbsolute32,
    /// <summary>64-bit absolute addresses.</summary>
    rtkAbsolute64,
    /// <summary>32-bit offsets from a base.</summary>
    rtkRelative32
  );

  /// <summary>One recognised jump table.</summary>
  TRoutineJumpTable = record
    /// <summary>Address of the indirect jump.</summary>
    JumpRva: Cardinal;
    /// <summary>Address of the table of targets.</summary>
    TableRva: Cardinal;
    /// <summary>Number of entries.</summary>
    EntryCount: Integer;
    /// <summary>Entry format.</summary>
    Kind: TRoutineTableKind;
    /// <summary>True when the table starts right after the jump.</summary>
    DirectlyAfterJump: Boolean;
    /// <summary>Address of the byte-index table between the jump and the
    /// address table (dcc32's second form); 0 when there is none.</summary>
    IndexTableRva: Cardinal;
    /// <summary>Size of the byte-index table in bytes.</summary>
    IndexTableSize: Cardinal;
  end;

  /// <summary>What kind of exception-handler entry an address is.</summary>
  TRoutineHandlerKind = (
    /// <summary>x64: a function <c>.pdata</c> lists inside the routine (a funclet).</summary>
    rhkFunction,
    /// <summary>x64: the target of a <c>try..finally</c> scope entry.</summary>
    rhkFinally,
    /// <summary>x64: the block of a bare <c>except</c>, inside the body (scope
    /// entry with Handler 2).</summary>
    rhkExcept,
    /// <summary>x64: the handler of a <c>safecall</c> routine, a funclet of its
    /// own (scope entry with Handler 1).</summary>
    rhkSafecall,
    /// <summary>The block of an <c>on ... do</c> clause, from a clause table.</summary>
    rhkOnBlock,
    /// <summary>x86: a handler stub.</summary>
    rhkStub,
    /// <summary>x86: the code at stub + 5, where the RTL's handler enters.</summary>
    rhkAfterStub,
    /// <summary>x86: the continuation a <c>try..finally</c> pushes.</summary>
    rhkContinuation
  );

  /// <summary>Which RTL handler an x86 stub jumps to.</summary>
  TX86StubKind = (
    /// <summary>Not a stub.</summary>
    xskNone,
    /// <summary><c>System.@HandleFinally</c>: calls stub + 5.</summary>
    xskFinally,
    /// <summary><c>System.@HandleAnyException</c>: jumps to stub + 5.</summary>
    xskAnyException,
    /// <summary><c>System.@HandleOnException</c>: reads the clause table at
    /// stub + 5 and jumps to a block it names.</summary>
    xskOnException,
    /// <summary><c>System.@HandleAutoException</c>: jumps to stub + 5.</summary>
    xskAutoException,
    /// <summary>The code map does not name the target (a package reaches the
    /// RTL through import thunks).</summary>
    xskUnnamed
  );

  /// <summary>One exception-handler entry of an analysed routine.</summary>
  TRoutineHandlerEntry = record
    /// <summary>Address of the entry.</summary>
    Rva: Cardinal;
    /// <summary>What it is.</summary>
    Kind: TRoutineHandlerKind;
    /// <summary>For <c>rhkStub</c>: the RTL handler behind it.</summary>
    Stub: TX86StubKind;
  end;

  /// <summary>One exception clause table found inside an analysed routine.</summary>
  TRoutineClauseTable = record
    /// <summary>Address of the table (its count field).</summary>
    Rva: Cardinal;
    /// <summary>Number of clauses.</summary>
    Count: Integer;
  end;

  /// <summary>Everything the analysis says about one routine. Read-only once
  /// returned: do not modify the arrays.</summary>
  TRoutineAnalysis = record
    /// <summary>Index into <c>TModuleCodeMap.Routines</c>, or -1 for an x64
    /// function known from <c>.pdata</c> only (an anonymous-method body).</summary>
    RoutineIndex: Integer;
    /// <summary>First byte, module-relative.</summary>
    StartRva: Cardinal;
    /// <summary>One past the last byte analysed: the routine's end, or the
    /// next routine's start when the two ranges overlap.</summary>
    EndRva: Cardinal;
    /// <summary>True when the analysis finished: every proven path was
    /// decoded to its end. False keeps what was confirmed before the break and
    /// forbids every multi-byte patch in the routine.</summary>
    Complete: Boolean;
    /// <summary>Why not, when <c>Complete</c> is False.</summary>
    Incomplete: TRoutineIncompleteReasons;
    /// <summary>Where the first break was met; 0 when <c>Complete</c>.</summary>
    IncompleteAtRva: Cardinal;
    /// <summary>A proven path runs past the routine's end without a jump or a
    /// <c>ret</c> (a routine that ends in a call that does not return).
    /// Informational: it does not make the analysis incomplete.</summary>
    FallsOffEnd: Boolean;
    /// <summary>Number of instructions decoded.</summary>
    InstructionCount: Integer;
    /// <summary>x86: addresses of the routine pushed as an immediate that are
    /// neither a handler stub nor a continuation -- data, typically string
    /// literals.</summary>
    PushedDataCount: Integer;
    /// <summary>One flag word per byte, indexed by <c>Rva - StartRva</c>: the
    /// <c>rbf*</c> bits, and at a boundary the instruction kind.</summary>
    Flags: TArray<Word>;
    /// <summary>The routine's line records, by ascending address.</summary>
    Lines: TArray<TRoutineLine>;
    /// <summary>The call instructions, by ascending address.</summary>
    CallSites: TArray<TRoutineCallSite>;
    /// <summary>Every <c>ret</c> and every jump that leaves the routine, by
    /// ascending address.</summary>
    Exits: TArray<TRoutineExit>;
    /// <summary>The recognised jump tables.</summary>
    JumpTables: TArray<TRoutineJumpTable>;
    /// <summary>The exception-handler entries.</summary>
    HandlerEntries: TArray<TRoutineHandlerEntry>;
    /// <summary>The clause tables inside the routine.</summary>
    ClauseTables: TArray<TRoutineClauseTable>;
    /// <summary>Flag word of an address.</summary>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>The flags, or 0 for an address outside the routine.</returns>
    function FlagsAt(Rva: Cardinal): Word;
    /// <summary>Whether an address is the first byte of a proven instruction.</summary>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>True for a boundary.</returns>
    function IsBoundary(Rva: Cardinal): Boolean;
    /// <summary>Kind of the instruction at a boundary.</summary>
    /// <param name="Rva">Module-relative address of a boundary.</param>
    /// <returns>The kind; <c>rikOther</c> when the address is not a boundary.</returns>
    function KindAt(Rva: Cardinal): TRoutineInsnKind;
    /// <summary>Length of the instruction at a boundary.</summary>
    /// <param name="Rva">Module-relative address of a boundary.</param>
    /// <returns>The length in bytes, or 0 when the address is not a boundary.</returns>
    function InstructionLength(Rva: Cardinal): Integer;
    /// <summary>Index of the line record at an address.</summary>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>The index into <c>Lines</c>, or -1.</returns>
    function FindLine(Rva: Cardinal): Integer;
  end;

  /// <summary>The sources of proven places that can be switched off, to measure
  /// what each one buys and to show in a test that it is needed. Production
  /// code switches none off.</summary>
  TRoutineAnalysisRule = (
    /// <summary>A path ends after a call to a routine that never returns.</summary>
    rarNoReturnCalls,
    /// <summary>Jump tables are recognised and their entries followed.</summary>
    rarJumpTables,
    /// <summary>x86: <c>pop reg; jmp reg</c> in front of a handler stub is the
    /// end of a finally block.</summary>
    rarFinallyExit,
    /// <summary>x86: handler stubs, clause tables and finally continuations
    /// are found through the addresses the routine pushes.</summary>
    rarHandlerStubs,
    /// <summary>x64: the functions <c>.pdata</c> lists inside the routine and the
    /// blocks its scope and clause tables name are followed.</summary>
    rarExceptionTables
  );
  TRoutineAnalysisRules = set of TRoutineAnalysisRule;

  /// <summary>What an analyzer is built from.</summary>
  TRoutineAnalysisInput = record
    /// <summary>Machine mode of the module's code.</summary>
    Mode: TDisasmMachineMode;
    /// <summary>Reads the module's bytes by virtual address: a file mapped as
    /// an image, or a live process. A short read is an answer, not a failure.</summary>
    Reader: TDisasmByteReader;
    /// <summary>Address of the module's first byte in the reader's address
    /// space. It is also what the absolute addresses stored in the image are
    /// relative to: the preferred base for a file, the load address for a
    /// live module.</summary>
    ImageBase: UInt64;
    /// <summary>The module's code map. Not owned; must outlive the analyzer.</summary>
    CodeMap: TModuleCodeMap;
    /// <summary>x64: location of the exception directory (<c>.pdata</c>).
    /// Leave both fields 0 to have it read from the PE header through
    /// <c>Reader</c>.</summary>
    ExceptionDirRva: Cardinal;
    /// <summary>x64: size of the exception directory in bytes.</summary>
    ExceptionDirSize: Cardinal;
    /// <summary>x64, optional: addresses of language handlers known to be
    /// <c>_DelphiExceptionHandler</c>, as the UNWIND_INFO names them. Needed
    /// only when neither the code map nor the import table can name the
    /// handler (a live package whose import names are gone).</summary>
    DelphiHandlerRvas: TArray<Cardinal>;
    /// <summary>Optional: more routines that never return, besides the ones
    /// the code map names <c>Halt0</c>.</summary>
    NoReturnRvas: TArray<Cardinal>;
    /// <summary>Where Zydis.dll is; empty uses the normal search order.</summary>
    ZydisDllPath: string;
    /// <summary>Rules to leave out. Empty in production; a test or the sweep
    /// tool names one to see what breaks without it.</summary>
    DisabledRules: TRoutineAnalysisRules;
  end;

  /// <summary>An x64 function known from <c>.pdata</c> only, with line
  /// records that lie outside every routine of the code map.</summary>
  TUnmappedFunction = record
    /// <summary>First byte: the function's <c>BeginAddress</c>.</summary>
    StartRva: Cardinal;
    /// <summary>One past the last byte of the function and of the funclets
    /// that follow it.</summary>
    EndRva: Cardinal;
  end;

  /// <summary>Analyses the routines of one module.</summary>
  TRoutineAnalyzer = class
  private type
    TPendingCall = record
      Ofs: Integer;
      Indirect: Boolean;
      Target: Int64;
    end;
    TPendingExit = record
      Ofs: Integer;
      Kind: TRoutineExitKind;
    end;
    TMetaChunk = record
      Tag: Int64;
      Valid: Integer;
      Data: TArray<Byte>;
    end;
  private
    FInput:          TRoutineAnalysisInput;
    FMap:            TModuleCodeMap;
    FMode:           TZydisMachineMode;
    FIs64:           Boolean;
    FAvailable:      Boolean;
    FStatus:         string;
    FImageSize:      Cardinal;
    FImportDirRva:   Cardinal;
    // What the code map's names give: routines that never return, the x86 RTL
    // handlers a stub jumps to.
    FNoReturn:       TArray<Cardinal>;
    FStubTargets:    TDictionary<Cardinal, TX86StubKind>;
    FNoReturnSlots:  TArray<Cardinal>;
    FNoReturnThunks: TDictionary<Cardinal, Boolean>;
    FImports:        TDictionary<Cardinal, string>;
    FImportsLoaded:  Boolean;
    // x64 exception directory, sorted by FPdBegin. FPdParent is the entry
    // whose scope table names this one as a finally target (-1: not a funclet).
    FPdBegin:        TArray<Cardinal>;
    FPdEnd:          TArray<Cardinal>;
    FPdHandler:      TArray<Cardinal>;
    FPdData:         TArray<Cardinal>;
    FPdParent:       TArray<Integer>;
    FDelphiHandlers: TDictionary<Cardinal, Boolean>;
    FUnmapped:       TArray<TUnmappedFunction>;
    FUnmappedBuilt:  Boolean;
    FChunks:         array[0..7] of TMetaChunk;
    // Scratch of the routine being analysed. Offsets are relative to FS.
    FS, FE:          Cardinal;
    FLen:            Integer;
    FCode:           TArray<Byte>;
    FFlags:          TArray<Word>;
    FWork:           TArray<Integer>;
    FWorkCount:      Integer;
    FPendJumps:      TList<Integer>;
    FPendPushes:     TList<Integer>;
    FCalls:          TList<TPendingCall>;
    FExitList:       TList<TPendingExit>;
    FTables:         TList<TRoutineJumpTable>;
    FHandlers:       TList<TRoutineHandlerEntry>;
    FClauses:        TList<TRoutineClauseTable>;
    FLineIdx:        TList<Integer>;
    FWhy:            TRoutineIncompleteReasons;
    FWhyAt:          Cardinal;
    FFallsOffEnd:    Boolean;
    FInsnCount:      Integer;
    FUnreachedOfs:    Integer;
    FUnreachedBefore: TLineVerdictReason;
    function  VaOf(Rva: Int64): UInt64; inline;
    function  RvaOfVa(VA: UInt64): Int64; inline;
    function  InRoutine(Rva: Int64): Boolean; inline;
    function  ReadExact(Rva: Int64; Buf: Pointer; Size: Integer): Boolean;
    function  ReadMeta(Rva: Int64; Buf: Pointer; Size: Integer): Boolean;
    function  ReadU32(Rva: Int64; out Value: Cardinal): Boolean;
    function  ReadAnsiZ(Rva: Int64): string;
    procedure ReadPeDirectories;
    procedure IndexRoutineNames;
    procedure LoadImports;
    function  ThunkSlotAt(Rva: Int64; out SlotRva: Int64): Boolean;
    function  IsNoReturnTarget(TargetRva: Int64): Boolean;
    procedure LoadExceptionDirectory;
    function  IsDelphiHandler(HandlerRva: Cardinal): Boolean;
    procedure LinkFunclets;
    function  FirstPdataAtOrAfter(Rva: Cardinal): Integer;
    function  FindPdataContaining(Rva: Cardinal): Integer;
    function  FindPdataBeginningAt(Rva: Cardinal): Integer;
    function  RootFunction(Index: Integer): Integer;
    procedure BuildUnmapped;
    function  FindUnmapped(Rva: Cardinal): Integer;
    function  StrayLine(LineIndex: Integer; Rva: Cardinal): TRoutineLine;
    // --- one routine ---
    function  AnalyzeRange(RoutineIndex: Integer; StartRva, EndRva: Cardinal;
      FirstLine, LineCount: Integer; OutsideOnly: Boolean): TRoutineAnalysis;
    procedure NotAnalysed(var Analysis: TRoutineAnalysis; Why: TRoutineIncompleteReason;
      Reason: TLineVerdictReason);
    function  LoadRoutineBytes: Boolean;
    procedure CollectLines(FirstLine, LineCount: Integer; OutsideOnly: Boolean);
    procedure Fail(Why: TRoutineIncompleteReason; Ofs: Integer);
    procedure Seed(Ofs: Int64; Bits: Word);
    procedure SeedHandler(TargetRva: Int64; Kind: TRoutineHandlerKind;
      Stub: TX86StubKind = xskNone);
    function  DecodeAt(Ofs: Integer; out Detail: TZydisInstructionDetail): Boolean; inline;
    function  KindOf(Ofs: Integer): TRoutineInsnKind; inline;
    procedure SetKind(Ofs: Integer; Kind: TRoutineInsnKind); inline;
    function  LengthOf(Ofs: Integer): Integer;
    function  PreviousInstruction(Ofs: Integer; out Prev: Integer): Boolean;
    function  NamedAddresses(const Detail: TZydisInstructionDetail;
      out Addresses: TArray<Int64>): Integer;
    procedure NoteAddressRefs(const Detail: TZydisInstructionDetail);
    procedure Drain;
    procedure DrainWithTables;
    procedure SeedExceptionData;
    procedure SeedScopeTable(PdataIndex: Integer);
    function  ReadTable(TableOfs: Integer; Kind: TRoutineTableKind; RelBase: Int64;
      Targets: TList<Integer>): Integer;
    procedure ResolveIndirectJump(JumpOfs: Integer);
    function  LooksLikeClauseTable(Ofs: Integer; out Count: Integer): Boolean;
    function  StubKindOfTarget(Dest: Int64): TX86StubKind;
    function  ProcessPushes: Boolean;
    procedure ScanUnexplainedPointers;
    function  WindowEnd(ReturnOfs: Integer): Integer;
    procedure BuildCallSites(var Analysis: TRoutineAnalysis);
    procedure BuildExits(var Analysis: TRoutineAnalysis);
    procedure BuildLines(var Analysis: TRoutineAnalysis);
    function  UnreachedReason(Ofs: Integer; out Verdict: TLineVerdict): TLineVerdictReason;
    procedure FirstBlock(Ofs, LineEnd: Integer; IsLastLine: Boolean; var Line: TRoutineLine);
  public
    /// <summary>Prepares the analysis of one module: loads Zydis, indexes the
    /// names the analysis needs and, on x64, reads the exception directory.</summary>
    /// <param name="Input">Mode, reader, base and code map of the module.</param>
    /// <exception cref="EArgumentNilException">No reader or no code map.</exception>
    constructor Create(const Input: TRoutineAnalysisInput);
    destructor Destroy; override;
    /// <summary>Analyses one routine of the code map.</summary>
    /// <param name="RoutineIndex">Index into <c>TModuleCodeMap.Routines</c>.</param>
    /// <returns>The analysis. Without a decoder: not complete, every record
    /// unconfirmed.</returns>
    function Analyze(RoutineIndex: Integer): TRoutineAnalysis;
    /// <summary>x64: the functions <c>.pdata</c> knows that the code map does
    /// not and that hold line records -- the bodies of anonymous methods.</summary>
    /// <returns>The functions, by ascending address; empty on x86.</returns>
    function UnmappedFunctions: TArray<TUnmappedFunction>;
    /// <summary>x64: analyses one function known from <c>.pdata</c> only.</summary>
    /// <param name="Index">Index into <c>UnmappedFunctions</c>.</param>
    /// <returns>The analysis, with <c>RoutineIndex</c> -1.</returns>
    function AnalyzeUnmapped(Index: Integer): TRoutineAnalysis;
    /// <summary>The verdict for one line record, wherever it lies.</summary>
    /// <remarks>Analyses the whole routine the record belongs to; a caller that
    /// wants many records of one routine calls <c>Analyze</c> once instead.</remarks>
    /// <param name="LineIndex">Index into <c>TModuleCodeMap.Lines</c>.</param>
    /// <returns>The record with its verdict.</returns>
    function AnalyzeLine(LineIndex: Integer): TRoutineLine;
    /// <summary>The verdict for an arbitrary address of the module: the one of
    /// its line record when a record starts there, otherwise what the analysis
    /// of the routine holding the address shows about that byte.</summary>
    /// <remarks>This is what decides whether a breakpoint may be planted at an
    /// address that a line table names: a provider other than the code map's
    /// can name an address the code map has no record for. Analyses the whole
    /// routine, like <c>AnalyzeLine</c>.</remarks>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>The verdict and its reason; <c>LineIndex</c> is -1 when no
    /// line record of the code map starts at the address, and the block fields
    /// are filled for a line record only.</returns>
    function AnalyzeAddress(Rva: Cardinal): TRoutineLine;
    /// <summary>x64: the piece of code an address lies in, as <c>.pdata</c>
    /// divides a routine: its body, or one of its funclets (a <c>finally</c>
    /// block emitted a second time for the exception dispatch to call, the
    /// handler of a <c>safecall</c> routine).</summary>
    /// <param name="Rva">Module-relative address.</param>
    /// <param name="RegionStart">First byte of the <c>.pdata</c> function
    /// holding the address.</param>
    /// <param name="RootStart">First byte of the function that region belongs
    /// to, through nested funclets. Equal to <c>RegionStart</c> when the
    /// address is in the body itself; different when it is in a funclet.</param>
    /// <returns>False on x86, without a decoder, and for an address no
    /// <c>.pdata</c> function holds.</returns>
    function CodeRegionOf(Rva: Cardinal; out RegionStart, RootStart: Cardinal): Boolean;
    /// <summary>Whether Zydis is loaded. False makes every analysis report
    /// "decoder unavailable".</summary>
    property Available: Boolean read FAvailable;
    /// <summary>Why <c>Available</c> is False, or where the decoder loaded from.</summary>
    property StatusText: string read FStatus;
    /// <summary>True when the module is 64-bit code.</summary>
    property Is64: Boolean read FIs64;
    /// <summary>x64: number of <c>.pdata</c> entries read.</summary>
    function PdataCount: Integer;
    /// <summary>The import an address-table slot belongs to, read from the
    /// module's import directory.</summary>
    /// <param name="SlotRva">Module-relative address of the slot.</param>
    /// <returns><c>dll!name</c>, or an empty string when the slot is not an
    /// import or its name cannot be read (a live module without a lookup
    /// table).</returns>
    function ImportNameOfSlot(SlotRva: Int64): string;
    /// <summary>Whether a line record is a unit's final <c>end.</c> that has
    /// no code.</summary>
    /// <remarks>Decided without reading a source and without looking at a
    /// byte: the record lies outside every routine of the code map (and, on
    /// x64, outside every function <c>.pdata</c> knows); it is on the highest
    /// line of its source file that has a line record; no record on that line
    /// lies inside a routine; and the file is its unit's OWN source. The body
    /// of an anonymous method, which is outside every TD32 range as well,
    /// never qualifies: the <c>end;</c> of the routine around it comes later.
    /// The last condition keeps out code the compiler synthesises for another
    /// unit's generic or inline routine under a line number past the end of
    /// that file.</remarks>
    /// <param name="LineIndex">Index into <c>TModuleCodeMap.Lines</c>.</param>
    /// <returns>True for such a record.</returns>
    function IsFinalEndOfUnit(LineIndex: Integer): Boolean;
  end;

/// <summary>Display text of a verdict reason.</summary>
/// <param name="Reason">The reason.</param>
/// <returns>One line of English.</returns>
function LineVerdictReasonText(Reason: TLineVerdictReason): string;

/// <summary>Display text of an incompleteness reason.</summary>
/// <param name="Reason">The reason.</param>
/// <returns>One line of English.</returns>
function IncompleteReasonText(Reason: TRoutineIncompleteReason): string;

/// <summary>The verdict a reason belongs to.</summary>
/// <param name="Reason">The reason.</param>
/// <returns>Confirmed, not code, or unconfirmed.</returns>
function VerdictOfReason(Reason: TLineVerdictReason): TLineVerdict;

implementation

uses
  System.Generics.Defaults;

const
  META_CHUNK_BITS   = 16;
  META_CHUNK_SIZE   = 1 shl META_CHUNK_BITS;
  MAX_INSN_LENGTH   = 15;
  // A routine larger than this is not read: no compiler emits one, and the
  // scratch buffers are sized by it.
  MAX_ROUTINE_BYTES = 64 * 1024 * 1024;
  MAX_SCOPE_ENTRIES = 8192;
  MAX_CLAUSES_X64   = 4096;
  MAX_CLAUSES_X86   = 512;
  // How far back from an indirect jump the instructions are read for the
  // addresses they name (candidate table bases).
  JUMP_CONTEXT_INSNS = 8;
  MAX_INDEX_TABLE    = 4096;
  UNW_FLAG_EHANDLER  = 1;
  UNW_FLAG_UHANDLER  = 2;
  UNW_FLAG_CHAININFO = 4;
  RUNTIME_FUNCTION_SIZE = 12;
  // Bounds on what is read from an image, so that a damaged one ends a walk
  // instead of hanging it. Far above anything a linker emits.
  MAX_EXCEPTION_DIR_BYTES = 512 * 1024 * 1024;
  MAX_IMPORT_MODULES      = 16384;
  MAX_IMPORTS_PER_MODULE  = 1024 * 1024;

  KIND_MASK = Word($F) shl rbfKindShift;

  REASON_TEXT: array[TLineVerdictReason] of string = (
    'instruction boundary',
    'inside an instruction the proven decode reached',
    'inside a recognised jump table',
    'inside an exception clause table',
    'not reached, and the byte there is zero',
    'not reached, and the bytes there are not an instruction',
    'the last line of its file, outside every routine: the unit''s final end., which has no code',
    'not reached: follows an indirect jump',
    'not reached: follows a ret / unconditional jmp, no known branch to it',
    'not reached: follows int3 / int n / hlt / ud2 / far jump',
    'not reached: the decode before it stopped',
    'not reached: follows a recognised table',
    'not reached: nothing proven before it in the routine',
    'outside every routine range: nothing proves an entry',
    'the routine''s bytes could not be read',
    'decoder unavailable');

  INCOMPLETE_TEXT: array[TRoutineIncompleteReason] of string = (
    'decoder unavailable',
    'the routine''s bytes could not be read',
    'a byte that does not decode',
    'two proven decodes disagree about instruction boundaries',
    'an instruction crosses the routine end',
    'an indirect jump that is not a recognised table',
    'an exception table that could not be read');

function LineVerdictReasonText(Reason: TLineVerdictReason): string;
begin
  Result := REASON_TEXT[Reason];
end;

function IncompleteReasonText(Reason: TRoutineIncompleteReason): string;
begin
  Result := INCOMPLETE_TEXT[Reason];
end;

function VerdictOfReason(Reason: TLineVerdictReason): TLineVerdict;
begin
  case Reason of
    lvrBoundary:
      Result := lvConfirmed;
    lvrInsideInstruction, lvrInJumpTable, lvrInClauseTable, lvrZeroByte, lvrUndecodable,
    lvrFinalEndOfUnit:
      Result := lvNotCode;
  else
    Result := lvUnconfirmed;
  end;
end;

function StubKindOfName(const Name: string): TX86StubKind;
begin
  if Pos('HandleAnyException', Name) > 0 then
    Exit(xskAnyException);
  if Pos('HandleOnException', Name) > 0 then
    Exit(xskOnException);
  if Pos('HandleAutoException', Name) > 0 then
    Exit(xskAutoException);
  if Pos('HandleFinally', Name) > 0 then
    Exit(xskFinally);
  Result := xskUnnamed;
end;

{ TRoutineAnalysis }

function TRoutineAnalysis.FlagsAt(Rva: Cardinal): Word;
begin
  if (Rva < StartRva) or (Rva >= EndRva) or (Int64(Rva) - StartRva >= Length(Flags)) then
    Exit(0);
  Result := Flags[Rva - StartRva];
end;

function TRoutineAnalysis.IsBoundary(Rva: Cardinal): Boolean;
begin
  Result := FlagsAt(Rva) and rbfBoundary <> 0;
end;

function TRoutineAnalysis.KindAt(Rva: Cardinal): TRoutineInsnKind;
begin
  var Flag := FlagsAt(Rva);
  if Flag and rbfBoundary = 0 then
    Exit(rikOther);
  Result := TRoutineInsnKind(Flag shr rbfKindShift);
end;

function TRoutineAnalysis.InstructionLength(Rva: Cardinal): Integer;
begin
  if not IsBoundary(Rva) then
    Exit(0);
  Result := 1;
  var Ofs := Integer(Rva - StartRva);
  while (Ofs + Result < Length(Flags)) and (Flags[Ofs + Result] and rbfInterior <> 0) and
        (Flags[Ofs + Result] and rbfBoundary = 0) do
    Inc(Result);
end;

function TRoutineAnalysis.FindLine(Rva: Cardinal): Integer;
begin
  var Lo := 0;
  var Hi := High(Lines);
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if Lines[Mid].Rva = Rva then
      Exit(Mid);
    if Lines[Mid].Rva < Rva then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := -1;
end;

{ TRoutineAnalyzer: construction }

constructor TRoutineAnalyzer.Create(const Input: TRoutineAnalysisInput);
begin
  inherited Create;
  if not Assigned(Input.Reader) then
    raise EArgumentNilException.Create('TRoutineAnalyzer.Create: no byte reader');
  if Input.CodeMap = nil then
    raise EArgumentNilException.Create('TRoutineAnalyzer.Create: no code map');
  FInput := Input;
  FMap   := Input.CodeMap;
  FIs64  := Input.Mode = dmmLong64;
  if FIs64 then
    FMode := zmmLong64
  else
    FMode := zmmLegacy32;
  for var I := Low(FChunks) to High(FChunks) do
    FChunks[I].Tag := -1;

  FStubTargets    := TDictionary<Cardinal, TX86StubKind>.Create;
  FNoReturnThunks := TDictionary<Cardinal, Boolean>.Create;
  FImports        := TDictionary<Cardinal, string>.Create;
  FDelphiHandlers := TDictionary<Cardinal, Boolean>.Create;
  FPendJumps      := TList<Integer>.Create;
  FPendPushes     := TList<Integer>.Create;
  FCalls          := TList<TPendingCall>.Create;
  FExitList       := TList<TPendingExit>.Create;
  FTables         := TList<TRoutineJumpTable>.Create;
  FHandlers       := TList<TRoutineHandlerEntry>.Create;
  FClauses        := TList<TRoutineClauseTable>.Create;
  FLineIdx        := TList<Integer>.Create;

  FAvailable := ZydisTryLoad(Input.ZydisDllPath);
  FStatus    := ZydisStatusText;
  if not FAvailable then
    Exit;

  ReadPeDirectories;
  IndexRoutineNames;
  // Whether the module reaches System.@Halt0 through an import thunk: only a
  // module that imports it pays for looking at call targets.
  LoadImports;
  for var Pair in FImports do
    if Pos('Halt0', Pair.Value) > 0 then
      FNoReturnSlots := FNoReturnSlots + [Pair.Key];
  if FIs64 then begin
    LoadExceptionDirectory;
    LinkFunclets;
  end;
end;

destructor TRoutineAnalyzer.Destroy;
begin
  FLineIdx.Free;
  FClauses.Free;
  FHandlers.Free;
  FTables.Free;
  FExitList.Free;
  FCalls.Free;
  FPendPushes.Free;
  FPendJumps.Free;
  FDelphiHandlers.Free;
  FImports.Free;
  FNoReturnThunks.Free;
  FStubTargets.Free;
  inherited;
end;

function TRoutineAnalyzer.PdataCount: Integer;
begin
  Result := Length(FPdBegin);
end;

function TRoutineAnalyzer.VaOf(Rva: Int64): UInt64;
begin
  {$OVERFLOWCHECKS OFF}{$RANGECHECKS OFF}
  Result := FInput.ImageBase + UInt64(Rva);
  {$OVERFLOWCHECKS ON}{$RANGECHECKS ON}
end;

function TRoutineAnalyzer.RvaOfVa(VA: UInt64): Int64;
// Module-relative address of a VA. Wraps on purpose: an address below the base
// comes out negative, which every caller treats as "not in the routine".
begin
  {$OVERFLOWCHECKS OFF}{$RANGECHECKS OFF}
  Result := Int64(VA - FInput.ImageBase);
  {$OVERFLOWCHECKS ON}{$RANGECHECKS ON}
end;

function TRoutineAnalyzer.InRoutine(Rva: Int64): Boolean;
begin
  Result := (Rva >= FS) and (Rva < FE);
end;

{ TRoutineAnalyzer: reading }

function TRoutineAnalyzer.ReadExact(Rva: Int64; Buf: Pointer; Size: Integer): Boolean;
// Reads exactly Size bytes, asking again after a short read: a reader may stop
// at a page or section boundary.
begin
  if (Rva < 0) or (Size < 0) then
    Exit(False);
  var Done := 0;
  while Done < Size do begin
    var Got := FInput.Reader(VaOf(Rva + Done), PByte(Buf) + Done, Size - Done);
    if Got <= 0 then
      Exit(False);
    Inc(Done, Got);
  end;
  Result := True;
end;

function TRoutineAnalyzer.ReadMeta(Rva: Int64; Buf: Pointer; Size: Integer): Boolean;
// Small reads of tables (unwind data, scope and clause tables, imports) through
// a few cached 64 KB chunks: on a live process each uncached read is a system
// call, and these tables are read hundreds of thousands of times in address
// order.
begin
  if (Rva < 0) or (Size <= 0) then
    Exit(False);
  if Size > META_CHUNK_SIZE then
    Exit(ReadExact(Rva, Buf, Size));
  var Done := 0;
  while Done < Size do begin
    var At := Rva + Done;
    var Tag := At shr META_CHUNK_BITS;
    var Slot := Integer(Tag and High(FChunks));
    if FChunks[Slot].Tag <> Tag then begin
      if FChunks[Slot].Data = nil then
        SetLength(FChunks[Slot].Data, META_CHUNK_SIZE);
      FChunks[Slot].Tag   := Tag;
      FChunks[Slot].Valid := FInput.Reader(VaOf(Tag shl META_CHUNK_BITS),
        @FChunks[Slot].Data[0], META_CHUNK_SIZE);
      if FChunks[Slot].Valid < 0 then
        FChunks[Slot].Valid := 0;
    end;
    var InChunk := Integer(At and (META_CHUNK_SIZE - 1));
    var Count := FChunks[Slot].Valid - InChunk;
    // The chunk's readable prefix does not reach: a section boundary or an
    // unreadable page sits inside it. Ask for exactly these bytes instead.
    if Count <= 0 then
      Exit(ReadExact(At, PByte(Buf) + Done, Size - Done));
    if Count > Size - Done then
      Count := Size - Done;
    Move(FChunks[Slot].Data[InChunk], (PByte(Buf) + Done)^, Count);
    Inc(Done, Count);
  end;
  Result := True;
end;

function TRoutineAnalyzer.ReadU32(Rva: Int64; out Value: Cardinal): Boolean;
begin
  Value := 0;
  Result := ReadMeta(Rva, @Value, SizeOf(Value));
end;

function TRoutineAnalyzer.ReadAnsiZ(Rva: Int64): string;
var
  Raw: array[0..255] of AnsiChar;
begin
  Result := '';
  FillChar(Raw, SizeOf(Raw), 0);
  // The name may sit at the very end of its section: take what is there.
  var Count := SizeOf(Raw) - 1;
  while (Count > 0) and not ReadMeta(Rva, @Raw[0], Count) do
    Count := Count div 2;
  if Count = 0 then
    Exit;
  Raw[Count] := #0;
  Result := string(AnsiString(PAnsiChar(@Raw[0])));
end;

procedure TRoutineAnalyzer.ReadPeDirectories;
// Import and exception directories, from the header the reader maps at RVA 0.
var
  Header: array[0..7] of Cardinal;
begin
  var PeOffset: Cardinal;
  var Signature: Cardinal;
  var Magic: Word := 0;
  if not ReadU32($3C, PeOffset) then
    Exit;
  if (not ReadU32(PeOffset, Signature)) or (Signature <> $00004550) then
    Exit;
  var Optional: Int64 := Int64(PeOffset) + 24;
  if not ReadMeta(Optional, @Magic, SizeOf(Magic)) then
    Exit;
  ReadU32(Optional + 56, FImageSize);
  var Directories: Int64 := Optional + 96;
  if Magic = $020B then
    Directories := Optional + 112;
  // Entries 0..3: export, import, resource, exception -- RVA and size each.
  if not ReadMeta(Directories, @Header[0], SizeOf(Header)) then
    Exit;
  FImportDirRva := Header[2];
  if (FInput.ExceptionDirRva = 0) and (FInput.ExceptionDirSize = 0) then begin
    FInput.ExceptionDirRva  := Header[6];
    FInput.ExceptionDirSize := Header[7];
  end;
end;

procedure TRoutineAnalyzer.IndexRoutineNames;
// One pass over the code map's names for the few routines the analysis must
// recognise by name. Every wanted name contains "Ha", which filters the rest
// out with one search.
begin
  for var Rva in FInput.NoReturnRvas do
    FNoReturn := FNoReturn + [Rva];
  for var Rva in FInput.DelphiHandlerRvas do
    FDelphiHandlers.AddOrSetValue(Rva, True);
  var Routines := FMap.Routines;
  for var I := 0 to High(Routines) do begin
    var Name := Routines[I].Name;
    if Pos('Ha', Name) = 0 then
      Continue;
    var Start := Routines[I].StartRva;
    if Pos('Halt0', Name) > 0 then
      FNoReturn := FNoReturn + [Start]
    else if Pos('DelphiExceptionHandler', Name) > 0 then
      FDelphiHandlers.AddOrSetValue(Start, True)
    else if StubKindOfName(Name) <> xskUnnamed then
      FStubTargets.AddOrSetValue(Start, StubKindOfName(Name));
  end;
end;

procedure TRoutineAnalyzer.LoadImports;
// Import slot -> "dll!name", from the import directory. The names are read
// through the lookup table (OriginalFirstThunk); where a module has none the
// address table still holds them in a FILE and holds bound addresses in a live
// process, which the image-size test rejects.
begin
  if FImportsLoaded then
    Exit;
  FImportsLoaded := True;
  if FImportDirRva = 0 then
    Exit;
  var PtrSize := 4;
  if FIs64 then
    PtrSize := 8;
  var Descriptor: array[0..4] of Cardinal;
  var Index: Int64 := 0;
  // Bounded: a damaged directory must end the walk, not hang it.
  while (Index < MAX_IMPORT_MODULES) and
        ReadMeta(Int64(FImportDirRva) + Index * 20, @Descriptor[0], 20) do begin
    var LookupRva := Descriptor[0];
    var SlotsRva := Descriptor[4];
    if (LookupRva = 0) and (SlotsRva = 0) then
      Break;
    if LookupRva = 0 then
      LookupRva := SlotsRva;
    var Dll := ReadAnsiZ(Descriptor[3]);
    var Entry: Int64 := 0;
    while Entry < MAX_IMPORTS_PER_MODULE do begin
      var Value: UInt64 := 0;
      if not ReadMeta(Int64(LookupRva) + Entry * PtrSize, @Value, PtrSize) then
        Break;
      if Value = 0 then
        Break;
      var ByOrdinal := Value shr (PtrSize * 8 - 1) <> 0;
      var SlotRva: Int64 := Int64(SlotsRva) + Entry * PtrSize;
      // A name RVA lies inside the image. In a live module without a lookup
      // table these words are bound addresses, which do not.
      if (not ByOrdinal) and (FImageSize <> 0) and (Value < FImageSize) and (SlotRva <= High(Cardinal)) then
        FImports.AddOrSetValue(Cardinal(SlotRva), Dll + '!' + ReadAnsiZ(Int64(Value) + 2));
      Inc(Entry);
    end;
    Inc(Index);
  end;
end;

function TRoutineAnalyzer.ImportNameOfSlot(SlotRva: Int64): string;
begin
  Result := '';
  if (SlotRva < 0) or (SlotRva > High(Cardinal)) then
    Exit;
  LoadImports;
  FImports.TryGetValue(Cardinal(SlotRva), Result);
end;

function TRoutineAnalyzer.ThunkSlotAt(Rva: Int64; out SlotRva: Int64): Boolean;
// An import thunk: `jmp [slot]` (FF 25), with an optional REX.W on x64.
var
  Code: array[0..7] of Byte;
begin
  SlotRva := -1;
  if not ReadMeta(Rva, @Code[0], SizeOf(Code)) then
    Exit(False);
  var Skip := 0;
  if FIs64 and (Code[0] = $48) then
    Skip := 1;
  if (Code[Skip] <> $FF) or (Code[Skip + 1] <> $25) then
    Exit(False);
  var Disp := PInteger(@Code[Skip + 2])^;
  if FIs64 then
    SlotRva := Rva + Skip + 6 + Disp
  else
    SlotRva := RvaOfVa(Cardinal(Disp));
  Result := True;
end;

function TRoutineAnalyzer.IsNoReturnTarget(TargetRva: Int64): Boolean;
begin
  if rarNoReturnCalls in FInput.DisabledRules then
    Exit(False);
  for var Known in FNoReturn do
    if Known = TargetRva then
      Exit(True);
  if (FNoReturnSlots = nil) or (TargetRva < 0) or (TargetRva > High(Cardinal)) then
    Exit(False);
  // The module imports a routine that never returns: a call may reach it
  // through a thunk. One look per distinct target.
  if FNoReturnThunks.TryGetValue(Cardinal(TargetRva), Result) then
    Exit;
  Result := False;
  var SlotRva: Int64;
  if ThunkSlotAt(TargetRva, SlotRva) then
    for var Slot in FNoReturnSlots do
      if Slot = SlotRva then
        Result := True;
  FNoReturnThunks.Add(Cardinal(TargetRva), Result);
end;

{ TRoutineAnalyzer: the x64 exception directory }

procedure TRoutineAnalyzer.LoadExceptionDirectory;
type
  TRuntimeFunction = packed record
    BeginRva, EndRva, UnwindRva: Cardinal;
  end;
var
  Rows: TArray<TRuntimeFunction>;
  Head: array[0..3] of Byte;
begin
  if (FInput.ExceptionDirRva = 0) or (FInput.ExceptionDirSize > MAX_EXCEPTION_DIR_BYTES) then
    Exit;
  var Count := Integer(FInput.ExceptionDirSize div RUNTIME_FUNCTION_SIZE);
  if Count = 0 then
    Exit;
  SetLength(Rows, Count);
  if not ReadExact(FInput.ExceptionDirRva, @Rows[0], Count * RUNTIME_FUNCTION_SIZE) then
    Exit;

  // The directory is sorted by BeginAddress by contract; everything below
  // bisects, so that is verified and repaired rather than trusted.
  var Kept := 0;
  var InOrder := True;
  for var I := 0 to Count - 1 do begin
    if Rows[I].EndRva <= Rows[I].BeginRva then
      Continue;
    if (Kept > 0) and (Rows[I].BeginRva <= Rows[Kept - 1].BeginRva) then
      InOrder := False;
    Rows[Kept] := Rows[I];
    Inc(Kept);
  end;
  SetLength(Rows, Kept);
  if not InOrder then
    TArray.Sort<TRuntimeFunction>(Rows, TComparer<TRuntimeFunction>.Construct(
      function(const A, B: TRuntimeFunction): Integer
      begin
        if A.BeginRva < B.BeginRva then
          Exit(-1);
        if A.BeginRva > B.BeginRva then
          Exit(1);
        Result := 0;
      end));

  SetLength(FPdBegin, Kept);
  SetLength(FPdEnd, Kept);
  SetLength(FPdHandler, Kept);
  SetLength(FPdData, Kept);
  SetLength(FPdParent, Kept);
  for var I := 0 to Kept - 1 do begin
    FPdBegin[I]  := Rows[I].BeginRva;
    FPdEnd[I]    := Rows[I].EndRva;
    FPdParent[I] := -1;
    // UNWIND_INFO: version:3 | flags:5, prolog size, code count, frame
    // register; then the codes, padded to an even number of 2-byte slots; then
    // the language handler and its data (docs/EH_FORMAT_NOTES.md).
    if not ReadMeta(Rows[I].UnwindRva, @Head[0], SizeOf(Head)) then
      Continue;
    var UnwindFlags := Head[0] shr 3;
    if UnwindFlags and UNW_FLAG_CHAININFO <> 0 then
      Continue;
    if UnwindFlags and (UNW_FLAG_EHANDLER or UNW_FLAG_UHANDLER) = 0 then
      Continue;
    var AfterCodes: Int64 := Int64(Rows[I].UnwindRva) + 4 +
      ((Int64(Head[2]) + 1) and not Int64(1)) * 2;
    var Handler: Cardinal;
    if (not ReadU32(AfterCodes, Handler)) or (Handler = 0) or (AfterCodes + 4 > High(Cardinal)) then
      Continue;
    FPdHandler[I] := Handler;
    FPdData[I]    := Cardinal(AfterCodes + 4);
  end;
end;

function TRoutineAnalyzer.IsDelphiHandler(HandlerRva: Cardinal): Boolean;
// Only _DelphiExceptionHandler's data is a Delphi scope table. Under another
// language handler the same field means something else (docs/TRAPS.md), so the
// handler is identified by NAME: the code map's, or, for a module that reaches
// the RTL through an import thunk, the import's.
begin
  if FDelphiHandlers.TryGetValue(HandlerRva, Result) then
    Exit;
  Result := False;
  var Routine := FMap.FindRoutine(HandlerRva);
  if Routine >= 0 then
    Result := Pos('DelphiExceptionHandler', FMap.Routines[Routine].Name) > 0;
  var SlotRva: Int64;
  if (not Result) and ThunkSlotAt(HandlerRva, SlotRva) then
    Result := Pos('DelphiExceptionHandler', ImportNameOfSlot(SlotRva)) > 0;
  FDelphiHandlers.Add(HandlerRva, Result);
end;

procedure TRoutineAnalyzer.LinkFunclets;
// A funclet is a .pdata function of its own that a scope entry names as its
// Target: the finally funclet (Handler = 0) and the handler of a safecall
// routine (Handler = 1). Its `ret` returns to the unwinder, to the RTL or to
// the body that called it -- never to the routine's caller -- so the analysis
// must know which entries are funclets and of what.
var
  Entry: array[0..3] of Cardinal;
begin
  for var I := 0 to High(FPdBegin) do begin
    if (FPdHandler[I] = 0) or not IsDelphiHandler(FPdHandler[I]) then
      Continue;
    var Count: Cardinal;
    if (not ReadU32(FPdData[I], Count)) or (Count = 0) or (Count > MAX_SCOPE_ENTRIES) then
      Continue;
    for var K := 0 to Integer(Count) - 1 do begin
      if not ReadMeta(Int64(FPdData[I]) + 4 + Int64(K) * 16, @Entry[0], SizeOf(Entry)) then
        Break;
      // Handler 0 (finally) and 1 (the handler of a safecall routine) name a
      // funclet; 2 names a block inside the body, which is no function start.
      if (Entry[2] > 2) or (Entry[3] = 0) then
        Continue;
      var Funclet := FindPdataBeginningAt(Entry[3]);
      if (Funclet >= 0) and (Funclet <> I) then
        FPdParent[Funclet] := I;
    end;
  end;
end;

function TRoutineAnalyzer.FirstPdataAtOrAfter(Rva: Cardinal): Integer;
begin
  var Lo := 0;
  var Hi := Length(FPdBegin);
  while Lo < Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if FPdBegin[Mid] < Rva then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  Result := Lo;
end;

function TRoutineAnalyzer.FindPdataContaining(Rva: Cardinal): Integer;
begin
  Result := FirstPdataAtOrAfter(Rva);
  if (Result < Length(FPdBegin)) and (FPdBegin[Result] = Rva) then
    Exit;
  Dec(Result);
  if (Result < 0) or (Rva >= FPdEnd[Result]) then
    Result := -1;
end;

function TRoutineAnalyzer.FindPdataBeginningAt(Rva: Cardinal): Integer;
begin
  Result := FirstPdataAtOrAfter(Rva);
  if (Result >= Length(FPdBegin)) or (FPdBegin[Result] <> Rva) then
    Result := -1;
end;

function TRoutineAnalyzer.RootFunction(Index: Integer): Integer;
// The function a funclet belongs to, through nested finally blocks. Bounded:
// a damaged table must not loop.
begin
  Result := Index;
  for var Step := 1 to 64 do begin
    if FPdParent[Result] < 0 then
      Exit;
    Result := FPdParent[Result];
  end;
end;

procedure TRoutineAnalyzer.BuildUnmapped;
// Anonymous-method bodies have no procedure record in TD32, so their line
// records lie outside every routine of the code map. On x64 .pdata still names
// the function and its funclets, and that is where the analysis takes the
// entry from. One unmapped function is a root function plus the funclets that
// directly follow it.
begin
  if FUnmappedBuilt then
    Exit;
  FUnmappedBuilt := True;
  if Length(FPdBegin) = 0 then
    Exit;
  var Lines := FMap.Lines;
  var Found := TList<TUnmappedFunction>.Create;
  try
    var CoveredTo: Cardinal := 0;
    for var I := 0 to High(Lines) do begin
      if Lines[I].RoutineIndex >= 0 then
        Continue;
      var Rva := Lines[I].Rva;
      if Rva < CoveredTo then
        Continue;
      var Holder := FindPdataContaining(Rva);
      if Holder < 0 then
        Continue;
      var Root := RootFunction(Holder);
      if FMap.FindRoutine(FPdBegin[Root]) >= 0 then
        Root := Holder;
      var Last := Root;
      while (Last < High(FPdBegin)) and (FPdParent[Last + 1] >= 0) and
            (RootFunction(Last + 1) = Root) and (FMap.FindRoutine(FPdBegin[Last + 1]) < 0) do
        Inc(Last);
      if (Holder < Root) or (Holder > Last) then begin
        Root := Holder;
        Last := Holder;
      end;
      var Item: TUnmappedFunction;
      Item.StartRva := FPdBegin[Root];
      Item.EndRva   := FPdEnd[Root];
      for var K := Root + 1 to Last do
        if FPdEnd[K] > Item.EndRva then
          Item.EndRva := FPdEnd[K];
      // Never into a routine the code map knows.
      var NextRoutine := FMap.FindRoutine(Item.EndRva - 1);
      if (NextRoutine >= 0) and (FMap.Routines[NextRoutine].StartRva > Item.StartRva) then
        Item.EndRva := FMap.Routines[NextRoutine].StartRva;
      if (Found.Count > 0) and (Item.StartRva < Found.Last.EndRva) then
        Item.StartRva := Found.Last.EndRva;
      if Item.EndRva <= Item.StartRva then
        Continue;
      CoveredTo := Item.EndRva;
      Found.Add(Item);
    end;
    FUnmapped := Found.ToArray;
  finally
    Found.Free;
  end;
end;

function TRoutineAnalyzer.FindUnmapped(Rva: Cardinal): Integer;
begin
  BuildUnmapped;
  Result := -1;
  var Lo := 0;
  var Hi := High(FUnmapped);
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if FUnmapped[Mid].StartRva <= Rva then begin
      Result := Mid;
      Lo     := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if (Result >= 0) and (Rva >= FUnmapped[Result].EndRva) then
    Result := -1;
end;

function TRoutineAnalyzer.UnmappedFunctions: TArray<TUnmappedFunction>;
begin
  BuildUnmapped;
  Result := FUnmapped;
end;

{ TRoutineAnalyzer: entry points }

function TRoutineAnalyzer.Analyze(RoutineIndex: Integer): TRoutineAnalysis;
begin
  var Routines := FMap.Routines;
  var Routine := Routines[RoutineIndex];
  // An address belongs to the routine with the nearest start at or below it,
  // so nothing past the next start is this routine's (CodeMap.EffectiveEnd).
  var EndRva := Routine.EndRva;
  if (RoutineIndex < High(Routines)) and (Routines[RoutineIndex + 1].StartRva < EndRva) then
    EndRva := Routines[RoutineIndex + 1].StartRva;
  Result := AnalyzeRange(RoutineIndex, Routine.StartRva, EndRva, Routine.FirstLine,
    Routine.LineCount, False);
end;

function TRoutineAnalyzer.AnalyzeUnmapped(Index: Integer): TRoutineAnalysis;
begin
  BuildUnmapped;
  var Item := FUnmapped[Index];
  // Its records: the ones of the code map inside the range that no routine owns.
  var Lines := FMap.Lines;
  var Lo := 0;
  var Hi := Length(Lines);
  while Lo < Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if Lines[Mid].Rva < Item.StartRva then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  var Count := 0;
  while (Lo + Count < Length(Lines)) and (Lines[Lo + Count].Rva < Item.EndRva) do
    Inc(Count);
  Result := AnalyzeRange(-1, Item.StartRva, Item.EndRva, Lo, Count, True);
end;

function TRoutineAnalyzer.StrayLine(LineIndex: Integer; Rva: Cardinal): TRoutineLine;
// An address no routine and no .pdata function contains (LineIndex is its line
// record, or -1). Nothing proves an entry before it, so it cannot be confirmed;
// but bytes that are zero or are not an instruction show it is data.
var
  Code: array[0..MAX_INSN_LENGTH - 1] of Byte;
  Detail: TZydisInstructionDetail;
begin
  Result := Default(TRoutineLine);
  Result.LineIndex := LineIndex;
  Result.Rva       := Rva;
  Result.Verdict   := lvUnconfirmed;
  Result.Reason    := lvrOutsideEveryRoutine;
  if not FAvailable then begin
    Result.Reason := lvrDecoderUnavailable;
    Exit;
  end;
  FillChar(Code, SizeOf(Code), 0);
  var Got := FInput.Reader(VaOf(Rva), @Code[0], SizeOf(Code));
  if Got <= 0 then begin
    Result.Reason := lvrUnreadable;
    Exit;
  end;
  if Code[0] = 0 then
    Result.Reason := lvrZeroByte
  else if not ZydisDecodeDetail(FMode, VaOf(Rva), Code, Got, Detail) then
    Result.Reason := lvrUndecodable
  // Bytes that happen to decode say nothing: a third of the final `end.`
  // records of a large 32-bit image land on such bytes, right after the unit's
  // last routine. What the record IS decides.
  else if (LineIndex >= 0) and IsFinalEndOfUnit(LineIndex) then
    Result.Reason := lvrFinalEndOfUnit;
  Result.Verdict := VerdictOfReason(Result.Reason);
end;

function TRoutineAnalyzer.IsFinalEndOfUnit(LineIndex: Integer): Boolean;
begin
  Result := False;
  var Line := FMap.Lines[LineIndex];
  if Line.RoutineIndex >= 0 then
    Exit;
  if FMap.LastLineOutsideRoutines(Line.FileIndex) <> Line.Line then
    Exit;
  // The unit's OWN file. A line of another file recorded in this unit is an
  // instantiation of a generic or an inlined routine, and the compiler gives
  // some synthesised code of that kind a line number beyond the end of the
  // file it names: the highest "line" of that file, and real code.
  var OwnUnit := FMap.UnitName(Line.UnitIndex);
  if (OwnUnit = '') or not SameText(ChangeFileExt(FMap.Files[Line.FileIndex].Name, ''), OwnUnit) then
    Exit;
  // x64: a record inside a function .pdata lists is code with a proven entry.
  if FIs64 then
    for var Sibling in FMap.LinesAt(Line.FileIndex, Line.Line) do
      if FindPdataContaining(FMap.Lines[Sibling].Rva) >= 0 then
        Exit;
  Result := True;
end;

function TRoutineAnalyzer.AnalyzeLine(LineIndex: Integer): TRoutineLine;
begin
  var Line := FMap.Lines[LineIndex];
  var Analysis: TRoutineAnalysis;
  if Line.RoutineIndex >= 0 then
    Analysis := Analyze(Line.RoutineIndex)
  else begin
    var Unmapped := -1;
    if FIs64 and FAvailable then
      Unmapped := FindUnmapped(Line.Rva);
    if Unmapped < 0 then
      Exit(StrayLine(LineIndex, Line.Rva));
    Analysis := AnalyzeUnmapped(Unmapped);
  end;
  var Index := Analysis.FindLine(Line.Rva);
  if Index < 0 then
    Exit(StrayLine(LineIndex, Line.Rva));
  Result := Analysis.Lines[Index];
end;

function TRoutineAnalyzer.AnalyzeAddress(Rva: Cardinal): TRoutineLine;
begin
  var LineIndex := FMap.FindLine(Rva);
  if LineIndex >= 0 then
    Exit(AnalyzeLine(LineIndex));

  // No record of the code map starts here: the routine's flags answer.
  var Analysis: TRoutineAnalysis;
  var Routine := FMap.FindRoutine(Rva);
  if Routine >= 0 then
    Analysis := Analyze(Routine)
  else begin
    var Unmapped := -1;
    if FIs64 and FAvailable then
      Unmapped := FindUnmapped(Rva);
    if Unmapped < 0 then
      Exit(StrayLine(-1, Rva));
    Analysis := AnalyzeUnmapped(Unmapped);
  end;

  Result := Default(TRoutineLine);
  Result.LineIndex := -1;
  Result.Rva       := Rva;
  Result.Verdict   := lvUnconfirmed;
  Result.Reason    := lvrDecoderUnavailable;
  if not FAvailable then
    Exit;
  Result.Reason := lvrUnreadable;
  // Not analysed (unreadable, too large), or the address is past where the
  // routine stops owning addresses.
  if (Length(Analysis.Flags) = 0) or (Rva < Analysis.StartRva) or
     (Int64(Rva) - Analysis.StartRva >= Length(Analysis.Flags)) then
    Exit;
  var Flag := Analysis.Flags[Rva - Analysis.StartRva];
  if Flag and rbfBoundary <> 0 then
    Result.Reason := lvrBoundary
  else if Flag and rbfJumpTable <> 0 then
    Result.Reason := lvrInJumpTable
  else if Flag and rbfClauseTable <> 0 then
    Result.Reason := lvrInClauseTable
  else if Flag and rbfInterior <> 0 then
    Result.Reason := lvrInsideInstruction
  else begin
    // The scratch buffers still hold the routine just analysed.
    FUnreachedOfs := -1;
    Result.Reason := UnreachedReason(Integer(Rva - FS), Result.Verdict);
  end;
  Result.Verdict := VerdictOfReason(Result.Reason);
end;

function TRoutineAnalyzer.CodeRegionOf(Rva: Cardinal;
  out RegionStart, RootStart: Cardinal): Boolean;
begin
  RegionStart := 0;
  RootStart   := 0;
  if (not FIs64) or (Length(FPdBegin) = 0) then
    Exit(False);
  var Holder := FindPdataContaining(Rva);
  if Holder < 0 then
    Exit(False);
  RegionStart := FPdBegin[Holder];
  RootStart   := FPdBegin[RootFunction(Holder)];
  Result := True;
end;

{ TRoutineAnalyzer: one routine }

procedure TRoutineAnalyzer.NotAnalysed(var Analysis: TRoutineAnalysis;
  Why: TRoutineIncompleteReason; Reason: TLineVerdictReason);
begin
  Analysis.Complete   := False;
  Analysis.Incomplete := [Why];
  SetLength(Analysis.Lines, FLineIdx.Count);
  var Lines := FMap.Lines;
  for var I := 0 to FLineIdx.Count - 1 do begin
    Analysis.Lines[I] := Default(TRoutineLine);
    Analysis.Lines[I].LineIndex := FLineIdx[I];
    Analysis.Lines[I].Rva       := Lines[FLineIdx[I]].Rva;
    Analysis.Lines[I].Verdict   := lvUnconfirmed;
    Analysis.Lines[I].Reason    := Reason;
  end;
end;

procedure TRoutineAnalyzer.CollectLines(FirstLine, LineCount: Integer; OutsideOnly: Boolean);
begin
  FLineIdx.Clear;
  if (FirstLine < 0) or (LineCount <= 0) then
    Exit;
  var Lines := FMap.Lines;
  for var I := FirstLine to FirstLine + LineCount - 1 do begin
    if OutsideOnly and (Lines[I].RoutineIndex >= 0) then
      Continue;
    if not InRoutine(Lines[I].Rva) then
      Continue;
    FLineIdx.Add(I);
  end;
end;

function TRoutineAnalyzer.LoadRoutineBytes: Boolean;
begin
  if Length(FCode) < FLen + MAX_INSN_LENGTH + 1 then
    SetLength(FCode, FLen + MAX_INSN_LENGTH + 1 + FLen div 2);
  if Length(FFlags) < FLen + 1 then
    SetLength(FFlags, FLen + 1 + FLen div 2);
  if not ReadExact(FS, @FCode[0], FLen) then
    Exit(False);
  // Up to one instruction's worth past the end, so a decode at the last byte
  // sees what the processor would; zeros where nothing is mapped.
  FillChar(FCode[FLen], MAX_INSN_LENGTH + 1, 0);
  var Done := 0;
  while Done < MAX_INSN_LENGTH do begin
    var Got := FInput.Reader(VaOf(Int64(FE) + Done), @FCode[FLen + Done], MAX_INSN_LENGTH - Done);
    if Got <= 0 then
      Break;
    Inc(Done, Got);
  end;
  FillChar(FFlags[0], FLen * SizeOf(Word), 0);
  Result := True;
end;

function TRoutineAnalyzer.AnalyzeRange(RoutineIndex: Integer; StartRva, EndRva: Cardinal;
  FirstLine, LineCount: Integer; OutsideOnly: Boolean): TRoutineAnalysis;
begin
  Result := Default(TRoutineAnalysis);
  Result.RoutineIndex := RoutineIndex;
  Result.StartRva     := StartRva;
  Result.EndRva       := EndRva;
  FS := StartRva;
  FE := EndRva;
  if FE < FS then
    FE := FS;
  FLen := 0;
  CollectLines(FirstLine, LineCount, OutsideOnly);
  if not FAvailable then begin
    NotAnalysed(Result, rirDecoderUnavailable, lvrDecoderUnavailable);
    Exit;
  end;
  if FE = FS then begin
    Result.Complete := True;
    Exit;
  end;
  if Int64(FE) - FS > MAX_ROUTINE_BYTES then begin
    NotAnalysed(Result, rirUnreadable, lvrUnreadable);
    Exit;
  end;
  FLen := Integer(FE - FS);
  if not LoadRoutineBytes then begin
    NotAnalysed(Result, rirUnreadable, lvrUnreadable);
    Exit;
  end;

  FWorkCount   := 0;
  FWhy         := [];
  FWhyAt       := 0;
  FFallsOffEnd := False;
  FInsnCount   := 0;
  FPendJumps.Clear;
  FPendPushes.Clear;
  FCalls.Clear;
  FExitList.Clear;
  FTables.Clear;
  FHandlers.Clear;
  FClauses.Clear;
  var Lines := FMap.Lines;
  for var I := 0 to FLineIdx.Count - 1 do begin
    var Ofs := Integer(Lines[FLineIdx[I]].Rva - FS);
    FFlags[Ofs] := FFlags[Ofs] or rbfLine;
  end;

  // The entry, and through it every direct branch target and in-routine call
  // target.
  Seed(0, rbfTarget);
  Drain;
  // x64: the funclets and the blocks the exception tables name.
  if FIs64 and not (rarExceptionTables in FInput.DisabledRules) then begin
    SeedExceptionData;
    Drain;
  end;
  // Jump tables, each of which can uncover more of them.
  DrainWithTables;
  // x86: handler stubs, clause tables and finally continuations, found through
  // the addresses the routine pushes.
  if not FIs64 then begin
    if not (rarHandlerStubs in FInput.DisabledRules) then
      while ProcessPushes do
        DrainWithTables;
    Result.PushedDataCount := FPendPushes.Count;
    ScanUnexplainedPointers;
  end;

  Result.Complete         := FWhy = [];
  Result.Incomplete       := FWhy;
  Result.IncompleteAtRva  := FWhyAt;
  Result.FallsOffEnd      := FFallsOffEnd;
  Result.InstructionCount := FInsnCount;
  BuildCallSites(Result);
  BuildExits(Result);
  BuildLines(Result);
  Result.JumpTables     := FTables.ToArray;
  Result.HandlerEntries := FHandlers.ToArray;
  Result.ClauseTables   := FClauses.ToArray;
  SetLength(Result.Flags, FLen);
  Move(FFlags[0], Result.Flags[0], FLen * SizeOf(Word));
end;

procedure TRoutineAnalyzer.Fail(Why: TRoutineIncompleteReason; Ofs: Integer);
begin
  if FWhy = [] then
    FWhyAt := Cardinal(Int64(FS) + Ofs);
  Include(FWhy, Why);
end;

procedure TRoutineAnalyzer.Seed(Ofs: Int64; Bits: Word);
begin
  if (Ofs < 0) or (Ofs >= FLen) then
    Exit;
  FFlags[Ofs] := FFlags[Ofs] or Bits;
  if FWorkCount = Length(FWork) then
    SetLength(FWork, FWorkCount * 2 + 64);
  FWork[FWorkCount] := Integer(Ofs);
  Inc(FWorkCount);
end;

procedure TRoutineAnalyzer.SeedHandler(TargetRva: Int64; Kind: TRoutineHandlerKind;
  Stub: TX86StubKind);
begin
  if not InRoutine(TargetRva) then
    Exit;
  var Bits: Word := rbfTarget or rbfHandlerEntry;
  if Kind = rhkStub then
    Bits := Bits or rbfStub;
  Seed(TargetRva - FS, Bits);
  var Entry: TRoutineHandlerEntry;
  Entry.Rva  := Cardinal(TargetRva);
  Entry.Kind := Kind;
  Entry.Stub := Stub;
  FHandlers.Add(Entry);
end;

function TRoutineAnalyzer.DecodeAt(Ofs: Integer; out Detail: TZydisInstructionDetail): Boolean;
begin
  Result := ZydisDecodeDetail(FMode, VaOf(Int64(FS) + Ofs), FCode[Ofs], MAX_INSN_LENGTH, Detail);
end;

function TRoutineAnalyzer.KindOf(Ofs: Integer): TRoutineInsnKind;
begin
  Result := TRoutineInsnKind(FFlags[Ofs] shr rbfKindShift);
end;

procedure TRoutineAnalyzer.SetKind(Ofs: Integer; Kind: TRoutineInsnKind);
begin
  FFlags[Ofs] := (FFlags[Ofs] and not KIND_MASK) or Word(Ord(Kind) shl rbfKindShift);
end;

function TRoutineAnalyzer.LengthOf(Ofs: Integer): Integer;
// Length of the proven instruction at Ofs, from the flags.
begin
  Result := 1;
  while (Ofs + Result < FLen) and (FFlags[Ofs + Result] and (rbfInterior or rbfBoundary) = rbfInterior) do
    Inc(Result);
end;

function TRoutineAnalyzer.PreviousInstruction(Ofs: Integer; out Prev: Integer): Boolean;
// The proven instruction that ends exactly at Ofs, if there is one.
begin
  Prev := 0;
  for var Back := 1 to MAX_INSN_LENGTH do begin
    if Ofs - Back < 0 then
      Exit(False);
    var Flag := FFlags[Ofs - Back];
    if Flag and rbfBoundary <> 0 then begin
      Prev := Ofs - Back;
      Exit(LengthOf(Prev) = Back);
    end;
    if Flag and rbfInterior = 0 then
      Exit(False);
  end;
  Result := False;
end;

function TRoutineAnalyzer.NamedAddresses(const Detail: TZydisInstructionDetail;
  out Addresses: TArray<Int64>): Integer;
// The addresses of THIS routine an instruction names as a displacement or an
// immediate, module-relative. They are possible targets, and candidate table
// bases; never places to start decoding (a pushed in-range address is a string
// literal far more often than code).
var
  Found: array[0..3] of Int64;

  procedure Consider(Rva: Int64);
  begin
    if InRoutine(Rva) and (Result <= High(Found)) then begin
      Found[Result] := Rva;
      Inc(Result);
    end;
  end;

begin
  Result := 0;
  Addresses := nil;
  if Detail.IsRipRelative then
    Consider(RvaOfVa(Detail.MemoryTarget))
  else if Detail.DispSize = 32 then begin
    // x86: any 32-bit displacement can be an absolute address. x64: only one
    // with no base register is.
    if (not FIs64) or (Detail.HasSib and (Detail.ModRMMod = 0) and (Detail.SibBase = 5)) then
      Consider(RvaOfVa(Cardinal(Detail.DispValue and $FFFFFFFF)));
  end
  else if Detail.DispSize = 64 then
    Consider(RvaOfVa(UInt64(Detail.DispValue)));   // mov rax, [moffs64]
  for var I := 0 to 1 do begin
    if Detail.Imm[I].IsRelative then
      Continue;
    case Detail.Imm[I].Size of
      32: Consider(RvaOfVa(Detail.Imm[I].Value and $FFFFFFFF));
      64: Consider(RvaOfVa(Detail.Imm[I].Value));
    end;
  end;
  if Result = 0 then
    Exit;
  SetLength(Addresses, Result);
  for var I := 0 to Result - 1 do
    Addresses[I] := Found[I];
end;

procedure TRoutineAnalyzer.NoteAddressRefs(const Detail: TZydisInstructionDetail);
// Same extraction as NamedAddresses, without the array: this runs for every
// instruction of the module.

  procedure Mark(Rva: Int64; IsPush: Boolean);
  begin
    if not InRoutine(Rva) then
      Exit;
    var Ofs := Integer(Rva - FS);
    FFlags[Ofs] := FFlags[Ofs] or rbfAddressRef;
    if IsPush then
      FPendPushes.Add(Ofs);
  end;

begin
  if Detail.IsRipRelative then
    Mark(RvaOfVa(Detail.MemoryTarget), False)
  else if Detail.DispSize = 32 then begin
    if (not FIs64) or (Detail.HasSib and (Detail.ModRMMod = 0) and (Detail.SibBase = 5)) then
      Mark(RvaOfVa(Cardinal(Detail.DispValue and $FFFFFFFF)), False);
  end
  else if Detail.DispSize = 64 then
    Mark(RvaOfVa(UInt64(Detail.DispValue)), False);
  if Detail.Imm[0].Size = 0 then
    Exit;
  // x86 `push imm32` (68 id, no prefix) of an address of the routine: how a
  // handler stub and a finally continuation are named.
  var IsPush := (not FIs64) and (Detail.Opcode = $68) and (Detail.OpcodeMap = 0) and
    (Detail.Imm[0].Offset = 1);
  for var I := 0 to 1 do begin
    if Detail.Imm[I].IsRelative then
      Continue;
    case Detail.Imm[I].Size of
      32: Mark(RvaOfVa(Detail.Imm[I].Value and $FFFFFFFF), IsPush and (I = 0));
      64: Mark(RvaOfVa(Detail.Imm[I].Value), False);
    end;
  end;
end;

procedure TRoutineAnalyzer.Drain;
// Decodes from every pending seed until each path ends: at an instruction
// already decoded, a `ret`, an unconditional jump, a trap, the routine's end,
// or a break.
const
  KIND_OF: array[TZydisInstructionKind] of TRoutineInsnKind = (rikOther, rikCall,
    rikCallIndirect, rikJump, rikJumpConditional, rikJumpIndirect, rikJumpFar, rikReturn,
    rikInt3, rikTrap, rikTrap);
var
  Detail: TZydisInstructionDetail;
  PendingExit: TPendingExit;
  PendingCall: TPendingCall;
begin
  while FWorkCount > 0 do begin
    Dec(FWorkCount);
    var Ofs := FWork[FWorkCount];
    while True do begin
      if Ofs >= FLen then begin
        FFallsOffEnd := True;
        Break;
      end;
      var Flag := FFlags[Ofs];
      if Flag and rbfBoundary <> 0 then
        Break;
      if Flag and (rbfInterior or rbfData) <> 0 then begin
        Fail(rirConflict, Ofs);
        Break;
      end;
      if not DecodeAt(Ofs, Detail) then begin
        Fail(rirUndecodable, Ofs);
        Break;
      end;
      var Len: Integer := Detail.Length;
      var Next := Ofs + Len;
      if Next > FLen then begin
        Fail(rirCrossesEnd, Ofs);
        Break;
      end;
      var Clash := False;
      for var K := Ofs + 1 to Next - 1 do
        if FFlags[K] and (rbfBoundary or rbfInterior or rbfData) <> 0 then
          Clash := True;
      if Clash then begin
        Fail(rirConflict, Ofs);
        Break;
      end;
      FFlags[Ofs] := (Flag and not KIND_MASK) or rbfBoundary or
        Word(Ord(KIND_OF[Detail.Kind]) shl rbfKindShift);
      for var K := Ofs + 1 to Next - 1 do
        FFlags[K] := FFlags[K] or rbfInterior;
      Inc(FInsnCount);
      if (Detail.DispSize <> 0) or (Detail.Imm[0].Size <> 0) then
        NoteAddressRefs(Detail);

      var Stop := False;
      case Detail.Kind of
        zikCallDirect, zikCallIndirect: begin
          if Next < FLen then
            FFlags[Next] := FFlags[Next] or rbfReturnAddr;
          PendingCall.Ofs      := Ofs;
          PendingCall.Indirect := Detail.Kind = zikCallIndirect;
          PendingCall.Target   := -1;
          if Detail.HasBranchTarget then begin
            var Target := RvaOfVa(Detail.BranchTarget);
            PendingCall.Target := Target;
            if InRoutine(Target) then
              Seed(Target - FS, rbfTarget)
            // What follows a call that never returns is not code: the call
            // that ends a program's main block is followed by data.
            else if IsNoReturnTarget(Target) then
              Stop := True;
          end;
          FCalls.Add(PendingCall);
        end;
        zikJumpDirect, zikJumpConditional: begin
          var Target := RvaOfVa(Detail.BranchTarget);
          if InRoutine(Target) and Detail.HasBranchTarget then
            Seed(Target - FS, rbfTarget)
          else begin
            PendingExit.Ofs  := Ofs;
            PendingExit.Kind := rekJump;
            if Detail.Kind = zikJumpConditional then
              PendingExit.Kind := rekJumpConditional;
            FExitList.Add(PendingExit);
          end;
          Stop := Detail.Kind = zikJumpDirect;
        end;
        zikJumpIndirect: begin
          FPendJumps.Add(Ofs);
          Stop := True;
        end;
        zikReturn: begin
          PendingExit.Ofs  := Ofs;
          PendingExit.Kind := rekReturn;
          FExitList.Add(PendingExit);
          Stop := True;
        end;
        zikInt3, zikInterrupt, zikHalt, zikJumpFar:
          Stop := True;
      end;
      if Stop then
        Break;
      Ofs := Next;
    end;
  end;
end;

procedure TRoutineAnalyzer.DrainWithTables;
begin
  Drain;
  while FPendJumps.Count > 0 do begin
    var JumpOfs := FPendJumps.Last;
    FPendJumps.Delete(FPendJumps.Count - 1);
    ResolveIndirectJump(JumpOfs);
    Drain;
  end;
end;

procedure TRoutineAnalyzer.SeedExceptionData;
// x64: every function .pdata lists inside the routine is a proven entry (the
// routine's funclets), and so is every block its scope and clause tables name.
begin
  var Index := FirstPdataAtOrAfter(FS);
  while (Index < Length(FPdBegin)) and (FPdBegin[Index] < FE) do begin
    if FPdBegin[Index] > FS then
      SeedHandler(FPdBegin[Index], rhkFunction);
    if (FPdHandler[Index] <> 0) and IsDelphiHandler(FPdHandler[Index]) then
      SeedScopeTable(Index);
    Inc(Index);
  end;
end;

procedure TRoutineAnalyzer.SeedScopeTable(PdataIndex: Integer);
// The scope table behind _DelphiExceptionHandler (docs/EH_FORMAT_NOTES.md):
// Count x { Begin, End, Handler, Target }. Handler 0 is a finally whose funclet
// is Target, 1 the handler funclet of a safecall routine, 2 a bare except whose
// block (inside the body) is Target, anything else the RVA of a clause table:
// Count x { class VMT, block }.
var
  Entry: array[0..3] of Cardinal;
begin
  var Data: Int64 := FPdData[PdataIndex];
  var Count: Cardinal;
  if (not ReadU32(Data, Count)) or (Count = 0) or (Count > MAX_SCOPE_ENTRIES) then begin
    Fail(rirHandlerTable, 0);
    Exit;
  end;
  for var I := 0 to Integer(Count) - 1 do begin
    if not ReadMeta(Data + 4 + Int64(I) * 16, @Entry[0], SizeOf(Entry)) then begin
      Fail(rirHandlerTable, 0);
      Exit;
    end;
    var Handler := Entry[2];
    var Target := Entry[3];
    if Handler = 0 then begin
      SeedHandler(Target, rhkFinally);
      Continue;
    end;
    if Handler = 1 then begin
      SeedHandler(Target, rhkSafecall);
      Continue;
    end;
    if Handler = 2 then begin
      SeedHandler(Target, rhkExcept);
      Continue;
    end;
    var Clauses: Cardinal;
    if (not ReadU32(Handler, Clauses)) or (Clauses = 0) or (Clauses > MAX_CLAUSES_X64) then begin
      Fail(rirHandlerTable, 0);
      Continue;
    end;
    var TableEnd: Int64 := Int64(Handler) + 4 + Int64(Clauses) * 8;
    if InRoutine(Handler) and (TableEnd <= FE) then begin
      var Item: TRoutineClauseTable;
      Item.Rva   := Handler;
      Item.Count := Integer(Clauses);
      FClauses.Add(Item);
      for var Ofs := Integer(Handler - FS) to Integer(TableEnd - FS) - 1 do begin
        if FFlags[Ofs] and (rbfBoundary or rbfInterior) <> 0 then
          Fail(rirConflict, Ofs);
        FFlags[Ofs] := FFlags[Ofs] or rbfClauseTable;
      end;
    end;
    for var K := 0 to Integer(Clauses) - 1 do begin
      var Block: Cardinal;
      if not ReadU32(Int64(Handler) + 8 + Int64(K) * 8, Block) then begin
        Fail(rirHandlerTable, 0);
        Break;
      end;
      SeedHandler(Block, rhkOnBlock);
    end;
  end;
end;

function TRoutineAnalyzer.ReadTable(TableOfs: Integer; Kind: TRoutineTableKind;
  RelBase: Int64; Targets: TList<Integer>): Integer;
// Reads a jump table for as long as its entries land inside the routine. The
// table cannot run into code a proven decode already reached, nor into the
// lowest of its own targets above it.
begin
  Targets.Clear;
  var EntrySize := 4;
  if Kind = rtkAbsolute64 then
    EntrySize := 8;
  var Limit := FLen;
  var At := TableOfs;
  while (At >= 0) and (At + EntrySize <= Limit) do begin
    if FFlags[At] and (rbfBoundary or rbfInterior) <> 0 then
      Break;
    var Target: Int64;
    case Kind of
      rtkAbsolute32: Target := RvaOfVa(PCardinal(@FCode[At])^);
      rtkAbsolute64: Target := RvaOfVa(PUInt64(@FCode[At])^);
    else
      Target := RelBase + PInteger(@FCode[At])^;
    end;
    if not InRoutine(Target) then
      Break;
    var TargetOfs := Integer(Target - FS);
    if (TargetOfs >= TableOfs) and (TargetOfs < At + EntrySize) then
      Break;
    if FFlags[TargetOfs] and (rbfInterior or rbfData) <> 0 then
      Break;
    Targets.Add(TargetOfs);
    if (TargetOfs > At) and (TargetOfs < Limit) then
      Limit := TargetOfs;
    Inc(At, EntrySize);
  end;
  Result := Targets.Count;
end;

procedure TRoutineAnalyzer.ResolveIndirectJump(JumpOfs: Integer);
// Decides what an indirect jump is: a jump through one fixed slot (an import
// thunk, a procedure variable), the x86 finally exit, a jump through a table
// this unit recognises -- or none of them, which breaks the analysis.
var
  Detail, Before: TZydisInstructionDetail;
  PendingExit: TPendingExit;
begin
  if not DecodeAt(JumpOfs, Detail) then
    Exit;
  var After := JumpOfs + Detail.Length;
  PendingExit.Ofs := JumpOfs;

  // jmp [disp32] / jmp [rip+disp32]: one slot, no index. Outside the routine it
  // holds a pointer to somewhere else and the jump leaves.
  if Detail.HasModRM and (Detail.ModRMMod = 0) and (Detail.ModRMRm = 5) then begin
    var SlotRva: Int64;
    if FIs64 then
      SlotRva := RvaOfVa(Detail.MemoryTarget)
    else
      SlotRva := RvaOfVa(Cardinal(Detail.DispValue and $FFFFFFFF));
    if not InRoutine(SlotRva) then begin
      SetKind(JumpOfs, rikJumpSlot);
      PendingExit.Kind := rekJumpSlot;
      FExitList.Add(PendingExit);
      Exit;
    end;
  end;

  // x86: `pop reg; jmp reg` directly in front of a handler stub is how dcc32
  // leaves a finally block. Not a table and not a routine exit: the address
  // popped is the continuation the try pushed, or the RTL's return address
  // when the block was called by System.@HandleFinally. Tested first because
  // it is a fifth of all routines and needs one look back, not eight.
  var PopBefore: Integer;
  if (not FIs64) and not (rarFinallyExit in FInput.DisabledRules) and
     (Detail.ModRMMod = 3) and PreviousInstruction(JumpOfs, PopBefore) and
     (LengthOf(PopBefore) = 1) and (FCode[PopBefore] = $58 + Detail.ModRMRm) and
     (FCode[After] = $E9) then begin
    var Dest := (Int64(FS) + After + 5 + PInteger(@FCode[After + 1])^) and $FFFFFFFF;
    if not InRoutine(Dest) then begin
      SetKind(JumpOfs, rikJumpFinally);
      // Its role is decided once every stub is known (BuildExits).
      PendingExit.Kind := rekJumpIndirect;
      FExitList.Add(PendingExit);
      Exit;
    end;
  end;

  if rarJumpTables in FInput.DisabledRules then begin
    Fail(rirIndirectJump, JumpOfs);
    PendingExit.Kind := rekJumpIndirect;
    FExitList.Add(PendingExit);
    Exit;
  end;

  var Candidates := TList<Integer>.Create;
  var Targets := TList<Integer>.Create;
  var Best := TList<Integer>.Create;
  try
    // The instructions in front of the jump: the routine addresses they name
    // are candidate table bases, and the one directly in front says whether a
    // byte index is loaded from the address right after the jump.
    var Cursor := JumpOfs;
    var ByteLoad := -1;
    for var K := 1 to JUMP_CONTEXT_INSNS do begin
      var Prev: Integer;
      if not PreviousInstruction(Cursor, Prev) then
        Break;
      if KindOf(Prev) in [rikJump, rikReturn, rikJumpIndirect, rikJumpTable, rikJumpSlot,
                          rikJumpFinally, rikInt3, rikTrap, rikJumpFar] then
        Break;
      var Named: TArray<Int64>;
      if DecodeAt(Prev, Before) and (NamedAddresses(Before, Named) > 0) then
        for var Rva in Named do begin
          var Ofs := Integer(Rva - FS);
          if not Candidates.Contains(Ofs) then
            Candidates.Add(Ofs);
          if K = 1 then
            ByteLoad := Ofs;
        end;
      Cursor := Prev;
    end;

    var Found := False;
    var TableOfs := 0;
    var TableKind := rtkAbsolute32;
    // x86: jmp dword ptr [index*4 + table], both forms dcc32 emits.
    if (not FIs64) and (Detail.ModRMMod = 0) and (Detail.ModRMRm = 4) and Detail.HasSib and
       (Detail.SibBase = 5) and (Detail.SibScale = 2) then begin
      var Table := RvaOfVa(Cardinal(Detail.DispValue and $FFFFFFFF));
      if InRoutine(Table) and (ReadTable(Integer(Table - FS), rtkAbsolute32, 0, Best) >= 1) then begin
        Found := True;
        TableOfs := Integer(Table - FS);
      end;
    end;
    // Anything else (hand-written assembly): every candidate address as a
    // table, against every base an entry could be relative to.
    if not Found then begin
      if not Candidates.Contains(After) then
        Candidates.Add(After);
      for var Table in Candidates do begin
        if not FIs64 then begin
          if (ReadTable(Table, rtkAbsolute32, 0, Targets) >= 2) and (Targets.Count > Best.Count) then begin
            Best.Clear;
            Best.AddRange(Targets);
            TableOfs  := Table;
            TableKind := rtkAbsolute32;
          end;
          Continue;
        end;
        if (ReadTable(Table, rtkAbsolute64, 0, Targets) >= 2) and (Targets.Count > Best.Count) then begin
          Best.Clear;
          Best.AddRange(Targets);
          TableOfs  := Table;
          TableKind := rtkAbsolute64;
        end;
        // Relative to: each candidate, the routine start, the image base (RVAs).
        for var BaseIndex := 0 to Candidates.Count + 1 do begin
          var RelBase: Int64 := 0;
          if BaseIndex < Candidates.Count then
            RelBase := Int64(FS) + Candidates[BaseIndex]
          else if BaseIndex = Candidates.Count then
            RelBase := FS;
          if (ReadTable(Table, rtkRelative32, RelBase, Targets) >= 2) and (Targets.Count > Best.Count) then begin
            Best.Clear;
            Best.AddRange(Targets);
            TableOfs  := Table;
            TableKind := rtkRelative32;
          end;
        end;
      end;
      Found := Best.Count >= 2;
    end;

    if not Found then begin
      Fail(rirIndirectJump, JumpOfs);
      PendingExit.Kind := rekJumpIndirect;
      FExitList.Add(PendingExit);
      Exit;
    end;

    var EntrySize := 4;
    if TableKind = rtkAbsolute64 then
      EntrySize := 8;
    for var Ofs := TableOfs to TableOfs + Best.Count * EntrySize - 1 do
      FFlags[Ofs] := FFlags[Ofs] or rbfJumpTable;
    var Table: TRoutineJumpTable;
    Table := Default(TRoutineJumpTable);
    Table.JumpRva           := Cardinal(Int64(FS) + JumpOfs);
    Table.TableRva          := Cardinal(Int64(FS) + TableOfs);
    Table.EntryCount        := Best.Count;
    Table.Kind              := TableKind;
    Table.DirectlyAfterJump := TableOfs = After;
    // dcc32's two-level form: a byte index table between the jump and the
    // address table, loaded by `movzx reg, byte ptr [reg+idx]` or
    // `mov reg8, [reg+idx]` with idx the address right after the jump.
    if (not FIs64) and (TableKind = rtkAbsolute32) and (ByteLoad = After) and (After < TableOfs) and
       (TableOfs - After <= MAX_INDEX_TABLE) then begin
      for var Ofs := After to TableOfs - 1 do
        FFlags[Ofs] := FFlags[Ofs] or rbfJumpTable;
      Table.IndexTableRva  := Cardinal(Int64(FS) + After);
      Table.IndexTableSize := Cardinal(TableOfs - After);
    end;
    FTables.Add(Table);
    SetKind(JumpOfs, rikJumpTable);
    for var Target in Best do
      Seed(Target, rbfTarget or rbfTableEntry);
  finally
    Best.Free;
    Targets.Free;
    Candidates.Free;
  end;
end;

function TRoutineAnalyzer.LooksLikeClauseTable(Ofs: Integer; out Count: Integer): Boolean;
// x86: DWORD count, then count pairs { class VMT VA, block VA } whose block is
// an address of the routine (docs/EH_FORMAT_NOTES.md).
begin
  Result := False;
  Count := 0;
  if Ofs + 4 > FLen then
    Exit;
  var Raw := PCardinal(@FCode[Ofs])^;
  if (Raw = 0) or (Raw > MAX_CLAUSES_X86) then
    Exit;
  if Int64(Ofs) + 4 + Int64(Raw) * 8 > FLen then
    Exit;
  for var K := 0 to Integer(Raw) - 1 do
    if not InRoutine(RvaOfVa(PCardinal(@FCode[Ofs + 8 + K * 8])^)) then
      Exit;
  Count := Integer(Raw);
  Result := True;
end;

function TRoutineAnalyzer.StubKindOfTarget(Dest: Int64): TX86StubKind;
// Which RTL handler a stub's jump reaches: by the code map's name for the
// target, or, in a module that reaches the RTL through import thunks, by the
// import's name. One look per distinct target.
begin
  if (Dest < 0) or (Dest > High(Cardinal)) then
    Exit(xskUnnamed);
  if FStubTargets.TryGetValue(Cardinal(Dest), Result) then
    Exit;
  Result := xskUnnamed;
  var SlotRva: Int64;
  if ThunkSlotAt(Dest, SlotRva) then
    Result := StubKindOfName(ImportNameOfSlot(SlotRva));
  FStubTargets.Add(Cardinal(Dest), Result);
end;

function TRoutineAnalyzer.ProcessPushes: Boolean;
// x86: what a `push imm32` of an address of the routine leads to. Either a
// handler stub -- an `E9` jump out of the routine, to an RTL handler -- followed
// by what that handler enters: the clause table for System.@HandleOnException,
// code at stub + 5 for the others (the RTL calls it for a finally and jumps to
// it for a bare except, docs/EH_FORMAT_NOTES.md). Or the continuation a
// try..finally pushes for the jump that ends its finally block. Any other
// pushed address of the routine is data in its range and is left alone.
begin
  Result := False;
  // Stubs first: a continuation is recognised by the stub in front of it.
  for var Pass := 0 to 1 do begin
    var Index := 0;
    while Index < FPendPushes.Count do begin
      var Ofs := FPendPushes[Index];
      if FFlags[Ofs] and rbfHandlerEntry <> 0 then begin
        FPendPushes.Delete(Index);
        Continue;
      end;
      if Pass = 0 then begin
        var Dest := (Int64(FS) + Ofs + 5 + PInteger(@FCode[Ofs + 1])^) and $FFFFFFFF;
        if (FCode[Ofs] <> $E9) or InRoutine(Dest) or (Ofs + 5 > FLen) then begin
          Inc(Index);
          Continue;
        end;
        FPendPushes.Delete(Index);
        Result := True;
        var Stub := StubKindOfTarget(Dest);
        SeedHandler(Int64(FS) + Ofs, rhkStub, Stub);
        var Entered := Ofs + 5;
        if Entered >= FLen then
          Continue;
        var Count: Integer;
        var Structural := LooksLikeClauseTable(Entered, Count);
        // The name decides when there is one; the structure must agree.
        if (Stub = xskOnException) and not Structural then begin
          Fail(rirHandlerTable, Entered);
          Continue;
        end;
        if (Stub in [xskFinally, xskAnyException, xskAutoException]) or not Structural then begin
          SeedHandler(Int64(FS) + Entered, rhkAfterStub);
          Continue;
        end;
        var Item: TRoutineClauseTable;
        Item.Rva   := Cardinal(Int64(FS) + Entered);
        Item.Count := Count;
        FClauses.Add(Item);
        for var K := Entered to Entered + 4 + Count * 8 - 1 do begin
          if FFlags[K] and (rbfBoundary or rbfInterior) <> 0 then
            Fail(rirConflict, K);
          FFlags[K] := FFlags[K] or rbfClauseTable;
        end;
        for var K := 0 to Count - 1 do
          SeedHandler(RvaOfVa(PCardinal(@FCode[Entered + 8 + K * 8])^), rhkOnBlock);
        Continue;
      end;
      // Pass 1: the continuation sits right after `jmp @HandleFinally` and the
      // `jmp <finally code>` at stub + 5, short or near.
      var AfterShort := (Ofs >= 7) and (FCode[Ofs - 2] = $EB) and (FFlags[Ofs - 7] and rbfStub <> 0);
      var AfterNear := (Ofs >= 10) and (FCode[Ofs - 5] = $E9) and (FFlags[Ofs - 10] and rbfStub <> 0);
      if AfterShort or AfterNear then begin
        FPendPushes.Delete(Index);
        Result := True;
        SeedHandler(Int64(FS) + Ofs, rhkContinuation);
        Continue;
      end;
      Inc(Index);
    end;
  end;
end;

procedure TRoutineAnalyzer.ScanUnexplainedPointers;
// x86: a DWORD of the routine, outside every proven instruction and every
// recognised table, that holds an address of the routine. Each one is a table
// this unit did not recognise; what it points at is a possible target.
begin
  var Ofs := 0;
  while Ofs + 4 <= FLen do begin
    if FFlags[Ofs] and (rbfBoundary or rbfInterior or rbfData) = 0 then begin
      var Target := RvaOfVa(PCardinal(@FCode[Ofs])^);
      if InRoutine(Target) then
        FFlags[Target - FS] := FFlags[Target - FS] or rbfAddressRef;
    end;
    Inc(Ofs);
  end;
end;

function TRoutineAnalyzer.WindowEnd(ReturnOfs: Integer): Integer;
// x64: the instructions RtlVirtualUnwind may read from a return address when
// it tests for an epilogue -- an optional `add rsp, imm` / `lea rsp, [..]`, any
// number of `pop r64`, and the one instruction after them. Marks each and
// returns the offset past the last one.

  function Proven(Ofs: Integer): Boolean;
  begin
    Result := (Ofs < FLen) and (FFlags[Ofs] and rbfBoundary <> 0);
  end;

  function IsStackAdjust(Ofs: Integer): Boolean;
  begin
    // add rsp, imm: 48 83 C4 ib or 48 81 C4 id.
    if (FCode[Ofs] = $48) and ((FCode[Ofs + 1] = $83) or (FCode[Ofs + 1] = $81)) and
       (FCode[Ofs + 2] = $C4) then
      Exit(True);
    // lea rsp, [base+disp]: 48 or 49 (the base may be r8..r15), 8D, reg = rsp.
    Result := (FCode[Ofs] and $FE = $48) and (FCode[Ofs + 1] = $8D) and (FCode[Ofs + 2] and $38 = $20);
  end;

  function IsPop(Ofs: Integer): Boolean;
  begin
    if (FCode[Ofs] >= $58) and (FCode[Ofs] <= $5F) then
      Exit(True);
    Result := (FCode[Ofs] and $F0 = $40) and (FCode[Ofs + 1] >= $58) and (FCode[Ofs + 1] <= $5F) and
      (LengthOf(Ofs) = 2);
  end;

  procedure Take(var Ofs: Integer);
  begin
    FFlags[Ofs] := FFlags[Ofs] or rbfWindow;
    Inc(Ofs, LengthOf(Ofs));
  end;

begin
  Result := ReturnOfs;
  if not Proven(Result) then
    Exit;
  if IsStackAdjust(Result) then
    Take(Result);
  while Proven(Result) and IsPop(Result) do
    Take(Result);
  if Proven(Result) then
    Take(Result);
end;

procedure TRoutineAnalyzer.BuildCallSites(var Analysis: TRoutineAnalysis);
begin
  SetLength(Analysis.CallSites, FCalls.Count);
  var Ascending := True;
  for var I := 0 to FCalls.Count - 1 do begin
    var Call := FCalls[I];
    var ReturnOfs := Call.Ofs + LengthOf(Call.Ofs);
    Analysis.CallSites[I].CallRva      := Cardinal(Int64(FS) + Call.Ofs);
    Analysis.CallSites[I].ReturnRva    := Cardinal(Int64(FS) + ReturnOfs);
    Analysis.CallSites[I].Indirect     := Call.Indirect;
    Analysis.CallSites[I].TargetRva    := Call.Target;
    Analysis.CallSites[I].WindowEndRva := Analysis.CallSites[I].ReturnRva;
    if FIs64 then
      Analysis.CallSites[I].WindowEndRva := Cardinal(Int64(FS) + WindowEnd(ReturnOfs));
    if (I > 0) and (Call.Ofs < FCalls[I - 1].Ofs) then
      Ascending := False;
  end;
  if not Ascending then
    TArray.Sort<TRoutineCallSite>(Analysis.CallSites, TComparer<TRoutineCallSite>.Construct(
      function(const A, B: TRoutineCallSite): Integer
      begin
        if A.CallRva < B.CallRva then
          Exit(-1);
        if A.CallRva > B.CallRva then
          Exit(1);
        Result := 0;
      end));
end;

procedure TRoutineAnalyzer.BuildExits(var Analysis: TRoutineAnalysis);
begin
  SetLength(Analysis.Exits, FExitList.Count);
  var Ascending := True;
  for var I := 0 to FExitList.Count - 1 do begin
    var Item := FExitList[I];
    var Next := Item.Ofs + LengthOf(Item.Ofs);
    var Role := rerRoutineExit;
    if FIs64 then begin
      // A `ret` or a leaving jump inside a funclet returns to the unwinder or
      // to the body that called the funclet.
      var Holder := FindPdataContaining(Cardinal(Int64(FS) + Item.Ofs));
      if (Holder >= 0) and (FPdParent[Holder] >= 0) then
        Role := rerFuncletReturn;
    end
    else if FFlags[Item.Ofs] and rbfStub <> 0 then
      Role := rerHandlerStub
    // x86: a `ret`, or the `pop reg; jmp reg`, directly in front of a handler
    // stub found through its push ends a finally block. Without the stub
    // nothing proves what the jump is and it stays an indirect exit.
    else if (Item.Kind in [rekReturn, rekJumpIndirect]) and (Next < FLen) and
            (FFlags[Next] and rbfStub <> 0) and
            ((Item.Kind = rekReturn) or (KindOf(Item.Ofs) = rikJumpFinally)) then
      Role := rerFinallyExit;
    Analysis.Exits[I].Rva  := Cardinal(Int64(FS) + Item.Ofs);
    Analysis.Exits[I].Kind := Item.Kind;
    Analysis.Exits[I].Role := Role;
    if (I > 0) and (Item.Ofs < FExitList[I - 1].Ofs) then
      Ascending := False;
  end;
  if not Ascending then
    TArray.Sort<TRoutineExit>(Analysis.Exits, TComparer<TRoutineExit>.Construct(
      function(const A, B: TRoutineExit): Integer
      begin
        if A.Rva < B.Rva then
          Exit(-1);
        if A.Rva > B.Rva then
          Exit(1);
        Result := 0;
      end));
end;

function TRoutineAnalyzer.UnreachedReason(Ofs: Integer;
  out Verdict: TLineVerdict): TLineVerdictReason;
// Why a record the decode did not arrive at is what it is. The first two
// answers prove it is not code; the others only say what stands before it.
var
  Detail: TZydisInstructionDetail;
begin
  // What stands before it: the nearest proven instruction or table below.
  // Records are asked about in ascending order and remember the answer, so a
  // long unreached stretch holding thousands of records (the static functions
  // of a linked C object share one procedure range) is walked once, not once
  // per record.
  var Before := lvrNothingProvenBefore;
  var Back := Ofs - 1;
  while Back >= 0 do begin
    if Back = FUnreachedOfs then begin
      Before := FUnreachedBefore;
      Break;
    end;
    var Flag := FFlags[Back];
    if Flag and rbfData <> 0 then begin
      Before := lvrAfterTable;
      Break;
    end;
    if Flag and (rbfBoundary or rbfInterior) <> 0 then begin
      while (Back >= 0) and (FFlags[Back] and rbfBoundary = 0) do
        Dec(Back);
      if Back < 0 then
        Break;
      case KindOf(Back) of
        rikJumpIndirect, rikJumpTable, rikJumpSlot, rikJumpFinally:
          Before := lvrAfterIndirectJump;
        rikReturn, rikJump:
          Before := lvrAfterReturnOrJump;
        rikInt3, rikTrap, rikJumpFar:
          Before := lvrAfterTrap;
      else
        Before := lvrAfterStoppedDecode;
      end;
      Break;
    end;
    Dec(Back);
  end;
  FUnreachedOfs    := Ofs;
  FUnreachedBefore := Before;

  if FCode[Ofs] = 0 then
    Result := lvrZeroByte
  else if not DecodeAt(Ofs, Detail) then
    Result := lvrUndecodable
  else
    Result := Before;
  Verdict := VerdictOfReason(Result);
end;

procedure TRoutineAnalyzer.FirstBlock(Ofs, LineEnd: Integer; IsLastLine: Boolean;
  var Line: TRoutineLine);
// The line's first straight-line block: every instruction from the line start
// up to and including its first branch or call, stopping BEFORE the first
// address a branch can reach and before the next line. Each of them runs
// exactly once per entry into the line.
begin
  var At := Ofs;
  Line.BlockEnd := lbeNone;
  while Line.BlockEnd = lbeNone do begin
    if At >= LineEnd then begin
      Line.BlockEnd := lbeNextLine;
      if IsLastLine then
        Line.BlockEnd := lbeRoutineEnd;
      Break;
    end;
    var Flag := FFlags[At];
    if Flag and rbfBoundary = 0 then begin
      Line.BlockEnd := lbeUnproven;
      Break;
    end;
    if (At > Ofs) and (Flag and rbfBarrier <> 0) then begin
      Line.BlockEnd := lbeTarget;
      Break;
    end;
    var Kind := KindOf(At);
    Inc(At, LengthOf(At));
    case Kind of
      rikOther:        ;
      rikCall:         Line.BlockEnd := lbeCall;
      rikCallIndirect: Line.BlockEnd := lbeCallIndirect;
      rikReturn:       Line.BlockEnd := lbeReturn;
      rikInt3, rikTrap: Line.BlockEnd := lbeTrap;
    else
      Line.BlockEnd := lbeBranch;
    end;
  end;
  Line.BlockEndRva := Cardinal(Int64(FS) + At);
end;

procedure TRoutineAnalyzer.BuildLines(var Analysis: TRoutineAnalysis);
begin
  FUnreachedOfs := -1;
  SetLength(Analysis.Lines, FLineIdx.Count);
  var Lines := FMap.Lines;
  for var I := 0 to FLineIdx.Count - 1 do begin
    var Line := Default(TRoutineLine);
    Line.LineIndex := FLineIdx[I];
    Line.Rva       := Lines[FLineIdx[I]].Rva;
    var Ofs := Integer(Line.Rva - FS);
    var Flag := FFlags[Ofs];
    if Flag and rbfBoundary <> 0 then begin
      Line.Verdict := lvConfirmed;
      Line.Reason  := lvrBoundary;
      var LineEnd := FLen;
      var IsLast := I = FLineIdx.Count - 1;
      if not IsLast then
        LineEnd := Integer(Lines[FLineIdx[I + 1]].Rva - FS);
      FirstBlock(Ofs, LineEnd, IsLast, Line);
    end
    else if Flag and rbfJumpTable <> 0 then begin
      Line.Verdict := lvNotCode;
      Line.Reason  := lvrInJumpTable;
    end
    else if Flag and rbfClauseTable <> 0 then begin
      Line.Verdict := lvNotCode;
      Line.Reason  := lvrInClauseTable;
    end
    else if Flag and rbfInterior <> 0 then begin
      Line.Verdict := lvNotCode;
      Line.Reason  := lvrInsideInstruction;
    end
    else
      Line.Reason := UnreachedReason(Ofs, Line.Verdict);
    Analysis.Lines[I] := Line;
  end;
end;

end.
