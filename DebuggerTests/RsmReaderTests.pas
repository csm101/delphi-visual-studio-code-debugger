unit RsmReaderTests;

// Low-level unit tests for byte-level RSM parsing helpers exposed by
// TRsmFile. Lets us cover compiler-internal record shapes (e.g. the
// `$08 hashLo hashHi <suffix> $FF` variant produced by big VCL classes)
// without having to convince the Delphi compiler to emit that exact
// shape inside the integration TestTarget.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TRsmReaderTests = class
  public
    [Test]
    procedure DecodeClassMemberHash_CompactTrailer;
    [Test]
    procedure DecodeClassMemberHash_SuffixBeforeFF;
    [Test]
    procedure DecodeClassMemberHash_NoAnchor;
    [Test]
    procedure DecodeClassMemberHash_StrayEarly08Ignored;

    // The SampleApp-style user-type table is a sequence of TTypeInfo records
    // each starting with the 8-byte `$08 00 00 00 00 00 00 00` marker.
    // Names must be returned in file order so the existing TypeId-by-index
    // formula (TypeId = (idx + 1) * 2) keeps working.
    [Test]
    procedure ExtractTypeInfoNames_ReturnsNamesInFileOrder;
    [Test]
    procedure ExtractTypeInfoNames_IgnoresInvalidRecords;
    [Test]
    procedure ExtractTypeInfoNames_EmptyBufferYieldsEmptyArray;

    [Test]
    procedure FindUserTypeTableAnchor_LocatesAfterSystem;
    [Test]
    procedure FindUserTypeTableAnchor_AbsentReturnsFalse;

    // Repro for the Debugme.dpr TFoo regression: a class declared with
    // ALL members (fields and constructor) under a single `private`
    // section emits a $2A type-decl record whose trailer does not carry
    // the $1E / $1F / $00 flag bytes recognised by
    // ParseTypeDeclarationSection. The class must still appear in
    // FClassMembers so the variables view can expand it.
    [Test]
    procedure ParseTypeDecl_AllPrivateClassIsParsed;
    // Same scenario as above but anchored on Debugme.dpr's TFoo, whose
    // RSM record ends with a hash byte $17 (not the $1E/$1F flag the
    // historic parser anchored on). The test depends on Debugme having
    // been built; if its .rsm is missing it asks for a rebuild rather
    // than silently passing.
    [Test]
    procedure ParseTypeDecl_DebugmeTFooIsParsed;
    // Repro for the "record-member skipped because preceding $31 record
    // had bogus RecLen" bug: TPoint3D in Debugme.dpr lost its X field
    // because a stray `$pdata$_ZN7Debugme12Finali...` blob earlier in
    // the file tag-shaped as a property record with NameLen=50, and the
    // parser unconditionally advanced by FindRecordEnd's RecLen (211)
    // over X. Must return X / Y / Z in offset order with offset 0 / 8 /
    // 16.
    [Test]
    procedure ParseClassMembers_TPoint3D_HasAllThreeFields;

    // Regression for the "class-typed field shows empty TypeName" bug.
    // `Exception.FInnerException : Exception` carries a 2-byte ODD VLE
    // TypeId equal to the trailer hash of the matching `$2A` class
    // declaration, not its declaration TypeId. `LookupTypeName` must
    // consult `FClassHashCandidates` for odd TypeIds it cannot resolve
    // via the user-type table, otherwise `Obj.FInnerException` shows
    // no type and the variables view collapses.
    [Test]
    procedure ClassTypedField_ResolvesViaClassHashCandidates;

    // Regression for the SampleApp "TApplication shows 452 members / FOwnsObjects
    // leaks in" bug. Class-member records are grouped only by the LOW 16 BITS
    // of the owning class's TypeId. On a > 65536-type target two unrelated
    // classes collide on that key, so the member list mixes in foreign fields
    // (TObjectList.FOwnsObjects, PICTDESC.cbSizeofstruct, ...) and inspecting
    // a global like Application renders garbage. The fix scopes members to the
    // class's own unit. These cover the exact decision DecodeClassMembers uses.
    [Test]
    procedure MemberUnitFilter_DropsForeignUnitOnHashCollision;
    [Test]
    procedure OwningUnitDisambiguatesCollidingMembers;

    // Regression for SampleApp "TApplication.HintColor shows as a getter that
    // can't be evaluated". `HintColor read FHintColor` is field-backed, but
    // the field record's hash marker is `9C 17 ...` (tag $17, not the $09/$01
    // the decoder accepted), so ClassMember_TryDecode rejected FHintColor, the
    // property could not bind to its backing field, and it fell through to a
    // (failing) synthetic getter call. The decoder must accept the marker
    // regardless of the tag byte.
    [Test]
    procedure ClassMember_FieldWith9C17Marker_Decodes;

    // Cross-unit same-binary disambiguation (feature "a"). SharedConflictProc is
    // declared in BOTH TestTargetConflict1 and ...2 with a unit-distinct local
    // (Marker1 / Marker2). The name-keyed FProcOffsets is last-wins, so a plain
    // by-name lookup is ambiguous; only GetLocalsForFunctionInUnit can pick the
    // right unit's copy. Also covers NameCollidesAcrossUnits' gate.
    [Test]
    procedure UnitScopedLocals_PicksRightUnitForCollidingProc;

    // Regression for the RSM $2C field-offset decode. The offset uses the
    // same LSB-VLE as local offsets: 1-byte (value*2, offset <= 127) or
    // 2-byte (LSB set, value = int16 >> 2) for larger offsets. The decoder
    // read a single byte and did `div 2`, truncating any field beyond
    // offset 127. TWideFields.FTailA / FTailB live at offset 256 / 260.
    [Test]
    procedure ParseClassMembers_WideFieldOffsetDecoded;

    // F14 regression: WaitForIndex must NOT block the caller (the debugger's
    // dispatch/pump thread when loading symbols synchronously) for long while a
    // module's background index is still building. A fresh, never-loaded reader
    // has FIndexReady=False forever, so WaitForIndex is forced to hit its budget;
    // it must return within (a small multiple of) IndexWaitBudgetMs, not the old
    // 60 s cap that made a form-open freeze the MCP server for minutes.
    [Test]
    procedure WaitForIndex_ReturnsWithinBudget_WhenIndexNeverReady;

    // The cold index build must be REPRODUCIBLE. It used to fan every phase
    // out in one wave, so the two consumer phases (ScanForProcOffsets ->
    // TryParseGlobalAt and CollectMainBlockLocals) resolved type hints against
    // dictionaries the producer phases were still filling. Three consecutive
    // cold builds of the same TestTarget.rsm produced three different sidecars
    // (699427 / 699421 / 699428 bytes), each missing a different subset of the
    // resolved type hints -- and that degraded index is what got cached in the
    // .idx and reused for every later session. Producers and consumers now run
    // in two waves, so the sidecar is identical run to run.
    [Test]
    procedure IndexBuild_SidecarIsReproducible;

    // WaitForIndex must REPORT whether it actually got a ready index. Callers
    // that cache a result derived from the index (GetLocalsForFunction pins
    // parsed locals in FProcLocals for the rest of the session) need to know the
    // difference between "ready" and "gave up": a result parsed against a
    // half-built index has blank or wrong type hints, and pinning it turns a
    // transient shortage into a permanent wrong answer.
    [Test]
    procedure WaitForIndex_ReportsWhetherIndexWasReady;

    // The interactive deadline must be PER THREAD. As a process-wide class var,
    // the dispatch thread's 3 s stop budget was visible to every other thread:
    // a background symbol load would abandon its own index build the moment the
    // UI armed a budget, and would clear that budget when its own scope ended --
    // disarming the F14 protection in the middle of a stop.
    [Test]
    procedure InteractiveDeadline_IsPerThread;

    // A sidecar string longer than 64 KB used to be written with a TRUNCATED
    // 16-bit length: the writer emitted more bytes than the length it had just
    // written, so the reader resynchronised at the wrong offset and every later
    // field decoded as garbage -- undetectably, because the magic still matched
    // and the file still parsed. Long strings now carry an escape prefix.
    [Test]
    procedure Sidecar_LongString_RoundTripsWithoutDesync;

    // Two writers racing to publish the same sidecar. The loser used to DELETE
    // the winner's complete file, and when that delete failed too (the file was
    // open) the exception escaped the index thread, so FIndexReady was never set
    // and every later WaitForIndex burned its full 60 s budget. DevTools\
    // PrebuildIdx running while a debug session is live hits exactly this.
    [Test]
    procedure Sidecar_PublishRace_LeavesTheOtherWritersFileIntact;

    // A corrupt / truncated sidecar must be REJECTED wholesale and the index
    // rebuilt from the source, never half-read: a partially decoded index looks
    // like a complete one to every caller.
    [Test]
    procedure Sidecar_Corrupt_IsRejectedAndRebuilt;
    [Test]
    procedure SidecarIsUsable_RejectsForeignMagicEvenWhenNewer;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Generics.Collections,
  System.IOUtils,
  System.DateUtils,
  System.Hash,
  RsmFileReader,
  RsmDecoders,
  DebugInfoTypes;

