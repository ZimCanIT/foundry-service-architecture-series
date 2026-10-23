#!/usr/bin/env bash
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1

# Uploads the trained LoRA adapter to Foundry and registers it as a custom model with the azd AI
# extension, then reads the registration back. Reads the Terraform outputs of the root, the adapter
# folder and adapter.sha256 written by fireworks_finetune.sh, and the azd sign-in. Print-only unless
# --execute: then it uploads the adapter to Azure (azd ai models create) and reads the model back
# (azd ai models show). It re-hashes the adapter before and after the upload and writes the
# registration JSON under --out. It changes nothing else.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
default_root="$(cd "${script_dir}/../../.." && pwd)/environments/foundry-fireworks-byow-lora"
readonly default_root

root="$default_root"
name="norrvik-triage"
version="1"
base_model=""
source_dir=""
azcopy_path=""
out="./.byow-work"
execute=false

usage() {
  cat <<'EOF'
Upload and register the LoRA adapter as a Foundry custom model, then read the registration back.

Usage:
  scripts/environments/foundry-fireworks-byow-lora/foundry_register_upload.sh --base-model NAME
      --source DIR --azcopy-path PATH [--root DIR] [--name NAME] [--version N] [--out DIR] [--execute]

  --root         Terraform root. Reads foundry_project_endpoint, foundry_account_name and
                 foundry_project_name. Defaults to this environment's root.
  --name         Custom model name. Defaults to norrvik-triage.
  --version      Custom model version. Defaults to 1. A 409 means the name and version exist;
                 bump the version.
  --base-model   Base model string, copied from the portal's Generate upload command. No default:
                 the accepted string for Qwen 3.5 9B is unconfirmed. A bare name is wrapped by the
                 extension as azureml://registries/azureml-fireworks/models/<name>/versions/1.
  --source       Adapter folder: adapter_config.json and adapter_model.safetensors (or .bin), and
                 nothing else. Required.
  --azcopy-path  AzCopy binary. Required, so the extension does not download AzCopy itself.
  --out          Working folder holding adapter.sha256 from fireworks_finetune.sh. Defaults to
                 ./.byow-work.
  --execute      Upload and register. Without it the command is printed and not run.

Before the upload the script re-hashes the adapter and compares it with --out/adapter.sha256. The
upload does not resume after a failure, and the terminal must stay open until it finishes.
Authentication uses the azd session (azd auth login), not az login.

Command run with --execute, in the order shown:
  azd ai models create --project-endpoint ENDPOINT --name NAME --version VERSION --base-model BASE
      --weight-type LoRA --source DIR --azcopy-path PATH --no-prompt
  azd ai models show --name NAME --version VERSION -o json
No --lora-* flags are sent: the service derives rank, alpha and target modules from adapter_config.json.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --base-model) base_model="$2"; shift 2 ;;
    --source) source_dir="$2"; shift 2 ;;
    --azcopy-path) azcopy_path="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --execute) execute=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$base_model" ]]; then
  echo "--base-model is required. Copy the base model from the portal's Generate upload command." >&2
  exit 2
fi
if [[ -z "$source_dir" ]]; then
  echo "--source is required." >&2
  exit 2
fi
if [[ -z "$azcopy_path" ]]; then
  echo "--azcopy-path is required." >&2
  exit 2
fi
if [[ -z "$name" || -z "$version" ]]; then
  echo "--name and --version must not be empty." >&2
  exit 2
fi
if [[ ! -d "$source_dir" ]]; then
  echo "Adapter folder not found: ${source_dir}" >&2
  exit 1
fi
if [[ ! -f "$azcopy_path" ]]; then
  echo "AzCopy not found at --azcopy-path." >&2
  exit 1
fi

tf="${TF:-terraform}"
py="${PYTHON:-python}"
sha_file="${out}/adapter.sha256"
if [[ ! -f "$sha_file" ]]; then
  echo "${sha_file} not found. Run fireworks_finetune.sh verify first." >&2
  exit 1
fi

# Converts a Git Bash path to the Windows form that azd and Python read.
native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# Prints a command with its arguments quoted, to standard error.
show() {
  echo "+ $*" >&2
}

# Compares every file in the adapter folder with adapter.sha256. Files must be exactly the two
# adapter files of one weight type. Prints one line per file; exits 1 on any difference.
check_py='import hashlib, json, os, sys
source, sha_path, label = sys.argv[1:4]
recorded = {}
with open(sha_path, encoding="utf-8") as handle:
    for line in handle:
        if line.strip():
            digest, name = line.rstrip("\n").split("  ", 1)
            recorded[name] = digest
entries = sorted(os.listdir(source))
folders = [e for e in entries if os.path.isdir(os.path.join(source, e))]
files = [e for e in entries if e not in folders]
weights = [w for w in ("adapter_model.safetensors", "adapter_model.bin") if w in files]
expected = {"adapter_config.json"} | set(weights)
problems = []
if folders:
    problems.append("sub-folders present: " + ", ".join(folders))
if len(weights) != 1:
    problems.append("expected exactly one of adapter_model.safetensors or adapter_model.bin")
if set(files) != expected:
    problems.append("unexpected files: " + ", ".join(sorted(set(files) - expected)) if set(files) - expected else "missing adapter files")
