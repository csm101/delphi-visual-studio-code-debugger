program VmtProbe;

// Empirically locates the Delphi VMT metadata slot offsets by SEARCHING the
// -256..0 byte window in front of a live VMT for offsets that satisfy an
// identity predicate whose ground truth comes from the compiler, not from any
// vmt* constant.
//
// Ground truths used (all independent of System.pas's vmt* constants):
//   SelfPtr      Pointer(TClassRef) IS the VMT address.
//   ClassName    compile-time string literal.
//   Parent       Pointer(TParentClassRef) IS the parent VMT address.
//   TypeInfo     TypeInfo(TClassRef) compiler intrinsic (direct RTTI symbol
//                reference, never routed through the VMT).
//   InstanceSize offset of the last declared field + its size (compiler layout).
//   FieldTable   published-field count and first published-field name, both
//                declared in this source file.
//
// Every matching offset in the window is reported, not just the first.
//
// Usage: VmtProbe.exe [-q]
//   -q   omit the raw VMT window dumps

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.TypInfo;

const
  WINDOW_LO = -256;
  WINDOW_HI = 0;

type
  TProbePlain = class(TObject)
  public
    FA: NativeInt;
    FB: NativeInt;
  end;

  TProbePublished = class(TPersistent)
  published
    FChildA: TObject;
    FChildB: TObject;
  end;

  TOffsetList = TArray<Integer>;

  TSlotKind = (skSelfPtr, skClassName, skInstanceSize, skParent, skTypeInfo, skFieldTable);

  TSlotPredicate = reference to function(Probe: Pointer): Boolean;

  TClassUnderTest = record
    Ref:              TClass;
    Caption:          string;
    LiteralName:      string;
    ParentRef:        TClass;   // nil when the parent slot cannot be ground-truthed
    CompilerTypeInfo: Pointer;
    ExpectedSize:     Integer;
    SizeIsIndependent: Boolean;
    PublishedCount:   Integer;  // 0 when the class has no published fields
    FirstPublished:   AnsiString;
  end;

const
  SlotNames: array[TSlotKind] of string =
    ('SelfPtr', 'ClassName', 'InstanceSize', 'Parent(deref)', 'TypeInfo', 'FieldTable');

function BitnessTag: string;
begin
{$IFDEF WIN64}
  Result := 'dcc64';
{$ELSE}
  Result := 'dcc32';
{$ENDIF}
end;

function HexPtr(P: Pointer): string;
begin
  Result := IntToHex(NativeUInt(P), SizeOf(Pointer) * 2);
end;

function TryReadPointer(Addr: Pointer; out Value: Pointer): Boolean;
begin
  try
    Value := PPointer(Addr)^;
    Result := True;
  except
    Value := nil;
    Result := False;
  end;
end;

function TryReadWord(Addr: Pointer; out Value: Word): Boolean;
begin
  try
    Value := PWord(Addr)^;
    Result := True;
  except
    Value := 0;
    Result := False;
  end;
end;

function TryReadInt32(Addr: Pointer; out Value: Integer): Boolean;
begin
  try
    Value := PInteger(Addr)^;
    Result := True;
  except
    Value := 0;
    Result := False;
  end;
end;

function TryReadShortString(Addr: Pointer; out Value: AnsiString): Boolean;
begin
  Value := '';
  try
    var Len := PByte(Addr)^;
    if Len = 0 then
      Exit(False);
    SetLength(Value, Len);
    Move((PByte(Addr) + 1)^, Value[1], Len);
    Result := True;
  except
    Value := '';
    Result := False;
  end;
end;

function LooksLikeIdentifier(const S: AnsiString): Boolean;
begin
  if S = '' then
    Exit(False);
  for var I := 1 to Length(S) do
    if not CharInSet(Char(S[I]), ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) then
      Exit(False);
  Result := True;
end;

function ScanWindow(Vmt: Pointer; const Matches: TSlotPredicate): TOffsetList;
begin
  SetLength(Result, 0);
  for var Offset := WINDOW_LO to WINDOW_HI do begin
    if Matches(PByte(Vmt) + Offset) then begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Offset;
    end;
  end;
end;

function FormatOffsets(const Offsets: TOffsetList): string;
begin
  if Length(Offsets) = 0 then
    Exit('(none)');
  Result := '';
  for var Offset in Offsets do begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + IntToStr(Offset);
  end;
end;

function MatchesSelfPtr(Vmt: Pointer): TSlotPredicate;
begin
  Result :=
    function(Probe: Pointer): Boolean
    begin
      var Value: Pointer;
      Result := TryReadPointer(Probe, Value) and (Value = Vmt);
    end;
