unit PackageInfoReader;

// The PACKAGEINFO resource of a Delphi binary: the units it contains and the
// packages it requires. The linker writes it into every package (.bpl) and
// into executables as well; it is what System.SysUtils.GetPackageInfo walks.
//
// Reading it costs one resource lookup in a file mapped as data: nothing is
// executed, no debug information is parsed, and the bitness of the file does
// not matter. That makes it the cheap answer to "can this module contain unit
// X", which a front end needs while modules load by the hundred and which the
// profiling scope needs before it decides to parse a module at all.
//
// Layout (System.SysUtils, TPackageInfoHeader / TPkgName / TUnitName):
//
//   Flags          : UInt32
//   RequiresCount  : Int32
//   RequiresCount x  HashCode : Byte, Name : UTF-8, zero-terminated
//   ContainsCount  : Int32
//   ContainsCount x  Flags : Byte, HashCode : Byte, Name : UTF-8, zero-terminated
//
// The unit depends on the RTL and the Windows API only.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

type
  /// <summary>What the PACKAGEINFO resource of one binary says.</summary>
  TPackageInfo = record
    /// <summary>The header's flags (<c>pfPackageModule</c>, <c>pfRunOnly</c>
    /// and the rest of the <c>pf*</c> constants of System.SysUtils).</summary>
    Flags: Cardinal;
    /// <summary>The packages the binary requires, as recorded: file names such
    /// as <c>rtl290.bpl</c>, in the resource's order. An entry with an empty
    /// name is left out.</summary>
    RequiredPackages: TArray<string>;
    /// <summary>The units the binary contains, as recorded (full dotted names
    /// such as <c>System.SysUtils</c>), in the resource's order. An entry with
    /// an empty name is left out.</summary>
    ContainedUnits: TArray<string>;
    /// <summary>True when both lists were read to their end. False when the
    /// resource stops early or carries a negative count: the lists then hold
    /// what was read before that point.</summary>
    Complete: Boolean;
  end;

/// <summary>Decodes a PACKAGEINFO resource from memory.</summary>
/// <param name="Data">First byte of the resource.</param>
/// <param name="Size">Its size in bytes. Nothing past it is read.</param>
/// <param name="Info">Receives what was decoded; reset first.</param>
/// <returns>True when the block holds at least the header. <c>Info.Complete</c>
/// then says whether the two lists were read in full.</returns>
function ParsePackageInfo(Data: PByte; Size: NativeInt; out Info: TPackageInfo): Boolean;

/// <summary>Reads the PACKAGEINFO resource of a binary on disk.</summary>
/// <remarks>The file is mapped with <c>LOAD_LIBRARY_AS_DATAFILE</c>: no code of
/// it runs, and a 32-bit file is read from a 64-bit process and the reverse.</remarks>
/// <param name="ModulePath">Path of the .bpl, .exe or .dll.</param>
/// <param name="Info">Receives what was decoded; reset first.</param>
/// <returns>False when the file does not exist, cannot be mapped, or has no
/// PACKAGEINFO resource holding at least a header. True otherwise, with
/// <c>Info.Complete</c> saying whether the lists were read in full.</returns>
function ReadPackageInfo(const ModulePath: string; out Info: TPackageInfo): Boolean;

/// <summary>The keys under which a contained unit is looked up by the name of
/// one of its source files.</summary>
/// <remarks>A source file gives a unit name without its unit scope
/// (<c>Forms.pas</c> for <c>Vcl.Forms</c>) as often as with it, so a unit is
/// indexed under both spellings.</remarks>
/// <param name="UnitName">A unit name as <c>TPackageInfo.ContainedUnits</c>
/// holds it.</param>
/// <returns>The lowercase full name, followed by its last dotted segment when
/// the name has more than one; empty for an empty name.</returns>
function PackageUnitLookupKeys(const UnitName: string): TArray<string>;

implementation

uses
  System.SysUtils, Winapi.Windows;

const
  RESOURCE_NAME = 'PACKAGEINFO';
  HEADER_SIZE   = SizeOf(Cardinal) + SizeOf(Integer);
  // What precedes the name in an entry of each list.
  REQUIRES_PREFIX = 1;   // HashCode
  CONTAINS_PREFIX = 2;   // Flags, HashCode

