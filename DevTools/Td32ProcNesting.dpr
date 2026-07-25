program Td32ProcNesting;

// Answers one question about any PE that carries embedded TD32 debug info:
// does the TD32 symbol stream express nested (inner) procedures as a LEXICAL
// SCOPE -- an LPROC32/GPROC32 record opened while another proc scope is still
// open -- and/or through the CodeView `pParent` back-pointer?
//
// This is the architecture-neutral alternative to the MAP-based mechanism,
// which recovers nesting by correlating `_ZZ...$pdata$...` mangled exception
// publics and therefore only works where the compiler emits .pdata (x64).
//
// The probe SEARCHES: it walks every symbol stream keeping a scope stack and
// reports, per procedure record, the depth, the enclosing procedure implied by
// the stack, and the raw `pParent` field. It asserts nothing.
//
// Usage:
//   Td32ProcNesting.exe <pe-path> [name-substring]
//
// With no filter it prints only the aggregate counts. With a filter it also
// prints every procedure whose (raw) name contains the substring, with the
// parent derived from the scope stack.
//
// Works on PE32 and PE32+ images regardless of the bitness of this probe
// itself: nothing in the TD32 container is pointer-sized.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Math;

const
  TD32_SIGNATURE     = $39304246;   // 'FB09'
  SST_ALIGN_SYMBOLS  = $125;
  SST_GLOBAL_SYMBOLS = $129;
  SST_NAMES          = $130;
  S_END              = $0006;
  S_LPROC32          = $0204;
  S_GPROC32          = $0205;
  S_BLOCK32          = $0207;

type
  TDirEntry = record
    SubType:  Word;
    ModIndex: Word;
    Offset:   Cardinal;
    Size:     Cardinal;
  end;

  TProcInfo = record
    Name:       string;
    ParentName: string;   // from the scope stack, '' when top level
    Depth:      Integer;  // 0 = top level
    Rva:        UInt64;
    PParent:    Cardinal; // raw CodeView pParent field at payload+0
    IsGlobal:   Boolean;
    // Byte offset of this record measured from two candidate origins, so the
    // pParent field can be matched against whichever the compiler used.
    OffFromStream: Cardinal;  // from the first record (subsection base + hdr)
    OffFromSubsec: Cardinal;  // from the subsection base
    ParentByPParent: string;  // name of the record pParent points at, if any
    Head: string;             // hex of payload bytes 0..11 (pParent/pEnd/pNext)
  end;

var
  GFile:       TBytes;
  GBase:       PByte;
  GSize:       Int64;
  GDebugBase:  PByte;
  GDebugEnd:   PByte;
  GDebugSize:  Cardinal;
  GTd32Base:   PByte;
  GSectionRvas: TArray<Cardinal>;
  GDirEntries: TArray<TDirEntry>;
  GNames:      TArray<string>;
  GProcs:      TArray<TProcInfo>;
  GMaxDepth:   Integer;
  GHitsFromStream: Integer;   // pParent measured from the first symbol record
  GHitsFromSubsec: Integer;   // pParent measured from the subsection header

procedure Fail(const Msg: string);
begin
  Writeln('ERROR: ', Msg);
  Halt(1);
end;

procedure LoadFile(const Path: string);
begin
  var Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    GSize := Stream.Size;
    SetLength(GFile, GSize);
    if GSize > 0 then
      Stream.ReadBuffer(GFile[0], GSize);
  finally
    Stream.Free;
  end;
  GBase := PByte(GFile);
end;

