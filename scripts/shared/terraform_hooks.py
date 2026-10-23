"""Pre-commit Terraform checks that run on Windows, macOS and Linux without bash.

Usage: terraform_hooks.py {fmt,validate,tflint} [files...]
Runs the check once for each Terraform directory that contains a passed file.

Set TERRAFORM_HOOKS_TERRAFORM or TERRAFORM_HOOKS_TFLINT to a command that replaces the
binary found on PATH. The command receives the same arguments.
"""

import os
import shlex
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TFLINT_CONFIG = REPO_ROOT / ".tflint.hcl"
TERRAFORM = shlex.split(os.environ.get("TERRAFORM_HOOKS_TERRAFORM", "terraform"))
TFLINT = shlex.split(os.environ.get("TERRAFORM_HOOKS_TFLINT", "tflint"))


def run(cmd: list[str], cwd: Path) -> int:
    print(f"[{cwd.relative_to(REPO_ROOT)}] {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, cwd=cwd).returncode


def init(directory: Path) -> int:
    if (directory / ".terraform").is_dir():
        return 0
    # Modules have no lock file, so only roots read it as read-only.
    lock = ["-lockfile=readonly"] if (directory / ".terraform.lock.hcl").exists() else []
    return run([*TERRAFORM, "init", "-backend=false", "-input=false", *lock], directory)


def check(action: str, directory: Path) -> int:
    if action == "fmt":
        return run([*TERRAFORM, "fmt", "-check", "-diff"], directory)
    if action == "validate":
        if init(directory):
            return 1
        return run([*TERRAFORM, "validate", "-no-color"], directory)
    if action == "tflint":
        # call_module_type = "all" in .tflint.hcl needs registry modules installed by init.
        if init(directory) or run([*TFLINT, "--init", f"--config={TFLINT_CONFIG}"], directory):
            return 1
        return run([*TFLINT, f"--config={TFLINT_CONFIG}"], directory)
    raise SystemExit(f"Unknown action: {action}")


def main() -> int:
    action, files = sys.argv[1], sys.argv[2:]
    directories = sorted({(REPO_ROOT / f).resolve().parent for f in files})
    failed = [d for d in directories if check(action, d)]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
