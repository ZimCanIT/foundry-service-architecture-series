"""Run terraform or tflint in a container when the host cannot run the binary.

The repository is mounted at /repo and the current directory is mapped to the matching path inside
the mount, so relative module sources, lock files and the shared .tflint.hcl keep working.

Usage: docker_tool.py {terraform|tflint} [args...]

Point the pre-commit hooks at it with:
  TERRAFORM_HOOKS_TERRAFORM="python <repo>/scripts/shared/docker_tool.py terraform"
  TERRAFORM_HOOKS_TFLINT="python <repo>/scripts/shared/docker_tool.py tflint"

Images are pinned and can be overridden with TERRAFORM_IMAGE and TFLINT_IMAGE. TFLint plugins persist
in TFLINT_PLUGIN_CACHE (default: tflint-plugins under LOCALAPPDATA or the home directory).
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TERRAFORM_IMAGE = os.environ.get("TERRAFORM_IMAGE", "hashicorp/terraform:1.15.9")
TFLINT_IMAGE = os.environ.get("TFLINT_IMAGE", "ghcr.io/terraform-linters/tflint:v0.64.0")


def container_workdir() -> str:
    cwd = Path.cwd().resolve()
    try:
        rel = cwd.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        raise SystemExit(f"{cwd} is outside the repository {REPO_ROOT}")
    return "/repo" if rel == "." else f"/repo/{rel}"


def map_args(args: list[str]) -> list[str]:
    mapped = []
    for arg in args:
        if arg.startswith("--config=") and arg.endswith(".tflint.hcl"):
            arg = "--config=/repo/.tflint.hcl"
        elif str(REPO_ROOT) in arg:
            arg = arg.replace(str(REPO_ROOT), "/repo").replace("\\", "/")
        mapped.append(arg)
    return mapped


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in {"terraform", "tflint"}:
        raise SystemExit(__doc__)
    tool, args = sys.argv[1], map_args(sys.argv[2:])
    env = {**os.environ, "MSYS_NO_PATHCONV": "1", "MSYS2_ARG_CONV_EXCL": "*"}
    base = ["docker", "run", "--rm", "-v", f"{REPO_ROOT}:/repo", "-w", container_workdir()]
    if tool == "terraform":
        cmd = [*base, TERRAFORM_IMAGE, *args]
    else:
        cache = Path(os.environ.get("TFLINT_PLUGIN_CACHE") or Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "tflint-plugins")
        cache.mkdir(parents=True, exist_ok=True)
        cmd = [*base, "-e", "TFLINT_PLUGIN_DIR=/plugins", "-v", f"{cache}:/plugins", TFLINT_IMAGE, *args]
    return subprocess.run(cmd, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())
