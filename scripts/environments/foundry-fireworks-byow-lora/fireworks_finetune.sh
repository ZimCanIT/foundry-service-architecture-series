#!/usr/bin/env bash
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1

# Runs the Fireworks side of the bring-your-own-weights LoRA walkthrough: uploads the train and
# evaluation datasets, starts one supervised fine-tuning job, polls it until it ends, downloads the
# adapter, then checks and hashes the files. Reads the local dataset folder and the Key Vault secret
# when --key-from-keyvault is given. With --execute it spends Fireworks credit, uploads datasets and
# downloads model files; without it every firectl and az call is printed and not run. The verify
# stage reads local files only, so it always runs. Writes working files under --out only.

readonly -a terminal_states=(JOB_STATE_COMPLETED JOB_STATE_FAILED JOB_STATE_CANCELLED JOB_STATE_EXPIRED JOB_STATE_EARLY_STOPPED)
readonly fw_id_pattern='^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'

stage=""
account_id=""
data_dir=""
dataset_id="fnol-triage-train"
eval_dataset_id="fnol-triage-eval"
base_model="accounts/fireworks/models/qwen3p5-9b"
output_model="fnol-triage-v1"
lora_rank="16"
epochs="1"
out="./.byow-work"
firectl_cmd="firectl"
key_vault=""
job_override=""
poll_seconds="60"
execute=false

usage() {
  cat <<'EOF'
Run the Fireworks fine-tuning stages for the bring-your-own-weights LoRA walkthrough.

Usage:
  scripts/environments/foundry-fireworks-byow-lora/fireworks_finetune.sh --stage STAGE --account-id ID
      [--data-dir DIR] [--dataset-id ID] [--eval-dataset-id ID] [--base-model NAME]
      [--output-model ID] [--lora-rank N] [--epochs N] [--out DIR] [--firectl COMMAND]
      [--key-from-keyvault VAULT] [--job NAME] [--poll-seconds N] [--execute]

  --stage            dataset, train, wait, download, verify or all (required).
                       dataset   uploads train.jsonl and eval.jsonl from --data-dir.
                       train     starts the SFT job. Spends Fireworks credit.
                       wait      polls the job until it ends.
                       download  downloads the output model into --out/adapter.
                       verify    checks the adapter files and writes adapter.sha256 (local only).
                       all       dataset, train, wait, download, verify, in that order.
  --account-id       Fireworks account, passed to firectl as -a (required).
  --data-dir         Folder with train.jsonl and eval.jsonl. Defaults to --out/dataset.
                     heldout.jsonl is never uploaded.
  --dataset-id       Training dataset ID. Defaults to fnol-triage-train.
  --eval-dataset-id  Evaluation dataset ID. Defaults to fnol-triage-eval.
  --base-model       Base model name. Defaults to accounts/fireworks/models/qwen3p5-9b.
  --output-model     Output model ID. Defaults to fnol-triage-v1.
  --lora-rank        LoRA rank, always passed. Defaults to 16.
  --epochs           Training epochs. Defaults to 1.
  --out              Working folder. Defaults to ./.byow-work.
  --firectl          firectl command. Defaults to firectl. For the WSL route, for example
                     "wsl -d Ubuntu-26.04 -- firectl"; file paths are then converted with wslpath.
  --key-from-keyvault
                     Read the Fireworks key from the fireworks-api-key secret in this Key Vault and
                     pass it as --api-key. Needs --execute. The key is not printed or written to disk.
                     Without this flag, the existing firectl signin is used.
  --job              Job name for wait. Defaults to the name saved by train in --out/job-name.txt.
  --poll-seconds     Seconds between polls in wait. Defaults to 60.
  --execute          Run the firectl and az calls. Without it they are printed only.

IDs are checked against the Fireworks rules before any call: 1 to 63 characters of a-z, 0-9 and
hyphen, starting with a letter and not ending with a hyphen.

Spend control, a separate step before train (this script does not set it):
  firectl quota update monthly-spend-usd --value AMOUNT

Local files: verify reads the adapter folder and writes --out/adapter.sha256 and
--out/firectl-version.txt. It calls firectl version --long to record the version only.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) stage="$2"; shift 2 ;;
    --account-id) account_id="$2"; shift 2 ;;
    --data-dir) data_dir="$2"; shift 2 ;;
    --dataset-id) dataset_id="$2"; shift 2 ;;
    --eval-dataset-id) eval_dataset_id="$2"; shift 2 ;;
    --base-model) base_model="$2"; shift 2 ;;
    --output-model) output_model="$2"; shift 2 ;;
    --lora-rank) lora_rank="$2"; shift 2 ;;
    --epochs) epochs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --firectl) firectl_cmd="$2"; shift 2 ;;
    --key-from-keyvault) key_vault="$2"; shift 2 ;;
    --job) job_override="$2"; shift 2 ;;
    --poll-seconds) poll_seconds="$2"; shift 2 ;;
    --execute) execute=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$stage" in
  dataset | train | wait | download | verify | all) ;;
  *) echo "--stage is required: dataset, train, wait, download, verify or all." >&2; usage >&2; exit 2 ;;
