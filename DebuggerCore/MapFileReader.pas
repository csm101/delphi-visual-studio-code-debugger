unit MapFileReader;

// MAP file reader with on-demand per-unit loading.
// The file is memory-mapped once (instant). A background thread scans for
// "Line numbers for" section headers and builds an offset index. Individual
// unit sections are parsed only when a lookup touches them.
// The Publics section (function names) is parsed in background after the index.
// Startup cost: near zero. Per-unit parse: <50 ms even for large units.

interface

uses
  System.SysUtils, System.StrUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.SyncObjs, System.IOUtils,
  Winapi.Windows,
  DebugInfoTypes, DapProtocol;

type
  TUnitSectionInfo = record
    DataOffset: Int64;   // byte offset of first data line in mmap'd file
    MinRva:     UInt64;  // first RVA found in this section (for range lookup)
    FullPath:   string;  // full source path from MAP "Line numbers for" header
  end;

  TRvaSectionEntry = record
    MinRva:  UInt64;
    UnitKey: string;    // uppercase filename (matches FUnitSections key)
  end;

  TMapFile = class(TInterfacedObject,
    ISourceLineProvider, IFunctionNameProvider, IBackgroundIndexProvider)
  private
    // Memory-mapped file
    FFileHandle:     THandle;
    FMappingHandle:  THandle;
    FMapData:        PByte;
    FMapSize:        Int64;
    // File context
    FMapPath:        string;
    FPreferredBase:  UInt64;
    FOutputRvaShift: UInt64; // added to every emitted RVA -- used when this MAP describes a relocated DLL/BPL
    // Segment base RVAs: written on main thread before background starts; read-only after.
    FSegmentBaseRvas: TDictionary<Integer, UInt64>;
    // Unit section index (background-filled, protected by FLock).
    FUnitSections:   TDictionary<string, TUnitSectionInfo>; // key = UPPER filename
    FSectionsByRva:  TArray<TRvaSectionEntry>;  // sorted by MinRva; built at index complete
    FPublicsDataOff: Int64;   // offset of Publics data first line; 0 = not found
    FIndexReady:     Boolean;
    FPubsReady:      Boolean;
    FLock:           TCriticalSection;
    // Per-unit load cache (main thread only; no lock needed).
    FLoadedUnits:    TDictionary<string, Boolean>;
    // Symbol tables (main thread only; populated lazily as units load).
    FRvaToLoc:       TDictionary<UInt64, TSourceLocation>;
    FLineToRva:      TDictionary<string, UInt64>;
    FSortedRvas:     TArray<UInt64>;
    // Public symbols (background-filled; read under FLock until FPubsReady).
    FSortedPubRvas:  TArray<UInt64>;
    FRvaToPubName:   TDictionary<UInt64, string>;
    // Reverse lookup indices for NameToRva (built lazily on first call).
    // Without them every NameToRva did up to three full linear scans over
    // FRvaToPubName, which on a single-EXE VCL app (tens of thousands of
    // publics) cost ~1-2 s per evaluate / hover.
    FPubNameLowerToRva: TDictionary<string, UInt64>; // key = LowerCase(full pub name)
    FPubTailLowerToRva: TDictionary<string, UInt64>; // key = LowerCase(last dotted segment)
    // Data-segment publics indexed by last segment. An unqualified name
    // (e.g. `Application`) is a global VARIABLE far more often than a free
    // proc, so a data symbol must win over an identically-tailed code symbol
    // (`Vcl.Forms.Application` data vs `...TppFilePathVariables.Application`
    // code). Without this the value comes back as raw code bytes shown as int.
    FPubDataTailLowerToRva: TDictionary<string, UInt64>;
    // Publics indexed by their last TWO dotted segments (`Class.Method`). The
    // MAP qualifies methods with the unit but WITHOUT the dotted namespace
    // (`Forms.TApplication.GetMainFormHandle`, not `Vcl.Forms.TApplication...`),
    // so a `ClassName.Method` getter lookup ("TApplication.GetMainFormHandle")
    // matched neither the exact full name nor (safely) the bare last segment
    // (which collides across classes, e.g. TcxControlHintHelper.GetHintControl).
    // The class+method pair disambiguates precisely while ignoring the unit.
    FPubClassMethodLowerToRva: TDictionary<string, UInt64>;
    FPubReverseReady:   Boolean;
    // Segment numbers whose Class is DATA / BSS / TLS, and the RVAs of the
    // publics that live in them. Filled eagerly (segments) and during the
    // publics scan (RVAs).
    FDataSegments:      TDictionary<Integer, Boolean>;
    FDataRvas:          TDictionary<UInt64, Boolean>;
    // Real SizeOfImage of the module this MAP describes (0 = unknown). Bounds
    // RvaIsInImage so an Rva from another module cannot be attributed here.
    FImageSize:         UInt64;
    FInnerToParent:  TDictionary<string, string>;
    // Per-RVA nested-proc parent. Built by correlating each `_ZZ$pdata$`
    // mangled symbol's (Unit, Inner) with the corresponding plain public
    // `Unit.Inner` at the inner proc's body RVA. Disambiguates same-named
    // nested procs across different units (SampleApp has nested CreateNodes
    // in multiple units; FInnerToParent collides, FRvaToParent does not).
    FRvaToParent:    TDictionary<UInt64, string>;
    // Inner-proc body RVA -> ENCLOSING proc body RVA. Resolved within the
    // SAME unit (parent last-segment + child's unit), so the parent-frame
    // walk never round-trips through a bare name that collides across
    // units (e.g. two units each with a nested `Mid`/`Inner`).
    FRvaToParentRva: TDictionary<UInt64, UInt64>;

    procedure OpenMappedFile;
    procedure CloseMappedFile;
    procedure ParseSegmentTableEager;
    procedure BuildIndexBackground;
    procedure ParseUnitSectionAt(const UnitKey, FullPath: string; DataOffset: Int64);
    procedure ParsePublicsAt(DataOffset: Int64);
    procedure EnsureUnitByKey(const UnitKey: string);
    procedure EnsureUnitForRva(Rva: UInt64);
    procedure EnsureUnitForFile(const FileName: string);
    procedure WaitForPubs;
    procedure BuildPubReverseIndex;
    procedure RebuildSortedRvas;
    function  FindUnitKeyForRva(Rva: UInt64): string;
    function  LineKey(const FileName: string; Line: Integer): string;
    function  SegmentRvaFromToken(const Token: string; out Rva: UInt64): Boolean;
    function  RvaIsInImage(Rva: UInt64): Boolean;
    // True when the nearest-preceding public `PubRva` may legitimately be treated
    // as the function CONTAINING Rva. Rejects a DATA public and an implausibly
    // large gap, so an address inside a gap / stripped routine no longer takes the
    // name (and entry RVA) of an unrelated preceding symbol.
    function  PublicCanContain(PubRva, Rva: UInt64): Boolean;
    function  LoadUnitIndexFromSidecar(const SidecarPath: string): Boolean;
    procedure SaveUnitIndexToSidecar(const SidecarPath: string);

  public
    constructor Create;
    destructor  Destroy; override;
    // Block until background indexing finished (public so the adapter's background
    // symbol loader can fully index a module off the dispatch thread before use).
    procedure   WaitForIndex;
    procedure   LoadFromFile(const MapPath: string; PreferredBase: UInt64 = 0;
                  OutputRvaShift: UInt64 = 0);
    // Real SizeOfImage of the module this MAP describes. Set by the module loader
    // right after LoadFromFile so RvaIsInImage bounds queries to the module's true
    // window instead of a blanket 1 GB. 0 (unset) keeps the old fallback.
    property    ImageSize: UInt64 read FImageSize write FImageSize;
    function    RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
    function    RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
    function    RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
    function    NameToRva(const Name: string; out Rva: UInt64): Boolean;
    function    SourceLineToRva(const FileName: string; Line: Integer;
                  out Rva: UInt64): Boolean;
    function    FirstUserRva: UInt64;
    function    GetEnclosingProcedure(const Inner: string; out Parent: string): Boolean;
    function    GetEnclosingProcedureByRva(InnerRva: UInt64; out Parent: string): Boolean;
    function    GetEnclosingProcedureRvaByRva(InnerRva: UInt64; out ParentRva: UInt64): Boolean;
    function    SortedRvas: TArray<UInt64>;
    // IBackgroundIndexProvider: True while the background publics parse is still
    // running, so a name miss may yet resolve once it completes.
    function    BackgroundIndexingPending: Boolean;
  end;

