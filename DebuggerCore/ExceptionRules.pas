unit ExceptionRules;

// Per-exception rule engine. A rule matches a first-chance (or second-chance)
// exception on a combination of: Delphi class name, message (substring or
// regex), the Win32 exception code, the source unit where it was raised (or
// explicitly the unknown-source case), and a source line range. The first
// matching rule wins and selects an action: ignore, log, log-with-stack, or
// break.
//
// The `code` criterion is the only one that can target a NATIVE Windows
// exception: such an exception carries no Delphi object, hence no class and no
// message, so `class` / `classIs` / `message` / `messageRegex` can never match
// it. Example: Delphi's TThread.NameThreadForDebugging raises the debugger
// thread-name exception 0x406D1388 during normal operation.
//
// The matcher is intentionally pure (no process / debugger state) so it can be
// unit-tested in isolation. The debugger supplies the already-decoded class,
// message and raise-site unit/line.

interface

uses
  System.SysUtils, System.StrUtils, System.RegularExpressions;

type
  TExceptionAction = (
    eaIgnore,    // swallow at the debugger level: resume, no stop, no log
    eaLog,       // write class + message to the debug console, then resume
    eaLogStack,  // like eaLog plus the formatted call stack
    eaBreak      // pause the debuggee in the debugger (the default behaviour)
  );

  TExceptionRule = record
    // All set criteria are AND-ed; an unset criterion is a wildcard.
    ClassNames:       TArray<string>; // `class`: any-of, exact match on the runtime class (case-insensitive); empty = any
    ClassIsNames:     TArray<string>; // `classIs`: any-of, matches the runtime class OR any ancestor; empty = any
    Codes:            TArray<Cardinal>; // `code`: any-of, Win32 exception code (e.g. $C0000005); empty = any
    MessageSub:       string;         // case-insensitive substring; '' = any
    MessageRegex:     string;         // regex (ignore-case); '' = any
    UnitName:         string;         // source basename without extension; '' = any
    MatchUnknownUnit: Boolean;        // true => match only when the raise site has no known source
    LineFrom:         Integer;        // -1 = no lower bound
    LineTo:           Integer;        // -1 = no upper bound
    Action:           TExceptionAction;
  end;

// Token recognised in a rule's `unit` field to target raises whose source
// cannot be resolved (RTL/third-party without line info, optimised code, etc.).
const
  UNKNOWN_UNIT_TOKEN = '*unknown*';

// Code passed to the matcher when the caller has no Win32 exception code to
// offer. 0 is not a real exception code, so a rule with `code` never matches it.
const
  NO_EXCEPTION_CODE = 0;

function ParseExceptionAction(const S: string; out Action: TExceptionAction): Boolean;
function ExceptionActionToStr(Action: TExceptionAction): string;

// Parse one `code` entry. Accepted syntaxes:
//   "0xC0000005" / "0XC0000005"  hexadecimal, C style
//   "$C0000005"                  hexadecimal, Pascal style
//   "3221225477"                 decimal (also as a JSON number)
//   "-1073741819"                signed decimal, for codes with the high bit set
// Anything else (including 0) is rejected.
function ParseExceptionCode(const S: string; out Code: Cardinal): Boolean;

// True if any rule references the raise-site unit or line, so the caller knows
// whether it must perform the (relatively costly) stack walk before matching.
function RulesNeedRaiseSite(const Rules: TArray<TExceptionRule>): Boolean;

// Evaluate a single rule against a decoded exception. ClassChain is the runtime
// class at index 0 followed by its ancestors (for `classIs`); for a non-Delphi
// exception (e.g. an access violation) it is a single synthetic name.
// ExceptionCode is the Win32 exception code, or NO_EXCEPTION_CODE when the
// caller does not know it.
function RuleMatches(const Rule: TExceptionRule;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer;
  ExceptionCode: Cardinal): Boolean; overload;
function RuleMatches(const Rule: TExceptionRule;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer): Boolean; overload;

// First-match-wins across the ordered rule list. Returns False when no rule
// matches (the caller then falls back to its own default policy). The string
// overloads (no ancestor chain) support `class` but not `classIs`; the overloads
// without an ExceptionCode parameter pass NO_EXCEPTION_CODE.
function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer; ExceptionCode: Cardinal;
  out Action: TExceptionAction): Boolean; overload;
