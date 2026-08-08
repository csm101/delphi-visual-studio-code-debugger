unit ZydisDisassembler;

// The Zydis-backed implementation of IDisassembler (DISASSEMBLY_PLAN.md
// increment 2). This is the ONLY unit besides ZydisApi.pas itself allowed to
// reference ZydisApi -- everything else in the debugger, including DevTools
// and any future MCP/DAP surface, must go through IDisassembler
// (Disassembler.pas), never through this unit's implementation details. Same
// discipline the codebase already applies to IDebugTarget/TWinDebugger.
//
// Symbolication is OPTIONAL: pass a TDebugInfoSet + the main exe's ImageBase
// to get per-instruction "nearest function + offset" / source file+line, and
// to have direct CALL/JMP targets annotated with a resolved name when one is
// known. Pass nil for Symbols to get pure decode with no lookups at all (the
// static-analysis, no-symbols case).

interface

uses
  System.SysUtils, System.RegularExpressions,
  Disassembler, ZydisApi, DebugInfoSet, DebugInfoTypes;

type
  TZydisDisassembler = class(TInterfacedObject, IDisassembler)
  private
    FMode:      TZydisMachineMode;
    FReader:    TDisasmByteReader;
    FSymbols:   TDebugInfoSet;   // nil = no symbolication
    FImageBase: UInt64;          // VA the main exe is mapped at; Rva := VA - FImageBase
    FBranchTargetRe: TRegEx;
    // Nearest function name + offset for an RVA already known to be inside the
    // main image, e.g. 'TFoo.Bar+0x14'; '' when no provider knows the RVA.
    function SymbolAt(Rva: UInt64): string;
    // Fills Item.Symbol / Item.SrcFile / Item.SrcLine for the instruction's own
    // address, and appends a resolved-name comment to Item.Text when Item.Text
    // is an EXACT direct-branch form ('<mnemonic> 0x<hex>') Zydis produced for
    // a call/jmp with a static target.
    procedure Symbolicate(var Item: TDisasmInstruction);
  public
    // Mode/Reader are mandatory; Symbols/ImageBase are optional (nil/0 = no
    // symbolication). DllPath overrides the normal DLL search order, exactly
    // like ZydisApi.ZydisTryLoad -- '' uses this exe's own directory then PATH.
    constructor Create(Mode: TDisasmMachineMode; const Reader: TDisasmByteReader;
      Symbols: TDebugInfoSet = nil; ImageBase: UInt64 = 0; const DllPath: string = '');
    function Available: Boolean;
    function StatusText: string;
    function Disassemble(VA: UInt64; Count: Integer): TArray<TDisasmInstruction>;
  end;

implementation

const
  // ZYDIS_MAX_INSTRUCTION_LENGTH. A generous per-instruction read so the
  // longest legal x86/x64 encoding never gets starved by an undersized buffer;
  // the byte READER, not this constant, is what enforces truncation at a real
  // page/section boundary (trap 2).
  MAX_INSN_LEN = 15;

constructor TZydisDisassembler.Create(Mode: TDisasmMachineMode;
  const Reader: TDisasmByteReader; Symbols: TDebugInfoSet; ImageBase: UInt64;
  const DllPath: string);
begin
  inherited Create;
  case Mode of
    dmmLong64:   FMode := zmmLong64;
    dmmLegacy32: FMode := zmmLegacy32;
  end;
  FReader    := Reader;
  FSymbols   := Symbols;
  FImageBase := ImageBase;
  // Matches ONLY the exact text Zydis's default formatter emits for a direct
  // near call/jmp/jcc with a static target: mnemonic, one space, '0x', hex
  // digits, nothing else. Measured with DevTools\DisasmProbe against real
  // Delphi output -- 'call 0x0000000000019F10' (x64, 16 digits) and
  // 'call 0x0001160C' (x86, 8 digits); an indirect call/jmp formats with
  // brackets or a bare register ('call [rbx]', 'call [ebx]') and never
  // matches.
  //
  // The mnemonic is a CLOSED whitelist of every control-transfer mnemonic
  // Zydis's formatter emits (call/jmp/every Jcc/loop family), not a bare
  // [A-Za-z]+. Measured regression: 'push 0x2A' (a plain PUSH of the
  // immediate 42) has the exact same 'mnemonic 0x<hex>' shape as a direct
  // call/jmp, so an open mnemonic match mislabelled a pushed constant as a
  // resolved call target. Missing a real branch here only means one fewer
  // annotated instruction (Text still shows the raw address Zydis printed,
  // which the plan already treats as the correct answer for an unresolved
  // target); matching a NON-branch would print a fabricated symbol next to
  // an unrelated operand, which this project's fail-closed rule forbids.
  FBranchTargetRe := TRegEx.Create(
    '^(call|jmp|jo|jno|jb|jnb|jz|jnz|jbe|jnbe|js|jns|jp|jnp|jl|jnl|jle|jnle|' +
    'jcxz|jecxz|jrcxz|loop|loope|loopne) 0x([0-9A-Fa-f]+)$');
  ZydisTryLoad(DllPath);
