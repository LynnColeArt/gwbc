# Provenance

`gwbc` originated in [Ziggify](https://github.com/LynnColeArt/ziggify) under
`examples/gwbasic`. This repository carries that directory's three development
commits through Ziggify revision `58ed6a7` and the original MIT license.

The Zig compiler is an independent implementation. The pinned DOS executable
is a separate test dependency. The replay runner checks its SHA-256 before use.

## References


- Microsoft’s 1983 GW-BASIC interpreter source archive and release notes
  establish the origin of the assembly reference:
  https://github.com/microsoft/GW-BASIC
- T.K. Chia’s JWasm build of the historical source, release `20261005`, tag
  revision `1432e385776554e43784b411eda7b8b2a9709e73`. The DOS executable SHA-256
  is pinned in the runner. The executable is used unchanged for observation
  and downloaded separately from the Zig compiler:
  https://codeberg.org/tkchia/GW-BASIC/releases/tag/20261005
- DOSBox 0.74-3 supplies the DOS runtime for the assembly reference. Its
  documented mount and unattended command options are used by the runner:
  https://www.dosbox.com/DOSBoxManual.html

- The pinned T.K. Chia revision's `OEM.ASM` and `GWMAIN.ASM` identify the BIOS
  keyboard and text output calls and integer loop setup. The DOS guest launcher
  uses those BIOS interfaces to supply scripted keyboard input and observe
  text writes. The source and executable remain unchanged:
  https://codeberg.org/tkchia/GW-BASIC/src/commit/1432e385776554e43784b411eda7b8b2a9709e73
- Microsoft's GW-BASIC documentation supplied the `INPUT` prompt and separator
  rules. Console transcripts and loop results were recorded from the pinned
  DOS executable:
  https://www.bitsavers.org/pdf/mindset/100213-001_GW-BASIC_Reference_Manual_1984.pdf
- Microsoft's GW-BASIC Interpreter User's Guide informed integer division,
  modulus, and arithmetic precedence. The pinned executable supplied observed
  results for signed remainders, adjacent unary signs, relational aliases,
  and comparisons used as integers:
  https://www.bitsavers.org/pdf/microsoft/gw-basic/410130001-320-R01-0686_Microsoft_GW-BASIC_Interpreter_Users_Guide_1986.pdf
- The Microsoft GW-BASIC reference describes `GOSUB`, plain `RETURN`, and
  `RETURN line`. Loop unwinding was checked against the pinned DOS binary:
  https://www.bitsavers.org/pdf/mindset/100213-001_GW-BASIC_Reference_Manual_1984.pdf
- Frank Cox's archived `ISBN.BAS` was tested unchanged with both the native
  compiler and DOS oracle,
  including a `SYSTEM` command supplied at the interpreter prompt after the
  listing completed. Its SHA-256 is
  `4b75f35594c8f9f8082d60b2b185befd14372759ff0a07479a3782fb85836db2`.
  The listing is an external compatibility target:
  https://github.com/robhagemans/hoard-of-gwbasic/blob/d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd/AllBasicCode/ISBN.BAS
- The Microsoft GW-BASIC Interpreter User's Reference documents string
  `INPUT`, including quoted strings with commas or surrounding spaces:
  https://www.bitsavers.org/pdf/microsoft/gw-basic/410130013-320-R01-0686_Microsoft_GW-BASIC_Interpreter_Users_Reference_1986.pdf
- `fahrenheit.bas` transcribes Figure 2 from Alan Neibauer's “Getting Started
  With … BASIC,” REMark, May 1988, page 13. The three-line excerpt is preserved
  as a compatibility fixture and attributed to the original publication.
  https://www.pestingers.net/pdfs/remark-scans/1988/remark-volume9-issue5-1988.pdf#page=13
- Microsoft's `MATH1.ASM` and `MATH2.ASM` were consulted for the
  single-precision display scaling and exponent rules. The numeric module
  implements these rules in Zig and the DOS replay supplies the expected output.
  https://github.com/microsoft/GW-BASIC/blob/master/MATH1.ASM
  https://github.com/microsoft/GW-BASIC/blob/master/MATH2.ASM
- Microsoft's `IBMRES.ASM` supplies the keyword and operator assignments.
  `GWMAIN.ASM` and `GWLIST.ASM` describe the packed lines and numeric
  constants. Files captured with `SAVE` under the pinned DOS binary established
  the line links, hidden separators, and record padding used by the decoder.
  https://github.com/microsoft/GW-BASIC/blob/master/IBMRES.ASM
  https://github.com/microsoft/GW-BASIC/blob/master/GWMAIN.ASM
  https://github.com/microsoft/GW-BASIC/blob/master/GWLIST.ASM
- `fixtures/tokenized/city-source.bas` transcribes the city table example
  from the 1986 Microsoft GW-BASIC Interpreter User's Reference, printed page
  39. `CITYTOK.BAS` is the unmodified binary produced by DOS `SAVE` from
  that listing. The reference also documents `DATA`, `READ`, `RESTORE`,
  `DIM`, and console print zones. DOS runs supplied the tested output.
  https://www.bitsavers.org/pdf/microsoft/gw-basic/410130013-320-R01-0686_Microsoft_GW-BASIC_Interpreter_Users_Reference_1986.pdf

- `fixtures/historical/customer.bas` transcribes the eight numbered lines
  of the `LINE INPUT#` example in Microsoft's 1989 GW-BASIC User's Guide and
  Reference, printed page 184. The DOS session supplies the expected
  transcript and full `INFO` file. Chapter 5 describes sequential files
  and append mode.
  https://bitsavers.trailing-edge.com/pdf/microsoft/gw-basic/Microsoft_GW-BASIC_Users_Guide_and_Reference_1989.pdf#page=190
- `FLOWTOK.BAS` is a DOS `SAVE` of the project's
  `fixtures/tokenized/flow-source.bas`. It exercises colon-separated
  statements, inline `IF`, `WHILE` / `WEND`, and a subroutine return. The
  saved byte sequence identifies the synthetic plus token after `WHILE`.
- The [archive survey](COMPATIBILITY.md) uses the unchanged `.BAS` files
  in `AllBasicCode` at the same pinned hoard-of-gwbasic revision as the ISBN
  test. The broader archive remains an external dependency.
