unit ExceptionRuleFiles;

// The JSON exception-rule schema, and the rule FILES of a VS Code session.
//
// ExceptionRules.pas is the matcher and stays pure: it knows nothing about JSON
// or files. This unit turns the JSON rule schema into TExceptionRule values
// (both frontends) and keeps the precedence chain of rule files a DAP session
// evaluates, narrowest scope first:
//
//   1. <Project>.ExceptionSettings.local.json      this developer, this machine
//   2. <Project>.ExceptionSettings.json            the project's own, shared
//   3. the machine-wide shared file
//
// First match wins across the whole chain, so the table handed to the engine is
// the tiers' rules concatenated in that order.
//
// The MCP server uses the schema but NEVER the chain: those files are the
// preferences of the human debugging in VS Code, and an agent's session -- one of
// possibly several running in parallel -- gets only the rules it passes itself.

interface

uses
  System.SysUtils, System.JSON, ExceptionRules;

// Parse the JSON rule schema into the rule-engine table. Each entry:
//   { class?: string|string[], classIs?: string|string[],
//     code?: string|number|array, message?, messageRegex?, unit?, line?: int,
//     lineFrom?: int, lineTo?: int,
//     action: "ignore"|"log"|"logStack"|"break" }
// Keys starting with "_" are comments. An entry with a missing or invalid
// action, an unparsable `code` or an invalid `messageRegex` is skipped; an
// unknown key is reported but does not drop the entry. Problems lists every
// such finding as "rule #N: ...", N counting from 1 in the array.
function ParseExceptionRulesArray(Arr: TJSONArray;
  out Problems: TArray<string>): TArray<TExceptionRule>; overload;
// Lenient form for rule FILES: problems only go to the diagnostic log.
function ParseExceptionRulesArray(Arr: TJSONArray): TArray<TExceptionRule>; overload;

// A whole rules document, as a rule file holds it: a bare array or an object
// with an `exceptionRules` array. Any other shape is reported in Problems.
function ParseExceptionRulesDocument(Root: TJSONValue;
  out Problems: TArray<string>): TArray<TExceptionRule>;

// Load the rules of one file -- the machine-wide shared file or either project
// sidecar; all three have the same shape. Accepts a bare array or an object with
// an `exceptionRules` key. Strict JSON, no JSONC. A missing or malformed file
// yields no rules and never raises: rules the user cannot see are a nuisance, a
// debugger that will not start is not.
function LoadExceptionRulesFile(const Path: string): TArray<TExceptionRule>;

// %USERPROFILE%\.DelphiWinDebugger\exceptionRules.json, '' without a profile.
function DefaultGlobalExceptionRulesPath: string;

// Last-write time of a rules file, 0 when absent. An absent file legitimately
// has an mtime: creating it later IS a change the reload must see.
function ExceptionRulesFileMTime(const Path: string): TDateTime;

type
  TExceptionRuleTierKind = (rtkProjectLocal, rtkProjectShared, rtkMachineWide);

  TExceptionRuleTier = record
    Kind:        TExceptionRuleTierKind;
    Path:        string;
    Description: string;      // how logs and tool results name this tier
    MTime:       TDateTime;   // file tiers: the mtime last read, to notice edits
    Rules:       TArray<TExceptionRule>;
  end;

  TExceptionRuleChain = class
  private
    FFileTiers: TArray<TExceptionRuleTier>;
    procedure AddFileTier(Kind: TExceptionRuleTierKind; const Path, Description: string);
  public
    // Replace the file tiers. ProjectFile '' = no project tiers; GlobalPath '' =
    // no machine-wide tier. A file need not exist: an absent one contributes no
    // rules but keeps its place, so creating it mid-session is picked up by
    // ReloadChangedFiles.
    procedure LoadFiles(const ProjectFile, GlobalPath: string);
    // Every tier's rules, concatenated narrowest first.
    function  Combined: TArray<TExceptionRule>;
    // Re-read every file tier whose mtime changed. Returns True when any did;
    // Messages then names each reloaded tier.
    function  ReloadChangedFiles(out Messages: TArray<string>): Boolean;
    property  Tiers: TArray<TExceptionRuleTier> read FFileTiers;
  end;

implementation

uses
  System.IOUtils, System.RegularExpressions, System.Generics.Collections, DapProtocol;

const
  KNOWN_RULE_KEYS: array[0..9] of string = ('class', 'classIs', 'code', 'message',
    'messageRegex', 'unit', 'line', 'lineFrom', 'lineTo', 'action');

function IsKnownRuleKey(const Key: string): Boolean;
begin
  if Key.StartsWith('_') then
    Exit(True);
  for var Known in KNOWN_RULE_KEYS do
    if Key = Known then
      Exit(True);
  Result := False;
