#!/usr/bin/env bash
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1

# Checks the tools, versions, sign-ins and Terraform outputs for one stage of the bring-your-own-
# weights walkthrough, and prints one table. Read-only: it runs version and status commands, reads
# Terraform outputs and hashes and reads the firectl binary. It starts no training, upload or
# deployment and changes nothing in Azure or Fireworks. Exit 1 if an item required for the chosen
# stage fails; the fix for each failing item is printed.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
default_root="$(cd "${script_dir}/../../.." && pwd)/environments/foundry-fireworks-byow-lora"
readonly default_root
readonly output_names=(
  subscription_id resource_group_name foundry_account_name foundry_account_id
  foundry_account_endpoint foundry_project_id foundry_project_name foundry_project_endpoint
  byow_deployment_names key_vault_name log_analytics_workspace_id log_analytics_workspace_customer_id
)

stage="tools"
root="$default_root"
firectl_cmd="firectl"
azcopy_path=""
show_ids=false

usage() {
  cat <<'EOF'
Check the tools, versions, sign-ins and Terraform outputs for one stage of the walkthrough.

Usage:
  scripts/environments/foundry-fireworks-byow-lora/preflight.sh [--stage STAGE] [--root DIR]
      [--firectl COMMAND] [--azcopy-path PATH] [--show-ids]

  --stage        tools, train, register, deploy or all. Defaults to tools. A failing item blocks
                 the exit code only when it is needed for the stage; every item is still shown.
  --root         Terraform root to read outputs from. Defaults to this environment's root.
  --firectl      firectl command. Defaults to firectl. For the WSL route, for example
                 "wsl -d Ubuntu-26.04 -- firectl".
  --azcopy-path  Path to the AzCopy binary, needed by the register stage.
  --show-ids     Show the subscription ID in full. By default only its last four characters show,
                 because the screen may be recorded.

Terraform is called as ${TF:-terraform}, so set TF to the signed binary if needed. Python is
called as ${PYTHON:-python}. The table is written to standard output and is safe to paste into
REHEARSAL.md. The subscription name is printed below the table, not in it, and should stay out
of tracked files.

Needs Git Bash, az sign-in (az login) and azd sign-in (azd auth login) for the register stage.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) stage="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --firectl) firectl_cmd="$2"; shift 2 ;;
    --azcopy-path) azcopy_path="$2"; shift 2 ;;
    --show-ids) show_ids=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$stage" in
  tools | train | register | deploy | all) ;;
  *) echo "--stage must be tools, train, register, deploy or all." >&2; usage >&2; exit 2 ;;
esac

tf="${TF:-terraform}"
py="${PYTHON:-python}"

# Converts a Git Bash path to the Windows form that Python reads.
native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}
read -r -a fc_words <<< "$firectl_cmd"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
probe_err="$tmp/stderr.txt"

# Runs a command, sets PROBE_RC to its exit code and PROBE_OUT to its standard output with CRs removed.
probe() {
  PROBE_RC=0
  PROBE_OUT="$("$@" 2>"$probe_err")" || PROBE_RC=$?
  PROBE_OUT="$(printf '%s' "$PROBE_OUT" | tr -d '\r')"
}

first_line() {
  printf '%s\n' "$1" | head -n 1
}

# Table rows are kept in parallel arrays and printed at the end.
rows_item=()
rows_needed=()
rows_found=()
rows_version=()
rows_status=()
rows_fix=()
failures_required=()

# add_item <item> <needed-for> <found> <version> <status ok|warn|FAIL> <fix>
add_item() {
  local required=false
  case "$stage" in
    all) required=true ;;
    tools) [[ "$2" == tools ]] && required=true ;;
    *) [[ "$2" == tools || "$2" == "$stage" ]] && required=true ;;
  esac
  rows_item+=("$1")
  rows_needed+=("$2")
  rows_found+=("$3")
  rows_version+=("$4")
  if [[ "$5" == FAIL && "$required" != true ]]; then
    rows_status+=("fail (not needed)")
  else
    rows_status+=("$5")
  fi
  rows_fix+=("$6")
  if [[ "$5" == FAIL && "$required" == true ]]; then
    failures_required+=("$1 – $6")
  fi
}

sha256_file() {
  "$py" -I -c 'import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())' "$1"
}