procedure TRsmReaderTests.DecodeClassMemberHash_CompactTrailer;
// `$2C $0D "TimerMessaggi" 00 0A 00 68 C1 20 9C 01 91 1B 07 00 00 08 2D 02 FF`
// Class hash = $022D (Word LE of $2D $02 immediately after the $08 anchor).
var
  Buf: TBytes;
  Hash: Word;
begin
  Buf := TBytes.Create(
    $2C, $0D,
    Ord('T'), Ord('i'), Ord('m'), Ord('e'), Ord('r'), Ord('M'), Ord('e'),
    Ord('s'), Ord('s'), Ord('a'), Ord('g'), Ord('g'), Ord('i'),
    $00, $0A, $00, $68, $C1, $20, $9C, $01, $91, $1B, $07, $00, $00,
    $08, $2D, $02,
    $FF);
  Assert.IsTrue(
    TRsmFile.DecodeClassMemberHash(@Buf[0], 0, Length(Buf), Hash),
    'compact trailer should decode');
  Assert.AreEqual(Word($022D), Hash, 'hash should be $022D');
end;

procedure TRsmReaderTests.DecodeClassMemberHash_SuffixBeforeFF;
// `$2C $13 "FLicenzaDgMessenger" 00 00 00 06 89 29 9C 01 A1 1D 07 00 00 08 2D 02 09 A1 1D 3A FF`
// Same `$08 $2D $02` anchor but with 5 extra suffix bytes before `$FF`.
// The earlier "walk back at most 4 bytes from $FF" rule missed this and
// silently dropped the field's class-membership association on big
// SampleApp-style VCL forms.
var
  Buf: TBytes;
  Hash: Word;
begin
  Buf := TBytes.Create(
    $2C, $13,
    Ord('F'), Ord('L'), Ord('i'), Ord('c'), Ord('e'), Ord('n'), Ord('z'),
    Ord('a'), Ord('D'), Ord('g'), Ord('M'), Ord('e'), Ord('s'), Ord('s'),
    Ord('e'), Ord('n'), Ord('g'), Ord('e'), Ord('r'),
    $00, $00, $00, $06, $89, $29, $9C, $01, $A1, $1D, $07, $00, $00,
    $08, $2D, $02,
    $09, $A1, $1D, $3A,
    $FF);
  Assert.IsTrue(
    TRsmFile.DecodeClassMemberHash(@Buf[0], 0, Length(Buf), Hash),
    'suffixed trailer should still decode');
  Assert.AreEqual(Word($022D), Hash,
    'hash should be $022D regardless of suffix bytes');
