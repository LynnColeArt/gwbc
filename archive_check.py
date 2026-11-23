"""Build every .BAS file in the pinned AllBasicCode snapshot."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from run_case import COMPILER

REVISION = "d4e65c52d782ba03f69fb15ea7a97a9b13e41bdd"


def survey(archive):
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=archive, text=True).strip()
    changes = subprocess.check_output(["git", "status", "--porcelain", "--", "AllBasicCode"],
                                      cwd=archive, text=True)
    if head != REVISION or changes:
        raise SystemExit(f"Expected a clean archive at {REVISION}")
    if not COMPILER.is_file():
        raise SystemExit("Build gwbc first with zig build -Doptimize=ReleaseSafe.")
    files = sorted(path for path in (archive / "AllBasicCode").iterdir()
                   if path.is_file() and path.suffix.lower() == ".bas")
    with tempfile.TemporaryDirectory(prefix="gwbc-archive-") as directory:
        executable = Path(directory, "program")
        for source in files:
            result = subprocess.run([COMPILER, source, "-o", executable],
                                    capture_output=True, text=True, errors="replace", timeout=90)
            if result.returncode == 0:
                executable.unlink()
                yield source.name, "Built"
            else:
                diagnostic = next(iter(result.stderr.splitlines()), "No compiler diagnostic")
                yield source.name, diagnostic.replace(str(source), source.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="checkout of robhagemans/hoard-of-gwbasic")
    args = parser.parse_args()
    for name, status in survey(args.archive.resolve()):
        print(f"{name}\t{status}")


if __name__ == "__main__":
    main()
