# GW-BASIC archive compatibility

`gwbc` builds standalone Linux x86-64 executables for a subset of GW-BASIC.
The archive survey built **2 of 37** unchanged listings from the top level
of [AllBasicCode](https://github.com/robhagemans/hoard-of-gwbasic/tree/d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd/AllBasicCode).
The previous revision built 1 of the same 37. The directory includes games
and DOS-specific programs. Compiler diagnostics show the first stopping point
for each listing. The [roadmap](ROADMAP.md) uses these results to choose
which programs to recover next. [Previous revision](https://github.com/LynnColeArt/gwbc/commit/94a42495eacf605d70bf50403ece1bb1027671a5)

## DOS-verified historical listings

| Listing | Comparison |
| --- | --- |
| Frank Cox's ISBN checker | Four input transcripts |
| Alan Neibauer's 1988 Fahrenheit converter | Decimal input and numeric display |
| Microsoft's city table | DOS tokenized save, quoted data, and print columns |
| Microsoft's customer-record example | Console transcript and complete `INFO` file bytes |

These checks and focused compiler cases are in the
[Ziggify replay report](ziggify/replay-report.json). The archive's
`TICTAC.BAS` also built unchanged. It expects interactive play until a
keyboard break, so the survey records the native build only.

## Archive build results

`SCREEN`, `CLS`, `KEY`, `RANDOMIZE`, multidimensional arrays, and
statements such as `NEXT X,Y` account for several early failures. The result for each
listing comes from the normal executable build command.

| Listing | Native build result |
| --- | --- |
| `3DTTT.BAS` | source row 26: UnsupportedStatement |
| `ADV-OLD.BAS` | source row 12: UnsupportedStatement |
| `ADVENTUR.BAS` | source row 2: UnsupportedStatement |
| `BATTLE.BAS` | source row 3: UnsupportedStatement |
| `CHAOS.BAS` | source row 2: UnsupportedStatement |
| `CHESS.BAS` | source row 3: UnsupportedStatement |
| `Connect4.bas` | source row 31: TrailingInput |
| `DRAG.BAS` | source row 1: UnsupportedStatement |
| `EV11.BAS` | source row 60: UnsupportedStatement |
| `Encode.bas` | source row 38: UnsupportedStatement |
| `FIAR.BAS` | source row 5: InvalidSyntax |
| `GUESS.BAS` | source row 1: UnsupportedStatement |
| `GWscan.BAS` | tokenized BASIC line 1020, near file offset 75: UnsupportedProgramToken |
| `INVADER.BAS` | source row 1: InvalidSyntax |
| `ISBN.BAS` | Built |
| `KERMIT.BAS` | source row 10: UnsupportedStatement |
| `LoanWhiz.BAS` | tokenized BASIC line 1020, near file offset 128: UnsupportedProgramToken |
| `MAZEGEN.BAS` | source row 1: UnsupportedStatement |
| `MIDWAY.BAS` | source row 1: InvalidSyntax |
| `MISSILE.BAS` | source row 10: UnsupportedStatement |
| `NORMAL-Z.BAS` | source row 22: UnsupportedStatement |
| `ORGAN.BAS` | source row 3: UnsupportedStatement |
| `PERSONA.BAS` | source row 2: UnsupportedStatement |
| `POINTA.BAS` | source row 3: UnsupportedStatement |
| `RUNES.BAS` | source row 1: UnsupportedStatement |
| `ST.BAS` | source row 7: InvalidSyntax |
| `SUNRISE.BAS` | source row 33: UnsupportedDouble |
| `SWATFLYS.BAS` | source row 5: UnsupportedStatement |
| `TICTAC.BAS` | Built |
| `TIMEZONE.BAS` | source row 2: UnsupportedStatement |
| `TYPER.BAS` | source row 1: UnsupportedStatement |
| `UFO.BAS` | source row 3: UnsupportedStatement |
| `XWING.BAS` | source row 1: UnsupportedStatement |
| `align.bas` | source row 24: TypeMismatch |
| `chaos.bas` | source row 11: TypeMismatch |
| `chaos02.bas` | source row 18: TypeMismatch |
| `gargoyle.bas` | source row 20: UnsupportedStatement |

## Reproduce the archive survey

```sh
zig build -Doptimize=ReleaseSafe
ARCHIVE_DIR=$(mktemp -d)
git clone https://github.com/robhagemans/hoard-of-gwbasic.git "$ARCHIVE_DIR"
git -C "$ARCHIVE_DIR" checkout --detach d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd
python3 archive_check.py "$ARCHIVE_DIR"
```

For the DOS runs, follow the [replay setup](README.md#replay-against-the-dos-reference).
