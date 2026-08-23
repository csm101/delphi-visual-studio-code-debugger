program Disasm;

// Exercises the IDisassembler seam end to end (docs/DISASSEMBLY_PLAN.md increment
// 2): the Zydis backend behind it, and symbolication of the output through
// the SAME provider set (TDebugInfoSet: MAP + RSM + TD32) the adapter itself
// queries when naming a stack frame.
//
// Two modes, both argv-driven with no hardcoded target:
//
//   Disasm.exe <exe> <hexRVA> [count] [-zydisdll <path>]
//     STATIC mode. Reads bytes straight out of a PE file on disk at a given
//     RVA and decodes them -- no running process, no breakpoints. Machine
//     mode is read from the file's own PE header, never assumed from the
//     host. Symbolication (when the sibling .map/.rsm exist) uses a
//     TDebugInfoSet built the same way the adapter builds one for a main
//     exe: RSM added first, TD32 primary, MAP last (ModuleSymbolLoader
//     .LoadMainModule order).
//
//   Disasm.exe -live <exe> <map> <rsm> <sourceRoot> <sourceBaseName> <marker>
//              [count] [-zydisdll <path>] [-args <targetArgs>]
//     LIVE mode. Launches the target through a real TDebugSession, plants a
//     breakpoint at the {BP:<marker>} tag, waits for the stop, then
//     disassembles from the stop PC using the session's OWN debug-info set
//     (multi-module aware) and OWN engine (IDebugTarget.ReadCodeMemoryAt),
//     which is what proves trap 1: the planted INT3 at the stop address
//     reads back as the user's real instruction, not `int3`. Machine mode
//     comes from IDebugTarget.TargetLayout.PointerSize, never from the host.
//
// -zydisdll overrides where Zydis.dll is loaded from (default: normal
// Windows search order, falling back to the repo-relative
// ThirdParty\Zydis\bin\x64\Zydis.dll so a fresh build works unmodified).

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.StrUtils,
  Winapi.Windows,
  Disassembler      in '..\DebuggerCore\Disassembler.pas',
  ZydisApi          in '..\DebuggerCore\ZydisApi.pas',
  ZydisDisassembler in '..\DebuggerCore\ZydisDisassembler.pas',
  DebugInfoTypes    in '..\DebuggerCore\DebugInfoTypes.pas',
  DebugInfoSet      in '..\DebuggerCore\DebugInfoSet.pas',
  MapFileReader     in '..\DebuggerCore\MapFileReader.pas',
  RsmFileReader     in '..\DebuggerCore\RsmFileReader.pas',
  TD32FileReader    in '..\DebuggerCore\TD32FileReader.pas',
  DebugSessionTypes in '..\DebuggerCore\DebugSessionTypes.pas',
  DebugSession      in '..\DebuggerCore\DebugSession.pas';

const
  IMAGE_FILE_MACHINE_I386  = $014C;
  IMAGE_FILE_MACHINE_AMD64 = $8664;

type
  TImageSection = record
    VirtualAddr: DWORD;
    VirtualSize: DWORD;
    RawOffset:   DWORD;
    RawSize:     DWORD;
  end;

{ ---------------------------------------------------------- PE helpers ---- }

function ReadPEMachine(const Path: string): Word;
var
  F: TFileStream;
  DosHeader: array[0..63] of Byte;
  PEOffset: DWORD;
  Sig: DWORD;
begin
  Result := 0;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    F.ReadBuffer(DosHeader, SizeOf(DosHeader));
    PEOffset := PCardinal(@DosHeader[$3C])^;
    F.Position := PEOffset;
    F.ReadBuffer(Sig, SizeOf(Sig));
    if Sig <> $00004550 then Exit;
    F.ReadBuffer(Result, SizeOf(Result));
  finally
    F.Free;
  end;
end;

function ReadSections(const Path: string): TArray<TImageSection>;
var
  F: TFileStream;
  DosHeader: array[0..63] of Byte;
  PEOffset: DWORD;
  Sig: DWORD;
  NumSectionsW, OptHeaderSize: Word;
  Raw: array[0..39] of Byte;
