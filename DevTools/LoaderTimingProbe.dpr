program LoaderTimingProbe;

// What the Windows loader has done, and what code has run, at each debug event
// of a process start or of an attach (docs\PROFILER_COVERAGE_PLAN.md, increment
// 1, assumptions 3, 4 and 5). A raw Windows debug loop with no engine in it; a
// 64-bit tool that drives 64-bit and 32-bit (WOW64) targets.
//
//   LoaderTimingProbe -pe [-zydisdll <path>] <image> [<image>...]
//     Static. Per image: the PE header flags that decide relocation (read from
//     the file, never taken from a compiler directive), the `.reloc` section, the
//     base relocations by kind and by section, and the instruction this tool
//     would watch: one that is reached from a TD32 line record and carries a
//     relocated absolute operand.
//
//   LoaderTimingProbe -run [options] <exe> [args...]
//     Launches the target under DEBUG_ONLY_THIS_PROCESS and lists every debug
//     event in order: module loads (with the preferred and the actual base),
//     thread starts, breakpoint exceptions (native $80000003 and WOW64
//     $4000001F, with the module the address belongs to and the modules mapped
//     at that moment), debug strings, and the one-shot $CC bytes this tool
//     plants. A one-shot is planted the moment its module is mapped (the
//     executable at CREATE_PROCESS_DEBUG_EVENT, a DLL at its
//     LOAD_DLL_DEBUG_EVENT); when it fires the saved byte goes back and the
//     program counter is rewound.
//
//     -entries all|own|none  one-shots on module entry points: every module
//                            (default), the modules in the executable's
//                            directory, or none.
//     -lines <module>        also a one-shot on every TD32 line record of that
//                            module that lies in a routine (base file name;
//                            repeatable). The listing
//                            then shows which line of the module ran first, and
//                            whether anything ran before its entry point.
//     -reloc <module>        watch the module's relocation (repeatable): the
//                            bytes of an instruction with a relocated operand,
//                            and of one relocated slot in a code section and one
//                            in a data section, read at the load event, at the
//                            entry-point one-shot and at process exit, next to
//                            what the file holds and what a relocated image must
//                            hold.
//     -plantsite             with -reloc: a one-shot on the first byte of the
//                            watched instruction, planted at the load event.
//     -jmppatch              with -reloc: the negative experiment. Writes a
//                            five-byte `jmp rel32` over the watched instruction
//                            at the load event, reads it back at the entry-point
//                            one-shot, reports what the loader made of it, and
//                            repairs the instruction before anything runs it.
//     -baseline              first runs the target under the same loop with
//                            nothing planted, then compares exit code, stdout
//                            and the sequence of debug strings of the two runs.
//     -anyrecord             with -lines: also the records the TD32 reader attributes
//                            to no routine. They are not code (the record of a
//                            unit's final `end.` points at data), so this is a
//                            negative control and can make the target fault.
//     -quiet                 no event listing, reports only.
//
//     At process exit every code section of a module that carried one-shots or
//     a -reloc watch is compared with the file's bytes relocated by the actual
//     delta, and every saved byte with the file's byte.
//
//   LoaderTimingProbe -attach [options] <exe> [args...]
//     Starts the target WITHOUT a debugger, waits for it to print
//     `counter=<hex> release=<hex>` on stdout (the addresses of a 32-bit counter
//     it keeps incrementing and of a 32-bit flag it waits on), attaches with
//     DebugActiveProcess and lists the synthesised events and the break-in, with
//     the counter read at every event: a counter that moves between two events
//     means the target's own threads ran between them. Plants nothing. 300 ms
//     after the break-in it writes 1 to the release flag and lists the rest of
//     the run.
//
//   Common options:
//     -path <dir>      prepended to the PATH the target inherits (repeatable);
//                      for a target built with runtime packages.
//     -timeout <s>     kill the target after that long (default 60).
//     -zydisdll <path> Zydis.dll; default next to this tool, then
//                      ThirdParty\Zydis\bin\x64 of the repository.
//
// Nothing is tied to one binary: targets, module names and counts come from the
// command line. The fixtures this tool was written against are in
// DevTools\Fixtures\LoaderTiming (build_loader_fixtures.bat).
//
// Simplifications:
// - The watched instruction is searched by decoding forward from each TD32 line
//   record up to the next one, stopping at the first `ret` or `jmp`, so that the
//   data dcc places after a routine is never taken for code. An instruction
//   behind a jump inside one source line is therefore not seen.
// - A breakpoint this tool did not plant is continued when it lies in ntdll
//   (the loader's own, or the attach break-in) and passed to the program
//   otherwise.
// - "Later" in the relocation watch is the process exit event, where the address
//   space is still intact.

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Win.Registry,
  DebugInfoTypes,
  TD32FileReader,
  ZydisApi;

{ ----------------------------------------------------------------- bindings -- }

const
  STATUS_WX86_BREAKPOINT   = DWORD($4000001F);
  HANDLE_LIST_ATTRIBUTE    = $00020002;   // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
  MACHINE_I386             = $014C;
  MACHINE_AMD64            = $8664;
  RELOC_HIGHLOW            = 3;
  RELOC_DIR64              = 10;
  SECTION_HAS_CODE         = $00000020;
  SECTION_EXECUTABLE       = $20000000;
  FILE_RELOCS_STRIPPED     = $0001;
  FILE_LARGE_ADDRESS_AWARE = $0020;
  FILE_IS_DLL              = $2000;
  DLLCHAR_HIGH_ENTROPY_VA  = $0020;
  DLLCHAR_DYNAMIC_BASE     = $0040;
  DLLCHAR_NX_COMPAT        = $0100;
  ASLR_POLICY              = 1;           // ProcessASLRPolicy
  TIMEOUT_EXIT_CODE        = $DEAD;
  INT3                     = $CC;
  JMP_PATCH_LENGTH         = 5;
  WATCH_BYTES              = 12;
  RELEASE_DELAY_MS         = 300;
  MAX_LISTED_MISMATCHES    = 6;

type
  TStartupInfoWithAttributes = record
    StartupInfo:   TStartupInfo;
    AttributeList: PProcThreadAttributeList;
  end;

function FinalPathNameByHandle(hFile: THandle; lpszFilePath: PWideChar; cchFilePath, dwFlags: DWORD): DWORD; stdcall;
  external kernel32 name 'GetFinalPathNameByHandleW';
function MappedFileName(hProcess: THandle; lpv: Pointer; lpFilename: PWideChar; nSize: DWORD): DWORD; stdcall;
  external 'psapi.dll' name 'GetMappedFileNameW';
function QueryMitigationPolicy(hProcess: THandle; MitigationPolicy: Integer; lpBuffer: Pointer;
  dwLength: NativeUInt): BOOL; stdcall; external kernel32 name 'GetProcessMitigationPolicy';

{ ------------------------------------------------------------------ helpers -- }

function HexBytes(const Bytes: TBytes): string;
begin
  Result := '';
  for var Value in Bytes do
    Result := Result + IntToHex(Value, 2) + ' ';
  Result := TrimRight(Result);
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function MachineName(Machine: Word): string;
begin
  case Machine of
    MACHINE_I386:  Result := '32-bit';
    MACHINE_AMD64: Result := '64-bit';
  else
    Result := 'machine $' + IntToHex(Machine, 4);
  end;
end;

function YesNo(Value: Boolean): string;
begin
  if Value then
    Result := 'yes'
  else
    Result := 'no';
end;

function PhysicalCoreCount: Integer;
begin
  Result := 0;
  var Needed: DWORD := 0;
  GetLogicalProcessorInformation(nil, Needed);
  if Needed = 0 then
    Exit;
  var Buffer: TBytes;
  SetLength(Buffer, Needed);
  if not GetLogicalProcessorInformation(PSystemLogicalProcessorInformation(@Buffer[0]), Needed) then
    Exit;
  var Entry := PSystemLogicalProcessorInformation(@Buffer[0]);
  for var I := 1 to Integer(Needed div SizeOf(TSystemLogicalProcessorInformation)) do begin
    if Entry^.Relationship = RelationProcessorCore then
      Inc(Result);
    Inc(Entry);
  end;
end;

function MachineDescription: string;
begin
  var Cpu: string := '?';
  var Build: string := '?';
  var Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if Registry.OpenKeyReadOnly('HARDWARE\DESCRIPTION\System\CentralProcessor\0') then begin
      Cpu := Trim(Registry.ReadString('ProcessorNameString'));
      Registry.CloseKey;
    end;
    if Registry.OpenKeyReadOnly('SOFTWARE\Microsoft\Windows NT\CurrentVersion') then begin
      Build := Registry.ReadString('CurrentBuild');
      if Registry.ValueExists('UBR') then
        Build := Build + '.' + IntToStr(Registry.ReadInteger('UBR'));
      if Registry.ValueExists('DisplayVersion') then
        Build := Build + ' (' + Registry.ReadString('DisplayVersion') + ')';
      Registry.CloseKey;
    end;
  finally
    Registry.Free;
  end;
  Result := Format('%s, %d cores / %d logical, Windows build %s', [Cpu, PhysicalCoreCount, CPUCount, Build]);
end;

