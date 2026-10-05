#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly environment_dir="${repo_root}/environments/foundry-basic-chat"
readonly output_file="${environment_dir}/easy-auth.auto.tfvars.json"

web_app_name=""
display_name=""

usage() {
  cat <<'EOF'
Create the single-tenant Microsoft Entra application used by the Series 1 App Service Easy Auth.

Usage:
  scripts/create_easy_auth_app.sh --web-app-name NAME [--display-name NAME]

The script uses the current Azure CLI tenant. It configures the callback for
https://NAME.azurewebsites.net/.auth/login/aad/callback and writes the
client ID and generated secret to the ignored, mode-0600 file:
environments/foundry-basic-chat/easy-auth.auto.tfvars.json

An interactive user needs permission to register applications (Application Developer
is the documented role) and add a credential to an app they own. For service-principal
automation, grant Microsoft Graph Application.ReadWrite.OwnedBy with tenant admin
consent. Azure subscription Owner alone does not grant these directory permissions.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --web-app-name)
      (($# >= 2)) || fail "--web-app-name requires a value."
      web_app_name="$2"
      shift 2
      ;;
    --display-name)
      (($# >= 2)) || fail "--display-name requires a value."
      display_name="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ "$web_app_name" =~ ^[a-z0-9][a-z0-9-]{0,58}[a-z0-9]$ ]] || fail "--web-app-name must be a valid two to 60 character Azure App Service name, using lowercase letters, numbers and hyphens, with an alphanumeric first and last character."
[[ -n "$display_name" ]] || display_name="Foundry Series 1 Basic Chat ${web_app_name} Easy Auth"

command -v az >/dev/null 2>&1 || fail "Azure CLI (az) is required."
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required to write the protected Terraform variables file."
[[ -d "$environment_dir" ]] || fail "The Series 1 environment directory does not exist: $environment_dir"
[[ ! -e "$output_file" ]] || fail "Refusing to overwrite $output_file. Remove or securely archive the existing file before creating a new secret."

relative_output="${output_file#"${repo_root}/"}"
git -C "$repo_root" check-ignore --quiet -- "$relative_output" || fail "$relative_output is not protected by .gitignore; refusing to write a client secret."

tenant_id="$(az account show --query tenantId --output tsv 2>/dev/null)" || fail "Azure CLI is not authenticated. Sign in to the intended Microsoft Entra tenant first."
[[ -n "$tenant_id" && "$tenant_id" != "None" ]] || fail "Azure CLI did not return an active tenant ID."

callback_uri="https://${web_app_name}.azurewebsites.net/.auth/login/aad/callback"
if [[ "$display_name" == *$'\n'* || "$display_name" == *$'\r'* ]]; then
  fail "The display name must be a single line."
fi

odata_display_name="${display_name//\'/\'\'}"
existing_app_ids="$(az ad app list \
  --filter "displayName eq '${odata_display_name}'" \
  --query '[].appId' \
  --output tsv \
  --only-show-errors 2>/dev/null)" || fail "Could not check for an existing app registration. Check Microsoft Graph application permissions and tenant admin consent."
[[ -z "$existing_app_ids" ]] || fail "An app registration named '$display_name' already exists (application ID(s): ${existing_app_ids//$'\n'/, }). Inspect it and remove or rename it before running this create-only script again."

printf 'Creating a single-tenant Easy Auth app in tenant %s.\n' "$tenant_id"
printf 'Callback URI: %s\n' "$callback_uri"

if ! app_id="$(az ad app create \
  --display-name "$display_name" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "$callback_uri" \
  --query appId \
  --output tsv \
  --only-show-errors)"; then
  fail "App registration creation failed. For service-principal automation, grant Microsoft Graph Application.ReadWrite.OwnedBy with tenant admin consent; alternatively sign in as an allowed user with Application Developer. Subscription Owner alone is not sufficient."
fi
[[ -n "$app_id" && "$app_id" != "None" ]] || fail "Microsoft Entra did not return an application (client) ID. The app registration may have been created; inspect the tenant before retrying."

app_object_id="$(az ad app list \
  --filter "appId eq '${app_id}'" \
  --query '[0].id' \
  --output tsv \
  --only-show-errors 2>/dev/null)" || true
if [[ -z "$app_object_id" || "$app_object_id" == "None" ]]; then
  fail "The app registration $app_id was created, but could not be read back for verification. Check directory permissions before continuing."
fi

# Easy Auth's confidential-client flow requests response_type=code id_token.
# Enabling ID-token issuance is required even though a client secret is configured;
# access-token issuance remains disabled.
if ! az rest \
  --method patch \
  --url "https://graph.microsoft.com/v1.0/applications/${app_object_id}" \
  --headers 'Content-Type=application/json' \
  --body '{"web":{"implicitGrantSettings":{"enableIdTokenIssuance":true}}}' \
  --output none \
  --only-show-errors; then
  fail "The app registration $app_id was created, but ID-token issuance could not be enabled. Enable ID tokens under App registrations > Authentication > Implicit grant and hybrid flows before using Easy Auth."
fi

if ! az ad app show \
  --id "$app_object_id" \
  --query 'web.implicitGrantSettings.enableIdTokenIssuance' \
  --output tsv \
  --only-show-errors 2>/dev/null | grep -Fqx 'true'; then
  fail "The app registration $app_id was created, but ID-token issuance could not be verified. Correct the app registration before using Easy Auth."
fi

# Pipe the one-time secret directly into Python. It is never written to terminal
# output, command arguments, shell history, or a temporary file.
if ! az ad app credential reset \
  --id "$app_id" \
  --append \
  --display-name "foundry-basic-chat-easy-auth" \
  --years 1 \
  --query password \
  --output tsv \
  --only-show-errors |
  python3 -c '
import json, os, pathlib, sys

path = pathlib.Path(sys.argv[1])
client_id = sys.argv[2]
secret = sys.stdin.read().strip()
if not secret:
    print("Azure CLI returned an empty client secret; no Terraform file was written.", file=sys.stderr)
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump({"easy_auth_client_id": client_id, "easy_auth_client_secret": secret}, output, indent=2)
        output.write("\n")
except OSError as error:
    print(f"Could not safely create {path}: {error}. The generated secret was not displayed; rotate it before retrying.", file=sys.stderr)
    raise SystemExit(1)
' "$output_file" "$app_id"; then
  fail "The app registration $app_id exists, but credential creation or protected file writing failed. No secret was printed. Remove any incomplete app or rotate its credential before retrying."
fi

actual_mode="$(stat -c '%a' "$output_file" 2>/dev/null || stat -f '%Lp' "$output_file" 2>/dev/null || true)"
[[ "$actual_mode" == "600" ]] || {
  chmod 600 "$output_file"
  actual_mode="$(stat -c '%a' "$output_file" 2>/dev/null || stat -f '%Lp' "$output_file" 2>/dev/null || true)"
}
[[ "$actual_mode" == "600" ]] || fail "The Terraform variables file permissions are not 0600; secure $output_file before proceeding."

if ! az ad app show --id "$app_object_id" --query "web.redirectUris[?@ == '$callback_uri'] | [0]" --output tsv 2>/dev/null | grep -Fqx "$callback_uri"; then
  fail "The app was created, but the Easy Auth callback URI could not be verified. Do not proceed with Terraform until the registration is corrected."
fi

printf 'Created app registration: %s\n' "$app_id"
printf 'Protected Terraform inputs: %s (mode %s)\n' "$relative_output" "$actual_mode"
printf 'The secret was not displayed. Local Terraform state will also contain it after apply.\n'
