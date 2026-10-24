#!/usr/bin/env bash
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1

# Reads what the Foundry account logged after a call: the latest RequestResponse rows from the Log
# Analytics workspace, token totals from AzureMetrics, and the ModelRequests metric split by model
# deployment. Reads the Terraform outputs of the root and the Azure CLI sign-in. Read-only: it runs
# queries and metric reads, and changes nothing in Azure. Logs arrive 3 to 10 minutes after a call,
# so run it after that wait. Working responses are kept in a temporary folder and removed on exit.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
default_root="$(cd "${script_dir}/../../.." && pwd)/environments/foundry-fireworks-byow-lora"
readonly default_root

root="$default_root"
hours="2"
rows="20"

usage() {
  cat <<'EOF'
Read the RequestResponse rows, token totals and ModelRequests metric for the Foundry account.

Usage:
  scripts/environments/foundry-fireworks-byow-lora/read_logs.sh [--root DIR] [--hours N] [--rows N]

  --root     Terraform root. Reads log_analytics_workspace_customer_id and foundry_account_id.
             Defaults to this environment's root.
  --hours    Window to read, in hours. Defaults to 2.
  --rows     Most recent RequestResponse rows to print. Defaults to 20.

Needs az login with read access to the workspace (Log Analytics Reader) and to the account
(Monitoring Reader). Logs arrive 3 to 10 minutes after a call. Nothing is written or changed.
Exit 1 if a query fails; the failure is printed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --hours) hours="$2"; shift 2 ;;
    --rows) rows="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$hours" =~ ^[1-9][0-9]*$ || ! "$rows" =~ ^[1-9][0-9]*$ ]]; then
  echo "--hours and --rows must be whole numbers above zero." >&2
  exit 2
fi

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
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

customer_id="$("$tf" -chdir="$root" output -raw log_analytics_workspace_customer_id)"
account_id="$("$tf" -chdir="$root" output -raw foundry_account_id)"
# Log Analytics stores _ResourceId in lower case.
account_lc="$(printf '%s' "$account_id" | tr '[:upper:]' '[:lower:]')"

# Window start and end, in the UTC form the metrics API takes.
window="$("$py" -I -c 'import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
start = now - datetime.timedelta(hours=int(sys.argv[1]))
print(start.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$hours")"
read -r start_time end_time <<< "$window"

# Turns the CLI's JSON (a list of rows, or a table object) into a list of dictionaries.
rows_py='import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(data, dict) and "tables" in data:
    table = data["tables"][0]
    names = [column["name"] for column in table["columns"]]
    data = [dict(zip(names, row)) for row in table["rows"]]
'

failed=false

echo "Window: last ${hours} hour(s), from ${start_time} to ${end_time} (UTC)."
echo "Logs arrive 3 to 10 minutes after a call; a call made in the last few minutes may not show yet."
echo

echo "== RequestResponse rows (latest ${rows}) =="
request_kql="AzureDiagnostics
| where TimeGenerated > ago(${hours}h)
| where Category == \"RequestResponse\" and _ResourceId == \"${account_lc}\"
| sort by TimeGenerated desc
| take ${rows}
| project TimeGenerated, OperationName, ResultSignature, DurationMs, properties_s"
if az monitor log-analytics query --workspace "$customer_id" --analytics-query "$request_kql" \
  --timespan "PT${hours}H" -o json > "$tmp/requests.json"; then
  "$py" -I -c "${rows_py}"'
if not data:
    print("No RequestResponse rows in the window. The columns are [To measure] on the first run.")
for row in data:
    props = " ".join(str(row.get("properties_s", "")).split())[:160]
    print("%s  %s  %s  %s ms  %s" % (row.get("TimeGenerated", ""), row.get("OperationName", ""),
          row.get("ResultSignature", ""), row.get("DurationMs", ""), props))' "$(native "$tmp/requests.json")"
else
  echo "The RequestResponse query failed; the first lines of the error follow." >&2
  failed=true
fi
echo

echo "== Token totals (AzureMetrics, window total) =="
tokens_kql="AzureMetrics
| where TimeGenerated > ago(${hours}h)
| where _ResourceId == \"${account_lc}\"
| where MetricName in (\"InputTokens\", \"OutputTokens\", \"TotalTokens\")
| summarize TokenTotal = sum(Total), Samples = count() by MetricName
| sort by MetricName asc"
if az monitor log-analytics query --workspace "$customer_id" --analytics-query "$tokens_kql" \
  --timespan "PT${hours}H" -o json > "$tmp/tokens.json"; then
  "$py" -I -c "${rows_py}"'
if not data:
    print("No token metrics in the window. Token metrics reach the workspace through the AllMetrics category.")
for row in data:
    print("%-16s total %s  (samples %s)" % (row.get("MetricName", ""), row.get("TokenTotal", ""), row.get("Samples", "")))' "$(native "$tmp/tokens.json")"
else
  echo "The AzureMetrics token query failed; the first lines of the error follow." >&2
  failed=true
fi
echo

echo "== ModelRequests by model deployment (metric total) =="
if az monitor metrics list --resource "$account_id" --metric ModelRequests --dimension ModelDeploymentName \
  --start-time "$start_time" --end-time "$end_time" --interval PT1H --aggregation Total -o json > "$tmp/metrics.json"; then
  "$py" -I -c 'import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
totals = {}
for metric in data.get("value", []):
    for series in metric.get("timeseries", []):
        name = "(no deployment dimension)"
        for meta in series.get("metadatavalues", []):
            if meta.get("name", {}).get("value") == "ModelDeploymentName":
                name = meta.get("value", name)
        count = sum(point.get("total") or 0 for point in series.get("data", []))
        totals[name] = totals.get(name, 0) + count
if not totals:
    print("No ModelRequests series in the window.")
for name in sorted(totals):
    print("%-40s %.0f" % (name, totals[name]))' "$(native "$tmp/metrics.json")"
else
  echo "The ModelRequests metric read failed; the first lines of the error follow." >&2
  failed=true
fi

if [[ "$failed" == true ]]; then
  exit 1
fi
