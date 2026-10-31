program CallResultSample;

// Fixture for the release of what synthetic calls leave behind. Each Shared*
// function returns a managed value that shares a reference with a global, so
// every call made from the debugger raises a reference count the program itself
// can report through the *RefCount functions (which return plain Integers and
// therefore leave nothing behind). Released correctly, the counts are back at
// their baseline once the debuggee has run again; leaked, they keep climbing.
//
// Separate target for the usual reason: adding scenarios to TestTarget shifts
// RSM import indices and marker ordering. GUI subsystem, like every fixture.

uses
  System.SysUtils, System.Variants;

type
  TCounted = class(TInterfacedObject)
  end;

var
  GSink:        Integer = 0;
  GText:        string;
  GVariantText: string;
  GVariant:     Variant;
  GImpl:        TCounted;
  GIntf:        IInterface;

function SharedText: string;
begin
  Result := GText;
end;

function SharedVariant: Variant;
begin
  Result := GVariant;
end;

function SharedIntf: IInterface;
begin
  Result := GIntf;
end;

function TextRefCount: Integer;
begin
  Result := StringRefCount(GText);
end;

function VariantTextRefCount: Integer;
begin
  Result := StringRefCount(GVariantText);
end;

function IntfRefCount: Integer;
begin
  Result := GImpl.RefCount;
end;

procedure RunCallResults;
begin
  // Built at run time, so each is a heap string with a real reference count
  // (a literal's is -1 and never moves).
  GText        := StringOfChar(WideChar('t'), 16);
  GVariantText := StringOfChar(WideChar('v'), 16);
  GVariant     := GVariantText;     // the Variant holds a second reference
  GImpl        := TCounted.Create;
  GIntf        := GImpl;            // RefCount 1
  GSink := 1;                                                    // {BP:CALLRES_FIRST}
  GSink := 2;                                                    // {BP:CALLRES_SECOND}
  // Keep every function in the binary; never true at run time.
  if GSink < 0 then
    GSink := Length(SharedText) + Ord(VarIsNull(SharedVariant)) + Ord(SharedIntf <> nil) +
      TextRefCount + VariantTextRefCount + IntfRefCount;
end;

begin
  RunCallResults;
end.