end;

procedure TRsmReaderTests.DecodeClassMemberHash_StrayEarly08Ignored;
// Some class-member records carry an internal `$08` byte inside their
// kind-data trailer (e.g. Debugme TFoo's `Value` field, which has
// `08 20 9C 09 F1 1E 0D 04 01 F1 1E 07 00 00 08 7D 1C FF`). The
// class-hash anchor is the LAST `$08` before `$FF`, not the first; a
// forward-scanner that stopped on the first hit would yield $9C20 for
// this record instead of the correct $1C7D and the field would never
// associate with TFoo.
var
  Buf: TBytes;
  Hash: Word;
begin
  Buf := TBytes.Create(
    $2C, $05, Ord('V'), Ord('a'), Ord('l'), Ord('u'), Ord('e'),
    $00, $00, $00,
    $08, $20, $9C, $09, $F1, $1E, $0D, $04, $01, $F1, $1E, $07, $00, $00,
    $08, $7D, $1C,
    $FF);
  Assert.IsTrue(
    TRsmFile.DecodeClassMemberHash(@Buf[0], 0, Length(Buf), Hash),
    'last $08 anchor before $FF must be used');
  Assert.AreEqual(Word($1C7D), Hash, 'hash should be $1C7D (last $08 anchor)');
end;

procedure TRsmReaderTests.DecodeClassMemberHash_NoAnchor;
// A malformed record without the `$08` anchor must return False rather
// than picking up garbage as a hash.
var
  Buf: TBytes;
  Hash: Word;
begin
  Buf := TBytes.Create(
    $2C, $03, Ord('a'), Ord('b'), Ord('c'),
    $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00,
    $FF);
  Assert.IsFalse(
    TRsmFile.DecodeClassMemberHash(@Buf[0], 0, Length(Buf), Hash),
    'absence of $08 anchor should yield False');
end;

procedure TRsmReaderTests.ExtractTypeInfoNames_ReturnsNamesInFileOrder;
// Three back-to-back TTypeInfo records: AnsiChar (tkChar), Char (tkWChar),
// ShortInt (tkInteger). Each record has the 8-byte zero-prefixed marker
// followed by Kind + NameLen + name bytes, then kind-specific TypeData and
// inter-record padding (`02 00`).
var
  Buf: TBytes;
  Names: TArray<string>;
begin
  Buf := TBytes.Create(
    // AnsiChar
    $08, $00, $00, $00, $00, $00, $00, $00,
    $02, $08, Ord('A'), Ord('n'), Ord('s'), Ord('i'),
              Ord('C'), Ord('h'), Ord('a'), Ord('r'),
    $01, $00, $00, $00, $00, $FF, $00, $00, $00,
    $02, $00, // inter-record padding
    // Char
    $08, $00, $00, $00, $00, $00, $00, $00,
    $09, $04, Ord('C'), Ord('h'), Ord('a'), Ord('r'),
    $03, $00, $00, $00, $00, $FF, $FF, $00, $00,
    $02, $00,
    // ShortInt
    $08, $00, $00, $00, $00, $00, $00, $00,
    $01, $08, Ord('S'), Ord('h'), Ord('o'), Ord('r'),
              Ord('t'), Ord('I'), Ord('n'), Ord('t'),
    $00, $80, $FF, $FF, $FF, $7F, $00, $00
  );
  Names := TRsmFile.ExtractTypeInfoNames(@Buf[0], Length(Buf));
  Assert.AreEqual<Integer>(3, Length(Names),
    'expected three sequential TypeInfo names');
  Assert.AreEqual('AnsiChar', Names[0]);
  Assert.AreEqual('Char',     Names[1]);
  Assert.AreEqual('ShortInt', Names[2]);
end;

procedure TRsmReaderTests.ExtractTypeInfoNames_IgnoresInvalidRecords;
// `$08 $00 ...` patterns that come from kind-data bytes or have garbage
// after the marker must not be picked up as type entries.
var
  Buf: TBytes;
  Names: TArray<string>;
begin
  Buf := TBytes.Create(
    // Valid record: "OK"
    $08, $00, $00, $00, $00, $00, $00, $00,
    $02, $02, Ord('O'), Ord('K'),
    $01, $00, $00, $00, $00, $FF,
    // Junk that contains an 8-byte zero run but no valid Kind/Name
    $08, $00, $00, $00, $00, $00, $00, $00,
    $00,                       // Kind = 0 -> invalid
    $00,                       // NameLen = 0 -> invalid
    $20, $21, $22,
    // Junk: valid Kind but name with control bytes
    $08, $00, $00, $00, $00, $00, $00, $00,
    $02, $04, $01, $02, $03, $04  // non-ASCII bytes -> reject
  );
  Names := TRsmFile.ExtractTypeInfoNames(@Buf[0], Length(Buf));
  Assert.AreEqual<Integer>(1, Length(Names), 'only the valid record should survive');
  Assert.AreEqual('OK', Names[0]);
end;

procedure TRsmReaderTests.ExtractTypeInfoNames_EmptyBufferYieldsEmptyArray;
var
  Names: TArray<string>;
begin
  Names := TRsmFile.ExtractTypeInfoNames(nil, 0);
  Assert.AreEqual<Integer>(0, Length(Names));
end;

procedure TRsmReaderTests.FindUserTypeTableAnchor_LocatesAfterSystem;
// The user-type table is preceded by the ShortString sequence
// `\05False \04True \06System`. FindUserTypeTableAnchor returns the
// position immediately AFTER `\06System` so the caller can start
// scanning TypeInfo records right at the table head.
var
  Buf: TBytes;
  EndOff: Int64;
