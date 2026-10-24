#!/usr/bin/env bash
# Stop under sh before any bash-only syntax is read: dash has no BASH_VERSION, and
# sh in Git Bash is bash in POSIX mode.
case ":${SHELLOPTS:-}:" in
  *:posix:*) not_bash=true ;;
  *) [ -n "${BASH_VERSION:-}" ] && not_bash=false || not_bash=true ;;
esac
if [ "$not_bash" = true ]; then
  echo "This script needs bash. Run it as: bash $0 --help" >&2
  exit 2
fi
set -Eeuo pipefail

# Lists the models a subscription can deploy in a region, with quota and deployable
# capacity. Read-only: it calls the model catalogue, the Usages API and the Model
# Capacities API, and changes nothing in Azure.

subscription="${ARM_SUBSCRIPTION_ID:-}"
location=""
model_filter=""
provider_filter=""
kind="AIServices"
check_capacity=true
readonly api_version="2024-10-01"
readonly max_pages=100

usage() {
  cat <<'EOF'
List the models a subscription can deploy in a region, with quota and available capacity.

Usage:
  scripts/shared/check_foundry_model_capacity.sh --location REGION [--model TEXT] [--provider TEXT]
      [--subscription ID_OR_NAME] [--kind KIND] [--no-capacity]
  scripts/shared/check_foundry_model_capacity.sh --help

  -l, --location  Azure region name, for example swedencentral.
  -m, --model     Case-insensitive text to match in the model name, for example deepseek or gpt-5.
  -p, --provider  Case-insensitive text to match in the model format (the provider), for example
                  Fireworks, Anthropic, Alibaba or OpenAI. Give --model, --provider or both.
  --subscription  Subscription ID or name. Defaults to ARM_SUBSCRIPTION_ID, then the Azure CLI
                  default. Every subscription-scoped call uses the ID it resolves to.
  --kind          Account kind to list models for. Defaults to AIServices, which Foundry uses.
                  Give any to list every kind.
  --no-capacity   Skip the Model Capacities API, which costs one call per model version.
  -h, --help      Show this help.

Option values cannot start with a hyphen.

Columns: Provider, Model, Version, Status, Retires, Deployment type, Default and Max come from
the model catalogue (az cognitiveservices model list). Quota is used/limit from the Usages API
(az cognitiveservices usage list). Available is the deployable capacity from the Model
Capacities API, read across every page of its reply. Capacity units follow the deployment type,
as on the Foundry quota page.

A cell that holds no number says why:
  -              Nothing to look up: the catalogue gives no value, usage name or SKU.
  ?              Azure returned a value that is not a number in Default, Max or either side
                 of Quota.
  skipped        --no-capacity was given.
  no-record      The calls succeeded but returned no record for this row.
  missing-value  A capacity record exists but holds no number.
  conflict       Azure returned two records for this row that disagree.
  invalid-id     The model format, name or version is empty or not a valid identifier, so no
                 capacity request was sent.
  unauthorised, throttled, error
                 The call failed; stderr names the operation, the model and the first error.

Exit codes:
  0  Complete listing (skipped capacity checks count as complete).
  1  No models match the filters.
  2  Invalid arguments, or not run with bash.
  3  Incomplete listing: at least one cell holds ?, missing-value, conflict, invalid-id or a
     failure state.
  4  Missing prerequisite, unknown subscription, or the model catalogue could not be read.

Needs bash, az login and read access to the subscription (Cognitive Services Usages Reader
covers the quota calls). Only providers enabled on the subscription appear in the catalogue.
EOF
}

need_value() {
  if [[ "$2" -lt 2 || -z "$3" || "$3" == -* ]]; then
    echo "$1 needs a value. Run with --help for usage." >&2
    exit 2
  fi
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) need_value "$1" $# "${2-}"; subscription="$2"; shift 2 ;;
    --location | -l) need_value "$1" $# "${2-}"; location="$2"; shift 2 ;;
    --model | -m) need_value "$1" $# "${2-}"; model_filter="$2"; shift 2 ;;
    --provider | -p) need_value "$1" $# "${2-}"; provider_filter="$2"; shift 2 ;;
    --kind) need_value "$1" $# "${2-}"; kind="$2"; shift 2 ;;
    --no-capacity) check_capacity=false; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$location" ]]; then
  echo "--location is required." >&2
  exit 2