begin
  SetLength(Result, 0);
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    F.ReadBuffer(DosHeader, SizeOf(DosHeader));
    PEOffset := PCardinal(@DosHeader[$3C])^;
    F.Position := PEOffset;
    F.ReadBuffer(Sig, SizeOf(Sig));
    if Sig <> $00004550 then Exit;
    F.Position := PEOffset + 4 + 2;
    F.ReadBuffer(NumSectionsW, SizeOf(NumSectionsW));
    F.Position := PEOffset + 4 + 16;
    F.ReadBuffer(OptHeaderSize, SizeOf(OptHeaderSize));
    F.Position := PEOffset + 4 + 20 + OptHeaderSize;
    SetLength(Result, NumSectionsW);
    for var I := 0 to NumSectionsW - 1 do begin
      F.ReadBuffer(Raw, SizeOf(Raw));
      var S: TImageSection;
      S.VirtualSize := PDWORD(@Raw[8])^;
      S.VirtualAddr := PDWORD(@Raw[12])^;
      S.RawSize     := PDWORD(@Raw[16])^;
      S.RawOffset   := PDWORD(@Raw[20])^;
      Result[I] := S;
    end;
  finally
    F.Free;
  end;
end;

function RvaToFileOffset(const Sections: TArray<TImageSection>; RVA: DWORD;
  out Found: Boolean): DWORD;
begin
  Found := False;
  Result := 0;
  for var S in Sections do
    if (RVA >= S.VirtualAddr) and (RVA < S.VirtualAddr + S.VirtualSize) then begin
      Result := S.RawOffset + (RVA - S.VirtualAddr);
      Found := True;
      Exit;
    end;
end;

function DefaultZydisDllPath: string;
begin
  // DevTools\Win64\<Config>\Disasm.exe is three levels below the repo root.
  Result := TPath.GetFullPath(TPath.Combine(ExtractFileDir(ParamStr(0)),
    '..\..\..\ThirdParty\Zydis\bin\x64\Zydis.dll'));
end;

function ResolveZydisDllPath(const OverridePath: string): string;
var
  NextToExe: string;
begin
  if OverridePath <> '' then Exit(OverridePath);
  NextToExe := TPath.Combine(ExtractFileDir(ParamStr(0)), 'Zydis.dll');
  if FileExists(NextToExe) then Exit(NextToExe);
  if FileExists(DefaultZydisDllPath) then Exit(DefaultZydisDllPath);
  Result := '';
end;

function ParseHexArg(const S: string): UInt64;
var
  Cleaned: string;
begin
  Cleaned := S;
  if Cleaned.StartsWith('0x', True) then Cleaned := Cleaned.Substring(2)
  else if Cleaned.StartsWith('$') then Cleaned := Cleaned.Substring(1);
  Result := StrToUInt64('$' + Cleaned);
end;

procedure PrintInstructions(const Insns: TArray<TDisasmInstruction>);
begin
  for var Ins in Insns do begin
    var BytesText := '';
    for var B in Ins.Bytes do
      BytesText := BytesText + IntToHex(B, 2) + ' ';
    var Loc := '';
    if Ins.SrcFile <> '' then
      Loc := Format('  ; %s:%d', [ExtractFileName(Ins.SrcFile), Ins.SrcLine]);
    var Sym := '';
    if Ins.Symbol <> '' then
      Sym := ' [' + Ins.Symbol + ']';
    Writeln(Format('  $%.16x  %-24s  %s%s%s',
      [Ins.VA, BytesText.TrimRight, Ins.Text, Sym, Loc]));
  end;
end;

{ ------------------------------------------------------------ Static mode - }

// Builds the same provider ORDER TModuleSymbolLoader.LoadMainModule uses for
// a main exe (RSM added, TD32 PRIMARY, MAP last), from sibling .rsm/.map
// files -- unranged, since a standalone-file probe has exactly one binary.
// Returns nil (no symbolication, not an error) when neither sidecar exists.
function BuildStaticSymbols(const ExePath: string): TDebugInfoSet;
var
  RsmPath, MapPath: string;
  AnyLoaded: Boolean;