begin
  Buf := TBytes.Create(
    $AA, $BB, $CC, // preamble noise
    $05, Ord('F'), Ord('a'), Ord('l'), Ord('s'), Ord('e'),
    $04, Ord('T'), Ord('r'), Ord('u'), Ord('e'),
    $06, Ord('S'), Ord('y'), Ord('s'), Ord('t'), Ord('e'), Ord('m'),
    $11, $22, $33 // body that follows the anchor
  );
  Assert.IsTrue(
    TRsmFile.FindUserTypeTableAnchor(@Buf[0], Length(Buf), EndOff),
    'anchor must be located');
  Assert.AreEqual<Int64>(3 + 18, EndOff,
    'EndOff points to first byte AFTER \06System');
end;

procedure TRsmReaderTests.FindUserTypeTableAnchor_AbsentReturnsFalse;
var
  Buf: TBytes;
  EndOff: Int64;
begin
  Buf := TBytes.Create($00, $01, $02, $03, $04, $05);
  Assert.IsFalse(
    TRsmFile.FindUserTypeTableAnchor(@Buf[0], Length(Buf), EndOff),
    'missing anchor must yield False');
end;

procedure TRsmReaderTests.ParseTypeDecl_AllPrivateClassIsParsed;
var
  Rsm:    TRsmFile;
  Members: TArray<TClassMember>;
  RsmPath: string;
  HasName, HasValue: Boolean;
begin
  // Load the freshly-built TestTarget RSM (sibling of the test runner)
  // and assert that TBareClass made it into the class-member table. The
  // class is the verbatim transcription of Debugme.dpr's TFoo: a single
  // `private` section listing fields + constructor.
  RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
  if not FileExists(RsmPath) then
    Assert.Fail('TestTarget.rsm not found at ' + RsmPath +
                ' -- run build_target.bat first');
  Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);
    Assert.IsTrue(Rsm.GetClassMembers('TBareClass', Members),
      'TBareClass was dropped from the class-member table ' +
      '(all-private $2A trailer variant not recognised)');
    HasName  := False;
    HasValue := False;
    for var M in Members do begin
      if SameText(M.Name, 'Name')  then HasName  := True;
      if SameText(M.Name, 'Value') then HasValue := True;
    end;
    Assert.IsTrue(HasName,  'private field "Name" missing from TBareClass members');
    Assert.IsTrue(HasValue, 'private field "Value" missing from TBareClass members');
  finally
    Rsm.Free;
  end;
end;

procedure TRsmReaderTests.ParseTypeDecl_DebugmeTFooIsParsed;
var
  Rsm:     TRsmFile;
  Members: TArray<TClassMember>;
  RsmPath: string;
begin
  RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\..\samples\Debugme\Win64\Debug\Debugme.rsm';
  if not FileExists(RsmPath) then
    Assert.Fail('Debugme.rsm not found at ' + RsmPath +
                ' -- run scripts/build_debug.bat first');
  Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);
    Assert.IsTrue(Rsm.GetClassMembers('TFoo', Members),
      'Debugme TFoo dropped from class-member table (regression)');
    Assert.IsTrue(Length(Members) >= 4,
      Format('TFoo should expose at least 4 members, got %d', [Length(Members)]));
  finally
    Rsm.Free;
  end;
end;

procedure TRsmReaderTests.ParseClassMembers_TPoint3D_HasAllThreeFields;
var
  Rsm:     TRsmFile;
  Members: TArray<TClassMember>;
  RsmPath: string;
  XMem, YMem, ZMem: TClassMember;
  HasX, HasY, HasZ: Boolean;
begin
  // Loads the freshly-built Debugme.rsm because Debugme's `$pdata$...`
  // symbols (large compile output for Win64 unwind tables) are what
  // trip the scanner -- TestTarget.rsm doesn't have a record at the
  // same relative position so its TPoint3D parses even with the bug.
  RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\..\samples\Debugme\Win64\Debug\Debugme.rsm';
  if not FileExists(RsmPath) then
    Assert.Fail('Debugme.rsm missing -- run scripts/build_debug.bat first');
  Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);
    Assert.IsTrue(Rsm.GetClassMembers('TPoint3D', Members),
      'TPoint3D dropped from class table');
    HasX := False; HasY := False; HasZ := False;
    for var M in Members do begin
      if SameText(M.Name, 'X') then begin HasX := True; XMem := M; end;
      if SameText(M.Name, 'Y') then begin HasY := True; YMem := M; end;
      if SameText(M.Name, 'Z') then begin HasZ := True; ZMem := M; end;
    end;
    Assert.IsTrue(HasX, 'TPoint3D.X missing');
    Assert.IsTrue(HasY, 'TPoint3D.Y missing');
    Assert.IsTrue(HasZ, 'TPoint3D.Z missing');
    Assert.AreEqual<Integer>(0,  XMem.FieldOffset, 'X offset must be 0');
    Assert.AreEqual<Integer>(8,  YMem.FieldOffset, 'Y offset must be 8');
    Assert.AreEqual<Integer>(16, ZMem.FieldOffset, 'Z offset must be 16');
  finally
    Rsm.Free;
  end;
end;

procedure TRsmReaderTests.ClassTypedField_ResolvesViaClassHashCandidates;
var
  Rsm:     TRsmFile;
  Members: TArray<TClassMember>;
  RsmPath: string;
  FoundField, FoundMsg: Boolean;
  FieldType, MsgType:   string;
begin
  RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
  if not FileExists(RsmPath) then
    Assert.Fail('TestTarget.rsm not found at ' + RsmPath +
                ' -- run build_target.bat first');
  Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);
    Assert.IsTrue(Rsm.GetClassMembers('Exception', Members),
      'Exception class must be in the class-member table');
    FoundField := False; FoundMsg := False;
    for var M in Members do begin
      if (M.Kind = cmkField) and SameText(M.Name, 'FInnerException') then begin
        FoundField := True;
        FieldType  := M.TypeName;
      end;
      if (M.Kind = cmkField) and SameText(M.Name, 'FMessage') then begin
        FoundMsg  := True;
        MsgType   := M.TypeName;
      end;
    end;
    Assert.IsTrue(FoundField, 'Exception.FInnerException missing from members');
    Assert.AreEqual('Exception', FieldType,
      'FInnerException must resolve to Exception via FClassHashCandidates fallback');
    Assert.IsTrue(FoundMsg, 'Exception.FMessage missing');
    Assert.AreEqual('UnicodeString', MsgType,
      'FMessage must resolve via per-unit imports');
  finally
    Rsm.Free;
  end;
