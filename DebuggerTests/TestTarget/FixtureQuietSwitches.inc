// Compiler switches of FixtureQuiet.pas and FixtureQuietNoSysUtils.pas.
//
// No debug information, like the RTL the fixture links: no line records, no
// local symbols, no reference information. The quiet unit is infrastructure,
// not test subject, and with line records of its own it became part of what
// the tests read as "the fixture's own code" -- the first entry of a line table,
// the routines a dynamic oracle must see executed -- and failed them.
{$D-}
{$L-}
{$Y-}
