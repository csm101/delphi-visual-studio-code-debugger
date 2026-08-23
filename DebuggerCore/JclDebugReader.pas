unit JclDebugReader;

// Debug-info provider backed by JCL (JEDI Code Library) debug data: the
// MAP-derived symbol table JCL stores either as a linked 'JCLDEBUG' PE section
// or a sidecar '.jdbg' file. Implements ISourceLineProvider + IFunctionNameProvider
// (same contract as MapFileReader), sourcing from JCL's ready-made
// TJclBinDebugScanner. Used as a MAP-equivalent address->location + procedure-name
// fallback for a module that has JCL data but no embedded TD32 / no '.map'.
//
// Opt-in via the JCL_DEBUG define, DEFAULT ON (see below). When disabled
// (JCL_DEBUG_OFF), the whole JCL-dependent body is compiled out: the unit has
// ZERO dependency on JclDebug (compiles without JCL installed) and the factory
// functions return False, so no provider is ever registered.
//
// Scope / limitations (verified on SampleAppSingleExe, 2026-07-18):
//   * ADDRESS -> LOCATION only. Line -> address (BP binding) is NOT in JCL's
//     public API, so SourceLineToRva returns False; TD32 owns BP binding.
//   * JCL does NOT preserve the mangled `_ZZ$pdata$` / `$unwind$` nested-proc
//     EH publics (confirmed absent), so GetEnclosingProcedure* return False --
//     JCL cannot rebuild the nested-proc parent linkage MAP provides for
//     outer-scope locals. Nested procs DO appear in a readable demangled form
//     (`Unit.Outer.Inner$ActRec.$0$Body`); deriving parent linkage from that is
//     a possible future enhancement (see docs/DEBUG_INFO_FORMATS_TODO.md).

interface

{$IFNDEF JCL_DEBUG_OFF}
  {$DEFINE JCL_DEBUG}
{$ENDIF}

uses
  System.SysUtils;

// True when BinaryPath has usable JCL debug data. LinkedSection is set when the
// data is embedded in the PE ('JCLDEBUG' section, never stale); otherwise JdbgPath
// is the sidecar '.jdbg' path that exists (the caller applies its own staleness
// policy to the sidecar). Always False when JCL_DEBUG is disabled.
function JclDebugDataPresent(const BinaryPath: string;
  out LinkedSection: Boolean; out JdbgPath: string): Boolean;

// Creates a JCL-backed provider for BinaryPath. OutputRvaShift is added to every
// emitted RVA so a relocated DLL/BPL's addresses land in the main-exe RVA space
// (mirrors MapFileReader / TD32). Returns True + an IInterface implementing
// ISourceLineProvider + IFunctionNameProvider when valid JCL data was loaded.
// ImageSize is the module's PE image size: it bounds the exe-space RVA window
// [OutputRvaShift, OutputRvaShift+ImageSize) the provider will answer for, so a
// flat-path query with an out-of-range address (kernel VA, another module) is
// rejected instead of clamped to a wrong symbol (or crashing JCL under range
// checks). Always False (Provider = nil) when JCL_DEBUG is disabled.
function CreateJclDebugProvider(const BinaryPath: string;
  OutputRvaShift, ImageSize: UInt64; out Provider: IInterface): Boolean;

implementation

{$IFDEF JCL_DEBUG}

uses
  System.Classes, System.Generics.Collections, System.SyncObjs,
  Winapi.Windows,
  DebugInfoTypes, JclDebug;

const
  // JCL stores VAs relative to (module base + ModuleCodeOffset). The scanner
  // Addr for an image RVA is therefore Rva - ModuleCodeOffset. Must match JCL's
  // own ModuleCodeOffset ($1000) since the stored data was generated with it.
  MODULE_CODE_OFFSET = $1000;
  JCL_SECTION_NAME   = 'JCLDEBUG';

