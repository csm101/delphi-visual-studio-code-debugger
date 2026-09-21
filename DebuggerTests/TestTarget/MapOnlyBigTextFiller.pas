unit MapOnlyBigTextFiller;

// Bulk only: pushes every unit linked after it past 4 MB of .text (see
// MapOnlyBigText.dpr). Each routine expands MapOnlyBigTextFill4.inc, which
// nests three more include levels into 20,000 statements, so the source stays
// small while the code does not. Nothing here is ever executed.

interface

procedure RunFiller;

implementation

var
  GFillSink: Integer = 0;

procedure Fill1; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill2; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill3; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill4; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill5; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill6; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill7; begin {$I MapOnlyBigTextFill4.inc} end;
procedure Fill8; begin {$I MapOnlyBigTextFill4.inc} end;

procedure RunFiller;
begin
  Fill1;
  Fill2;
  Fill3;
  Fill4;
  Fill5;
  Fill6;
  Fill7;
  Fill8;
end;

end.
