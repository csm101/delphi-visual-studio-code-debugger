unit TestTargetFlow;

// Control-flow sampler: stepping (over/into/out, into getter, into
// no-debug RTL), nested try/finally with a handler BP, 3-level nested
// procedures, record returned by value, and BP-edge markers.

interface

procedure RunStepFlow;
procedure RunStepBranchFlow;
procedure RunStepEntryFlow;
procedure RunExcHandlerFlow;
procedure RunNest3Flow;
procedure RunRecByValFlow;

type
  TFlowRec = record X, Y: Integer; end;

  TGetterObj = class
  private
    FVal: Integer;
    function GetVal: Integer;
  public
    constructor Create(AVal: Integer);
    property Val: Integer read GetVal;
  end;

implementation

uses
  System.SysUtils;

type
  TLocalSink = class
    procedure Use(const Tag: string; const Vals: array of const); virtual;
  end;

procedure TLocalSink.Use(const Tag: string; const Vals: array of const);
begin
end;

var
  GSink: TLocalSink;

constructor TGetterObj.Create(AVal: Integer);
begin
  inherited Create;
  FVal := AVal;
end;

function TGetterObj.GetVal: Integer;
begin
  Result := FVal * 2;          // {BP:GETTER_BODY}  step-into target
end;

function StepHelper(X: Integer): Integer;
begin
  Result := X * 2;             // {BP:STEP_HELPER_BODY}
end;

procedure RunStepFlow;
var
  R: Integer;
  G: TGetterObj;
begin
  // {BP:NO_CODE_LINE} comment-only line: the compiler emits no code/line here
  R := 1;                      // {BP:STEP_START}
  R := StepHelper(R);          // {BP:STEP_CALL} step-into enters StepHelper; step-over advances
  R := Length(IntToStr(R));    // step-into here hits RTL (no debug info) -> step-over
  G := TGetterObj.Create(21);
  try
    R := G.Val;                // step-into enters GetVal
  finally
    G.Free;
  end;
  GSink.Use('step-flow', [R]);
end;

// Step-over across a NOT-TAKEN conditional branch. `P` is non-nil at runtime, so
// the `then` body is skipped: execution jumps from the `if` line straight to the
// fall-through line. A step-over that planted a single BP only on the textual
// next line (the skipped `then` body) would never be hit, letting execution run
// free. The step must land on STEP_IF_LAND, not on STEP_BRANCH_END.
procedure RunStepBranchFlow;
var
  P: TObject;
  R: Integer;
begin
  P := GSink;                    // non-nil
  R := 0;
  if P = nil then                // {BP:STEP_IF}
    R := 111;                    // then-body: skipped at runtime (P <> nil)
  R := 222;                      // {BP:STEP_IF_LAND}  step-over must land here
  GSink.Use('step-branch', [R]); // {BP:STEP_BRANCH_END}
end;

function StepMultiLine(Seed: Integer): Integer;
begin                            // {BP:STEP_ML_BEGIN}  a BP here binds to the function entry (pre-prologue)
  Result := Seed;                // {BP:STEP_ML_L1}     step-over from the entry must land here
  Result := Result + 1;          // {BP:STEP_ML_L2}
  Result := Result * 3;          // {BP:STEP_ML_L3}
end;

// Step-over from a function's ENTRY line. A breakpoint on the callee's `begin`
// binds to the function entry, before the prologue has allocated the frame (RSP
// is at its entry value). Stepping over must advance to the next line in the SAME
// function. A step-over that captured the entry RSP and then treated every
// post-prologue same-frame line as a deeper recursive frame would skip them all
// and run free out of the function -- the debugger appeared to freeze.
procedure RunStepEntryFlow;
var
  R: Integer;
begin
  R := 5;
  R := StepMultiLine(R);         // {BP:STEP_ML_CALL}  step-into enters StepMultiLine
  GSink.Use('step-entry', [R]);  // {BP:STEP_ENTRY_END}
end;

procedure RaiseInner;
begin
  raise Exception.Create('flow-exc');
end;

procedure RunExcHandlerFlow;
var
  FinallyRan: Integer;
begin
  FinallyRan := 0;
  try
    try
      RaiseInner;
    finally
      FinallyRan := 1;         // nested try/finally inner cleanup
    end;
  except
    on E: Exception do
      GSink.Use('exc-caught', [E.Message, FinallyRan]);   // {BP:EXC_NESTED_CATCH}
  end;
end;

procedure RunNest3Flow;
var
  OuterV: Integer;

  procedure Mid;
  var
    MidV: Integer;

    procedure Inner;
    var
      InnerV: Integer;
    begin
      InnerV := 3;
      GSink.Use('nest3', [InnerV, MidV, OuterV]);   // {BP:NEST3_INNER}
    end;

  begin
    MidV := 2;
    Inner;
  end;

begin
  OuterV := 1;
  Mid;
end;

function MakeRec(A, B: Integer): TFlowRec;
begin
  Result.X := A;
  Result.Y := B;
end;

procedure RunRecByValFlow;
var
  Rec: TFlowRec;
begin
  Rec := MakeRec(11, 22);      // returned by value
  GSink.Use('rec-byval', [Rec.X, Rec.Y]);   // {BP:REC_BYVAL_BODY}
end;

initialization
  GSink := TLocalSink.Create;

finalization
  GSink.Free;

end.
