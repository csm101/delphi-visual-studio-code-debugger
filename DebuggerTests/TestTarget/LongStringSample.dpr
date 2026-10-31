program LongStringSample;

// Long-string fixture for the value readers' truncation limit (the MCP
// `maxStringLength` argument) and for `read_memory` beyond 4096 bytes: every
// string kind the readers decode, most of them longer than the default limit of
// 4096, plus 300-character pointer strings -- the length at which PAnsiChar and
// PWideChar used to lose their beginning.
//
// Every text is the pattern 'a'..'z' repeated (PatternText), so a test can
// recompute any prefix of it. Separate target for the usual reason: adding
// scenarios to TestTarget shifts RSM import indices and marker ordering.
// GUI subsystem, like every fixture: no console window.

uses
  Winapi.Windows, System.SysUtils;

const
  PAGE = 4096;

var
  GSink: Integer = 0;

function PatternText(Count: Integer): string;
begin
  SetLength(Result, Count);
  for var I := 1 to Count do
    Result[I] := Char(Ord('a') + (I - 1) mod 26);
end;

// Called by the tests through evaluate_expression: the string a function of the
// program returns goes through the same readers as a variable.
function LongTextOf(Count: Integer): string;
begin
  Result := PatternText(Count);
end;

// Two readable pages followed by a PAGE_NOACCESS one. EdgeEnd is the address of
// the first unreadable byte; the two strings end right before it, so a reader
// whose fixed-size chunk runs past the terminator faults on the guard page.
procedure MakePageEdgeStrings(out EdgeAnsi: PAnsiChar; out EdgeWide: PWideChar;
  out EdgeEnd: NativeUInt);
const
  ANSI_TEXT: AnsiString = 'edge';
  WIDE_TEXT: string = 'edge';
begin
  var Block := PByte(VirtualAlloc(nil, 3 * PAGE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE));
  var OldProtect: DWORD;
  VirtualProtect(Block + 2 * PAGE, PAGE, PAGE_NOACCESS, OldProtect);
  EdgeEnd  := NativeUInt(Block + 2 * PAGE);
  EdgeAnsi := PAnsiChar(Block + 2 * PAGE - 5);
  Move(PAnsiChar(ANSI_TEXT)^, EdgeAnsi^, 5);
  EdgeWide := PWideChar(Block + 2 * PAGE - 15);
  Move(PWideChar(WIDE_TEXT)^, EdgeWide^, 10);
end;

procedure InspectLongStrings;
var
  EdgeAnsi:     PAnsiChar;
  EdgeWide:     PWideChar;
  EdgeEnd:      NativeUInt;
  LongUnicode:  string;
  LongWide:     WideString;
  LongAnsi:     AnsiString;
  LongUtf8:     UTF8String;
  LongRaw:      RawByteString;
  Ansi300:      AnsiString;
  Ansi5000:     AnsiString;
  Wide300:      string;
  Wide5000:     string;
  PAnsi300:     PAnsiChar;
  PAnsi5000:    PAnsiChar;
  PWide300:     PWideChar;
  PWide5000:    PWideChar;
begin
  LongUnicode := PatternText(10000);
  LongWide    := PatternText(5000);
  LongAnsi    := AnsiString(PatternText(5000));
  // 4095 ASCII bytes, then U+00E8 -- two bytes in UTF-8 -- 1000 times: the
  // default limit of 4096 bytes falls in the middle of the first one.
  LongUtf8    := UTF8String(StringOfChar(WideChar('x'), 4095) + StringOfChar(WideChar($E8), 1000));
  LongRaw     := RawByteString(AnsiString(PatternText(5000)));
  SetCodePage(LongRaw, $FFFF, False);
  Ansi300     := AnsiString(PatternText(300));
  Ansi5000    := AnsiString(PatternText(5000));
  Wide300     := PatternText(300);
  Wide5000    := PatternText(5000);
  PAnsi300    := PAnsiChar(Ansi300);
  PAnsi5000   := PAnsiChar(Ansi5000);
  PWide300    := PWideChar(Wide300);
  PWide5000   := PWideChar(Wide5000);
  MakePageEdgeStrings(EdgeAnsi, EdgeWide, EdgeEnd);
  GSink := Integer(EdgeEnd and 1) + Length(EdgeAnsi) + Length(EdgeWide) + Length(LongUnicode) +
    Length(LongWide) + Length(LongAnsi) + Length(LongUtf8) + Length(LongRaw) + Length(PAnsi300) +
    Length(PAnsi5000) + Length(PWide300) + Length(PWide5000);
  GSink := GSink + Length(LongTextOf(1));                         // {BP:LONGSTR_BODY}
end;

begin
  InspectLongStrings;
end.
