program IntfTableProbe;

// Locates the Delphi VMT interface-table slot and the TInterfaceEntry layout by
// SEARCHING the window in front of a live VMT for an offset satisfying an
// identity predicate, in the same style as VmtProbe -- ground truth from the
// compiler, never from a vmt* constant of our own.
//
// Why this is needed: recovering the OBJECT behind an interface reference is
// currently done by walking backwards until a candidate looks right. The exact
// answer is in the class's interface table, which records, per implemented
// interface, the byte offset of the hidden field holding its method-table
// pointer. Object = InterfaceRef - IOffset, with nothing to guess.
//
// Ground truths used:
//   IntfTable   TMyClass.GetInterfaceTable IS the table address (RTL intrinsic,
//               not our constant).
//   IOffset     PByte(IntfRef) - PByte(Obj) for a live instance, computed from
//               the two pointers the compiler itself produced.
//
// Build BOTH bitnesses -- the answer differs and that is the point:
//   DevTools\build_one.bat   IntfTableProbe     (64-bit)
//   DevTools\build_one32.bat IntfTableProbe     (32-bit)

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

const
  WINDOW_LO = -256;
  WINDOW_HI = 0;

type
  IProbeOne = interface
    ['{7A1C4E20-9B3D-4F51-8C62-1D0E5A937B44}']
    procedure DoOne;
  end;

  IProbeTwo = interface
    ['{2F8B6C31-4D57-49AE-93F0-6C21B8E45A07}']
    procedure DoTwo;
  end;

  // Two interfaces and a leading field, so the two IOffsets differ from each
  // other AND from zero -- an entry layout that is decoded wrongly cannot then
  // accidentally produce the right answer.
  TProbeImpl = class(TInterfacedObject, IProbeOne, IProbeTwo)
  public
    FLead: array[0..3] of NativeInt;
    procedure DoOne;
    procedure DoTwo;
  end;

procedure TProbeImpl.DoOne;
begin
end;

procedure TProbeImpl.DoTwo;
begin
end;

function HexPtr(P: Pointer): string;
begin
  Result := Format('$%p', [P]);
end;

// Every offset in the window whose slot holds Wanted.
function OffsetsHolding(Vmt: Pointer; Wanted: Pointer): TArray<Integer>;
begin
  SetLength(Result, 0);
  var Step := SizeOf(Pointer);
  var Off := WINDOW_LO;
  while Off <= WINDOW_HI - Step do begin
    var Slot := PPointer(PByte(Vmt) + Off)^;
    if Slot = Wanted then
      Result := Result + [Off];
    Inc(Off, Step);
  end;
end;

function FormatOffsets(const Offsets: TArray<Integer>): string;
begin
  if Length(Offsets) = 0 then
    Exit('(none)');
  Result := '';
  for var O in Offsets do
    Result := Result + IntToStr(O) + ' ';
  Result := Trim(Result);
end;

begin
  try
    Writeln(Format('IntfTableProbe  pointer size = %d', [SizeOf(Pointer)]));

    var Impl := TProbeImpl.Create;
    var One:  IProbeOne := Impl;
    var Two:  IProbeTwo := Impl;

    var ObjAddr  := PByte(Impl);
    var OneDelta := PByte(Pointer(One)) - ObjAddr;
    var TwoDelta := PByte(Pointer(Two)) - ObjAddr;
    Writeln(Format('  object=%s  IProbeOne at +%d   IProbeTwo at +%d',
      [HexPtr(Impl), OneDelta, TwoDelta]));

    // Ground truth for the table address, straight from the RTL.
    var Table := TProbeImpl.GetInterfaceTable;
    Writeln(Format('  GetInterfaceTable = %s', [HexPtr(Table)]));

    var Vmt := Pointer(TProbeImpl);
    Writeln(Format('  VMT = %s', [HexPtr(Vmt)]));
    Writeln(Format('    IntfTable slot offsets: %s',
      [FormatOffsets(OffsetsHolding(Vmt, Table))]));

    // Decode the table with NO assumed entry size: find, for each interface,
    // the byte offset within the table at which its known IOffset appears as a
    // 4-byte value, and report the stride that implies.
    if Table <> nil then begin
      var Count := PInteger(Table)^;
      Writeln(Format('    EntryCount = %d', [Count]));
      if (Count > 0) and (Count < 64) then begin
        var Bytes := PByte(Table);
        // Search a generous span after the count for the two known IOffsets.
        for var Target in [OneDelta, TwoDelta] do begin
          var Found := '';
          for var At := 4 to 4 + Count * 64 do
            if PInteger(Bytes + At)^ = Target then
              Found := Found + IntToStr(At) + ' ';
          Writeln(Format('    IOffset %-4d appears at table byte offsets: %s',
            [Target, Trim(Found)]));
        end;
        Writeln(Format('    sizeof(TGUID)=%d sizeof(Pointer)=%d',
          [SizeOf(TGUID), SizeOf(Pointer)]));
      end;
    end;

    One := nil;
    Two := nil;
  except
    on E: Exception do begin
      Writeln('EXCEPTION ' + E.ClassName + ': ' + E.Message);
      Halt(1);
    end;
  end;
end.
