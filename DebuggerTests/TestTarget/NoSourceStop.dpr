program NoSourceStop;

// A target that stops where there is NO SOURCE to open, so the client-side
// behaviour can be observed instead of assumed.
//
// The open question it exists to answer (see KNOWN_UNKNOWNS.md): now that the
// adapter declares supportsDisassembleRequest and every frame carries
// instructionPointerReference, does VS Code open the Disassembly View by itself
// when a stop has no source -- and does the adapter's placeholder source
// document PREVENT it from doing so, by making the frame look as though source
// exists?
//
// Separate target on purpose. Adding scenarios to TestTarget shifts RSM per-unit
// import indices and perturbs first-hit marker ordering, which has broken
// unrelated tests before (see TRAPS.md, "Fixture design").
//
// Built with -$O- -V -VN like the other fixtures, so THIS program has full debug
// info. That is deliberate: the faulting frame must be the one without source,
// while the frames below it are ours and resolve normally. A stack that is
// unreadable end to end would not distinguish "the client opened disassembly"
// from "the client gave up".

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils;

// Faults INSIDE the RTL: System.Move dereferences the source pointer. The
// shipped RTL DCUs carry no line information, so the top frame typically
// resolves to a name from the MAP and to no source file.
procedure FaultInsideRtl;
var
  Dest: array[0..15] of Byte;
begin
  Move(PByte(nil)^, Dest[0], Length(Dest));
end;

// Faults INSIDE an OS module. RtlMoveMemory copies without validating, and
// unlike the Win32 string helpers it carries no internal SEH guard, so a bogus
// source pointer faults in ntdll -- where there is no debug info at all, exports
// only. This is the harder and more interesting case of the two.
//
// MEASURED, and the reason this is not lstrlenW: lstrlenW is SEH-wrapped inside
// kernel32 on current Windows and simply returns 0 for a bad pointer, so the
// first version of this fixture never faulted at all.
procedure RtlMoveMemory(Dest: Pointer; Src: Pointer; Count: NativeUInt); stdcall;
  external 'ntdll.dll' name 'RtlMoveMemory';

procedure FaultInsideOsCode;
var
  Dest: array[0..15] of Byte;
begin
  RtlMoveMemory(@Dest[0], Pointer($1), Length(Dest));
end;

procedure Usage;
begin
  Writeln('NoSourceStop -- stops where no source exists, to observe what the client does.');
  Writeln;
  Writeln('  NoSourceStop -rtl   access violation inside System.Move (RTL, no line info)');
  Writeln('  NoSourceStop -os    access violation inside kernel32 (no debug info at all)');
  Writeln;
  Writeln('Run it under the debugger and let the exception reach the debugger.');
end;

begin
  if ParamCount = 0 then begin
    Usage;
    Halt(1);
  end;

  if SameText(ParamStr(1), '-rtl') then begin
    Writeln('faulting inside the RTL...');
    FaultInsideRtl;
  end else if SameText(ParamStr(1), '-os') then begin
    Writeln('faulting inside OS code...');
    FaultInsideOsCode;
  end else begin
    Usage;
    Halt(1);
  end;

  Writeln('did not fault -- nothing to observe');
end.
