unit ExceptionRulesTests;

// Unit tests for the pure per-exception rule matcher (ExceptionRules.pas).
// No debugger / process involved: the matcher takes an already-decoded
// exception (class, message, raise-site unit/line) and an ordered rule list.

interface

uses
  System.SysUtils, DUnitX.TestFramework, ExceptionRules;

type
  [TestFixture]
  TExceptionRulesTests = class
  private
    function Match(const Rules: TArray<TExceptionRule>;
      const ClassName, Msg, RaiseUnit: string; HasSite: Boolean;
      Line: Integer; out Action: TExceptionAction): Boolean;
    function Rule(const Action: TExceptionAction): TExceptionRule;
  public
    [Test] procedure ParseActions_RoundTrip;
    [Test] procedure ParseAction_RejectsUnknown;
    [Test] procedure ClassExact_Matches;
    [Test] procedure ClassList_AnyOf;
    [Test] procedure ClassMismatch_NoMatch;
    [Test] procedure ClassIs_MatchesAncestor;
    [Test] procedure ClassIs_CaseInsensitive;
    [Test] procedure ClassIs_NoMatchWhenAbsent;
    [Test] procedure ClassExact_DoesNotMatchAncestor;
    [Test] procedure ParseCode_AcceptsHexAndDecimalSpellings;
    [Test] procedure ParseCode_RejectsGarbage;
    [Test] procedure Code_MatchesNativeException;
    [Test] procedure Code_AnyOf;
    [Test] procedure Code_DoesNotMatchOtherCode;
    [Test] procedure Code_NoMatchWhenCodeUnknown;
    [Test] procedure Code_CombinedWithClass_BothMustHold;
    [Test] procedure MessageSubstring_CaseInsensitive;
    [Test] procedure MessageRegex_Matches;
    [Test] procedure MessageRegex_Invalid_NeverMatches;
    [Test] procedure Unit_Matches_WithOrWithoutExt;
    [Test] procedure UnknownUnit_MatchesOnlyWhenNoSite;
    [Test] procedure LineRange_Bounds;
    [Test] procedure FirstMatchWins;
    [Test] procedure NoMatch_ReturnsFalse;
    [Test] procedure NeedsRaiseSite_DetectsUnitOrLine;
    [Test] procedure CombinedCriteria_AllMustHold;
  end;

implementation

function TExceptionRulesTests.Rule(const Action: TExceptionAction): TExceptionRule;
begin
  Result := Default(TExceptionRule);
  Result.LineFrom := -1;
  Result.LineTo   := -1;
  Result.Action   := Action;
end;

function TExceptionRulesTests.Match(const Rules: TArray<TExceptionRule>;
  const ClassName, Msg, RaiseUnit: string; HasSite: Boolean;
  Line: Integer; out Action: TExceptionAction): Boolean;
begin
  Result := MatchExceptionRules(Rules, ClassName, Msg, RaiseUnit, HasSite, Line, Action);
end;

procedure TExceptionRulesTests.ParseActions_RoundTrip;
begin
  for var S in ['ignore', 'log', 'logStack', 'break'] do begin
    var A: TExceptionAction;
    Assert.IsTrue(ParseExceptionAction(S, A), 'should parse ' + S);
    Assert.AreEqual(S, ExceptionActionToStr(A), 'round-trip ' + S);
  end;
end;

procedure TExceptionRulesTests.ParseAction_RejectsUnknown;
begin
  var A: TExceptionAction;
  Assert.IsFalse(ParseExceptionAction('halt', A));
  Assert.IsFalse(ParseExceptionAction('', A));
end;

procedure TExceptionRulesTests.ClassExact_Matches;
begin
  var R := Rule(eaIgnore);
  R.ClassNames := ['EAbort'];
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'EAbort', '', '', False, 0, A));
  Assert.AreEqual(eaIgnore, A);
end;

procedure TExceptionRulesTests.ClassList_AnyOf;
begin
  var R := Rule(eaBreak);
  R.ClassNames := ['EConvertError', 'EAccessViolation'];
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'eaccessviolation', '', '', False, 0, A), 'case-insensitive any-of');
end;

procedure TExceptionRulesTests.ClassMismatch_NoMatch;
begin
  var R := Rule(eaIgnore);
  R.ClassNames := ['EAbort'];
  var A: TExceptionAction;
  Assert.IsFalse(Match([R], 'EOracleError', '', '', False, 0, A));
end;

procedure TExceptionRulesTests.ClassIs_MatchesAncestor;
begin
  var R := Rule(eaIgnore);
  R.ClassIsNames := ['Exception'];
  var A: TExceptionAction;
  // Runtime class EConvertError, ancestors Exception, TObject.
  Assert.IsTrue(MatchExceptionRules([R],
    ['EConvertError', 'Exception', 'TObject'], '', '', False, 0, A),
    'classIs should match an ancestor');
  Assert.AreEqual(eaIgnore, A);
end;