end;

function MatchesClassName(const LiteralName: string): TSlotPredicate;
begin
  Result :=
    function(Probe: Pointer): Boolean
    begin
      var Target: Pointer;
      if not TryReadPointer(Probe, Target) or (Target = nil) then
        Exit(False);
      var Text: AnsiString;
      if not TryReadShortString(Target, Text) then
        Exit(False);
      Result := string(Text) = LiteralName;
    end;
end;

function MatchesPointerValue(Expected: Pointer): TSlotPredicate;
begin
  Result :=
    function(Probe: Pointer): Boolean
    begin
      var Value: Pointer;
      Result := (Expected <> nil) and TryReadPointer(Probe, Value) and (Value = Expected);
    end;
end;

// The slot holds a pointer to a location that in turn holds Expected.
function MatchesIndirectPointerValue(Expected: Pointer): TSlotPredicate;
begin
  Result :=
    function(Probe: Pointer): Boolean
    begin
      var Value, Indirect: Pointer;
      if (Expected = nil) or not TryReadPointer(Probe, Value) or (Value = nil) then
        Exit(False);
      Result := TryReadPointer(Value, Indirect) and (Indirect = Expected);
    end;
end;

function MatchesInt32Value(Expected: Integer): TSlotPredicate;
begin
  Result :=
    function(Probe: Pointer): Boolean
    begin
      var Value: Integer;
      Result := TryReadInt32(Probe, Value) and (Value = Expected);
    end;
end;

// Published field table: Count(Word) + ClassTab(Pointer) header, then entries of
// Offset(UInt32) + TypeIndex(Word) + ShortString name -- exactly the layout
// TObject.FieldAddress walks in System.pas.
function MatchesFieldTable(ExpectedCount: Integer; const FirstName: AnsiString): TSlotPredicate;
begin
  Result :=
    function(Probe: Pointer): Boolean
    begin
      if ExpectedCount <= 0 then
        Exit(False);
      var Table: Pointer;
      if not TryReadPointer(Probe, Table) or (Table = nil) then
        Exit(False);
      var Count: Word;
      if not TryReadWord(Table, Count) or (Count <> ExpectedCount) then
        Exit(False);
      var FirstEntry := PByte(Table) + SizeOf(Word) + SizeOf(Pointer);
      var Name: AnsiString;
      if not TryReadShortString(FirstEntry + SizeOf(UInt32) + SizeOf(Word), Name) then
        Exit(False);
      Result := Name = FirstName;
    end;
end;

procedure ReportSlot(const SlotName, GroundTruth: string; const Offsets: TOffsetList);
begin
  Writeln(Format('    %-13s %-46s %s', [SlotName, GroundTruth, FormatOffsets(Offsets)]));
end;

function FirstOffsetOr(const Offsets: TOffsetList; Fallback: Integer): Integer;
begin
  if Length(Offsets) = 0 then
    Exit(Fallback);
  Result := Offsets[0];
end;

var
  SelfPtrOffsetOf: array of Integer;
  TypeInfoOffsetOf: array of Integer;
  InstanceSizeOffsetOf: array of Integer;
  SlotOffsetOf: array[TSlotKind] of array of Integer;

procedure RecordSlot(Slot: TSlotKind; Index: Integer; const Offsets: TOffsetList);
begin
  SlotOffsetOf[Slot][Index] := FirstOffsetOr(Offsets, MaxInt);
end;

function SlotOffsetText(Slot: TSlotKind; Index: Integer): string;
begin
  if SlotOffsetOf[Slot][Index] = MaxInt then
    Result := '  --'
  else
    Result := Format('%4d', [SlotOffsetOf[Slot][Index]]);
end;

