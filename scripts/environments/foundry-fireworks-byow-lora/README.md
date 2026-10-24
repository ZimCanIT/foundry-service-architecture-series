# Bring-your-own-weights LoRA scripts

Scripts that support the `environments/foundry-fireworks-byow-lora` root. They train a LoRA adapter on a hosted base model, register the adapter in Foundry, deploy it once with provisioned throughput, and call it with Entra ID. The data is synthetic: an invented insurer, Harbourline Mutual, with first-notice-of-loss (FNOL) reports that contain no real customers, people, addresses, phone numbers or email addresses.

Run every script from the repository root unless a step says otherwise. Working files go to `./.byow-work/` (ignored by Git). Nothing in this folder writes a secret to disk.

## Prerequisites

The Terraform root needs Terraform `>= 1.10.0, < 2.0.0`, the AzureRM `~> 5.8.0` and AzAPI `~> 2.13.0` providers, and an Azure CLI sign-in with a subscription that has the `Fireworks.EnableDeploy` feature registered. [Repo]

Tools on the recording machine:

| Tool | Used by | Note |
| --- | --- | --- |
| Python 3.10 or later, in a virtual environment | all Python scripts | `make_dataset.py` needs only the standard library. |
| Azure CLI (`az`) and `az login` | `preflight.sh`, `foundry_register_upload.sh`, `read_logs.sh` | |
| Azure Developer CLI (`azd`) and the `azure.ai.models` extension | `foundry_register_upload.sh`, `preflight.sh` | Sign in with `azd auth login`; the extension uses that session, not `az login`. |
| AzCopy, passed with `--azcopy-path` | `foundry_register_upload.sh` | Required, so the extension does not download it. |
| `firectl` (Fireworks CLI), signed in with `firectl signin` | `fireworks_finetune.sh`, `preflight.sh` | Runs natively or in WSL. |
| Terraform, or the signed binary named in `TF` | `set_fireworks_secret.py`, `test_keyless_call.py`, `preflight.sh` | Scripts read outputs with `"${TF:-terraform}" -chdir=<root> output -raw <name>` for strings and `output -json <name>` for the `byow_deployment_names` map and for `key_vault_name`, which is null when the Key Vault is off. |
| Bash, `curl` | the `.sh` scripts | Git Bash on Windows. Scripts set `MSYS_NO_PATHCONV=1` so Git Bash does not rewrite `/subscriptions/...` arguments. |

No `jq` or `wget` is needed. [To measure]

