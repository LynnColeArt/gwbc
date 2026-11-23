"""Run one Ziggify fixture with the DOS oracle or the native compiler."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
COMPILER = ROOT / "zig-out" / "bin" / "gwbc"
ORACLE_HASH = "ceb0c57c1c31981844a2e41b375cd14f77630e3e200419fe746b501d21dcf333"
ISBN_HASH = "4b75f35594c8f9f8082d60b2b185befd14372759ff0a07479a3782fb85836db2"
FAHRENHEIT_HASH = "52d6ec00ad4db676e0155d77776707a355a86655bba71e9bed6345bc376cc3a1"
TOKENIZED_HASHES = {
    "FAHTOK.BAS": "8def4bef27868225cd930b10c607392f6c64451034d6b11590b803f386c1e464",
    "GCDTOK.BAS": "cb22333a5339fd75e172007afc8d64de53b5526f682d6fe1fc542dadd4498ab2",
    "NUMTOK.BAS": "3804af29827fd3158754454407f5b4e3d775984d66b5ec1ac637fc85f4af947e",
    "CITYTOK.BAS": "08a0de2bc0bf13c78d202eb37c7fd7dddd1e264eeb1761466cc0d0fad0a9bd6d",
    "MONTOK.BAS": "667a9689d9016f9cb0de61516b5ad1a4ae80db6d37c9602b5f6128e6ab087180",
}


def source_path(program):
    if program == "ISBN.BAS":
        source, expected = ROOT / ".ziggify/oracle/ISBN.BAS", ISBN_HASH
    elif program == "FAHREN.BAS":
        source, expected = ROOT / "fahrenheit.bas", FAHRENHEIT_HASH
    elif program in TOKENIZED_HASHES:
        source, expected = ROOT / "fixtures/tokenized" / program, TOKENIZED_HASHES[program]
    else:
        return Path(program)
    if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise ValueError(f"{program} does not match the pinned archived listing")
    return source


def stage_console(guest, prompt_exit):
    raw = sys.stdin.buffer.read(513)
    keys = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r")
    if prompt_exit:
        if keys and not keys.endswith(b"\r"):
            raise ValueError("DOS program input must end with a return before the prompt exit")
        keys += b"SYSTEM\r"
    if len(keys) > 256 or any(byte != 13 and not 32 <= byte <= 126 for byte in keys):
        raise ValueError("console fixture must use at most 256 printable ASCII keystrokes and returns")
    (guest / "KEYS.TXT").write_bytes(keys)
    subprocess.run(["as", "--32", ROOT / "console_oracle.s", "-o", "console.o"], cwd=guest, check=True)
    subprocess.run(
        ["ld", "-m", "elf_i386", "-Ttext", "0x100", "--oformat", "binary",
         "-e", "_start", "-o", "CONSOLE.COM", "console.o"],
        cwd=guest, check=True,
    )


def console_transcript(trace, prompt_exit):
    if not trace or len(trace) % 3:
        raise ValueError("DOS oracle produced an empty or incomplete console trace")
    transcript = bytearray()
    row, column = 0, 0
    for next_column, next_row, byte in zip(trace[::3], trace[1::3], trace[2::3]):
        if (next_row, next_column) < (row, column) or next_column >= 79 or next_row >= 24:
            raise ValueError("DOS oracle requires sequential text within the first screen")
        if next_row > row:
            transcript.extend(b"\n" * (next_row - row))
            row, column = next_row, 0
        transcript.extend(b" " * (next_column - column))
        transcript.append(byte)
        column = next_column + 1
    transcript.append(10)
    if prompt_exit:
        # These rows come from GW-BASIC's direct-mode prompt after the listing
        # ends. Require the exact suffix before excluding it from program output.
        suffix = b"\nOk\xff\nSYSTEM\n"
        if not transcript.endswith(suffix):
            raise ValueError("DOS oracle did not return to the expected interpreter prompt")
        del transcript[-len(suffix) + 1:]
    if any(byte != 10 and not 32 <= byte <= 126 for byte in transcript):
        raise ValueError("DOS oracle requires printable ASCII output")
    return bytes(transcript)


def original(program, mode="file"):
    executable = Path(os.environ.get("GWBASIC_EXE", ROOT / ".ziggify/oracle/GWBASIC.EXE"))
    payload = executable.read_bytes()
    if hashlib.sha256(payload).hexdigest() != ORACLE_HASH:
        raise ValueError("GW-BASIC executable does not match the pinned release")

    with tempfile.TemporaryDirectory(prefix="gwbasic-dos-") as directory:
        guest = Path(directory)
        (guest / "GWBASIC.EXE").write_bytes(payload)
        source = source_path(program).read_bytes()
        if program != "ISBN.BAS" and not source.startswith((b"\xff", b"\xfe")):
            source = b"\r\n".join(source.splitlines()) + b"\r\n"
        (guest / "INPUT.BAS").write_bytes(source)
        command = "gwbasic input.bas"
        console = mode in ("console", "console-end")
        prompt_exit = mode == "console-end"
        if console:
            stage_console(guest, prompt_exit)
            command = "console.com"
        config = guest / "dosbox.conf"
        config.write_text("[sdl]\noutput=surface\n[mixer]\nnosound=true\n[midi]\nmididevice=none\n")
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        result = subprocess.run(
            [os.environ.get("DOSBOX", "dosbox"), "-conf", str(config), "-noconsole",
             "-c", 'mount c "."', "-c", "c:", "-c", command, "-c", "exit"],
            cwd=guest, env=env, capture_output=True, timeout=12, check=True,
        )
        if console:
            trace = guest / "TRACE.BIN"
            if not trace.is_file():
                raise ValueError(f"DOS console launcher failed to capture the program\n{result.stdout.decode(errors='replace')}")
            sys.stdout.buffer.write(console_transcript(trace.read_bytes(), prompt_exit))
            return
        output = guest / "OUT.TXT"
        if not output.is_file():
            raise ValueError(f"DOS oracle produced no OUT.TXT\n{result.stdout.decode(errors='replace')}")
        payload = output.read_bytes()
        if b"\x1a" not in payload or len(payload) % 128:
            raise ValueError("DOS oracle did not finish writing OUT.TXT")
        Path("OUT.TXT").write_bytes(payload)


def build():
    subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseSafe"],
        check=True,
        cwd=ROOT,
    )


def native(program, _mode="file"):
    with tempfile.TemporaryDirectory(prefix="gwbasic-native-") as directory:
        executable = Path(directory, "program")
        subprocess.run([COMPILER, source_path(program), "-o", executable], check=True)
        subprocess.run([executable], check=True)


def check():
    config = json.loads((ROOT / "ziggify.json").read_text())
    samples = {name.upper(): (ROOT / name).read_text() for name in ("hours.bas", "reorder.bas", "gcd.bas")}
    for case in config["cases"]:
        for fixture in case.get("files", []):
            sample = samples.get(fixture["path"])
            if sample is not None and fixture["data"] != sample:
                raise ValueError(f"{case['name']} uses a different copy of {fixture['path']}")
    with tempfile.TemporaryDirectory(prefix="gwbasic-check-") as directory:
        program = Path(directory, "BAD.BAS")
        invalid_links = bytearray(source_path("FAHTOK.BAS").read_bytes())
        invalid_links[1] ^= 1
        for text, diagnostic in [
            ("10 GOTO 40\n20 SYSTEM\n", b"jumps to missing line 40"),
            ("10 SCREEN 1\n20 SYSTEM\n", b"UnsupportedStatement"),
            ("10 REM COMMENT\n10 SYSTEM\n", b"duplicate BASIC line 10"),
            ("10 NEXT I%\n20 SYSTEM\n", b"NEXT without FOR"),
            ("10 FOR I%=1 TO 2\n20 NEXT J%\n30 SYSTEM\n", b"does not match FOR"),
            ("10 FOR I%=1 TO 2\n20 SYSTEM\n", b"FOR without NEXT"),
            ("10 PRINT (2+3\n20 SYSTEM\n", b"InvalidSyntax"),
            ("10 IF 1 THEN 20 ELSE 30\n20 SYSTEM\n", b"jumps to missing line 30"),
            ("10 GOSUB 40\n20 SYSTEM\n", b"jumps to missing line 40"),
            ("10 RETURN 40\n20 SYSTEM\n", b"jumps to missing line 40"),
            ('10 LET X%=MID$("text",1,1)\n20 SYSTEM\n', b"TypeMismatch"),
            ('10 IF "text" THEN 20\n20 SYSTEM\n', b"TypeMismatch"),
            ("10 PRINT 12345678\n20 SYSTEM\n", b"UnsupportedDouble"),
            ("10 DIM A%\n20 SYSTEM\n", b"ExpectedArrayBound"),
            ("10 RESTORE 30\n20 SYSTEM\n", b"restores from missing line 30"),
            (bytes(invalid_links), b"InvalidTokenizedLink"),
            (b"\xff\x01", b"TruncatedTokenizedProgram"),
            (b"\xff\x01\x09\x0a\x00\x91\x1d\x00\x00", b"TruncatedTokenizedProgram"),
            (b"\xff\x01\x09\x0a\x00\xfe\x01", b"UnsupportedProgramToken"),
            (b"\xff\x01\x09\x0a\x00\x91\x1f" + bytes(8), b"UnsupportedTokenizedDouble"),
            (b"\xfe\x00", b"ProtectedBasicProgram"),
        ]:
            program.write_bytes(text.encode() if isinstance(text, str) else text)
            executable = program.with_suffix("")
            result = subprocess.run([COMPILER, program, "-o", executable], capture_output=True, check=False)
            if result.returncode != 1 or result.stdout or diagnostic not in result.stderr:
                raise ValueError(f"expected a compilation error for {text!r}: {result!r}")
            if executable.exists():
                raise ValueError("failed compilation produced an executable")


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    operations = {"original": original, "native": native, "build": build, "check": check}
    try:
        operations[command](*args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"{command}: {error}", file=sys.stderr)
        sys.exit(1)
