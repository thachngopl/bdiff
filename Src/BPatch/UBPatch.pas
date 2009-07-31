{
  ------------------------------------------------------------------------------
  UBPatch.pas

  Main program logic for BPatch.

  Copyright (c) 2003-2007 Peter D Johnson (www.delphidabbler.com).

  Based on bpatch.c by Stefan Reuther, copyright (c) 1999 Stefan Reuther
  <Streu@gmx.de>.

  THIS SOFTWARE IS PROVIDED "AS-IS", WITHOUT ANY EXPRESS OR IMPLIED WARRANTY. IN
  NO EVENT WILL THE AUTHORS BE HELD LIABLE FOR ANY DAMAGES ARISING FROM THE USE
  OF THIS SOFTWARE.

  For conditions of distribution and use see the BDiff / BPatch license
  available from http://www.delphidabbler.com/software/bdiff/license

  Change log
  v1.0 of 28 Nov 2003  -  Original Pascal translation of bpatch.c
  v1.1 of 18 Sep 2007  -  Fixed bug preventing overwriting of existing output
                          files.
                       -  Removed "side-by-side" C code.
                       -  Removed conditional Windows / DOS conditional code.
                       -  Updated help screen copyright statement.
                       -  Changed date format displayed by --version switch.
                       -  Fixed small bug in -h and -v options.
                       -  Moved code that redirects stdin to UBDiffUtils unit.
                       -  Updated version constant to 0.2.3 (skipping 0.2.2).
                       -  Changed copyright and license notice.
  ------------------------------------------------------------------------------
}


unit UBPatch;


{
  PASCAL IMPLEMENTATION NOTES:

  The Pascal code is only suitable for use on Windows targets - it compiles to a
  Win32 console application and uses the Windows API.

  Patch files read via shell redirection in the Pascal translation are read in
  pure binary mode, removing necessity to use --input command line switch to
  read patch files that is required in C implementations on MS-DOS/Windows
  systems. The --input command is still supported.
}


interface


