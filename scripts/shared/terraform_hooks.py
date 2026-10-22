"""Pre-commit Terraform checks that run on Windows, macOS and Linux without bash.

Usage: terraform_hooks.py {fmt,validate,tflint} [files...]
Runs the check once for each Terraform directory that contains a passed file.
"""

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TFLINT_CONFIG = REPO_ROOT / ".tflint.hcl"


def run(cmd: list[str], cwd: Path) -> int:
    print(f"[{cwd.relative_to(REPO_ROOT)}] {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, cwd=cwd).returncode


def check(action: str, directory: Path) -> int:
    if action == "fmt":
        return run(["terraform", "fmt", "-check", "-diff"], directory)
    if action == "validate":
        if not (directory / ".terraform").is_dir():
            # Modules have no lock file, so only roots read it as read-only.
            lock = ["-lockfile=readonly"] if (directory / ".terraform.lock.hcl").exists() else []
            if run(["terraform", "init", "-backend=false", "-input=false", *lock], directory):
                return 1
        return run(["terraform", "validate", "-no-color"], directory)
    if action == "tflint":
        if run(["tflint", "--init", f"--config={TFLINT_CONFIG}"], directory):
            return 1
        return run(["tflint", f"--config={TFLINT_CONFIG}"], directory)
    raise SystemExit(f"Unknown action: {action}")


def main() -> int:
    action, files = sys.argv[1], sys.argv[2:]
    directories = sorted({(REPO_ROOT / f).resolve().parent for f in files})
    failed = [d for d in directories if check(action, d)]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
