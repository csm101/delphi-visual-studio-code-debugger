unit TestPkgUnit;

interface

uses
  System.SysUtils;

type
  // A class DEFINED INSIDE the BPL. Mirrors SampleApp's real shape where
  // forms / business objects live in runtime-loaded packages and must be
  // inspectable from the debugger even though the host EXE never declared
  // them. The debugger has to resolve this class's member table from the
  // BPL's own debug info (RSM / DCP / TD32), not from the EXE.
  TPkgWidget = class
  private
    FTag:   Integer;
    FLabel: string;
  public
    constructor Create(ATag: Integer; const ALabel: string);
    property Tag: Integer read FTag;
    property LabelText: string read FLabel;
  end;

  // Exception class DEFINED INSIDE the BPL. The debugger must report its
  // ClassName / Message from the BPL's runtime RTTI when it surfaces in a
  // handler, even though the host EXE never declared the type.
  EPkgError = class(Exception);

var
  // A unit-level global that lives INSIDE the BPL, with a name unique across
  // the whole process (no cross-unit / cross-binary collision). The cross-BPL
  // test stops in the HOST EXE and watches this from the exe frame: it must
  // resolve through the BPL's own per-binary symbol provider (image-base
  // shifted), proving cross-module global resolution for the common real case
  // (a form / business global living in a runtime package, inspected from
  // elsewhere). Set in this unit's initialization, which runs during the
  // host's LoadPackage, before the host reaches its own stop point.
  GPkgUniqueGlobal: Integer;

  // Cross-BINARY collision: the SAME global name is declared in TestPackage2
  // (as Double). With both BPLs loaded, watching this from a frame inside
  // THIS package must resolve to this binary's copy (Integer), never the
  // other binary's. Set in initialization.
  GCrossBinAmbiguous: Integer;

  // Uses-graph collision: the SAME global name is also declared in the HOST
  // exe (TestTarget, value 444). TestPackage2 `requires` this package but NOT
  // the host, so when stopped in a TestPackage2 frame (which does not declare
  // GUsesGraph) the watch must resolve to THIS required package's copy (333),
  // never the unrelated host's 444. Set in initialization.
  GUsesGraph: Integer;

function PkgAdd(A, B: Integer): Integer;

// Creates a TPkgWidget and returns its address WITHOUT freeing it. The host
// keeps the pointer past UnloadPackage so the debugger can be asked to inspect
// an instance whose class (VMT / debug info) lives in an unloaded module.
function PkgMakePersistentWidget: NativeUInt;

implementation

uses
  Winapi.Windows;

constructor TPkgWidget.Create(ATag: Integer; const ALabel: string);
begin
  inherited Create;
  FTag   := ATag;
  FLabel := ALabel;
end;

// A second BPL-resident function, called from PkgAdd. Stepping INTO the
// call must land here -- proves step-into resolves the next source line from
// the BPL's own debug info, not just the EXE's.
function PkgInner(X: Integer): Integer;
begin
  Result := X * 10;    // {BP:PKG_INNER_BODY}
end;

function PkgAdd(A, B: Integer): Integer;
var
  W: TPkgWidget;
begin
  W := TPkgWidget.Create(A + B, 'pkg-widget');
  try
    Result := W.Tag;          // {BP:PKG_BP}
    Result := PkgInner(Result); // {BP:PKG_STEP_CALL} step-into enters PkgInner
    Sleep(0);
  finally
    W.Free;
  end;
end;

// Raises a BPL-defined exception and catches it locally; the handler is a
// deterministic stop point for the cross-module exception-RTTI test. The
// BPL's initialization triggers it only when the host was launched with
// --pkg-raise (FindCmdLineSwitch reads the shared process command line).
procedure PkgRaiseDefined;
begin
  try
    raise EPkgError.Create('pkg-exc-msg');
  except
    on E: EPkgError do
      Sleep(0);   // {BP:PKG_EXC_HANDLER}  E is a BPL-defined exception
  end;
end;

function PkgMakePersistentWidget: NativeUInt;
begin
  // Intentionally leaked: the host holds this pointer across UnloadPackage.
  Result := NativeUInt(TPkgWidget.Create(99, 'persistent-pkg-widget'));
end;

exports
  PkgMakePersistentWidget name 'PkgMakePersistentWidget';

initialization
  // Runs synchronously when the host's LoadPackage('TestPackage.bpl')
  // returns. A BP planted at PKG_BP fires here — the integration test
  // uses this entry point because LoadPackage gives us a deterministic
  // moment when the BPL's symbols are loaded AND its code runs.
  PkgAdd(2, 3);
  GPkgUniqueGlobal := 24680;
  GCrossBinAmbiguous := 111;
  GUsesGraph := 333;
  if FindCmdLineSwitch('pkg-raise') or FindCmdLineSwitch('-pkg-raise') then
    PkgRaiseDefined;

end.