fi
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
location="$(lower "$location")"
if [[ ! "$location" =~ ^[a-z0-9]+$ ]]; then
  echo "--location must be a region name such as swedencentral, not a display name." >&2
  exit 2
fi
if [[ -z "$model_filter" && -z "$provider_filter" ]]; then
  echo "Give --model, --provider or both." >&2
  exit 2
fi
if [[ "$kind" == any ]]; then
  kind=""
elif [[ ! "$kind" =~ ^[A-Za-z0-9.]+$ ]]; then
  echo "--kind must be an account kind such as AIServices, or any." >&2
  exit 2
fi
if ! command -v az > /dev/null 2>&1; then
  echo "The Azure CLI (az) is not on PATH." >&2
  exit 4
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/errors.txt"

# First line of the CLI's stderr that is not a warning.
first_error() {
  awk 'NF && !/^WARNING/ { print; exit }' "$1" | tr -d '\r'
}

# Name the failure from the CLI's error code or reason phrase, never from a bare number
# that could sit inside a request ID; anything unrecognised is an error.
classify() {
  if grep -Eqi 'AuthorizationFailed|InvalidAuthenticationToken|^ERROR: *(Forbidden|Unauthorized)\(|"code": *"(Forbidden|Unauthorized)"' "$1"; then
    echo unauthorised
  elif grep -Eqi 'TooManyRequests|Too Many Requests|RateLimit|Throttl' "$1"; then
    echo throttled
  else
    echo error
  fi
}

record_error() {
  printf '%s for %s: %s\n' "$1" "$2" "${3:-no error text from the Azure CLI}" >> "$tmp/errors.txt"
}

if [[ -n "$subscription" ]]; then
  account_ok=true
  subscription_id="$(az account show --subscription "$subscription" --query id --output tsv \
    2> "$tmp/account.err" | tr -d '\r')" || account_ok=false
else
  account_ok=true
  subscription_id="$(az account show --query id --output tsv 2> "$tmp/account.err" | tr -d '\r')" \
    || account_ok=false
fi
if [[ "$account_ok" != true || -z "$subscription_id" ]]; then
  echo "Could not resolve the subscription${subscription:+ '${subscription}'}: $(first_error "$tmp/account.err")" >&2
  exit 4
fi

# One catalogue call. Each line is one model version. Every field goes through to_string so
# null arrives as the text null, never as an empty field. SKUs are packed with the ASCII
# record separator between SKUs and the unit separator between their fields.
kind_filter="[]"
if [[ -n "$kind" ]]; then
  kind_filter="[?kind=='${kind}']"
fi
sku_query='join(`"\u001e"`, (model.skus || `[]`)[].join(`"\u001f"`, [to_string(name), to_string(usageName), to_string(capacity.default), to_string(capacity.maximum)]))'
catalog_query="${kind_filter}.[to_string(model.format), to_string(model.name), to_string(model.version), to_string(model.lifecycleStatus), to_string(model.deprecation.inference), ${sku_query}]"

if ! az cognitiveservices model list --location "$location" --subscription "$subscription_id" \
  --query "$catalog_query" --output tsv > "$tmp/catalog.raw" 2> "$tmp/catalog.err"; then
  echo "Could not read the model catalogue for ${location}: $(first_error "$tmp/catalog.err")" >&2
  exit 4
fi
# Filters reach awk through the environment, so their text is matched literally.
tr -d '\r' < "$tmp/catalog.raw" \
  | MODEL_FILTER="$model_filter" PROVIDER_FILTER="$provider_filter" awk -F'\t' '
      BEGIN { m = tolower(ENVIRON["MODEL_FILTER"]); p = tolower(ENVIRON["PROVIDER_FILTER"]) }
      (m == "" || index(tolower($2), m) > 0) && (p == "" || index(tolower($1), p) > 0) && !seen[$0]++' \
  | sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3 > "$tmp/models.tsv"

if [[ ! -s "$tmp/models.tsv" ]]; then
  echo "No ${kind:+${kind} }models match model~'${model_filter}' provider~'${provider_filter}' in ${location} for subscription ${subscription_id}." >&2
  exit 1
fi

# Quota per usage name: used and limit. A failure marks the Quota column, not the run.
usage_state=ok
if az cognitiveservices usage list --location "$location" --subscription "$subscription_id" \
  --query "[].[to_string(name.value), to_string(currentValue), to_string(limit)]" --output tsv \
  > "$tmp/usages.raw" 2> "$tmp/usages.err"; then
  tr -d '\r' < "$tmp/usages.raw" > "$tmp/usages.tsv"