Install the Python pins into the virtual environment:

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/environments/foundry-fireworks-byow-lora/requirements.txt
```

[Research] The pins were checked on PyPI on 2026-10-24. Their Python bounds (3.9 or 3.10 and later) include Python 3.14. Check the pins again on the day you run the scripts. `azure-keyvault-secrets` is needed only when the Key Vault is on.

## Scripts and run order

Read each step before running it. `fireworks_finetune.sh` takes one stage word per call (`dataset`, `train`, `wait`, `download` or `verify`), or `--stage all` to run them in order. A step that spends money or changes Azure or Fireworks prints its commands and stops unless `--execute` is given. The table in the next section lists which steps those are.

| Step | Script | What it does | Changes anything? |
| --- | --- | --- | --- |
| 1 | `preflight.sh --stage tools` | Checks tools, versions, sign-ins and the firectl binary hash; prints one table. | No |
| 2 | `python make_dataset.py --self-test` | Checks determinism, vocabularies and split separation. | No |
| 3 | `python make_dataset.py` | Writes `train.jsonl`, `eval.jsonl`, `heldout.jsonl`, `ood.jsonl` and `manifest.json` to `./.byow-work/dataset`. | Local files only |
| 4 | `preflight.sh --stage train` | Confirms the training prerequisites are present. | No |
| 5 | `set_fireworks_secret.py` | Only when the root's Key Vault is on and you train with `--key-from-keyvault`, which needs the secret to exist. Prints the plan; with `--execute`, prompts for the Fireworks key and writes the Key Vault secret. | Azure secret |
| 6 | `fireworks_finetune.sh --stage dataset` | Prints the dataset upload command. Add `--execute` to upload the dataset. | Fireworks storage |
| 7 | `fireworks_finetune.sh --stage train` | Prints the training command. Add `--execute` to start the job. | Fireworks credit |
| 8 | `fireworks_finetune.sh --stage wait` | Polls the job until it finishes. | Read-only on Fireworks |
| 9 | `fireworks_finetune.sh --stage download` | Downloads the adapter. | Local downloads |
| 10 | `fireworks_finetune.sh --stage verify` | Checks the adapter files and writes `adapter.sha256`. | Local files only |
| 11 | `foundry_register_upload.sh` | Re-hashes the adapter, prints the upload command beside the one the portal generates. Add `--execute` to upload and register it. | Azure upload and registration |
| 12 | `preflight.sh --stage deploy` | Checks that the root's outputs exist before a deployment call. | No |
| 13 | `test_keyless_call.py --wait-ready 15` | One keyless call to the deployment, with a held-out report; checks the four labels. | Calls the deployment |
| 14 | `read_logs.sh` | Reads request rows and token metrics after 3 to 10 minutes. | No |

The root's own steps (plan phase 1, save and apply phase 2, stop the meter, teardown) are in the root's README, not here.

### What each script does

**`preflight.sh`** takes `--stage tools|train|register|deploy|all` and exits 1 when a required item for the stage fails, printing the fix. It masks subscription and tenant IDs unless `--show-ids` is given, because the screen may be recorded. It checks the Python version, `az version`, `azd version`, the `azure.ai.models` extension, `azd auth login --check-status`, the AzCopy version, `firectl version --long`, `firectl whoami`, the firectl SHA-256 and its Authenticode status (read, not run), `terraform version` and `docker info`. [To measure] for the azd status check.

**`make_dataset.py`** generates the synthetic dataset. It is deterministic: the same `--seed` gives identical JSONL bytes. `manifest.json` records the generator version, seed, counts, label distribution per split, SHA-256 per file and creation time, so it differs between runs only in that time. It also prints an estimate of training tokens (characters divided by four, labelled as an estimate). Held-out reports use phrasings the training split never contains, so a held-out score measures generalisation rather than memory. Defaults are 2000 training, 200 evaluation, 200 held-out and 40 out-of-domain records. The four labels (`claim_type`, `severity`, `fraud_flag`, `next_action`) follow fixed rules that are set out in the script's docstring and in `manifest.json`, so an exact-match score is meaningful. [Plan]

**`fireworks_finetune.sh`** runs the Fireworks steps `dataset`, `train`, `wait`, `download` and `verify`. Without `--execute` it prints the `firectl` commands and stops. It checks dataset and model IDs against the Fireworks naming rules before any call. It passes `--lora-rank 16` explicitly, because firectl defaults to 8 and an omitted rank means full-parameter training in the API. It can read the key from Key Vault with `--key-from-keyvault`, and then passes it as an argument, which firectl offers no other way to receive. [Research: https://docs.fireworks.ai/fine-tuning/fine-tuning-models] [Research: firectl command reference]

Before training, set a monthly spend limit on the Fireworks account: `firectl quota update monthly-spend-usd --value <amount>`. [Research: https://docs.fireworks.ai/guides/quotas_usage/account-quotas]

**`verify`** in `fireworks_finetune.sh` checks that `adapter_config.json` and either `adapter_model.safetensors` or `adapter_model.bin` exist, because Foundry requires both. It prints `r`, `lora_alpha`, `target_modules` and `base_model_name_or_path`, and checks that the base model is the one trained on. [Learn: required model files] [To measure] for the JSON field names of `firectl ... -o json`.

**`foundry_register_upload.sh`** re-hashes the adapter directory and compares it with `adapter.sha256`, checks the project endpoint against the root's output, then runs `azd ai models create` with `--weight-type LoRA`. By default it sends no `--lora-*` flags and prints `r` and `lora_alpha` from the adapter's `adapter_config.json`; the service deriving rank, alpha and target modules from that file is [To measure]. Learn says the portal's generated command carries rank and alpha for LoRA, so compare it with the command this script prints and match it: pass `--lora-rank` and `--lora-alpha`, or `--lora-from-config` to send the values read from `adapter_config.json`. [Learn: https://learn.microsoft.com/azure/foundry/how-to/fireworks/import-custom-models#import-a-custom-model] The base model string comes from the portal's **Generate upload command** (`--base-model` has no default), and the script shows that command beside its own for comparison. After the upload it reads the registration back and re-hashes the directory. A 409 means the name and version exist, so bump `--version`; a 403 means a missing role. [Learn: import custom models] [Research: extension source]

**`set_fireworks_secret.py`** writes the key as the secret `fireworks-api-key`. It reads the vault name from the root's `key_vault_name` output, or from `--vault-name`. Without `--execute` it prints the plan only. With `--execute` it prompts with a hidden prompt, writes the secret with the Key Vault SDK, and prints only the secret identifier. It retries a 403 for up to five minutes, because the role assignment takes time to apply. The script is not `az keyvault secret set`, which would put the key in the argument list. [Learn: https://learn.microsoft.com/cli/azure/keyvault/secret] [Learn: Key Vault RBAC guide]

**`test_keyless_call.py`** calls the deployment with Entra ID and the scope `https://ai.azure.com/.default`. It uses Chat Completions and then Responses with `store=false`, both on `https://<account>.services.ai.azure.com/openai/v1/`. It prints the route, request ID, client latency, usage, the token's `idtyp` claim and a shortened object ID, and whether each of the four labels is in its vocabulary and matches the reference answer. `--wait-ready MINUTES` retries 401, 403, 404, 429 and 503 with backoff, because role assignments and new deployments take minutes. `--skip-responses` covers a deployment where the Responses route is not available. [To measure]