begin
  Result := nil;
  RsmPath := ChangeFileExt(ExePath, '.rsm');
  MapPath := ChangeFileExt(ExePath, '.map');
  AnyLoaded := False;
  var Info := TDebugInfoSet.Create;
  try
    if FileExists(RsmPath) then begin
      var Rsm := TRsmFile.Create;
      Rsm.LoadFromFile(RsmPath);
      if Rsm.Loaded then begin
        Info.AddProvider(Rsm);
        AnyLoaded := True;
      end
      else
        Rsm.Free;
    end;
    var Td32 := TTD32FileReader.Create;
    Td32.LoadFromFile(ExePath);
    if Td32.Loaded then begin
      Info.AddProvider(Td32, True);
      AnyLoaded := True;
    end
    else
      Td32.Free;
    if FileExists(MapPath) then begin
      var Map := TMapFile.Create;
      Map.LoadFromFile(MapPath);
      Info.AddProvider(Map);
      AnyLoaded := True;
    end;
  except
    Info.Free;
    raise;
  end;
  if AnyLoaded then
    Result := Info
  else
    Info.Free;
end;

procedure RunStaticMode(const ExePath: string; RVA: UInt64; Count: Integer;
  const DllArg: string);
var
  Mode: TDisasmMachineMode;
  Machine: Word;
  Sections: TArray<TImageSection>;
  Symbols: TDebugInfoSet;
begin
  Mode := dmmLong64;
  Machine := ReadPEMachine(ExePath);
  case Machine of
    IMAGE_FILE_MACHINE_I386:  Mode := dmmLegacy32;
    IMAGE_FILE_MACHINE_AMD64: Mode := dmmLong64;
  else
    Writeln(Format('FATAL: %s has unrecognised PE machine $%.4x', [ExePath, Machine]));
    Halt(2);
  end;
  Writeln(Format('%s: PE machine $%.4x -> mode %s',
    [ExtractFileName(ExePath), Machine, IfThen(Mode = dmmLong64, 'long64', 'legacy32')]));

  Sections := ReadSections(ExePath);
  Symbols := BuildStaticSymbols(ExePath);
  if Symbols = nil then
    Writeln('  (no .rsm/.map/TD32 symbols found -- decoding without symbolication)');

  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    var
      F: TFileStream;
      Found: Boolean;
      Offset: DWORD;
      Avail: Int64;
    begin
      Result := 0;
      Offset := RvaToFileOffset(Sections, DWORD(VA), Found);
      if not Found then Exit;
      F := TFileStream.Create(ExePath, fmOpenRead or fmShareDenyNone);
      try
        Avail := F.Size - Offset;
        if Avail <= 0 then Exit;
        if Avail > Size then Avail := Size;   // truncate at EOF -- trap 2
        F.Position := Offset;
        F.ReadBuffer(Buf^, Avail);
        Result := Integer(Avail);
      finally
        F.Free;
      end;
    end;

  var Disasm: IDisassembler := TZydisDisassembler.Create(Mode, Reader, Symbols, 0,
    ResolveZydisDllPath(DllArg));
  Writeln('  ' + Disasm.StatusText);
  if not Disasm.Available then begin
    Writeln('FATAL: Zydis unavailable, cannot disassemble.');
    Symbols.Free;
    Halt(3);
  end;

  Writeln(Format('Decoding %d instruction(s) from RVA $%x:', [Count, RVA]));
  PrintInstructions(Disasm.Disassemble(RVA, Count));
  Symbols.Free;
end;

{ -------------------------------------------------------------- Live mode - }