function ReadPEPreferredBase(const ExePath: string): UInt64;

implementation

{ --------------------------------------------------------------------------- }
{  Helpers                                                                     }
{ --------------------------------------------------------------------------- }

// Parses an Itanium-mangled _ZZ... name for nested procedure relationships.
function ParseDelphiNestedMangled(const Mangled: string;
  out InnerName, ParentName, UnitName: string): Boolean;

  function ReadIdent(var P: Integer; out S: string): Boolean;
  var
    Len: Integer;
  begin
    Result := False;
    if (P > Length(Mangled)) or not CharInSet(Mangled[P], ['0'..'9']) then Exit;
    Len := 0;
    while (P <= Length(Mangled)) and CharInSet(Mangled[P], ['0'..'9']) do begin
      Len := Len * 10 + Ord(Mangled[P]) - Ord('0');
      Inc(P);
    end;
    if (Len < 1) or (P + Len - 1 > Length(Mangled)) then Exit;
    S := Copy(Mangled, P, Len);
    Inc(P, Len);
    Result := True;
  end;

var
  P: Integer;
  Comp: string;
  Parts: TArray<string>;
begin
  Result     := False;
  InnerName  := '';
  ParentName := '';
  UnitName   := '';
  if not Mangled.StartsWith('_ZZ') then Exit;
  // Count consecutive `Z` characters after the leading `_`. Each `Z`
  // beyond the first one introduces one extra "local name" nesting
  // context. So `_ZZ` (two Z's after `_`) = 1 nesting level,
  // `_ZZZ` (three Z's) = 2 levels, etc. The IMMEDIATE parent walked for
  // an inner proc is the previous local-name component (e.g. `Mid` for
  // an Inner declared inside `Mid`); deeper ancestors are reachable via
  // successive GetEnclosingProcedureByRva calls.
  P := 2;
  var TotalZ := 0;
  while (P <= Length(Mangled)) and (Mangled[P] = 'Z') do begin
    Inc(TotalZ);
    Inc(P);
  end;
  if TotalZ < 2 then Exit;
  var NestingDepth := TotalZ - 1;
  if (P > Length(Mangled)) or (Mangled[P] <> 'N') then Exit;
  Inc(P);
  while (P <= Length(Mangled)) and (Mangled[P] <> 'E') do begin
    if not ReadIdent(P, Comp) then Exit;
    Parts := Parts + [Comp];
  end;
  if Length(Parts) = 0 then Exit;
  UnitName := Parts[0];
  if Length(Parts) >= 2 then
    ParentName := string.Join('.', Copy(Parts, 1, Length(Parts) - 1))
  else
    ParentName := Parts[0];
  if (P > Length(Mangled)) or (Mangled[P] <> 'E') then Exit;
  Inc(P);
  // For each nesting level, skip the function param encoding (`v` / `Pv`
  // / `Pi` / etc. up to the next `E`), then read the local-name
  // identifier. The LAST identifier read is InnerName; everything before
  // becomes ParentName.
  var LocalChain: TArray<string>;
  for var Level := 1 to NestingDepth do begin
    while (P <= Length(Mangled)) and (Mangled[P] <> 'E') do Inc(P);
    if (P > Length(Mangled)) or (Mangled[P] <> 'E') then Exit;
    Inc(P);
    if not ReadIdent(P, Comp) then begin
      // Top-level `_ZZ...E` form: last `E` closes the function scope and
      // the deepest identifier IS the only local. Pop out gracefully.
      if Level = 1 then begin
        Result := False;
        Exit;
      end;
      Break;
    end;
    LocalChain := LocalChain + [Comp];
  end;
  if Length(LocalChain) = 0 then Exit;
  InnerName := LocalChain[High(LocalChain)];
  // Append intermediate local names (Mid in the 3-Z case) to the parent
  // chain so the walker sees `RunDeepNesting.Mid` for Inner's parent.
  if Length(LocalChain) > 1 then begin
    var ExtraParents := Copy(LocalChain, 0, Length(LocalChain) - 1);
    ParentName := ParentName + '.' + string.Join('.', ExtraParents);
  end;
  Result := True;
end;

// Advances P past one text line, returning content without CRLF.
// Returns False only when P >= PEnd before reading any byte.
function ScanLine(var P: PByte; const PEnd: PByte; out Line: string): Boolean;
var
  Start: PByte;
  Len: NativeInt;
begin
  if P >= PEnd then Exit(False);
  Start := P;
  while (P < PEnd) and (P^ <> 10) do Inc(P);
  Len := P - Start;
  if (Len > 0) and ((Start + Len - 1)^ = 13) then Dec(Len); // strip CR
  if Len > 0 then
    SetString(Line, PAnsiChar(Start), Len)
  else
    Line := '';
  if P < PEnd then Inc(P); // skip LF
  Result := True;
end;

{ --------------------------------------------------------------------------- }
{  ReadPEPreferredBase                                                         }
{ --------------------------------------------------------------------------- }

function ReadPEPreferredBase(const ExePath: string): UInt64;
var
  F: TFileStream;
  DosHeader: array[0..63] of Byte;
  PEOffset: DWORD;
  Signature: DWORD;
  Magic: WORD;
  Base: UInt64;
begin
  Result := $400000;
  if not FileExists(ExePath) then Exit;
  F := TFileStream.Create(ExePath, fmOpenRead or fmShareDenyNone);
  try
    if F.Size < 64 then Exit;
    F.ReadBuffer(DosHeader, 64);
    if (DosHeader[0] <> Ord('M')) or (DosHeader[1] <> Ord('Z')) then Exit;
    PEOffset := PCardinal(@DosHeader[$3C])^;
    F.Position := PEOffset;
    F.ReadBuffer(Signature, 4);
    if Signature <> $00004550 then Exit;
    F.Position := PEOffset + 4 + 20;
    F.ReadBuffer(Magic, 2);
    if Magic <> $020B then Exit;
    F.Position := PEOffset + 4 + 20 + 24;
    F.ReadBuffer(Base, 8);
    Result := Base;
  finally
    F.Free;
  end;
