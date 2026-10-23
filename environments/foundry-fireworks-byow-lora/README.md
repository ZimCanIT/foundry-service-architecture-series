# Bring your own LoRA adapter to Fireworks on Foundry

This environment deploys a LoRA adapter that you trained on Fireworks AI and imported into Microsoft Foundry. Terraform creates a resource group, Log Analytics and Application Insights, a Foundry account and project, role assignments, a budget with an action group and, optionally, a Key Vault for the Fireworks API key. After the adapter is registered in the project, Terraform deploys it as a `FireworksCustom` model on `GlobalProvisionedManaged` capacity. The scripts in [`scripts/environments/foundry-fireworks-byow-lora`](../../scripts/environments/foundry-fireworks-byow-lora/README.md) build the dataset, train and download the adapter, upload and register it, and call the deployment keylessly.

LoRA adapter import to Fireworks on Foundry is a preview feature, offered under the [Supplemental Terms of Use for Microsoft Azure Previews](https://azure.microsoft.com/support/legal/preview-supplemental-terms/). [Learn]

> [!WARNING]
> Global Provisioned capacity bills every hour from the moment the deployment is created until it is deleted, and it cannot be paused. Stop the meter (below) as soon as the test is finished. [Learn]

## Prerequisites

- `Fireworks.EnableDeploy` is `Registered` in the subscription. This root only reads it. Apply [`foundry-fireworks-model-deployment`](../foundry-fireworks-model-deployment/README.md) once, or run `az feature registration create --namespace Microsoft.CognitiveServices --name Fireworks.EnableDeploy`. [Repo]
- Global Provisioned quota for Fireworks in the region. If the portal reports none, request it at https://aka.ms/fireworks-quota. Reading quota needs Cognitive Services Usages Reader at subscription scope, assigned outside this root. [Learn]
- The person who applies can create role assignments, for example Role Based Access Control Administrator on the resource group or above. Terraform gives that user Foundry Owner on the account. [Repo]
- A Fireworks account with a payment method and a monthly spend cap. [Research]
- Three separate sign-ins: `az login` (Terraform and the Python scripts), `azd auth login` (registration) and `firectl signin` (training). [Research]

### Tools and where to install them

The Terraform tooling is the same as the rest of the repository. The tools below are new for this environment. Keep them outside the repository, so nothing they write can be committed.

| Tool | Used for | Install to | How |
| --- | --- | --- | --- |
| `firectl` | Dataset upload, training job, adapter download | `$HOME/.local/bin/firectl.exe` on Windows (add `$HOME/.local/bin` to `PATH`), or `/usr/local/bin/firectl` inside WSL | Download from Fireworks with `curl -L -o "$HOME/.local/bin/firectl.exe" https://storage.googleapis.com/fireworks-public/firectl/stable/firectl.exe`. The Windows binary is not Authenticode-signed, so Smart App Control may block it; the WSL build is the fallback. Record `firectl version --long` and the file's SHA-256 on each run day. [Research] [To measure] |
| Azure Developer CLI (`azd`) | `azd ai models create` and `show` | The location WinGet chooses for `Microsoft.Azd` | `winget install Microsoft.Azd` [Research] |
| `azure.ai.models` azd extension | Upload and registration | azd's extension folder under `$HOME/.azd` | `azd extension install azure.ai.models`, then save `azd ai models create --help` in `REHEARSAL.md`, because the flags are not on Learn. [Research] |
| AzCopy v10 | The upload inside `azd ai models create` | `$HOME/.local/bin/azcopy.exe`, passed to the script with `--azcopy-path` | Install a known version from the Learn AzCopy page. Without `--azcopy-path` the extension downloads AzCopy itself into `$HOME/.azd/bin` with no checksum check. [Learn] [Research] |
| Python packages | The Python scripts | A virtual environment in `.venv` at the repository root (git-ignored) | `python -m venv .venv`, then `pip install -r scripts/environments/foundry-fireworks-byow-lora/requirements.txt` [Repo] |

Datasets, adapters and other working files go under `.byow-work/` (git-ignored), never into tracked folders. [Repo]

## Two phases

The project must exist before an adapter can be registered in it, and the deployment must name a registered model, so one apply cannot do both. [Learn]

| Phase | `adapters` | The plan contains | Who |
| --- | --- | --- | --- |
| 1 – base | `{}` | Resource group, monitoring, account, project, roles, budget, action group, optional Key Vault. No PTUs. | Plan, then the user applies |
| Between | – | Train on Fireworks, download, hash, `azd ai models create`, `Registered` in the portal, copy the PTU minimum and increment from the deploy dialog. | User |
| 2 – deploy | One entry | One `azapi_resource.byow_deployment[...]` to create and nothing else. Starts the meter. | Plan, the approver reads it, the user applies |
| Stop | `{}` | Only the deployments to destroy. | Plan, then the user applies |
| Teardown | – | `terraform plan -destroy`. | Plan, then the user applies |

## Configure and plan

From `environments/foundry-fireworks-byow-lora`, copy the [example variables](terraform.tfvars.example) to `terraform.tfvars`, which is git-ignored. Replace the IDs, tags, budget amount and alert address.

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init -lockfile=readonly
terraform fmt -check -recursive
terraform validate
tflint --init --config=../../.tflint.hcl
tflint --config=../../.tflint.hcl
terraform test
terraform plan -out=phase1.tfplan     # adapters = {}
```

`terraform test` runs the offline tests in `tests/` with mocked providers, so it needs no Azure sign-in. [Repo]

## The PTU gate

A phase 2 plan fails until every condition holds, because each deployment carries these preconditions [Repo]:

1. `Fireworks.EnableDeploy` is `Registered`.
2. `model_name` and `model_version` are the values the portal shows as `Registered`, not `REPLACE_` placeholders.
3. `ptu_gate.approved` is `true` and `ptu_gate.approver` names the person who read the saved plan.
4. `ptu_gate.cap` is above zero and the adapters' total capacity is within it.
5. No two entries use the same `model_name`. A project allows one active deployment per imported model. [Learn]

A `check` block warns when a capacity is not the portal minimum plus whole increments. It is a warning because the service decides, and no Learn page states the grid for a custom import. [Learn] [Plan]

The deployment depends on the budget, so the budget and its action group exist before the meter starts. Budgets are evaluated once a day and alerts can take hours, so the gate and the stop plan are the controls and the budget is the backstop. [Learn]

## Stop the meter

Set `adapters = {}`, then plan and apply. The plan must show only deployments to destroy.

```bash
terraform plan -out=stop.tfplan
```

Confirm in the portal, or with `az cognitiveservices account deployment list`, that no `FireworksCustom` deployment remains. Whether the registered model survives the deletion of its deployment is [To measure].

## Teardown

```bash
terraform plan -destroy -out=destroy.tfplan
```

Deployments are destroyed before the account, and the provider purges the soft-deleted account, because charges for deployments on a deleted account continue until it is purged. This root sets no management lock: a lock on a parent applies to its children and would block the deletion that stops the meter. [Learn]

## Security and data handling

- Foundry is keyless: local authentication is off, and callers use Entra ID tokens for `https://ai.azure.com/.default`. Inference principals get Foundry User by default, or Cognitive Services User; which one the call needs is [To measure]. [Learn]
- Fireworks on Foundry is a Microsoft meter with Fireworks as a subprocessor. Inference runs on Fireworks GPUs outside Microsoft facilities, and the service is excluded from the EU Data Boundary. Read the [privacy and compliance FAQ](https://learn.microsoft.com/azure/foundry/how-to/fireworks/privacy-compliance-faq) before using real data. [Learn]
- The Key Vault is off by default. When it is on, it uses RBAC, logs `AuditEvent` to the workspace and gives the deploying user Key Vault Secrets Officer. Terraform never creates the secret, because AzureRM keeps secret values in plain text in state; `set_fireworks_secret.py` writes it. Purge protection is off for a demo that is destroyed after each rehearsal; turn it on for anything else. [Learn] [Plan]
- The Key Vault name is `kv-<stem>-<environment>-<region_code>-<suffix>` rather than the usual naming pattern, because vault names are limited to 24 characters. [Learn]
- The datasets are synthetic. Never commit `terraform.tfvars`, plans, state, `.byow-work/`, datasets or adapter files. [Repo]

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| The plan stops with a `Fireworks.EnableDeploy` message | The feature is not `Registered`; see Prerequisites. |
| `azd ai models create` returns 403 | A missing role on the account; whether Foundry Owner covers the upload is [To measure]. |
| `azd ai models create` returns 409 | That name and version are already registered; raise `--version`. |
| The deployment fails for quota | Request Global Provisioned quota at https://aka.ms/fireworks-quota. |
| A `/subscriptions/...` argument arrives as a Windows path | Git Bash path conversion; the scripts export `MSYS_NO_PATHCONV=1`. |