end;

function ReadNames(Entry: TJSONObject; const Key: string): TArray<string>;
begin
  Result := nil;
  var V := Entry.FindValue(Key);
  if V is TJSONArray then begin
    for var Item in TJSONArray(V) do
      Result := Result + [Item.Value];
  end else if (V <> nil) and (V.Value <> '') then
    Result := [V.Value];
end;

// `code` accepts a hex ("0xC0000005" / "$C0000005") or decimal spelling, as a
// JSON string or a JSON number, singly or as an any-of array. Entries that do
// not parse are dropped rather than turned into a match-everything rule.
function ReadCodes(Entry: TJSONObject; const Key: string): TArray<Cardinal>;

  procedure AddCode(V: TJSONValue; var Codes: TArray<Cardinal>);
  begin
    if V = nil then
      Exit;
    var Code: Cardinal;
    if ParseExceptionCode(V.Value, Code) then
      Codes := Codes + [Code];
  end;

begin
  Result := nil;
  var V := Entry.FindValue(Key);
  if V is TJSONArray then begin
    for var Item in TJSONArray(V) do
      AddCode(Item, Result);
  end else
    AddCode(V, Result);
end;

function IsValidRegex(const Pattern: string; out ErrMsg: string): Boolean;
begin
  ErrMsg := '';
  try
    TRegEx.Create(Pattern, [roIgnoreCase]).IsMatch('');
    Result := True;
  except
    on E: Exception do begin
      ErrMsg := E.Message;
      Result := False;
    end;
  end;
end;

// One entry -> one rule. False (with Problem set) when the entry must be skipped;
// Warnings collects findings that leave the rule usable.
function TryParseRule(Entry: TJSONObject; out Rule: TExceptionRule; out Problem: string;
  var Warnings: TArray<string>): Boolean;
begin
  Rule    := Default(TExceptionRule);
  Problem := '';
  for var Pair in Entry do
    if not IsKnownRuleKey(Pair.JsonString.Value) then
      Warnings := Warnings + [Format('unknown key "%s" (ignored; prefix a comment key with "_")',
        [Pair.JsonString.Value])];

  var Action: TExceptionAction;
  if not ParseExceptionAction(Entry.GetValue<string>('action', ''), Action) then begin
    Problem := '"action" is missing or not one of ignore / log / logStack / break; rule skipped';
    Exit(False);
  end;
  Rule.Action       := Action;
  Rule.ClassNames   := ReadNames(Entry, 'class');
  Rule.ClassIsNames := ReadNames(Entry, 'classIs');
  Rule.Codes        := ReadCodes(Entry, 'code');
  // A `code` that parsed to nothing would silently degrade into a wildcard and
  // make the rule match every exception.
  if (Entry.FindValue('code') <> nil) and (Length(Rule.Codes) = 0) then begin
    Problem := '"code" is not a valid Win32 exception code; rule skipped';
    Exit(False);
  end;
  Rule.MessageSub   := Entry.GetValue<string>('message', '');
  Rule.MessageRegex := Entry.GetValue<string>('messageRegex', '');
  var RegexErr: string;
  if (Rule.MessageRegex <> '') and not IsValidRegex(Rule.MessageRegex, RegexErr) then begin
    // The matcher would treat it as never matching; saying so beats a rule that
    // silently does nothing.
    Problem := Format('"messageRegex" is not a valid regular expression (%s); rule skipped', [RegexErr]);
    Exit(False);
  end;
  var UnitStr := Entry.GetValue<string>('unit', '');
  if SameText(UnitStr, UNKNOWN_UNIT_TOKEN) then
    Rule.MatchUnknownUnit := True
  else
    Rule.UnitName := UnitStr;
  Rule.LineFrom := -1;
  Rule.LineTo   := -1;
  var SingleLine := Entry.GetValue<Integer>('line', -1);
  if SingleLine >= 0 then begin
    Rule.LineFrom := SingleLine;
    Rule.LineTo   := SingleLine;
  end;
  Rule.LineFrom := Entry.GetValue<Integer>('lineFrom', Rule.LineFrom);
  Rule.LineTo   := Entry.GetValue<Integer>('lineTo',   Rule.LineTo);
  Result := True;
end;

function ParseExceptionRulesArray(Arr: TJSONArray;
  out Problems: TArray<string>): TArray<TExceptionRule>;
begin
  Result   := nil;
  Problems := nil;
  if Arr = nil then
    Exit;
  for var I := 0 to Arr.Count - 1 do begin
    var Prefix := Format('rule #%d: ', [I + 1]);
    if not (Arr.Items[I] is TJSONObject) then begin
      Problems := Problems + [Prefix + 'not a JSON object; skipped'];
      Continue;
    end;
    var Rule: TExceptionRule;
    var Problem: string;
    var Warnings: TArray<string> := nil;
    var Parsed := TryParseRule(TJSONObject(Arr.Items[I]), Rule, Problem, Warnings);
    for var W in Warnings do
      Problems := Problems + [Prefix + W];
    if not Parsed then begin
      Problems := Problems + [Prefix + Problem];
      Continue;
    end;
    Result := Result + [Rule];
  end;