end;

{ --------------------------------------------------------------------------- }
{  TMapFile                                                                    }
{ --------------------------------------------------------------------------- }

constructor TMapFile.Create;
begin
  inherited;
  FFileHandle      := INVALID_HANDLE_VALUE;
  FMappingHandle   := 0;
  FMapData         := nil;
  FMapSize         := 0;
  FSegmentBaseRvas := TDictionary<Integer, UInt64>.Create;
  FUnitSections    := TDictionary<string, TUnitSectionInfo>.Create;
  FLoadedUnits     := TDictionary<string, Boolean>.Create;
  FRvaToLoc        := TDictionary<UInt64, TSourceLocation>.Create;
  FLineToRva       := TDictionary<string, UInt64>.Create;
  FRvaToPubName    := TDictionary<UInt64, string>.Create;
  FPubNameLowerToRva := TDictionary<string, UInt64>.Create;
  FPubTailLowerToRva := TDictionary<string, UInt64>.Create;
  FPubDataTailLowerToRva := TDictionary<string, UInt64>.Create;
  FPubClassMethodLowerToRva := TDictionary<string, UInt64>.Create;
  FDataSegments      := TDictionary<Integer, Boolean>.Create;
  FDataRvas          := TDictionary<UInt64, Boolean>.Create;
  FInnerToParent   := TDictionary<string, string>.Create;
  FRvaToParent     := TDictionary<UInt64, string>.Create;
  FRvaToParentRva  := TDictionary<UInt64, UInt64>.Create;
  FLock            := TCriticalSection.Create;
end;

destructor TMapFile.Destroy;
begin
  CloseMappedFile;
  FSegmentBaseRvas.Free;
  FUnitSections.Free;
  FLoadedUnits.Free;
  FRvaToLoc.Free;
  FLineToRva.Free;
  FRvaToPubName.Free;
  FPubNameLowerToRva.Free;
  FPubTailLowerToRva.Free;
  FPubDataTailLowerToRva.Free;
  FPubClassMethodLowerToRva.Free;
  FDataSegments.Free;
  FDataRvas.Free;
  FInnerToParent.Free;
  FRvaToParent.Free;
  FRvaToParentRva.Free;
  FLock.Free;
  inherited;
end;

