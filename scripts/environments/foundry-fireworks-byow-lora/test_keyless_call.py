"""Make one keyless call to a bring-your-own-weights deployment and check the four labels in the reply.

The script authenticates with Microsoft Entra ID through DefaultAzureCredential (the az login session,
a managed identity or environment credentials) and requests a token for the Foundry scope
https://ai.azure.com/.default. It never reads or prints an API key, and it never prints the token.
Only the token's idtyp claim and a shortened object ID are decoded locally, so the call can be matched
to its log rows. No names or sign-in names are printed.

Two routes are exercised by default, both on the Foundry-managed /openai/v1 endpoint:
  1. Chat Completions.
  2. Responses with store=false, so the service does not retain the response.
Other routes, including the Fireworks passthrough, are not called. The keyless claim covers only the
routes this script calls. Pass --skip-responses if the Responses route is not available on the deployment.

The request is a held-out FNOL report from the dataset folder (--index N, default 0), with the system
and user messages only. The reply should be one JSON object with one key per label field. The script parses it and checks each
value against the vocabularies in manifest.json. When the record has a reference answer, it also prints whether each field matches. One
call is a demonstration, not an evaluation; the evaluation is a separate step.

Deployments can take minutes to accept calls after creation, and role assignments take minutes to apply.
--wait-ready MINUTES retries 401, 403, 404, 429 and 503 with backoff, printing each status, until the
time limit. Without it the first error stops the script. A 404 on the Responses route after Chat
Completions has succeeded is not retried: it is reported with the advice to use --skip-responses.

Calls are billed through the provisioned deployment (hourly, not per token), so each call adds no
per-token charge. Logs reach Log Analytics 3 to 10 minutes after a call; record the printed UTC time.

Usage:
  python test_keyless_call.py [--root DIR] [--account-name NAME] [--adapter KEY | --deployment NAME]
      [--dataset-dir DIR] [--index N | --prompt TEXT] [--skip-responses] [--wait-ready MINUTES] [--tf BINARY]
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import openai
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import OpenAI

FOUNDRY_SCOPE = "https://ai.azure.com/.default"
ROOT_DEFAULT = Path(__file__).resolve().parents[3] / "environments" / "foundry-fireworks-byow-lora"
DATASET_DEFAULT = Path(".byow-work/dataset")
RETRY_STATUSES = {401, 403, 404, 429, 503}
MAX_BACKOFF_SECONDS = 60
MAX_TOKENS = 300


def terraform_output(root: Path, name: str, as_json: bool = False):
    """Read one output. -raw suits strings, numbers and bools; maps and null need -json."""
    binary = os.environ.get("TF", "terraform")
    try:
        result = subprocess.run(
            [binary, f"-chdir={root}", "output", "-json" if as_json else "-raw", name],
            check=True,
            capture_output=True,
            text=True,
        )
    except OSError:
        raise SystemExit(json.dumps({
            "error": f"could not run {binary}",
            "fix": "install Terraform or set TF (or --tf) to the Terraform binary",
        }))
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip().splitlines()
        raise SystemExit(json.dumps({
            "error": f"could not read the {name} output from the root",
            "detail": (detail[0] if detail else f"exit code {error.returncode}")[:300],
            "fix": "run terraform init and apply the earlier phase in the root, check --root, "
                   "or pass the value on the command line",
        }))
    text = result.stdout.strip()
    if not as_json:
        return text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise SystemExit(json.dumps({
            "error": f"the {name} output is not valid JSON",
            "fix": "check the Terraform binary (TF or --tf) and rerun terraform output -json " + name,
        }))


def resolve_account(root: Path, explicit: str | None) -> str:
    return explicit or terraform_output(root, "foundry_account_name")


def resolve_deployment(root: Path, deployment: str | None, adapter: str | None) -> str:
    if deployment:
        return deployment
    names = terraform_output(root, "byow_deployment_names", as_json=True)
    if not isinstance(names, dict) or not names:
        raise SystemExit(json.dumps({
            "error": "no BYOW deployment in the root outputs",
            "fix": "apply phase 2 (one adapter entry) first, or pass --deployment",
        }))
    if adapter:
        if adapter not in names:
            raise SystemExit(json.dumps({"error": "adapter key not in byow_deployment_names", "keys": sorted(names)}))
        return names[adapter]
    if len(names) > 1:
        raise SystemExit(json.dumps({"error": "more than one deployment; choose with --adapter", "keys": sorted(names)}))
    return next(iter(names.values()))


def load_vocabularies(dataset_dir: Path) -> dict[str, list[str]] | None:
    manifest = dataset_dir / "manifest.json"
    if not manifest.is_file():
        return None
    return json.loads(manifest.read_text(encoding="utf-8"))["vocabularies"]


def load_messages(args: argparse.Namespace) -> tuple[list[dict], dict | None, str]:
    if args.prompt is not None:
        return [{"role": "user", "content": args.prompt}], None, "free text (no label check)"
    prompt_file = args.prompt_file or (args.dataset_dir / "heldout.jsonl")
    lines = [line for line in prompt_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not 0 <= args.index < len(lines):
        raise SystemExit(json.dumps({"error": "index out of range", "records": len(lines), "index": args.index}))
    messages = json.loads(lines[args.index])["messages"]
    expected = None
    if messages[-1]["role"] == "assistant":
        expected = json.loads(messages[-1]["content"])
        messages = messages[:-1]
    return messages, expected, f"{prompt_file.name}[{args.index}]"


def caller_identity(credential: DefaultAzureCredential) -> dict:
    token = credential.get_token(FOUNDRY_SCOPE).token
    payload_part = token.split(".")[1]
    payload = json.loads(base64.urlsafe_b64decode(payload_part + "=" * (-len(payload_part) % 4)))
    oid = payload.get("oid")
    return {
        "idtyp": payload.get("idtyp", "absent"),
        "object_id_prefix": f"{oid[:8]}..." if oid else None,
    }


def check_labels(text: str, vocabularies: dict[str, list[str]] | None, expected: dict | None) -> dict:
    if vocabularies is None and expected is None:
        return {"applicable": False, "passed": True, "reason": "no manifest and no reference answer"}
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`").removeprefix("json").strip()
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError:
        return {"parsed_as_json": False, "passed": False}
    if not isinstance(parsed, dict):
        return {"parsed_as_json": False, "passed": False}
    fields = {}
    field_names = list(vocabularies) if vocabularies is not None else list(expected)
    for field in field_names:
        value = parsed.get(field)
        entry = {"value": value}
        if vocabularies is not None:
            entry["in_vocabulary"] = value in vocabularies.get(field, [])
        if expected is not None:
            entry["matches_reference"] = value == expected.get(field)
        fields[field] = entry
    passed = all(
        entry.get("in_vocabulary", True) and entry.get("matches_reference", True) for entry in fields.values()
    )
    return {"parsed_as_json": True, "fields": fields, "passed": passed,
            "vocabulary_checked": vocabularies is not None, "reference_checked": expected is not None}


def with_retry(call, wait_ready_minutes: float, route: str,
               retry_statuses: set[int] = RETRY_STATUSES) -> tuple[object, int]:
    deadline = time.monotonic() + wait_ready_minutes * 60
    backoff = 5
    attempt = 0
    while True:
        attempt += 1
        try:
            return call(), attempt
        except openai.APIStatusError as error:
            status = error.status_code
            if status not in retry_statuses or time.monotonic() + backoff > deadline:
                raise
            print(json.dumps({"route": route, "status": "retrying", "attempt": attempt, "http_status": status,
                              "wait_seconds": backoff}), flush=True)
            time.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF_SECONDS)


def report(route: str, started: float, response, raw_headers, attempts: int, check: dict) -> None:
    elapsed_ms = round((time.perf_counter() - started) * 1000)
    request_id = raw_headers.get("apim-request-id") or raw_headers.get("x-request-id") or raw_headers.get("x-ms-request-id")
    usage = getattr(response, "usage", None)
    print(json.dumps({
        "route": route,
        "utc_time": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "request_id": request_id,
        "client_latency_ms": elapsed_ms,
        "attempts": attempts,
        "model": getattr(response, "model", None),
        "usage": usage.model_dump() if usage is not None else {},
        "label_check": check,
    }, indent=2))


def call_chat_completions(client: OpenAI, deployment: str, messages: list[dict], wait_minutes: float,
                          vocabularies, expected) -> bool:
    route = "POST /openai/v1/chat/completions"
    started = time.perf_counter()

    def send():
        return client.chat.completions.with_raw_response.create(
            model=deployment, messages=messages, max_tokens=MAX_TOKENS)

    raw, attempts = with_retry(send, wait_minutes, route)
    response = raw.parse()
    text = response.choices[0].message.content or ""
    check = check_labels(text, vocabularies, expected)
    report(route, started, response, raw.headers, attempts, check)
    print(json.dumps({"route": route, "completion": text.strip()}, ensure_ascii=False))
    return check["passed"] if check.get("applicable", True) else True


def call_responses(client: OpenAI, deployment: str, messages: list[dict], wait_minutes: float,
                   vocabularies, expected) -> bool:
    route = "POST /openai/v1/responses (store=false)"
    started = time.perf_counter()

    def send():
        return client.responses.with_raw_response.create(
            model=deployment, input=messages, store=False, max_output_tokens=MAX_TOKENS)

    # A 404 here, after Chat Completions succeeded, means the route is missing on this deployment, not
    # that the deployment is still starting, so it is not retried.
    raw, attempts = with_retry(send, wait_minutes, route, RETRY_STATUSES - {404})
    response = raw.parse()
    text = response.output_text or ""
    check = check_labels(text, vocabularies, expected)
    report(route, started, response, raw.headers, attempts, check)
    print(json.dumps({"route": route, "response_id": response.id, "output": text.strip()}, ensure_ascii=False))
    return check["passed"] if check.get("applicable", True) else True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT_DEFAULT, help="Root folder, read with terraform output. Default: the environment folder.")
    parser.add_argument("--account-name", help="Foundry account name. Default: the root's foundry_account_name output.")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--adapter", help="Key of the entry in byow_deployment_names. Needed only when there is more than one.")
    target.add_argument("--deployment", help="Deployment name, instead of reading byow_deployment_names.")
    parser.add_argument("--dataset-dir", type=Path, default=DATASET_DEFAULT, help="Dataset folder with manifest.json and heldout.jsonl. Default: ./.byow-work/dataset.")
    parser.add_argument("--prompt-file", type=Path, help="JSONL file to read the record from. Default: heldout.jsonl in the dataset folder.")
    parser.add_argument("--index", type=int, default=0, help="Zero-based line of the record in the prompt file. Default: 0.")
    parser.add_argument("--prompt", help="Send this free text instead of a dataset record. No label check is run.")
    parser.add_argument("--skip-responses", action="store_true", help="Call only Chat Completions.")
    parser.add_argument("--wait-ready", type=float, default=0.0, metavar="MINUTES", help="Retry 401, 403, 404, 429 and 503 for up to this many minutes. Default: 0.")
    parser.add_argument("--tf", default=None, help="Terraform binary. Default: the TF environment variable, then terraform.")
    args = parser.parse_args(argv)

    if args.tf:
        os.environ["TF"] = args.tf
    root = args.root.resolve()
    account = resolve_account(root, args.account_name)
    deployment = resolve_deployment(root, args.deployment, args.adapter)
    messages, expected, source = load_messages(args)
    vocabularies = None if args.prompt is not None else load_vocabularies(args.dataset_dir)

    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    token_provider = get_bearer_token_provider(credential, FOUNDRY_SCOPE)
    client = OpenAI(base_url=f"https://{account}.services.ai.azure.com/openai/v1/", api_key=token_provider)

    print(json.dumps({
        "account": account,
        "deployment": deployment,
        "prompt_source": source,
        "reference_answer": expected is not None,
        "vocabulary_check": vocabularies is not None,
        "caller": caller_identity(credential),
    }, indent=2))

    chat_done = False
    try:
        ok = call_chat_completions(client, deployment, messages, args.wait_ready, vocabularies, expected)
        chat_done = True
        if not args.skip_responses:
            ok = call_responses(client, deployment, messages, args.wait_ready, vocabularies, expected) and ok
    except openai.APIStatusError as error:
        if chat_done and error.status_code == 404:
            print(json.dumps({"error": "the Responses route returned 404 after Chat Completions succeeded",
                              "http_status": 404,
                              "fix": "the route is not available on this deployment [To measure]; "
                                     "rerun with --skip-responses to call Chat Completions only."}, indent=2))
            return 1
        print(json.dumps({"error": "call failed", "http_status": error.status_code,
                          "fix": "401 and 403 point to role assignments (allow minutes); 404 to the deployment name; "
                                 "429 and 503 to capacity or backoff. Use --wait-ready to retry."}, indent=2))
        return 1
    except openai.APIError as error:
        print(json.dumps({"error": "call failed", "type": type(error).__name__}, indent=2))
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
