# gwbc

`gwbc` compiles a subset of line-numbered GW-BASIC into standalone Linux x86-64
executables. The Zig front end parses source, resolves BASIC line targets and
loop pairs, and generates Zig control flow and runtime calls. Zig 0.16.0 builds
the executable. The project started as a [Ziggify](https://github.com/LynnColeArt/ziggify)
compiler experiment. See [PROVENANCE.md](PROVENANCE.md) for the source history
and DOS reference.

## Compile and run the weekly-hours tally

[hours.bas](hours.bas) asks for the number of days, reads the hours for each day,
and prints their sum. From this repository root:

```sh
zig build -Doptimize=ReleaseSafe
DEMO_DIR=$(mktemp -d)
zig-out/bin/gwbc hours.bas -o "$DEMO_DIR/hours"
"$DEMO_DIR/hours"
```

A session with three days looks like this:

```text
WEEKLY HOURS TOTAL
NUMBER OF DAYS? 3
HOURS: 8
HOURS: 7
HOURS: 6
TOTAL HOURS: 21
```

Use `zig-out/bin/gwbc --emit-zig hours.bas` to inspect the generated code.
The executable also accepts piped input. It echoes piped answers to preserve
the BASIC transcript and leaves terminal echo to the host on interactive runs.

[reorder.bas](reorder.bas) calculates how many full cases to order to restock an
item. It uses integer division and `MOD` to round up when the shortage leaves a
partial case. With 14 units on hand, a target of 50, and 10 units per case, it
prints `CASES TO ORDER: 4`.

```sh
zig-out/bin/gwbc reorder.bas -o "$DEMO_DIR/reorder"
printf '14\n50\n10\n' | "$DEMO_DIR/reorder"
```

[gcd.bas](gcd.bas) uses nested subroutines to calculate the greatest common
divisor of two nonnegative integers. For inputs 270 and 192 it prints 6.

```sh
zig-out/bin/gwbc gcd.bas -o "$DEMO_DIR/gcd"
printf '270\n192\n' | "$DEMO_DIR/gcd"
```

## Supported source

Use ASCII text or an unprotected GW-BASIC tokenized file. Numbered lines
can contain colon-separated statements. ASCII DOS end-of-file markers are
recognized. Native programs
finish at end of source, `END`, or `SYSTEM`. The compiler supports `REM` and
apostrophe comments, assignment with or without `LET`, and `GOTO`.
`IF … THEN … [ELSE …]` accepts statement sequences or line targets, and
nested branches bind `ELSE` to the nearest unmatched `IF`. `GOSUB line`
supports nested calls with shared variables. `RETURN` resumes after the
calling statement, even on the same BASIC line. `RETURN line` discards the
call before jumping to the given line. Returning discards loops entered
inside the subroutine and preserves the caller's active loops. The compiler
supports lexically nested `FOR … TO … [STEP …]` / `NEXT` loops with distinct
variables, optional variable names on `NEXT`, and `WHILE` / `WEND` loops.

Assignments, `IF`, `PRINT`, and loop bounds and steps accept numeric
expressions. They support parentheses, unary signs, multiplication, division
(`/`), integer division (`\`), `MOD`, addition and subtraction, comparisons,
and bitwise `NOT`, `AND`, and `OR`. Comparisons produce `-1` when true and `0` when
false. Unsuffixed and `!` variables use single precision, and `%` variables
use signed 16-bit integers. Integer addition, subtraction, and multiplication
promote to single precision when the result exceeds the integer range.

Single-precision arithmetic uses Zig `f32` with range checks and GW-BASIC-style
seven-digit display. The replay cases cover ordinary decimal calculations and
formatting. Bit-for-bit Microsoft Binary Format arithmetic, underflow edges,
double precision, and all numeric error transcripts remain outside this slice.

`PRINT` preserves GW-BASIC's numeric spacing and accepts semicolon separators
and console commas between values. A console comma advances to the next of
five 14-column print zones, wrapping after the last. `INPUT` accepts a list
of numeric or string variables, including quoted fields with commas or
surrounding spaces. It retries a malformed response before assigning any
fields. `LINE INPUT` keeps the whole response, including quotes, commas,
and spaces. Native console I/O uses standard streams and LF. The runtime
also supports string concatenation and comparison, `LEN`,
`MID$(text, start, count)`, `RIGHT$`, and decimal prefixes in `VAL`.

Sequential files support `OPEN filename FOR INPUT|OUTPUT|APPEND AS #n`
and the corresponding `OPEN "I"|"O"|"A",#n,filename` forms. Statements take
literal channel numbers. Use `INPUT #` for fields, `LINE INPUT #` for a line,
`EOF(n)` to check for end of file, `PRINT #` to write, and `CLOSE` to finish.
Output uses DOS CRLF, Ctrl-Z, and 128-byte records. Append resumes at the
existing end-of-file marker. Bare filenames are uppercased as on DOS.
Explicit host paths retain their casing.

`DATA` holds decimal numbers and quoted or unquoted text. `READ` reads fields
in BASIC line order into scalars or array elements. `RESTORE` rewinds the
cursor. `RESTORE line` resumes at the first `DATA` on or after that existing
line. `DIM` declares one-dimensional numeric and string arrays with inclusive
zero-based bounds. Undimensioned arrays have bounds 0 through 10. Scalars and
arrays can share a name.

File print zones, trailing print separators, protected program files,
precise MBF arithmetic, multidimensional arrays, `OPTION BASE`, graphics,
sound, DOS devices, and general runtime diagnostic parity remain outside the
verified subset. See the [archive compatibility report](COMPATIBILITY.md)
for unchanged builds and DOS checks on historical programs.

## Run Frank Cox's archived ISBN checker

Frank Cox's [ISBN checksum utility](https://github.com/robhagemans/hoard-of-gwbasic/blob/d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd/AllBasicCode/ISBN.BAS)
compiles unchanged. Fetch the pinned listing and compile it from the
repository root:

```sh
zig build -Doptimize=ReleaseSafe
mkdir -p .ziggify/oracle
curl -fsSL \
  https://raw.githubusercontent.com/robhagemans/hoard-of-gwbasic/d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd/AllBasicCode/ISBN.BAS \
  -o .ziggify/oracle/ISBN.BAS
DEMO_DIR=$(mktemp -d)
zig-out/bin/gwbc .ziggify/oracle/ISBN.BAS -o "$DEMO_DIR/isbn"
printf '0-306-40615-2\n' | "$DEMO_DIR/isbn"
```

The archive prints `OK` for this input. Ziggify also checks a wrong check
digit and both uppercase and lowercase `X` check digits.

## Run the 1988 Fahrenheit converter

[fahrenheit.bas](fahrenheit.bas) is the three-line listing from Figure 2 of
Alan Neibauer's “Getting Started With … BASIC,” published in the May 1988
issue of REMark. It compiles as printed, including the fractional calculation
and the two unsuffixed variables.
[Scanned listing, page 13](https://www.pestingers.net/pdfs/remark-scans/1988/remark-volume9-issue5-1988.pdf#page=13)

```sh
zig build -Doptimize=ReleaseSafe
DEMO_DIR=$(mktemp -d)
zig-out/bin/gwbc fahrenheit.bas -o "$DEMO_DIR/fahrenheit"
printf '98.6\n' | "$DEMO_DIR/fahrenheit"
```

## Compile a tokenized save

GW-BASIC's ordinary `SAVE` writes tokenized source. `gwbc` detects that format
from the file header and compiles it through the same parser as ASCII source.
It checks the saved line links and decodes the compiler's existing keyword
subset, embedded line targets, integers, and representable MBF single literals.
Protected files and embedded double-precision constants produce explicit errors.

```sh
zig build -Doptimize=ReleaseSafe
DEMO_DIR=$(mktemp -d)
zig-out/bin/gwbc fixtures/tokenized/FAHTOK.BAS -o "$DEMO_DIR/fahrenheit"
printf '37.5\n' | "$DEMO_DIR/fahrenheit"
```

The binary files under [fixtures/tokenized](fixtures/tokenized) are unchanged DOS
saves. To create an equivalent save, load its ASCII listing in the pinned DOS
interpreter and run `SAVE "FAHTOK.BAS"` or the corresponding fixture name. The source
listings are `fahrenheit.bas`, `gcd.bas`,
`fixtures/tokenized/numbers-source.bas`, `fixtures/tokenized/city-source.bas`,
`fixtures/tokenized/flow-source.bas`, and `months.bas`. Ziggify verifies each binary's
SHA-256 and passes the same file bytes to both implementations.

## Run a table lookup from a DOS save

[CITYTOK.BAS](fixtures/tokenized/CITYTOK.BAS) is a DOS save of the city table
example in the 1986 Microsoft GW-BASIC Interpreter User's Reference. It reads
a quoted comma, a state name, and a numeric ZIP code from `DATA`. The companion
[MONTOK.BAS](fixtures/tokenized/MONTOK.BAS) uses numeric and string arrays to
look up month lengths for a common year. Its transcript exercises both forms
of `RESTORE`. [Microsoft reference, printed page 39](https://www.bitsavers.org/pdf/microsoft/gw-basic/410130013-320-R01-0686_Microsoft_GW-BASIC_Interpreter_Users_Reference_1986.pdf)

```sh
zig build -Doptimize=ReleaseSafe
DEMO_DIR=$(mktemp -d)
zig-out/bin/gwbc fixtures/tokenized/MONTOK.BAS -o "$DEMO_DIR/months"
printf '12\n' | "$DEMO_DIR/months"
```

## Recover a sequential file from an archived listing

The [customer-record example](fixtures/historical/customer.bas) is the
eight-line `LINE INPUT#` listing from Microsoft's 1989 manual. It accepts
a line containing commas and spaces, writes it to `INFO`, closes the file,
reopens it, and prints the record it reads back.

```sh
zig build -Doptimize=ReleaseSafe
DEMO_DIR=$(mktemp -d)
zig-out/bin/gwbc fixtures/historical/customer.bas -o "$DEMO_DIR/customer"
(cd "$DEMO_DIR" && printf 'LINDA JONES  234,4  MEMPHIS\n' | ./customer)
```

Ziggify compares the transcript and the complete `INFO` file, including
record padding. Separate cases check appending to an existing file and
appending across a record boundary.

## Replay against the DOS reference

The reference is T.K. Chia's [2026-10-05 build](https://codeberg.org/tkchia/GW-BASIC/releases/tag/20261005)
of the [1983 Microsoft assembly release](https://github.com/microsoft/GW-BASIC).
The runner verifies the executable's SHA-256, stages the same BASIC source with
DOS line endings, and launches the executable in
[DOSBox 0.74-3](https://www.dosbox.com/DOSBoxManual.html).

For console fixtures, a small DOS launcher supplies scripted BIOS keystrokes and
captures ordered text cell writes. The runner converts row changes to LF,
retains printable bytes including spaces, and appends LF after the last visible
row. This capture covers short screens of sequential ASCII text, including the
interpreter's input echo. Terminal control effects and blank lines after the
last visible row are outside the capture. File fixtures compare every byte of each watched file. Ziggify also compares exit status and both output streams.

Install [Ziggify](https://github.com/LynnColeArt/ziggify/releases/tag/v0.2.0-alpha.1),
DOSBox, GNU binutils, Python 3, and Zig 0.16.0. Download the archived
`ISBN.BAS` as shown above. With `ziggify` on PATH, run from the repository
root:

```sh
mkdir -p .ziggify/oracle
curl -fsSL https://codeberg.org/tkchia/GW-BASIC/releases/download/20261005/GWB26A05.ZIP \
  -o .ziggify/oracle/GWB26A05.ZIP
unzip -p .ziggify/oracle/GWB26A05.ZIP DEVEL/GWBASIC/GWBASIC.EXE \
  > .ziggify/oracle/GWBASIC.EXE
ziggify gate .
```

`DOSBOX` and `GWBASIC_EXE` can point to absolute paths for local installations.
The [replay report](ziggify/replay-report.json) covers 46 cases, including
the archived ISBN checker, the 1988 Fahrenheit converter, the tokenized city
table from Microsoft's manual, and its customer-record example. The runner
verifies the archive fixtures' SHA-256, adapts line endings for DOS, and
supplies `SYSTEM` after each archived program finishes. The interpreter
prompt and command echo are outside the program transcript.
