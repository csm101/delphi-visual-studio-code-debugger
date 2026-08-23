program Debugme;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils, Winapi.Windows;

type
  TPoint3D = record
  private
    X, Y, Z: Double;
  end;

  TFoo = class
  private
    Name: string;
    Value: Integer;
    Active: Boolean;
    Pt: TPoint3D;
    constructor Create(const AName: string; AValue: Integer);
  end;

  constructor TFoo.Create(const AName: string; AValue: Integer);
  begin
    inherited Create;
    Name   := AName;
    Value  := AValue;
    Active := True;
    Pt.X   := 1.5;
    Pt.Y   := 2.5;
    Pt.Z   := 3.5;
  end;


  procedure Increment(var x: integer);

  var d1:TDateTime;

     procedure ThisIsALocalProcedure;
     var x1: string;
     const FOO = 'foo';
     begin
        x1 := FOO + ' ' + DateTimeToStr(d1);
        writeln(x1 + ' ' );
     end;

  var s1:string;

  begin
    var d := now;
    d1 := d;
    Inc(x);
    var s := 'foo!';
    s1 := s;
    writeln(s1);
    ThisIsALocalProcedure;
  end;

// Loads TestPlugin.dll and calls Compute(3,7) — expected result: 44.
// Set a BP in TestPluginUnit.Compute to exercise multi-module debugging.
procedure TestDynamicPlugin;
type
  TComputeFn = function(X, Y: Integer): Integer; stdcall;
var
  Lib: HMODULE;
  Fn:  TComputeFn;
begin
  Lib := LoadLibrary('TestPlugin.dll');
  if Lib = 0 then begin
    Writeln('TestPlugin.dll not found — skip dynamic-load test');
    Exit;
  end;
  try
    @Fn := GetProcAddress(Lib, 'Compute');
    if Assigned(Fn) then
      Writeln('TestPlugin.Compute(3, 7) = ', Fn(3, 7))  // expected: 44
    else
      Writeln('TestPlugin: Compute export not found');
  finally
    FreeLibrary(Lib);
  end;
end;

// Opt-in loop for exercising an ATTACH configuration against this program.
// Debugme normally runs to completion in well under a second, so by the time a
// debugger has attached there is nothing left to observe. With `--attach-demo`
// it keeps raising and catching the exception `Debugme.ExceptionSettings.json`
// names, long enough to attach and watch that rule decide. Nothing changes for
// a normal run.
procedure AttachDemoLoop;
begin
  for var Pass := 1 to 120 do begin
    try
      raise Exception.Create('Bare error');
    except
      on E: Exception do
        Writeln('attach-demo ', Pass, ': ', E.Message);
    end;
    Sleep(500);
  end;
end;

var data: TDateTime;
var x: integer;
begin
  if FindCmdLineSwitch('attach-demo') or FindCmdLineSwitch('-attach-demo') then begin
    AttachDemoLoop;
    Halt(0);
  end;

  var localdata := now;
  Writeln(localdata);
  data := localdata + 1;
  var foo := TFoo.Create('hello', 42);
  try
    x := 10;
    writeln(x);
    writeln(foo.Name, ' ', foo.Value);
    Increment(x);
    writeln(x);
    raise Exception.Create('Test error');
    readln;
  except
    on E: Exception do begin
      Writeln('aliased handler entered');
      Writeln(E.ClassName, ': ', E.Message);  // {BP:MAIN_EXC_ALIASED}
      Writeln('aliased handler leaving');
    end;
  end;

  // Bare `except` in the program main block: no alias, so the only name the
  // exception object has is the debugger's synthetic `$exception`.
  try
    raise Exception.Create('Bare error');
  except
    Writeln('bare handler entered');
    Writeln('bare handler still running');    // {BP:MAIN_EXC_BARE}
    Writeln('bare handler leaving');
  end;

  foo.Free;
  TestDynamicPlugin;
end.
