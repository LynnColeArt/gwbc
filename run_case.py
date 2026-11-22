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


def stage_console(guest):
    raw = sys.stdin.buffer.read(513)
    keys = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r")
    if len(keys) > 256 or any(byte != 13 and not 32 <= byte <= 126 for byte in keys):
        raise ValueError("console fixture must use at most 256 printable ASCII keystrokes and returns")
    (guest / "KEYS.TXT").write_bytes(keys)
    subprocess.run(["as", "--32", ROOT / "console_oracle.s", "-o", "console.o"], cwd=guest, check=True)
    subprocess.run(
        ["ld", "-m", "elf_i386", "-Ttext", "0x100", "--oformat", "binary",
         "-e", "_start", "-o", "CONSOLE.COM", "console.o"],
        cwd=guest, check=True,
    )


def console_transcript(trace):
    if not trace or len(trace) % 3:
        raise ValueError("DOS oracle produced an empty or incomplete console trace")
    transcript = bytearray()
    row, column = 0, 0
    for next_column, next_row, byte in zip(trace[::3], trace[1::3], trace[2::3]):
        if (next_row, next_column) < (row, column) or next_column >= 79 or next_row >= 24:
            raise ValueError("DOS oracle requires sequential text within the first screen")
        if not 32 <= byte <= 126:
            raise ValueError("DOS oracle requires printable ASCII output")
        if next_row > row:
            transcript.extend(b"\n" * (next_row - row))
            row, column = next_row, 0
        transcript.extend(b" " * (next_column - column))
        transcript.append(byte)
        column = next_column + 1
    return bytes(transcript) + b"\n"


def original(program, mode="file"):
    executable = Path(os.environ.get("GWBASIC_EXE", ROOT / ".ziggify/oracle/GWBASIC.EXE"))
    payload = executable.read_bytes()
    if hashlib.sha256(payload).hexdigest() != ORACLE_HASH:
        raise ValueError("GW-BASIC executable does not match the pinned release")

    with tempfile.TemporaryDirectory(prefix="gwbasic-dos-") as directory:
        guest = Path(directory)
        (guest / "GWBASIC.EXE").write_bytes(payload)
        (guest / "INPUT.BAS").write_bytes(b"\r\n".join(Path(program).read_bytes().splitlines()) + b"\r\n")
        command = "gwbasic input.bas"
        if mode == "console":
            stage_console(guest)
            command = "console.com"
        config = guest / "dosbox.conf"
        config.write_text("[sdl]\noutput=surface\n[mixer]\nnosound=true\n[midi]\nmididevice=none\n")
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        result = subprocess.run(
            [os.environ.get("DOSBOX", "dosbox"), "-conf", str(config), "-noconsole",
             "-c", 'mount c "."', "-c", "c:", "-c", command, "-c", "exit"],
            cwd=guest, env=env, capture_output=True, timeout=12, check=True,
        )
        if mode == "console":
            trace = guest / "TRACE.BIN"
            if not trace.is_file():
                raise ValueError(f"DOS console launcher failed to capture the program\n{result.stdout.decode(errors='replace')}")
            sys.stdout.buffer.write(console_transcript(trace.read_bytes()))
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
        subprocess.run([COMPILER, program, "-o", executable], check=True)
        subprocess.run([executable], check=True)


def check():
    config = json.loads((ROOT / "ziggify.json").read_text())
    samples = {name.upper(): (ROOT / name).read_text() for name in ("hours.bas", "reorder.bas")}
    for case in config["cases"]:
        for fixture in case["files"]:
            sample = samples.get(fixture["path"])
            if sample is not None and fixture["data"] != sample:
                raise ValueError(f"{case['name']} uses a different copy of {fixture['path']}")
    with tempfile.TemporaryDirectory(prefix="gwbasic-check-") as directory:
        program = Path(directory, "BAD.BAS")
        for text, diagnostic in [
            ("10 GOTO 40\n20 SYSTEM\n", b"jumps to missing line 40"),
            ("10 SCREEN 1\n20 SYSTEM\n", b"UnsupportedStatement"),
            ("10 REM COMMENT\n10 SYSTEM\n", b"duplicate BASIC line 10"),
            ("10 NEXT I%\n20 SYSTEM\n", b"NEXT without FOR"),
            ("10 FOR I%=1 TO 2\n20 NEXT J%\n30 SYSTEM\n", b"does not match FOR"),
            ("10 FOR I%=1 TO 2\n20 SYSTEM\n", b"FOR without NEXT"),
            ("10 PRINT (2+3\n20 SYSTEM\n", b"InvalidSyntax"),
            ("10 IF 1 THEN 20 ELSE 30\n20 SYSTEM\n", b"jumps to missing line 30"),
        ]:
            program.write_text(text)
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