# Git Bash and the path switch.
case "$(uname -s)" in
  MINGW* | MSYS*)
    add_item "Git Bash (path switch)" tools yes "${MSYSTEM:-unknown}" ok \
      "Set by this script: MSYS_NO_PATHCONV=1."
    on_windows=true
    ;;
  *)
    add_item "Git Bash (path switch)" tools no "$(uname -s)" warn \
      "Run the scripts from Git Bash on Windows, so the path switch applies."
    on_windows=false
    ;;
esac

# Python 3.10 or later.
probe "$py" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3]); sys.exit(0 if sys.version_info >= (3, 10) else 1)'
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "Python 3.10 or later" tools yes "$(first_line "$PROBE_OUT")" ok ""
else
  add_item "Python 3.10 or later" tools no "-" FAIL \
    "Install Python 3.10 or later, or set PYTHON to its path. The Windows Store alias does not count."
fi

if [[ -n "${VIRTUAL_ENV:-}" ]]; then
  add_item "Active virtual environment" train yes "active" ok ""
else
  add_item "Active virtual environment" train no "-" warn \
    "Activate the virtual environment that holds the pinned requirements."
fi

# Azure CLI version and sign-in. The subscription name is kept out of the table.
probe az version -o json
if [[ $PROBE_RC -eq 0 ]]; then
  az_version="$(printf '%s' "$PROBE_OUT" | "$py" -I -c 'import json, sys; print(json.load(sys.stdin)["azure-cli"])')"
  add_item "Azure CLI" tools yes "$az_version" ok ""
else
  add_item "Azure CLI" tools no "-" FAIL "Install Azure CLI."
fi

subscription_name=""
subscription_id=""
probe az account show --query name -o tsv
if [[ $PROBE_RC -eq 0 && -n "$PROBE_OUT" ]]; then
  subscription_name="$PROBE_OUT"
  probe az account show --query id -o tsv
  subscription_id="$PROBE_OUT"
  masked="****${subscription_id: -4}"
  [[ "$show_ids" == true ]] && masked="$subscription_id"
  add_item "Azure sign-in (az account)" tools yes "$masked" ok ""
else
  add_item "Azure sign-in (az account)" tools no "-" FAIL "Run az login, then az account set to the subscription."
fi

# azd and its AI extension, needed for the upload.
probe azd version
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "azd" register yes "$(first_line "$PROBE_OUT")" ok ""
else
  add_item "azd" register no "-" FAIL "Install the Azure Developer CLI."
fi

probe azd extension list --installed
ext_line=""
if [[ $PROBE_RC -eq 0 ]]; then
  ext_line="$(printf '%s\n' "$PROBE_OUT" | grep -F 'azure.ai.models' | head -n 1 || true)"
fi
if [[ -n "$ext_line" ]]; then
  ext_version="$(printf '%s' "$ext_line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  add_item "azd extension azure.ai.models" register yes "${ext_version:-unknown}" ok ""
else
  add_item "azd extension azure.ai.models" register no "-" FAIL \
    "Run azd extension install azure.ai.models, then check the version with azd extension list --installed."
fi

probe azd auth login --check-status
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "azd sign-in (azd auth login --check-status)" register yes "signed in" ok ""
else
  add_item "azd sign-in (azd auth login --check-status)" register no "-" FAIL \
    "Run azd auth login. The upload uses the azd session, not az login. [To measure] on azd 1.36.0."
fi

if [[ -n "$azcopy_path" ]]; then
  probe "$azcopy_path" --version
  if [[ $PROBE_RC -eq 0 ]]; then
    add_item "AzCopy" register yes "$(first_line "$PROBE_OUT")" ok ""
  else
    add_item "AzCopy" register no "-" FAIL "Check the --azcopy-path value; the file did not run."
  fi
else
  add_item "AzCopy" register no "-" FAIL \
    "Pass --azcopy-path so the extension does not download AzCopy itself."
fi

# firectl: version, sign-in, binary hash and, on Windows, the Authenticode status (read, not run).
probe "${fc_words[@]}" version --long
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "firectl version" train yes "$(first_line "$PROBE_OUT")" ok ""
else
  add_item "firectl version" train no "-" FAIL \
    "Install firectl, or pass --firectl with the WSL command. Run firectl signin."
