"""Run terraform init, validate and test for each module, on one provider track.

Usage: module_tests.py [--providers pinned|latest] [--lock-from DIR] [MODULE_DIR ...]

With no MODULE_DIR, every modules/*/ directory that holds a versions.tf is tested.
Paths are relative to the repository root unless they are absolute.

The latest track (the default) moves a module's lock file aside, so the newest allowed
provider versions resolve. The pinned track copies DIR/.terraform.lock.hcl into each
module first, so the module is tested against the versions a root pins. --lock-from is
required for the pinned track and is not allowed otherwise. On both tracks the module's
own lock file is put back byte for byte, and any lock file the run creates is removed.

Each module runs with its own temporary TF_DATA_DIR, so its .terraform directory is never
touched. Set TF_PLUGIN_CACHE_DIR to keep providers between runs. Without it, a temporary
cache is shared by the modules of one run and removed at the end.

Set TERRAFORM_HOOKS_TERRAFORM to a command that replaces the binary found on PATH.
Set GITHUB_STEP_SUMMARY to append the results table to the job summary as Markdown.
The exit status is 1 when any module failed, and each failed module is named on stderr.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TERRAFORM = shlex.split(os.environ.get("TERRAFORM_HOOKS_TERRAFORM", "terraform"))
LOCK_FILE = ".terraform.lock.hcl"
SUMMARY_LINE = re.compile(r"(?:Success|Failure)! (\d+) passed, (\d+) failed")
HEADERS = ["module", "provider versions", "validate", "tests", "seconds"]


@dataclass
class Result:
    module: str
    versions: str = "-"
    validate: str = "not run"
    tests: str = "-"
    seconds: float = 0.0
    failed: bool = False


def label(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def run(cmd: list[str], cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    """Run one command, echo its output so the job log keeps it, and return the result."""
    print(f"[{label(cwd)}] {' '.join(cmd)}", flush=True)
    try:
        proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                              encoding="utf-8", errors="replace")
    except OSError as error:
        raise SystemExit(f"module_tests: cannot start {cmd[0]}: {error}") from error
    print(proc.stdout, end="", flush=True)
    print(proc.stderr, end="", file=sys.stderr, flush=True)
    return proc


def remove_tree(path: Path) -> None:
    """Delete a temporary directory, clearing read-only flags first (Windows needs this)."""
    for item in path.rglob("*"):
        if item.is_file() and not item.is_symlink():
            item.chmod(stat.S_IREAD | stat.S_IWRITE)
    shutil.rmtree(path, ignore_errors=True)
    if path.exists():
        print(f"module_tests: could not remove {path}", file=sys.stderr)


def plugin_cache() -> tuple[str, bool]:
    """Return the provider cache to use, and whether this run created it."""
    existing = os.environ.get("TF_PLUGIN_CACHE_DIR")
    if existing:
        return existing, False
    return tempfile.mkdtemp(prefix="tpc"), True


@contextmanager
def lock_for_track(module: Path, data_dir: Path, lock_from: Path | None) -> Iterator[None]:
    """Set the module's lock file for one track, then put the module's own lock back."""
    lock = module / LOCK_FILE
    kept = data_dir / "module-lock.hcl"
    had_lock = lock.is_file()
    if had_lock:
        shutil.move(lock, kept)
    try:
        if lock_from is not None:
            shutil.copyfile(lock_from / LOCK_FILE, lock)
        yield
    finally:
        if lock.exists():
            lock.unlink()
        if had_lock:
            shutil.move(kept, lock)


def provider_versions(module: Path, env: dict[str, str]) -> str:
    """Name the provider versions that init selected, read from terraform version -json."""
    proc = subprocess.run([*TERRAFORM, "version", "-json"], cwd=module, env=env,
                          capture_output=True, encoding="utf-8", errors="replace")
    try:
        selections = json.loads(proc.stdout)["provider_selections"]
    except (ValueError, KeyError, TypeError):
        return "-"
    names = [f"{address.rsplit('/', 1)[-1]} {version}"
             for address, version in sorted(selections.items())]
    return ", ".join(names) or "-"


def has_tests(module: Path) -> bool:
    return any((module / "tests").glob("*.tftest.hcl"))


def run_steps(module: Path, env: dict[str, str], result: Result) -> None:
    """Run init, then validate and test. Validate and test are skipped only when init fails."""
    init = run([*TERRAFORM, "init", "-backend=false", "-input=false"], module, env)
    if init.returncode:
        result.failed = True
        result.tests = "not run" if has_tests(module) else "-"
        return
    result.versions = provider_versions(module, env)
    validate = run([*TERRAFORM, "validate", "-no-color"], module, env)
    result.validate = "passed" if validate.returncode == 0 else "failed"
    result.failed = validate.returncode != 0
    if has_tests(module):
        tests = run([*TERRAFORM, "test", "-no-color"], module, env)
        match = SUMMARY_LINE.search(tests.stdout + tests.stderr)
        result.tests = f"{match[1]} passed, {match[2]} failed" if match else "error"
        if match is None or tests.returncode != 0:
            result.failed = True


def check_module(module: Path, lock_from: Path | None, base_env: dict[str, str]) -> Result:
    """Check one module in its own temporary data directory. A failure does not stop the run."""
    started = time.perf_counter()
    result = Result(label(module))
    data_dir = Path(tempfile.mkdtemp(prefix="tfd"))
    env = {**base_env, "TF_DATA_DIR": str(data_dir)}
    try:
        with lock_for_track(module, data_dir, lock_from):
            run_steps(module, env, result)
    finally:
        remove_tree(data_dir)
        result.seconds = time.perf_counter() - started
    return result


def plain_table(rows: list[list[str]]) -> str:
    """Align the table in columns for the job log."""
    widths = [max(len(row[col]) for row in [HEADERS, *rows]) for col in range(len(HEADERS))]
    lines = [HEADERS, ["-" * width for width in widths], *rows]
    return "\n".join("  ".join(cell.ljust(width) for cell, width in zip(line, widths)).rstrip()
                     for line in lines)


def markdown_table(rows: list[list[str]]) -> str:
    lines = [HEADERS, ["---"] * len(HEADERS), *rows]
    return "\n".join("| " + " | ".join(line) + " |" for line in lines)


def default_modules() -> list[Path]:
    return sorted(path for path in (REPO_ROOT / "modules").iterdir()
                  if (path / "versions.tf").is_file())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run terraform init, validate and test for each module.")
    parser.add_argument("--providers", choices=["pinned", "latest"], default="latest",
                        help="provider track (default: latest)")
    parser.add_argument("--lock-from", metavar="DIR",
                        help="directory with the reference .terraform.lock.hcl "
                        "(required for pinned)")
    parser.add_argument("modules", nargs="*", metavar="MODULE_DIR",
                        help="module directories (default: each modules/*/ "
                        "that holds a versions.tf)")
    args = parser.parse_args()
    if args.providers == "pinned" and args.lock_from is None:
        parser.error("--lock-from DIR is required with --providers pinned")
    if args.providers == "latest" and args.lock_from is not None:
        parser.error("--lock-from can only be used with --providers pinned")
    if args.lock_from is not None and not (REPO_ROOT / args.lock_from / LOCK_FILE).is_file():
        parser.error(f"no {LOCK_FILE} in {args.lock_from}")
    for module in args.modules:
        if not (REPO_ROOT / module).is_dir():
            parser.error(f"not a directory: {module}")
    return args


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    args = parse_args()
    modules = [(REPO_ROOT / module).resolve() for module in args.modules] or default_modules()
    if not modules:
        raise SystemExit("module_tests: no module directories hold a versions.tf")
    lock_from = (REPO_ROOT / args.lock_from).resolve() if args.lock_from else None
    cache, created = plugin_cache()
    base_env = {**os.environ, "TF_PLUGIN_CACHE_DIR": cache}
    try:
        results = [check_module(module, lock_from, base_env) for module in modules]
    finally:
        if created:
            remove_tree(Path(cache))
    rows = [[r.module, r.versions, r.validate, r.tests, f"{r.seconds:.1f}"] for r in results]
    print(f"\nProvider track: {args.providers}")
    print(plain_table(rows))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            heading = f"### Module tests ({args.providers} providers)"
            handle.write(f"{heading}\n\n{markdown_table(rows)}\n\n")
    failed = [r.module for r in results if r.failed]
    for module in failed:
        print(f"module_tests: failed: {module}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
