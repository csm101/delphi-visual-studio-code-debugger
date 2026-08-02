program X86DecodeProbe;

// Validates DebuggerCore\X86Decode.pas against real dcc32 output.
//
// The check needs no disassembler to compare against, because the binary
// already contains ground truth: EVERY ADDRESS IN THE LINE TABLE IS AN
// INSTRUCTION BOUNDARY. So decoding a routine linearly from its entry must
// land exactly on each of its line addresses. A single wrong instruction
// length desynchronises the stream and the probe sees the misses.
//
// This matters because the x86 stack walker uses the decoder to decide whether
// a stack word is a genuine return address. A decoder that is merely usually
// right would put wrong frames on screen.
//
// Usage: X86DecodeProbe.exe <exe-or-bpl> [-v] [-max N]
//   -v      list every routine that failed, with the bytes at the break
//   -max N  stop after N reported failures (default 20)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  Winapi.Windows,
  System.Generics.Collections,
  System.Generics.Defaults,
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  X86Decode      in '..\DebuggerCore\X86Decode.pas';

type
  TImageSection = record
    VirtualAddr: DWORD;
    VirtualSize: DWORD;
    RawOffset:   DWORD;
    RawSize:     DWORD;
  end;

  // The module's code, addressable by RVA, so the decoder sees exactly the
  // bytes the debuggee would execute.
  TImageBytes = class
  private
    FSections: TArray<TImageSection>;
    FRaw: TBytes;
  public
    constructor Create(const Path: string);
    function Read(Rva: UInt64; Buf: Pointer; Size: Integer): Boolean;
  end;

constructor TImageBytes.Create(const Path: string);
begin
  inherited Create;
  var F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(FRaw, F.Size);
    if Length(FRaw) > 0 then
      F.ReadBuffer(FRaw[0], Length(FRaw));
  finally
    F.Free;
  end;

  var PEOffset := PCardinal(@FRaw[$3C])^;
  if PCardinal(@FRaw[PEOffset])^ <> $00004550 then
    raise Exception.Create('not a PE image');
  var NumSections := PWord(@FRaw[PEOffset + 6])^;
  var OptSize     := PWord(@FRaw[PEOffset + 20])^;
  var Base        := PEOffset + 24 + OptSize;
  SetLength(FSections, NumSections);
  for var I := 0 to NumSections - 1 do begin
    var P := Base + UInt32(I) * 40;
    FSections[I].VirtualSize := PDWORD(@FRaw[P + 8])^;
    FSections[I].VirtualAddr := PDWORD(@FRaw[P + 12])^;
    FSections[I].RawSize     := PDWORD(@FRaw[P + 16])^;
    FSections[I].RawOffset   := PDWORD(@FRaw[P + 20])^;
  end;
end;

function TImageBytes.Read(Rva: UInt64; Buf: Pointer; Size: Integer): Boolean;
begin
  for var S in FSections do begin
    if (Rva < S.VirtualAddr) or (Rva >= UInt64(S.VirtualAddr) + S.VirtualSize) then
      Continue;
    var Delta := Rva - S.VirtualAddr;
    if Delta + UInt64(Size) > S.RawSize then
      Exit(False);
    var Ofs := S.RawOffset + Delta;
    if Ofs + UInt64(Size) > UInt64(Length(FRaw)) then
      Exit(False);
    Move(FRaw[Ofs], Buf^, Size);
    Exit(True);
  end;
  Result := False;
end;

type
  TRoutine = record
    StartRva: UInt64;
    LineRvas: TArray<UInt64>;
  end;

  TOutcome = (ocClean, ocUnknownOpcode, ocMissedLine, ocUnreadable);

  TResult = record
    Outcome:  TOutcome;
    AtRva:    UInt64;   // where it went wrong
    Bytes:    string;
  end;

function GroupByRoutine(Reader: TTD32FileReader;
  out Orphans: Integer): TArray<TRoutine>;
begin
  Orphans := 0;
  var Map := TDictionary<UInt64, TList<UInt64>>.Create;
  try
    for var Rva in Reader.SortedRvas do begin
      var Start: UInt64;
      if not Reader.RvaToFunctionStart(Rva, Start) then begin
        Inc(Orphans);
        Continue;
      end;
      var L: TList<UInt64>;
      if not Map.TryGetValue(Start, L) then begin
        L := TList<UInt64>.Create;
        Map.Add(Start, L);
      end;
      L.Add(Rva);
    end;

    SetLength(Result, Map.Count);
    var I := 0;
    for var Pair in Map do begin
      Result[I].StartRva := Pair.Key;
      Pair.Value.Sort;
      Result[I].LineRvas := Pair.Value.ToArray;
      Inc(I);
    end;
  finally
    for var L in Map.Values do
      L.Free;
    Map.Free;
  end;

  TArray.Sort<TRoutine>(Result, TComparer<TRoutine>.Construct(
    function(const A, B: TRoutine): Integer
    begin
      if A.StartRva < B.StartRva then
        Result := -1
      else if A.StartRva > B.StartRva then
        Result := 1
      else
        Result := 0;
    end));
