"""Run one Ziggify fixture with the DOS oracle or the native compiler."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
COMPILER = ROOT / "zig-out" / "bin" / "gwbc"
SOURCE_FILE = ROOT / "ziggify" / "compiler.zig"
ORACLE_HASH = "ceb0c57c1c31981844a2e41b375cd14f77630e3e200419fe746b501d21dcf333"


def original(program):
    executable = Path(os.environ.get("GWBASIC_EXE", ROOT / ".ziggify/oracle/GWBASIC.EXE"))
    payload = executable.read_bytes()
    if hashlib.sha256(payload).hexdigest() != ORACLE_HASH:
        raise ValueError("GW-BASIC executable does not match the pinned release")

    with tempfile.TemporaryDirectory(prefix="gwbasic-dos-") as directory:
        guest = Path(directory)
        (guest / "GWBASIC.EXE").write_bytes(payload)
        (guest / "INPUT.BAS").write_bytes(b"\r\n".join(program.read_bytes().splitlines()) + b"\r\n")
        config = guest / "dosbox.conf"
        config.write_text("[sdl]\noutput=surface\n[mixer]\nnosound=true\n[midi]\nmididevice=none\n")
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        result = subprocess.run(
            [os.environ.get("DOSBOX", "dosbox"), "-conf", str(config), "-noconsole",
             "-c", 'mount c "."', "-c", "c:", "-c", "gwbasic input.bas", "-c", "exit"],
            cwd=guest, env=env, capture_output=True, timeout=12, check=True,
        )
        output = guest / "OUT.TXT"
        if not output.is_file():
            raise ValueError(f"DOS oracle produced no OUT.TXT\n{result.stdout.decode(errors='replace')}")
        payload = output.read_bytes()
        if b"\x1a" not in payload or len(payload) % 128:
            raise ValueError("DOS oracle did not finish writing OUT.TXT")
        Path("OUT.TXT").write_bytes(payload)


def build():
    COMPILER.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["zig", "build-exe", SOURCE_FILE, "-O", "ReleaseSafe", f"-femit-bin={COMPILER}"],
        check=True,
        cwd=ROOT,
    )


def native(program):
    with tempfile.TemporaryDirectory(prefix="gwbasic-native-") as directory:
        executable = Path(directory, "program")
        subprocess.run([COMPILER, program, "-o", executable], check=True)
        subprocess.run([executable], check=True)


def check():
    with tempfile.TemporaryDirectory(prefix="gwbasic-check-") as directory:
        program = Path(directory, "BAD.BAS")
        for text, diagnostic in [
            ("10 GOTO 40\n20 SYSTEM\n", b"jumps to missing line 40"),
            ("10 SCREEN 1\n20 SYSTEM\n", b"UnsupportedStatement"),
            ("10 REM COMMENT\n10 SYSTEM\n", b"duplicate BASIC line 10"),
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
        operations[command](*map(Path, args))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"{command}: {error}", file=sys.stderr)
        sys.exit(1)
