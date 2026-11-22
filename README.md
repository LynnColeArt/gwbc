# GW-BASIC native compiler experiment

`gwbc` compiles a subset of line-numbered GW-BASIC into standalone Linux x86-64
executables. The Zig front end parses source, resolves BASIC line targets and
loop pairs, and generates Zig control flow and runtime calls. Zig 0.16.0 builds
the executable.

## Compile and run the weekly-hours tally

[hours.bas](hours.bas) asks for the number of days, reads the hours for each day,
and prints their sum. From the Ziggify repository root:

```sh
python3 examples/gwbasic/run_case.py build
DEMO_DIR=$(mktemp -d)
examples/gwbasic/zig-out/bin/gwbc examples/gwbasic/hours.bas -o "$DEMO_DIR/hours"
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

Use `gwbc --emit-zig examples/gwbasic/hours.bas` to inspect the generated code.
The executable also accepts piped input. It echoes piped answers to preserve
the BASIC transcript and leaves terminal echo to the host on interactive runs.

[reorder.bas](reorder.bas) calculates how many full cases to order to restock an
item. It uses integer division and `MOD` to round up when the shortage leaves a
partial case. With 14 units on hand, a target of 50, and 10 units per case, it
prints `CASES TO ORDER: 4`.

```sh
examples/gwbasic/zig-out/bin/gwbc examples/gwbasic/reorder.bas -o "$DEMO_DIR/reorder"
printf '14\n50\n10\n' | "$DEMO_DIR/reorder"
```

## Supported source

Use printable ASCII with one statement per numbered line and a final
`SYSTEM`. The compiler supports `REM` and apostrophe comments, signed 16-bit
integers in one-letter variables such as `I%`, `LET`, `GOTO`, and
`IF … THEN line [ELSE line]`. It supports
lexically nested `FOR … TO … [STEP …]` / `NEXT` loops with distinct variables,
and optional variable names on `NEXT`.

Assignments, `IF`, `PRINT`, and loop bounds and steps accept integer
expressions. They support parentheses, unary signs, multiplication,
integer division (`\`), `MOD`, addition and subtraction, and numeric
comparisons. Comparisons produce `-1` when true and `0` when false. Intermediate
arithmetic results must fit in a signed 16-bit integer. Single-precision
promotion on overflow remains outside this slice.

`PRINT` supports newline-terminated strings and integers separated by semicolons
and preserves GW-BASIC's numeric spacing. `INPUT` reads one signed decimal
integer from a line, supports an optional quoted prompt with the comma or
semicolon separator, treats a blank answer as zero, and repeats the prompt
after nonnumeric text. Native console I/O uses standard streams and LF.
Sequential file output uses
`OPEN "OUT.TXT" FOR OUTPUT AS #1`, `PRINT #1,`, and `CLOSE #1` with DOS
CRLF, end-of-file markers, and record bytes.

String and floating-point input, comma-separated output zones, trailing
semicolons on `PRINT`, tokenized and protected program files, MBF arithmetic,
arrays, subroutines, graphics, sound, and general runtime diagnostic parity
remain outside the verified subset.

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

With DOSBox, GNU binutils, Python 3, and Zig 0.16.0 installed, run from the
repository root:

```sh
zig build -Doptimize=ReleaseSafe
mkdir -p examples/gwbasic/.ziggify/oracle
curl -fsSL https://codeberg.org/tkchia/GW-BASIC/releases/download/20261005/GWB26A05.ZIP \
  -o examples/gwbasic/.ziggify/oracle/GWB26A05.ZIP
unzip -p examples/gwbasic/.ziggify/oracle/GWB26A05.ZIP DEVEL/GWBASIC/GWBASIC.EXE \
  > examples/gwbasic/.ziggify/oracle/GWBASIC.EXE
./zig-out/bin/ziggify gate examples/gwbasic
```

`DOSBOX` and `GWBASIC_EXE` can point to absolute paths for local installations.
The corpus has four transcripts from `hours.bas`, five from `reorder.bas`,
two focused console cases for loop and expression semantics, and six file cases
covering strings, integers, branches, line order, and record boundaries.