type
  PJclDbgHeaderLocal = ^TJclDbgHeader; // TJclDbgHeader is public in JclDebug

  TJclFileReader = class(TInterfacedObject,
    ISourceLineProvider, IFunctionNameProvider)
  private
    FStream:  TMemoryStream;   // kept alive for the scanner's lifetime
    FScanner: TJclBinDebugScanner;
    FShift:   UInt64;          // added to every emitted RVA (relocated module)
    FLoRva:   UInt64;          // exe-space RVA window [FLoRva, FHiRva) this module
    FHiRva:   UInt64;          // owns; queries outside it are rejected (see below)
    FSortedRvas:  TArray<UInt64>;
    FSortedBuilt: Boolean;
    // TJclBinDebugScanner lazily MUTATES its line/proc caches (CacheData=True) on
    // first query. The adapter queries providers from both the debug-loop thread
    // (ReportStopped) and the DAP dispatch thread (stackTrace), so every scanner
    // access must be serialized -- an unguarded concurrent lazy-build crashes.
    FLock: TCriticalSection;
    // An exe-space RVA this module owns AND that is at/above the code base. JCL's
    // scanner CLAMPS an out-of-range address to its nearest symbol (wrong answer)
    // and, under the adapter's {$R+}, range-errors on the truncated DWORD; both
    // are avoided by only querying JCL for in-window code RVAs. The flat provider
    // list would otherwise hand us kernel/other-module addresses.
    function InModuleCodeRange(Rva: UInt64): Boolean;
    function ExeRvaToScannerAddr(Rva: UInt64): DWORD;
    procedure BuildSortedRvas;
  public
    constructor Create(AStream: TMemoryStream; OutputRvaShift, ImageSize: UInt64);
    destructor Destroy; override;
    function ValidFormat: Boolean;
    // ISourceLineProvider
    function RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
    function SourceLineToRva(const FileName: string; Line: Integer; out Rva: UInt64): Boolean;
    function SortedRvas: TArray<UInt64>;
    // IFunctionNameProvider
    function RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
    function RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
    function NameToRva(const Name: string; out Rva: UInt64): Boolean;
    function GetEnclosingProcedure(const Inner: string; out Parent: string): Boolean;
    function GetEnclosingProcedureByRva(InnerRva: UInt64; out Parent: string): Boolean;
    function GetEnclosingProcedureRvaByRva(InnerRva: UInt64; out ParentRva: UInt64): Boolean;
  end;

{ PE section extraction (on disk, no loaded module) }

// Reads min(SizeOfRawData, VirtualSize) bytes of the named section from the PE at
// FileName into Stream (mirrors TJclPeSectionStream sizing). False if absent.
function ReadPeSection(const FileName, SectionName: string;
  Stream: TMemoryStream): Boolean;
var
  FS: TFileStream;
  Dos: TImageDosHeader;
  Nt: TImageNtHeaders64;
  Sec: TImageSectionHeader;
  Nm: AnsiString;
  DataSize: DWORD;
begin
  Result := False;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if FS.Read(Dos, SizeOf(Dos)) <> SizeOf(Dos) then Exit;
    if Dos.e_magic <> IMAGE_DOS_SIGNATURE then Exit;
    FS.Position := Dos._lfanew;
    if FS.Read(Nt, SizeOf(Nt)) <> SizeOf(Nt) then Exit;
    if Nt.Signature <> IMAGE_NT_SIGNATURE then Exit;
    FS.Position := Int64(Dos._lfanew) + SizeOf(DWORD) + SizeOf(TImageFileHeader) +
      Nt.FileHeader.SizeOfOptionalHeader;
    for var I := 0 to Nt.FileHeader.NumberOfSections - 1 do begin
      if FS.Read(Sec, SizeOf(Sec)) <> SizeOf(Sec) then Exit;
      // PE section names are an 8-byte field, NOT null-terminated when exactly 8
      // chars long (e.g. 'JCLDEBUG'), so bound the length to 8 explicitly.
      var NameLen := 0;
      while (NameLen < Length(Sec.Name)) and (Sec.Name[NameLen] <> 0) do
        Inc(NameLen);
      SetString(Nm, PAnsiChar(@Sec.Name[0]), NameLen);
      if not SameText(string(Nm), SectionName) then
        Continue;
      DataSize := Sec.SizeOfRawData;
      if (Sec.Misc.VirtualSize > 0) and (Sec.Misc.VirtualSize < DataSize) then
        DataSize := Sec.Misc.VirtualSize;
      Stream.Size := 0;
      FS.Position := Sec.PointerToRawData;
      Stream.CopyFrom(FS, DataSize);
      Stream.Position := 0;
      Exit(True);
    end;
  finally
    FS.Free;
  end;
end;

function SidecarJdbgPath(const BinaryPath: string): string;
begin
  Result := ChangeFileExt(BinaryPath, '.jdbg');
end;

function HasLinkedJclSection(const BinaryPath: string): Boolean;
var
  Probe: TMemoryStream;
begin
  Result := False;
  if not FileExists(BinaryPath) then Exit;
  Probe := TMemoryStream.Create;
  try
    try
      Result := ReadPeSection(BinaryPath, JCL_SECTION_NAME, Probe);
    except
      Result := False;
    end;
  finally
    Probe.Free;
  end;
