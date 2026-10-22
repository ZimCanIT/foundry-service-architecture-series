#!/usr/bin/env bash
set -Eeuo pipefail

# Lists the models a subscription can deploy in a region, with quota and deployable
# capacity. Read-only: it calls the model catalog, the Usages API and the Model
# Capacities API, and changes nothing in Azure.

subscription="${ARM_SUBSCRIPTION_ID:-}"
location=""
model_filter=""
provider_filter=""
kind="AIServices"
check_capacity=true
readonly api_version="2024-10-01"

usage() {
  cat <<'EOF'
List the models a subscription can deploy in a region, with quota and available capacity.

Usage:
  scripts/shared/check_foundry_model_capacity.sh --location REGION [--model TEXT] [--provider TEXT]
      [--subscription ID] [--kind KIND] [--no-capacity]

  --location      Azure region, for example swedencentral.
  --model         Case-insensitive text to match in the model name, for example deepseek or gpt-5.
  --provider      Case-insensitive text to match in the model format (the provider), for example
                  Fireworks, Anthropic, Alibaba or OpenAI. Give --model, --provider or both.
  --subscription  Subscription ID. Defaults to ARM_SUBSCRIPTION_ID, then the Azure CLI default.
  --kind          Account kind to list models for. Defaults to AIServices, which Foundry uses.
  --no-capacity   Skip the Model Capacities API, which costs one call per model version.

Columns: Provider, Model, Version, Status, Retires, Deployment type, Default and Max come from
the model catalog (az cognitiveservices model list). Quota is used/limit from the Usages API
(az cognitiveservices usage list). Available is the deployable capacity from the Model
Capacities API. Capacity units follow the deployment type, as on the Foundry quota page.

Needs az login and read access to the subscription (Cognitive Services Usages Reader covers
the quota calls). Only providers enabled on the subscription appear in the catalog.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) subscription="$2"; shift 2 ;;
    --location | -l) location="$2"; shift 2 ;;
    --model | -m) model_filter="$2"; shift 2 ;;
    --provider | -p) provider_filter="$2"; shift 2 ;;
    --kind) kind="$2"; shift 2 ;;
    --no-capacity) check_capacity=false; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$location" ]]; then
  echo "--location is required." >&2
  exit 2
fi
if [[ -z "$model_filter" && -z "$provider_filter" ]]; then
  echo "Give --model, --provider or both." >&2
  exit 2
fi
if [[ -z "$subscription" ]]; then
  subscription="$(az account show --query id -o tsv | tr -d '\r')"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
model_lc="$(lower "$model_filter")"
provider_lc="$(lower "$provider_filter")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One catalog call. Each line is one model version; its SKUs are packed as
# name:usageName:default:maximum, separated by semicolons, and unpacked below.
kind_filter="[]"
if [[ -n "$kind" ]]; then
  kind_filter="[?kind=='${kind}']"
fi
catalog_query="${kind_filter}.[model.format, model.name, model.version, to_string(model.lifecycleStatus), to_string(model.deprecation.inference), join(';', (model.skus || \`[]\`)[].join(':', [name, to_string(usageName), to_string(capacity.default), to_string(capacity.maximum)]))]"

az cognitiveservices model list --location "$location" --subscription "$subscription" \
  --query "$catalog_query" --output tsv | tr -d '\r' \
  | awk -F'\t' -v m="$model_lc" -v p="$provider_lc" \
    '(m == "" || index(tolower($2), m) > 0) && (p == "" || index(tolower($1), p) > 0)' \
  > "$tmp/models.tsv"

if [[ ! -s "$tmp/models.tsv" ]]; then
  echo "No ${kind:+${kind} }models match model~'${model_filter}' provider~'${provider_filter}' in ${location} for subscription ${subscription}." >&2
  exit 1
fi

# Quota per usage name: used and limit.
az cognitiveservices usage list --location "$location" --subscription "$subscription" \
  --query "[].[name.value, to_string(currentValue), to_string(limit)]" --output tsv | tr -d '\r' \
  > "$tmp/usages.tsv"

# Deployable capacity per model version and SKU, one call per model version.
: > "$tmp/capacity.tsv"
: > "$tmp/capacity-errors.txt"
if [[ "$check_capacity" == true ]]; then
  echo "Checking available capacity for $(wc -l < "$tmp/models.tsv" | tr -d ' ') model versions in ${location}..." >&2
  while IFS=$'\t' read -r format name version _; do
    az rest --method get \
      --url "https://management.azure.com/subscriptions/${subscription}/providers/Microsoft.CognitiveServices/modelCapacities" \
      --uri-parameters "api-version=${api_version}" "modelFormat=${format}" "modelName=${name}" "modelVersion=${version}" \
      --query "value[?location=='${location}'].[properties.skuName, to_string(properties.availableCapacity)]" --output tsv \
      2>> "$tmp/capacity-errors.txt" | tr -d '\r' \
      | awk -F'\t' -v k="${format}|${name}|${version}" 'NF { print k "|" $1 "\t" $2 }' >> "$tmp/capacity.tsv" || true
  done < "$tmp/models.tsv"
fi

value_or_dash() {
  if [[ -z "$1" || "$1" == "null" ]]; then printf '%s' "-"; else printf '%s' "$1"; fi
}

{
  printf 'Provider\tModel\tVersion\tStatus\tRetires\tDeployment type\tDefault\tMax\tQuota used/limit\tAvailable\n'
  while IFS=$'\t' read -r format name version status retires skus; do
    if [[ -z "$skus" ]]; then
      skus="-:null:null:null"
    fi
    IFS=';' read -r -a sku_list <<< "$skus"
    for sku in "${sku_list[@]}"; do
      IFS=':' read -r sku_name usage_name cap_default cap_max <<< "$sku"
      quota="$(awk -F'\t' -v k="$usage_name" \
        'function num(v) { return (v + 0 == int(v + 0)) ? int(v + 0) : v }
         $1 == k { printf "%s/%s", num($2), num($3); exit }' "$tmp/usages.tsv")"
      available="$(awk -F'\t' -v k="${format}|${name}|${version}|${sku_name}" '$1 == k { print $2; exit }' "$tmp/capacity.tsv")"
      if [[ "$check_capacity" != true ]]; then
        available="skipped"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$format" "$name" "$version" "$(value_or_dash "$status")" "$(value_or_dash "${retires:0:10}")" \
        "$sku_name" "$(value_or_dash "$cap_default")" "$(value_or_dash "$cap_max")" \
        "$(value_or_dash "$quota")" "$(value_or_dash "$available")"
    done
  done < <(sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3 "$tmp/models.tsv")
} > "$tmp/table.tsv"

echo "Subscription ${subscription}, region ${location}, kind ${kind:-any}, filters: model~'${model_filter}' provider~'${provider_filter}'"
echo
# Pad every column to its widest value so the table lines up without extra tools.
awk -F'\t' '
  { rows++; for (i = 1; i <= NF; i++) { cell[rows, i] = $i; if (length($i) > width[i]) width[i] = length($i) }; if (NF > cols) cols = NF }
  END {
    for (r = 1; r <= rows; r++) {
      line = ""
      for (i = 1; i <= cols; i++) line = line sprintf("%-" width[i] + 2 "s", cell[r, i])
      sub(/ +$/, "", line); print line
    }
  }' "$tmp/table.tsv"

if [[ -s "$tmp/capacity-errors.txt" ]]; then
  echo
  echo "Some Model Capacities calls failed; their Available column shows '-'. First error:" >&2
  head -n 1 "$tmp/capacity-errors.txt" >&2
fi