else
  usage_state="$(classify "$tmp/usages.err")"
  record_error "Usages" "region ${location}" "$(first_error "$tmp/usages.err")"
  : > "$tmp/usages.tsv"
fi

# Deployable capacity per model version and SKU, following every page of each reply.
# capacity.tsv holds the records for the region; capacity-state.tsv holds one state per
# model version: ok, invalid-id, or the failure that stopped its pages.
: > "$tmp/capacity.tsv"
: > "$tmp/capacity-state.tsv"
if [[ "$check_capacity" == true ]]; then
  if ! arm="$(az cloud show --query endpoints.resourceManager --output tsv 2> "$tmp/cloud.err" | tr -d '\r')" \
    || [[ "$arm" != https://* ]]; then
    echo "Could not read the resource-manager endpoint of the current cloud: $(first_error "$tmp/cloud.err")" >&2
    exit 4
  fi
  arm="${arm%/}/"
  capacity_query='[[[`"next"`, to_string(nextLink)]], (value || `[]`)[].[`"row"`, to_string(location), to_string(properties.skuName), to_string(properties.availableCapacity)]][]'
  # The pattern the Model Capacities API documents for modelFormat, modelName and modelVersion.
  id_pattern='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

  # One line per model version that has SKUs to look up, fields split by the unit separator
  # so an empty one stays put.
  awk -F'\t' '$6 != "" && !seen[$1 FS $2 FS $3]++ { print $1 "\037" $2 "\037" $3 }' "$tmp/models.tsv" > "$tmp/versions.txt"
  echo "Checking available capacity for $(wc -l < "$tmp/versions.txt" | tr -d ' ') model versions in ${location}..." >&2

  while IFS=$'\037' read -r format name version; do
    subject="${format} ${name} version ${version:-(empty)}"
    state=ok
    for field in "$format" "$name" "$version"; do
      if [[ "$field" == null || ! "$field" =~ $id_pattern ]]; then
        state=invalid-id
      fi
    done
    if [[ "$state" == invalid-id ]]; then
      record_error "Model Capacities" "$subject" "not requested: the format, name or version is empty or not a valid identifier"
    else
      url="${arm}subscriptions/${subscription_id}/providers/Microsoft.CognitiveServices/modelCapacities"
      params=(--uri-parameters "api-version=${api_version}" "modelFormat=${format}" "modelName=${name}" "modelVersion=${version}")
      seen_links=$'\n'
      page=1
      while :; do
        if ! az rest --method get --url "$url" ${params[@]+"${params[@]}"} --subscription "$subscription_id" \
          --query "$capacity_query" --output tsv < /dev/null > "$tmp/page.raw" 2> "$tmp/page.err"; then
          state="$(classify "$tmp/page.err")"
          record_error "Model Capacities (page ${page})" "$subject" "$(first_error "$tmp/page.err")"
          break
        fi
        tr -d '\r' < "$tmp/page.raw" > "$tmp/page.tsv"
        # Keep the records for the region; Azure may return it as WestUS or West US.
        awk -F'\t' -v OFS='\t' -v f="$format" -v n="$name" -v v="$version" -v want="$location" '
          $1 == "row" { loc = tolower($2); gsub(/ /, "", loc); if (loc == want) print f, n, v, $3, $4 }' \
          "$tmp/page.tsv" >> "$tmp/capacity.tsv"
        next_link="$(awk -F'\t' '$1 == "next" { print $2; exit }' "$tmp/page.tsv")"
        if [[ -z "$next_link" || "$next_link" == null ]]; then
          break
        fi
        if [[ "$(lower "$next_link")" != "$(lower "$arm")"* ]]; then
          state=error
          record_error "Model Capacities (page ${page})" "$subject" "next page link is not on ${arm}; stopped"
          break
        fi
        case "$seen_links" in
          *$'\n'"$next_link"$'\n'*)
            state=error
            record_error "Model Capacities (page ${page})" "$subject" "next page link repeats an earlier one; stopped"
            break ;;
        esac
        if [[ "$page" -ge "$max_pages" ]]; then
          state=error
          record_error "Model Capacities" "$subject" "more than ${max_pages} pages; stopped"
          break
        fi
        seen_links="${seen_links}${next_link}"$'\n'
        url="$next_link"
        params=()
        page=$((page + 1))
      done
    fi
    printf '%s\t%s\t%s\t%s\n' "$format" "$name" "$version" "$state" >> "$tmp/capacity-state.tsv"
  done < "$tmp/versions.txt"
fi

# Join catalogue, quota and capacity in one pass. Exit status 3 means a cell is incomplete.
printf 'Provider\tModel\tVersion\tStatus\tRetires\tDeployment type\tDefault\tMax\tQuota used/limit\tAvailable\n' > "$tmp/table.tsv"
join_status=0
CHECK_CAPACITY="$check_capacity" USAGE_STATE="$usage_state" awk -F'\t' -v OFS='\t' '
  # Integral numbers print without a decimal part; anything not a number is unknown.
  function num(v) {
    if (v ~ /^-?[0-9]+(\.0+)?$/) { sub(/\.0+$/, "", v); return v }
    if (v ~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) return v
    return "?"
  }
  function dash(v) { return (v == "" || v == "null") ? "-" : v }
  function keep(map, k, v) { map[k] = ((k in map) && map[k] != v) ? "conflict" : v }
  BEGIN { check = ENVIRON["CHECK_CAPACITY"]; ustate = ENVIRON["USAGE_STATE"]; incomplete = 0 }
  FILENAME == ARGV[1] { keep(quota, $1, num($2) "/" num($3)); next }
  FILENAME == ARGV[2] {
    a = num($5); if (a == "?") a = "missing-value"
    keep(avail, $1 SUBSEP $2 SUBSEP $3 SUBSEP $4, a); next
  }
  FILENAME == ARGV[3] { cstate[$1 SUBSEP $2 SUBSEP $3] = $4; next }
  {
    fmt = $1; name = $2; ver = $3
    n = ($6 == "") ? 0 : split($6, skus, "\036")
    for (i = 1; i <= (n ? n : 1); i++) {
      if (n) { split(skus[i], f, "\037"); sku = f[1]; un = f[2]; def = f[3]; max = f[4] }
      else { sku = "-"; un = "null"; def = "null"; max = "null" }

      if (dash(un) == "-") q = "-"
      else if (ustate != "ok") q = ustate
      else if (un in quota) q = quota[un]
      else q = "no-record"

      st = cstate[fmt SUBSEP name SUBSEP ver]
      k = fmt SUBSEP name SUBSEP ver SUBSEP sku
      if (!n) a = "-"
      else if (check != "true") a = "skipped"
      else if (st == "invalid-id") a = "invalid-id"
      else if (k in avail) a = avail[k]
      else if (st == "ok") a = "no-record"
      else a = st

      if (!(q == "-" || q == "no-record" || (q ~ /\// && q !~ /\?/))) incomplete = 1
      if (!(a == "-" || a == "skipped" || a == "no-record" || num(a) != "?")) incomplete = 1
      d = (dash(def) == "-") ? "-" : num(def)
      m = (dash(max) == "-") ? "-" : num(max)
      if (d == "?" || m == "?") incomplete = 1

      row = fmt OFS name OFS dash(ver) OFS dash($4) OFS dash(substr($5, 1, 10)) OFS sku OFS \
        d OFS m OFS q OFS a
      if (!printed[row]++) print row
    }
  }
  END { exit incomplete ? 3 : 0 }' \
  "$tmp/usages.tsv" "$tmp/capacity.tsv" "$tmp/capacity-state.tsv" "$tmp/models.tsv" \
  >> "$tmp/table.tsv" || join_status=$?
if [[ "$join_status" -ne 0 && "$join_status" -ne 3 ]]; then
  echo "Could not join the catalogue, quota and capacity results (awk exit ${join_status})." >&2
  exit 4
fi

echo "Subscription ${subscription_id}, region ${location}, kind ${kind:-any}, filters: model~'${model_filter}' provider~'${provider_filter}'"
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

if [[ "$join_status" -eq 3 || -s "$tmp/errors.txt" ]]; then
  {
    echo
    echo "Incomplete listing: some cells hold a state instead of a number (see --help)."
    if [[ -s "$tmp/errors.txt" ]]; then
      echo "Problems:"
      sed 's/^/  /' "$tmp/errors.txt"
    fi
  } >&2
  exit 3
fi