// Length of the zero-terminated name starting at Offset, or -1 when the block
// ends before its terminator.
function NameLengthAt(Data: PByte; Size, Offset: NativeInt): NativeInt;
begin
  Result := 0;
  while Offset + Result < Size do begin
    if Data[Offset + Result] = 0 then
      Exit;
    Inc(Result);
  end;
  Result := -1;
end;

function Utf8NameAt(Data: PByte; Offset, NameLength: NativeInt): string;
begin
  var Raw: UTF8String;
  SetString(Raw, PAnsiChar(@Data[Offset]), NameLength);
  Result := UTF8ToString(Raw);
end;

function ReadInt32At(Data: PByte; Offset: NativeInt): Integer;
begin
  Move(Data[Offset], Result, SizeOf(Result));
end;

// Reads Count entries of one list from Offset on. False when the block ends
// inside the list; Names then holds the entries read before that.
function ReadNameList(Data: PByte; Size: NativeInt; var Offset: NativeInt;
  Count, PrefixSize: Integer; var Names: TArray<string>): Boolean;
begin
  for var I := 0 to Count - 1 do begin
    // The prefix and at least the terminator must be there.
    if Offset + PrefixSize + 1 > Size then
      Exit(False);
    var NameLength := NameLengthAt(Data, Size, Offset + PrefixSize);
    if NameLength < 0 then
      Exit(False);
    if NameLength > 0 then begin
      var Name := Utf8NameAt(Data, Offset + PrefixSize, NameLength);
      if Name <> '' then
        Names := Names + [Name];
    end;
    Inc(Offset, PrefixSize + NameLength + 1);
  end;
  Result := True;
end;

function ParsePackageInfo(Data: PByte; Size: NativeInt; out Info: TPackageInfo): Boolean;
begin
  Info := Default(TPackageInfo);
  if (Data = nil) or (Size < HEADER_SIZE) then
    Exit(False);
  Result := True;

  Move(Data[0], Info.Flags, SizeOf(Info.Flags));
  var RequiresCount := ReadInt32At(Data, SizeOf(Cardinal));
  if RequiresCount < 0 then
    Exit;
  var Offset: NativeInt := HEADER_SIZE;
  if not ReadNameList(Data, Size, Offset, RequiresCount, REQUIRES_PREFIX, Info.RequiredPackages) then
    Exit;

  if Offset + SizeOf(Integer) > Size then
    Exit;
  var ContainsCount := ReadInt32At(Data, Offset);
  if ContainsCount < 0 then
    Exit;
  Inc(Offset, SizeOf(Integer));
  if not ReadNameList(Data, Size, Offset, ContainsCount, CONTAINS_PREFIX, Info.ContainedUnits) then
    Exit;

  Info.Complete := True;
end;

function ReadPackageInfo(const ModulePath: string; out Info: TPackageInfo): Boolean;
begin
  Info := Default(TPackageInfo);
  if (ModulePath = '') or not FileExists(ModulePath) then
    Exit(False);
  var Module := LoadLibraryEx(PChar(ModulePath), 0, LOAD_LIBRARY_AS_DATAFILE);
  if Module = 0 then
    Exit(False);
  try
    var Resource := FindResource(Module, RESOURCE_NAME, RT_RCDATA);
    if Resource = 0 then
      Exit(False);
    var Loaded := LoadResource(Module, Resource);
    if Loaded = 0 then
      Exit(False);
    var Data: PByte := LockResource(Loaded);
    if Data = nil then
      Exit(False);
    Result := ParsePackageInfo(Data, SizeofResource(Module, Resource), Info);
  finally
    FreeLibrary(Module);
  end;
end;

function PackageUnitLookupKeys(const UnitName: string): TArray<string>;
begin
  var Full := LowerCase(UnitName);
  if Full = '' then
    Exit(nil);
  Result := [Full];
  var LastDot := LastDelimiter('.', Full);
  if LastDot > 0 then
    Result := Result + [Copy(Full, LastDot + 1, MaxInt)];
end;

end.