end;

procedure TRsmReaderTests.MemberUnitFilter_DropsForeignUnitOnHashCollision;
begin
  // TApplication (Vcl.Forms) and TObjectList (System.Generics.Collections)
  // share a class-member hash bucket on a > 65536-type target. The owning-unit
  // check must drop the cross-unit member while keeping same-unit ones.
  Assert.IsFalse(
    MemberMatchesClassUnit('Vcl.Forms', 'System.Generics.Collections'),
    'foreign-unit member must be dropped');
  Assert.IsTrue(
    MemberMatchesClassUnit('Vcl.Forms', 'vcl.forms'),
    'same unit (case-insensitive) must be kept');
  // Conservative: unknown unit on either side keeps the member, so incomplete
  // anchor coverage never hides a real member.
  Assert.IsTrue(
    MemberMatchesClassUnit('', 'System.Generics.Collections'),
    'unknown class unit keeps member');
  Assert.IsTrue(
    MemberMatchesClassUnit('Vcl.Forms', ''),
    'unknown member unit keeps member');
end;

procedure TRsmReaderTests.OwningUnitDisambiguatesCollidingMembers;
var
  Anchors: TList<TPair<Int64, string>>;
begin
  // Anchors split the RSM into two unit sections:
  //   [100, 200) -> Vcl.Forms                    (TApplication + its members)
  //   [200, ...) -> System.Generics.Collections  (TObjectList + its members)
  // A record at offset 250 only lands in TApplication's bucket because of the
  // low-16 collision; its owning unit exposes it as foreign.
  Anchors := TList<TPair<Int64, string>>.Create;
  try
    Anchors.Add(TPair<Int64, string>.Create(100, 'Vcl.Forms'));
    Anchors.Add(TPair<Int64, string>.Create(200, 'System.Generics.Collections'));

    var ClassUnit     := FindOwningUnit(Anchors, 120); // TApplication decl
    var OwnMember      := FindOwningUnit(Anchors, 150); // real TApplication member
    var ForeignMember  := FindOwningUnit(Anchors, 250); // colliding TObjectList member

    Assert.AreEqual('Vcl.Forms', ClassUnit, 'class unit resolved from decl offset');
    Assert.IsTrue(MemberMatchesClassUnit(ClassUnit, OwnMember),
      'same-unit member kept');
    Assert.IsFalse(MemberMatchesClassUnit(ClassUnit, ForeignMember),
      'colliding cross-unit member dropped');
  finally
    Anchors.Free;
  end;
end;

procedure TRsmReaderTests.ClassMember_FieldWith9C17Marker_Decodes;
// Verbatim bytes of TApplication.FHintColor's $2C field record from SampleApp:
// `2C 0A "FHintColor" 00 00 00 85 03 51 03 9C 17 B9 8D ... 08 0D 07 FF`.
// The hash marker is `9C 17` (tag $17). The old decoder only accepted
// `9C 09` / `9C 01`, so this field was dropped and HintColor (read FHintColor)
// could not resolve. Hash16 is the two bytes after the tag: B9 8D -> $8DB9.
var
  Buf: TBytes;
  M:   TClassMember;
begin
  Buf := TBytes.Create(
    $2C, $0A,
    Ord('F'), Ord('H'), Ord('i'), Ord('n'), Ord('t'),
    Ord('C'), Ord('o'), Ord('l'), Ord('o'), Ord('r'),
    $00, $00, $00,
    $85, $03, $51, $03,
    $9C, $17, $B9, $8D,
    $02, $0D, $10, $00, $01, $B9, $8D, $07, $00, $00,
    $08, $0D, $07,
    $FF);
  Assert.IsTrue(ClassMember_TryDecode(@Buf[0], Length(Buf), 0, M),
    'field record with `9C 17` hash marker must decode (not be rejected)');
  Assert.AreEqual('FHintColor', M.Name, 'name');
  Assert.AreEqual<Integer>(Ord(cmkField), Ord(M.Kind), 'must be a field');
  Assert.AreEqual(Word($8DB9), M.Hash,
    'hash16 must be the two bytes after the tag (B9 8D)');
end;

procedure TRsmReaderTests.UnitScopedLocals_PicksRightUnitForCollidingProc;

  function HasLocal(const A: TArray<TLocalSymbol>; const Name: string): Boolean;
  begin
    Result := False;
    for var L in A do
      if SameText(L.Name, Name) then Exit(True);
  end;

var
  Rsm:     TRsmFile;
  RsmPath: string;
  Locals1, Locals2: TArray<TLocalSymbol>;
begin
  RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
  if not FileExists(RsmPath) then
    Assert.Fail('TestTarget.rsm not found at ' + RsmPath +
                ' -- run build_target.bat first');
  Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);

    Assert.IsTrue(Rsm.NameCollidesAcrossUnits('SharedConflictProc'),
      'SharedConflictProc must be detected as cross-unit colliding');
    Assert.IsFalse(Rsm.NameCollidesAcrossUnits('RunConflict1'),
      'RunConflict1 is unique -- must NOT be flagged as colliding');

    Assert.IsTrue(
      Rsm.GetLocalsForFunctionInUnit('SharedConflictProc', 'TestTargetConflict1', Locals1),
      'unit-scoped lookup must find SharedConflictProc in TestTargetConflict1');
    Assert.IsTrue(HasLocal(Locals1, 'Marker1'),
      'TestTargetConflict1 copy must expose its own local Marker1');
    Assert.IsFalse(HasLocal(Locals1, 'Marker2'),
      'TestTargetConflict1 copy must NOT leak the other unit''s Marker2');

    Assert.IsTrue(
      Rsm.GetLocalsForFunctionInUnit('SharedConflictProc', 'TestTargetConflict2', Locals2),
      'unit-scoped lookup must find SharedConflictProc in TestTargetConflict2');
    Assert.IsTrue(HasLocal(Locals2, 'Marker2'),
      'TestTargetConflict2 copy must expose its own local Marker2');
    Assert.IsFalse(HasLocal(Locals2, 'Marker1'),
      'TestTargetConflict2 copy must NOT leak the other unit''s Marker1');
  finally
    Rsm.Free;
  end;