function QuoteArgument(const Value: string): string;
begin
  if (Value <> '') and (Value.IndexOfAny([' ', #9, '"']) < 0) then
    Exit(Value);
  // A backslash run before the closing quote would escape it.
  var Trailing := 0;
  while (Trailing < Value.Length) and (Value[Value.Length - Trailing] = '\') do
    Inc(Trailing);
  Result := '"' + Value.Replace('"', '\"') + StringOfChar('\', Trailing) + '"';
end;

function ResolveZydisDll(const OverridePath: string): string;
begin
  if OverridePath <> '' then
    Exit(OverridePath);
  var Dir := ExtractFileDir(ParamStr(0));
  Result := TPath.Combine(Dir, 'Zydis.dll');
  if FileExists(Result) then
    Exit;
  for var Up := 1 to 6 do begin
    Dir := ExtractFileDir(Dir);
    if Dir = '' then
      Break;
    Result := TPath.Combine(Dir, 'ThirdParty\Zydis\bin\x64\Zydis.dll');
    if FileExists(Result) then
      Exit;
  end;
  Result := '';
end;

{ ----------------------------------------------------------------- PE files -- }

type
  TPeHeader = record
    Machine:            Word;
    Is64:               Boolean;
    Characteristics:    Word;
    DllCharacteristics: Word;
    ImageBase:          UInt64;
    EntryRva:           Cardinal;
    SizeOfImage:        Cardinal;
    RelocDirRva:        Cardinal;
    RelocDirSize:       Cardinal;
    SectionCount:       Integer;
    SectionTable:       Integer;   // offset of the first section header
  end;

  TPeSection = record
    Name:        string;
    Rva:         Cardinal;
    VirtualSize: Cardinal;
    RawOffset:   Cardinal;
    RawSize:     Cardinal;
    Flags:       Cardinal;
    function IsCode: Boolean;
  end;

  TPeFixup = record
    Rva:  Cardinal;
    Kind: Byte;
    function Width: Integer;
  end;

  // A PE image as the file holds it.
  TPeImage = class
  public
    Path:     string;
    Data:     TBytes;
    Header:   TPeHeader;
    Sections: TArray<TPeSection>;
    Fixups:   TArray<TPeFixup>;   // ascending RVA
    constructor Create(const APath: string);
    function SectionIndexOf(Rva: Cardinal): Integer;
    function IsCodeRva(Rva: Cardinal): Boolean;
    function FileBytes(Rva: Cardinal; Count: Integer): TBytes;
    function RelocatedBytes(Rva: Cardinal; Count: Integer; Delta: Int64): TBytes;
    function FirstFixupAtOrAfter(Rva: Cardinal): Integer;
    function HasRelocSection: Boolean;
  end;

function TPeSection.IsCode: Boolean;
begin
  Result := (Flags and (SECTION_HAS_CODE or SECTION_EXECUTABLE)) <> 0;
end;

function TPeFixup.Width: Integer;
begin
  if Kind = RELOC_DIR64 then
    Result := 8
  else
    Result := 4;
end;

// Works on a file and on the first page of a mapped image alike.
function ParsePeHeader(const Data: TBytes; out Header: TPeHeader): Boolean;
begin
  Header := Default(TPeHeader);
  if Length(Data) < $40 then
    Exit(False);
  var NtOffset := PInteger(@Data[$3C])^;
  if (NtOffset <= 0) or (NtOffset + 24 + 240 > Length(Data)) or (PCardinal(@Data[NtOffset])^ <> $00004550) then
    Exit(False);
  Header.Machine         := PWord(@Data[NtOffset + 4])^;
  Header.SectionCount    := PWord(@Data[NtOffset + 6])^;
  Header.Characteristics := PWord(@Data[NtOffset + 22])^;
  var Optional := NtOffset + 24;
  Header.SectionTable := Optional + PWord(@Data[NtOffset + 20])^;
  Header.Is64         := PWord(@Data[Optional])^ = $020B;
  Header.EntryRva     := PCardinal(@Data[Optional + 16])^;
  if Header.Is64 then
    Header.ImageBase := PUInt64(@Data[Optional + 24])^
  else
    Header.ImageBase := PCardinal(@Data[Optional + 28])^;
  Header.SizeOfImage        := PCardinal(@Data[Optional + 56])^;
  Header.DllCharacteristics := PWord(@Data[Optional + 70])^;
  var Directories := Optional + 96;
  if Header.Is64 then
    Directories := Optional + 112;
  if PCardinal(@Data[Directories - 4])^ > 5 then begin
    Header.RelocDirRva  := PCardinal(@Data[Directories + 5 * 8])^;
    Header.RelocDirSize := PCardinal(@Data[Directories + 5 * 8 + 4])^;
  end;
  Result := True;
end;

constructor TPeImage.Create(const APath: string);
begin
  inherited Create;
  Path := APath;
  var Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Data, Stream.Size);
    Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  if not ParsePeHeader(Data, Header) then
    raise Exception.Create('not a PE image: ' + APath);

  SetLength(Sections, Header.SectionCount);
  for var I := 0 to Header.SectionCount - 1 do begin
    var Entry := Header.SectionTable + I * 40;
    var Name: AnsiString;
    SetString(Name, PAnsiChar(@Data[Entry]), 8);
    Sections[I].Name        := string(PAnsiChar(Name));
    Sections[I].VirtualSize := PCardinal(@Data[Entry + 8])^;
    Sections[I].Rva         := PCardinal(@Data[Entry + 12])^;
    Sections[I].RawSize     := PCardinal(@Data[Entry + 16])^;
    Sections[I].RawOffset   := PCardinal(@Data[Entry + 20])^;
    Sections[I].Flags       := PCardinal(@Data[Entry + 36])^;
  end;

  if (Header.RelocDirRva = 0) or (Header.RelocDirSize = 0) then
    Exit;
  var Table := FileBytes(Header.RelocDirRva, Header.RelocDirSize);
  var List := TList<TPeFixup>.Create;
  try
    var Position := 0;
    while Position + 8 <= Length(Table) do begin
      var PageRva := PCardinal(@Table[Position])^;
      var BlockSize := Integer(PCardinal(@Table[Position + 4])^);
      if (BlockSize < 8) or (Position + BlockSize > Length(Table)) then
        Break;
      for var Entry := 0 to (BlockSize - 8) div 2 - 1 do begin
        var Item := PWord(@Table[Position + 8 + Entry * 2])^;
        var Fixup: TPeFixup;
        Fixup.Kind := Item shr 12;
        Fixup.Rva  := PageRva + (Item and $0FFF);
        if Fixup.Kind in [RELOC_HIGHLOW, RELOC_DIR64] then
          List.Add(Fixup);
      end;
      Inc(Position, BlockSize);
    end;
    List.Sort(TComparer<TPeFixup>.Construct(function(const A, B: TPeFixup): Integer
      begin
        Result := Integer(A.Rva > B.Rva) - Integer(A.Rva < B.Rva);
      end));
    Fixups := List.ToArray;
  finally
    List.Free;
  end;
end;

function TPeImage.SectionIndexOf(Rva: Cardinal): Integer;
begin
  for var I := 0 to High(Sections) do begin
    var Size := Sections[I].VirtualSize;
    if Size = 0 then
      Size := Sections[I].RawSize;
    if (Rva >= Sections[I].Rva) and (Rva < Sections[I].Rva + Size) then
      Exit(I);
  end;
  Result := -1;
end;

function TPeImage.IsCodeRva(Rva: Cardinal): Boolean;
begin
  var Index := SectionIndexOf(Rva);
  Result := (Index >= 0) and Sections[Index].IsCode;
end;

// Zero where the file has nothing (the tail of a section past its raw data).
function TPeImage.FileBytes(Rva: Cardinal; Count: Integer): TBytes;
begin
  SetLength(Result, Count);
  if Count = 0 then
    Exit;
  FillChar(Result[0], Count, 0);
  for var I := 0 to Count - 1 do begin
    var At := Rva + Cardinal(I);
    var Index := SectionIndexOf(At);
    if Index < 0 then
      Continue;
    var InSection := At - Sections[Index].Rva;
    if (InSection < Sections[Index].RawSize) and (Sections[Index].RawOffset + InSection < Cardinal(Length(Data))) then
      Result[I] := Data[Sections[Index].RawOffset + InSection];
  end;
end;

function TPeImage.FirstFixupAtOrAfter(Rva: Cardinal): Integer;
begin
  var Low := 0;
  var High := Length(Fixups);
  while Low < High do begin
    var Middle := (Low + High) div 2;
    if Fixups[Middle].Rva < Rva then
      Low := Middle + 1
    else
      High := Middle;
  end;
  Result := Low;
end;

// What a correctly relocated image holds at Rva: the file's bytes with Delta
// added to every relocated field, including one that only partly overlaps.
function TPeImage.RelocatedBytes(Rva: Cardinal; Count: Integer; Delta: Int64): TBytes;
const
  MARGIN = 8;
begin
  var First := Rva;
  if First >= MARGIN then
    Dec(First, MARGIN)
  else
    First := 0;
  var Wide := FileBytes(First, Count + Integer(Rva - First) + MARGIN);
  var Index := FirstFixupAtOrAfter(First);
  while (Index < Length(Fixups)) and (Fixups[Index].Rva + Cardinal(Fixups[Index].Width) <= First + Cardinal(Length(Wide))) do begin
    var Offset := Fixups[Index].Rva - First;
    if Fixups[Index].Kind = RELOC_DIR64 then
      PUInt64(@Wide[Offset])^ := UInt64(Int64(PUInt64(@Wide[Offset])^) + Delta)
    else
      PCardinal(@Wide[Offset])^ := Cardinal(Int64(PCardinal(@Wide[Offset])^) + Delta);
    Inc(Index);
  end;
  Result := Copy(Wide, Rva - First, Count);
end;

function TPeImage.HasRelocSection: Boolean;
begin
  for var Section in Sections do
    if SameText(Section.Name, '.reloc') then
      Exit(True);
  Result := False;
end;

{ -------------------------------------------- what a module's file says -- }

type
  TLineRecord = record
    Rva:        Cardinal;
    SourceFile: string;
    Line:       Integer;
    Routine:    string;
  end;

  // An instruction with a relocated operand, reached from a line record.
  TOperandSite = record
    Found:       Boolean;
    Rva:         Cardinal;
    Length:      Integer;
    FixupRva:    Cardinal;
    FixupWidth:  Integer;
    AtLineStart: Boolean;
    Text:        string;
    Where:       string;
  end;

  TModuleStatics = class
  public
    Pe:        TPeImage;
    HasTd32:   Boolean;
    Lines:     TArray<TLineRecord>;
    CodeFixups, DataFixups, OperandFixups, LineStartOperandFixups: Integer;
    Operand:   TOperandSite;
    CodeSlot, DataSlot: Integer;   // indexes into Pe.Fixups, -1 when there is none
    constructor Create(const Path: string);
    destructor Destroy; override;
    function LineIndexOf(Rva: Cardinal): Integer;
    function LineLabel(Index: Integer): string;
  private
    FSources: TDictionary<string, TStringList>;
    procedure LoadLines;
    procedure SurveyFixups;
    function SourceText(const FileName: string; Line: Integer): string;
  end;

constructor TModuleStatics.Create(const Path: string);
begin
  inherited Create;
  FSources := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  Pe := TPeImage.Create(Path);
  LoadLines;
  SurveyFixups;
end;

destructor TModuleStatics.Destroy;
begin
  FSources.Free;
  Pe.Free;
  inherited;
end;

// The line table comes from the engine's own reader. The reader keeps the image
// mapped while it lives, so everything needed is copied out and it is freed.
procedure TModuleStatics.LoadLines;
begin
  var Reader := TTD32FileReader.Create;
  try
    try
      Reader.LoadFromFile(Pe.Path);
    except
      on E: Exception do
        Exit;
    end;
    HasTd32 := Reader.Loaded;
    if not HasTd32 then
      Exit;
    var Rvas := Reader.SortedRvas;
    SetLength(Lines, Length(Rvas));
    for var I := 0 to High(Rvas) do begin
      Lines[I].Rva := Cardinal(Rvas[I]);
      var Location: TSourceLocation;
      if Reader.RvaToSourceLine(Rvas[I], Location) then begin
        Lines[I].SourceFile := Location.SourceFile;
        Lines[I].Line       := Location.Line;
      end;
      if not Reader.RvaToFunctionName(Rvas[I], Lines[I].Routine) then
        Lines[I].Routine := '';
    end;
  finally
    Reader.Free;
  end;
end;

function TModuleStatics.LineIndexOf(Rva: Cardinal): Integer;
begin
  for var I := 0 to High(Lines) do
    if Lines[I].Rva = Rva then
      Exit(I);
  Result := -1;
end;

// The source is looked for beside the module and up to three directories above
// it, which is where a Delphi project keeps it relative to .\<Platform>\<Config>.
function TModuleStatics.SourceText(const FileName: string; Line: Integer): string;
begin
  Result := '';
  var Lines_: TStringList;
  if not FSources.TryGetValue(FileName, Lines_) then begin
    Lines_ := TStringList.Create;
    FSources.Add(FileName, Lines_);
    var Dir := ExtractFileDir(Pe.Path);
    for var Up := 0 to 3 do begin
      var Candidate := TPath.Combine(Dir, FileName);
      if FileExists(Candidate) then begin
        Lines_.LoadFromFile(Candidate);
        Break;
      end;
      Dir := ExtractFileDir(Dir);
    end;
  end;
  if (Line >= 1) and (Line <= Lines_.Count) then
    Result := Trim(Lines_[Line - 1]);
  if Result.Length > 56 then
    Result := Result.Substring(0, 53) + '...';
end;

function TModuleStatics.LineLabel(Index: Integer): string;
begin
  var Item := Lines[Index];
  Result := Format('%s:%d', [Item.SourceFile, Item.Line]);
  if Item.Routine <> '' then
    Result := Result + ' [' + Item.Routine + ']';
  var Text := SourceText(Item.SourceFile, Item.Line);
  if Text <> '' then
    Result := Result + ' "' + Text + '"';
end;

procedure TModuleStatics.SurveyFixups;

  function EndsStraightLine(const Text: string): Boolean;
  begin
    Result := Text.StartsWith('ret') or Text.StartsWith('jmp') or Text.StartsWith('int3');
  end;

  function Better(const Candidate: TOperandSite): Boolean;
  begin
    if not Operand.Found then
      Exit(True);
    var CandidateLong := Candidate.Length >= JMP_PATCH_LENGTH;
    var CurrentLong := Operand.Length >= JMP_PATCH_LENGTH;
    if CandidateLong <> CurrentLong then
      Exit(CandidateLong);
    // A relocation delta is a multiple of 64K: it never changes the two low bytes
    // of a field. The jump patch is only disturbed when it covers a higher one.
    var CandidateHit := Candidate.FixupRva - Candidate.Rva + 2 < JMP_PATCH_LENGTH;
    var CurrentHit := Operand.FixupRva - Operand.Rva + 2 < JMP_PATCH_LENGTH;
    if CandidateHit <> CurrentHit then
      Exit(CandidateHit);
    Result := Candidate.AtLineStart and not Operand.AtLineStart;
  end;

begin
  CodeSlot := -1;
  DataSlot := -1;
  for var I := 0 to High(Pe.Fixups) do
    if Pe.IsCodeRva(Pe.Fixups[I].Rva) then begin
      Inc(CodeFixups);
      if CodeSlot < 0 then
        CodeSlot := I;
    end
    else begin
      Inc(DataFixups);
      if DataSlot < 0 then
        DataSlot := I;
    end;
  if (Length(Lines) = 0) or not ZydisAvailable then
    Exit;

  var Mode := zmmLegacy32;
  if Pe.Header.Is64 then
    Mode := zmmLong64;
  for var I := 0 to High(Lines) do begin
    var Start := Lines[I].Rva;
    if not Pe.IsCodeRva(Start) then
      Continue;
    var Stop := Start + 64;
    if I < High(Lines) then
      Stop := Lines[I + 1].Rva;
    if Stop > Start + 4096 then
      Stop := Start + 4096;
    var Position := Start;
    while Position < Stop do begin
      var Bytes := Pe.FileBytes(Position, 16);
      var Instruction: TZydisInstruction;
      if not ZydisDecodeOne(Mode, Pe.Header.ImageBase + Position, Bytes[0], Length(Bytes), Instruction) then
        Break;
      var Index := Pe.FirstFixupAtOrAfter(Position);
      if (Index < Length(Pe.Fixups)) and
         (Pe.Fixups[Index].Rva + Cardinal(Pe.Fixups[Index].Width) <= Position + Cardinal(Instruction.Length)) then begin
        Inc(OperandFixups);
        var Candidate := Default(TOperandSite);
        Candidate.Found       := True;
        Candidate.Rva         := Position;
        Candidate.Length      := Instruction.Length;
        Candidate.FixupRva    := Pe.Fixups[Index].Rva;
        Candidate.FixupWidth  := Pe.Fixups[Index].Width;
        Candidate.AtLineStart := Position = Start;
        Candidate.Text        := Instruction.Text;
        Candidate.Where       := LineLabel(I);
        if Candidate.AtLineStart then
          Inc(LineStartOperandFixups);
        if Better(Candidate) then
          Operand := Candidate;
      end;
      if EndsStraightLine(Instruction.Text) then
        Break;
      Inc(Position, Instruction.Length);
    end;
  end;
end;

procedure PrintStatics(Statics: TModuleStatics; const Indent: string);
begin
  var Header := Statics.Pe.Header;
  var Kind := 'PE32';
  if Header.Is64 then
    Kind := 'PE32+';
  Writeln(Indent, Format('%s (%s), preferred ImageBase %s, entry point +$%x, SizeOfImage $%x',
    [Kind, MachineName(Header.Machine), IntToHex(Header.ImageBase, 8), Header.EntryRva, Header.SizeOfImage]));
  Writeln(Indent, Format('Characteristics $%.4x: DLL=%s RELOCS_STRIPPED=%s LARGE_ADDRESS_AWARE=%s',
    [Header.Characteristics, YesNo((Header.Characteristics and FILE_IS_DLL) <> 0),
     YesNo((Header.Characteristics and FILE_RELOCS_STRIPPED) <> 0),
     YesNo((Header.Characteristics and FILE_LARGE_ADDRESS_AWARE) <> 0)]));
  Writeln(Indent, Format('DllCharacteristics $%.4x: DYNAMIC_BASE=%s HIGH_ENTROPY_VA=%s NX_COMPAT=%s',
    [Header.DllCharacteristics, YesNo((Header.DllCharacteristics and DLLCHAR_DYNAMIC_BASE) <> 0),
     YesNo((Header.DllCharacteristics and DLLCHAR_HIGH_ENTROPY_VA) <> 0),
     YesNo((Header.DllCharacteristics and DLLCHAR_NX_COMPAT) <> 0)]));
  var HighLow := 0;
  var Dir64 := 0;
  for var Fixup in Statics.Pe.Fixups do
    if Fixup.Kind = RELOC_DIR64 then
      Inc(Dir64)
    else
      Inc(HighLow);
  Writeln(Indent, Format('.reloc section: %s; relocation directory: rva $%x, %d bytes; fixups: %d HIGHLOW, %d DIR64',
    [YesNo(Statics.Pe.HasRelocSection), Header.RelocDirRva, Header.RelocDirSize, HighLow, Dir64]));
  Writeln(Indent, Format('fixups in code sections: %d, in other sections: %d', [Statics.CodeFixups, Statics.DataFixups]));
  if not Statics.HasTd32 then
    Writeln(Indent, 'no TD32 debug info: no line records, so no instruction can be named')
  else
    Writeln(Indent, Format('TD32 line records: %d; instructions reached from them that carry a fixup: %d (%d the first of a line)',
      [Length(Statics.Lines), Statics.OperandFixups, Statics.LineStartOperandFixups]));
  if Statics.Operand.Found then begin
    var Site := Statics.Operand;
    Writeln(Indent, Format('watched instruction: rva $%x, %d bytes, fixup at +%d (%d bytes), %s',
      [Site.Rva, Site.Length, Site.FixupRva - Site.Rva, Site.FixupWidth, Site.Where]));
    Writeln(Indent, Format('  %s   %s', [HexBytes(Statics.Pe.FileBytes(Site.Rva, Site.Length)), Site.Text]));
  end
  else if Statics.HasTd32 then
    Writeln(Indent, 'watched instruction: NONE. No instruction reached from a line record has a relocated operand');
end;

procedure RunPeMode(const Paths: TArray<string>);
begin
  Writeln('LoaderTimingProbe -pe');
  Writeln(ZydisStatusText);
  for var Path in Paths do begin
    Writeln;
    Writeln(ExtractFileName(Path), '  (', ExpandFileName(Path), ')');
    var Statics := TModuleStatics.Create(ExpandFileName(Path));
    try
      PrintStatics(Statics, '  ');
      var Line := '  sections:';
      for var Section in Statics.Pe.Sections do begin
        Line := Line + Format(' %s@$%x', [Section.Name, Section.Rva]);
        if Section.IsCode then
          Line := Line + '(code)';
      end;
      Writeln(Line);
    finally
      Statics.Free;
    end;
  end;
end;

{ ------------------------------------------------------------ child processes -- }

function InheritableSecurity: TSecurityAttributes;
begin
  Result := Default(TSecurityAttributes);
  Result.nLength        := SizeOf(Result);
  Result.bInheritHandle := True;
end;

function OpenNulForChild: THandle;
begin
  var Security := InheritableSecurity;
  Result := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @Security, OPEN_EXISTING, 0, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

function CreateChildOutputFile(const Path: string): THandle;
begin
  var Security := InheritableSecurity;
  Result := CreateFile(PChar(Path), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    @Security, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

function ReadSharedFile(const Path: string): TBytes;
begin
  Result := nil;
  var Handle := CreateFile(PChar(Path), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, 0, 0);
  if Handle = INVALID_HANDLE_VALUE then
    Exit;
  try
    var Size := GetFileSize(Handle, nil);
    if (Size = 0) or (Size = INVALID_FILE_SIZE) then
      Exit;
    SetLength(Result, Size);
    var Done: DWORD;
    if not ReadFile(Handle, Result[0], Size, Done, nil) then
      Done := 0;
    SetLength(Result, Done);
  finally
    CloseHandle(Handle);
  end;
end;

// A child never inherits this tool's standard handles: it gets StdInput and
// StdOutput (stderr shares the latter) and nothing else, the way
// TWinDebugger.LaunchWithCapturedStdio starts a console debuggee.
function LaunchWithStdHandles(const CommandLine: string; StdInput, StdOutput: THandle;
  CreationFlags: DWORD): TProcessInformation;
begin
  var ListSize: NativeUInt := 0;
  InitializeProcThreadAttributeList(nil, 1, 0, ListSize);
  var ListBuffer: TBytes;
  SetLength(ListBuffer, ListSize);
  var List := PProcThreadAttributeList(@ListBuffer[0]);
  if not InitializeProcThreadAttributeList(List, 1, 0, ListSize) then
    RaiseLastOSError;
  try
    var Inherited_: array[0..1] of THandle;
    Inherited_[0] := StdInput;
    Inherited_[1] := StdOutput;
    if not UpdateProcThreadAttribute(List, 0, HANDLE_LIST_ATTRIBUTE, @Inherited_[0], SizeOf(Inherited_), nil,
         PNativeUInt(nil)^) then
      RaiseLastOSError;
    var Startup := Default(TStartupInfoWithAttributes);
    Startup.StartupInfo.cb         := SizeOf(Startup);
    Startup.StartupInfo.dwFlags    := STARTF_USESTDHANDLES;
    Startup.StartupInfo.hStdInput  := StdInput;
    Startup.StartupInfo.hStdOutput := StdOutput;
    Startup.StartupInfo.hStdError  := StdOutput;
    Startup.AttributeList          := List;
    var Writable := CommandLine;
    UniqueString(Writable);
    if not CreateProcess(nil, PChar(Writable), nil, nil, True, CreationFlags or EXTENDED_STARTUPINFO_PRESENT,
         nil, nil, Startup.StartupInfo, Result) then
      RaiseLastOSError;
  finally
    DeleteProcThreadAttributeList(List);
  end;
end;

{ -------------------------------------------------------------- the debug loop -- }

type
  TEntryScope = (esNone, esOwn, esAll);
  TOneShotKind = (osEntry, osLine, osSite);

  TWatchSite = record
    Title:      string;
    Rva:        Cardinal;
    Count:      Integer;
    FixupRva:   Cardinal;
    FixupWidth: Integer;
    FileBytes, Expected, AtLoad, AtEntry, AtExit: TBytes;
  end;

  TModule = class
  public
    Base:            UInt64;
    Size:            Cardinal;
    Path, Name:      string;
    Machine:         Word;
    EntryRva:        Cardinal;
    HeaderImageBase: UInt64;     // the ImageBase field of the MAPPED header, at the load event
    IsMain, Own, Unloaded: Boolean;
    LoadEvent, UnloadEvent: Integer;
    Statics:         TModuleStatics;
    WatchRelocation: Boolean;
    Sites:           TArray<TWatchSite>;
    EntryPlanted, EntryFired: Boolean;
    ShotsPlanted, ShotsFired, AlreadyInt3: Integer;
    JmpWritten, JmpReadBack, JmpBefore: TBytes;
    JmpVA:           UInt64;
    destructor Destroy; override;
    function Delta: Int64;
    function Contains(VA: UInt64): Boolean;
  end;

  TOneShot = record
    VA:     UInt64;
    Kind:   TOneShotKind;
    Module: TModule;
    Saved:  Byte;
    Fired:  Boolean;
    Lost:   Boolean;   // its module was unmapped before it fired
    Text:   string;
  end;

  TLoaderRun = class
  private
    FProcess:      THandle;
    FProcessId:    DWORD;
    FThreads:      TDictionary<DWORD, THandle>;
    FModules:      TObjectList<TModule>;
    FShots:        TList<TOneShot>;
    FShotIndex:    TDictionary<UInt64, Integer>;
    FEventNo:      Integer;
    FStarted:      Int64;
    FFrequency:    Int64;
    FExeDir:       string;
    FNativeBreaks, FWowBreaks, FShotsFired, FOtherExceptions: Integer;
    FCounterVA, FReleaseVA: UInt64;
    FHaveCounter, FReleased: Boolean;
    FReleaseAt:    UInt64;
    FMainThreadId: DWORD;
    procedure Pump;
    procedure Log(ThreadId: DWORD; const Text: string);
    procedure Detail(const Text: string);
    function  CounterText: string;
    function  ReadTarget(VA: UInt64; Count: Integer; out Bytes: TBytes): Boolean;
    function  WriteCode(VA: UInt64; const Bytes: TBytes): Boolean;
    function  FindModule(VA: UInt64): TModule;
    function  Where(VA: UInt64): string;
    function  ModulePath(FileHandle: THandle; Base: UInt64): string;
    function  NameListed(const Name: string; const List: TArray<string>): Boolean;
    function  RegisterModule(Base: UInt64; FileHandle: THandle; IsMain: Boolean; ThreadId: DWORD): TModule;
    procedure PlantForModule(Module: TModule);
    procedure PlantOneShot(Module: TModule; VA: UInt64; Kind: TOneShotKind; const Text: string);
    procedure PrepareSites(Module: TModule);
    procedure ReadSites(Module: TModule; Stage: Integer);
    procedure WriteJmpPatch(Module: TModule);
    procedure ReadBackAndRepairJmpPatch(Module: TModule);
    function  HandleException(const Event: TDebugEvent): DWORD;
    procedure HandleOneShot(const Event: TDebugEvent; Index: Integer);
    procedure RewindProgramCounter(ThreadId: DWORD; Address: UInt64; IsWowBreak: Boolean);
    procedure DescribeMappedModules;
    procedure HandleDebugString(const Event: TDebugEvent);
    procedure HandleProcessExit;
    procedure CheckImage(Module: TModule);
    procedure ForgetOneShotsOf(Module: TModule);
    procedure WaitForCounterLine(const OutputPath: string);
    procedure ReleaseTarget;
  public
    // Configuration.
    Attach, Quiet, PlantSite, JmpPatch, AnyRecord: Boolean;
    EntryScope:   TEntryScope;
    LineModules, RelocModules: TArray<string>;
    TimeoutMs:    Cardinal;
    // Results.
    ExitCode:     DWORD;
    TimedOut:     Boolean;
    Output:       TBytes;
    DebugStrings: TStringList;
    ImageMismatches, SavedByteMismatches, WriteFailures, ContextFailures: Integer;
    constructor Create;
    destructor  Destroy; override;
    procedure Execute(const Exe, CommandLine: string);
    procedure ReportRelocation;
    procedure ReportOneShots;
  end;

var
  GOutputFileSerial: Integer = 0;

destructor TModule.Destroy;
begin
  Statics.Free;
  inherited;
end;

function TModule.Delta: Int64;
begin
  if Statics <> nil then
    Result := Int64(Base) - Int64(Statics.Pe.Header.ImageBase)
  else
    Result := 0;
end;

function TModule.Contains(VA: UInt64): Boolean;
begin
  Result := (not Unloaded) and (VA >= Base) and (VA < Base + Size);
end;

constructor TLoaderRun.Create;
begin
  inherited Create;
  FThreads     := TDictionary<DWORD, THandle>.Create;
  FModules     := TObjectList<TModule>.Create(True);
  FShots       := TList<TOneShot>.Create;
  FShotIndex   := TDictionary<UInt64, Integer>.Create;
  DebugStrings := TStringList.Create;
  TimeoutMs    := 60000;
  EntryScope   := esAll;
  QueryPerformanceFrequency(FFrequency);
end;

destructor TLoaderRun.Destroy;
begin
  DebugStrings.Free;
  FShotIndex.Free;
  FShots.Free;
  FModules.Free;
  FThreads.Free;
  inherited;
end;

procedure TLoaderRun.Log(ThreadId: DWORD; const Text: string);
begin
  Inc(FEventNo);
  if Quiet then
    Exit;
  var Now_: Int64;
  QueryPerformanceCounter(Now_);
  Writeln(Format('[%3d] %8.1f ms  tid %5d%s  %s',
    [FEventNo, (Now_ - FStarted) * 1000 / FFrequency, ThreadId, CounterText, Text]));
end;

procedure TLoaderRun.Detail(const Text: string);
begin
  if not Quiet then
    Writeln('          ', Text);
end;

function TLoaderRun.CounterText: string;
begin
  Result := '';
  if not FHaveCounter then
    Exit;
  var Bytes: TBytes;
  if ReadTarget(FCounterVA, 4, Bytes) then
    Result := Format('  counter %10u', [PCardinal(@Bytes[0])^])
  else
    Result := '  counter   unreadable';
end;

function TLoaderRun.ReadTarget(VA: UInt64; Count: Integer; out Bytes: TBytes): Boolean;
begin
  SetLength(Bytes, Count);
  var Done: NativeUInt := 0;
  Result := (Count > 0) and ReadProcessMemory(FProcess, Pointer(VA), @Bytes[0], Count, Done) and (Done = NativeUInt(Count));
  if not Result then
    Bytes := nil;
end;

// The engine's own sequence for code bytes (TWinDebugger.WriteByte).
function TLoaderRun.WriteCode(VA: UInt64; const Bytes: TBytes): Boolean;
begin
  var OldProtect, Ignored: DWORD;
  var Done: NativeUInt := 0;
  VirtualProtectEx(FProcess, Pointer(VA), Length(Bytes), PAGE_EXECUTE_READWRITE, OldProtect);
  Result := WriteProcessMemory(FProcess, Pointer(VA), @Bytes[0], Length(Bytes), Done) and (Done = NativeUInt(Length(Bytes)));
  VirtualProtectEx(FProcess, Pointer(VA), Length(Bytes), OldProtect, Ignored);
  FlushInstructionCache(FProcess, Pointer(VA), Length(Bytes));
  if not Result then
    Inc(WriteFailures);
end;

function TLoaderRun.FindModule(VA: UInt64): TModule;
begin
  for var Module in FModules do
    if Module.Contains(VA) then
      Exit(Module);
  Result := nil;
end;

function TLoaderRun.Where(VA: UInt64): string;
begin
  var Module := FindModule(VA);
  if Module = nil then
    Exit('$' + IntToHex(VA, 8) + ' (in no mapped module)');
  Result := Format('%s+$%x (%s module)', [Module.Name, VA - Module.Base, MachineName(Module.Machine)]);
end;

function TLoaderRun.ModulePath(FileHandle: THandle; Base: UInt64): string;
var
  Buffer: array[0..1023] of Char;
begin
  Result := '';
  if (FileHandle <> 0) and (FileHandle <> INVALID_HANDLE_VALUE) then begin
    var Length_ := FinalPathNameByHandle(FileHandle, Buffer, Length(Buffer), 0);
    if (Length_ > 0) and (Length_ < DWORD(Length(Buffer))) then begin
      Result := Buffer;
      if Result.StartsWith('\\?\') then
        Result := Result.Substring(4);
    end;
  end;
  if Result = '' then begin
    // A device path: good for the name, not for opening the file.
    var Length_ := MappedFileName(FProcess, Pointer(Base), Buffer, Length(Buffer));
    if Length_ > 0 then
      Result := Buffer;
  end;
end;

function TLoaderRun.NameListed(const Name: string; const List: TArray<string>): Boolean;
begin
  for var Item in List do
    if SameText(Item, Name) then
      Exit(True);
  Result := False;
end;

function TLoaderRun.RegisterModule(Base: UInt64; FileHandle: THandle; IsMain: Boolean; ThreadId: DWORD): TModule;
begin
  Result := TModule.Create;
  FModules.Add(Result);
  Result.Base   := Base;
  Result.IsMain := IsMain;
  Result.Path   := ModulePath(FileHandle, Base);
  Result.Name   := ExtractFileName(Result.Path);
  if Result.Name = '' then
    Result.Name := '<unnamed>';
  Result.Own := SameText(ExtractFileDir(Result.Path), FExeDir);

  var Page: TBytes;
  var Header: TPeHeader;
  var HeaderRead := ReadTarget(Base, 4096, Page) and ParsePeHeader(Page, Header);
  if HeaderRead then begin
    Result.Size            := Header.SizeOfImage;
    Result.Machine         := Header.Machine;
    Result.EntryRva        := Header.EntryRva;
    Result.HeaderImageBase := Header.ImageBase;
  end;

  var NeedsStatics := (not Attach) and (NameListed(Result.Name, LineModules) or NameListed(Result.Name, RelocModules));
  var OnlyStatics := Result.Own and FileExists(Result.Path);
  if NeedsStatics or OnlyStatics then
    try
      Result.Statics := TModuleStatics.Create(Result.Path);
    except
      on E: Exception do
        Detail('cannot read ' + Result.Path + ': ' + E.Message);
    end;

  var Text := 'LOAD_DLL';
  if IsMain then
    Text := 'CREATE_PROCESS';
  Text := Format('%-14s %s at %s (%s)', [Text, Result.Name, IntToHex(Base, 8), MachineName(Result.Machine)]);
  if not HeaderRead then
    Text := Text + ', header unreadable';
  if Result.Statics <> nil then begin
    var Preferred := Result.Statics.Pe.Header.ImageBase;
    if Preferred = Base then
      Text := Text + ', its preferred base'
    else
      Text := Text + Format(', preferred %s: MOVED by $%x', [IntToHex(Preferred, 8), Result.Delta]);
    Text := Text + Format('; mapped header ImageBase field %s', [IntToHex(Result.HeaderImageBase, 8)]);
  end;
  Log(ThreadId, Text);
  Result.LoadEvent := FEventNo;
end;

procedure TLoaderRun.PlantOneShot(Module: TModule; VA: UInt64; Kind: TOneShotKind; const Text: string);
begin
  if FShotIndex.ContainsKey(VA) then
    Exit;
  // The jump patch of the negative experiment owns its bytes.
  if (Length(Module.JmpWritten) > 0) and (VA >= Module.JmpVA) and (VA < Module.JmpVA + JMP_PATCH_LENGTH) then
    Exit;
  var Current: TBytes;
  if not ReadTarget(VA, 1, Current) then
    Exit;
  if Current[0] = INT3 then begin
    Inc(Module.AlreadyInt3);
    Exit;
  end;
  if not WriteCode(VA, [INT3]) then
    Exit;
  var Shot := Default(TOneShot);
  Shot.VA     := VA;
  Shot.Kind   := Kind;
  Shot.Module := Module;
  Shot.Saved  := Current[0];
  Shot.Text   := Text;
  FShotIndex.Add(VA, FShots.Add(Shot));
  Inc(Module.ShotsPlanted);
  if Kind = osEntry then
    Module.EntryPlanted := True;
end;

procedure TLoaderRun.PrepareSites(Module: TModule);

  procedure Add(const Title: string; Rva: Cardinal; Count: Integer; FixupRva: Cardinal; FixupWidth: Integer);
  begin
    var Site := Default(TWatchSite);
    Site.Title      := Title;
    Site.Rva        := Rva;
    Site.Count      := Count;
    Site.FixupRva   := FixupRva;
    Site.FixupWidth := FixupWidth;
    Site.FileBytes  := Module.Statics.Pe.FileBytes(Rva, Count);
    Site.Expected   := Module.Statics.Pe.RelocatedBytes(Rva, Count, Module.Delta);
    Module.Sites := Module.Sites + [Site];
  end;

begin
  var Statics := Module.Statics;
  if Statics.Operand.Found then begin
    var Count := Statics.Operand.Length;
    if Count < WATCH_BYTES then
      Count := WATCH_BYTES;
    Add(Format('instruction with a relocated operand (%s, "%s", fixup at +%d)', [Statics.Operand.Where, Statics.Operand.Text,
      Statics.Operand.FixupRva - Statics.Operand.Rva]), Statics.Operand.Rva, Count, Statics.Operand.FixupRva,
      Statics.Operand.FixupWidth);
  end;
  if Statics.CodeSlot >= 0 then begin
    var Fixup := Statics.Pe.Fixups[Statics.CodeSlot];
    Add('first relocated slot in a code section', Fixup.Rva, Fixup.Width, Fixup.Rva, Fixup.Width);
  end;
  if Statics.DataSlot >= 0 then begin
    var Fixup := Statics.Pe.Fixups[Statics.DataSlot];
    Add('first relocated slot in a data section', Fixup.Rva, Fixup.Width, Fixup.Rva, Fixup.Width);
  end;
end;

// Stage 0: the load event, 1: the entry-point one-shot, 2: process exit.
procedure TLoaderRun.ReadSites(Module: TModule; Stage: Integer);
begin
  for var I := 0 to High(Module.Sites) do begin
    var Bytes: TBytes;
    ReadTarget(Module.Base + Module.Sites[I].Rva, Module.Sites[I].Count, Bytes);
    case Stage of
      0: Module.Sites[I].AtLoad  := Bytes;
      1: Module.Sites[I].AtEntry := Bytes;
      2: Module.Sites[I].AtExit  := Bytes;
    end;
  end;
end;

procedure TLoaderRun.WriteJmpPatch(Module: TModule);
begin
  var Site := Module.Statics.Operand;
  if (not Site.Found) or (Site.Length < JMP_PATCH_LENGTH) then begin
    Detail('-jmppatch: no watched instruction of five bytes or more in ' + Module.Name);
    Exit;
  end;
  Module.JmpVA := Module.Base + Site.Rva;
  ReadTarget(Module.JmpVA, WATCH_BYTES, Module.JmpBefore);
  // jmp +$100 from the end of the patch: the target is irrelevant, the
  // instruction is repaired before anything can execute it.
  var Patch: TBytes := [$E9, $00, $01, $00, $00];
  if WriteCode(Module.JmpVA, Patch) then begin
    Module.JmpWritten := Patch;
    Detail(Format('-jmppatch: wrote %s over the watched instruction at %s+$%x',
      [HexBytes(Patch), Module.Name, Site.Rva]));
  end;
end;

procedure TLoaderRun.ReadBackAndRepairJmpPatch(Module: TModule);
begin
  if Length(Module.JmpWritten) = 0 then
    Exit;
  ReadTarget(Module.JmpVA, WATCH_BYTES, Module.JmpReadBack);
  var Site := Module.Statics.Operand;
  var Good := Module.Statics.Pe.RelocatedBytes(Site.Rva, Site.Length, Module.Delta);
  if WriteCode(Module.JmpVA, Good) then
    Detail(Format('-jmppatch: read back %s; repaired with %s', [HexBytes(Module.JmpReadBack), HexBytes(Good)]));
end;

procedure TLoaderRun.PlantForModule(Module: TModule);
begin
  if Attach then
    Exit;
  var Statics := Module.Statics;
  Module.WatchRelocation := (Statics <> nil) and NameListed(Module.Name, RelocModules);
  if Module.WatchRelocation then begin
    PrepareSites(Module);
    ReadSites(Module, 0);
    if JmpPatch then
      WriteJmpPatch(Module);
  end;

  var WantsLines := (Statics <> nil) and NameListed(Module.Name, LineModules);
  var WantsEntry := (EntryScope = esAll) or ((EntryScope = esOwn) and Module.Own) or Module.WatchRelocation or WantsLines;
  if WantsEntry and (Module.EntryRva <> 0) then
    PlantOneShot(Module, Module.Base + Module.EntryRva, osEntry, 'entry point of ' + Module.Name);
  if Module.WatchRelocation and PlantSite and Statics.Operand.Found then
    PlantOneShot(Module, Module.Base + Statics.Operand.Rva, osSite,
      Format('watched instruction of %s, %s', [Module.Name, Statics.Operand.Where]));
  if WantsLines then begin
    // A record that the TD32 reader attributes to no routine is not code (the
    // record of a unit's final `end.` points at data the RTL reads), and the
    // plan never probes one. -anyrecord plants there too, as the negative control.
    var LeftAlone := 0;
    for var I := 0 to High(Statics.Lines) do begin
      if not Statics.Pe.IsCodeRva(Statics.Lines[I].Rva) then
        Continue;
      if (Statics.Lines[I].Routine = '') and not AnyRecord then begin
        Inc(LeftAlone);
        Continue;
      end;
      PlantOneShot(Module, Module.Base + Statics.Lines[I].Rva, osLine,
        Format('line %s in %s', [Statics.LineLabel(I), Module.Name]));
    end;
    if LeftAlone > 0 then
      Detail(Format('%d line record(s) of %s lie in no TD32 routine and were left alone', [LeftAlone, Module.Name]));
  end;
  if (Module.ShotsPlanted > 1) or (Module.AlreadyInt3 > 0) then begin
    var Text := Format('planted %d one-shot(s) in %s', [Module.ShotsPlanted, Module.Name]);
    if Module.AlreadyInt3 > 0 then
      Text := Text + Format(' (%d address(es) already held an int3 and were left alone)', [Module.AlreadyInt3]);
    Detail(Text);
  end;
end;

procedure TLoaderRun.RewindProgramCounter(ThreadId: DWORD; Address: UInt64; IsWowBreak: Boolean);
var
  Context:    TContext;
  WowContext: TWow64Context;
begin
  var Thread: THandle;
  if not FThreads.TryGetValue(ThreadId, Thread) then begin
    Inc(ContextFailures);
    Exit;
  end;
  var Done: Boolean;
  if IsWowBreak then begin
    WowContext.ContextFlags := WOW64_CONTEXT_CONTROL;
    Done := Wow64GetThreadContext(Thread, WowContext);
    if Done then begin
      WowContext.Eip := DWORD(Address);
      Done := Wow64SetThreadContext(Thread, WowContext);
    end;
  end
  else begin
    Context.ContextFlags := CONTEXT_CONTROL;
    Done := GetThreadContext(Thread, Context);
    if Done then begin
      Context.Rip := Address;
      Done := SetThreadContext(Thread, Context);
    end;
  end;
  if not Done then
    Inc(ContextFailures);
end;

procedure TLoaderRun.DescribeMappedModules;
const
  MACHINES: array[0..1] of Word = (MACHINE_AMD64, MACHINE_I386);
begin
  if Quiet then
    Exit;
  for var Machine in MACHINES do begin
    var Names := '';
    var Count := 0;
    for var Module in FModules do
      if (not Module.Unloaded) and (Module.Machine = Machine) then begin
        Inc(Count);
        if Names <> '' then
          Names := Names + ', ';
        Names := Names + Module.Name;
      end;
    if Count > 0 then
      Detail(Format('mapped, %s (%d): %s', [MachineName(Machine), Count, Names]));
  end;
  var Fired := '';
  for var Shot in FShots do
    if Shot.Fired and (Shot.Kind = osEntry) then begin
      if Fired <> '' then
        Fired := Fired + ', ';
      Fired := Fired + Shot.Module.Name;
    end;
  if Fired = '' then
    Fired := 'none';
  if not Attach then
    Detail(Format('so far: %d one-shot(s) fired of %d planted, %d debug string(s); entry points reached: %s',
      [FShotsFired, FShots.Count, DebugStrings.Count, Fired]));
end;

procedure TLoaderRun.HandleOneShot(const Event: TDebugEvent; Index: Integer);
begin
  var Shot := FShots[Index];
  var IsWowBreak := DWORD(Event.Exception.ExceptionRecord.ExceptionCode) = STATUS_WX86_BREAKPOINT;
  if Shot.Fired then begin
    // Another thread ran into the same $CC before it was taken out.
    RewindProgramCounter(Event.dwThreadId, Shot.VA, IsWowBreak);
    Exit;
  end;
  WriteCode(Shot.VA, [Shot.Saved]);
  RewindProgramCounter(Event.dwThreadId, Shot.VA, IsWowBreak);
  Shot.Fired := True;
  FShots[Index] := Shot;
  Inc(FShotsFired);

  var Module := Shot.Module;
  var Text := 'ONE-SHOT       ' + Shot.Text;
  if Module.ShotsFired = 0 then
    Text := Text + '   <- first code seen in ' + Module.Name;
  if (Shot.Kind <> osEntry) and Module.EntryPlanted and not Module.EntryFired then
    Text := Text + '   !! BEFORE the entry point of ' + Module.Name;
  Inc(Module.ShotsFired);
  Log(Event.dwThreadId, Text);
  if Shot.Kind <> osEntry then
    Exit;

  Module.EntryFired := True;
  if Module.WatchRelocation then begin
    ReadSites(Module, 1);
    ReadBackAndRepairJmpPatch(Module);
  end;
  if Module.IsMain then
    DescribeMappedModules;
end;

function TLoaderRun.HandleException(const Event: TDebugEvent): DWORD;
begin
  var Code := DWORD(Event.Exception.ExceptionRecord.ExceptionCode);
  var Address := UInt64(NativeUInt(Event.Exception.ExceptionRecord.ExceptionAddress));
  var IsWowBreak := Code = STATUS_WX86_BREAKPOINT;
  if (Code <> DWORD(EXCEPTION_BREAKPOINT)) and not IsWowBreak then begin
    Inc(FOtherExceptions);
    if FOtherExceptions <= 40 then
      Log(Event.dwThreadId, Format('EXCEPTION      $%.8x at %s, first chance %d: passed to the program',
        [Code, Where(Address), Event.Exception.dwFirstChance]));
    Exit(DBG_EXCEPTION_NOT_HANDLED);
  end;

  var Index: Integer;
  if FShotIndex.TryGetValue(Address, Index) then begin
    HandleOneShot(Event, Index);
    Exit(DBG_CONTINUE);
  end;

  var Kind := 'native $80000003';
  if IsWowBreak then
    Kind := 'WOW64 $4000001F';
  var Module := FindModule(Address);
  var InNtdll := (Module <> nil) and SameText(Module.Name, 'ntdll.dll');
  if not InNtdll then begin
    Log(Event.dwThreadId, Format('BREAKPOINT     %s at %s: not planted here, passed to the program', [Kind, Where(Address)]));
    Exit(DBG_EXCEPTION_NOT_HANDLED);
  end;

  if IsWowBreak then
    Inc(FWowBreaks)
  else
    Inc(FNativeBreaks);
  var Role := 'loader breakpoint';
  if Attach then
    Role := 'attach break-in';
  Log(Event.dwThreadId, Format('BREAKPOINT     %s at %s  <- %s, breakpoint event #%d of the process',
    [Kind, Where(Address), Role, FNativeBreaks + FWowBreaks]));
  DescribeMappedModules;
  if FNativeBreaks + FWowBreaks = 1 then begin
    var Flags: DWORD := 0;
    if QueryMitigationPolicy(FProcess, ASLR_POLICY, @Flags, SizeOf(Flags)) then
      Detail(Format('ASLR policy of the process: bottom-up %s, force-relocate images %s, high entropy %s, disallow stripped images %s',
        [YesNo((Flags and 1) <> 0), YesNo((Flags and 2) <> 0), YesNo((Flags and 4) <> 0), YesNo((Flags and 8) <> 0)]));
  end;
  if Attach and FHaveCounter and (FReleaseAt = 0) then
    FReleaseAt := GetTickCount64 + RELEASE_DELAY_MS;
  Result := DBG_CONTINUE;
end;

procedure TLoaderRun.HandleDebugString(const Event: TDebugEvent);
begin
  var Info := Event.DebugString;
  var Text := '';
  var Bytes: TBytes;
  if Info.fUnicode <> 0 then begin
    if ReadTarget(UInt64(NativeUInt(Info.lpDebugStringData)), Info.nDebugStringLength * 2, Bytes) then
      Text := TEncoding.Unicode.GetString(Bytes);
  end
  else if ReadTarget(UInt64(NativeUInt(Info.lpDebugStringData)), Info.nDebugStringLength, Bytes) then
    Text := TEncoding.Default.GetString(Bytes);
  var Terminator := Text.IndexOf(#0);
  if Terminator >= 0 then
    Text := Text.Substring(0, Terminator);
  Text := Text.TrimRight([#13, #10]);
  DebugStrings.Add(Text);
  Log(Event.dwThreadId, 'DEBUG STRING   "' + Text + '"');
end;

// Every code section must read as the file relocated by the actual delta,
// except for a $CC on each one-shot that never fired; and every saved byte must
// be the file's byte, which no relocation touches.
procedure TLoaderRun.CheckImage(Module: TModule);
begin
  var Pe := Module.Statics.Pe;
  var Mismatches := 0;
  var Compared := 0;
  for var Section in Pe.Sections do begin
    if not Section.IsCode then
      Continue;
    var Count := Integer(Section.VirtualSize);
    if (Section.RawSize > 0) and (Integer(Section.RawSize) < Count) then
      Count := Section.RawSize;
    var Memory: TBytes;
    if not ReadTarget(Module.Base + Section.Rva, Count, Memory) then begin
      Detail(Format('image check of %s: section %s is unreadable', [Module.Name, Section.Name]));
      Inc(ImageMismatches);
      Continue;
    end;
    var Expected := Pe.RelocatedBytes(Section.Rva, Count, Module.Delta);
    for var Shot in FShots do
      if (Shot.Module = Module) and (not Shot.Fired) and (Shot.VA >= Module.Base + Section.Rva) and
         (Shot.VA < Module.Base + Section.Rva + Cardinal(Count)) then
        Expected[Shot.VA - Module.Base - Section.Rva] := INT3;
    Inc(Compared, Count);
    for var I := 0 to Count - 1 do
      if Memory[I] <> Expected[I] then begin
        Inc(Mismatches);
        if Mismatches <= MAX_LISTED_MISMATCHES then
          Writeln(Format('    MISMATCH %s+$%x: memory %.2x, relocated file %.2x', [Module.Name, Section.Rva + Cardinal(I),
            Memory[I], Expected[I]]));
      end;
  end;
  var SavedWrong := 0;
  var Shots := 0;
  for var Shot in FShots do
    if Shot.Module = Module then begin
      Inc(Shots);
      if Shot.Saved <> Pe.FileBytes(Cardinal(Shot.VA - Module.Base), 1)[0] then
        Inc(SavedWrong);
    end;
  Writeln(Format('  %-18s code sections vs the file relocated by $%x: %d of %d bytes differ; saved bytes equal to the file''s: %d of %d',
    [Module.Name, Module.Delta, Mismatches, Compared, Shots - SavedWrong, Shots]));
  Inc(ImageMismatches, Mismatches);
  Inc(SavedByteMismatches, SavedWrong);
end;

// An unmapped image takes its private pages with it, the $CC bytes included: the
// addresses are free for whatever is mapped there next.
procedure TLoaderRun.ForgetOneShotsOf(Module: TModule);
begin
  var Lost := 0;
  for var I := 0 to FShots.Count - 1 do begin
    var Shot := FShots[I];
    if Shot.Module <> Module then
      Continue;
    FShotIndex.Remove(Shot.VA);
    if Shot.Fired then
      Continue;
    Shot.Lost := True;
    FShots[I] := Shot;
    Inc(Lost);
  end;
  if Lost > 0 then
    Detail(Format('%d one-shot(s) planted in this mapping of %s went with it, unfired', [Lost, Module.Name]));
end;

procedure TLoaderRun.HandleProcessExit;
begin
  var Header := False;
  for var Module in FModules do begin
    if Module.Unloaded or (Module.Statics = nil) then
      Continue;
    if Module.WatchRelocation then
      ReadSites(Module, 2);
    if (Module.ShotsPlanted = 0) and not Module.WatchRelocation then
      Continue;
    if not Header then begin
      Writeln;
      Writeln('Image check at process exit');
      Header := True;
    end;
    CheckImage(Module);
  end;
end;

procedure TLoaderRun.ReleaseTarget;
begin
  FReleased := True;
  var One: Integer := 1;
  var Done: NativeUInt;
  var Written := WriteProcessMemory(FProcess, Pointer(FReleaseVA), @One, SizeOf(One), Done);
  if not Quiet then
    Writeln(Format('          -- %d ms after the break-in: release flag written (%s); what follows is the released program --',
      [RELEASE_DELAY_MS, YesNo(Written)]));
end;

procedure TLoaderRun.Pump;
var
  Event: TDebugEvent;
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while True do begin
    if (not TimedOut) and (GetTickCount64 > Deadline) then begin
      TimedOut := True;
      TerminateProcess(FProcess, TIMEOUT_EXIT_CODE);
    end;
    if (FReleaseAt <> 0) and (not FReleased) and (GetTickCount64 >= FReleaseAt) then
      ReleaseTarget;
    if not WaitForDebugEvent(Event, 20) then
      Continue;
    var Status: DWORD := DBG_CONTINUE;
    case Event.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT: begin
        FMainThreadId := Event.dwThreadId;
        FThreads.AddOrSetValue(Event.dwThreadId, Event.CreateProcessInfo.hThread);
        var Module := RegisterModule(UInt64(NativeUInt(Event.CreateProcessInfo.lpBaseOfImage)),
          Event.CreateProcessInfo.hFile, True, Event.dwThreadId);
        PlantForModule(Module);
        if Event.CreateProcessInfo.hFile <> 0 then
          CloseHandle(Event.CreateProcessInfo.hFile);
        if Event.CreateProcessInfo.hProcess <> 0 then
          CloseHandle(Event.CreateProcessInfo.hProcess);
      end;
      CREATE_THREAD_DEBUG_EVENT: begin
        FThreads.AddOrSetValue(Event.dwThreadId, Event.CreateThread.hThread);
        Log(Event.dwThreadId, 'CREATE_THREAD  start address ' +
          Where(UInt64(NativeUInt(Event.CreateThread.lpStartAddress))));
      end;
      EXIT_THREAD_DEBUG_EVENT: begin
        FThreads.Remove(Event.dwThreadId);
        Log(Event.dwThreadId, Format('EXIT_THREAD    exit code %d', [Event.ExitThread.dwExitCode]));
      end;
      LOAD_DLL_DEBUG_EVENT: begin
        var Module := RegisterModule(UInt64(NativeUInt(Event.LoadDll.lpBaseOfDll)), Event.LoadDll.hFile, False,
          Event.dwThreadId);
        PlantForModule(Module);
        if Event.LoadDll.hFile <> 0 then
          CloseHandle(Event.LoadDll.hFile);
      end;
      UNLOAD_DLL_DEBUG_EVENT: begin
        var Module := FindModule(UInt64(NativeUInt(Event.UnloadDll.lpBaseOfDll)));
        if Module <> nil then begin
          Log(Event.dwThreadId, Format('UNLOAD_DLL     %s at %s', [Module.Name, IntToHex(Module.Base, 8)]));
          Module.Unloaded    := True;
          Module.UnloadEvent := FEventNo;
          ForgetOneShotsOf(Module);
        end
        else
          Log(Event.dwThreadId, 'UNLOAD_DLL     $' + IntToHex(UInt64(NativeUInt(Event.UnloadDll.lpBaseOfDll)), 8));
      end;
      OUTPUT_DEBUG_STRING_EVENT:
        HandleDebugString(Event);
      EXCEPTION_DEBUG_EVENT:
        Status := HandleException(Event);
      EXIT_PROCESS_DEBUG_EVENT: begin
        ExitCode := Event.ExitProcess.dwExitCode;
        Log(Event.dwThreadId, Format('EXIT_PROCESS   exit code %d', [ExitCode]));
        // The address space is still there at this event.
        HandleProcessExit;
        ContinueDebugEvent(Event.dwProcessId, Event.dwThreadId, DBG_CONTINUE);
        Exit;
      end;
    end;
    ContinueDebugEvent(Event.dwProcessId, Event.dwThreadId, Status);
  end;
end;

// The target tells where its counter and its release flag are.
procedure TLoaderRun.WaitForCounterLine(const OutputPath: string);
begin
  var Deadline := GetTickCount64 + 15000;
  while GetTickCount64 < Deadline do begin
    var Text := TEncoding.Default.GetString(ReadSharedFile(OutputPath));
    var Position := Text.IndexOf('counter=');
    if (Position >= 0) and (Text.IndexOf(#10, Position) > 0) then begin
      var Fields := Text.Substring(Position, Text.IndexOf(#10, Position) - Position).Trim.Split([' ']);
      if Length(Fields) >= 2 then begin
        FCounterVA := UInt64(StrToInt64Def('$' + Fields[0].Substring(8), 0));
        FReleaseVA := UInt64(StrToInt64Def('$' + Fields[1].Substring(8), 0));
        FHaveCounter := (FCounterVA <> 0) and (FReleaseVA <> 0);
      end;
      Exit;
    end;
    if WaitForSingleObject(FProcess, 20) = WAIT_OBJECT_0 then
      Exit;
  end;
end;

procedure TLoaderRun.Execute(const Exe, CommandLine: string);
begin
  FExeDir := ExtractFileDir(Exe);
  Inc(GOutputFileSerial);
  var OutputPath := TPath.Combine(TPath.GetTempPath,
    Format('LoaderTimingProbe_%d_%d.out', [GetCurrentProcessId, GOutputFileSerial]));
  var NulInput := OpenNulForChild;
  var OutputFile := CreateChildOutputFile(OutputPath);
  try
    var Flags: DWORD := DEBUG_ONLY_THIS_PROCESS;
    if Attach then
      Flags := 0;
    QueryPerformanceCounter(FStarted);
    var Info := LaunchWithStdHandles(CommandLine, NulInput, OutputFile, Flags);
    CloseHandle(Info.hThread);
    FProcess   := Info.hProcess;
    FProcessId := Info.dwProcessId;
    try
      if Attach then begin
        WaitForCounterLine(OutputPath);
        if not FHaveCounter then
          raise Exception.Create('the target did not print `counter=<hex> release=<hex>` within 15 s');
        var Before, After: TBytes;
        ReadTarget(FCounterVA, 4, Before);
        Sleep(100);
        ReadTarget(FCounterVA, 4, After);
        if (Before <> nil) and (After <> nil) then
          Writeln(Format('before the attach the counter moved by %u in 100 ms (it reads %u)',
            [Cardinal(PCardinal(@After[0])^ - PCardinal(@Before[0])^), PCardinal(@After[0])^]));
        QueryPerformanceCounter(FStarted);
        if not DebugActiveProcess(FProcessId) then
          RaiseLastOSError;
        if not Quiet then
          Writeln('DebugActiveProcess returned;', CounterText.Replace('  counter', ' counter'));
      end;
      Pump;
    finally
      // A no-op once the target has exited; after an error it is what keeps a
      // debuggee from outliving the run.
      TerminateProcess(FProcess, TIMEOUT_EXIT_CODE);
      // The images stay mapped until the process object goes: wait for it
      // before anything is deleted or rebuilt.
      WaitForSingleObject(FProcess, 10000);
      CloseHandle(FProcess);
    end;
  finally
    CloseHandle(NulInput);
    CloseHandle(OutputFile);
    if TFile.Exists(OutputPath) then begin
      Output := TFile.ReadAllBytes(OutputPath);
      TFile.Delete(OutputPath);
    end;
  end;
end;

procedure TLoaderRun.ReportRelocation;

  function FieldOf(const Site: TWatchSite; const Bytes: TBytes): TBytes;
  begin
    Result := Copy(Bytes, Site.FixupRva - Site.Rva, Site.FixupWidth);
  end;

  function Verdict(const Site: TWatchSite; const Bytes: TBytes): string;
  begin
    if Bytes = nil then
      Exit('unreadable');
    var Field := FieldOf(Site, Bytes);
    var FromFile := FieldOf(Site, Site.FileBytes);
    var Relocated := FieldOf(Site, Site.Expected);
    if SameBytes(FromFile, Relocated) then begin
      if SameBytes(Field, FromFile) then
        Exit('as in the file (nothing to relocate)');
      Exit('NEITHER the file''s value nor the relocated one');
    end;
    if SameBytes(Field, Relocated) then
      Exit('RELOCATED');
    if SameBytes(Field, FromFile) then
      Exit('NOT relocated: still the file''s value');
    Result := 'NEITHER the file''s value nor the relocated one';
  end;

begin
  var Described := TStringList.Create;
  try
    for var Module in FModules do begin
      if not Module.WatchRelocation then
        Continue;
      Writeln;
      var Fate := 'still mapped at process exit';
      if Module.Unloaded then
        Fate := Format('UNMAPPED at event %d', [Module.UnloadEvent]);
      Writeln(Format('Relocation of %s: mapped at %s by event %d, delta $%x, %s',
        [Module.Name, IntToHex(Module.Base, 8), Module.LoadEvent, Module.Delta, Fate]));
      if Described.IndexOf(Module.Path) < 0 then begin
        Described.Add(Module.Path);
        PrintStatics(Module.Statics, '  ');
      end;
      Writeln(Format('  ImageBase field of the mapped header at the load event: %s', [IntToHex(Module.HeaderImageBase, 8)]));
      var Gone := '';
      if Module.Unloaded then
        Gone := ' (the mapping was gone by then)';
      var AtLoad := '';
      for var Site in Module.Sites do begin
        Writeln(Format('  %s, rva $%x', [Site.Title, Site.Rva]));
        Writeln(Format('    in the file           %s', [HexBytes(Site.FileBytes)]));
        Writeln(Format('    relocated image holds %s', [HexBytes(Site.Expected)]));
        Writeln(Format('    at the load event     %-36s %s', [HexBytes(Site.AtLoad), Verdict(Site, Site.AtLoad)]));
        if Module.EntryFired then
          Writeln(Format('    at the entry point    %-36s %s', [HexBytes(Site.AtEntry), Verdict(Site, Site.AtEntry)]))
        else
          Writeln('    at the entry point    the entry-point one-shot of this mapping never fired' + Gone);
        Writeln(Format('    at process exit       %-36s %s', [HexBytes(Site.AtExit), Verdict(Site, Site.AtExit) + Gone]));
        if AtLoad = '' then
          AtLoad := Verdict(Site, Site.AtLoad);
      end;
      if Module.Delta = 0 then
        Writeln('  VERDICT: loaded at its preferred base, the question does not arise')
      else if AtLoad = 'RELOCATED' then
        Writeln('  VERDICT: relocations were applied BEFORE the debug event that announced this mapping')
      else if AtLoad.StartsWith('NOT relocated') then
        Writeln('  VERDICT: relocations were NOT yet applied at the debug event that announced this mapping')
      else
        Writeln('  VERDICT: unclear, read the rows above');
      if Length(Module.JmpWritten) > 0 then begin
        var Site := Module.Statics.Operand;
        Writeln(Format('  -jmppatch on the watched instruction (rva $%x):', [Site.Rva]));
        Writeln(Format('    before the patch, at the load event  %s', [HexBytes(Module.JmpBefore)]));
        Writeln(Format('    written at the load event            %s', [HexBytes(Module.JmpWritten)]));
        if Module.EntryFired then begin
          Writeln(Format('    read back at the entry point         %s', [HexBytes(Module.JmpReadBack)]));
          Writeln(Format('    a correct relocated image holds      %s',
            [HexBytes(Module.Statics.Pe.RelocatedBytes(Site.Rva, WATCH_BYTES, Module.Delta))]));
          var Tail := Copy(Module.JmpBefore, JMP_PATCH_LENGTH, WATCH_BYTES);
          if not SameBytes(Copy(Module.JmpReadBack, 0, JMP_PATCH_LENGTH), Module.JmpWritten) then
            Writeln('    the five bytes came back CHANGED: the loader added its delta to the middle of the patch')
          else if not SameBytes(Copy(Module.JmpReadBack, JMP_PATCH_LENGTH, WATCH_BYTES), Tail) then
            Writeln('    the five bytes came back as written, the bytes behind them changed: the delta fell past the patch')
          else
            Writeln('    the five bytes came back as written: nothing touched them after the event');
        end
        else
          Writeln('    never read back: the entry-point one-shot of this mapping never fired' + Gone);
      end;
    end;
  finally
    Described.Free;
  end;
end;

procedure TLoaderRun.ReportOneShots;
begin
  if FShots.Count = 0 then
    Exit;
  var Never := '';
  var NeverLines := 0;
  var Lost := 0;
  for var Shot in FShots do begin
    if Shot.Fired then
      Continue;
    if Shot.Lost then
      Inc(Lost)
    else if Shot.Kind = osEntry then begin
      if Never <> '' then
        Never := Never + ', ';
      Never := Never + Shot.Module.Name;
    end
    else
      Inc(NeverLines);
  end;
  Writeln;
  Writeln(Format('One-shots: %d planted, %d fired, %d gone unfired with a mapping that was unmapped; ' +
    'failed writes %d, failed context changes %d', [FShots.Count, FShotsFired, Lost, WriteFailures, ContextFailures]));
  if Never <> '' then
    Writeln('  entry points never reached: ', Never);
  if NeverLines > 0 then
    Writeln('  line or instruction one-shots never reached: ', NeverLines);
  Writeln(Format('Breakpoint events not planted here, in ntdll: %d native ($80000003), %d WOW64 ($4000001F)',
    [FNativeBreaks, FWowBreaks]));
end;

{ ---------------------------------------------------------------------- main -- }

type
  TOptions = record
    Mode:        string;
    EntryScope:  TEntryScope;
    LineModules, RelocModules, Paths, Rest: TArray<string>;
    PlantSite, JmpPatch, Baseline, Quiet, AnyRecord: Boolean;
    TimeoutSeconds: Integer;
    ZydisDll:    string;
  end;

function ParseOptions: TOptions;
begin
  Result := Default(TOptions);
  Result.Mode           := LowerCase(ParamStr(1));
  Result.EntryScope     := esAll;
  Result.TimeoutSeconds := 60;
  var Index := 2;
  while Index <= ParamCount do begin
    var Name := LowerCase(ParamStr(Index));
    var Value := ParamStr(Index + 1);
    if Name = '-entries' then begin
      if SameText(Value, 'none') then
        Result.EntryScope := esNone
      else if SameText(Value, 'own') then
        Result.EntryScope := esOwn
      else
        Result.EntryScope := esAll;
    end
    else if Name = '-lines' then
      Result.LineModules := Result.LineModules + [Value]
    else if Name = '-reloc' then
      Result.RelocModules := Result.RelocModules + [Value]
    else if Name = '-path' then
      Result.Paths := Result.Paths + [Value]
    else if Name = '-timeout' then
      Result.TimeoutSeconds := StrToIntDef(Value, 60)
    else if Name = '-zydisdll' then
      Result.ZydisDll := Value
    else begin
      // A flag, or the first word that is not an option: the target.
      if Name = '-plantsite' then
        Result.PlantSite := True
      else if Name = '-jmppatch' then
        Result.JmpPatch := True
      else if Name = '-baseline' then
        Result.Baseline := True
      else if Name = '-quiet' then
        Result.Quiet := True
      else if Name = '-anyrecord' then
        Result.AnyRecord := True
      else
        Break;
      Inc(Index);
      Continue;
    end;
    Inc(Index, 2);
  end;
  for var I := Index to ParamCount do
    Result.Rest := Result.Rest + [ParamStr(I)];
end;

function ConfiguredRun(const Options: TOptions; Planting: Boolean): TLoaderRun;
begin
  Result := TLoaderRun.Create;
  Result.Attach    := Options.Mode = '-attach';
  Result.TimeoutMs := Cardinal(Options.TimeoutSeconds) * 1000;
  Result.Quiet     := Options.Quiet or not Planting;
  if Planting and not Result.Attach then begin
    Result.EntryScope   := Options.EntryScope;
    Result.LineModules  := Options.LineModules;
    Result.RelocModules := Options.RelocModules;
    Result.PlantSite    := Options.PlantSite;
    Result.JmpPatch     := Options.JmpPatch;
    Result.AnyRecord    := Options.AnyRecord;
  end
  else
    Result.EntryScope := esNone;
end;

procedure RunLiveMode(const Options: TOptions);
begin
  if Length(Options.Rest) = 0 then
    raise Exception.Create('no target given');
  var Exe := ExpandFileName(Options.Rest[0]);
  var CommandLine := QuoteArgument(Exe);
  for var I := 1 to High(Options.Rest) do
    CommandLine := CommandLine + ' ' + QuoteArgument(Options.Rest[I]);
  if Length(Options.Paths) > 0 then
    SetEnvironmentVariable('PATH', PChar(string.Join(';', Options.Paths) + ';' + GetEnvironmentVariable('PATH')));

  var Image := TPeImage.Create(Exe);
  var Bitness := 'x64';
  if Image.Header.Machine = MACHINE_I386 then
    Bitness := 'x86 under WOW64';
  Image.Free;

  Writeln('LoaderTimingProbe ', Options.Mode);
  Writeln('machine : ', MachineDescription);
  Writeln('target  : ', CommandLine, '  (', Bitness, ')');
  Writeln(ZydisStatusText);

  var Baseline: TLoaderRun := nil;
  var Run: TLoaderRun := nil;
  try
    if Options.Baseline then begin
      Baseline := ConfiguredRun(Options, False);
      Baseline.Attach := False;
      Baseline.Execute(Exe, CommandLine);
    end;
    Writeln;
    Run := ConfiguredRun(Options, True);
    Run.Execute(Exe, CommandLine);
    Run.ReportRelocation;
    if not Run.Attach then
      Run.ReportOneShots;
    Writeln;
    var TimedOutNote := '';
    if Run.TimedOut then
      TimedOutNote := ' (TIMED OUT)';
    Writeln(Format('exit code %d%s; %d debug strings; stdout %d bytes',
      [Run.ExitCode, TimedOutNote, Run.DebugStrings.Count, Length(Run.Output)]));
    if (Run.ImageMismatches > 0) or (Run.SavedByteMismatches > 0) or Run.TimedOut then
      ExitCode := 3;
    if Baseline <> nil then begin
      var SameExit := (Baseline.ExitCode = Run.ExitCode) and not (Baseline.TimedOut or Run.TimedOut);
      var SameOutput := SameBytes(Baseline.Output, Run.Output);
      var SameStrings := Baseline.DebugStrings.Text = Run.DebugStrings.Text;
      Writeln(Format('against the run with nothing planted: exit code %d vs %d (%s), stdout %d vs %d bytes (%s), ' +
        'debug strings %d vs %d (%s)',
        [Baseline.ExitCode, Run.ExitCode, YesNo(SameExit), Length(Baseline.Output), Length(Run.Output),
         YesNo(SameOutput), Baseline.DebugStrings.Count, Run.DebugStrings.Count, YesNo(SameStrings)])
        .Replace('(yes)', '(same)').Replace('(no)', '(DIFFERENT)'));
      if not (SameExit and SameOutput and SameStrings) then
        ExitCode := 3;
    end;
    Writeln('----- stdout of the target');
    Write(TEncoding.Default.GetString(Run.Output));
    Writeln('-----');
  finally
    Run.Free;
    Baseline.Free;
  end;
end;

procedure PrintUsage;
begin
  Writeln('LoaderTimingProbe -pe [-zydisdll <path>] <image> [<image>...]');
  Writeln('LoaderTimingProbe -run [-entries all|own|none] [-lines <module>]... [-reloc <module>]... [-plantsite]');
  Writeln('                  [-jmppatch] [-anyrecord] [-baseline] [-quiet] [-path <dir>]... [-timeout <s>] [-zydisdll <path>]');
  Writeln('                  <exe> [args...]');
  Writeln('LoaderTimingProbe -attach [-quiet] [-path <dir>]... [-timeout <s>] <exe> [args...]');
  Writeln('See the header of LoaderTimingProbe.dpr or DevTools\README.md.');
end;

begin
  FormatSettings.DecimalSeparator := '.';
  try
    var Options := ParseOptions;
    ZydisTryLoad(ResolveZydisDll(Options.ZydisDll));
    if Options.Mode = '-pe' then
      RunPeMode(Options.Rest)
    else if (Options.Mode = '-run') or (Options.Mode = '-attach') then
      RunLiveMode(Options)
    else begin
      PrintUsage;
      ExitCode := 2;
    end;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
