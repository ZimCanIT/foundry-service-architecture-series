#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: az-register-fireworks-pre-relase-feature.sh [subscription-id]

Checks Microsoft.CognitiveServices provider registration first, requests the
Fireworks.EnableDeploy feature registration, and reports its current state.
USAGE
}

if [[ $# -gt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0
  exit 2
fi

if [[ $# -eq 1 ]]; then
  subscription_id="$1"
else
  if ! read -r -p "Enter the subscription ID where Fireworks on Foundry should be enabled: " subscription_id; then
    printf 'Error: could not read a subscription ID.\n' >&2
    exit 2
  fi
fi

if [[ -z "$subscription_id" ]]; then
  printf 'Error: subscription ID cannot be empty.\n' >&2
  exit 2
fi

if [[ ! "$subscription_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  printf 'Error: subscription ID must be a UUID.\n' >&2
  exit 2
fi

if ! command -v az >/dev/null 2>&1; then
  printf 'Error: Azure CLI (az) is required.\n' >&2
  exit 1
fi

az account show --subscription "$subscription_id" --output none

provider_state=$(az provider show \
  --namespace Microsoft.CognitiveServices \
  --subscription "$subscription_id" \
  --query registrationState \
  --output tsv)

if [[ "$provider_state" == "Registered" || "$provider_state" == "Registering" ]]; then
  printf 'Resource provider Microsoft.CognitiveServices state is %s; skipping another registration request.\n' "$provider_state"
else
  printf 'Registering resource provider Microsoft.CognitiveServices (current state: %s)...\n' "${provider_state:-unknown}"
  az provider register \
    --namespace Microsoft.CognitiveServices \
    --subscription "$subscription_id" \
    --output none
fi

state=$(az feature registration show \
  --provider-namespace Microsoft.CognitiveServices \
  --name Fireworks.EnableDeploy \
  --subscription "$subscription_id" \
  --query 'properties.state' \
  --output tsv 2>/dev/null || true)

if [[ "$state" != "Registered" && "$state" != "Registering" ]]; then
  printf 'Registering Fireworks.EnableDeploy in subscription %s...\n' "$subscription_id"
  az feature registration create \
    --namespace Microsoft.CognitiveServices \
    --name Fireworks.EnableDeploy \
    --subscription "$subscription_id" \
    --output none
fi

state=$(az feature registration show \
  --provider-namespace Microsoft.CognitiveServices \
  --name Fireworks.EnableDeploy \
  --subscription "$subscription_id" \
  --query 'properties.state' \
  --output tsv 2>/dev/null || true)

if [[ "$state" == "Registered" ]]; then
  printf 'Fireworks.EnableDeploy is Registered in subscription %s.\n' "$subscription_id"
else
  printf 'Feature registration was requested. Current state: %s. Check again before planning the Foundry deployment.\n' "${state:-unknown}"
fi