procedure TExceptionRulesTests.ClassIs_CaseInsensitive;
begin
  var R := Rule(eaBreak);
  R.ClassIsNames := ['exception'];
  var A: TExceptionAction;
  Assert.IsTrue(MatchExceptionRules([R],
    ['EConvertError', 'Exception', 'TObject'], '', '', False, 0, A));
end;

procedure TExceptionRulesTests.ClassIs_NoMatchWhenAbsent;
begin
  var R := Rule(eaIgnore);
  R.ClassIsNames := ['EAccessViolation'];
  var A: TExceptionAction;
  Assert.IsFalse(MatchExceptionRules([R],
    ['EConvertError', 'Exception', 'TObject'], '', '', False, 0, A),
    'classIs should not match a class outside the chain');
end;

procedure TExceptionRulesTests.ClassExact_DoesNotMatchAncestor;
begin
  var R := Rule(eaIgnore);
  R.ClassNames := ['Exception'];  // `class` is leaf-only
  var A: TExceptionAction;
  Assert.IsFalse(MatchExceptionRules([R],
    ['EConvertError', 'Exception', 'TObject'], '', '', False, 0, A),
    '`class` must match only the runtime (leaf) class, not ancestors');
end;

procedure TExceptionRulesTests.ParseCode_AcceptsHexAndDecimalSpellings;
begin
  var Code: Cardinal;
  for var S in ['0xC0000005', '0XC0000005', '$C0000005', '3221225477', '-1073741819', ' 0xC0000005 '] do begin
    Assert.IsTrue(ParseExceptionCode(S, Code), 'should parse ' + S);
    Assert.IsTrue(Code = $C0000005, Format('value of %s -> $%.8x', [S, Code]));
  end;
  Assert.IsTrue(ParseExceptionCode('$E0424242', Code));
  Assert.IsTrue(Code = $E0424242, Format('$E0424242 -> $%.8x', [Code]));
end;

procedure TExceptionRulesTests.ParseCode_RejectsGarbage;
begin
  var Code: Cardinal;
  // No prefix is not treated as hex (it would be ambiguous with decimal), and
  // 0 is not a usable exception code.
  for var S in ['', '   ', 'C0000005', '0xZZ', '$', 'EAbort', '0', '$0', '4294967296'] do
    Assert.IsFalse(ParseExceptionCode(S, Code), 'should reject ' + S);
end;

procedure TExceptionRulesTests.Code_MatchesNativeException;
begin
  var R := Rule(eaIgnore);
  R.Codes := [$E0424242];
  var A: TExceptionAction;
  // A native exception has no Delphi object: only the code identifies it.
  Assert.IsTrue(MatchExceptionRules([R], TArray<string>.Create('Exception 0xe0424242'),
    '', '', False, 0, $E0424242, A));
  Assert.AreEqual(eaIgnore, A);
end;

procedure TExceptionRulesTests.Code_AnyOf;
begin
  var R := Rule(eaLog);
  R.Codes := [$C0000005, $E0424242];
  var A: TExceptionAction;
  Assert.IsTrue(MatchExceptionRules([R], 'EAccessViolation', '', '', False, 0, $C0000005, A));
  Assert.IsTrue(MatchExceptionRules([R], 'Exception 0xe0424242', '', '', False, 0, $E0424242, A));
end;

procedure TExceptionRulesTests.Code_DoesNotMatchOtherCode;
begin
  var R := Rule(eaIgnore);
  R.Codes := [$E0424242];
  var A: TExceptionAction;
  // $0EEDFADE is the Delphi raise: a `code` rule for a native exception must
  // leave a Delphi exception raised nearby alone.
  Assert.IsFalse(MatchExceptionRules([R], 'Exception', 'exc-after-native', '', False, 0,
    $0EEDFADE, A));
end;

procedure TExceptionRulesTests.Code_NoMatchWhenCodeUnknown;
begin
  var R := Rule(eaIgnore);
  R.Codes := [$E0424242];
  var A: TExceptionAction;
  Assert.IsFalse(Match([R], 'Exception 0xe0424242', '', '', False, 0, A),
    'a caller with no code (NO_EXCEPTION_CODE) must not satisfy a `code` rule');
end;

procedure TExceptionRulesTests.Code_CombinedWithClass_BothMustHold;
begin
  var R := Rule(eaBreak);
  R.ClassNames := ['EAccessViolation'];
  R.Codes      := [$C0000005];
  var A: TExceptionAction;
  Assert.IsTrue(MatchExceptionRules([R], 'EAccessViolation', '', '', False, 0, $C0000005, A));
  Assert.IsFalse(MatchExceptionRules([R], 'EAccessViolation', '', '', False, 0, $80000003, A),
    'code fails -> no match');
  Assert.IsFalse(MatchExceptionRules([R], 'Exception', '', '', False, 0, $C0000005, A),
    'class fails -> no match');
end;

procedure TExceptionRulesTests.MessageSubstring_CaseInsensitive;
begin
  var R := Rule(eaLog);
  R.MessageSub := 'ora-00942';
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'EOracleError', 'ORA-00942: table or view does not exist', '', False, 0, A));
  Assert.IsFalse(Match([R], 'EOracleError', 'ORA-00001: unique constraint', '', False, 0, A));