procedure ProbeOne(const Subject: TClassUnderTest; Index: Integer);
begin
  var Vmt := Pointer(Subject.Ref);
  Writeln;
  Writeln(Format('  %s  (VMT at %s)', [Subject.Caption, HexPtr(Vmt)]));
  Writeln('    slot          ground truth                                   matching offsets');

  var SelfOffsets := ScanWindow(Vmt, MatchesSelfPtr(Vmt));
  ReportSlot('SelfPtr', 'value = Pointer(' + Subject.LiteralName + ')', SelfOffsets);
  SelfPtrOffsetOf[Index] := FirstOffsetOr(SelfOffsets, MaxInt);
  RecordSlot(skSelfPtr, Index, SelfOffsets);

  var NameOffsets := ScanWindow(Vmt, MatchesClassName(Subject.LiteralName));
  ReportSlot('ClassName', 'ShortString@value = ''' + Subject.LiteralName + '''', NameOffsets);
  RecordSlot(skClassName, Index, NameOffsets);

  var SizeNote := 'Int32 = ' + IntToStr(Subject.ExpectedSize);
  if Subject.SizeIsIndependent then
    SizeNote := SizeNote + ' (field layout)'
  else
    SizeNote := SizeNote + ' (InstanceSize, circular)';
  var SizeOffsets := ScanWindow(Vmt, MatchesInt32Value(Subject.ExpectedSize));
  ReportSlot('InstanceSize', SizeNote, SizeOffsets);
  InstanceSizeOffsetOf[Index] := FirstOffsetOr(SizeOffsets, MaxInt);
  RecordSlot(skInstanceSize, Index, SizeOffsets);

  if Subject.ParentRef <> nil then begin
    ReportSlot('Parent(direct)', 'value = Pointer(' + Subject.ParentRef.ClassName + ')',
      ScanWindow(Vmt, MatchesPointerValue(Pointer(Subject.ParentRef))));
    var ParentOffsets := ScanWindow(Vmt, MatchesIndirectPointerValue(Pointer(Subject.ParentRef)));
    ReportSlot('Parent(deref)', '^value = Pointer(' + Subject.ParentRef.ClassName + ')', ParentOffsets);
    RecordSlot(skParent, Index, ParentOffsets);
  end
  else
    ReportSlot('Parent', 'n/a (no parent)', nil);

  var TypeInfoOffsets := ScanWindow(Vmt, MatchesPointerValue(Subject.CompilerTypeInfo));
  ReportSlot('TypeInfo', 'value = TypeInfo(' + Subject.LiteralName + ') @ ' + HexPtr(Subject.CompilerTypeInfo),
    TypeInfoOffsets);
  TypeInfoOffsetOf[Index] := FirstOffsetOr(TypeInfoOffsets, MaxInt);
  RecordSlot(skTypeInfo, Index, TypeInfoOffsets);

  if Subject.PublishedCount > 0 then begin
    var FieldOffsets := ScanWindow(Vmt, MatchesFieldTable(Subject.PublishedCount, Subject.FirstPublished));
    ReportSlot('FieldTable', Format('count=%d, first=''%s''', [Subject.PublishedCount, string(Subject.FirstPublished)]),
      FieldOffsets);
    RecordSlot(skFieldTable, Index, FieldOffsets);
  end
  else
    ReportSlot('FieldTable', 'n/a (no published fields)', nil);

  // Cross-check: does the value the RTL itself exposes agree with the searched offset?
  Writeln(Format('    RTL says: ClassName=%s InstanceSize=%d ClassInfo=%s ClassParent=%s',
    [Subject.Ref.ClassName, Subject.Ref.InstanceSize, HexPtr(Subject.Ref.ClassInfo),
     HexPtr(Pointer(Subject.Ref.ClassParent))]));

  // Adjudicate the two candidate SelfPtr bases directly.
  const UnadjustedSelfPtr = {$IFDEF WIN64} -176 {$ELSE} -88 {$ENDIF};
  const AdjustedSelfPtr = UnadjustedSelfPtr - 3 * SizeOf(Pointer);
  var AtUnadjusted, AtAdjusted: Pointer;
  TryReadPointer(PByte(Vmt) + UnadjustedSelfPtr, AtUnadjusted);
  TryReadPointer(PByte(Vmt) + AdjustedSelfPtr, AtAdjusted);
  Writeln(Format('    SelfPtr candidates: [%d]=%s%s  [%d]=%s%s',
    [UnadjustedSelfPtr, HexPtr(AtUnadjusted), BoolToStr(AtUnadjusted = Vmt, True),
     AdjustedSelfPtr, HexPtr(AtAdjusted), BoolToStr(AtAdjusted = Vmt, True)]));

  // What the field-table slot actually contains for this class.
  // vmtFieldTable - vmtSelfPtr = 40 (x64) / 20 (x86), relative to the SelfPtr offset just discovered.
  const FieldTableFromSelfPtr = {$IFDEF WIN64} 40 {$ELSE} 20 {$ENDIF};
  var FieldTableSlot := PByte(Vmt) + SelfPtrOffsetOf[Index] + FieldTableFromSelfPtr;
  var TablePtr: Pointer;
  if TryReadPointer(FieldTableSlot, TablePtr) then begin
    var RawCount: Word := 0;
    if TablePtr <> nil then
      TryReadWord(TablePtr, RawCount);
    var Delta := NativeInt(TablePtr) - NativeInt(Vmt);
    var DeltaText := 'nil';
    if TablePtr <> nil then
      DeltaText := 'VMT + ' + IntToStr(Delta);
    Writeln(Format('    FieldTable slot value = %s (%s)  decoded count = %d',
      [HexPtr(TablePtr), DeltaText, RawCount]));
  end;