end;

function OutcomeName(O: TOutcome): string;
begin
  case O of
    ocClean:         Result := 'clean';
    ocUnknownOpcode: Result := 'unknown-opcode';
    ocMissedLine:    Result := 'missed-line';
  else
    Result := 'unreadable';
  end;
end;

function HexBytes(Img: TImageBytes; Rva: UInt64; Count: Integer): string;
begin
  Result := '';
  for var I := 0 to Count - 1 do begin
    var B: Byte := 0;
    if not Img.Read(Rva + UInt64(I), @B, 1) then
      Break;
    Result := Result + IntToHex(B, 2) + ' ';
  end;
  Result := Trim(Result);
end;

// Decodes each line-table address forward to the NEXT one and confirms a
// boundary lands there. This is the property the stack walker depends on: it
// never decodes a whole routine, it decodes a short span starting at a known
// boundary. Measuring it directly keeps the probe honest about what is
// actually relied upon.
//
// Returns the number of spans checked in Spans, and the number that did not
// resolve in Broken.
procedure CheckSpans(Img: TImageBytes; const R: TRoutine;
  var Spans, Broken: Integer; var FirstBreakRva: UInt64);
const
  WINDOW = 16;
begin
  for var I := 0 to High(R.LineRvas) - 1 do begin
    var From := R.LineRvas[I];
    var Upto := R.LineRvas[I + 1];
    if Upto <= From then
      Continue;   // duplicate address for two source lines: nothing to decode
    Inc(Spans);
    var Rva := From;
    var Landed := False;
    while Rva < Upto do begin
      var Buf: array[0..WINDOW - 1] of Byte;
      FillChar(Buf, SizeOf(Buf), 0);
      var Got := WINDOW;
      while (Got > 0) and (not Img.Read(Rva, @Buf[0], Got)) do
        Dec(Got);
      if Got = 0 then
        Break;
      var Insn := DecodeX86Insn32(Buf, Got, UInt32(Rva));
      if Insn.Length <= 0 then
        Break;
      Rva := Rva + UInt64(Insn.Length);
      if Rva = Upto then begin
        Landed := True;
        Break;
      end;
      if Rva > Upto then
        Break;
    end;
    if Landed then
      Continue;
    Inc(Broken);
    if FirstBreakRva = 0 then
      FirstBreakRva := From;
  end;
end;

// Decodes the routine from its entry and confirms a boundary falls on every
// line address it owns. Stricter than the walker needs -- dcc32 embeds the
// exception-handler table directly in the code stream after the `jmp
// @HandleAnyException` of a try/except, and no linear decode can cross data --
// so a failure here is informative, not necessarily a decoder bug.
function CheckRoutine(Img: TImageBytes; const R: TRoutine): TResult;
const
  WINDOW = 16;
begin
  Result := Default(TResult);
  Result.Outcome := ocClean;
  if Length(R.LineRvas) = 0 then
    Exit;

  var Boundaries := TDictionary<UInt64, Byte>.Create;
  try
    var Horizon := R.LineRvas[High(R.LineRvas)];
    var Rva := R.StartRva;
    Boundaries.AddOrSetValue(Rva, 1);
    while Rva <= Horizon do begin
      var Buf: array[0..WINDOW - 1] of Byte;
      FillChar(Buf, SizeOf(Buf), 0);
      var Got := WINDOW;
      while (Got > 0) and (not Img.Read(Rva, @Buf[0], Got)) do
        Dec(Got);
      if Got = 0 then begin
        Result.Outcome := ocUnreadable;
        Result.AtRva := Rva;
        Exit;
      end;
      var Insn := DecodeX86Insn32(Buf, Got, UInt32(Rva));
      if Insn.Length <= 0 then begin
        Result.Outcome := ocUnknownOpcode;
        Result.AtRva   := Rva;
        Result.Bytes   := HexBytes(Img, Rva, 8);
        Exit;
      end;
      Rva := Rva + UInt64(Insn.Length);
      Boundaries.AddOrSetValue(Rva, 1);
    end;

    for var LineRva in R.LineRvas do
      if not Boundaries.ContainsKey(LineRva) then begin
        Result.Outcome := ocMissedLine;
        Result.AtRva   := LineRva;
        Result.Bytes   := HexBytes(Img, LineRva - 8, 16);
        Exit;
      end;
  finally
    Boundaries.Free;
  end;
