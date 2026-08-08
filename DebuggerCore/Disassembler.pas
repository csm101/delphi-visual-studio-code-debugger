unit Disassembler;

// The disassembly seam (DISASSEMBLY_PLAN.md increment 2, "The seam"). This
// unit is deliberately library-free: no third-party disassembler is named or
// imported here, so every caller depends only on this interface and can be
// tested without the backend's DLL. `ZydisDisassembler.pas` is the (currently
// only) implementation; the same discipline as IDebugTarget/TWinDebugger --
// callers program against IDisassembler, never against the concrete class.

interface

uses
  System.SysUtils;

type
  // Which instruction-set width to decode. Bound to the TARGET, never to the
  // host: the adapter is one 64-bit process that debugs both a native x64
  // target and a 32-bit (WOW64) one, so this must come from
  // IDebugTarget.TargetLayout (PointerSize) or the target's own PE machine
  // word -- never assumed from SizeOf(Pointer) in the adapter's own process.
  TDisasmMachineMode = (dmmLong64, dmmLegacy32);

  // Supplies raw code bytes to decode from, decoupling the backend from where
  // the bytes come from (a live debuggee, a PE file on disk, a test double).
  //
  // Returns the number of bytes actually placed in Buf, which may be LESS
  // than Size -- a read that reaches the end of a section, a page boundary
  // backed by nothing, or EOF is a NORMAL case and must be answered with a
  // shorter buffer, never with a failure (DISASSEMBLY_PLAN.md trap: "reads
  // across a page boundary into unmapped memory must TRUNCATE, not fail the
  // whole request"). 0 means nothing at all was readable at VA.
  //
  // A reader over a LIVE process must return bytes with any of the debugger's
  // OWN planted breakpoints (INT3, $CC) restored to the original opcode --
  // otherwise the disassembly shows `int3` where the user's code actually is.
  // This unit does not enforce that; the reader supplied by the live-session
  // caller is where it is enforced (see WinDebuggerBase.ReadCodeMemoryAt).
  TDisasmByteReader = reference to function(VA: UInt64; Buf: Pointer;
    Size: Integer): Integer;

  TDisasmInstruction = record
    VA:      UInt64;
    Length:  Integer;
    Bytes:   TArray<Byte>;
    Text:    string;    // Intel syntax; 'db XX' when Zydis could not decode
    Decoded: Boolean;   // False -> Text is 'db XX', never a guessed mnemonic
    Symbol:  string;    // nearest function + offset for THIS instruction's own
                         // VA (e.g. 'TFoo.Bar+0x14'), '' when no provider knows
    SrcFile: string;    // source file for this VA, '' when the line table
                         // has nothing here
    SrcLine: Integer;   // meaningful only when SrcFile <> ''
  end;

  // Backend contract. `Available` and `StatusText` let every caller degrade to
  // "disassembly unavailable" instead of falling back to any other decoder --
  // there is no general-purpose fallback in this project; X86Decode.pas has a
  // different, narrower contract (exact instruction LENGTHS only, x86 only, no
  // library dependency) and stays on the call-site-proving path, untouched.
  IDisassembler = interface
    ['{7F3E9C2A-1B4D-4A6E-9C71-2E8B5A3F1D06}']
    // Backend loaded and version-checked. False for the whole lifetime of this
    // instance when the DLL is missing or version-mismatched at construction --
    // never retried, matching the underlying loader's own one-shot contract.
    function Available: Boolean;
    // Diagnostics: why Available is False, or where the backend loaded from.
    // Never empty.
    function StatusText: string;
    // Decodes up to Count instructions starting at VA. Stops early (a shorter
    // array than Count) when the byte reader runs out of bytes to offer.
    // Returns an empty array when not Available -- this unit never guesses at
    // instruction boundaries with no decoder behind it.
    function Disassemble(VA: UInt64; Count: Integer): TArray<TDisasmInstruction>;
  end;

  // Reusable backward-disassembly mechanism (DISASSEMBLY_PLAN.md, "before" --
  // decision: proven-boundary-only). x86/x64 cannot be decoded backwards, so
  // the only exact way to find instructions PRECEDING TargetVA is to start
  // from a PROVEN earlier boundary and decode FORWARD, keeping the result
  // only if it lands EXACTLY on TargetVA. BoundaryVA must already be such a
  // boundary (from IDebugTarget.NearestInstructionBoundaryBefore, or its
  // PE-export fallback for a module with no debug info) -- this function
  // does not find one itself and never guesses at a shorter or longer span:
  // it returns NO instructions at all, rather than a partial or misaligned
  // list, when the forward decode does not land exactly on TargetVA (e.g. an
  // inline exception-handler table straddled between the boundary and the
  // target). Increment 6's DAP negative instructionOffset must call this
  // same function rather than re-implement backward disassembly.
  function DisassembleBackward(const Disasm: IDisassembler;
    BoundaryVA, TargetVA: UInt64; Before: Integer): TArray<TDisasmInstruction>;

implementation

function DisassembleBackward(const Disasm: IDisassembler;
  BoundaryVA, TargetVA: UInt64; Before: Integer): TArray<TDisasmInstruction>;
begin
  Result := nil;
  if (Before <= 0) or (BoundaryVA >= TargetVA) then
    Exit;

  var Chain: TArray<TDisasmInstruction> := nil;
  var Cursor := BoundaryVA;
  while Cursor < TargetVA do begin
    var Step := Disasm.Disassemble(Cursor, 1);
    if Length(Step) = 0 then
      Exit;   // reader ran dry before reaching the target -- refuse, no guess
    Chain := Chain + [Step[0]];
    Inc(Cursor, UInt64(Step[0].Length));
  end;
  if Cursor <> TargetVA then
    Exit;   // overshot or (impossible, but checked) fell short of the target
            // exactly -- refuse rather than trust a decode that did not land

  var Keep := Length(Chain);
  if Keep > Before then
    Keep := Before;
  Result := Copy(Chain, Length(Chain) - Keep, Keep);
end;

end.
