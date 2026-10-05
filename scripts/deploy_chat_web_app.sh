#!/usr/bin/env bash
set -euo pipefail

readonly sample_commit="93dc20bd96c3f70ecc9395771fd063f50459ad6b"
readonly expected_sha256="e3e40f5b883df19bd012638139ef6ba77196b80a8af926dc873b378b5ec4389f"
readonly package_url="https://raw.githubusercontent.com/Azure-Samples/microsoft-foundry-basic/${sample_commit}/website/chatui.zip"
readonly package_path="${TMPDIR:-/tmp}/foundry-basic-chatui-${sample_commit}.zip"

if [[ ! -f "$package_path" ]]; then
  curl --fail --location --silent --show-error "$package_url" --output "$package_path"
fi

actual_sha256="$(sha256sum "$package_path" | cut -d ' ' -f 1)"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  rm -f "$package_path"
  echo "Pinned chat package checksum did not match; stopped before deployment." >&2
  exit 1
fi

resource_group="$(terraform output -raw resource_group_name)"
web_app="$(terraform output -raw web_app_name)"
az webapp deploy \
  --resource-group "$resource_group" \
  --name "$web_app" \
  --src-path "$package_path" \
  --type zip

echo "Deployed the checksum-verified sample package to ${web_app}."
