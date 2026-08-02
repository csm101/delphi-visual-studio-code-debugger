program MapOnlyGlobals;

// A target that ships a MAP but NO embedded debug info: built with `-GD` (so the
// MAP carries publics and line numbers) and without `-V` / `-VR` / `-VN` (so the
// exe has no `.debug` TD32 section and there is no `.rsm`). That is a realistic
// release-build shape, and it is the only configuration in which the debugger
// has an ADDRESS for a global but no TYPE for it.
//
// Why it matters: with no type, the reader has no width either, and it used to
// read a fixed 8 bytes. The globals below are deliberately PACKED and small, so
// an over-wide read folds the following variables into the value and reports a
// large number for a Byte. There is nothing in the output to mark that as a
// guess, which makes it the worst kind of wrong.
//
// The values are chosen to be unmistakable: a correct read of GSmallA is 5, and
// any over-read is thousands or more.

// GUI subsystem deliberately (no {$APPTYPE CONSOLE}): launching it must not open
// a console window, the same rule the other test targets follow. It writes
// nothing anyway.

uses
  Winapi.Windows;

var
  GSmallA: Byte  = 5;
  GSmallB: Byte  = $AA;
  GWordC:  Word  = $BEEF;
  GSink:   Integer = 0;

procedure Touch;
begin
  // Keeps every global live and gives the test a line to stop on. Reading them
  // here also proves the program itself sees the declared values, so a wrong
  // answer from the debugger cannot be blamed on the target.
  GSink := GSmallA + GSmallB + Integer(GWordC);   // {BP:MAPONLY_BODY}
  if GSink = 0 then
    ExitProcess(2);
end;

begin
  Touch;
end.
