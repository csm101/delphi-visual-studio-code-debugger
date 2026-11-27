unit PeImageFile;

// A PE file on disk, mapped read-only and addressed the way a loaded module is:
// by virtual address. It lets code written against a byte reader of a live
// process (Disassembler.TDisasmByteReader) run on a binary that is never
// started -- the routine analysis, its sweep tool and its static tests.
//
// What a read returns is what the loader would have mapped at the preferred
// base, with nothing relocated: the headers at RVA 0, each section at its RVA,
// and zeros for the part of a section the file does not back. A read never
// crosses a section end; it returns fewer bytes instead, as the reader
// contract allows.
//
// The unit depends on nothing of the engine.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

uses
  System.SysUtils, Winapi.Windows;

type
  /// <summary>One section header of a PE file.</summary>
  TPeFileSection = record
    /// <summary>Section name, at most eight characters.</summary>
    Name: string;
    /// <summary>Address of the section, relative to the image base.</summary>
    Rva: Cardinal;
    /// <summary>Size of the section once mapped.</summary>
    VirtualSize: Cardinal;
    /// <summary>File offset of the section's bytes.</summary>
    RawOffset: Cardinal;
    /// <summary>Number of bytes the file holds for the section.</summary>
    RawSize: Cardinal;
    /// <summary>The <c>IMAGE_SCN_*</c> flags.</summary>
    Characteristics: Cardinal;
  end;

  /// <summary>A PE file mapped read-only, readable by virtual address.</summary>
  TPeImageFile = class
  private
    FPath:          string;
    FFile:          THandle;
    FMapping:       THandle;
    FView:          PByte;
    FFileSize:      Int64;
    FMachine:       Word;
    FIs64:          Boolean;
    FImageBase:     UInt64;
    FSizeOfImage:   Cardinal;
    FSizeOfHeaders: Cardinal;
    FSections:      TArray<TPeFileSection>;
    FLastSection:   Integer;
    procedure ParseHeaders;
    function  SectionAt(Rva: Cardinal): Integer;
  public
    /// <summary>Maps the file and reads its headers.</summary>
    /// <param name="Path">Path of an executable or a DLL / BPL.</param>
    /// <exception cref="EOSError">The file cannot be opened or mapped.</exception>
    /// <exception cref="EInvalidOpException">The file is not a PE image.</exception>
    constructor Create(const Path: string);
    destructor Destroy; override;
    /// <summary>Reads bytes by virtual address. Has the signature of
    /// <c>Disassembler.TDisasmByteReader</c>.</summary>
    /// <param name="VA">Address, as if the image were loaded at <c>ImageBase</c>.</param>
    /// <param name="Buf">Receives the bytes.</param>
    /// <param name="Size">Number of bytes wanted.</param>
    /// <returns>The number of bytes placed in <c>Buf</c>: fewer than
    /// <c>Size</c> at the end of the headers or of a section, 0 when nothing is
    /// mapped at the address.</returns>
    function Read(VA: UInt64; Buf: Pointer; Size: Integer): Integer;
    /// <summary>Path given to the constructor.</summary>
    property Path: string read FPath;
    /// <summary>The <c>IMAGE_FILE_MACHINE_*</c> value of the file header.</summary>
    property Machine: Word read FMachine;
    /// <summary>True for a PE32+ image.</summary>
    property Is64: Boolean read FIs64;
    /// <summary>Preferred base of the image: what addresses stored in the file
    /// are relative to.</summary>
    property ImageBase: UInt64 read FImageBase;
    /// <summary>Size of the image once mapped.</summary>
    property SizeOfImage: Cardinal read FSizeOfImage;
    /// <summary>The section headers, in file order. Read-only.</summary>
    property Sections: TArray<TPeFileSection> read FSections;
  end;

implementation

const
  PE_SIGNATURE     = $00004550;
  PE32PLUS_MAGIC   = $020B;
  SECTION_HDR_SIZE = 40;