print("%s hashes" % label)
for name in files:
    path = os.path.join(source, name)
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    value = digest.hexdigest()
    status = "match" if recorded.get(name) == value else "DIFFERENT"
    if status != "match":
        problems.append("hash differs or not recorded: " + name)
    print("  %-30s %12d bytes  %s  %s" % (name, os.path.getsize(path), value[:16], status))
missing = sorted(set(recorded) - set(files))
if missing:
    problems.append("recorded but not present: " + ", ".join(missing))
if problems:
    for item in problems:
        print("FAIL " + item)
    sys.exit(1)
print("  all %d files match adapter.sha256" % len(files))'

# Reads the azd show output: prints the status and compares the service's file list with the folder.
service_py='import json, os, sys
registration, source = sys.argv[1:3]
with open(registration, encoding="utf-8") as handle:
    data = json.load(handle)
def walk(node, found):
    if isinstance(node, dict):
        found.append(node)
        for value in node.values():
            walk(value, found)
    elif isinstance(node, list):
        for value in node:
            walk(value, found)
    return found
nodes = walk(data, [])
status = next((str(n[k]) for n in nodes for k in ("status", "provisioningState") if isinstance(n.get(k), str)), "not reported")
print("Service status: " + status)
local = {n: os.path.getsize(os.path.join(source, n)) for n in os.listdir(source) if os.path.isfile(os.path.join(source, n))}
reported = {}
for node in nodes:
    name = node.get("name")
    size = next((node[k] for k in node if "size" in k.lower() and isinstance(node[k], int)), None)
    if isinstance(name, str) and size is not None:
        reported[os.path.basename(name)] = size
if not reported:
    print("The service reported no file names with sizes; the per-file check is [To measure].")
    sys.exit(0)
for name in sorted(set(local) | set(reported)):
    if name not in reported:
        print("  not reported by the service: " + name)
    elif name not in local:
        print("  reported but not local: " + name)
    else:
        print("  %-30s local %d, service %d %s" % (name, local[name], reported[name], "match" if local[name] == reported[name] else "DIFFERENT"))
hash_keys = sorted({k for n in nodes for k in n if "sha" in k.lower() or "hash" in k.lower()})
print("Hash fields reported by the service: " + (", ".join(hash_keys) if hash_keys else "none [To measure]"))'

# Terraform outputs.
foundry_account="$("$tf" -chdir="$root" output -raw foundry_account_name)"
foundry_project="$("$tf" -chdir="$root" output -raw foundry_project_name)"
endpoint="$("$tf" -chdir="$root" output -raw foundry_project_endpoint)"
expected_endpoint="https://${foundry_account}.services.ai.azure.com/api/projects/${foundry_project}"
if [[ "$endpoint" != "$expected_endpoint" ]]; then
  echo "The project endpoint does not match the form or the account and project outputs." >&2
  echo "Expected form: https://<account>.services.ai.azure.com/api/projects/<project>" >&2
  exit 1
fi
echo "Project endpoint matches the root outputs (form https://<account>.services.ai.azure.com/api/projects/<project>)."

# Extension and sign-in.
extensions="$(azd extension list --installed 2>/dev/null | tr -d '\r')" || extensions=""
case "$extensions" in
  *azure.ai.models*) ;;
  *)
    echo "The azure.ai.models extension is not installed. Run: azd extension install azure.ai.models" >&2
    exit 1
    ;;
esac
echo "azure.ai.models extension: installed."
if ! azd auth login --check-status >/dev/null 2>&1; then
  echo "azd is not signed in. Run azd auth login (az login does not count here)." >&2
  exit 1
fi
echo "azd sign-in: valid."

# Before-upload hashes.
"$py" -I -c "$check_py" "$(native "$source_dir")" "$(native "$sha_file")" "Before upload" || {
  echo "The adapter folder does not match adapter.sha256. Do not upload; rerun the training stages." >&2
  exit 1
}

endpoint_args=(--project-endpoint "$endpoint" --name "$name" --version "$version" --base-model "$base_model"
  --weight-type LoRA --source "$(native "$source_dir")" --azcopy-path "$(native "$azcopy_path")" --no-prompt)
show_args=(--name "$name" --version "$version" -o json)

echo
echo "Upload command (compare with the portal's Generate upload command before --execute):"
show azd ai models create "${endpoint_args[@]}"
echo

if [[ "$execute" != true ]]; then
  echo "Print-only: nothing uploaded. The read-back that follows the upload is:"
  show azd ai models show "${show_args[@]}"
  exit 0
fi

mkdir -p "$out"
if ! azd ai models create "${endpoint_args[@]}"; then
  echo "The upload failed. It does not resume: fix the cause and start again." >&2
  echo "409: the name and version exist; bump --version. 403: a role is missing; see the environment README for the roles." >&2
  exit 1
fi

registration="${out}/registration.json"
if ! azd ai models show "${show_args[@]}" > "$registration"; then
  echo "The upload finished but the model could not be read back. Run azd ai models show by hand." >&2
  exit 1
fi
echo
"$py" -I -c "$service_py" "$(native "$registration")" "$(native "$source_dir")"
echo
"$py" -I -c "$check_py" "$(native "$source_dir")" "$(native "$sha_file")" "After upload" || {
  echo "The adapter folder changed during the upload. Do not use this registration." >&2
  exit 1
}
echo "Registration read back: ${registration}."