end;

procedure TExceptionRulesTests.MessageRegex_Matches;
begin
  var R := Rule(eaLogStack);
  R.MessageRegex := 'ORA-\d{5}';
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'EOracleError', 'failed: ORA-12541 no listener', '', False, 0, A));
  Assert.IsFalse(Match([R], 'EOracleError', 'no oracle code here', '', False, 0, A));
end;

procedure TExceptionRulesTests.MessageRegex_Invalid_NeverMatches;
begin
  var R := Rule(eaBreak);
  R.MessageRegex := '([unbalanced';
  var A: TExceptionAction;
  Assert.IsFalse(Match([R], 'E', 'anything', '', False, 0, A), 'invalid regex must not crash or match');
end;

procedure TExceptionRulesTests.Unit_Matches_WithOrWithoutExt;
begin
  var R := Rule(eaBreak);
  R.UnitName := 'OracleData';
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'E', '', 'OracleData.pas', True, 10, A), 'frame has .pas');
  R.UnitName := 'OracleData.pas';
  Assert.IsTrue(Match([R], 'E', '', 'OracleData', True, 10, A), 'rule has .pas');
  Assert.IsFalse(Match([R], 'E', '', 'OtherUnit.pas', True, 10, A));
end;

procedure TExceptionRulesTests.UnknownUnit_MatchesOnlyWhenNoSite;
begin
  var R := Rule(eaLog);
  R.MatchUnknownUnit := True;
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'E', '', '', False, 0, A), 'no source -> matches unknown');
  Assert.IsFalse(Match([R], 'E', '', 'Known.pas', True, 5, A), 'known source -> no match');
end;

procedure TExceptionRulesTests.LineRange_Bounds;
begin
  var R := Rule(eaBreak);
  R.UnitName := 'U';
  R.LineFrom := 2700;
  R.LineTo   := 2800;
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'E', '', 'U.pas', True, 2750, A), 'inside range');
  Assert.IsFalse(Match([R], 'E', '', 'U.pas', True, 2699, A), 'below range');
  Assert.IsFalse(Match([R], 'E', '', 'U.pas', True, 2801, A), 'above range');
  Assert.IsFalse(Match([R], 'E', '', 'U.pas', False, 2750, A), 'no site -> line cannot match');
end;

procedure TExceptionRulesTests.FirstMatchWins;
begin
  var R1 := Rule(eaIgnore);  R1.ClassNames := ['EAbort'];
  var R2 := Rule(eaBreak);   // catch-all
  var A: TExceptionAction;
  Assert.IsTrue(Match([R1, R2], 'EAbort', '', '', False, 0, A));
  Assert.AreEqual(eaIgnore, A, 'first matching rule wins');
  Assert.IsTrue(Match([R1, R2], 'EOther', '', '', False, 0, A));
  Assert.AreEqual(eaBreak, A, 'falls through to catch-all');
end;

procedure TExceptionRulesTests.NoMatch_ReturnsFalse;
begin
  var R := Rule(eaIgnore);  R.ClassNames := ['EAbort'];
  var A: TExceptionAction;
  Assert.IsFalse(Match([R], 'EOther', '', '', False, 0, A));
end;

procedure TExceptionRulesTests.NeedsRaiseSite_DetectsUnitOrLine;
begin
  var Plain := Rule(eaBreak);  Plain.ClassNames := ['E'];
  Assert.IsFalse(RulesNeedRaiseSite([Plain]), 'class/message only -> no walk');
  var WithUnit := Rule(eaBreak);  WithUnit.UnitName := 'U';
  Assert.IsTrue(RulesNeedRaiseSite([WithUnit]));
  var WithLine := Rule(eaBreak);  WithLine.LineFrom := 10;
  Assert.IsTrue(RulesNeedRaiseSite([WithLine]));
  var WithUnknown := Rule(eaBreak);  WithUnknown.MatchUnknownUnit := True;
  Assert.IsTrue(RulesNeedRaiseSite([WithUnknown]));
end;

procedure TExceptionRulesTests.CombinedCriteria_AllMustHold;
begin
  var R := Rule(eaBreak);
  R.ClassNames := ['EOracleError'];
  R.MessageSub := 'ORA-00942';
  R.UnitName   := 'OracleData';
  R.LineFrom   := 2700;
  R.LineTo     := 2800;
  var A: TExceptionAction;
  Assert.IsTrue(Match([R], 'EOracleError', 'ORA-00942 bad', 'OracleData.pas', True, 2750, A),
    'all criteria satisfied');
  Assert.IsFalse(Match([R], 'EOracleError', 'ORA-00001 other', 'OracleData.pas', True, 2750, A),
    'message fails -> no match');
  Assert.IsFalse(Match([R], 'EConvertError', 'ORA-00942 bad', 'OracleData.pas', True, 2750, A),
    'class fails -> no match');
end;

initialization
  TDUnitX.RegisterTestFixture(TExceptionRulesTests);
end.
