program TdsSample;

// Built with dcc64 -VT (external .tds debug info, NO embedded .debug section) so
// TD32ReaderTests can exercise TTD32FileReader.LoadFromTdsFile. Kept tiny and
// self-contained; launched only via stopAtEntry, so the body never runs.

{$APPTYPE CONSOLE}

uses
  Winapi.Windows;

function TdsSampleAdd(A, B: Integer): Integer;
begin
  Result := A + B;   // {BP:TDS_ADD}
end;

begin
  var X := TdsSampleAdd(2, 3);
  if X < 0 then
    Sleep(1);
  Sleep(60000);
end.
