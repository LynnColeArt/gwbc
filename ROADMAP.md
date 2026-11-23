# GW-BASIC recovery roadmap

Start with a text-mode runtime and use `TIMEZONE.BAS` as its first acceptance
test. The baseline builds **2 of 37** unchanged listings from the pinned
`AllBasicCode` archive. The DOS replay suite passes **46 of 46** selected
cases. [Archive survey](COMPATIBILITY.md) · [DOS replay](ziggify/replay-report.json)

## What the archive says

| Finding | What it changes |
| --- | --- |
| 31 of 37 listings use at least one of `CLS`, `LOCATE`, `COLOR`, `WIDTH`, or `KEY ON/OFF`. | A shared text-screen model is the best place to start. |
| 17 of 37 reference `INKEY$`; 18 use `BEEP`, `SOUND`, or `PLAY` in statement position. | Keyboard and audio need separate acceptance tests. Games often need both. |
| `Connect4.bas` first stops at `NEXT X,Y`, then needs cursor control, color, nonblocking keys, random numbers, and audio. | Bundle multi-variable `NEXT` with a program that can reach a full build. |
| The two tokenized listings both first stop on a line with `SAVE` and `LIST`. `LoanWhiz.BAS` also uses random records and error handling. `GWscan.BAS` uses segmented memory and binary screen saves. | Treat token decoding as part of each feature and pick these applications after their runtime dependencies are in place. |

The source counts overlap. The scan covered 35 text listings and ASCII
listings of the two tokenized files, with comments and string literals
excluded. The candidate review used per-line parse diagnostics and manual
checks for constructs that can parse with the wrong meaning. The build and replay counts come from the published
baseline. [Pinned source archive](https://github.com/robhagemans/hoard-of-gwbasic/tree/d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd/AllBasicCode) · [PC-BASIC conversion documentation](https://robhagemans.github.io/pcbasic/doc/2.0/PC-BASIC_documentation.html)

One example is `PRINT TAB(5);STR$(12)`. The current compiler emits reads
from numeric and string arrays. Recognize reserved functions explicitly and
give `TAB` its output semantics before using a successful build as evidence
for programs that use them.

## Milestones in order

1. **Recover a text-mode utility.** Use `TIMEZONE.BAS` to add `CLS`, an
   80-column screen with `WIDTH`, and `PRINT TAB(n)`. Implement `STRING$`,
   `LEFT$`, and `STR$`. Keep a plain stream path for existing programs and
   give text-screen programs a model that tracks cursor position, wrapping,
   clearing, and scrolling. Add DOS screen snapshots at input prompts and
   result screens. The current transcript recorder only covers sequential
   writes within the first screen. Ship this milestone when the untouched
   listing builds, the archive count reaches at least **3 of 37**, and
   Ziggify matches a normal conversion and a half-hour path from the DOS
   original. [Target listing](https://github.com/robhagemans/hoard-of-gwbasic/blob/d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd/AllBasicCode/TIMEZONE.BAS) · [Microsoft screen routines](https://github.com/microsoft/GW-BASIC/blob/master/GWSTS.ASM)

2. **Extend the text subset to more complete listings.** Take `Encode.bas`
   next for `ASC`, `CHR$`, CP437 bytes in string literals and output, and
   `RUN` restart semantics. Use `ADV-OLD.BAS` for computed
   `ON … GOSUB`, trailing `PRINT` separators, `FIX`, and deterministic
   `RND` checks. Verify the encoder's byte output and a bounded session of
   the adventure. `TYPER.BAS` is a separate small target once `IF … GOTO`
   and a printer-byte sink for `LPRINT` are in scope.

3. **Add interactive text and common array forms.** Use `GUESS.BAS` for
   `LOCATE`, nonblocking `INKEY$`, `RANDOMIZE TIMER`, `INT`,
   and `MID$` assignment. Extend the screen model with `COLOR`, text-mode `SCREEN 0`,
   and `KEY ON/OFF` as the next targets require them. Add multi-variable
   `NEXT` and multidimensional arrays with separate DOS fixtures. Recheck
   `Connect4.bas` and `CHESS.BAS` after these changes and track their
   remaining requirements before promising either as a full-build target.

4. **Recover numerical utilities.** Use `SUNRISE.BAS` for double-precision
   literals, the math intrinsics it actually calls, and numeric
   `PRINT USING`. Bring its precision and display to DOS-verified results
   across several dates and locations. Use `DRAG.BAS` to check exponentiation
   and mixed-precision arithmetic once these pieces are in place.

5. **Choose the next device or file family from the results.** Use
   `LoanWhiz.BAS` to scope random-access records and `ON ERROR`/`RESUME`.
   Give sound, raster graphics, and DOS memory or device access separate
   compatibility targets. Before investing in a device backend, repeat the
   survey on a second pinned archive sample with more utilities. The current
   sample includes many games and related variants.

After each milestone, rerun the same 37-file survey, publish the number of
unchanged native builds and the next blockers, and add DOS replay cases for
the target listings. Keep the build count and behavior checks visible in the
[compatibility report](COMPATIBILITY.md).