function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer;
  out Action: TExceptionAction): Boolean; overload;
function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassName, Msg, RaiseUnit: string; HasRaiseSite: Boolean;
  RaiseLine: Integer; ExceptionCode: Cardinal;
  out Action: TExceptionAction): Boolean; overload;
function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassName, Msg, RaiseUnit: string; HasRaiseSite: Boolean;
  RaiseLine: Integer; out Action: TExceptionAction): Boolean; overload;

implementation

function ParseExceptionAction(const S: string; out Action: TExceptionAction): Boolean;
begin
  Result := True;
  if      SameText(S, 'ignore')   then Action := eaIgnore
  else if SameText(S, 'log')      then Action := eaLog
  else if SameText(S, 'logStack') then Action := eaLogStack
  else if SameText(S, 'break')    then Action := eaBreak
  else Result := False;
end;

function ExceptionActionToStr(Action: TExceptionAction): string;
begin
  case Action of
    eaIgnore:   Result := 'ignore';
    eaLog:      Result := 'log';
    eaLogStack: Result := 'logStack';
    eaBreak:    Result := 'break';
  else          Result := '?';
  end;
end;

function ParseExceptionCode(const S: string; out Code: Cardinal): Boolean;
begin
  Code := NO_EXCEPTION_CODE;
  var Text := Trim(S);
  if Text = '' then
    Exit(False);

  var IsHex := False;
  if Text.StartsWith('$') then begin
    IsHex := True;
    Text  := Text.Substring(1);
  end else if Text.StartsWith('0x', True) then begin
    IsHex := True;
    Text  := Text.Substring(2);
  end;

  var Value: Int64;
  if IsHex then begin
    // TryStrToInt64 understands the Pascal '$' prefix; normalise both spellings
    // onto it so hex is parsed as unsigned up to $FFFFFFFF.
    if not TryStrToInt64('$' + Text, Value) then
      Exit(False);
  end else if not TryStrToInt64(Text, Value) then
    Exit(False);

  // A code with the high bit set may arrive either unsigned (3221225477) or
  // signed (-1073741819) depending on who wrote the configuration.
  if (Value < Low(Integer)) or (Value > High(Cardinal)) then
    Exit(False);
  if Value < 0 then
    Code := Cardinal(Integer(Value))
  else
    Code := Cardinal(Value);
  Result := Code <> NO_EXCEPTION_CODE;
end;

function UnitBaseName(const NameOrFile: string): string;
begin
  // Accept both "OracleData" and "OracleData.pas"; compare on the bare,
  // lower-cased unit name without extension.
  Result := LowerCase(ChangeFileExt(ExtractFileName(NameOrFile), ''));
end;

function RulesNeedRaiseSite(const Rules: TArray<TExceptionRule>): Boolean;
begin
  for var R in Rules do
    if (R.UnitName <> '') or R.MatchUnknownUnit or
       (R.LineFrom >= 0) or (R.LineTo >= 0) then
      Exit(True);
  Result := False;
end;

function ClassCriterionMatches(const Rule: TExceptionRule;
  const ClassChain: TArray<string>): Boolean;
begin
  // `class`: exact match on the runtime (most-derived) class only.
  if Length(Rule.ClassNames) = 0 then
    Exit(True);
  if Length(ClassChain) = 0 then
    Exit(False);
  for var Want in Rule.ClassNames do
    if SameText(Trim(Want), ClassChain[0]) then
      Exit(True);
  Result := False;
end;

function ClassIsCriterionMatches(const Rule: TExceptionRule;
  const ClassChain: TArray<string>): Boolean;
begin
  // `classIs`: match the runtime class OR any ancestor (Delphi `is` semantics).
  if Length(Rule.ClassIsNames) = 0 then
    Exit(True);
  for var Want in Rule.ClassIsNames do
    for var Cls in ClassChain do
      if SameText(Trim(Want), Cls) then
        Exit(True);
  Result := False;
end;