{ The program's main interface code: called from the project file }
procedure Main;


implementation

{
  ABOUT THIS UNIT'S IMPLEMENTATION

  v1.0 of this file was a literal translation into Object Pascal of Stefan
  Reuther's bpatch.c file from BPatch v0.2. The original C code was included as
  comments in the file.

  v1.1 of this file has been updated to fix a few issues and is no longer a
  simple translation of Stefan's code. The C code has been stripped from the
  file as a result.
}

{$IOCHECKS OFF}

uses
  // Delphi
  Windows, SysUtils,
  // Project: special types & routines
  UBPatchUtils, UBPatchTypes;

const
  VERSION_ = '0.2.3';     // this program's version number
  FORMAT_VERSION = '02';  // binary diff file format version
  BUFFER_SIZE = 4096;     // size of buffer used to read files

var
  { Global variables }
  progname: string;         // program name
  tempfile: string = '';    // name of temporary file
  tempfd: Integer = 0;      // handle to temp file

{ Exit program with error message }
procedure error_exit(msg: PChar);
begin
  fprintf(stderr, '%s: %s'#13#10, [progname, msg]);
  if tempfd > 0 then
    fclose(tempfd);
  if tempfile <> '' then
    SysUtils.DeleteFile(tempfile);
  Halt(1);
end;

{ Compute simple checksum }
function checksum(data: PChar; len: size_t; l: Longint): Longint;
begin
  while len <> 0 do
  begin
    Dec(len);
    l := ((l shr 30) and 3) or (l shl 2);
    l := l xor PShortInt(data)^;
    Inc(data);
  end;
  Result := l;
end;

{ Get 32-bit quantity from char array }
function getlong(p: PChar): Longint;
var
  q: PByte;
  l: LongWord;
begin
  q := PByte(p);
  l := q^;  Inc(q);
  l := l + 256 * q^;  Inc(q);
  l := l + 65536 * q^;  Inc(q);
  l := l + 16777216 * q^;
  Result := l;
end;

{ Copy data from one stream to another, computing checksums (allows dest = 0) }
procedure copy_data(src, dest: Integer; amount, check: Longint;
  src_is_patch: Integer);
var
  chk: Longint;
  buffer: array[0..BUFFER_SIZE-1] of Char;
  now: size_t;
begin
  chk := 0;

  while amount <> 0 do
  begin
    if amount > BUFFER_SIZE then
      now := BUFFER_SIZE
    else
      now := amount;
    if fread(@buffer, 1, now, src) <> now then
    begin
      if feof(src) then
      begin
        if src_is_patch <> 0 then
          error_exit('Patch garbled - unexpected end of data')
        else
          error_exit('Source file does not match patch');
      end
      else
      begin
        if src_is_patch <> 0 then
          error_exit('Error reading patch file')
        else
          error_exit('Error reading source file');
      end;
    end;
    if dest <> 0 then
      if fwrite(@buffer, 1, now, dest) <> now then
        error_exit('Error writing temporary file');
    chk := checksum(buffer, now, chk);
    Dec(amount, now);
  end;
  if (src_is_patch = 0) and (chk <> check) then
    error_exit('Source file does not  match patch');
end;

{ Apply patch }
procedure bpatch_(const src, dest: PChar);
var
  sf: Integer; {source file}
  df: Integer; {destination file}
  header: array[0..15] of Char;
  p: PChar;
  q: PChar;
  srclen, destlen: Longint;
  size: Longint;
  ofs: Longint;
  c: Integer;
const
  error_msg = 'Patch garbled - invalid section ''%''';
begin
  { read header }
  if fread(@header, 1, 16, stdin) <> 16 then
    error_exit('Patch not in BINARY format');
  if StrLComp(header, PChar('bdiff' + FORMAT_VERSION + #$1A), 8) <> 0 then
    error_exit('Patch not in BINARY format');
  srclen := getlong(@header[8]);
  destlen := getlong(@header[12]);

  { open source file }
  sf := FileOpen(src, fmOpenRead + fmShareDenyNone);
  if sf <= 0 then
  begin
    perror(src);
    Halt(1);
  end;

  { create temporary file }
  if StrLen(dest) = 0 then
    error_exit('Empty destination file name');

  { we use Pascal long string: no need to malloc space for it }
  { hack source file name to get a suitable temp file name }
  tempfile := dest;
  p := StrRScan(PChar(tempfile), '/');
  if not Assigned(p) then
    p := PChar(tempfile)
  else
    Inc(p);
  q := StrRScan(p, '\');
  if Assigned(q) then
    p := q + 1;
  q := StrRScan(p, ':');
  if Assigned(q) then
    p := q + 1;
  p^ := '$';
  df := FileCreate(tempfile);
  if df <= 0 then
    error_exit('Can''t create temporary file');
  tempfd := df;

  { apply patch }
  while True do
  begin
    c := fgetc(stdin);
    if c = EOF then
      Break;
    case c of
      Integer('@'):
      begin
        { copy from source }
        if fread(@header, 1, 12, stdin) <> 12 then
          error_exit('Patch garbled - unexpected end of data');
        size := getlong(@header[4]);
        ofs := getlong(@header[0]);
        if (ofs < 0) or (size <= 0) or (ofs > srclen) or (size > srclen)
          or (size+ofs > srclen) then
          error_exit('Patch garbled - invalid change request');
        if fseek(sf, ofs, SEEK_SET) <> 0 then
          error_exit('''fseek'' on source file failed');
        copy_data(sf, df, size, getlong(@header[8]), 0);
        Dec(destlen, size);
      end;
      Integer('+'):
      begin
        { copy N bytes from patch }
        if fread(@header, 1, 4, stdin) <> 4 then
          error_exit('Patch garbled - unexpected end of data');
        size := getlong(@header[0]);
        copy_data(stdin, df, size, 0, 1);
        Dec(destlen, size);
      end;
      else
      begin
        fclose(sf);
        fclose(df);
        StrRScan(error_msg, '%')^ := Char(c);
        error_exit(error_msg);
      end;
    end;
    if destlen < 0 then
      error_exit('Patch garbled - patch file longer than announced in header');
  end;
  if destlen <> 0 then
    error_exit(
      'Patch garbled - destination file shorter than announced in header'
    );

  fclose(sf);
  fclose(df);
  tempfd := 0;

  SysUtils.DeleteFile(dest);    // Added in v1.1: bug fix
  if not RenameFile(tempfile, dest) then
    error_exit('Can''t rename temporary file');
  tempfile := '';
end;

{ Help & exit }
procedure help;
begin
  fprintf(stdout, '%s: binary ''patch'' - apply binary patch'#13#10
    + #13#10
    + 'Usage: %s [options] old-file [new-file] [<patch-file]'#13#10#13#10
    + 'Creates new-file from old-file and patch-file'#13#10
    + 'If new-file is not provided old-file is updated in place'#13#10
    + #13#10
    + 'Valid options:'#13#10
    + ' -i FN --input=FN     Set input file name (instead of stdin)'
    + #13#10
    + ' -h    --help         Show this help screen'#13#10
    + ' -v    --version      Show version information'#13#10
    + #13#10
    + '(c) copyright 1999 Stefan Reuther <Streu@gmx.de>'#13#10
    + '(c) copyright 2003-2007 Peter Johnson (www.delphidabbler.com)'#13#10,
    [progname, progname]);
  Halt(0);
end;

{ Version & exit }
procedure version;
  function ExeDate: string;
  var
    H: Integer;
    DOSDate: Integer;
  begin
    H := FileOpen(ParamStr(0), fmOpenRead + fmShareDenyNone);
    try
      DOSDate := FileGetDate(H);
    finally
      FileClose(H);
    end;
    Result := FormatDateTime('dd mmm yyy', FileDateToDateTime(DOSDate));
  end;
begin
  // NOTE: original code displayed compile date using C's __DATE__ macro. Since
  // there is no Pascal equivalent of __DATE__ we display update date of program
  // file instead
  fprintf(stdout, 'bpatch-%s %s '#13#10, [VERSION_, ExeDate]);
  Halt(0);
end;

{ Control }
procedure Main;
var
  oldfn: string;
  newfn: string;
  infn: string;
  i: Integer;
  p: PChar;

  argv: PChar;
  fp: Integer;
begin
  oldfn := '';
  newfn := '';
  infn := '';

  progname := ExtractFileName(ParamStr(0));

  i := 1;
  while i <= ParamCount do
  begin
    argv := PChar(ParamStr(i) + #0#0#0);
    if argv[0] = '-' then
    begin
      if argv[1] = '-' then
      begin
        { long option }
        p := argv + 2;
        if StrComp(p, 'help') = 0 then
          help
        else if StrComp(p, 'version') = 0 then
          version
        else if StrComp(p, 'input') = 0 then
        begin
          Inc(i);
          argv := PChar(ParamStr(i));
          if (argv^ = #0) then
          begin
            fprintf(
              stderr, '%s: missing argument to ''--input'''#13#10, [progname]
            );
            Halt(1);
          end
          else
            infn := argv;
        end
        else if StrLComp(p, 'input=', 6) = 0 then
          infn := p + 6
        else
        begin
          fprintf(
            stderr,
            '%s: unknown option ''--%s'''#13#10
              + '%s: try ''%s --help'' for more information'#13#10,
            [progname, p, progname, progname]);
          Halt(1);
        end;
      end
      else
      begin
        { short option }
        p := argv + 1;
        while p^ <> #0 do
        begin
          case p^ of
            'h':
              if StrComp(p, 'h') = 0 then help; // changed v1.1
            'v':
              if StrComp(p, 'v') = 0 then version;  // changed v1.1
            'i':
            begin
              Inc(i);
              argv := PChar(ParamStr(i));
              if argv^ = #0 then
              begin
                fprintf(
                  stderr, '%s: missing argument to ''-i'''#13#10, [progname]
                );
                Halt(1);
              end
              else
                infn := argv;
            end
            else
            begin
              fprintf(
                stderr,
                '%s: unknown option ''-%s'''#13#10
                  + '%s: try ''%s --help'' for more information'#13#10,
                [progname, p^, progname, progname]
              );
              Halt(1);
            end;
          end;
          Inc(p);
        end;
      end;
    end
    else
    begin
      if oldfn = '' then
        oldfn := ParamStr(i)
      else if newfn = '' then
        newfn := ParamStr(i)
      else
        error_exit('Too many file names on command line');
    end;
    Inc(i);
  end;

  if oldfn = '' then
  begin
    fprintf(
      stderr,
      '%s: File name argument missing'#13#10
        + '%s: try ''%s --help'' for more information'#13#10,
      [progname, progname, progname]);
    Halt(1);
  end;

  if newfn = '' then
    newfn := oldfn;

  if (infn <> '') and (infn <> '-') then
  begin
    fp := FileOpen(infn, fmOpenRead or fmShareDenyNone);
    if fp <= 0 then
    begin
      perror(infn);
      Halt(1);
    end;
    RedirectStdIn(fp);
  end;

  bpatch_(PChar(oldfn), PChar(newfn));

end;

end.