constructor TPeImageFile.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  FFile := CreateFile(PChar(Path), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  if FFile = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  var SizeHigh: DWORD := 0;
  var SizeLow := GetFileSize(FFile, @SizeHigh);
  FFileSize := (Int64(SizeHigh) shl 32) or SizeLow;
  FMapping := CreateFileMapping(FFile, nil, PAGE_READONLY, 0, 0, nil);
  if FMapping = 0 then
    RaiseLastOSError;
  FView := MapViewOfFile(FMapping, FILE_MAP_READ, 0, 0, 0);
  if FView = nil then
    RaiseLastOSError;
  ParseHeaders;
end;

destructor TPeImageFile.Destroy;
begin
  if FView <> nil then
    UnmapViewOfFile(FView);
  if FMapping <> 0 then
    CloseHandle(FMapping);
  if (FFile <> 0) and (FFile <> INVALID_HANDLE_VALUE) then
    CloseHandle(FFile);
  inherited;
end;

procedure TPeImageFile.ParseHeaders;

  procedure NotAnImage;
  begin
    raise EInvalidOpException.Create('not a PE image: ' + FPath);
  end;

begin
  if FFileSize < $40 then
    NotAnImage;
  var PeOffset: Int64 := PCardinal(FView + $3C)^;
  if (PeOffset + 24 + 96 > FFileSize) or (PCardinal(FView + PeOffset)^ <> PE_SIGNATURE) then
    NotAnImage;
  FMachine := PWord(FView + PeOffset + 4)^;
  var SectionCount: Integer := PWord(FView + PeOffset + 6)^;
  var OptionalSize: Integer := PWord(FView + PeOffset + 20)^;
  var Optional := FView + PeOffset + 24;
  FIs64 := PWord(Optional)^ = PE32PLUS_MAGIC;
  if FIs64 then
    FImageBase := PUInt64(Optional + 24)^
  else
    FImageBase := PCardinal(Optional + 28)^;
  FSizeOfImage   := PCardinal(Optional + 56)^;
  FSizeOfHeaders := PCardinal(Optional + 60)^;
  if FSizeOfHeaders > FFileSize then
    FSizeOfHeaders := Cardinal(FFileSize);

  var FirstSection: Int64 := PeOffset + 24 + OptionalSize;
  if FirstSection + Int64(SectionCount) * SECTION_HDR_SIZE > FFileSize then
    NotAnImage;
  SetLength(FSections, SectionCount);
  for var I := 0 to SectionCount - 1 do begin
    var Header := FView + FirstSection + Int64(I) * SECTION_HDR_SIZE;
    var RawName: array[0..8] of AnsiChar;
    FillChar(RawName, SizeOf(RawName), 0);
    Move(Header^, RawName, 8);
    FSections[I].Name            := string(AnsiString(PAnsiChar(@RawName[0])));
    FSections[I].VirtualSize     := PCardinal(Header + 8)^;
    FSections[I].Rva             := PCardinal(Header + 12)^;
    FSections[I].RawSize         := PCardinal(Header + 16)^;
    FSections[I].RawOffset       := PCardinal(Header + 20)^;
    FSections[I].Characteristics := PCardinal(Header + 36)^;
  end;
end;

function TPeImageFile.SectionAt(Rva: Cardinal): Integer;

  function Holds(Index: Integer): Boolean;
  begin
    var Section := FSections[Index];
    var Extent: UInt64 := Section.VirtualSize;
    if Section.RawSize > Extent then
      Extent := Section.RawSize;
    Result := (Rva >= Section.Rva) and (UInt64(Rva) < UInt64(Section.Rva) + Extent);
  end;

begin
  if (FLastSection < Length(FSections)) and Holds(FLastSection) then
    Exit(FLastSection);
  for var I := 0 to High(FSections) do
    if Holds(I) then begin
      FLastSection := I;
      Exit(I);
    end;
  Result := -1;
end;

function TPeImageFile.Read(VA: UInt64; Buf: Pointer; Size: Integer): Integer;
begin
  Result := 0;
  if (Size <= 0) or (VA < FImageBase) or (VA - FImageBase >= FSizeOfImage) then
    Exit;
  var Rva := Cardinal(VA - FImageBase);

  // The headers are mapped at RVA 0, byte for byte as they are in the file.
  if Rva < FSizeOfHeaders then begin
    var Count: Int64 := Int64(FSizeOfHeaders) - Rva;
    if Count > Size then
      Count := Size;
    Move((FView + Rva)^, Buf^, Count);
    Exit(Integer(Count));
  end;

  var Index := SectionAt(Rva);
  if Index < 0 then
    Exit;
  var Section := FSections[Index];
  var Delta: Int64 := Int64(Rva) - Section.Rva;
  var Extent: Int64 := Section.VirtualSize;
  if Section.RawSize > Extent then
    Extent := Section.RawSize;
  var Count: Int64 := Extent - Delta;
  if Count > Size then
    Count := Size;

  // What the file backs is copied; the rest of the section is zero once mapped.
  var Backed: Int64 := Int64(Section.RawSize) - Delta;
  if Int64(Section.RawOffset) + Delta + Backed > FFileSize then
    Backed := FFileSize - Section.RawOffset - Delta;
  if Backed < 0 then
    Backed := 0;
  if Backed > Count then
    Backed := Count;
  if Backed > 0 then
    Move((FView + Section.RawOffset + Delta)^, Buf^, Backed);
  if Count > Backed then
    FillChar((PByte(Buf) + Backed)^, Count - Backed, 0);
  Result := Integer(Count);
end;

end.