end;

function ParseExceptionRulesArray(Arr: TJSONArray): TArray<TExceptionRule>;
begin
  var Problems: TArray<string>;
  Result := ParseExceptionRulesArray(Arr, Problems);
  for var P in Problems do
    DapLog('exceptionRules: ' + P);
end;

function ParseExceptionRulesDocument(Root: TJSONValue;
  out Problems: TArray<string>): TArray<TExceptionRule>;
begin
  Result   := nil;
  Problems := nil;
  if Root is TJSONArray then
    Exit(ParseExceptionRulesArray(TJSONArray(Root), Problems));
  if Root is TJSONObject then begin
    var Rules := TJSONObject(Root).FindValue('exceptionRules');
    if Rules is TJSONArray then
      Exit(ParseExceptionRulesArray(TJSONArray(Rules), Problems));
  end;
  Problems := ['not a rules document: expected an array of rules or an object with an "exceptionRules" array'];
end;

function LoadExceptionRulesFile(const Path: string): TArray<TExceptionRule>;
begin
  Result := nil;
  if (Path = '') or not FileExists(Path) then
    Exit;
  try
    var Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Path, TEncoding.UTF8));
    if Root = nil then
      Exit;
    try
      var Problems: TArray<string>;
      Result := ParseExceptionRulesDocument(Root, Problems);
      for var P in Problems do
        DapLog('exceptionRules: ' + Path + ': ' + P);
    finally
      Root.Free;
    end;
  except
    on E: Exception do
      DapLog('LoadExceptionRulesFile failed: ' + E.Message);
  end;
end;

function DefaultGlobalExceptionRulesPath: string;
begin
  var Home := GetEnvironmentVariable('USERPROFILE');
  if Home = '' then
    Exit('');
  Result := TPath.Combine(TPath.Combine(Home, '.DelphiWinDebugger'), 'exceptionRules.json');
end;

function ExceptionRulesFileMTime(const Path: string): TDateTime;
begin
  Result := 0;
  if (Path = '') or not FileExists(Path) then
    Exit;
  try
    Result := TFile.GetLastWriteTime(Path);
  except
    Result := 0;
  end;
end;

{ TExceptionRuleChain }

procedure TExceptionRuleChain.AddFileTier(Kind: TExceptionRuleTierKind;
  const Path, Description: string);
begin
  if Path = '' then
    Exit;
  var Tier := Default(TExceptionRuleTier);
  Tier.Kind        := Kind;
  Tier.Path        := Path;
  Tier.Description := Description;
  Tier.MTime       := ExceptionRulesFileMTime(Path);
  Tier.Rules       := LoadExceptionRulesFile(Path);
  FFileTiers := FFileTiers + [Tier];
  if Length(Tier.Rules) > 0 then
    DapLog(Format('exceptionRules: %d %s rule(s) from %s', [Length(Tier.Rules), Description, Path]));
end;

procedure TExceptionRuleChain.LoadFiles(const ProjectFile, GlobalPath: string);
begin
  FFileTiers := nil;
  if ProjectFile <> '' then begin
    AddFileTier(rtkProjectLocal,  LocalProjectExceptionRulesPath(ProjectFile), 'project (local)');
    AddFileTier(rtkProjectShared, ProjectExceptionRulesPath(ProjectFile),      'project (shared)');
  end;
  AddFileTier(rtkMachineWide, GlobalPath, 'machine-wide');
end;

function TExceptionRuleChain.Combined: TArray<TExceptionRule>;
begin
  Result := nil;
  for var Tier in FFileTiers do
    Result := Result + Tier.Rules;
end;

function TExceptionRuleChain.ReloadChangedFiles(out Messages: TArray<string>): Boolean;
begin
  Messages := nil;
  for var I := 0 to High(FFileTiers) do begin
    var MTime := ExceptionRulesFileMTime(FFileTiers[I].Path);
    if MTime = FFileTiers[I].MTime then
      Continue;
    FFileTiers[I].MTime := MTime;
    FFileTiers[I].Rules := LoadExceptionRulesFile(FFileTiers[I].Path);
    Messages := Messages + [Format('[exceptionRules] reloaded %s (%d rules): %s',
      [FFileTiers[I].Description, Length(FFileTiers[I].Rules), FFileTiers[I].Path])];
  end;
  Result := Length(Messages) > 0;
end;

end.