procedure TMapFile.OpenMappedFile;
begin
  FFileHandle := CreateFile(PChar(FMapPath), GENERIC_READ, FILE_SHARE_READ, nil,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FFileHandle = INVALID_HANDLE_VALUE then Exit;
  var SizeLow, SizeHigh: DWORD;
  SizeLow   := GetFileSize(FFileHandle, @SizeHigh);
  FMapSize  := Int64(SizeHigh) shl 32 or SizeLow;
  if FMapSize = 0 then begin
    CloseMappedFile;
    Exit;
  end;
  FMappingHandle := CreateFileMapping(FFileHandle, nil, PAGE_READONLY, 0, 0, nil);
  if FMappingHandle = 0 then begin
    CloseMappedFile;
    Exit;
  end;
  FMapData := MapViewOfFile(FMappingHandle, FILE_MAP_READ, 0, 0, 0);
  if FMapData = nil then
    CloseMappedFile;
end;

procedure TMapFile.CloseMappedFile;
begin
  if FMapData <> nil then begin
    UnmapViewOfFile(FMapData);
    FMapData := nil;
  end;
  if FMappingHandle <> 0 then begin
    CloseHandle(FMappingHandle);
    FMappingHandle := 0;
  end;
  if FFileHandle <> INVALID_HANDLE_VALUE then begin
    CloseHandle(FFileHandle);
    FFileHandle := INVALID_HANDLE_VALUE;
  end;
  FMapSize := 0;
end;

procedure TMapFile.LoadFromFile(const MapPath: string; PreferredBase: UInt64 = 0;
  OutputRvaShift: UInt64 = 0);
begin
  FMapPath        := MapPath;
  FPreferredBase  := PreferredBase;
  FOutputRvaShift := OutputRvaShift;
  FIndexReady    := False;
  FPubsReady     := False;
  FPublicsDataOff := 0;
  FUnitSections.Clear;
  FLoadedUnits.Clear;
  FRvaToLoc.Clear;
  FLineToRva.Clear;
  FRvaToPubName.Clear;
  FInnerToParent.Clear;
  FRvaToParent.Clear;
  FRvaToParentRva.Clear;
  FSegmentBaseRvas.Clear;
  FSortedRvas    := nil;
  FSortedPubRvas := nil;
  FSectionsByRva := nil;
  CloseMappedFile;

  if not FileExists(MapPath) then Exit;

  OpenMappedFile;
  if FMapData = nil then Exit;

  // Parse segment table synchronously (reads first ~10 KB; instant).
  if PreferredBase > 0 then begin
    ParseSegmentTableEager;
    DapLog(Format('[MAP] SegTable: preferredBase=$%x segments=%d',
      [PreferredBase, FSegmentBaseRvas.Count]));
    for var KV in FSegmentBaseRvas do
      DapLog(Format('[MAP]   seg %d baseRva=$%x', [KV.Key, KV.Value]));
  end else
    DapLog('[MAP] SegTable skipped (PreferredBase=0)');

  // All remaining work is in background.
  TThread.CreateAnonymousThread(procedure
  begin
    BuildIndexBackground;
  end).Start;
end;

{ --------------------------------------------------------------------------- }
{  Segment table (main thread)                                                 }
{ --------------------------------------------------------------------------- }

procedure TMapFile.ParseSegmentTableEager;
// Scans a limited prefix of the mmap for "SSSS:LLLLLLLLLLLLLLLL" patterns
// that appear in the "Start Length Name Class" section.
// Stops after the first "Line numbers for" line (segment table is always first).
const
  ScanLimit = 512 * 1024; // 512 KB is more than enough for any segment table
var
  P, PEnd: PByte;
  Line, SegStr, AddrPart: string;
  ColonPos, SegNum, NextIdx: Integer;
  LinearAddr: UInt64;
  IsHex: Boolean;
begin
  var Limit := FMapSize;
  if Int64(ScanLimit) < Limit then Limit := ScanLimit;
  P    := FMapData;
  PEnd := FMapData + Limit;
  while ScanLine(P, PEnd, Line) do begin
    var Trimmed := Line.Trim;
    // Stop when we reach the line-numbers section (segment table is now complete).
    if Trimmed.StartsWith('Line numbers for ') then Break;

    if Trimmed.Length < 21 then Continue;
    ColonPos := Trimmed.IndexOf(':');
    if (ColonPos < 1) or (ColonPos > 4) then Continue;
    SegStr := Trimmed.Substring(0, ColonPos);
    SegNum := StrToIntDef('$' + SegStr, -1);
    if SegNum <= 0 then Continue;
    // The Class is the last whitespace-delimited token on a segment line
    // (`SSSS:start length .name CLASS`). DATA/BSS/TLS hold global variables.
    var SegTokens := Trimmed.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    if Length(SegTokens) > 0 then begin
      var Cls := SegTokens[High(SegTokens)].ToUpper;
      if (Cls = 'DATA') or (Cls = 'BSS') or (Cls = 'TLS') then
        FDataSegments.AddOrSetValue(SegNum, True);
    end;
    if Trimmed.Length < ColonPos + 1 + 16 then Continue;
    AddrPart := Trimmed.Substring(ColonPos + 1, 16);
    IsHex := True;
    for var C in AddrPart do
      if not CharInSet(C, ['0'..'9', 'A'..'F', 'a'..'f']) then begin
        IsHex := False;
        Break;
      end;
    if not IsHex then Continue;
    NextIdx := ColonPos + 1 + 16;
    if (NextIdx < Trimmed.Length) and (Trimmed.Chars[NextIdx] <> ' ') then Continue;
    LinearAddr := StrToInt64Def('$' + AddrPart, 0);
    if (LinearAddr > 0) and (LinearAddr >= FPreferredBase) then begin
      {$Q-}
      FSegmentBaseRvas.AddOrSetValue(SegNum, (LinearAddr - FPreferredBase) + FOutputRvaShift);
      {$Q+}
    end;
  end;
end;

{ --------------------------------------------------------------------------- }
{  Background index build                                                      }
{ --------------------------------------------------------------------------- }

const
  MAP_SIDECAR_MAGIC: UInt32 = $4D495832; // 'MIX2' -- includes FullPath field

function MapSidecarIsFresh(const MapPath, SidecarPath: string): Boolean;
begin
  Result := FileExists(SidecarPath) and
            (TFile.GetLastWriteTime(SidecarPath) >= TFile.GetLastWriteTime(MapPath));
end;

function TMapFile.LoadUnitIndexFromSidecar(const SidecarPath: string): Boolean;
var
  F: TFileStream;
  Magic: UInt32;
  Count, I: UInt32;
  KeyLen: UInt16;
  KeyBuf: TBytes;
  Info: TUnitSectionInfo;
begin
  Result := False;
  try
    F := TFileStream.Create(SidecarPath, fmOpenRead or fmShareDenyNone);
    try
      if F.Size < 8 then Exit;
      F.ReadBuffer(Magic, 4);
      if Magic <> MAP_SIDECAR_MAGIC then Exit;
      F.ReadBuffer(Count, 4);
      for I := 0 to Count - 1 do begin
        F.ReadBuffer(KeyLen, 2);
        SetLength(KeyBuf, KeyLen);
        if KeyLen > 0 then F.ReadBuffer(KeyBuf[0], KeyLen);
        var Key: string;
        SetString(Key, PAnsiChar(KeyBuf), KeyLen);
        F.ReadBuffer(Info.DataOffset, 8);
        F.ReadBuffer(Info.MinRva, 8);
        var PathLen: UInt16;
        F.ReadBuffer(PathLen, 2);
        var PathBuf: TBytes;
        SetLength(PathBuf, PathLen);
        if PathLen > 0 then F.ReadBuffer(PathBuf[0], PathLen);
        Info.FullPath := TEncoding.UTF8.GetString(PathBuf);
        FUnitSections.Add(Key, Info);
      end;
      F.ReadBuffer(FPublicsDataOff, 8);
      Result := True;
    finally
      F.Free;
    end;
  except
    FUnitSections.Clear;
    Result := False;
  end;
end;

procedure TMapFile.SaveUnitIndexToSidecar(const SidecarPath: string);
var
  F: TStream;
  Magic: UInt32;
  Count: UInt32;
begin
  try
    // Buffered for the same reason as TRsmFile.SerializeIndexToStream: the
    // loop below issues ~7 tiny WriteBuffer calls per unit, and against a raw
    // TFileStream each one is a separate WriteFile syscall (measured ~2.4 us
    // on this machine). Byte format unchanged.
    F := TBufferedFileStream.Create(SidecarPath, fmCreate, 256 * 1024);
    try
      Magic := MAP_SIDECAR_MAGIC;
      F.WriteBuffer(Magic, 4);
      Count := FUnitSections.Count;
      F.WriteBuffer(Count, 4);
      for var KV in FUnitSections do begin
        var KeyBytes := TEncoding.ASCII.GetBytes(KV.Key);
        var KeyLen: UInt16 := Length(KeyBytes);
        F.WriteBuffer(KeyLen, 2);
        if KeyLen > 0 then F.WriteBuffer(KeyBytes[0], KeyLen);
        F.WriteBuffer(KV.Value.DataOffset, 8);
        F.WriteBuffer(KV.Value.MinRva, 8);
        var PathBytes := TEncoding.UTF8.GetBytes(KV.Value.FullPath);
        var PathLen: UInt16 := Length(PathBytes);
        F.WriteBuffer(PathLen, 2);
        if PathLen > 0 then F.WriteBuffer(PathBytes[0], PathLen);
      end;
      F.WriteBuffer(FPublicsDataOff, 8);
    finally
      F.Free;
    end;
  except
    // Sidecar write failure is non-fatal; delete partial file if present.
    if FileExists(SidecarPath) then
      TFile.Delete(SidecarPath);
  end;
end;

procedure TMapFile.BuildIndexBackground;
// Sequential scan of the entire mmap. Builds FUnitSections and records
// FPublicsDataOff. Collects MinRva for each unit section. Then parses Publics.
// If a fresh sidecar index exists, loads from it instead of scanning.
var
  P, PEnd, PBase: PByte;
  Line: string;
  Sections: TList<TRvaSectionEntry>;
var
  SidecarPath: string;
begin
  SidecarPath := FMapPath + '.idx';
  DapLog(Format('[MAP] BuildIndex start: %s sidecar=%s segBases=%d',
    [ExtractFileName(FMapPath), ExtractFileName(SidecarPath),
     FSegmentBaseRvas.Count]));

  // Fast path: load from sidecar when fresh.
  // Skip sidecar entirely for relocated DLL/BPL loads -- MinRva values would
  // be baked at one shift but reused across runs where the shift may differ
  // (target EXE base or BPL load base may move between sessions).
  if (FOutputRvaShift = 0) and MapSidecarIsFresh(FMapPath, SidecarPath) and
     LoadUnitIndexFromSidecar(SidecarPath) then begin
    // Rebuild FSectionsByRva from the loaded FUnitSections.
    Sections := TList<TRvaSectionEntry>.Create;
    try
      for var KV in FUnitSections do
        if KV.Value.MinRva > 0 then begin
          var E: TRvaSectionEntry;
          E.MinRva  := KV.Value.MinRva;
          E.UnitKey := KV.Key;
          Sections.Add(E);
        end;
      Sections.Sort(TComparer<TRvaSectionEntry>.Construct(
        function(const A, B: TRvaSectionEntry): Integer
        begin
          if A.MinRva < B.MinRva then Result := -1
          else if A.MinRva > B.MinRva then Result := 1
          else Result := 0;
        end));
      DapLog(Format('[MAP] Sidecar fast-path: %d units loaded', [FUnitSections.Count]));
      FLock.Acquire;
      try
        FSectionsByRva := Sections.ToArray;
        FIndexReady    := True;
      finally
        FLock.Release;
      end;
    finally
      Sections.Free;
    end;
    // Still need to parse Publics (not stored in sidecar -- too large).
    var PubOff: Int64;
    FLock.Acquire;
    try
      PubOff := FPublicsDataOff;
    finally
      FLock.Release;
    end;
    if PubOff > 0 then
      ParsePublicsAt(PubOff);
    FLock.Acquire;
    try
      FPubsReady := True;
    finally
      FLock.Release;
    end;
    Exit;
  end;

  // Slow path: full sequential scan.
  PBase := FMapData;
  P     := FMapData;
  PEnd  := FMapData + FMapSize;
  Sections := TList<TRvaSectionEntry>.Create;
  try
    while ScanLine(P, PEnd, Line) do begin
      var Trimmed := Line.Trim;

      if Trimmed.StartsWith('Line numbers for ') then begin
        // Extract source filename from "Line numbers for UnitX(path\UnitX.pas) segment .text"
        var P1 := Trimmed.IndexOf('(');
        var P2 := Trimmed.LastIndexOf(')');
        if (P1 < 0) or (P2 <= P1) then Continue;
        var UnitPath := Trimmed.Substring(P1 + 1, P2 - P1 - 1);
        var UnitKey  := UpperCase(ExtractFileName(UnitPath));

        // Skip optional blank line between header and first data line.
        begin
          var PeekP := P;
          var PeekLine: string;
          if ScanLine(PeekP, PEnd, PeekLine) and (PeekLine.Trim = '') then
            P := PeekP;
        end;

        var DataOffset := Int64(P - PBase);

        // Read first data line to get MinRva for range-based lookup.
        var MinRva: UInt64 := 0;
        var SaveP := P;
        var FirstDataLine: string;
        if ScanLine(P, PEnd, FirstDataLine) then begin
          var Tokens := FirstDataLine.Trim.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
          if Length(Tokens) >= 2 then begin
            var RvaToken := Tokens[1];
            var ColonPos := RvaToken.IndexOf(':');
            if ColonPos >= 1 then begin
              var SegNum  := StrToIntDef('$' + RvaToken.Substring(0, ColonPos), 0);
              var Offset: UInt64 := StrToInt64Def('$' + RvaToken.Substring(ColonPos + 1), 0);
              if Offset > 0 then begin
                var BaseRva: UInt64 := 0;
                FSegmentBaseRvas.TryGetValue(SegNum, BaseRva);
                MinRva := BaseRva + Offset;
              end;
            end;
          end;
        end;
        P := SaveP; // rewind so ParseUnitSectionAt re-reads from DataOffset

        var Info: TUnitSectionInfo;
        Info.DataOffset := DataOffset;
        Info.MinRva     := MinRva;
        Info.FullPath   := UnitPath;

        // No lock: background is the sole writer of FUnitSections; foreground
        // only reads after FIndexReady is set (end of this procedure).
        if not FUnitSections.ContainsKey(UnitKey) then
          FUnitSections.Add(UnitKey, Info);

        if MinRva > 0 then begin
          var Entry: TRvaSectionEntry;
          Entry.MinRva  := MinRva;
          Entry.UnitKey := UnitKey;
          Sections.Add(Entry);
        end;

        Continue;
      end;

      if (FPublicsDataOff = 0) and Trimmed.Contains('Publics by Value') then begin
        // Skip the blank line following the header if present.
        var PeekP := P;
        var PeekLine: string;
        if ScanLine(PeekP, PEnd, PeekLine) and (PeekLine.Trim = '') then
          P := PeekP;
        FPublicsDataOff := Int64(P - PBase);
        // Do NOT break -- in some MAP files (e.g. large DevExpress projects),
        // the Publics section comes before the Line numbers sections.
        // We must scan to EOF to find all units.
      end;
    end;

    // Sort section-range entries by MinRva and publish.
    Sections.Sort(TComparer<TRvaSectionEntry>.Construct(
      function(const A, B: TRvaSectionEntry): Integer
      begin
        if A.MinRva < B.MinRva then Result := -1
        else if A.MinRva > B.MinRva then Result := 1
        else Result := 0;
      end));

    DapLog(Format('[MAP] Slow scan done: %d units, pubOff=$%x segBases=%d',
      [FUnitSections.Count, FPublicsDataOff, FSegmentBaseRvas.Count]));
    FLock.Acquire;
    try
      FSectionsByRva := Sections.ToArray;
      FIndexReady    := True;
    finally
      FLock.Release;
    end;
  finally
    Sections.Free;
  end;

  if FOutputRvaShift = 0 then
    SaveUnitIndexToSidecar(SidecarPath);

  // Parse Publics section (fills FRvaToPubName / FInnerToParent).
  var PubOff: Int64;
  FLock.Acquire;
  try
    PubOff := FPublicsDataOff;
  finally
    FLock.Release;
  end;
  if PubOff > 0 then
    ParsePublicsAt(PubOff);

  FLock.Acquire;
  try
    FPubsReady := True;
  finally
    FLock.Release;
  end;
end;

{ --------------------------------------------------------------------------- }
{  On-demand unit section parse                                                }
{ --------------------------------------------------------------------------- }

procedure TMapFile.ParseUnitSectionAt(const UnitKey, FullPath: string; DataOffset: Int64);
// Reads line-number pairs from the mmap starting at DataOffset until a blank
// line or a new section header is found. Inserts into FRvaToLoc / FLineToRva.
var
  P, PEnd: PByte;
  Line: string;
  SourceFile: string;
begin
  // Prefer the full path (from MAP header) so VS Code can open the file directly.
  // Fall back to the uppercase basename key if no path was stored.
  SourceFile := IfThen(FullPath <> '', FullPath, UnitKey);
  P    := FMapData + DataOffset;
  PEnd := FMapData + FMapSize;

  while ScanLine(P, PEnd, Line) do begin
    var DataLine := Line.Trim;
    if DataLine = '' then Break;
    if DataLine.StartsWith('Line numbers') or DataLine.StartsWith('Bound') or
       DataLine.Contains('Publics by Value') then Break;

    var Tokens := DataLine.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    var T := 0;
    while T + 1 < Length(Tokens) do begin
      var LineNum := StrToIntDef(Tokens[T], 0);
      var RvaStr  := Tokens[T + 1];
      Inc(T, 2);
      if LineNum <= 0 then Continue;

      var Rva: UInt64;
      if not SegmentRvaFromToken(RvaStr, Rva) then Continue;

      var Loc: TSourceLocation;
      Loc.SourceFile := SourceFile;
      Loc.Line       := LineNum;
      if not FRvaToLoc.ContainsKey(Rva) then
        FRvaToLoc.Add(Rva, Loc);

      var Key := LineKey(SourceFile, LineNum);
      if not FLineToRva.ContainsKey(Key) then
        FLineToRva.Add(Key, Rva);
    end;
  end;
end;

{ --------------------------------------------------------------------------- }
{  Publics section                                                             }
{ --------------------------------------------------------------------------- }

procedure TMapFile.ParsePublicsAt(DataOffset: Int64);
type
  TPubRecord = record
    Rva:  UInt64;
    Full: string;  // original `Unit.Name[.Class.Method...]`
    Stripped: string;  // first-segment-stripped, used for short display
    IsData: Boolean;   // lives in a DATA/BSS/TLS segment (global variable)
  end;
var
  P, PEnd: PByte;
  Line: string;
  UnitInnerToParent: TDictionary<string, string>;
  Pubs:              TList<TPubRecord>;
begin
  P    := FMapData + DataOffset;
  PEnd := FMapData + FMapSize;
  UnitInnerToParent := TDictionary<string, string>.Create;
  Pubs              := TList<TPubRecord>.Create;
  try
    while ScanLine(P, PEnd, Line) do begin
      var Trimmed := Line.Trim;
      if Trimmed.StartsWith('Bound resource files') or
         Trimmed.StartsWith('Line numbers') or
         Trimmed.StartsWith('Segment') then Break;
      if Trimmed = '' then Continue;

      var Tokens := Trimmed.Split([' ', #9], 2, TStringSplitOptions.ExcludeEmpty);
      if Length(Tokens) < 2 then Continue;
      var AddrToken := Tokens[0];
      var SymName   := Tokens[1].Trim;

      if SymName.Contains('$') then begin
        var ZIdx := SymName.IndexOf('_ZZ');
        if ZIdx >= 0 then begin
          var Inner, Parent, NestUnit: string;
          if ParseDelphiNestedMangled(SymName.Substring(ZIdx), Inner, Parent, NestUnit) then begin
            // Legacy short-name fallback: only used when RvaToParent lookup
            // misses (older callers / non-_ZZ-coupled procs).
            FInnerToParent.AddOrSetValue(LowerCase(Inner), Parent);
            if NestUnit <> '' then
              UnitInnerToParent.AddOrSetValue(LowerCase(NestUnit + '.' + Inner), Parent);
          end;
        end;
        // `$pdata$` / `$unwind$` are exception metadata (PDATA/XDATA), not code --
        // skip them. But other `$` names ARE legitimate code publics: closure bodies
        // (`...$ActRec.$0$Body`), VMTs, thunks. Those MUST be indexed so an
        // anonymous-method frame resolves to its own function instead of clamping to
        // a neighbouring proc (increment B: closure body frame/line resolution).
        if SymName.Contains('$pdata$') or SymName.Contains('$unwind$') then
          Continue;
      end;

      var Rva: UInt64;
      if not SegmentRvaFromToken(AddrToken, Rva) then Continue;

      var SegColon := AddrToken.IndexOf(':');
      var PubSeg := -1;
      if SegColon > 0 then
        PubSeg := StrToIntDef('$' + AddrToken.Substring(0, SegColon), -1);

      var DotPos := SymName.IndexOf('.');
      var Stripped := SymName;
      if DotPos >= 0 then
        Stripped := SymName.Substring(DotPos + 1);

      var Rec: TPubRecord;
      Rec.Rva      := Rva;
      Rec.Full     := SymName;
      Rec.Stripped := Stripped;
      Rec.IsData   := (PubSeg > 0) and FDataSegments.ContainsKey(PubSeg);
      Pubs.Add(Rec);
    end;

    // Map full `Unit.Qualified` public name -> RVA, so a parent proc can
    // be resolved to its body RVA within the SAME unit (no cross-unit
    // bare-name collision).
    var FullToRva := TDictionary<string, UInt64>.Create;
    try
      for var Rec in Pubs do
        FullToRva.AddOrSetValue(LowerCase(Rec.Full), Rec.Rva);

      // Drain into the dicts. Per-RVA parent association happens here
      // because it needs BOTH the regular public's Unit.Name AND the
      // _ZZ-mangled Unit/Inner correlate from the first pass.
      for var Rec in Pubs do begin
        if not FRvaToPubName.ContainsKey(Rec.Rva) then
          FRvaToPubName.Add(Rec.Rva, Rec.Stripped);
        if Rec.IsData and not FDataRvas.ContainsKey(Rec.Rva) then
          FDataRvas.Add(Rec.Rva, True);
        var Parent: string;
        if UnitInnerToParent.TryGetValue(LowerCase(Rec.Full), Parent) and
           not FRvaToParent.ContainsKey(Rec.Rva) then begin
          FRvaToParent.Add(Rec.Rva, Parent);
          // Resolve the parent's body RVA in the child's OWN unit:
          // childUnit + '.' + last-segment(Parent). Parent may be
          // `EnclosingProc.Mid` -- the public is `Unit.Mid`.
          var UnitDot := Rec.Full.IndexOf('.');
          if UnitDot > 0 then begin
            var UnitName := Rec.Full.Substring(0, UnitDot);
            var PLastDot := Parent.LastIndexOf('.');
            var PLeaf := Parent;
            if PLastDot >= 0 then PLeaf := Parent.Substring(PLastDot + 1);
            var ParentRva: UInt64;
            if FullToRva.TryGetValue(LowerCase(UnitName + '.' + PLeaf), ParentRva) and
               not FRvaToParentRva.ContainsKey(Rec.Rva) then
              FRvaToParentRva.Add(Rec.Rva, ParentRva);
          end;
        end;
      end;
    finally
      FullToRva.Free;
    end;
  finally
    UnitInnerToParent.Free;
    Pubs.Free;
  end;

  var SortedPubs := FRvaToPubName.Keys.ToArray;
  TArray.Sort<UInt64>(SortedPubs);
  FLock.Acquire;
  try
    FSortedPubRvas := SortedPubs;
  finally
    FLock.Release;
  end;
end;

{ --------------------------------------------------------------------------- }
{  Wait helpers                                                                }
{ --------------------------------------------------------------------------- }

procedure TMapFile.WaitForIndex;
begin
  // Never block the DAP loop for long while the background indexer scans a
  // very large MAP. If the index isn't ready yet, callers retry naturally
  // (reposted breakpoints, later lookups) once the worker completes.
  var Deadline := GetTickCount64 + 50; // short responsiveness budget
  while True do begin
    FLock.Acquire;
    try
      if FIndexReady then Exit;
    finally
      FLock.Release;
    end;
    if GetTickCount64 > Deadline then Exit;
    Sleep(1);
  end;
end;

procedure TMapFile.WaitForPubs;
begin
  // Name/public lookup should degrade gracefully while the background parser
  // is still building the publics table.
  var Deadline := GetTickCount64 + 50;
  while True do begin
    FLock.Acquire;
    try
      if FPubsReady then Exit;
    finally
      FLock.Release;
    end;
    if GetTickCount64 > Deadline then Exit;
    Sleep(1);
  end;
end;

function TMapFile.BackgroundIndexingPending: Boolean;
begin
  FLock.Acquire;
  try
    Result := not FPubsReady;
  finally
    FLock.Release;
  end;
end;

{ --------------------------------------------------------------------------- }
{  Per-unit load                                                               }
{ --------------------------------------------------------------------------- }

procedure TMapFile.RebuildSortedRvas;
begin
  FSortedRvas := FRvaToLoc.Keys.ToArray;
  TArray.Sort<UInt64>(FSortedRvas);
end;

procedure TMapFile.EnsureUnitByKey(const UnitKey: string);
begin
  if FLoadedUnits.ContainsKey(UnitKey) then Exit;
  FLoadedUnits.Add(UnitKey, True);

  var Info: TUnitSectionInfo;
  FLock.Acquire;
  try
    if not FUnitSections.TryGetValue(UnitKey, Info) then begin
      DapLog(Format('[MAP] EnsureUnit MISS key="%s" totalUnits=%d',
        [UnitKey, FUnitSections.Count]));
      Exit;
    end;
  finally
    FLock.Release;
  end;

  var LinesBefore := FLineToRva.Count;
  ParseUnitSectionAt(UnitKey, Info.FullPath, Info.DataOffset);
  DapLog(Format('[MAP] EnsureUnit OK key="%s" off=$%x lines+=%d',
    [UnitKey, Info.DataOffset, FLineToRva.Count - LinesBefore]));
  RebuildSortedRvas;
end;

function TMapFile.FindUnitKeyForRva(Rva: UInt64): string;
// Binary-search FSectionsByRva for the largest MinRva <= Rva.
var
  Arr: TArray<TRvaSectionEntry>;
  Lo, Hi, Mid, Best: Integer;
begin
  Result := '';
  FLock.Acquire;
  try
    Arr := FSectionsByRva;
  finally
    FLock.Release;
  end;
  if Length(Arr) = 0 then Exit;
  Lo   := 0;
  Hi   := High(Arr);
  Best := -1;
  while Lo <= Hi do begin
    Mid := (Lo + Hi) div 2;
    if Arr[Mid].MinRva <= Rva then begin
      Best := Mid;
      Lo   := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if Best >= 0 then
    Result := Arr[Best].UnitKey;
end;

procedure TMapFile.EnsureUnitForRva(Rva: UInt64);
begin
  WaitForIndex;
  var UnitKey := FindUnitKeyForRva(Rva);
  if UnitKey <> '' then
    EnsureUnitByKey(UnitKey);
end;

procedure TMapFile.EnsureUnitForFile(const FileName: string);
begin
  WaitForIndex;
  EnsureUnitByKey(UpperCase(ExtractFileName(FileName)));
end;

{ --------------------------------------------------------------------------- }
{  Helper functions                                                            }
{ --------------------------------------------------------------------------- }

function TMapFile.LineKey(const FileName: string; Line: Integer): string;
begin
  Result := UpperCase(ExtractFileName(FileName)) + ':' + IntToStr(Line);
end;

function TMapFile.RvaIsInImage(Rva: UInt64): Boolean;
// Bound queries to THIS module's address window. The real SizeOfImage is used
// when the module loader supplied it; otherwise a generous 1 GB span. The blanket
// 1 GB window let an Rva belonging to an entirely different (unknown / stripped)
// module fall inside a loaded module's range, and the nearest-preceding-public
// search then labelled that address with this module's last public -- a stack
// frame confidently named after the wrong binary. Subtracting rather than adding
// also avoids overflowing when the shift is large.
const
  MaxImageSize = UInt64($40000000); // 1 GB -- fallback when the real size is unknown
begin
  Result := False;
  if Rva < FOutputRvaShift then Exit;
  var Span := FImageSize;
  if Span = 0 then
    Span := MaxImageSize;
  Result := (Rva - FOutputRvaShift) < Span;
end;

function TMapFile.PublicCanContain(PubRva, Rva: UInt64): Boolean;
const
  // No Delphi routine approaches this; a larger gap means Rva sits in a region
  // this MAP has no symbol for (padding, a stripped routine, another segment).
  MAX_FUNC_SPAN = UInt64($40000);   // 256 KB
begin
  Result := False;
  if Rva < PubRva then Exit;
  // A DATA public (global / constant table) is never the function containing a
  // code address. FDataRvas is already built while parsing Publics.
  FLock.Acquire;
  try
    if FDataRvas.ContainsKey(PubRva) then Exit;
  finally
    FLock.Release;
  end;
  Result := (Rva - PubRva) < MAX_FUNC_SPAN;
end;

function TMapFile.SegmentRvaFromToken(const Token: string; out Rva: UInt64): Boolean;
var
  ColonPos, SegNum: Integer;
  BaseRva, Offset: UInt64;
begin
  Result   := False;
  ColonPos := Token.IndexOf(':');
  if ColonPos < 1 then Exit;
  SegNum  := StrToIntDef('$' + Token.Substring(0, ColonPos), 0);
  BaseRva := 0;
  FSegmentBaseRvas.TryGetValue(SegNum, BaseRva);
  Offset := StrToInt64Def('$' + Token.Substring(ColonPos + 1), 0);
  if Offset = 0 then Exit;
  Rva    := BaseRva + Offset;
  Result := True;
end;

{ --------------------------------------------------------------------------- }
{  Public API                                                                  }
{ --------------------------------------------------------------------------- }

function TMapFile.RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;

  function BinarySearchNearest: Boolean;
  var
    Lo, Hi, Mid, Best: Integer;
  begin
    Result := False;
    if Length(FSortedRvas) = 0 then Exit;
    Lo   := 0;
    Hi   := High(FSortedRvas);
    Best := -1;
    while Lo <= Hi do begin
      Mid := (Lo + Hi) div 2;
      if FSortedRvas[Mid] <= Rva then begin
        Best := Mid;
        Lo   := Mid + 1;
      end else
        Hi := Mid - 1;
    end;
    if Best < 0 then Exit;
    if Rva - FSortedRvas[Best] > 512 then Exit;
    Result := FRvaToLoc.TryGetValue(FSortedRvas[Best], Loc);
  end;

begin
  Result := False;
  if not RvaIsInImage(Rva) then Exit;
  // Fast path: check already-loaded data.
  if BinarySearchNearest then Exit(True);

  // Slow path: find owning unit, load it, retry.
  EnsureUnitForRva(Rva);
  Result := BinarySearchNearest;
end;

function TMapFile.SourceLineToRva(const FileName: string; Line: Integer;
  out Rva: UInt64): Boolean;
begin
  EnsureUnitForFile(FileName);
  var Key := LineKey(FileName, Line);
  Result := FLineToRva.TryGetValue(Key, Rva);
  if not Result then
    DapLog(Format('[MAP] SourceLineToRva MISS file="%s" line=%d key="%s" totalLines=%d',
      [FileName, Line, Key, FLineToRva.Count]));
end;

function TMapFile.RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
var
  Arr: TArray<UInt64>;
  Lo, Hi, Mid, Best: Integer;
begin
  Result := False;
  // Non-blocking: if Publics not ready yet, return False rather than stalling
  // the DAP dispatch thread while the background thread parses the large Publics section.
  FLock.Acquire;
  try
    if not FPubsReady then Exit;
  finally
    FLock.Release;
  end;
  // Quick bounds check: reject Rvas clearly outside this image's range.
  // Without it, an EXE-MAP would return its nearest public for any Rva in a
  // BPL's address space (which sorts after every EXE public).
  if not RvaIsInImage(Rva) then
    Exit;
  FLock.Acquire;
  try
    Arr := FSortedPubRvas;
  finally
    FLock.Release;
  end;
  if Length(Arr) = 0 then Exit;
  Lo   := 0;
  Hi   := High(Arr);
  Best := -1;
  while Lo <= Hi do begin
    Mid := (Lo + Hi) div 2;
    if Arr[Mid] <= Rva then begin
      Best := Mid;
      Lo   := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if Best < 0 then Exit;
  // The nearest PRECEDING public is the containing function only when Rva
  // plausibly lies inside it (see PublicCanContain). Without this an address in a
  // gap / stripped routine took the name of a data symbol or a far-away routine.
  if not PublicCanContain(Arr[Best], Rva) then Exit;
  FLock.Acquire;
  try
    Result := FRvaToPubName.TryGetValue(Arr[Best], Name);
  finally
    FLock.Release;
  end;
end;

function TMapFile.RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
var
  Arr: TArray<UInt64>;
  Lo, Hi, Mid, Best: Integer;
begin
  Result  := False;
  FuncRva := 0;
  if not RvaIsInImage(Rva) then Exit;
  FLock.Acquire;
  try
    if not FPubsReady then Exit;
  finally
    FLock.Release;
  end;
  FLock.Acquire;
  try
    Arr := FSortedPubRvas;
  finally
    FLock.Release;
  end;
  if Length(Arr) = 0 then Exit;
  Lo   := 0;
  Hi   := High(Arr);
  Best := -1;
  while Lo <= Hi do begin
    Mid := (Lo + Hi) div 2;
    if Arr[Mid] <= Rva then begin
      Best := Mid;
      Lo   := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if Best < 0 then Exit;
  if not PublicCanContain(Arr[Best], Rva) then Exit;
  FuncRva := Arr[Best];
  Result  := True;
end;

// Last two dotted segments of a symbol name, lowercased: the `Class.Method`
// pair. `Forms.TApplication.GetMainFormHandle` -> `tapplication.getmainformhandle`.
// A name with fewer than two dots returns its whole (lowercased) self.
function MapLastTwoSegments(const S: string): string;
begin
  var P1 := S.LastIndexOf('.');
  if P1 < 0 then Exit(S.ToLower);
  var P2 := S.LastIndexOf('.', P1 - 1);
  Result := S.Substring(P2 + 1).ToLower; // P2 = -1 -> Substring(0) = whole
end;

procedure TMapFile.BuildPubReverseIndex;
begin
  // Caller holds FLock. Mirrors the three match modes of the former linear
  // NameToRva: full-name exact, last-segment exact, and the unqualified
  // suffix fallback. "First hit wins" is preserved with ContainsKey guards
  // (the old code's first hit over an unordered dict was itself arbitrary).
  if FPubReverseReady then Exit;
  for var KV in FRvaToPubName do begin
    var LowerFull := KV.Value.ToLower;
    if not FPubNameLowerToRva.ContainsKey(LowerFull) then
      FPubNameLowerToRva.Add(LowerFull, KV.Key);
    var DotPos := KV.Value.LastIndexOf('.');
    var Tail := KV.Value;
    if DotPos >= 0 then
      Tail := KV.Value.Substring(DotPos + 1);
    var LowerTail := Tail.ToLower;
    if not FPubTailLowerToRva.ContainsKey(LowerTail) then
      FPubTailLowerToRva.Add(LowerTail, KV.Key);
    if FDataRvas.ContainsKey(KV.Key) and
       not FPubDataTailLowerToRva.ContainsKey(LowerTail) then
      FPubDataTailLowerToRva.Add(LowerTail, KV.Key);
    if DotPos >= 0 then begin
      var ClassMethod := MapLastTwoSegments(KV.Value);
      if not FPubClassMethodLowerToRva.ContainsKey(ClassMethod) then
        FPubClassMethodLowerToRva.Add(ClassMethod, KV.Key);
    end;
  end;
  FPubReverseReady := True;
end;

function TMapFile.NameToRva(const Name: string; out Rva: UInt64): Boolean;
begin
  Rva := 0;
  WaitForPubs;
  FLock.Acquire;
  try
    BuildPubReverseIndex;
    // Exact match first.
    if FPubNameLowerToRva.TryGetValue(Name.ToLower, Rva) then
      Exit(True);
    if not Name.Contains('.') then begin
      // Suffix match: callers pass `Now`, the MAP has `System.SysUtils.Now`.
      // Only for unqualified names so already-qualified names aren't fuzzed.
      // The tail index keys publics by their last dotted segment; the prior
      // dotted-suffix semantics (`pub endsWith '.Name'`) reduce to
      // last-segment == Name, since exact (dotless) hits were taken above.
      // Prefer a DATA-segment symbol: a bare identifier is a global variable
      // far more often than a free procedure, so `Application` must resolve
      // to `Vcl.Forms.Application` (data) rather than an identically-tailed
      // method in some unit.
      if FPubDataTailLowerToRva.TryGetValue(Name.ToLower, Rva) then
        Exit(True);
      if FPubTailLowerToRva.TryGetValue(Name.ToLower, Rva) then
        Exit(True);
    end else begin
      // Qualified miss: match by the `Class.Method` pair. The MAP qualifies
      // methods with the unit but without the dotted namespace
      // (`Forms.TApplication.GetMainFormHandle`), so a `TApplication.GetX`
      // getter lookup matches the pair while ignoring the unit prefix -- and
      // does so PRECISELY, unlike the bare last segment which collides across
      // classes (TApplication.GetHintControl vs TcxControlHintHelper.GetHintControl).
      if FPubClassMethodLowerToRva.TryGetValue(MapLastTwoSegments(Name), Rva) then
        Exit(True);
      // Last resort: the last segment as a full name. Used by the parent walk
      // on multi-level nested procs (`RunDeepNesting.Mid` -> MAP stores `Mid`).
      var DotPos := Name.LastIndexOf('.');
      if DotPos >= 0 then begin
        var Tail := Name.Substring(DotPos + 1);
        if FPubNameLowerToRva.TryGetValue(Tail.ToLower, Rva) then
          Exit(True);
      end;
    end;
  finally
    FLock.Release;
  end;
  Result := False;
end;

function TMapFile.FirstUserRva: UInt64;
begin
  Result := 0;
  WaitForIndex;
  // Load at least the first section so FSortedRvas is not empty.
  var FirstKey := '';
  FLock.Acquire;
  try
    if Length(FSectionsByRva) > 0 then
      FirstKey := FSectionsByRva[0].UnitKey;
  finally
    FLock.Release;
  end;
  if FirstKey <> '' then
    EnsureUnitByKey(FirstKey);
  if Length(FSortedRvas) > 0 then
    Result := FSortedRvas[0];
end;

function TMapFile.SortedRvas: TArray<UInt64>;
begin
  Result := FSortedRvas;
end;

function TMapFile.GetEnclosingProcedure(const Inner: string;
  out Parent: string): Boolean;
begin
  WaitForPubs;
  FLock.Acquire;
  try
    Result := FInnerToParent.TryGetValue(LowerCase(Inner), Parent);
  finally
    FLock.Release;
  end;
end;

function TMapFile.GetEnclosingProcedureByRva(InnerRva: UInt64;
  out Parent: string): Boolean;
begin
  WaitForPubs;
  FLock.Acquire;
  try
    Result := FRvaToParent.TryGetValue(InnerRva, Parent);
  finally
    FLock.Release;
  end;
end;

function TMapFile.GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
  out ParentRva: UInt64): Boolean;
begin
  WaitForPubs;
  FLock.Acquire;
  try
    Result := FRvaToParentRva.TryGetValue(InnerRva, ParentRva);
  finally
    FLock.Release;
  end;
end;

end.