end;

procedure DumpWindow(const Subject: TClassUnderTest);
begin
  var Vmt := Pointer(Subject.Ref);
  Writeln;
  Writeln(Format('--- raw VMT window: %s at %s (%s) ---', [Subject.Caption, HexPtr(Vmt), BitnessTag]));
  var Offset := WINDOW_LO;
  while Offset < WINDOW_HI do begin
    var Slot := PByte(Vmt) + Offset;
    var Value: Pointer;
    if not TryReadPointer(Slot, Value) then begin
      Writeln(Format('  %5d  <unreadable>', [Offset]));
      Inc(Offset, SizeOf(Pointer));
      Continue;
    end;
    var Note := '';
    if Value = Vmt then
      Note := Note + ' SELF';
    if (Subject.CompilerTypeInfo <> nil) and (Value = Subject.CompilerTypeInfo) then
      Note := Note + ' TYPEINFO(compiler)';
    if (Subject.ParentRef <> nil) and (Value = Pointer(Subject.ParentRef)) then
      Note := Note + ' PARENT';
    var Text: AnsiString;
    if (Value <> nil) and TryReadShortString(Value, Text) and LooksLikeIdentifier(Text) then
      Note := Note + ' ->"' + string(Text) + '"';
    var AsInt: Integer;
    if TryReadInt32(Slot, AsInt) and (AsInt = Subject.ExpectedSize) then
      Note := Note + ' int32=' + IntToStr(AsInt) + '(=expected size)';
    Writeln(Format('  %5d  %s%s', [Offset, HexPtr(Value), Note]));
    Inc(Offset, SizeOf(Pointer));
  end;
end;

function BuildSubjects: TArray<TClassUnderTest>;
begin
  // Instance layout the compiler produced: VMT pointer, declared fields, then the
  // hidden monitor field (hfFieldSize = SizeOf(Pointer)) at the tail.
  var Plain := TProbePlain.Create;
  var PlainSize := Integer(NativeUInt(@Plain.FB) - NativeUInt(Plain)) + SizeOf(Plain.FB) + SizeOf(Pointer);
  Plain.Free;

  SetLength(Result, 5);

  Result[0].Ref               := TObject;
  Result[0].Caption           := 'TObject (System, root)';
  Result[0].LiteralName       := 'TObject';
  Result[0].ParentRef         := nil;
  Result[0].CompilerTypeInfo  := TypeInfo(TObject);
  Result[0].ExpectedSize      := SizeOf(Pointer) * 2;  // VMT pointer + hidden monitor field
  Result[0].SizeIsIndependent := True;
  Result[0].PublishedCount    := 0;

  Result[1].Ref               := TProbePlain;
  Result[1].Caption           := 'TProbePlain (plain user class)';
  Result[1].LiteralName       := 'TProbePlain';
  Result[1].ParentRef         := TObject;
  Result[1].CompilerTypeInfo  := TypeInfo(TProbePlain);
  Result[1].ExpectedSize      := PlainSize;
  Result[1].SizeIsIndependent := True;
  Result[1].PublishedCount    := 0;

  Result[2].Ref               := TProbePublished;
  Result[2].Caption           := 'TProbePublished (published fields)';
  Result[2].LiteralName       := 'TProbePublished';
  Result[2].ParentRef         := TPersistent;
  Result[2].CompilerTypeInfo  := TypeInfo(TProbePublished);
  Result[2].ExpectedSize      := TProbePublished.InstanceSize;
  Result[2].SizeIsIndependent := False;
  Result[2].PublishedCount    := 2;
  Result[2].FirstPublished    := 'FChildA';

  Result[3].Ref               := Exception;
  Result[3].Caption           := 'Exception (System.SysUtils, CPP_ABI candidate)';
  Result[3].LiteralName       := 'Exception';
  Result[3].ParentRef         := TObject;
  Result[3].CompilerTypeInfo  := TypeInfo(Exception);
  Result[3].ExpectedSize      := Exception.InstanceSize;
  Result[3].SizeIsIndependent := False;
  Result[3].PublishedCount    := 0;

  Result[4].Ref               := TStringList;
  Result[4].Caption           := 'TStringList (System.Classes)';
  Result[4].LiteralName       := 'TStringList';
  Result[4].ParentRef         := TStrings;
  Result[4].CompilerTypeInfo  := TypeInfo(TStringList);
  Result[4].ExpectedSize      := TStringList.InstanceSize;
  Result[4].SizeIsIndependent := False;
  Result[4].PublishedCount    := 0;