end;

function TZydisDisassembler.Available: Boolean;
begin
  Result := ZydisAvailable;
end;

function TZydisDisassembler.StatusText: string;
begin
  Result := ZydisStatusText;
end;

function TZydisDisassembler.SymbolAt(Rva: UInt64): string;
var
  Name: string;
  FuncRva: UInt64;
begin
  Result := '';
  if FSymbols = nil then
    Exit;
  if not FSymbols.RvaToFunctionName(Rva, Name) then
    Exit;
  Result := Name;
  if FSymbols.RvaToFunctionStart(Rva, FuncRva) and (Rva > FuncRva) then
    Result := Result + Format('+0x%x', [Rva - FuncRva]);
end;

procedure TZydisDisassembler.Symbolicate(var Item: TDisasmInstruction);
var
  Loc: TSourceLocation;
  Rva: UInt64;
begin
  if (FSymbols = nil) or (Item.VA < FImageBase) then
    Exit;   // outside the main image's RVA space -- nothing to look up here

  {$Q-}
  Rva := Item.VA - FImageBase;
  {$Q+}
  Item.Symbol := SymbolAt(Rva);
  if FSymbols.RvaToSourceLine(Rva, Loc) then begin
    Item.SrcFile := Loc.SourceFile;
    Item.SrcLine := Loc.Line;
  end;

  if not Item.Decoded then
    Exit;
  var M := FBranchTargetRe.Match(Item.Text);
  if not M.Success then
    Exit;   // not a whitelisted direct-branch mnemonic -- leave Text as-is
  var TargetVA := StrToUInt64('$' + M.Groups[2].Value);
  if TargetVA < FImageBase then
    Exit;   // target outside the main image -- an address is the honest answer
  {$Q-}
  var TargetRva := TargetVA - FImageBase;
  {$Q+}
  var TargetName := SymbolAt(TargetRva);
  if TargetName <> '' then
    Item.Text := Item.Text + '  ; ' + TargetName;
end;

function TZydisDisassembler.Disassemble(VA: UInt64;
  Count: Integer): TArray<TDisasmInstruction>;
var
  Cursor: UInt64;
  Buf: array[0..MAX_INSN_LEN - 1] of Byte;
  Avail: Integer;
  Insn: TZydisInstruction;
  Item: TDisasmInstruction;
begin
  SetLength(Result, 0);
  if not Available then
    Exit;   // fail closed -- no fallback decoder anywhere in this project

  Cursor := VA;
  for var I := 1 to Count do begin
    Avail := FReader(Cursor, @Buf[0], MAX_INSN_LEN);
    if Avail <= 0 then
      Break;   // nothing readable at all here -- stop, do not fabricate

    Item := Default(TDisasmInstruction);
    Item.VA := Cursor;
    if ZydisDecodeOne(FMode, Cursor, Buf[0], Avail, Insn) and Insn.Decoded then begin
      Item.Length  := Insn.Length;
      SetLength(Item.Bytes, Insn.Length);
      Move(Buf[0], Item.Bytes[0], Insn.Length);
      Item.Text    := Insn.Text;
      Item.Decoded := True;
    end
    else begin
      // Undecodable -- render exactly one byte as data and try to resync on
      // the next one, never guess a length. DISASSEMBLY_PLAN.md: "an
      // instruction Zydis cannot decode renders as `db XX`, never a guess."
      Item.Length := 1;
      SetLength(Item.Bytes, 1);
      Item.Bytes[0] := Buf[0];
      Item.Text     := Format('db %.2x', [Buf[0]]);
      Item.Decoded  := False;
    end;

    Symbolicate(Item);
    Result := Result + [Item];
    Inc(Cursor, UInt64(Item.Length));
  end;
end;

end.