function MarkerLine(const SourcePath, Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

procedure RunLiveMode(const ExePath, MapPath, RsmPath, SourceRoot,
  SourceBaseName, Marker: string; Count: Integer; const DllArg, TargetArgs: string);
begin
  var SourcePath := IncludeTrailingPathDelimiter(SourceRoot) + SourceBaseName;
  var Line := MarkerLine(SourcePath, Marker);
  if Line <= 0 then begin
    Writeln(Format('FATAL: marker {BP:%s} not found in %s', [Marker, SourcePath]));
    Halt(2);
  end;

  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := ExePath;
    Opts.MapPath     := MapPath;
    Opts.RsmPath     := RsmPath;
    Opts.SourceRoot  := SourceRoot;
    Opts.StopAtEntry := False;
    Opts.Args        := TargetArgs;
    if not Session.Launch(Opts) then begin
      Writeln('FATAL: launch failed');
      Halt(3);
    end;

    var LineSpec: TBpLineSpec;
    LineSpec := Default(TBpLineSpec);
    LineSpec.Line := Line;
    Session.SetBreakpoints(SourceBaseName, [LineSpec]);

    var Deadline := GetTickCount64 + 60000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    if Session.State <> dsStopped then begin
      Writeln('FATAL: did not stop at the marker (exited or timed out)');
      Halt(4);
    end;

    var Pc := Session.Debugger.GetRegisters.Pc;
    Writeln(Format('stopped at VA $%.16x (module ImageBase $%.16x)',
      [Pc, Session.Debugger.ImageBase]));

    // Prove trap 1 directly: the raw byte at the stop PC is the debugger's OWN
    // planted INT3 -- ReadProcessMemoryAt must show $CC, ReadCodeMemoryAt (what
    // the disassembler is fed) must show the restored original opcode.
    var RawByte: Byte := 0;
    Session.Debugger.ReadProcessMemoryAt(Pc, @RawByte, 1);
    var FixedByte: Byte := 0;
    Session.Debugger.ReadCodeMemoryAt(Pc, @FixedByte, 1);
    Writeln(Format('  raw memory at PC = $%.2x (%s)   code-memory at PC = $%.2x (%s)',
      [RawByte, IfThen(RawByte = $CC, 'INT3 -- as expected, a breakpoint is planted here',
                                        'no breakpoint byte'),
       FixedByte, IfThen(FixedByte = $CC, 'STILL INT3 -- trap 1 NOT handled', 'restored')]));

    var Mode: TDisasmMachineMode;
    if Session.Debugger.TargetLayout.PointerSize = 8 then Mode := dmmLong64
    else Mode := dmmLegacy32;
    Writeln(Format('  TargetLayout.PointerSize=%d -> mode %s',
      [Session.Debugger.TargetLayout.PointerSize,
       IfThen(Mode = dmmLong64, 'long64', 'legacy32')]));

    var Debugger := Session.Debugger;
    var Reader: TDisasmByteReader :=
      function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
      begin
        Result := Integer(Debugger.ReadCodeMemoryAt(VA, Buf, NativeUInt(Size)));
      end;

    var Disasm: IDisassembler := TZydisDisassembler.Create(Mode, Reader,
      Session.DebugInfo, Session.Debugger.ImageBase, ResolveZydisDllPath(DllArg));
    Writeln('  ' + Disasm.StatusText);
    if not Disasm.Available then begin
      Writeln('FATAL: Zydis unavailable, cannot disassemble.');
      Halt(5);
    end;

    Writeln(Format('Decoding %d instruction(s) from the stop PC:', [Count]));
    PrintInstructions(Disasm.Disassemble(Pc, Count));
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

{ ------------------------------------------------------------------- main - }

procedure Run;
var
  Args: TArray<string>;
  DllArg, TargetArgsVal: string;
  Count: Integer;
begin
  SetLength(Args, ParamCount);
  for var I := 1 to ParamCount do Args[I - 1] := ParamStr(I);

  DllArg := '';
  TargetArgsVal := '';
  for var I := High(Args) downto 0 do begin
    if SameText(Args[I], '-zydisdll') and (I < High(Args)) then begin
      DllArg := Args[I + 1];
      Delete(Args, I, 2);
    end
    else if SameText(Args[I], '-args') and (I < High(Args)) then begin
      TargetArgsVal := Args[I + 1];
      Delete(Args, I, 2);
    end;
  end;

  if (Length(Args) >= 1) and SameText(Args[0], '-live') then begin
    if Length(Args) < 7 then begin
      Writeln('Usage: Disasm.exe -live <exe> <map> <rsm> <sourceRoot> <sourceBaseName> <marker> [count] [-args <targetArgs>] [-zydisdll <path>]');
      Halt(1);
    end;
    Count := 10;
    if Length(Args) >= 8 then Count := StrToInt(Args[7]);
    RunLiveMode(Args[1], Args[2], Args[3], Args[4], Args[5], Args[6], Count,
      DllArg, TargetArgsVal);
    Exit;
  end;

  if Length(Args) < 2 then begin
    Writeln('Usage: Disasm.exe <exe> <hexRVA> [count] [-zydisdll <path>]');
    Writeln('       Disasm.exe -live <exe> <map> <rsm> <sourceRoot> <sourceBaseName> <marker> [count] [-args <targetArgs>] [-zydisdll <path>]');
    Halt(1);
  end;
  Count := 10;
  if Length(Args) >= 3 then Count := StrToInt(Args[2]);
  RunStaticMode(Args[0], ParseHexArg(Args[1]), Count, DllArg);
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.ClassName, ': ', E.Message);
      Halt(9);
    end;
  end;
end.
