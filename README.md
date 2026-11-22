# GW-BASIC native compiler experiment

`gwbc` compiles a subset of line-numbered GW-BASIC into native Linux x86-64
executables. The Zig front end parses the source, resolves BASIC line targets,
and generates Zig control flow and runtime calls. Zig 0.16.0 builds the native
executable. The executable runs on its own.

From the Ziggify repository root, build the compiler and try a small program:

```sh
python3 examples/gwbasic/run_case.py build
GWBC="$PWD/examples/gwbasic/zig-out/bin/gwbc"
DEMO_DIR=$(mktemp -d)
cd "$DEMO_DIR"
cat > COUNT.BAS <<'BASIC'
10 OPEN "OUT.TXT" FOR OUTPUT AS #1
20 LET I% = -2
30 PRINT #1,I%
40 LET I% = I% + 1
50 IF I% < 3 THEN 30
60 CLOSE #1
70 SYSTEM
BASIC
"$GWBC" COUNT.BAS -o count
./count
xxd OUT.TXT
```

Use `gwbc --emit-zig COUNT.BAS` to inspect the generated source. The first
slice accepts printable ASCII, one statement per numbered line, unique line
numbers, `REM` and apostrophe comments, one-letter signed integer variables
such as `I%`, assignment with optional checked addition, `GOTO`, and
`IF … < … THEN` with a line number. The program ends with a numbered
`SYSTEM`. File output uses `OPEN "OUT.TXT" FOR OUTPUT AS #1`, `PRINT #1,`
with a single string or integer value, and `CLOSE #1`. The runtime emits
GW-BASIC's numeric spacing, CRLF, DOS end-of-file marker, and sequential
file record bytes.

Console I/O, tokenized and protected BASIC files, floating-point arithmetic
and MBF, arrays, subroutines, graphics, sound, and compatibility for runtime
error messages remain outside this slice.

## Replay against the DOS reference

The reference is T.K. Chia's [2026-10-05 build](https://codeberg.org/tkchia/GW-BASIC/releases/tag/20261005)
of the [1983 Microsoft assembly release](https://github.com/microsoft/GW-BASIC).
The runner checks the executable's SHA-256 each time and launches it in
[DOSBox 0.74-3](https://www.dosbox.com/DOSBoxManual.html). It stages the BASIC
source with DOS line endings and returns the complete output file to Ziggify.
The same fixtures go through the native compiler and each resulting executable.

With DOSBox, Python 3, and Zig 0.16.0 installed, run from the repository root:

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
The six fixtures cover string and integer output, a backward conditional branch,
a forward jump, numbered execution order, and empty, exact-boundary, and
multi-record files. Ziggify compares process status, stdout, stderr, and every
byte of `OUT.TXT`.