end;

procedure TRsmReaderTests.ParseClassMembers_WideFieldOffsetDecoded;
var
  Rsm:     TRsmFile;
  Members: TArray<TClassMember>;
  RsmPath: string;

  function OffsetOf(const FieldName: string; out Off: Integer): Boolean;
  begin
    Result := False;
    for var M in Members do
      if (M.Kind = cmkField) and SameText(M.Name, FieldName) then begin
        Off := M.FieldOffset;
        Exit(True);
      end;
  end;

begin
  RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
  if not FileExists(RsmPath) then
    Assert.Fail('TestTarget.rsm not found at ' + RsmPath +
                ' -- run build_target.bat first');
  Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);
    Assert.IsTrue(Rsm.GetClassMembers('TWideFields', Members),
      'TWideFields missing from the class-member table');
    var Off: Integer;
    Assert.IsTrue(OffsetOf('FHead', Off), 'FHead field missing');
    Assert.AreEqual<Integer>(8, Off, 'FHead offset (1-byte VLE form)');
    Assert.IsTrue(OffsetOf('FTailA', Off), 'FTailA field missing');
    Assert.AreEqual<Integer>(256, Off,
      'FTailA offset must decode to 256 (2-byte VLE), not a div-2 truncation');
    Assert.IsTrue(OffsetOf('FTailB', Off), 'FTailB field missing');
    Assert.AreEqual<Integer>(260, Off, 'FTailB offset (2-byte VLE)');
  finally
    Rsm.Free;
  end;
end;

procedure TRsmReaderTests.WaitForIndex_ReturnsWithinBudget_WhenIndexNeverReady;
begin
  // The per-call cap stays long (correctness: BP binding / first locals must get a
  // fully-built index). The interactive deadline is what protects the dispatch
  // thread: while it is armed, WaitForIndex bails out at the deadline instead of
  // waiting the full cap. This is the mechanism that stops a form-open (many BPLs
  // loaded at once) from freezing the MCP server for minutes (F14).
  var SavedDeadline := TRsmFile.InteractiveDeadlineTicks;
  try
    // Never call LoadFromFile -> no background indexer -> FIndexReady stays False,
    // so without the deadline WaitForIndex would block for the full 60 s cap.
    var Rsm := TRsmFile.Create;
    try
      TRsmFile.InteractiveDeadlineTicks := GetTickCount64 + 100;  // ~100 ms budget
      var SW := TStopwatch.StartNew;
      Rsm.WaitForIndex;
      SW.Stop;
      Assert.IsTrue(SW.ElapsedMilliseconds < 1500,
        Format('WaitForIndex blocked %d ms while the interactive deadline was armed ' +
               '-- must bail at the deadline, not the 60 s cap (F14)',
               [SW.ElapsedMilliseconds]));
    finally
      Rsm.Free;
    end;
  finally
    TRsmFile.InteractiveDeadlineTicks := SavedDeadline;
  end;
end;

procedure TRsmReaderTests.IndexBuild_SidecarIsReproducible;

  function BuildSidecarHash(const RsmPath: string): string;
  begin
    var SidecarPath := RsmPath + '.idx';
    if TFile.Exists(SidecarPath) then
      TFile.Delete(SidecarPath);
    var Rsm := TRsmFile.Create;
    try
      Rsm.LoadFromFile(RsmPath);
      Rsm.WaitForIndex;
    finally
      Rsm.Free;
    end;
    Assert.IsTrue(TFile.Exists(SidecarPath),
      'cold index build wrote no sidecar for ' + RsmPath);
    Result := THashSHA2.GetHashStringFromFile(SidecarPath, SHA256);
  end;

begin
  var SourceRsm := ExtractFilePath(ParamStr(0)) +
                   '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
  if not FileExists(SourceRsm) then
    Assert.Fail('TestTarget.rsm not found at ' + SourceRsm +
                ' -- run build_target.bat first');

  // Work on a private copy: the build writes a sidecar next to the input and
  // the shipped one must not be disturbed by a test run.
  var WorkDir := TPath.Combine(TPath.GetTempPath, 'RsmIdxRepro_' +
                               IntToStr(GetCurrentProcessId));
  TDirectory.CreateDirectory(WorkDir);
  try
    var WorkRsm := TPath.Combine(WorkDir, 'TestTarget.rsm');
    TFile.Copy(SourceRsm, WorkRsm, True);

    var First  := BuildSidecarHash(WorkRsm);
    var Second := BuildSidecarHash(WorkRsm);
    var Third  := BuildSidecarHash(WorkRsm);

    Assert.AreEqual(First, Second,
      'cold index build is not reproducible: two builds of the same .rsm ' +
      'produced different sidecars (' + First + ' vs ' + Second + ')');
    Assert.AreEqual(First, Third,
      'cold index build is not reproducible: third build differs (' +
      First + ' vs ' + Third + ')');
  finally
    TDirectory.Delete(WorkDir, True);
  end;
end;