esac
if [[ -z "$account_id" ]]; then
  echo "--account-id is required." >&2
  exit 2
fi
for pair in "dataset-id:$dataset_id" "eval-dataset-id:$eval_dataset_id" "output-model:$output_model"; do
  if [[ ! "${pair#*:}" =~ $fw_id_pattern ]]; then
    echo "--${pair%%:*} '${pair#*:}' breaks the Fireworks ID rules: 1 to 63 characters of a-z, 0-9 and hyphen, starting with a letter and not ending with a hyphen." >&2
    exit 2
  fi
done
if [[ ! "$lora_rank" =~ ^[1-9][0-9]*$ || ! "$epochs" =~ ^[1-9][0-9]*$ || ! "$poll_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "--lora-rank, --epochs and --poll-seconds must be whole numbers above zero." >&2
  exit 2
fi
if [[ -z "$base_model" ]]; then
  echo "--base-model is required." >&2
  exit 2
fi
[[ -n "$data_dir" ]] || data_dir="${out}/dataset"

read -r -a fc_words <<< "$firectl_cmd"
is_wsl=false
wsl_prefix=()
if [[ "${fc_words[0]}" == wsl ]]; then
  is_wsl=true
  for word in "${fc_words[@]}"; do
    [[ "$word" == firectl || "$word" == firectl.exe ]] && break
    wsl_prefix+=("$word")
  done
fi

py="${PYTHON:-python}"

# Converts a Git Bash path to the Windows form that Python reads.
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

# Converts a Windows path for firectl. Under WSL the path is converted with wslpath; otherwise it is passed as is.
fc_path_of() {
  if [[ "$is_wsl" == true ]]; then
    "${wsl_prefix[@]}" wslpath -a "$(native "$1")"
  else
    native "$1"
  fi
}

api_key=""
# Reads the key from Key Vault into memory only. Called once, before any firectl call, and only when executing.
load_key() {
  if [[ "$execute" == true && -n "$key_vault" && -z "$api_key" ]]; then
    api_key="$(az keyvault secret show --vault-name "$key_vault" --name fireworks-api-key --query value -o tsv | tr -d '\r')" \
      || { echo "Could not read the fireworks-api-key secret from Key Vault." >&2; exit 1; }
    if [[ -z "$api_key" ]]; then
      echo "The fireworks-api-key secret is empty." >&2
      exit 1
    fi
  fi
}

# Runs firectl with the account and, if given, the key. The key is shown as a placeholder.
fc() {
  local -a cmd=(env -u AZURE_TENANT_ID -u AZURE_MANAGED_IDENTITY_CLIENT_ID -u WANDB_API_KEY "${fc_words[@]}" -a "$account_id")
  local -a shown=("${cmd[@]}")
  if [[ -n "$key_vault" ]]; then
    cmd+=(--api-key "$api_key")
    shown+=(--api-key KEY-FROM-KEY-VAULT)
  fi
  cmd+=("$@")
  shown+=("$@")
  if [[ "$execute" == true ]]; then
    "${cmd[@]}"
  else
    show "${shown[@]}"
  fi
}

# Python helpers, run with -I so no script in the working folders is imported.
find_field_py='import json, sys
def find(node, keys):
    if isinstance(node, dict):
        for key in keys:
            value = node.get(key)
            if isinstance(value, str) and value:
                return value
        children = list(node.values())
    elif isinstance(node, list):
        children = node
    else:
        return None
    for child in children:
        found = find(child, keys)
        if found:
            return found
    return None
value = find(json.load(sys.stdin), sys.argv[1:])
if value is None:
    sys.exit(1)
print(value)'

check_dataset_py='import json, sys
path = sys.argv[1]
count = 0
with open(path, encoding="utf-8") as handle:
    for number, line in enumerate(handle, 1):
        if not line.strip():
            continue
        record = json.loads(line)
        if not isinstance(record.get("messages"), list):
            sys.exit("line %d has no messages array" % number)
        count += 1
print(count)'

sha256_py='import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
print(digest.hexdigest())'

stage_dataset() {
  local train_file="${data_dir}/train.jsonl"
  local eval_file="${data_dir}/eval.jsonl"
  local name file count
  for file in "$train_file" "$eval_file"; do
    if [[ ! -f "$file" ]]; then
      echo "Missing dataset file: ${file}. Generate it with make_dataset.py first." >&2
      exit 1
    fi
    name="$(basename "$file")"
    count="$("$py" -I -c "$check_dataset_py" "$(native "$file")")" || { echo "${name} failed the message check." >&2; exit 1; }
    if (( count < 3 || count > 3000000 )); then
      echo "${name} has ${count} lines; Fireworks accepts 3 to 3,000,000." >&2
      exit 1
    fi
    echo "${name}: ${count} lines, each with a messages array."
  done
  load_key
  fc dataset create "$dataset_id" "$(fc_path_of "$train_file")"
  fc dataset create "$eval_dataset_id" "$(fc_path_of "$eval_file")"
}

stage_train() {
  if [[ "$execute" != true ]]; then
    fc sftj create --base-model "$base_model" --dataset "$dataset_id" --evaluation-dataset "$eval_dataset_id" \
      --output-model "$output_model" --lora-rank "$lora_rank" --epochs "$epochs" -o json
    echo "Print-only: nothing started. Before --execute, set the spend quota (see usage)." >&2
    return 0
  fi
  load_key
  mkdir -p "$out"
  local job_json job_name
  job_json="$(fc sftj create --base-model "$base_model" --dataset "$dataset_id" --evaluation-dataset "$eval_dataset_id" \
    --output-model "$output_model" --lora-rank "$lora_rank" --epochs "$epochs" -o json)"
  printf '%s\n' "$job_json" > "${out}/sftj-create.json"
  if ! job_name="$(printf '%s' "$job_json" | "$py" -I -c "$find_field_py" name jobName id)"; then
    echo "The job name is not in the JSON below; the field names are [To measure]. Raw output:" >&2
    printf '%s\n' "$job_json" >&2
    exit 1
  fi
  printf '%s\n' "$job_name" > "${out}/job-name.txt"
  echo "Job started: ${job_name}"
}

stage_wait() {
  local job="$job_override"
  if [[ -z "$job" && -f "${out}/job-name.txt" ]]; then
    job="$(cat "${out}/job-name.txt")"
  fi
  if [[ -z "$job" ]]; then
    if [[ "$execute" == true ]]; then
      echo "No job name. Pass --job, or run train first." >&2
      exit 1
    fi
    job="JOB-NAME"
  fi
  if [[ "$execute" != true ]]; then
    fc sftj get "$job" -o json
    echo "Print-only: the script would poll every ${poll_seconds} seconds until one of: ${terminal_states[*]}." >&2
    return 0
  fi
  load_key
  mkdir -p "$out"
  local state_json state first=true
  while true; do
    state_json="$(fc sftj get "$job" -o json)"
    printf '%s\n' "$state_json" > "${out}/sftj-get.json"
    if ! state="$(printf '%s' "$state_json" | "$py" -I -c "$find_field_py" state)"; then
      echo "No state field in the JSON below; the field names are [To measure]. Raw output:" >&2
      printf '%s\n' "$state_json" >&2
      exit 1
    fi
    if [[ "$first" == true ]]; then
      echo "First poll, raw state JSON saved to ${out}/sftj-get.json."
      first=false
    fi
    echo "$(date -u +%H:%M:%S) ${state}"
    for terminal in "${terminal_states[@]}"; do
      if [[ "$state" == "$terminal" ]]; then
        printf '%s\n' "$state" > "${out}/job-state.txt"
        if [[ "$state" != JOB_STATE_COMPLETED ]]; then
          echo "The job ended in ${state}. Nothing to download." >&2
          exit 1
        fi
        echo "Job completed."
        return 0
      fi
    done
    sleep "$poll_seconds"
  done
}

stage_download() {
  local adapter_dir="${out}/adapter"
  if [[ "$execute" == true ]]; then
    if [[ ! -f "${out}/job-state.txt" || "$(cat "${out}/job-state.txt")" != JOB_STATE_COMPLETED ]]; then
      echo "The job has not completed in this working folder. Run wait first." >&2
      exit 1
    fi
    if [[ -d "$adapter_dir" && -n "$(ls -A "$adapter_dir" 2>/dev/null)" ]]; then
      echo "${adapter_dir} already holds files. Move them aside before downloading again." >&2
      exit 1
    fi
    mkdir -p "$adapter_dir"
    load_key
  fi
  fc model download "$output_model" "$(fc_path_of "$adapter_dir")"
}

# Local checks. Exits 1 on a missing required file; prints the adapter settings and writes the hashes.
verify_py='import hashlib, json, os, re, sys
adapter_dir, base_model, expected_rank, sha_path = sys.argv[1:5]
failures = []
def say(tag, text):
    print("%-5s %s" % (tag, text))
if not os.path.isdir(adapter_dir):
    say("FAIL", "adapter folder is missing: " + adapter_dir)
    sys.exit(1)
entries = sorted(os.listdir(adapter_dir))
folders = [e for e in entries if os.path.isdir(os.path.join(adapter_dir, e))]
files = [e for e in entries if e not in folders]
known = ("adapter_config.json", "adapter_model.safetensors", "adapter_model.bin")
if folders or [e for e in files if e not in known]:
    say("WARN", "unexpected entries: " + ", ".join(folders + [e for e in files if e not in known]))
if "adapter_config.json" not in files:
    failures.append("adapter_config.json is missing")
if not any(w in files for w in ("adapter_model.safetensors", "adapter_model.bin")):
    failures.append("neither adapter_model.safetensors nor adapter_model.bin is present")
for name in files:
    say("OK", "%s  %d bytes" % (name, os.path.getsize(os.path.join(adapter_dir, name))))
def norm(text):
    text = re.sub(r"p(\d)", r".\1", text.rsplit("/", 1)[-1]).lower()
    return re.sub(r"[^a-z0-9]", "", text)
if "adapter_config.json" in files:
    with open(os.path.join(adapter_dir, "adapter_config.json"), encoding="utf-8") as handle:
        config = json.load(handle)
    rank = config.get("r")
    say("INFO", "r=%s lora_alpha=%s" % (rank, config.get("lora_alpha")))
    say("INFO", "target_modules=%s" % json.dumps(config.get("target_modules")))
    base = config.get("base_model_name_or_path")
    say("INFO", "base_model_name_or_path=%s" % base)
    if rank is None:
        failures.append("r is missing from adapter_config.json")
    elif str(rank) != expected_rank:
        say("WARN", "r is %s; the job asked for %s" % (rank, expected_rank))
    if not base or norm(base_model) not in norm(str(base)):
        say("WARN", "base model does not match %s; compare the names by hand [To measure]" % base_model)
if failures:
    for item in failures:
        say("FAIL", item)
    sys.exit(1)
with open(sha_path, "w", encoding="utf-8") as out:
    for name in files:
        digest = hashlib.sha256()
        with open(os.path.join(adapter_dir, name), "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        out.write("%s  %s\n" % (digest.hexdigest(), name))
say("OK", "wrote " + sha_path)'

stage_verify() {
  local adapter_dir="${out}/adapter"
  if [[ "$execute" != true && ! -d "$adapter_dir" ]]; then
    echo "Print-only: ${adapter_dir} does not exist yet, so the adapter checks are skipped. Download it with --execute first." >&2
    return 0
  fi
  mkdir -p "$out"
  "$py" -I -c "$verify_py" "$(native "$adapter_dir")" "$base_model" "$lora_rank" "$(native "${out}/adapter.sha256")"
  local version_file="${out}/firectl-version.txt"
  if ! { "${fc_words[@]}" version --long; } > "$version_file" 2>&1; then
    echo "firectl version --long did not run; ${version_file} records the error." >&2
  fi
  if [[ "$is_wsl" == false ]] && fc_bin="$(command -v "${fc_words[0]}" 2>/dev/null)" && [[ -f "$fc_bin" ]]; then
    printf 'binary SHA-256  %s\n' "$("$py" -I -c "$sha256_py" "$(native "$fc_bin")")" >> "$version_file"
  fi
  echo "Recorded firectl version in ${version_file}."
}

echo "Stage ${stage}, output model ${output_model}, base model ${base_model}, rank ${lora_rank}, epochs ${epochs}."
if [[ "$execute" == true ]]; then
  echo "Executing: firectl calls will run."
else
  echo "Print-only: firectl and az calls are printed, not run. verify runs locally."
fi

case "$stage" in
  dataset) stage_dataset ;;
  train) stage_train ;;
  wait) stage_wait ;;
  download) stage_download ;;
  verify) stage_verify ;;
  all)
    stage_dataset
    stage_train
    stage_wait
    stage_download
    stage_verify
    ;;
esac