function CodeCriterionMatches(const Rule: TExceptionRule; ExceptionCode: Cardinal): Boolean;
begin
  // `code`: any-of on the Win32 exception code. This is what makes a native
  // exception (no Delphi object, no class, no message) targetable at all.
  if Length(Rule.Codes) = 0 then
    Exit(True);
  if ExceptionCode = NO_EXCEPTION_CODE then
    Exit(False);
  for var Want in Rule.Codes do
    if Want = ExceptionCode then
      Exit(True);
  Result := False;
end;

function MessageCriterionMatches(const Rule: TExceptionRule; const Msg: string): Boolean;
begin
  if (Rule.MessageSub <> '') and
     not ContainsText(Msg, Rule.MessageSub) then
    Exit(False);
  if Rule.MessageRegex <> '' then begin
    try
      if not TRegEx.IsMatch(Msg, Rule.MessageRegex, [roIgnoreCase]) then
        Exit(False);
    except
      // Invalid pattern never matches rather than crashing the debug loop.
      Exit(False);
    end;
  end;
  Result := True;
end;

function RaiseSiteCriterionMatches(const Rule: TExceptionRule;
  const RaiseUnit: string; HasRaiseSite: Boolean; RaiseLine: Integer): Boolean;
begin
  if Rule.MatchUnknownUnit then
    Exit(not HasRaiseSite);
  if Rule.UnitName <> '' then begin
    if not HasRaiseSite then Exit(False);
    if not SameText(UnitBaseName(RaiseUnit), UnitBaseName(Rule.UnitName)) then
      Exit(False);
  end;
  if Rule.LineFrom >= 0 then begin
    if not HasRaiseSite then Exit(False);
    if RaiseLine < Rule.LineFrom then Exit(False);
  end;
  if Rule.LineTo >= 0 then begin
    if not HasRaiseSite then Exit(False);
    if RaiseLine > Rule.LineTo then Exit(False);
  end;
  Result := True;
end;

function RuleMatches(const Rule: TExceptionRule;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer;
  ExceptionCode: Cardinal): Boolean;
begin
  if not ClassCriterionMatches(Rule, ClassChain) then Exit(False);
  if not ClassIsCriterionMatches(Rule, ClassChain) then Exit(False);
  if not CodeCriterionMatches(Rule, ExceptionCode) then Exit(False);
  if not MessageCriterionMatches(Rule, Msg) then Exit(False);
  if not RaiseSiteCriterionMatches(Rule, RaiseUnit, HasRaiseSite, RaiseLine) then Exit(False);
  Result := True;
end;

function RuleMatches(const Rule: TExceptionRule;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer): Boolean;
begin
  Result := RuleMatches(Rule, ClassChain, Msg, RaiseUnit, HasRaiseSite, RaiseLine,
    NO_EXCEPTION_CODE);
end;

function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer; ExceptionCode: Cardinal;
  out Action: TExceptionAction): Boolean;
begin
  for var R in Rules do
    if RuleMatches(R, ClassChain, Msg, RaiseUnit, HasRaiseSite, RaiseLine,
         ExceptionCode) then begin
      Action := R.Action;
      Exit(True);
    end;
  Action := eaBreak;
  Result := False;
end;

function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassChain: TArray<string>; const Msg, RaiseUnit: string;
  HasRaiseSite: Boolean; RaiseLine: Integer;
  out Action: TExceptionAction): Boolean;
begin
  Result := MatchExceptionRules(Rules, ClassChain, Msg, RaiseUnit, HasRaiseSite,
    RaiseLine, NO_EXCEPTION_CODE, Action);
end;

function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassName, Msg, RaiseUnit: string; HasRaiseSite: Boolean;
  RaiseLine: Integer; ExceptionCode: Cardinal;
  out Action: TExceptionAction): Boolean;
begin
  Result := MatchExceptionRules(Rules, TArray<string>.Create(ClassName),
    Msg, RaiseUnit, HasRaiseSite, RaiseLine, ExceptionCode, Action);
end;

function MatchExceptionRules(const Rules: TArray<TExceptionRule>;
  const ClassName, Msg, RaiseUnit: string; HasRaiseSite: Boolean;
  RaiseLine: Integer; out Action: TExceptionAction): Boolean;
begin
  Result := MatchExceptionRules(Rules, TArray<string>.Create(ClassName),
    Msg, RaiseUnit, HasRaiseSite, RaiseLine, NO_EXCEPTION_CODE, Action);
end;

end.