procedure TRsmReaderTests.WaitForIndex_ReportsWhetherIndexWasReady;
begin
  var SavedDeadline := TRsmFile.InteractiveDeadlineTicks;
  try
    // Never loaded -> FIndexReady stays False forever. The wait must give up AND
    // say so, so a caller can decline to pin whatever it computed meanwhile.
    var Unbuilt := TRsmFile.Create;
    try
      TRsmFile.InteractiveDeadlineTicks := GetTickCount64 + 50;
      Assert.IsFalse(Unbuilt.WaitForIndex,
        'WaitForIndex reported success although it gave up on a never-built index');
    finally
      Unbuilt.Free;
    end;

    // A real, fully-indexed reader must report success.
    TRsmFile.InteractiveDeadlineTicks := 0;
    var RsmPath := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
    if not FileExists(RsmPath) then
      Assert.Fail('TestTarget.rsm not found at ' + RsmPath + ' -- run build_target.bat first');
    var Ready := TRsmFile.Create;
    try
      Ready.LoadFromFile(RsmPath);
      Assert.IsTrue(Ready.WaitForIndex,
        'WaitForIndex reported failure on a reader whose index completes');
    finally
      Ready.Free;
    end;
  finally
    TRsmFile.InteractiveDeadlineTicks := SavedDeadline;
  end;
end;

procedure TRsmReaderTests.InteractiveDeadline_IsPerThread;
var
  WorkerSawDeadline: UInt64;
  WorkerWaitMs: Int64;
begin
  var SavedDeadline := TRsmFile.InteractiveDeadlineTicks;
  try
    // Arm a budget on THIS thread, as TDebugSession does around a stop.
    TRsmFile.InteractiveDeadlineTicks := GetTickCount64 + 100;
    WorkerSawDeadline := 1;   // sentinel: the worker must overwrite this with 0
    WorkerWaitMs      := 0;

    var Worker := TThread.CreateAnonymousThread(
      procedure
      begin
        WorkerSawDeadline := TRsmFile.InteractiveDeadlineTicks;
        // A never-built index with NO budget armed on this thread must consume
        // this thread's own per-call cap, not bail out on the other thread's.
        TRsmFile.IndexWaitBudgetMs := 200;
        var Rsm := TRsmFile.Create;
        try
          var SW := TStopwatch.StartNew;
          Rsm.WaitForIndex;
          SW.Stop;
          WorkerWaitMs := SW.ElapsedMilliseconds;
        finally
          Rsm.Free;
        end;
        // Ending a scope on this thread must not disarm the other thread's budget.
        TRsmFile.InteractiveDeadlineTicks := 0;
      end);
    Worker.FreeOnTerminate := False;
    try
      Worker.Start;
      Worker.WaitFor;
    finally
      Worker.Free;
      TRsmFile.IndexWaitBudgetMs := 60000;
    end;

    Assert.AreEqual<UInt64>(0, WorkerSawDeadline,
      'the worker thread inherited the dispatch thread''s interactive deadline; ' +
      'it would abandon its own index build half-way and publish a partial reader');
    Assert.IsTrue(WorkerWaitMs >= 150,
      Format('the worker waited only %d ms: it bailed out on another thread''s ' +
             'deadline instead of its own 200 ms cap', [WorkerWaitMs]));
    Assert.IsTrue(TRsmFile.InteractiveDeadlineTicks <> 0,
      'the worker cleared THIS thread''s interactive deadline -- that is the F14 ' +
      'protection being disarmed in the middle of a stop');
  finally
    TRsmFile.InteractiveDeadlineTicks := SavedDeadline;
  end;
end;

procedure TRsmReaderTests.Sidecar_LongString_RoundTripsWithoutDesync;
begin
  var Long := StringOfChar('A', 70000);
  var S := TMemoryStream.Create;
  try
    SidecarWriteStr(S, Long);
    SidecarWriteStr(S, 'next-field');
    S.Position := 0;
    Assert.AreEqual(Long, SidecarReadStr(S),
      'a 70,000-byte string did not survive the sidecar encoding');
    Assert.AreEqual('next-field', SidecarReadStr(S),
      'the stream desynchronised after a long string -- this is the silent, ' +
      'undetectable corruption the truncating 16-bit length field caused');
  finally
    S.Free;
  end;
end;

// Copies TestTarget.rsm into a private directory and returns its path. The
// index build writes a sidecar next to the input, so no test may work on the
// shipped file.
function CopyTestTargetRsmTo(const WorkDirTag: string; out WorkDir: string): string;
begin
  var SourceRsm := ExtractFilePath(ParamStr(0)) +
                   '..\..\TestTarget\Win64\Debug\TestTarget.rsm';
  if not FileExists(SourceRsm) then
    Assert.Fail('TestTarget.rsm not found at ' + SourceRsm +
                ' -- run build_target.bat first');
  WorkDir := TPath.Combine(TPath.GetTempPath,
               WorkDirTag + '_' + IntToStr(GetCurrentProcessId));
  TDirectory.CreateDirectory(WorkDir);
  Result := TPath.Combine(WorkDir, 'TestTarget.rsm');
  TFile.Copy(SourceRsm, Result, True);
end;

// Cold-builds the index for RsmPath and returns the sorted procedure names the
// resulting reader answers with.
function BuildAndListProcs(const RsmPath: string): TArray<string>;
begin
  var Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(RsmPath);
    Assert.IsTrue(Rsm.WaitForIndex,
      'the index thread never published readiness for ' + RsmPath);
    Result := Rsm.AllProcedureNames;
  finally
    Rsm.Free;
  end;
  TArray.Sort<string>(Result);
end;

// A sidecar that is newer than its source but written in another format must be
// reported unusable, because the loader rejects it and falls back to a full
// scan. Anything that decides what needs rebuilding has to agree with the
// loader: a timestamp-only rule once left 144 sidecars reported as up to date
// while every debug session went on paying the cold scan for all of them.
procedure TRsmReaderTests.SidecarIsUsable_RejectsForeignMagicEvenWhenNewer;
var
  WorkDir: string;