fi

probe "${fc_words[@]}" whoami
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "firectl sign-in (firectl whoami)" train yes "signed in" ok ""
else
  add_item "firectl sign-in (firectl whoami)" train no "-" FAIL "Run firectl signin."
fi

fc_path="$(command -v "${fc_words[0]}" 2>/dev/null || true)"
if [[ -n "$fc_path" && -f "$fc_path" ]]; then
  fc_hash="$(sha256_file "$(native "$fc_path")")"
  add_item "firectl binary SHA-256" train yes "${fc_hash:0:12}..." ok "Full hash printed below the table."
  fc_full_hash="$fc_hash"
  if [[ "$on_windows" == true ]]; then
    win_path="$(cygpath -w "$fc_path")"
    quoted="${win_path//\'/\'\'}"
    probe powershell.exe -NoProfile -NonInteractive -Command "(Get-AuthenticodeSignature -LiteralPath '${quoted}').Status"
    if [[ $PROBE_RC -eq 0 && "$PROBE_OUT" == Valid ]]; then
      add_item "firectl Authenticode status" train yes "$PROBE_OUT" ok ""
    else
      add_item "firectl Authenticode status" train yes "${PROBE_OUT:-unknown}" warn \
        "Not Valid. Check the publisher before training. Read with Get-AuthenticodeSignature; nothing was run."
    fi
  fi
else
  fc_full_hash=""
  add_item "firectl binary SHA-256" train no "-" FAIL "firectl is not a file on PATH; the WSL route has no local binary to hash."
fi

# Terraform and Docker (TFLint runs from the pinned container).
probe "$tf" version
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "Terraform" tools yes "$(first_line "$PROBE_OUT")" ok ""
else
  add_item "Terraform" tools no "-" FAIL "Install Terraform, or set TF to the signed binary."
fi

probe docker info --format '{{.ServerVersion}}'
if [[ $PROBE_RC -eq 0 ]]; then
  add_item "Docker (TFLint)" tools yes "$PROBE_OUT" ok ""
else
  add_item "Docker (TFLint)" tools no "-" FAIL "Start Docker Desktop. TFLint runs from its container."
fi

# Terraform outputs the scripts read. Values are checked for presence only, never printed.
outputs_found=0
for name in "${output_names[@]}"; do
  if probe "$tf" -chdir="$root" output -raw "$name" && [[ -n "$PROBE_OUT" ]]; then
    outputs_found=$((outputs_found + 1))
  fi
done
if [[ $outputs_found -eq ${#output_names[@]} ]]; then
  add_item "Terraform outputs (root)" deploy yes "${outputs_found} of ${#output_names[@]}" ok ""
else
  add_item "Terraform outputs (root)" deploy no "${outputs_found} of ${#output_names[@]}" FAIL \
    "Apply the root in your own session, then rerun. The root must have state for these outputs."
fi

# Table.
echo "Preflight for stage: ${stage}"
echo
printf '%-44s %-9s %-6s %-44s %s\n' "Item" "Needed for" "Found" "Version" "Status"
printf '%-44s %-9s %-6s %-44s %s\n' "----" "----------" "-----" "-------" "------"
for i in "${!rows_item[@]}"; do
  printf '%-44s %-9s %-6s %-44s %s\n' "${rows_item[$i]}" "${rows_needed[$i]}" "${rows_found[$i]}" \
    "${rows_version[$i]}" "${rows_status[$i]}"
done

echo
echo "Subscription (on screen only; keep it out of tracked files): ${subscription_name:-not read}"
if [[ -n "${fc_full_hash:-}" ]]; then
  echo "firectl SHA-256 (full): ${fc_full_hash}"
fi

for i in "${!rows_item[@]}"; do
  if [[ -n "${rows_fix[$i]}" && "${rows_status[$i]}" != ok ]]; then
    echo "Fix – ${rows_item[$i]}: ${rows_fix[$i]}"
  fi
done

if [[ ${#failures_required[@]} -gt 0 ]]; then
  echo
  echo "Stage ${stage} is blocked by ${#failures_required[@]} required item(s):" >&2
  for failure in "${failures_required[@]}"; do
    echo "  $failure" >&2
  done
  exit 1
fi

echo
echo "Stage ${stage}: every required item passed."