end;

{ TJclFileReader }

constructor TJclFileReader.Create(AStream: TMemoryStream; OutputRvaShift, ImageSize: UInt64);
begin
  inherited Create;
  FLock   := TCriticalSection.Create;
  FStream := AStream;                 // takes ownership
  FShift  := OutputRvaShift;
  FLoRva  := OutputRvaShift;
  {$Q-}{$R-}
  FHiRva  := OutputRvaShift + ImageSize;
  {$Q+}{$R+}
  FScanner := TJclBinDebugScanner.Create(FStream, True, False);
  // Prime the lazy line/proc caches now, on the single load thread, so later
  // concurrent reads never trigger a mutating build (belt-and-suspenders with
  // FLock). Safe no-ops if the format is invalid.
  if FScanner.ValidFormat then begin
    FScanner.LineNumberFromAddr(0);
    FScanner.ProcNameFromAddr(0);
  end;
end;

destructor TJclFileReader.Destroy;
begin
  FScanner.Free;
  FStream.Free;
  FLock.Free;
  inherited;
end;

function TJclFileReader.ValidFormat: Boolean;
begin
  Result := FScanner.ValidFormat;
end;

function TJclFileReader.InModuleCodeRange(Rva: UInt64): Boolean;
begin
  // Below FLoRva+$1000 the scanner Addr (Rva-FShift-$1000) underflows; at/above
  // FHiRva the address belongs to another module or none. FHiRva=FLoRva (unknown
  // image size) disables the upper bound but keeps the lower guard.
  if Rva < FLoRva + MODULE_CODE_OFFSET then Exit(False);
  Result := (FHiRva <= FLoRva) or (Rva < FHiRva);
end;

function TJclFileReader.ExeRvaToScannerAddr(Rva: UInt64): DWORD;
begin
  {$Q-}{$R-}
  Result := DWORD(Rva - FShift - MODULE_CODE_OFFSET);
  {$Q+}{$R+}
end;

function TJclFileReader.RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
begin
  Result := False;
  if not InModuleCodeRange(Rva) then Exit;
  var Addr := ExeRvaToScannerAddr(Rva);
  FLock.Enter;
  try
    // ModuleNameFromAddr = '' means Addr is outside every unit range JCL knows;
    // without this guard the scanner clamps to the nearest line of an unrelated unit.
    if FScanner.ModuleNameFromAddr(Addr) = '' then Exit;
    var Line := FScanner.LineNumberFromAddr(Addr);
    if Line <= 0 then Exit;
    var Src := FScanner.SourceNameFromAddr(Addr);
    if Src = '' then Exit;
    Loc.SourceFile := ExtractFileName(Src);
    Loc.Line := Line;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TJclFileReader.SourceLineToRva(const FileName: string; Line: Integer;
  out Rva: UInt64): Boolean;
begin
  // JCL exposes no line->address lookup (FLineNumbers is reverse-searched only).
  // TD32 owns BP binding; see the unit header.
  Rva := 0;
  Result := False;
end;

procedure TJclFileReader.BuildSortedRvas;
var
  P: PByte;
  CurrVA: DWORD;
  Shift, N: Integer;
  B: Byte;
  Val: Integer;
  List: TList<UInt64>;

  function ReadVarint: Integer;
  begin
    N := 0; Shift := 0;
    repeat
      B := P^;
      Inc(P);
      Inc(N, (B and $7F) shl Shift);
      Inc(Shift, 7);
    until B and $80 = 0;
    Result := N;
  end;

begin
  FSortedBuilt := True;
  SetLength(FSortedRvas, 0);
  if (FStream.Memory = nil) or not FScanner.ValidFormat then Exit;
  var Hdr := PJclDbgHeaderLocal(FStream.Memory);
  List := TList<UInt64>.Create;
  try
    P := PByte(NativeUInt(FStream.Memory) + NativeUInt(Hdr^.LineNumbers));
    CurrVA := 0;
    while True do begin
      Val := ReadVarint;
      if Val = MaxInt then Break;
      Inc(CurrVA, DWORD(Val));
      ReadVarint; // line-number delta (unused for the RVA index)
      {$Q-}{$R-}
      List.Add(UInt64(CurrVA) + MODULE_CODE_OFFSET + FShift);
      {$Q+}{$R+}
    end;
    List.Sort;
    // Dedup.
    var Last: Integer := -1;
    for var I := 0 to List.Count - 1 do
      if (Last < 0) or (List[I] <> FSortedRvas[Last]) then begin
        SetLength(FSortedRvas, Last + 2);
        Inc(Last);
        FSortedRvas[Last] := List[I];
      end;
  finally
    List.Free;
  end;
