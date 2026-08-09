program ExcHandlerProbe;

{
  ExcHandlerProbe -- two measurements about what a debugger can do at a
  FIRST-CHANCE exception stop, both taken against a live debuggee through the
  raw Windows Debug API, on a native x64 target and on a WOW64 x86 target.

  Q1 ("does the trap flag survive exception dispatch?")
    At the exception stop, set EFLAGS.TF on the faulting thread (read back to
    prove the write took) and resume with a chosen continue status. Then report
    the NEXT debug event verbatim: its code, its address, the module it lands
    in, and whether it is a single step ($80000004 native / $4000001E WOW64).
    If TF survives the kernel's transfer to KiUserExceptionDispatcher, the very
    next event is a single step inside ntdll; if TF is cleared, the next event
    is whatever the program does next, and "deliver with TF armed" is just a
    plain continue.

    -cont notHandled  (default)  DBG_EXCEPTION_NOT_HANDLED: deliver it
    -cont handled                DBG_CONTINUE: swallow it. This is the CONTROL
                                 for a Delphi raise -- the same stop, the same
                                 thread, the same arming code, only the continue
                                 status differs, so a single step here and none
                                 with notHandled isolates the dispatch path as
                                 the cause rather than the arming.

  Q2 ("how do you find the user's handler?")
    x64: for every frame of the stopped thread, look up the RUNTIME_FUNCTION in
      that module's .pdata, decode UNWIND_INFO (version/flags/prolog/codes),
      and when UNW_FLAG_EHANDLER / UNW_FLAG_UHANDLER is set, print the language
      handler RVA and the handler-specific data that follows the unwind codes,
      resolving every word that looks like an in-image RVA back to
      function+source:line through the engine's own TD32/MAP readers. Chained
      unwind info (UNW_FLAG_CHAININFO) is followed.
    x86: there is no .pdata. Walk the fs:[0] SEH chain in the debuggee (FS base
      from Wow64GetThreadSelectorEntry, cross-checked against the 32-bit TEB
      at TEB64+$2000 whose Self field must point at itself), print every
      registration record, decode the `jmp @HandleXxx` stub each Handler field
      points at, and resolve the words that follow it.

    Addresses that resolve to a source line in the main executable are
    collected as CANDIDATES. -plant then plants an INT3 at each candidate,
    resumes with DBG_EXCEPTION_NOT_HANDLED, and reports which one is actually
    reached -- which is the check that says a one-shot breakpoint on the
    discovered address really lands in the user's block.

  Usage:
    ExcHandlerProbe <target.exe> [-args "<debuggee args>"] [-map <file.map>]
                    [-code <hex>] [-skip N] [-frames N]
                    [-tf] [-cont handled|notHandled] [-events N]
                    [-plant] [-timeout MS]

    -args     command line handed to the debuggee
    -map      explicit .map (default: the exe's sibling .map, if present)
    -code     only treat this exception code as the stop (default: $0EEDFADE
              Delphi raise and $C0000005 access violation)
    -skip     ignore the first N matching first-chance exceptions
    -frames   how many x64 stack frames to analyse (default 12)
    -tf       run the Q1 trap-flag measurement at the stop
    -events   how many debug events to report after the resume (default 4)
    -plant    run the Q2 candidate check: INT3 at every candidate, then resume
    -timeout  WaitForDebugEvent timeout in ms (default 20000)

  Nothing here is target specific: every path, address and count comes from the
  command line. DevTools\Fixtures\ExcNestFixture.dpr is a debuggee built for it
  (raise inside try/finally inside try/except), but any executable works.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.Math,
  System.Generics.Collections,
  DebugInfoTypes,
  TD32FileReader,
  MapFileReader;

const
  STATUS_WX86_SINGLE_STEP = DWORD($4000001E);
  STATUS_WX86_BREAKPOINT  = DWORD($4000001F);
  DELPHI_EXCEPTION        = DWORD($0EEDFADE);
  MachineI386             = DWORD($014C);
  MachineAmd64            = DWORD($8664);
  AddrModeFlat            = DWORD(3);
  TRAP_FLAG               = DWORD($00000100);

  UNW_FLAG_EHANDLER   = $01;
  UNW_FLAG_UHANDLER   = $02;
  UNW_FLAG_CHAININFO  = $04;

  DIR_EXCEPTION       = 3;   // IMAGE_DIRECTORY_ENTRY_EXCEPTION

type
  TDbgAddress64 = record
    Offset:  UInt64;
    Segment: Word;
    Mode:    DWORD;
  end;

  TDbgStackFrame64 = record
    AddrPC:         TDbgAddress64;
    AddrReturn:     TDbgAddress64;
    AddrFrame:      TDbgAddress64;
    AddrStack:      TDbgAddress64;
    AddrBStore:     TDbgAddress64;
    FuncTableEntry: Pointer;
    Params:         array[0..3] of UInt64;
    Far_:           BOOL;
    Virtual_:       BOOL;
    Reserved:       array[0..2] of UInt64;
    KdHelp:         array[0..111] of Byte;
  end;

  TRuntimeFunction = packed record
    BeginAddress: DWORD;
    EndAddress:   DWORD;
    UnwindData:   DWORD;
  end;

  TModuleInfo = record
    Base: UInt64;
    Size: UInt64;
    Name: string;   // lowercase base name
    Path: string;
    PdataRva:  DWORD;
    PdataSize: DWORD;
    HeaderRead: Boolean;
  end;

  TIsWow64Process2 = function(hProcess: THandle;
    out ProcessMachine: USHORT; out NativeMachine: USHORT): BOOL; stdcall;

function SymInitialize(hProcess: THandle; UserSearchPath: PAnsiChar;
  fInvadeProcess: BOOL): BOOL; stdcall; external 'dbghelp.dll';
function SymCleanup(hProcess: THandle): BOOL; stdcall; external 'dbghelp.dll';
function StackWalk64(MachineType: DWORD; hProcess, hThread: THandle;
  var StackFrame: TDbgStackFrame64; ContextRecord: Pointer;
  ReadMemoryRoutine, FunctionTableAccessRoutine,
  GetModuleBaseRoutine, TranslateAddressRoutine: Pointer): BOOL;
  stdcall; external 'dbghelp.dll';
function SymFunctionTableAccess64(hProcess: THandle; AddrBase: UInt64): Pointer;
  stdcall; external 'dbghelp.dll';
function SymGetModuleBase64(hProcess: THandle; qwAddr: UInt64): UInt64;
  stdcall; external 'dbghelp.dll';

function GetFinalPathNameByHandleW(hFile: THandle; lpszFilePath: PWideChar;
  cchFilePath, dwFlags: DWORD): DWORD; stdcall;
  external kernel32 name 'GetFinalPathNameByHandleW';

function Wow64GetThreadSelectorEntry(hThread: THandle; dwSelector: DWORD;
  var lpSelectorEntry: TLdtEntry): BOOL; stdcall;
  external kernel32 name 'Wow64GetThreadSelectorEntry';

function NtQueryInformationThread(ThreadHandle: THandle;
  ThreadInformationClass: DWORD; ThreadInformation: Pointer;
  ThreadInformationLength: ULONG; ReturnLength: PULONG): Integer; stdcall;
  external 'ntdll.dll';

var
  GProcess:     THandle = 0;
  GIsWow64:     Boolean = False;
  GMainBase:    UInt64  = 0;
  GModules:     TList<TModuleInfo>;
  GThreads:     TDictionary<DWORD, THandle>;
  GTd32:        TTD32FileReader = nil;
  GMap:         TMapFile = nil;
  GCandidates:  TList<UInt64>;
  GFrameCount:  Integer = 12;
  // A function's scope table lists EVERY protected region in that function. Only
  // the entry whose Begin..End covers the frame's own RVA can receive this
  // exception, so that is the only one whose blocks become candidates unless
  // -allscopes says otherwise.
  GFrameRva:    DWORD  = 0;
  GAllScopes:   Boolean = False;
  // The scope table's third field is a FILTER FUNCTION rva under MSVC's
  // __C_specific_handler and a CLAUSE TABLE rva under Delphi's. Decoding one as
  // the other produces confident nonsense, so the clause decoding is gated on
  // the language handler actually being Delphi's.
  GDelphiHandler: Boolean = False;

{ ------------------------------------------------------------------ utils -- }

procedure Say(const Line: string);
begin
  Writeln(Line);
  Flush(Output);
end;

function Hex(Value: UInt64): string;
begin
  Result := '$' + IntToHex(Value, 8);
end;

function IsSingleStep(Code: DWORD): Boolean;
begin
  Result := (Code = DWORD(EXCEPTION_SINGLE_STEP)) or (Code = STATUS_WX86_SINGLE_STEP);
end;

function ExceptionCodeName(Code: DWORD): string;
begin
  case Code of
    DWORD(EXCEPTION_BREAKPOINT):      Result := 'EXCEPTION_BREAKPOINT';
    DWORD(EXCEPTION_SINGLE_STEP):     Result := 'EXCEPTION_SINGLE_STEP';
    STATUS_WX86_BREAKPOINT:           Result := 'STATUS_WX86_BREAKPOINT';
    STATUS_WX86_SINGLE_STEP:          Result := 'STATUS_WX86_SINGLE_STEP';
    DWORD(EXCEPTION_ACCESS_VIOLATION):Result := 'EXCEPTION_ACCESS_VIOLATION';
    DELPHI_EXCEPTION:                 Result := 'Delphi raise ($0EEDFADE)';
    DWORD($406D1388):                 Result := 'MS_VC_EXCEPTION (thread name)';
  else
    Result := '';
  end;
end;

function ReadMem(Addr: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
var
  Got: NativeUInt;
begin
  Got := 0;
  Result := ReadProcessMemory(GProcess, Pointer(Addr), Buf, Size, Got) and (Got = Size);
end;

function ReadU32(Addr: UInt64; out Value: DWORD): Boolean;
begin
  Value := 0;
  Result := ReadMem(Addr, @Value, SizeOf(Value));
end;

function ReadU64V(Addr: UInt64; out Value: UInt64): Boolean;
begin
  Value := 0;
  Result := ReadMem(Addr, @Value, SizeOf(Value));
end;

{ --------------------------------------------------------------- modules -- }

function PathFromHandle(H: THandle): string;
var
  Buf: array[0..MAX_PATH * 2] of WideChar;
begin
  Result := '';
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then
    Exit;
  var N := GetFinalPathNameByHandleW(H, @Buf[0], Length(Buf) - 1, 0);
  if (N > 0) and (N < DWORD(Length(Buf))) then begin
    Result := Buf;
    if Result.StartsWith('\\?\') then
      Result := Result.Substring(4);
  end;
end;

// SizeOfImage and the .pdata directory come from the PE headers as MAPPED, read
// out of the debuggee itself -- never from the file on disk, so a relocated or
// non-file-backed module is described correctly.
procedure ReadModuleHeaders(var M: TModuleInfo);
var
  Dos: TImageDosHeader;
  Sig: DWORD;
  FileHdr: TImageFileHeader;
  Magic: Word;
begin
  M.HeaderRead := False;
  M.Size := 0;
  M.PdataRva := 0;
  M.PdataSize := 0;
  if not ReadMem(M.Base, @Dos, SizeOf(Dos)) then Exit;
  if Dos.e_magic <> IMAGE_DOS_SIGNATURE then Exit;
  var NtOff := M.Base + UInt64(DWORD(Dos._lfanew));
  if not ReadU32(NtOff, Sig) then Exit;
  if Sig <> IMAGE_NT_SIGNATURE then Exit;
  if not ReadMem(NtOff + 4, @FileHdr, SizeOf(FileHdr)) then Exit;
  var OptOff := NtOff + 4 + SizeOf(FileHdr);
  if not ReadMem(OptOff, @Magic, SizeOf(Magic)) then Exit;
  if Magic = $20B then begin
    var Opt: TImageOptionalHeader64;
    if not ReadMem(OptOff, @Opt, SizeOf(Opt)) then Exit;
    M.Size := Opt.SizeOfImage;
    M.PdataRva  := Opt.DataDirectory[DIR_EXCEPTION].VirtualAddress;
    M.PdataSize := Opt.DataDirectory[DIR_EXCEPTION].Size;
  end
  else begin
    var Opt32: TImageOptionalHeader32;
    if not ReadMem(OptOff, @Opt32, SizeOf(Opt32)) then Exit;
    M.Size := Opt32.SizeOfImage;
    M.PdataRva  := Opt32.DataDirectory[DIR_EXCEPTION].VirtualAddress;
    M.PdataSize := Opt32.DataDirectory[DIR_EXCEPTION].Size;
  end;
  M.HeaderRead := True;
end;

procedure AddModule(Base: UInt64; const Path: string);
var
  M: TModuleInfo;
begin
  if Base = 0 then
    Exit;
  for var I := 0 to GModules.Count - 1 do
    if GModules[I].Base = Base then
      Exit;
  M := Default(TModuleInfo);
  M.Base := Base;
  M.Path := Path;
  M.Name := LowerCase(ExtractFileName(Path));
  if M.Name = '' then
    M.Name := '<' + IntToHex(Base, 8) + '>';
  ReadModuleHeaders(M);
  GModules.Add(M);
end;

function FindModule(VA: UInt64; out M: TModuleInfo): Boolean;
begin
  Result := False;
  for var I := 0 to GModules.Count - 1 do begin
    var Cur := GModules[I];
    var Size := Cur.Size;
    if Size = 0 then
      Size := $1000000;
    if (VA >= Cur.Base) and (VA < Cur.Base + Size) then begin
      M := Cur;
      Exit(True);
    end;
  end;
end;

{ ---------------------------------------------------------- symbolication -- }

// Resolution goes through the engine's OWN readers, so a positive result says
// the shipping debugger would see the same thing, not that a private parser
// agreed with itself.
function ResolveMainRva(Rva: UInt64; out FuncName: string; out Loc: TSourceLocation): Boolean;
begin
  FuncName := '';
  Loc := Default(TSourceLocation);
  Result := False;
  if (GTd32 <> nil) and GTd32.Loaded then begin
    if GTd32.RvaToFunctionName(Rva, FuncName) then Result := True;
    if GTd32.RvaToSourceLine(Rva, Loc) then Result := True;
  end;
  if (not Result) and (GMap <> nil) then begin
    if GMap.RvaToFunctionName(Rva, FuncName) then Result := True;
    if GMap.RvaToSourceLine(Rva, Loc) then Result := True;
  end;
end;

function DescribeVa(VA: UInt64): string;
var
  M: TModuleInfo;
  FuncName: string;
  Loc: TSourceLocation;
begin
  if VA = 0 then
    Exit('(null)');
  if not FindModule(VA, M) then
    Exit(Hex(VA) + ' <unknown module>');
  var Rva := VA - M.Base;
  Result := Format('%s %s+%s', [Hex(VA), M.Name, Hex(Rva)]);
  if M.Base <> GMainBase then
    Exit;
  if ResolveMainRva(Rva, FuncName, Loc) then begin
    if FuncName <> '' then
      Result := Result + '  ' + FuncName;
    if Loc.Line > 0 then
      Result := Result + Format('  [%s:%d]', [Loc.SourceFile, Loc.Line]);
  end;
end;

// A candidate is an address in the MAIN executable that maps to a real source
// line -- that is the property which separates the user's own except/finally
// block from an RTL funclet or a piece of table data.
function IsUserCodeRva(Rva: UInt64; out Where: string): Boolean;
var
  FuncName: string;
  Loc: TSourceLocation;
begin
  Where := '';
  Result := False;
  if not ResolveMainRva(Rva, FuncName, Loc) then
    Exit;
  if Loc.Line <= 0 then
    Exit;
  Where := Format('%s [%s:%d]', [FuncName, Loc.SourceFile, Loc.Line]);
  Result := True;
end;

procedure NoteCandidate(VA: UInt64);
begin
  if (VA = 0) or (GCandidates.IndexOf(VA) >= 0) then
    Exit;
  GCandidates.Add(VA);
end;

{ ------------------------------------------------- x64 .pdata / UNWIND_INFO -- }

function FindRuntimeFunction(const M: TModuleInfo; Rva: DWORD;
  out RF: TRuntimeFunction): Boolean;
begin
  Result := False;
  if (not M.HeaderRead) or (M.PdataRva = 0) or (M.PdataSize < SizeOf(TRuntimeFunction)) then
    Exit;
  var Count := M.PdataSize div SizeOf(TRuntimeFunction);
  var Lo := 0;
  var Hi := Integer(Count) - 1;
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) div 2;
    var Cur: TRuntimeFunction;
    if not ReadMem(M.Base + M.PdataRva + UInt64(Mid) * SizeOf(TRuntimeFunction),
                   @Cur, SizeOf(Cur)) then
      Exit;
    if Rva < Cur.BeginAddress then
      Hi := Mid - 1
    else if Rva >= Cur.EndAddress then
      Lo := Mid + 1
    else begin
      RF := Cur;
      Exit(True);
    end;
  end;
end;

function ScopeTableLooksPlausible(const M: TModuleInfo; DataRva: DWORD;
  out Count: DWORD): Boolean;
begin
  Count := 0;
  Result := False;
  if not ReadU32(M.Base + DataRva, Count) then
    Exit;
  if (Count = 0) or (Count > 256) then
    Exit;
  var Bytes := UInt64(4) + UInt64(Count) * 16;
  if DataRva + Bytes > M.Size then
    Exit;
  // Every entry's Begin/End must be a sane ascending pair inside the image.
  for var I := 0 to Integer(Count) - 1 do begin
    var E: array[0..3] of DWORD;
    if not ReadMem(M.Base + DataRva + 4 + UInt64(I) * 16, @E[0], SizeOf(E)) then
      Exit;
    if (E[0] = 0) or (E[1] <= E[0]) or (UInt64(E[1]) > M.Size) then
      Exit;
  end;
  Result := True;
end;

// A scope entry whose Handler is a real RVA does NOT point at code: it points at
// a clause table, laid out as
//     DWORD Count; Count x { DWORD ClassVmtRva; DWORD BlockRva }
// where BlockRva IS the address of the user's `on <Class> do` block. Planting an
// INT3 on the table address itself would overwrite Count and derail dispatch, so
// only the decoded BlockRvas ever become candidates.
procedure DumpClauseTable(const M: TModuleInfo; TableRva: DWORD; const Indent: string);
begin
  var Count: DWORD;
  if not ReadU32(M.Base + TableRva, Count) then begin
    Say(Indent + 'clause table unreadable');
    Exit;
  end;
  if (Count = 0) or (Count > 64) then begin
    Say(Format('%sclause table at %s: implausible count %s', [Indent, Hex(TableRva), Hex(Count)]));
    Exit;
  end;
  Say(Format('%sclause table at %s: %d clause(s)', [Indent, Hex(TableRva), Count]));
  for var I := 0 to Integer(Count) - 1 do begin
    var Pair: array[0..1] of DWORD;
    if not ReadMem(M.Base + TableRva + 4 + UInt64(I) * 8, @Pair[0], SizeOf(Pair)) then
      Break;
    var Where: string;
    if IsUserCodeRva(Pair[1], Where) then begin
      Say(Format('%s  on <vmt %s> -> block %s = %s  *** USER BLOCK ***',
        [Indent, Hex(Pair[0]), Hex(Pair[1]), Where]));
      NoteCandidate(M.Base + Pair[1]);
    end
    else
      Say(Format('%s  on <vmt %s> -> block %s = %s',
        [Indent, Hex(Pair[0]), Hex(Pair[1]), DescribeVa(M.Base + Pair[1])]));
  end;
end;

procedure DumpScopeTable(const M: TModuleInfo; DataRva, Count: DWORD; const Indent: string);
begin
  Say(Format('%sscope table at rva %s: %d entr%s',
    [Indent, Hex(DataRva), Count, IfThen(Count = 1, 'y', 'ies')]));
  for var I := 0 to Integer(Count) - 1 do begin
    var E: array[0..3] of DWORD;
    if not ReadMem(M.Base + DataRva + 4 + UInt64(I) * 16, @E[0], SizeOf(E)) then
      Break;
    var Covers := (GFrameRva >= E[0]) and (GFrameRva < E[1]);
    Say(Format('%s  [%d] Begin=%s End=%s Handler=%s Target=%s%s',
      [Indent, I, Hex(E[0]), Hex(E[1]), Hex(E[2]), Hex(E[3]),
       IfThen(Covers, '   <== COVERS THIS FRAME''S RVA ' + Hex(GFrameRva), '')]));
    if not (Covers or GAllScopes) then
      Continue;
    var Where: string;
    if E[2] = 0 then begin
      Say(Indent + '      kind: FINALLY (Handler=0) -- Target is the finally funclet');
      if IsUserCodeRva(E[3], Where) then begin
        Say(Format('%s      Target -> %s  *** USER BLOCK ***', [Indent, Where]));
        NoteCandidate(M.Base + E[3]);
      end;
    end
    else if E[2] <= 2 then begin
      Say(Format('%s      kind: UNCONDITIONAL EXCEPT (Handler=%s, a flag not an rva)',
        [Indent, Hex(E[2])]));
      if IsUserCodeRva(E[3], Where) then begin
        Say(Format('%s      Target -> %s  *** USER BLOCK ***', [Indent, Where]));
        NoteCandidate(M.Base + E[3]);
      end;
    end
    else if not GDelphiHandler then
      Say(Indent + '      kind: non-Delphi language handler -- Handler is a FILTER FUNCTION rva, ' +
                   'not a clause table; not decoded')
    else begin
      Say(Indent + '      kind: EXCEPT WITH `on` CLAUSES -- Handler is a clause table rva');
      DumpClauseTable(M, E[2], Indent + '      ');
      if (E[3] <> 0) and IsUserCodeRva(E[3], Where) then begin
        Say(Format('%s      Target -> %s  *** USER BLOCK ***', [Indent, Where]));
        NoteCandidate(M.Base + E[3]);
      end;
    end;
  end;
end;

procedure DumpHandlerData(const M: TModuleInfo; DataRva: DWORD; const Indent: string);
const
  WordsToDump = 12;
begin
  var Count: DWORD;
  if ScopeTableLooksPlausible(M, DataRva, Count) then
    DumpScopeTable(M, DataRva, Count, Indent)
  else
    Say(Indent + 'handler data is not an MSVC-shaped scope table');

  Say(Indent + 'raw handler data words:');
  for var I := 0 to WordsToDump - 1 do begin
    var W: DWORD;
    if not ReadU32(M.Base + DataRva + UInt64(I) * 4, W) then
      Break;
    var Where: string;
    // Evidence only -- never a candidate. Words of the raw dump include the
    // clause-table header and the following unwind bytes, and an INT3 written
    // over one of those is a corruption, not a breakpoint.
    if IsUserCodeRva(W, Where) then
      Say(Format('%s  +%.2x %s   -> %s', [Indent, I * 4, Hex(W), Where]))
    else
      Say(Format('%s  +%.2x %s', [Indent, I * 4, Hex(W)]));
  end;
end;

procedure DumpUnwindInfo(const M: TModuleInfo; UnwindRva: DWORD;
  Depth: Integer; const Indent: string);
var
  Hdr: array[0..3] of Byte;
begin
  if Depth > 4 then begin
    Say(Indent + 'chain too deep, stopping');
    Exit;
  end;
  if not ReadMem(M.Base + UnwindRva, @Hdr[0], SizeOf(Hdr)) then begin
    Say(Indent + 'UNWIND_INFO unreadable at rva ' + Hex(UnwindRva));
    Exit;
  end;
  var Version := Hdr[0] and 7;
  var Flags   := Hdr[0] shr 3;
  var SizeOfProlog := Hdr[1];
  var CountOfCodes := Hdr[2];
  var FrameReg  := Hdr[3] and $0F;
  var FrameOffs := Hdr[3] shr 4;
  var FlagText := '';
  if (Flags and UNW_FLAG_EHANDLER)  <> 0 then FlagText := FlagText + 'EHANDLER ';
  if (Flags and UNW_FLAG_UHANDLER)  <> 0 then FlagText := FlagText + 'UHANDLER ';
  if (Flags and UNW_FLAG_CHAININFO) <> 0 then FlagText := FlagText + 'CHAININFO ';
  if FlagText = '' then FlagText := '(none)';
  Say(Format('%sUNWIND_INFO@%s ver=%d flags=%s(%s) prolog=%d codes=%d frameReg=%d frameOffs=%d',
    [Indent, Hex(UnwindRva), Version, Hex(Flags), Trim(FlagText),
     SizeOfProlog, CountOfCodes, FrameReg, FrameOffs]));

  // UNWIND_CODE array is padded to an EVEN number of 2-byte slots.
  var Slots := (Integer(CountOfCodes) + 1) and not 1;
  var TailRva := UnwindRva + 4 + DWORD(Slots) * 2;

  if (Flags and (UNW_FLAG_EHANDLER or UNW_FLAG_UHANDLER)) <> 0 then begin
    var HandlerRva: DWORD;
    if not ReadU32(M.Base + TailRva, HandlerRva) then begin
      Say(Indent + '  handler rva unreadable');
      Exit;
    end;
    var HandlerDesc := DescribeVa(M.Base + HandlerRva);
    GDelphiHandler := ContainsText(HandlerDesc, 'DelphiExceptionHandler');
    Say(Format('%s  language handler rva=%s -> %s%s',
      [Indent, Hex(HandlerRva), HandlerDesc,
       IfThen(GDelphiHandler, '   (Delphi)', '   (not Delphi)')]));
    DumpHandlerData(M, TailRva + 4, Indent + '  ');
  end
  else if (Flags and UNW_FLAG_CHAININFO) <> 0 then begin
    var Chained: TRuntimeFunction;
    if not ReadMem(M.Base + TailRva, @Chained, SizeOf(Chained)) then
      Exit;
    Say(Format('%s  chained to Begin=%s End=%s Unwind=%s',
      [Indent, Hex(Chained.BeginAddress), Hex(Chained.EndAddress), Hex(Chained.UnwindData)]));
    DumpUnwindInfo(M, Chained.UnwindData, Depth + 1, Indent + '  ');
  end
  else
    Say(Indent + '  no handler, no chain -- this function cannot receive the exception');
end;

procedure AnalyseX64Frames(hThread: THandle);
var
  Ctx: TContext;
  Walk: TContext;
  Frame: TDbgStackFrame64;
begin
  Say('');
  Say('--- Q2 (x64): .pdata / UNWIND_INFO per frame ---------------------------');
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(hThread, Ctx) then begin
    Say('GetThreadContext FAILED err=' + IntToStr(GetLastError));
    Exit;
  end;
  if not SymInitialize(GProcess, nil, True) then
    Say('(SymInitialize failed err=' + IntToStr(GetLastError) + ' -- walk may be short)');

  Walk := Ctx;
  Frame := Default(TDbgStackFrame64);
  Frame.AddrPC.Offset    := Ctx.Rip;   Frame.AddrPC.Mode    := AddrModeFlat;
  Frame.AddrFrame.Offset := Ctx.Rbp;   Frame.AddrFrame.Mode := AddrModeFlat;
  Frame.AddrStack.Offset := Ctx.Rsp;   Frame.AddrStack.Mode := AddrModeFlat;

  var Index := 0;
  while (Index < GFrameCount) and
        StackWalk64(MachineAmd64, GProcess, hThread, Frame, @Walk, nil,
          @SymFunctionTableAccess64, @SymGetModuleBase64, nil) do begin
    var Pc := Frame.AddrPC.Offset;
    if Pc = 0 then
      Break;
    Say('');
    Say(Format('#%-2d %s', [Index, DescribeVa(Pc)]));
    var M: TModuleInfo;
    if not FindModule(Pc, M) then begin
      Say('    (no module)');
      Inc(Index);
      Continue;
    end;
    var RF: TRuntimeFunction;
    if not FindRuntimeFunction(M, DWORD(Pc - M.Base), RF) then begin
      Say('    no RUNTIME_FUNCTION covers this address');
      Inc(Index);
      Continue;
    end;
    Say(Format('    RUNTIME_FUNCTION Begin=%s End=%s Unwind=%s',
      [Hex(RF.BeginAddress), Hex(RF.EndAddress), Hex(RF.UnwindData)]));
    GFrameRva := DWORD(Pc - M.Base);
    DumpUnwindInfo(M, RF.UnwindData, 0, '    ');
    Inc(Index);
  end;
  SymCleanup(GProcess);
end;

{ ------------------------------------------------------ x86 fs:[0] SEH chain -- }

function Wow64FsBase(hThread: THandle; out Base: UInt64; out How: string): Boolean;
var
  Ctx: TWow64Context;
  Ldt: TLdtEntry;
begin
  Base := 0;
  How := '';
  Result := False;
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_CONTROL or WOW64_CONTEXT_SEGMENTS or WOW64_CONTEXT_INTEGER;
  if not Wow64GetThreadContext(hThread, Ctx) then begin
    How := 'Wow64GetThreadContext failed err=' + IntToStr(GetLastError);
    Exit;
  end;
  Ldt := Default(TLdtEntry);
  if Wow64GetThreadSelectorEntry(hThread, Ctx.SegFs, Ldt) then begin
    Base := UInt64(Ldt.BaseLow) or (UInt64(Ldt.BaseMid) shl 16) or (UInt64(Ldt.BaseHi) shl 24);
    How := Format('Wow64GetThreadSelectorEntry(fs=%s)', [Hex(Ctx.SegFs)]);
    Result := Base <> 0;
    if Result then
      Exit;
  end
  else
    How := Format('Wow64GetThreadSelectorEntry(fs=%s) failed err=%d',
      [Hex(Ctx.SegFs), GetLastError]);
  // Fallback: the 32-bit TEB sits at TEB64+$2000 in a WOW64 process. Verified,
  // not assumed: TEB32+$18 (Self) must point back at the computed address.
  // THREAD_BASIC_INFORMATION is exactly 48 bytes on x64 (ExitStatus+pad 8,
  // TebBaseAddress 8, ClientId 16, AffinityMask 8, Priority+BasePriority 8);
  // handing NtQueryInformationThread any other length returns
  // STATUS_INFO_LENGTH_MISMATCH and the fallback silently never works.
  var Info: array[0..5] of UInt64;   // THREAD_BASIC_INFORMATION, 48 bytes
  FillChar(Info, SizeOf(Info), 0);
  var St := NtQueryInformationThread(hThread, 0, @Info[0], SizeOf(Info), nil);
  if St < 0 then begin
    How := How + Format('; NtQueryInformationThread failed status=$%s', [IntToHex(St, 8)]);
    Exit;
  end;
  var Teb64 := Info[1];
  var Teb32 := Teb64 + $2000;
  var SelfPtr: DWORD;
  if ReadU32(Teb32 + $18, SelfPtr) and (UInt64(SelfPtr) = Teb32) then begin
    Base := Teb32;
    How := Format('TEB64(%s)+$2000, Self field verified', [Hex(Teb64)]);
    Exit(True);
  end;
  How := How + Format('; TEB64=%s TEB32 self-check failed', [Hex(Teb64)]);
end;

procedure DumpSehHandlerStub(HandlerVa: UInt64; const Indent: string);
const
  WordsAfterStub = 10;
var
  Stub: array[0..15] of Byte;
begin
  if not ReadMem(HandlerVa, @Stub[0], SizeOf(Stub)) then begin
    Say(Indent + 'handler bytes unreadable');
    Exit;
  end;
  Say(Format('%sbytes at handler: %s %s %s %s %s %s %s %s',
    [Indent, IntToHex(Stub[0], 2), IntToHex(Stub[1], 2), IntToHex(Stub[2], 2),
     IntToHex(Stub[3], 2), IntToHex(Stub[4], 2), IntToHex(Stub[5], 2),
     IntToHex(Stub[6], 2), IntToHex(Stub[7], 2)]));
  var TableVa := HandlerVa;
  if Stub[0] = $E9 then begin
    var Rel := PInteger(@Stub[1])^;
    var Target := UInt64(Int64(HandlerVa) + 5 + Rel);
    Say(Format('%sjmp rel32 -> %s', [Indent, DescribeVa(Target)]));
    TableVa := HandlerVa + 5;
  end
  else
    Say(Indent + 'handler does not start with a jmp rel32');

  // Decode the words after the stub as a clause table:
  //   DWORD Count; Count x { DWORD ClassVmtVA; DWORD BlockVA }   (ABSOLUTE VAs)
  // Only the decoded block addresses become candidates -- an INT3 written over
  // the count word would corrupt dispatch instead of stopping it.
  var Count: DWORD;
  if ReadU32(TableVa, Count) and (Count > 0) and (Count <= 64) then begin
    Say(Format('%sclause table: %d clause(s)', [Indent, Count]));
    for var I := 0 to Integer(Count) - 1 do begin
      var Pair: array[0..1] of DWORD;
      if not ReadMem(TableVa + 4 + UInt64(I) * 8, @Pair[0], SizeOf(Pair)) then
        Break;
      var Where: string;
      if (GMainBase <> 0) and (UInt64(Pair[1]) > GMainBase) and
         IsUserCodeRva(UInt64(Pair[1]) - GMainBase, Where) then begin
        Say(Format('%s  on <vmt %s> -> block %s = %s  *** USER BLOCK ***',
          [Indent, Hex(Pair[0]), Hex(Pair[1]), Where]));
        NoteCandidate(Pair[1]);
      end
      else
        Say(Format('%s  on <vmt %s> -> block %s (not user code -- table shape may not apply here)',
          [Indent, Hex(Pair[0]), Hex(Pair[1])]));
    end;
  end
  else
    Say(Indent + 'no plausible clause table follows the stub');

  Say(Indent + 'words following the stub (evidence only):');
  for var I := 0 to WordsAfterStub - 1 do begin
    var W: DWORD;
    if not ReadU32(TableVa + UInt64(I) * 4, W) then
      Break;
    Say(Format('%s  +%.2x %s', [Indent, I * 4, Hex(W)]));
  end;
end;

procedure AnalyseX86Seh(hThread: THandle);
begin
  Say('');
  Say('--- Q2 (x86): fs:[0] SEH registration chain ----------------------------');
  var FsBase: UInt64;
  var How: string;
  if not Wow64FsBase(hThread, FsBase, How) then begin
    Say('could not locate the 32-bit TEB: ' + How);
    Exit;
  end;
  Say(Format('TEB32 / fs base = %s  (%s)', [Hex(FsBase), How]));

  var Head: DWORD;
  if not ReadU32(FsBase, Head) then begin
    Say('fs:[0] unreadable');
    Exit;
  end;
  Say(Format('fs:[0] = %s', [Hex(Head)]));

  var Rec := UInt64(Head);
  var Index := 0;
  while (Rec <> 0) and (Rec <> $FFFFFFFF) and (Index < 24) do begin
    var Pair: array[0..1] of DWORD;
    if not ReadMem(Rec, @Pair[0], SizeOf(Pair)) then begin
      Say(Format('  [%d] record at %s unreadable', [Index, Hex(Rec)]));
      Break;
    end;
    Say('');
    Say(Format('  [%d] record@%s  Next=%s  Handler=%s',
      [Index, Hex(Rec), Hex(Pair[0]), Hex(Pair[1])]));
    Say(Format('       handler -> %s', [DescribeVa(Pair[1])]));
    // The Handler field of a Delphi registration record is not RTL code: it is a
    // stub INSIDE the protected routine, so it is itself a candidate address.
    var HandlerWhere: string;
    if (GMainBase <> 0) and (UInt64(Pair[1]) > GMainBase) and
       IsUserCodeRva(UInt64(Pair[1]) - GMainBase, HandlerWhere) then begin
      Say('       handler resolves to ' + HandlerWhere + '  *** IN-MODULE STUB ***');
      NoteCandidate(Pair[1]);
    end;
    var Extra: array[0..7] of DWORD;
    if ReadMem(Rec, @Extra[0], SizeOf(Extra)) then begin
      var S := '';
      for var K := 0 to High(Extra) do
        S := S + Hex(Extra[K]) + ' ';
      Say('       record words: ' + Trim(S));
    end;
    DumpSehHandlerStub(Pair[1], '       ');
    Rec := UInt64(Pair[0]);
    Inc(Index);
  end;
  Say(Format('  (%d registration records walked)', [Index]));
end;

{ -------------------------------------------------------- Q1: trap flag -- }

function ArmTrapFlag(hThread: THandle): Boolean;
begin
  Result := False;
  if GIsWow64 then begin
    var Ctx := Default(TWow64Context);
    Ctx.ContextFlags := WOW64_CONTEXT_CONTROL or WOW64_CONTEXT_INTEGER;
    if not Wow64GetThreadContext(hThread, Ctx) then begin
      Say('  Wow64GetThreadContext FAILED err=' + IntToStr(GetLastError));
      Exit;
    end;
    Say(Format('  before: EIP=%s EFLAGS=%s TF=%d',
      [Hex(Ctx.Eip), Hex(Ctx.EFlags), Ord((Ctx.EFlags and TRAP_FLAG) <> 0)]));
    Ctx.EFlags := Ctx.EFlags or TRAP_FLAG;
    if not Wow64SetThreadContext(hThread, Ctx) then begin
      Say('  Wow64SetThreadContext FAILED err=' + IntToStr(GetLastError));
      Exit;
    end;
    var Back := Default(TWow64Context);
    Back.ContextFlags := WOW64_CONTEXT_CONTROL or WOW64_CONTEXT_INTEGER;
    if not Wow64GetThreadContext(hThread, Back) then
      Exit;
    Result := (Back.EFlags and TRAP_FLAG) <> 0;
    Say(Format('  after : EIP=%s EFLAGS=%s TF=%d  (readback %s)',
      [Hex(Back.Eip), Hex(Back.EFlags), Ord(Result),
       IfThen(Result, 'CONFIRMS the write took', 'says the write did NOT take')]));
  end
  else begin
    var Ctx := Default(TContext);
    Ctx.ContextFlags := CONTEXT_CONTROL or CONTEXT_INTEGER;
    if not GetThreadContext(hThread, Ctx) then begin
      Say('  GetThreadContext FAILED err=' + IntToStr(GetLastError));
      Exit;
    end;
    Say(Format('  before: RIP=%s EFLAGS=%s TF=%d',
      [Hex(Ctx.Rip), Hex(Ctx.EFlags), Ord((Ctx.EFlags and TRAP_FLAG) <> 0)]));
    Ctx.EFlags := Ctx.EFlags or TRAP_FLAG;
    if not SetThreadContext(hThread, Ctx) then begin
      Say('  SetThreadContext FAILED err=' + IntToStr(GetLastError));
      Exit;
    end;
    var Back := Default(TContext);
    Back.ContextFlags := CONTEXT_CONTROL or CONTEXT_INTEGER;
    if not GetThreadContext(hThread, Back) then
      Exit;
    Result := (Back.EFlags and TRAP_FLAG) <> 0;
    Say(Format('  after : RIP=%s EFLAGS=%s TF=%d  (readback %s)',
      [Hex(Back.Rip), Hex(Back.EFlags), Ord(Result),
       IfThen(Result, 'CONFIRMS the write took', 'says the write did NOT take')]));
  end;
end;

{ ------------------------------------------------------------------- main -- }

type
  TPlanted = record
    VA: UInt64;
    Orig: Byte;
  end;

var
  GPlanted: TArray<TPlanted>;

procedure PlantCandidates;
begin
  SetLength(GPlanted, 0);
  for var VA in GCandidates do begin
    var Orig: Byte := 0;
    if not ReadMem(VA, @Orig, 1) then begin
      Say('  cannot read at ' + Hex(VA) + ' -- not planting');
      Continue;
    end;
    var Cc: Byte := $CC;
    var Written: NativeUInt := 0;
    var Old: DWORD := 0;
    VirtualProtectEx(GProcess, Pointer(VA), 1, PAGE_EXECUTE_READWRITE, Old);
    if WriteProcessMemory(GProcess, Pointer(VA), @Cc, 1, Written) and (Written = 1) then begin
      FlushInstructionCache(GProcess, Pointer(VA), 1);
      SetLength(GPlanted, Length(GPlanted) + 1);
      GPlanted[High(GPlanted)].VA := VA;
      GPlanted[High(GPlanted)].Orig := Orig;
      Say(Format('  INT3 planted at %s (orig byte %s)', [DescribeVa(VA), IntToHex(Orig, 2)]));
    end
    else
      Say('  WriteProcessMemory FAILED at ' + Hex(VA));
    VirtualProtectEx(GProcess, Pointer(VA), 1, Old, Old);
  end;
end;

function UnplantAt(VA: UInt64): Boolean;
begin
  Result := False;
  for var I := 0 to High(GPlanted) do
    if GPlanted[I].VA = VA then begin
      var Written: NativeUInt := 0;
      var Old: DWORD := 0;
      VirtualProtectEx(GProcess, Pointer(VA), 1, PAGE_EXECUTE_READWRITE, Old);
      WriteProcessMemory(GProcess, Pointer(VA), @GPlanted[I].Orig, 1, Written);
      VirtualProtectEx(GProcess, Pointer(VA), 1, Old, Old);
      FlushInstructionCache(GProcess, Pointer(VA), 1);
      Exit(True);
    end;
end;

procedure RewindPcOverInt3(hThread: THandle; VA: UInt64);
begin
  if GIsWow64 then begin
    var Ctx := Default(TWow64Context);
    Ctx.ContextFlags := WOW64_CONTEXT_CONTROL;
    if Wow64GetThreadContext(hThread, Ctx) then begin
      Ctx.Eip := DWORD(VA);
      Wow64SetThreadContext(hThread, Ctx);
    end;
  end
  else begin
    var Ctx := Default(TContext);
    Ctx.ContextFlags := CONTEXT_CONTROL;
    if GetThreadContext(hThread, Ctx) then begin
      Ctx.Rip := VA;
      SetThreadContext(hThread, Ctx);
    end;
  end;
end;

procedure Run(const ExePath, TargetArgs, MapPath: string; WantCode: DWORD;
  SkipCount: Integer; DoTf, DoPlant: Boolean; ContinueStatusAfter: DWORD;
  EventsAfter, TimeoutMs: Integer);
var
  Ev: TDebugEvent;
  Si: TStartupInfo;
  Pi: TProcessInformation;
  CmdLine: string;
begin
  CmdLine := '"' + ExePath + '"';
  if TargetArgs <> '' then
    CmdLine := CmdLine + ' ' + TargetArgs;
  // The debuggee is launched with NO console and its three standard handles
  // redirected to NUL. This probe relaunches the target dozens of times while
  // measuring, and without this every launch pops a console window that steals
  // the keyboard focus.
  //
  // These flags are legitimate HERE and BANNED in the adapter: an SW_HIDE in the
  // adapter's own CreateProcess once hid the VCL main forms of the applications
  // being debugged (TRAPS.md / project memory). Nothing in this block may be
  // carried across into DebuggerCore.
  var NulSec := Default(TSecurityAttributes);
  NulSec.nLength := SizeOf(NulSec);
  NulSec.bInheritHandle := True;
  var NulIn  := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
                  @NulSec, OPEN_EXISTING, 0, 0);
  var NulOut := CreateFile('NUL', GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
                  @NulSec, OPEN_EXISTING, 0, 0);
  Si := Default(TStartupInfo);
  Si.cb := SizeOf(Si);
  Si.dwFlags := STARTF_USESTDHANDLES;
  Si.hStdInput  := NulIn;
  Si.hStdOutput := NulOut;
  Si.hStdError  := NulOut;
  Pi := Default(TProcessInformation);
  var Mutable := CmdLine;
  UniqueString(Mutable);
  if not CreateProcess(nil, PChar(Mutable), nil, nil, True,
      DEBUG_ONLY_THIS_PROCESS or CREATE_NO_WINDOW, nil,
      PChar(ExtractFilePath(ExePath)), Si, Pi) then begin
    Say('CreateProcess FAILED err=' + IntToStr(GetLastError));
    Halt(2);
  end;
  CloseHandle(NulIn);
  CloseHandle(NulOut);
  Say(Format('launched %s pid=%d', [CmdLine, Pi.dwProcessId]));

  var Analysed := False;
  var Matches := 0;
  var PostEvents := 0;
  var Done := False;

  while (not Done) and WaitForDebugEvent(Ev, TimeoutMs) do begin
    var Status: DWORD := DBG_CONTINUE;

    case Ev.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT:
        begin
          GProcess := Ev.CreateProcessInfo.hProcess;
          GThreads.AddOrSetValue(Ev.dwThreadId, Ev.CreateProcessInfo.hThread);
          GMainBase := UInt64(Ev.CreateProcessInfo.lpBaseOfImage);
          var Fn: TIsWow64Process2 := GetProcAddress(GetModuleHandle('kernel32.dll'), 'IsWow64Process2');
          if Assigned(Fn) then begin
            var PM, NM: USHORT;
            if Fn(GProcess, PM, NM) then
              GIsWow64 := PM = USHORT(MachineI386);
          end;
          AddModule(GMainBase, ExePath);
          Say(Format('main image base=%s  target=%s',
            [Hex(GMainBase), IfThen(GIsWow64, 'WOW64 / x86', 'native x64')]));

          GTd32 := TTD32FileReader.Create;
          GTd32.LoadFromFile(ExePath);
          Say('TD32 debug info: ' + IfThen(GTd32.Loaded, 'loaded', 'NOT loaded'));
          if (MapPath <> '') and FileExists(MapPath) then begin
            GMap := TMapFile.Create;
            GMap.LoadFromFile(MapPath, 0, 0);
            GMap.WaitForIndex;
            Say('MAP: loaded ' + MapPath);
          end;
        end;

      CREATE_THREAD_DEBUG_EVENT:
        GThreads.AddOrSetValue(Ev.dwThreadId, Ev.CreateThread.hThread);

      LOAD_DLL_DEBUG_EVENT:
        AddModule(UInt64(Ev.LoadDll.lpBaseOfDll), PathFromHandle(Ev.LoadDll.hFile));

      EXIT_PROCESS_DEBUG_EVENT:
        begin
          Say('EXIT_PROCESS (analysed=' + BoolToStr(Analysed, True) + ')');
          Done := True;
        end;

      EXCEPTION_DEBUG_EVENT:
        begin
          var Code := Ev.Exception.ExceptionRecord.ExceptionCode;
          var Addr := UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress);
          var First := Ev.Exception.dwFirstChance <> 0;
          var hThread: THandle := 0;
          GThreads.TryGetValue(Ev.dwThreadId, hThread);

          if Analysed then begin
            Inc(PostEvents);
            Say('');
            Say(Format('POST-RESUME event %d: code=%s %s firstChance=%s tid=%d',
              [PostEvents, Hex(Code), ExceptionCodeName(Code), BoolToStr(First, True), Ev.dwThreadId]));
            Say('  at ' + DescribeVa(Addr));
            if IsSingleStep(Code) then
              Say('  *** SINGLE STEP -- the trap flag SURVIVED ***');
            if DoPlant and ((Code = DWORD(EXCEPTION_BREAKPOINT)) or (Code = STATUS_WX86_BREAKPOINT)) then begin
              // The reported address for an INT3 IS the INT3 byte's address.
              if UnplantAt(Addr) then begin
                Say('  *** this is one of OUR planted candidates -- REACHED ***');
                RewindPcOverInt3(hThread, Addr);
              end;
            end;
            if PostEvents >= EventsAfter then begin
              Say('');
              Say('(event budget spent; terminating debuggee)');
              Done := True;
            end;
            Status := DBG_EXCEPTION_NOT_HANDLED;
            if IsSingleStep(Code) or (Code = DWORD(EXCEPTION_BREAKPOINT)) or
               (Code = STATUS_WX86_BREAKPOINT) then
              Status := DBG_CONTINUE;
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, Status);
            Continue;
          end;

          var Interesting: Boolean;
          if WantCode <> 0 then
            Interesting := Code = WantCode
          else
            Interesting := (Code = DELPHI_EXCEPTION) or (Code = DWORD(EXCEPTION_ACCESS_VIOLATION));

          if First and Interesting then begin
            Inc(Matches);
            if Matches <= SkipCount then
              Status := DBG_EXCEPTION_NOT_HANDLED
            else begin
              Say('');
              Say('=======================================================================');
              Say(Format('FIRST-CHANCE STOP: code=%s %s tid=%d',
                [Hex(Code), ExceptionCodeName(Code), Ev.dwThreadId]));
              Say('  fault address ' + DescribeVa(Addr));
              Say(Format('  target: %s', [IfThen(GIsWow64, 'WOW64 / x86', 'native x64')]));

              if GIsWow64 then
                AnalyseX86Seh(hThread)
              else
                AnalyseX64Frames(hThread);

              Say('');
              Say(Format('--- candidates (main-exe addresses that map to a source line): %d',
                [GCandidates.Count]));
              for var VA in GCandidates do
                Say('    ' + DescribeVa(VA));

              if DoPlant then begin
                Say('');
                Say('--- planting INT3 at every candidate ---');
                PlantCandidates;
              end;

              if DoTf then begin
                Say('');
                Say('--- Q1: arming EFLAGS.TF ---');
                ArmTrapFlag(hThread);
              end;

              Status := ContinueStatusAfter;
              Say('');
              Say(Format('resuming with %s',
                [IfThen(Status = DBG_CONTINUE, 'DBG_CONTINUE (swallow)',
                                               'DBG_EXCEPTION_NOT_HANDLED (deliver)')]));
              Analysed := True;
            end;
          end
          else
            Status := DBG_EXCEPTION_NOT_HANDLED;

          if (Code = DWORD(EXCEPTION_BREAKPOINT)) or (Code = STATUS_WX86_BREAKPOINT) or
             IsSingleStep(Code) then
            if not Analysed then
              Status := DBG_CONTINUE;
        end;
    end;

    ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, Status);
  end;

  if not Analysed then
    Say('NO matching first-chance exception was ever observed.');

  TerminateProcess(Pi.hProcess, 0);
  CloseHandle(Pi.hThread);
  CloseHandle(Pi.hProcess);