function FindDebugSection: Boolean;
begin
  Result := False;
  if GSize < 64 then Exit;
  if (GBase[0] <> Ord('M')) or (GBase[1] <> Ord('Z')) then Exit;
  var PeOff: Cardinal := PCardinal(GBase + $3C)^;
  if PeOff + 24 >= GSize then Exit;
  if (GBase[PeOff] <> Ord('P')) or (GBase[PeOff + 1] <> Ord('E')) then Exit;
  var NumSections: Word := PWord(GBase + PeOff + 6)^;
  var OptSize:     Word := PWord(GBase + PeOff + 20)^;
  var SectTbl := PeOff + 24 + OptSize;
  for var I := 0 to NumSections - 1 do begin
    var Hdr := SectTbl + Cardinal(I) * 40;
    var SecName: AnsiString;
    SetString(SecName, PAnsiChar(GBase + Hdr), 8);
    var Z := Pos(AnsiChar(#0), SecName);
    if Z > 0 then
      SecName := Copy(SecName, 1, Z - 1);
    GSectionRvas := GSectionRvas + [PCardinal(GBase + Hdr + 12)^];
    if string(SecName) <> '.debug' then Continue;
    var RawSize: Cardinal := PCardinal(GBase + Hdr + 16)^;
    var RawOff:  Cardinal := PCardinal(GBase + Hdr + 20)^;
    if (RawOff = 0) or (Int64(RawOff) + RawSize > GSize) then Exit;
    GDebugSize := RawSize;
    GDebugBase := GBase + RawOff;
    GDebugEnd  := GDebugBase + RawSize;
    Result     := True;
  end;
end;

function FindTd32Base: Boolean;
begin
  Result := False;
  if (GDebugBase = nil) or (GDebugSize < 16) then Exit;
  var Trailer := GDebugBase + GDebugSize - 8;
  if PCardinal(Trailer)^ = TD32_SIGNATURE then begin
    var OffBack: Cardinal := PCardinal(Trailer + 4)^;
    if (OffBack > 0) and (OffBack <= GDebugSize) then begin
      var Candidate := GDebugBase + GDebugSize - OffBack;
      if PCardinal(Candidate)^ = TD32_SIGNATURE then begin
        GTd32Base := Candidate;
        Exit(True);
      end;
    end;
  end;
  var Limit := Min(Int64(256), Int64(GDebugSize) - 4);
  for var I: Int64 := 0 to Limit do
    if PCardinal(GDebugBase + I)^ = TD32_SIGNATURE then begin
      GTd32Base := GDebugBase + I;
      Exit(True);
    end;
end;

function ReadDirectory: Boolean;
const
  MAX_BLOCKS = 16;
begin
  Result := False;
  if GTd32Base = nil then Exit;
  var Rel: Cardinal := PCardinal(GTd32Base + 4)^;
  for var Block := 0 to MAX_BLOCKS - 1 do begin
    var Abs_ := GTd32Base + Rel;
    if (Abs_ < GDebugBase) or (Abs_ + 16 > GDebugEnd) then Exit;
    var HeaderSize: Word     := PWord(Abs_)^;
    var EntrySize:  Word     := PWord(Abs_ + 2)^;
    var Count:      Cardinal := PCardinal(Abs_ + 4)^;
    var Next:       Cardinal := PCardinal(Abs_ + 8)^;
    if (HeaderSize < 16) or (EntrySize < 12) or (Count > 1000000) then Exit;
    var EntryStart := Abs_ + HeaderSize;
    if EntryStart + Int64(Count) * EntrySize > GDebugEnd then Exit;
    var StartIdx := Length(GDirEntries);
    SetLength(GDirEntries, StartIdx + Integer(Count));
    for var I := 0 to Integer(Count) - 1 do begin
      var P := EntryStart + I * EntrySize;
      GDirEntries[StartIdx + I].SubType  := PWord(P)^;
      GDirEntries[StartIdx + I].ModIndex := PWord(P + 2)^;
      GDirEntries[StartIdx + I].Offset   := PCardinal(P + 4)^;
      GDirEntries[StartIdx + I].Size     := PCardinal(P + 8)^;
    end;
    if Next = 0 then Break;
    Rel := Next;
  end;
  Result := Length(GDirEntries) > 0;
end;

procedure BuildNamesIndex;
begin
  var NamesBase: PByte := nil;
  var NamesSize: Cardinal := 0;
  var NamesCount: Cardinal := 0;
  for var E in GDirEntries do
    if E.SubType = SST_NAMES then begin
      var P := GTd32Base + E.Offset;
      if (P < GDebugBase) or (P + E.Size > GDebugEnd) or (E.Size < 4) then Exit;
      NamesCount := PCardinal(P)^;
      NamesBase  := P + 4;
      NamesSize  := E.Size - 4;
      Break;
    end;
  if NamesBase = nil then Exit;
  SetLength(GNames, NamesCount + 1);
  var P := NamesBase;
  var Stop := NamesBase + NamesSize;
  var I: Cardinal := 1;
  while (P < Stop) and (I <= NamesCount) do begin
    var L := P^;
    Inc(P);
    var Start := P;
    Inc(P, L);
    while (P < Stop) and (P^ <> 0) do
      Inc(P, 256);
    var ActualLen: Int64 := P - Start;
    if (Start < Stop) and (ActualLen > 0) and (ActualLen < NamesSize) then begin
      var A: AnsiString;
      SetString(A, PAnsiChar(Start), ActualLen);
      GNames[I] := string(A);
    end;
    Inc(P);
    Inc(I);
  end;
end;

function NameByIndex(Idx: Cardinal): string;
begin
  Result := '';
  if (Idx >= 1) and (Idx < Cardinal(Length(GNames))) then
    Result := GNames[Idx];
end;

function SegOffsetToRva(Seg: Word; Offs: Cardinal): UInt64;
begin
  Result := 0;
  if (Seg = 0) or (Seg > Cardinal(Length(GSectionRvas))) then Exit;
  Result := UInt64(Offs + GSectionRvas[Seg - 1]);
end;

procedure WalkSymbolStream(SubsecBase, Base, Stop: PByte);
var
  ScopeNames: TArray<string>;
  IsProcScope: TArray<Boolean>;
  StreamProcs: TArray<TProcInfo>;

  // The enclosing PROCEDURE is the nearest proc-kind entry on the stack; a
  // BLOCK32 level must not be mistaken for one.
  function EnclosingProc: string;
  begin
    Result := '';
    for var I := High(ScopeNames) downto 0 do
      if IsProcScope[I] then
        Exit(ScopeNames[I]);
  end;

  procedure Push(const AName: string; AIsProc: Boolean);
  begin
    ScopeNames  := ScopeNames  + [AName];
    IsProcScope := IsProcScope + [AIsProc];
  end;

  procedure Pop;
  begin
    if Length(ScopeNames) = 0 then Exit;
    SetLength(ScopeNames,  Length(ScopeNames)  - 1);
    SetLength(IsProcScope, Length(IsProcScope) - 1);
  end;

  function ProcDepth: Integer;
  begin
    Result := 0;
    for var I := 0 to High(IsProcScope) do
      if IsProcScope[I] then
        Inc(Result);
  end;

begin
  var Cur := Base;
  while Cur + 4 <= Stop do begin
    var RecSize: Word := PWord(Cur)^;
    var Kind:    Word := PWord(Cur + 2)^;
    if (RecSize < 2) or (Cur + 2 + Int64(RecSize) > Stop) then Break;
    var Payload    := Cur + 4;
    var PayloadEnd := Cur + 2 + Int64(RecSize);
    case Kind of
      S_LPROC32, S_GPROC32: begin
        var Info: TProcInfo;
        Info.IsGlobal   := Kind = S_GPROC32;
        Info.ParentName := EnclosingProc;
        Info.Depth      := ProcDepth;
        Info.PParent    := 0;
        Info.Rva        := 0;
        Info.Name       := '';
        Info.ParentByPParent := '';
        Info.OffFromStream   := Cardinal(Cur - Base);
        Info.OffFromSubsec   := Cardinal(Cur - SubsecBase);
        Info.Head := '';
        if PayloadEnd - Payload >= 12 then
          Info.Head := Format('%.8x %.8x %.8x',
            [PCardinal(Payload)^, PCardinal(Payload + 4)^, PCardinal(Payload + 8)^]);
        if PayloadEnd - Payload >= 40 then begin
          Info.PParent := PCardinal(Payload)^;
          Info.Rva     := SegOffsetToRva(PWord(Payload + 28)^, PCardinal(Payload + 24)^);
          Info.Name    := NameByIndex(PCardinal(Payload + 36)^);
        end;
        StreamProcs := StreamProcs + [Info];
        GMaxDepth := Max(GMaxDepth, Info.Depth);
        Push(Info.Name, True);
      end;
      S_BLOCK32:
        Push('', False);
      S_END:
        Pop;
    end;
    Cur := PayloadEnd;
  end;
  // Resolve pParent by treating it as a byte offset to another proc record in
  // this same stream. Both candidate origins are tried; whichever hits wins.
  for var I := 0 to High(StreamProcs) do begin
    if StreamProcs[I].PParent = 0 then Continue;
    for var J := 0 to High(StreamProcs) do begin
      if J = I then Continue;
      if StreamProcs[J].OffFromStream = StreamProcs[I].PParent then begin
        StreamProcs[I].ParentByPParent := StreamProcs[J].Name;
        Inc(GHitsFromStream);
        Break;
      end;
      if StreamProcs[J].OffFromSubsec = StreamProcs[I].PParent then begin
        StreamProcs[I].ParentByPParent := StreamProcs[J].Name;
        Inc(GHitsFromSubsec);
        Break;
      end;
    end;
  end;
  GProcs := GProcs + StreamProcs;
end;

procedure WalkAllStreams;
begin
  for var E in GDirEntries do begin
    var Base := GTd32Base + E.Offset;
    if (Base < GDebugBase) or (Base + E.Size > GDebugEnd) then Continue;
    case E.SubType of
      SST_ALIGN_SYMBOLS:
        if E.Size > 4 then
          WalkSymbolStream(Base, Base + 4, Base + E.Size);
      SST_GLOBAL_SYMBOLS:
        if E.Size > 32 then
          WalkSymbolStream(Base, Base + 32, Base + E.Size);
    end;
  end;
end;

procedure Report(const Filter: string);

  // A nested procedure is the only kind Delphi stores under a BARE short name:
  // every unit-level routine and method carries a mangled, unit-qualified name
  // (`@Unit@Proc$qqr...` on x86, `_ZN...` on x64). Counting the bare ones gives
  // the population that a parent link would have to cover.
  function LooksNested(const AName: string): Boolean;
  begin
    if AName = '' then Exit(False);
    if AName.StartsWith('@') or AName.StartsWith('_Z') then Exit(False);
    Result := True;
  end;

begin
  var BareNamed := 0;
  var BareWithParent := 0;
  var Nested := 0;
  var WithPParent := 0;
  var PParentResolved := 0;
  for var P in GProcs do begin
    if LooksNested(P.Name) then begin
      Inc(BareNamed);
      if P.ParentByPParent <> '' then
        Inc(BareWithParent);
    end;
    if P.Depth > 0 then
      Inc(Nested);
    if P.PParent <> 0 then
      Inc(WithPParent);
    if P.ParentByPParent <> '' then
      Inc(PParentResolved);
  end;
  Writeln(Format('proc records            : %d', [Length(GProcs)]));
  Writeln(Format('lexically nested (>0)   : %d', [Nested]));
  Writeln(Format('max proc nesting depth  : %d', [GMaxDepth]));
  Writeln(Format('records with pParent<>0 : %d', [WithPParent]));
  Writeln(Format('pParent resolved to proc: %d', [PParentResolved]));
  Writeln(Format('  origin = first record  : %d', [GHitsFromStream]));
  Writeln(Format('  origin = subsection hdr: %d', [GHitsFromSubsec]));
  Writeln(Format('bare-named (nested) procs: %d', [BareNamed]));
  Writeln(Format('  of which parent-linked : %d', [BareWithParent]));
  if BareNamed - BareWithParent <= 60 then begin
    Writeln('bare-named procs with NO parent link:');
    for var P in GProcs do
      if LooksNested(P.Name) and (P.ParentByPParent = '') then
        Writeln(Format('  %-24s rva=$%x recOff=$%x', [P.Name, P.Rva, P.OffFromSubsec]));
  end;
  if Filter = '' then Exit;
  Writeln;
  Writeln('matches for "', Filter, '":');
  var Hits := 0;
  for var P in GProcs do begin
    if not P.Name.ToLower.Contains(Filter.ToLower) then Continue;
    Inc(Hits);
    var Kind := 'LPROC32';
    if P.IsGlobal then
      Kind := 'GPROC32';
    Writeln(Format('  %s depth=%d rva=$%x recOff=$%x pParent=$%x',
      [Kind, P.Depth, P.Rva, P.OffFromSubsec, P.PParent]));
    Writeln(Format('    name  : %s', [P.Name]));
    Writeln(Format('    pParent/pEnd/pNext: %s', [P.Head]));
    if P.ParentName <> '' then
      Writeln(Format('    parent by scope stack: %s', [P.ParentName]))
    else
      Writeln('    parent by scope stack: (top level)');
    if P.ParentByPParent <> '' then
      Writeln(Format('    parent by pParent    : %s', [P.ParentByPParent]))
    else if P.PParent <> 0 then
      Writeln('    parent by pParent    : (offset does not hit a proc record)')
    else
      Writeln('    parent by pParent    : (pParent = 0)');
  end;
  if Hits = 0 then
    Writeln('  (none)');
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: Td32ProcNesting.exe <pe-path> [name-substring]');
      Halt(1);
    end;
    var Path := ParamStr(1);
    if not FileExists(Path) then
      Fail('file not found: ' + Path);
    LoadFile(Path);
    Writeln('File: ', Path);
    if not FindDebugSection then
      Fail('no .debug section (no embedded TD32)');
    if not FindTd32Base then
      Fail('no TD32 signature in .debug');
    if not ReadDirectory then
      Fail('TD32 directory unreadable');
    BuildNamesIndex;
    Writeln(Format('dir entries: %d   names: %d', [Length(GDirEntries), Length(GNames)]));
    WalkAllStreams;
    Report(ParamStr(2));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