end;

function TJclFileReader.SortedRvas: TArray<UInt64>;
begin
  FLock.Enter;
  try
    if not FSortedBuilt then
      BuildSortedRvas;
    Result := FSortedRvas;
  finally
    FLock.Leave;
  end;
end;

function TJclFileReader.RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
begin
  Result := False;
  Name := '';
  if not InModuleCodeRange(Rva) then Exit;
  var Addr := ExeRvaToScannerAddr(Rva);
  FLock.Enter;
  try
    if FScanner.ModuleNameFromAddr(Addr) = '' then Exit;
    var Nm := FScanner.ProcNameFromAddr(Addr);
    if Nm = '' then Exit;
    Name := Nm;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TJclFileReader.RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
begin
  Result := False;
  FuncRva := 0;
  if not InModuleCodeRange(Rva) then Exit;
  var Addr := ExeRvaToScannerAddr(Rva);
  FLock.Enter;
  try
    if FScanner.ModuleNameFromAddr(Addr) = '' then Exit;
    var Offset: Integer;
    var Nm := FScanner.ProcNameFromAddr(Addr, Offset);
    if Nm = '' then Exit;
    {$Q-}{$R-}
    FuncRva := Rva - UInt64(Offset);
    {$Q+}{$R+}
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TJclFileReader.NameToRva(const Name: string; out Rva: UInt64): Boolean;
begin
  // Reverse lookup not implemented (would need unit/proc split; TD32/MAP own it).
  Rva := 0;
  Result := False;
end;

function TJclFileReader.GetEnclosingProcedure(const Inner: string;
  out Parent: string): Boolean;
begin
  Parent := '';
  Result := False; // JCL lacks the `_ZZ` nested-proc linkage (see unit header)
end;

function TJclFileReader.GetEnclosingProcedureByRva(InnerRva: UInt64;
  out Parent: string): Boolean;
begin
  Parent := '';
  Result := False;
end;

function TJclFileReader.GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
  out ParentRva: UInt64): Boolean;
begin
  ParentRva := 0;
  Result := False;
end;

{ Factory }

function JclDebugDataPresent(const BinaryPath: string;
  out LinkedSection: Boolean; out JdbgPath: string): Boolean;
begin
  LinkedSection := False;
  JdbgPath := '';
  if BinaryPath = '' then Exit(False);
  if HasLinkedJclSection(BinaryPath) then begin
    LinkedSection := True;
    Exit(True);
  end;
  var Sidecar := SidecarJdbgPath(BinaryPath);
  if FileExists(Sidecar) then begin
    JdbgPath := Sidecar;
    Exit(True);
  end;
  Result := False;
end;

function CreateJclDebugProvider(const BinaryPath: string;
  OutputRvaShift, ImageSize: UInt64; out Provider: IInterface): Boolean;
var
  Stream: TMemoryStream;
begin
  Provider := nil;
  Result := False;
  if BinaryPath = '' then Exit;
  Stream := TMemoryStream.Create;
  try
    var Loaded := False;
    if HasLinkedJclSection(BinaryPath) then
      Loaded := ReadPeSection(BinaryPath, JCL_SECTION_NAME, Stream)
    else begin
      var Sidecar := SidecarJdbgPath(BinaryPath);
      if FileExists(Sidecar) then begin
        Stream.LoadFromFile(Sidecar);
        Loaded := True;
      end;
    end;
    if not Loaded then begin
      Stream.Free;
      Exit;
    end;
  except
    Stream.Free;
    Exit;
  end;
  // Stream ownership transfers to the reader.
  var Reader := TJclFileReader.Create(Stream, OutputRvaShift, ImageSize);
  if not Reader.ValidFormat then begin
    Reader.Free;   // frees the owned stream too
    Exit;
  end;
  Provider := Reader as IInterface;
  Result := True;
end;

{$ELSE JCL_DEBUG}

// JCL_DEBUG disabled: no JclDebug dependency, no provider ever created.

function JclDebugDataPresent(const BinaryPath: string;
  out LinkedSection: Boolean; out JdbgPath: string): Boolean;
begin
  LinkedSection := False;
  JdbgPath := '';
  Result := False;
end;

function CreateJclDebugProvider(const BinaryPath: string;
  OutputRvaShift, ImageSize: UInt64; out Provider: IInterface): Boolean;
begin
  Provider := nil;
  Result := False;
end;

{$ENDIF JCL_DEBUG}

end.
