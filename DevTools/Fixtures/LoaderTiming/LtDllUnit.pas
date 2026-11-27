unit LtDllUnit;

{
  The one unit of every plain DLL fixture of DevTools\LoaderTimingProbe (LtFixA,
  LtFixB, LtDynA, LtDynB, LtDllStatic, LtDllDynamic). The DLLs differ only in the
  linker directives of their project file.

  What the probe needs from it:

  - instructions whose operand is an absolute address the loader must relocate.
    On x86 every access to a global is one (`Inc(GTouchCount)` is
    `FF 05 <abs32>`). dcc64 addresses globals RIP-relative, so on x64 the only
    such instruction is the hand-written `mov rax, offset` of LtAbsoluteOperand;
  - relocated pointers in data (GTablePointer, the VMT of TLtSquare);
  - a result that comes out wrong, or a fault, if any of those were relocated
    wrongly: LtTouch goes through all of them;
  - an `initialization` section that announces itself.
}

interface

function LtTouch(Value: Integer): Integer; stdcall;
function LtAbsoluteOperand: Pointer;
procedure LtAnnounce(const What: string);

implementation

uses
  Winapi.Windows;

{$I LtAnnounce.inc}

type
  TLtShape = class
    function Sides: Integer; virtual;
  end;

  TLtSquare = class(TLtShape)
    function Sides: Integer; override;
  end;

var
  GTouchCount:   Integer = 0;
  GLastValue:    Integer = 0;
  GTable:        array[0..3] of Integer = (3, 5, 7, 11);
  GTablePointer: PInteger = @GTable[2];

function TLtShape.Sides: Integer;
begin
  Result := 0;
end;

function TLtSquare.Sides: Integer;
begin
  Result := 4;
end;

{$IFDEF CPUX64}
function LtAbsoluteOperand: Pointer;
asm
  .NOFRAME
  MOV RAX, OFFSET GTouchCount
end;
{$ELSE}
function LtAbsoluteOperand: Pointer;
begin
  Result := @GTouchCount;
end;
{$ENDIF}

function LtTouch(Value: Integer): Integer; stdcall;
begin
  Inc(GTouchCount);
  GLastValue := Value;
  var Shape: TLtShape := TLtSquare.Create;
  try
    Result := Value * GTable[GTouchCount and 3] + GTablePointer^ + Shape.Sides;
  finally
    Shape.Free;
  end;
  Result := Result + PInteger(LtAbsoluteOperand)^ * 1000 + GLastValue;
end;

initialization
  LtAnnounce('initialization of unit LtDllUnit');

finalization
  LtAnnounce('finalization of unit LtDllUnit');

end.
