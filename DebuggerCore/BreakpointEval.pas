unit BreakpointEval;

// Shared conditional / hit-count / log-point breakpoint evaluation. Both frontends
// (TDapServer and TDebugSession) delegate here so the condition/hit/logpoint logic
// lives once. The evaluator computes a neutral decision (stop / resume / log) plus
// the rendered log text; each frontend does its own output (DAP a console output
// event, the session its debugger-output ring buffer).
//
// Ownership: the evaluator owns nothing. Debugger / Rtti / DebugInfo / Readers are
// references the owner sets before use (the owner also guarantees Rtti is created).

interface

uses
  System.SysUtils,
  DebugTarget, DebugInfoTypes, DebugInfoSet, DelphiRtti, DelphiValueReaders, ExprEval;

type
  // What to do when a planted breakpoint fires.
  //   bpStop   - surface a stop to the user.
  //   bpResume - silently resume (condition/hit-count not met).
  //   bpLog    - a logpoint fired: emit LogText, then resume (do not stop).
  TBpAction = (bpStop, bpResume, bpLog);

  TBpEvaluator = class
  public
    // References set by the owner as they become available. Not owned here.
    Debugger:  IDebugTarget;
    Rtti:      TDelphiRtti;
    DebugInfo: TDebugInfoSet;
    Readers:   TDelphiValueReader;

    // Evaluate an expression in the current frame context. Requires Rtti set by
    // the owner (created on the first stop). Returns False on any failure.
    function EvalExpr(const Expr: string; out Val: TExprValue): Boolean;

    // Parses the DAP-style hit-condition forms VS Code emits: "5"/"=5" (Nth hit),
    // ">5", ">=5", "%5" (every Nth). Empty or unparseable -> fire (True).
    class function HitConditionMet(const HitCond: string; HitCount: Integer): Boolean; static;

    // Renders a log-point template, replacing {expr} with the evaluated value.
    // `{{` / `}}` are literal braces; an unparseable expression renders as the
    // original `{...}` text so the user sees the typo.
    function RenderLogMessage(const Template: string): string;

    // The full fired-breakpoint decision: condition -> hit-count gate -> logpoint.
    // On bpLog, LogText holds the rendered message (empty otherwise).
    function Decide(const Condition, HitCondition, LogMessage: string;
      HitCount: Integer; out LogText: string): TBpAction;
  private
    function FormatExprValue(const E: TExprValue): string;
  end;

implementation

function TBpEvaluator.EvalExpr(const Expr: string; out Val: TExprValue): Boolean;
begin
  Result := False;
  Val    := Default(TExprValue);
  if (Debugger = nil) or (Debugger.ProcessHandle = 0) or (Rtti = nil) then
    Exit;
  var Eval := TExprEvaluator.Create(Debugger, Rtti, DebugInfo);
  try
    Result := Eval.Evaluate(Expr, Val);
  finally
    Eval.Free;
  end;
end;

class function TBpEvaluator.HitConditionMet(const HitCond: string;
  HitCount: Integer): Boolean;
var
  N, Code: Integer;
begin
  Result := True;
  var S := Trim(HitCond);
  if S = '' then
    Exit;
  var Op := '';
  var ParseFrom := 1;
  if S.StartsWith('>=') then begin Op := '>='; ParseFrom := 3; end
  else if S.StartsWith('>') then begin Op := '>'; ParseFrom := 2; end
  else if S.StartsWith('%') then begin Op := '%'; ParseFrom := 2; end
  else if S.StartsWith('=') then begin Op := '='; ParseFrom := 2; end;
  Val(Trim(Copy(S, ParseFrom, MaxInt)), N, Code);
  if Code <> 0 then
    Exit;
  if      Op = '>=' then Result := HitCount >= N
  else if Op = '>'  then Result := HitCount >  N
  else if Op = '%'  then Result := (N > 0) and (HitCount mod N = 0)
  else                   Result := HitCount =  N;
end;

function TBpEvaluator.FormatExprValue(const E: TExprValue): string;
var
  LV: TLocalValue;
begin
  LV            := Default(TLocalValue);
  LV.TypeHint   := E.TypeHint;
  LV.Address    := E.Address;
  LV.RawValue   := E.RawValue;
  LV.ValueValid := E.IsValid;
  LV.Kind       := lkLocal;
  Result := Readers.FormatLocalValue(LV);
end;

function TBpEvaluator.RenderLogMessage(const Template: string): string;
var
  Buf: TStringBuilder;
begin
  Buf := TStringBuilder.Create;
  try
    var I := 1;
    while I <= Length(Template) do begin
      if (Template[I] = '{') and (I + 1 <= Length(Template)) and (Template[I + 1] = '{') then begin
        Buf.Append('{'); Inc(I, 2);
      end
      else if (Template[I] = '}') and (I + 1 <= Length(Template)) and (Template[I + 1] = '}') then begin
        Buf.Append('}'); Inc(I, 2);
      end
      else if Template[I] = '{' then begin
        var EndPos := Pos('}', Template, I + 1);
        if EndPos = 0 then begin
          Buf.Append(Template[I]); Inc(I);
        end
        else begin
          var Inner := Copy(Template, I + 1, EndPos - I - 1);
          var Val: TExprValue;
          if EvalExpr(Inner, Val) then
            Buf.Append(FormatExprValue(Val))
          else
            Buf.Append('{' + Inner + '}');
          I := EndPos + 1;
        end;
      end
      else begin
        Buf.Append(Template[I]); Inc(I);
      end;
    end;
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

function TBpEvaluator.Decide(const Condition, HitCondition, LogMessage: string;
  HitCount: Integer; out LogText: string): TBpAction;
begin
  LogText := '';
  var ShouldStop := True;
  // Condition: an arbitrary expression that must evaluate to a non-zero value.
  // An eval failure suppresses the stop so a typo doesn't behave as an
  // unconditional breakpoint.
  if Condition <> '' then begin
    var Val: TExprValue;
    if not EvalExpr(Condition, Val) then
      ShouldStop := False
    else
      ShouldStop := Val.RawValue <> 0;
  end;
  // Hit count gates on top of the condition.
  if ShouldStop and (HitCondition <> '') then
    ShouldStop := HitConditionMet(HitCondition, HitCount);
  if not ShouldStop then
    Exit(bpResume);
  // Logpoint: when the gate passed, emit the rendered message and DO NOT stop.
  if LogMessage <> '' then begin
    LogText := RenderLogMessage(LogMessage);
    Exit(bpLog);
  end;
  Result := bpStop;
end;

end.