begin
  var WorkRsm := CopyTestTargetRsmTo('RsmUsable', WorkDir);
  try
    BuildAndListProcs(WorkRsm);
    var SidecarPath := WorkRsm + '.idx';
    Assert.IsTrue(TFile.Exists(SidecarPath), 'the cold build wrote no sidecar');
    Assert.IsTrue(TRsmFile.SidecarIsUsable(WorkRsm),
      'a sidecar just written by this build must be usable');

    var Bytes := TFile.ReadAllBytes(SidecarPath);
    Assert.IsTrue(Length(Bytes) > 4, 'sidecar too small to hold a magic');
    var Original := Bytes[0];
    Bytes[0] := Bytes[0] xor $FF;                 // any other format
    TFile.WriteAllBytes(SidecarPath, Bytes);
    TFile.SetLastWriteTime(SidecarPath, Now + 1); // and newer than its source
    Assert.IsFalse(TRsmFile.SidecarIsUsable(WorkRsm),
      'a newer sidecar in a foreign format must still be reported unusable');

    Bytes[0] := Original;
    TFile.WriteAllBytes(SidecarPath, Bytes);
    TFile.SetLastWriteTime(SidecarPath, Now + 1);
    Assert.IsTrue(TRsmFile.SidecarIsUsable(WorkRsm),
      'restoring the magic must make it usable again');

    TFile.SetLastWriteTime(SidecarPath, TFile.GetLastWriteTime(WorkRsm) - 1);
    Assert.IsFalse(TRsmFile.SidecarIsUsable(WorkRsm),
      'a sidecar older than its source must be reported unusable');
  finally
    TDirectory.Delete(WorkDir, True);
  end;
end;

procedure TRsmReaderTests.Sidecar_PublishRace_LeavesTheOtherWritersFileIntact;
var
  WorkDir: string;
begin
  var WorkRsm := CopyTestTargetRsmTo('RsmIdxRace', WorkDir);
  try
    var SidecarPath := WorkRsm + '.idx';
    BuildAndListProcs(WorkRsm);
    Assert.IsTrue(TFile.Exists(SidecarPath), 'the first build wrote no sidecar');
    var WinnerHash := THashSHA2.GetHashStringFromFile(SidecarPath, SHA256);

    // Age the sidecar so the next reader treats it as stale and rebuilds, then
    // hold it open the way another process would while reading or replacing it.
    // Our publish must fail -- and failing must cost nothing but the write.
    TFile.SetLastWriteTime(SidecarPath, IncSecond(TFile.GetLastWriteTime(WorkRsm), -10));
    var Holder := TFileStream.Create(SidecarPath, fmOpenRead or fmShareDenyWrite);
    var SavedBudget := TRsmFile.IndexWaitBudgetMs;
    try
      // Bound the wait: the pre-fix failure mode is FIndexReady never being set,
      // which shows up as WaitForIndex burning the whole budget and returning
      // False. 5 s keeps the RED run fast.
      TRsmFile.IndexWaitBudgetMs := 5000;
      var Second := TRsmFile.Create;
      try
        Second.LoadFromFile(WorkRsm);
        Assert.IsTrue(Second.WaitForIndex,
          'the index thread died on a failed sidecar publish and never set ' +
          'FIndexReady -- every later lookup then burns the full 60 s budget');
        Assert.IsTrue(Length(Second.AllProcedureNames) > 0,
          'the reader answered nothing after a failed sidecar publish');
      finally
        Second.Free;
      end;
    finally
      TRsmFile.IndexWaitBudgetMs := SavedBudget;
      Holder.Free;
    end;

    Assert.IsTrue(TFile.Exists(SidecarPath),
      'the losing writer DELETED a sidecar it did not write');
    Assert.AreEqual(WinnerHash,
      THashSHA2.GetHashStringFromFile(SidecarPath, SHA256),
      'the losing writer damaged the other writer''s sidecar');
    Assert.AreEqual<Integer>(0, Length(TDirectory.GetFiles(WorkDir, '*.tmp')),
      'a temporary sidecar file was left behind by the failed publish');
  finally
    TDirectory.Delete(WorkDir, True);
  end;
end;

procedure TRsmReaderTests.Sidecar_Corrupt_IsRejectedAndRebuilt;
var
  WorkDir: string;
begin
  var WorkRsm := CopyTestTargetRsmTo('RsmIdxCorrupt', WorkDir);
  try
    var SidecarPath := WorkRsm + '.idx';
    var Reference := BuildAndListProcs(WorkRsm);
    Assert.IsTrue(Length(Reference) > 0, 'the reference build indexed no procedures');
    var GoodHash := THashSHA2.GetHashStringFromFile(SidecarPath, SHA256);

    // Two flavours of damage, both of which keep the file NEWER than the .rsm,
    // so the freshness rule accepts it and only the decoder can reject it:
    // a truncated stream, and a stream whose header parses but whose body is
    // garbage.
    var Truncated := TFile.ReadAllBytes(SidecarPath);
    SetLength(Truncated, Length(Truncated) div 2);
    var Garbled := TFile.ReadAllBytes(SidecarPath);
    for var I := 4 to High(Garbled) do
      Garbled[I] := $FF;

    for var Damaged in [Truncated, Garbled] do begin
      TFile.WriteAllBytes(SidecarPath, Damaged);
      var Rebuilt := BuildAndListProcs(WorkRsm);
      Assert.AreEqual(string.Join(#10, Reference), string.Join(#10, Rebuilt),
        'a corrupt sidecar was half-read: the reader answered with a different ' +
        'symbol set than a clean build of the same .rsm');
      Assert.AreEqual(GoodHash, THashSHA2.GetHashStringFromFile(SidecarPath, SHA256),
        'the corrupt sidecar was not replaced by a rebuilt one');
    end;
  finally
    TDirectory.Delete(WorkDir, True);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TRsmReaderTests);

end.