end;

procedure Main;
begin
  var Quiet := False;
  for var I := 1 to ParamCount do
    if SameText(ParamStr(I), '-q') then
      Quiet := True;

  Writeln('VmtProbe -- ', BitnessTag, ', SizeOf(Pointer)=', SizeOf(Pointer),
          ', window ', WINDOW_LO, '..', WINDOW_HI, ' scanned byte-by-byte');
  Writeln('CompilerVersion: ', Format('%.1f', [System.CompilerVersion]));

  var Subjects := BuildSubjects;
  SetLength(SelfPtrOffsetOf, Length(Subjects));
  SetLength(TypeInfoOffsetOf, Length(Subjects));
  SetLength(InstanceSizeOffsetOf, Length(Subjects));
  for var Slot := Low(TSlotKind) to High(TSlotKind) do begin
    SetLength(SlotOffsetOf[Slot], Length(Subjects));
    for var I := 0 to High(Subjects) do
      SlotOffsetOf[Slot][I] := MaxInt;
  end;

  for var I := 0 to High(Subjects) do
    ProbeOne(Subjects[I], I);

  Writeln;
  Writeln('=== consensus slot offsets, first match per class (', BitnessTag, ') ===');
  Write(Format('  %-14s', ['slot']));
  for var I := 0 to High(Subjects) do
    Write(Format(' %6s', [Copy(Subjects[I].LiteralName, 1, 6)]));
  Writeln('   verdict');
  for var Slot := Low(TSlotKind) to High(TSlotKind) do begin
    Write(Format('  %-14s', [SlotNames[Slot]]));
    var Consensus := MaxInt;
    var Conflict := False;
    for var I := 0 to High(Subjects) do begin
      Write(Format(' %6s', [SlotOffsetText(Slot, I)]));
      if SlotOffsetOf[Slot][I] = MaxInt then
        Continue;
      if Consensus = MaxInt then
        Consensus := SlotOffsetOf[Slot][I]
      else if Consensus <> SlotOffsetOf[Slot][I] then
        Conflict := True;
    end;
    if Conflict then
      Writeln('   CONFLICT')
    else if Consensus = MaxInt then
      Writeln('   no data')
    else
      Writeln(Format('   %d', [Consensus]));
  end;

  Writeln;
  Writeln('=== derived relationships (', BitnessTag, ') ===');
  for var I := 0 to High(Subjects) do begin
    if (SelfPtrOffsetOf[I] = MaxInt) or (TypeInfoOffsetOf[I] = MaxInt) then
      Continue;
    var SizeDelta := 'n/a';
    if InstanceSizeOffsetOf[I] <> MaxInt then
      SizeDelta := IntToStr(InstanceSizeOffsetOf[I] - TypeInfoOffsetOf[I]);
    Writeln(Format('  %-46s SelfPtr=%d TypeInfo=%d TypeInfo-SelfPtr=%d InstanceSize-TypeInfo=%s',
      [Subjects[I].Caption, SelfPtrOffsetOf[I], TypeInfoOffsetOf[I],
       TypeInfoOffsetOf[I] - SelfPtrOffsetOf[I], SizeDelta]));
  end;

  Writeln;
  Writeln('=== CPP_ABI shift check (SelfPtr offset relative to TProbePlain) ===');
  var BaseSelf := SelfPtrOffsetOf[1];
  for var I := 0 to High(Subjects) do begin
    if SelfPtrOffsetOf[I] = MaxInt then
      Continue;
    Writeln(Format('  %-46s shift = %d', [Subjects[I].Caption, BaseSelf - SelfPtrOffsetOf[I]]));
  end;
  Writeln('  (System.pas formula would give CPP_ABI_ADJUST = 3 * SizeOf(Pointer) = ',
    3 * SizeOf(Pointer), ')');

  if not Quiet then begin
    DumpWindow(Subjects[1]);
    DumpWindow(Subjects[3]);
  end;
end;

begin
  try
    Main;
  except
    on E: Exception do begin
      Writeln('FATAL ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
