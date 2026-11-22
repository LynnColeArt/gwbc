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

Use printable ASCII with one statement per numbered line. Native programs
finish at end of source, `END`, or `SYSTEM`. The compiler supports `REM` and
apostrophe comments, assignment with or without `LET`, and `GOTO`.
`IF … THEN … [ELSE …]` accepts a line number, assignment, or `PRINT` in
each branch. `GOSUB line` supports nested calls with shared
variables. `RETURN` resumes the most recent caller and `RETURN line` discards
that call before jumping to the given line. Returning discards loops entered
inside the subroutine and preserves the caller's active loops. The compiler
supports lexically nested `FOR … TO … [STEP …]` / `NEXT` loops with distinct
variables and optional variable names on `NEXT`.

Assignments, `IF`, `PRINT`, and loop bounds and steps accept integer
expressions. They support parentheses, unary signs, multiplication,
integer division (`\`), `MOD`, addition and subtraction, and numeric
comparisons, and bitwise `AND` and `OR`. Comparisons produce `-1` when true
and `0` when false. Both explicit `%` variables and unsuffixed numeric
variables in this compiler use signed 16-bit values. The DOS interpreter's
default single precision, including overflow promotion, remains outside this
slice.

`PRINT` supports newline-terminated strings and integers separated by
semicolons and preserves GW-BASIC's numeric spacing. `INPUT` reads one value
into a numeric variable or a `$` string variable. String input trims
unquoted outer spaces and accepts quoted fields containing commas and
outer spaces. Both forms support a quoted prompt with the comma or
semicolon separator. The runtime also supports string concatenation and
comparison, `LEN`, `MID$(text, start, count)`, `RIGHT$`, and integer
decimal prefixes in `VAL`. Native console I/O uses standard streams and LF.
Sequential file output uses
`OPEN "OUT.TXT" FOR OUTPUT AS #1`, `PRINT #1,`, and `CLOSE #1` with DOS
CRLF, end-of-file markers, and record bytes.

Floating-point input, multiple input fields, comma-separated output zones, trailing
semicolons on `PRINT`, tokenized and protected program files, MBF arithmetic,
arrays, graphics, sound, and general runtime diagnostic parity
remain outside the verified subset.

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
last visible row are outside the capture. File fixtures compare complete
`OUT.TXT` bytes. Ziggify also compares exit status and both output streams.

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
The corpus has four transcripts from `hours.bas`, five from `reorder.bas`,
two from `gcd.bas`, four from the archived `ISBN.BAS`, four focused console
cases for loops, expressions, subroutine returns and string input, and six file
cases. The runner verifies the archived listing's SHA-256 and gives both
implementations the same bytes. In DOS it supplies `SYSTEM` after the listing
finishes and excludes the interpreter prompt and command echo from the
comparison.