end;

procedure Run(const ModulePath: string; Verbose: Boolean; MaxReports: Integer);
begin
  var Img := TImageBytes.Create(ModulePath);
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ModulePath);
    if not Reader.Loaded then begin
      Writeln('ERROR: no TD32 debug info in ', ModulePath);
      Halt(1);
    end;

    var Orphans: Integer;
    var Routines := GroupByRoutine(Reader, Orphans);
    Writeln('Module   : ', ModulePath);
    Writeln('Routines : ', Length(Routines));
    Writeln('Line rvas: ', Length(Reader.SortedRvas),
      '  (unattributed: ', Orphans, ')');
    Writeln;

    var Counts: array[TOutcome] of Integer;
    for var O := Low(TOutcome) to High(TOutcome) do
      Counts[O] := 0;
    var Reported := 0;
    var Spans := 0;
    var Broken := 0;
    var FirstBreak: UInt64 := 0;

    for var R in Routines do begin
      CheckSpans(Img, R, Spans, Broken, FirstBreak);
      var Res := CheckRoutine(Img, R);
      Inc(Counts[Res.Outcome]);
      if (Res.Outcome = ocClean) or (not Verbose) or (Reported >= MaxReports) then
        Continue;
      Inc(Reported);
      var Name: string;
      if not Reader.RvaToFunctionName(R.StartRva, Name) then
        Name := '<unnamed>';
      Writeln(Format('  %-14s %s  start=$%x at=$%x',
        [OutcomeName(Res.Outcome), Name,
         R.StartRva, Res.AtRva]));
      if Res.Bytes <> '' then
        Writeln('                 bytes: ', Res.Bytes);
    end;

    Writeln;
    Writeln('--- line-to-line spans (what the stack walker actually decodes) ---');
    Writeln('spans checked  : ', Spans);
    Writeln('spans broken   : ', Broken);
    if Broken > 0 then
      Writeln('first break at : $', IntToHex(FirstBreak, 8));
    Writeln;
    Writeln('--- whole-routine decode from entry (stricter than needed) ---');
    Writeln('clean          : ', Counts[ocClean]);
    Writeln('unknown opcode : ', Counts[ocUnknownOpcode]);
    Writeln('missed line    : ', Counts[ocMissedLine]);
    Writeln('unreadable     : ', Counts[ocUnreadable]);
    Writeln;
    // Deliberately no pass/fail verdict on the raw counts. Neither measure can
    // reach zero on a real binary, because dcc32 puts DATA in the code stream --
    // the exception-handler table after `jmp @HandleAnyException`, and the jump
    // table of every large `case`. Both are indistinguishable from an unknown
    // instruction to a linear decoder, and refusing is the right answer for both.
    //
    // What to look at instead: run the probe before and after a decoder change.
    // A change that ADDS coverage lowers the unknown count without raising the
    // broken-span count; one that gets a length WRONG desynchronises the stream
    // and RAISES broken spans. That comparison is the signal -- an absolute
    // number is not.
    if Verbose then
      Writeln('NOTE: inspect the bytes above. Repeated small values and pairs of ' +
              'in-image addresses are jump tables, i.e. data, not gaps in the map.');
    Writeln(Format('RESULT: %d/%d spans unresolved (%.2f%%), %d routines hit an ' +
      'unknown opcode. Compare against the previous run rather than against zero.',
      [Broken, Spans, (Broken * 100.0) / Max(Spans, 1), Counts[ocUnknownOpcode]]));
  finally
    Reader.Free;
    Img.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: X86DecodeProbe.exe <exe-or-bpl> [-v] [-max N]');
      Halt(1);
    end;
    var ModulePath := ParamStr(1);
    var Verbose := False;
    var MaxReports := 20;
    var I := 2;
    while I <= ParamCount do begin
      if SameText(ParamStr(I), '-v') then
        Verbose := True
      else if SameText(ParamStr(I), '-max') and (I < ParamCount) then begin
        Inc(I);
        MaxReports := StrToIntDef(ParamStr(I), 20);
      end;
      Inc(I);
    end;
    if not FileExists(ModulePath) then begin
      Writeln('ERROR: module not found: ', ModulePath);
      Halt(1);
    end;
    Run(ModulePath, Verbose, MaxReports);
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
