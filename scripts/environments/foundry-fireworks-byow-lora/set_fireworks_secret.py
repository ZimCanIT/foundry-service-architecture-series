"""Write the Fireworks API key to the Key Vault secret used by the fine-tuning helper, without printing it.

The script runs only when the root's optional Key Vault is on. It reads the vault name from the root's
key_vault_name output (or --vault-name), prompts for the key with getpass, and writes it as the secret
fireworks-api-key with the Key Vault data-plane API. It authenticates with DefaultAzureCredential, which
does not open a browser. It prints only the secret identifier returned by the service, never the value.

Why not az keyvault secret set: --value puts the key in the process argument list, and --file needs the
key on disk first. The SDK call takes the value from memory.

Without --execute the script prints the plan (vault name, secret name, and the exact step it would take)
and exits without prompting or writing. With --execute it prompts for the key and writes the secret.

The deploying user needs the Key Vault Secrets Officer role on the vault. Role assignments can take a few
minutes to apply, so a 403 is retried for up to five minutes before the script gives up.

Usage:
  python set_fireworks_secret.py [--root DIR] [--vault-name NAME] [--secret-name NAME] [--tf BINARY] [--execute]
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

DEFAULT_SECRET_NAME = "fireworks-api-key"
ROOT_DEFAULT = Path(__file__).resolve().parents[3] / "environments" / "foundry-fireworks-byow-lora"
RETRY_WINDOW_SECONDS = 300
RETRY_INTERVAL_SECONDS = 15


def terraform_output(root: Path, name: str) -> str:
    binary = os.environ.get("TF", "terraform")
    result = subprocess.run(
        [binary, f"-chdir={root}", "output", "-raw", name],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def resolve_vault_name(root: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
    try:
        value = terraform_output(root, "key_vault_name")
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        raise SystemExit(
            json.dumps({"error": "could not read key_vault_name from the root", "detail": str(error)[:300],
                        "fix": "run terraform init and apply phase 1 in the root, or pass --vault-name"})
        )
    if not value:
        raise SystemExit(json.dumps({
            "error": "the root has no Key Vault",
            "fix": "set key_vault.enabled = true in the root's tfvars and apply, or pass --vault-name",
        }))
    return value


def write_secret(client: SecretClient, name: str, value: str) -> str:
    deadline = time.monotonic() + RETRY_WINDOW_SECONDS
    attempt = 0
    while True:
        attempt += 1
        try:
            secret = client.set_secret(name, value)
            return secret.id
        except HttpResponseError as error:
            if getattr(error, "status_code", None) != 403 or time.monotonic() >= deadline:
                raise
            print(json.dumps({
                "status": "waiting",
                "attempt": attempt,
                "http_status": 403,
                "message": "Key Vault refused the write. Role assignments take 1 to 5 minutes to apply; retrying.",
            }), flush=True)
            time.sleep(RETRY_INTERVAL_SECONDS)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT_DEFAULT, help="Root folder, read with terraform output. Default: the environment folder.")
    parser.add_argument("--vault-name", help="Key Vault name. Default: the root's key_vault_name output.")
    parser.add_argument("--secret-name", default=DEFAULT_SECRET_NAME, help="Secret name. Default: fireworks-api-key.")
    parser.add_argument("--tf", default=None, help="Terraform binary. Default: the TF environment variable, then terraform.")
    parser.add_argument("--execute", action="store_true", help="Prompt for the key and write the secret. Without it, only the plan is printed.")
    args = parser.parse_args(argv)

    if args.tf:
        os.environ["TF"] = args.tf
    root = args.root.resolve()
    vault_name = resolve_vault_name(root, args.vault_name)
    vault_url = f"https://{vault_name}.vault.azure.net"

    plan = {
        "vault_name": vault_name,
        "vault_url": vault_url,
        "secret_name": args.secret_name,
        "steps": [
            "prompt for the key with getpass (not echoed, not stored)",
            "SecretClient.set_secret(secret_name, value) with DefaultAzureCredential",
            "print the secret identifier only",
        ],
    }
    if not args.execute:
        print(json.dumps({"mode": "print-only", "plan": plan, "next": "re-run with --execute to prompt and write"}, indent=2))
        return 0

    key = getpass.getpass("Fireworks API key (input hidden): ").strip()
    if not key:
        print(json.dumps({"error": "no key entered; nothing written"}))
        return 1

    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    client = SecretClient(vault_url=vault_url, credential=credential)
    try:
        identifier = write_secret(client, args.secret_name, key)
    except HttpResponseError as error:
        print(json.dumps({"error": "Key Vault write failed", "http_status": getattr(error, "status_code", None),
                          "fix": "check the Key Vault Secrets Officer role for the deploying user and the vault name"}, indent=2))
        return 1

    print(json.dumps({"status": "written", "vault_name": vault_name, "secret_name": args.secret_name,
                      "secret_identifier": identifier}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