end;

function ParseHex(const S: string; Default_: DWORD): DWORD;
var
  T: string;
begin
  T := S;
  if T.StartsWith('$') then T := T.Substring(1)
  else if T.StartsWith('0x', True) then T := T.Substring(2);
  var V: Int64;
  if TryStrToInt64('$' + T, V) then
    Result := DWORD(V)
  else
    Result := Default_;
end;

begin
  try
    if ParamCount < 1 then begin
      Say('usage: ExcHandlerProbe <target.exe> [-args "<debuggee args>"] [-map <file.map>]');
      Say('                       [-code <hex>] [-skip N] [-frames N]');
      Say('                       [-tf] [-cont handled|notHandled] [-events N]');
      Say('                       [-plant] [-allscopes] [-timeout MS]');
      Halt(1);
    end;
    var ExePath := ExpandFileName(ParamStr(1));
    var TargetArgs := '';
    var MapPath := ChangeFileExt(ExePath, '.map');
    var WantCode: DWORD := 0;
    var SkipCount := 0;
    var DoTf := False;
    var DoPlant := False;
    var ContAfter: DWORD := DBG_EXCEPTION_NOT_HANDLED;
    var EventsAfter := 4;
    var TimeoutMs := 20000;

    var I := 2;
    while I <= ParamCount do begin
      var A := ParamStr(I);
      if SameText(A, '-args') and (I < ParamCount) then begin
        TargetArgs := ParamStr(I + 1); Inc(I, 2);
      end
      else if SameText(A, '-map') and (I < ParamCount) then begin
        MapPath := ParamStr(I + 1); Inc(I, 2);
      end
      else if SameText(A, '-code') and (I < ParamCount) then begin
        WantCode := ParseHex(ParamStr(I + 1), 0); Inc(I, 2);
      end
      else if SameText(A, '-skip') and (I < ParamCount) then begin
        SkipCount := StrToIntDef(ParamStr(I + 1), 0); Inc(I, 2);
      end
      else if SameText(A, '-frames') and (I < ParamCount) then begin
        GFrameCount := StrToIntDef(ParamStr(I + 1), GFrameCount); Inc(I, 2);
      end
      else if SameText(A, '-events') and (I < ParamCount) then begin
        EventsAfter := StrToIntDef(ParamStr(I + 1), EventsAfter); Inc(I, 2);
      end
      else if SameText(A, '-timeout') and (I < ParamCount) then begin
        TimeoutMs := StrToIntDef(ParamStr(I + 1), TimeoutMs); Inc(I, 2);
      end
      else if SameText(A, '-cont') and (I < ParamCount) then begin
        if SameText(ParamStr(I + 1), 'handled') then
          ContAfter := DBG_CONTINUE
        else
          ContAfter := DBG_EXCEPTION_NOT_HANDLED;
        Inc(I, 2);
      end
      else if SameText(A, '-tf') then begin
        DoTf := True; Inc(I);
      end
      else if SameText(A, '-plant') then begin
        DoPlant := True; Inc(I);
      end
      else if SameText(A, '-allscopes') then begin
        GAllScopes := True; Inc(I);
      end
      else
        Inc(I);
    end;

    GModules := TList<TModuleInfo>.Create;
    GThreads := TDictionary<DWORD, THandle>.Create;
    GCandidates := TList<UInt64>.Create;
    try
      Run(ExePath, TargetArgs, MapPath, WantCode, SkipCount, DoTf, DoPlant,
        ContAfter, EventsAfter, TimeoutMs);
    finally
      GCandidates.Free;
      GThreads.Free;
      GModules.Free;
      GTd32.Free;
      GMap.Free;
    end;
  except
    on E: Exception do begin
      Say(E.ClassName + ': ' + E.Message);
      Halt(9);
    end;
  end;
end.