The keyless claim covers only the routes this script calls. It does not call the Fireworks passthrough route.

**`read_logs.sh`** runs two `az monitor log-analytics query` calls, for `RequestResponse` rows in `AzureDiagnostics` and token metrics in `AzureMetrics`, then `az monitor metrics list` for `ModelRequests` split by `ModelDeploymentName`. It is read-only. Logs arrive 3 to 10 minutes after a call. [Learn: https://learn.microsoft.com/azure/foundry/foundry-models/how-to/monitor-models]

## Steps that spend money or change Azure

| Step | Spends or changes | Stops unless |
| --- | --- | --- |
| `fireworks_finetune.sh --stage train` | Fireworks training, billed on training tokens (dataset tokens times epochs). [Research: https://fireworks.ai/pricing#training-pricing] The estimate printed by `make_dataset.py` is characters divided by four; compare it with the live price list on the day. [To measure] | `--execute` |
| `foundry_register_upload.sh` | Azure storage upload and a model registration in the project. Whether either has a charge is [To measure]. | `--execute` |
| `set_fireworks_secret.py` | Writes one Key Vault secret. | `--execute` |
| `test_keyless_call.py` | Calls a provisioned deployment. The deployment is billed by the hour from creation until it is deleted, not per token, so a call adds no per-token charge. [Learn: https://learn.microsoft.com/azure/foundry/openai/concepts/provisioned-throughput-billing#hourly-billing] | Runs when invoked |

The deployment is created by the root, not by these scripts. Its hourly meter runs until the deployment is deleted, so run the stop plan in the root's README as soon as the calls are done.

## Keyless access and the key

The Fireworks API key is needed only in two places: `fireworks_finetune.sh` when training (from the signed-in firectl session, or from Key Vault with `--key-from-keyvault`), and `set_fireworks_secret.py` when writing the vault. No script prints the key or writes it to a file in this folder. Calls to the Foundry deployment use Entra ID only.

## Pins

| Package | Pin | Where it came from |
| --- | --- | --- |
| `azure-identity` | 1.26.0 | Same pin as the earlier Fireworks model deployment script; checked on PyPI 2026-10-24. [Research: PyPI JSON API] |
| `openai` | 3.37.0 | Same pin as the earlier Fireworks model deployment script; checked on PyPI 2026-10-24, released 2026-10-22. [Research: PyPI JSON API] |
| `azure-keyvault-secrets` | 4.11.3 | Latest on PyPI 2026-10-24, released 2026-10-02, requires Python 3.9 or later. [Research: PyPI JSON API] |

Not used: `fireworks-ai`. firectl trains and downloads, the SDK has no polling helper for these jobs, and its download returns signed URLs rather than files. The `[training]` extra needs Python 3.11 or later and pulls in `torch`.

## Checks

```bash
python -m py_compile scripts/environments/foundry-fireworks-byow-lora/make_dataset.py
python -m py_compile scripts/environments/foundry-fireworks-byow-lora/set_fireworks_secret.py
python -m py_compile scripts/environments/foundry-fireworks-byow-lora/test_keyless_call.py
python scripts/environments/foundry-fireworks-byow-lora/make_dataset.py --self-test
python scripts/environments/foundry-fireworks-byow-lora/make_dataset.py --help
```

Run `pre-commit run --all-files` from the repository root before committing.

## Data

Synthetic only. Harbourline Mutual is invented. Policy references (`HLM-000000` pattern), crime references, dates, amounts and towns are random or invented. The vocabularies for `claim_type`, `severity`, `fraud_flag` and `next_action` are constants in `make_dataset.py` and are written into `manifest.json`, so an evaluation can score exact matches per field. Generated data stays in `./.byow-work/` and is never committed.
