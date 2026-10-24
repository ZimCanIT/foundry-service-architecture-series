# Foundry Service Architecture Series

[![Checks](https://github.com/ZimCanIT/foundry-service-architecture-series/actions/workflows/checks.yml/badge.svg?branch=main)](https://github.com/ZimCanIT/foundry-service-architecture-series/actions/workflows/checks.yml)

Terraform reference deployments for Microsoft Foundry on Azure, written as the code companion to the ZimCanIT YouTube series on Foundry and on Fireworks AI models in Foundry. Each environment is a self-contained Terraform root that you can plan, deploy and remove in your own subscription, built from a small set of shared modules. The repository is for cloud and platform engineers who want a working, keyless starting point for a Foundry architecture and a clear record of the trade-offs it makes. The environments are proofs of concept: each README lists what you would need to change, such as public endpoints or single-region capacity, before production use.

## Environments

Each environment has its own README with prerequisites, inputs, deployment steps and clean-up. The [environments overview](environments/README.md) has more detail.

| Environment | What it deploys | Status |
| --- | --- | --- |
| [foundry-basic-chat](environments/foundry-basic-chat/README.md) | Foundry account and project with a GPT-4.1 deployment, Azure AI Search, Bing grounding, Azure Monitor and an App Service chat UI behind Easy Auth. Helper scripts create the search index and a prompt agent. | Available |
| [foundry-fireworks-model-deployment](environments/foundry-fireworks-model-deployment/README.md) | Registers the `Microsoft.CognitiveServices` provider and the `Fireworks.EnableDeploy` feature on the subscription, then deploys a Fireworks AI catalogue model (DeepSeek V4.1 Flash in the example) to a Foundry account and project on Global Standard. | Available |
| [foundry-fireworks-byow-lora](environments/foundry-fireworks-byow-lora/README.md) | Bring-your-own-weights: a LoRA adapter trained on Fireworks, registered in a Foundry project and deployed as `FireworksCustom` on Global Provisioned capacity. Two-phase apply – phase 1 creates the account, project, monitoring and a resource group budget; phase 2 adds the deployment behind a PTU approval gate. Optional Key Vault for the Fireworks API key. | Preview |
| `foundry-agent-service` | Reserved for a later architecture stage. | No deployment yet |

## Shared modules

The environments compose these modules from `modules/`. The [module catalogue](modules/README.md) describes their boundaries and design choices.

| Module | What it provides | Used by |
| --- | --- | --- |
| [foundry](modules/foundry/README.md) | Foundry account with an optional project and model deployment, diagnostics, network rules, managed identities, role assignments, a `security_profile` with plan-time checks, an optional management lock and optional project connections. Has mocked `terraform test` coverage. | All environments |
| [azure-monitor](modules/azure-monitor) | Log Analytics workspace and Application Insights, keyless by default, with optional retention, quota, per-table retention, role assignments and a management lock. | All environments |
| [azure-ai-search](modules/azure-ai-search) | Azure AI Search service, diagnostics and deployment-principal access for index bootstrap. | foundry-basic-chat |
| [bing-grounding](modules/bing-grounding) | Bing Grounding resource and sensitive key retrieval. | foundry-basic-chat |
| [web-app](modules/web-app) | Linux web app configuration and diagnostics, on a dedicated App Service plan (through the Azure Verified Module) or an existing shared plan. | foundry-basic-chat |

## Repository layout

```text
.
├── environments/            Independent Terraform roots, each with local state and a committed lock file
├── modules/                 Shared modules; they declare minimum provider versions, the roots pin them
├── scripts/
│   ├── environments/<env>/  Helpers for one environment, such as agent bootstrap or dataset generation
│   ├── case-studies/<slug>/ Helpers for one case study
│   └── shared/              Model capacity check, pre-commit hooks, module test runner, container wrapper
├── case-studies/            End-to-end write-ups that compose environments (none published yet)
├── .github/workflows/       The Checks workflow
├── .pre-commit-config.yaml  Local hooks for file hygiene, Terraform and TFLint
├── .tflint.hcl              Shared TFLint configuration
├── .commitlintrc.yml        Commit message rules
└── CONTRIBUTING.md          Development checks and CI reference
```

## Prerequisites

| Requirement | Version or detail | Where it is set |
| --- | --- | --- |
| Terraform | `>= 1.10.0, < 2.0.0` | `required_version` in each root and module |
| AzureRM provider | `~> 5.8.0` | Each root's `versions.tf` and lock file |
| AzAPI provider | `~> 2.13.0` | Each root's `versions.tf` and lock file |
| Random provider | `~> 3.9.0` (Fireworks roots), `~> 3.5` (basic chat) | Each root's `versions.tf` |
| Azure CLI | Signed in with `az login`; the providers use CLI authentication | Each root's provider block |
| Azure subscription | Permission to create resource groups and role assignments; some roots also register providers and features | Each environment README |
| Python | 3.10 or later, for the helper scripts and pre-commit | `scripts/` |
| TFLint | 0.64.0 with the AzureRM ruleset 0.32.0 | [CONTRIBUTING.md](CONTRIBUTING.md) |

`terraform init` fails on provider versions outside the pinned ranges. Check model availability, quota and capacity for your region before you plan; `scripts/shared/check_foundry_model_capacity.sh` reports them without changing anything in Azure.

## Quick start

1. Clone the repository and sign in to Azure:

   ```bash
   git clone https://github.com/ZimCanIT/foundry-service-architecture-series.git
   cd foundry-service-architecture-series
   az login
   az account set --subscription "<subscription-id>"
   export ARM_SUBSCRIPTION_ID="<subscription-id>"
   ```

2. Pick an environment and read its README first. Some need extra steps, such as a deployment service principal and an Easy Auth app for `foundry-basic-chat`, or a registered adapter and PTU approval for `foundry-fireworks-byow-lora`.

3. Copy the example variables and replace every placeholder:

   ```bash
   cd environments/<environment>
   cp terraform.tfvars.example terraform.tfvars
   ```

4. Initialise, check and save a plan:

   ```bash
   terraform init -lockfile=readonly
   terraform fmt -check -recursive
   terraform validate
   terraform plan -out=tfplan
   ```

5. Review the saved plan. Applying it creates billable resources, so apply only when you are ready, and destroy the environment as soon as you have finished:

   ```bash
   terraform apply tfplan
   terraform destroy
   ```

Keep the local state for as long as the resources exist; Terraform needs it to change or remove them.

## Conventions

- **Keyless by default.** Local key authentication is disabled. Access uses Microsoft Entra ID, managed identities and role assignments created in Terraform.
- **One root per architecture.** Each environment creates its own resource group with `azurerm_resource_group` and keeps local state, so roots can be deployed and removed independently.
- **Consistent naming.** Resource names follow `<type>-<workload>-<environment>-<region_code>-<instance>`. Names that must be globally unique, such as the Foundry account, add a five-character random suffix.
- **Pinned versions.** Roots pin provider versions and commit `.terraform.lock.hcl`; modules declare minimum versions only. Model deployments use `NoAutoUpgrade`, and `lifecycle` preconditions stop a plan that still contains placeholder values or lacks a prerequisite.
- **AzureRM first.** AzAPI covers only what AzureRM cannot express yet, such as project connections and `FireworksCustom` deployments.
- **No secrets in Git.** Populated `*.tfvars`, state, saved plans, `.env` files and keys are ignored by Git, and a pre-commit hook rejects them. Only `*.example` copies are committed. Case studies and datasets use synthetic data only.

## Quality checks

The same checks run locally and in CI; none of them needs Azure access. See [CONTRIBUTING.md](CONTRIBUTING.md) for installation, versions and how to run each one.

- **pre-commit** – trailing whitespace, line endings, YAML and JSON syntax, private-key detection, Terraform `fmt` and `validate`, TFLint and a block on sensitive files. Install with `pre-commit install` and run with `pre-commit run --all-files`.
- **Checks workflow** – runs on pull requests into `main`, on pushes to `main`, weekly and on demand:

  | Job | What it checks |
  | --- | --- |
  | `pre-commit` | All pre-commit hooks, plus actionlint and zizmor on the workflows |
  | `secrets` | Git history scanned with Betterleaks |
  | `module tests` | `terraform init`, `validate` and `test` for each module, with pinned and with latest provider versions |
  | `branch name` | Branches are named `<type>/<topic>`, for example `feat/module-test-runner` |
  | `commit messages` | Commits follow Conventional Commits, checked by commitlint against `.commitlintrc.yml` |
  | `terraform docs` | Generated sections of module READMEs are up to date |
  | `branch protection` | `main` keeps its protection rules |

Changes reach `main` through pull requests only.

## Cost and safety

- **Every apply creates billable resources.** Destroy each environment when you have finished with it, and check the resource group is gone.
- **Global Provisioned capacity bills hourly until it is deleted.** The `FireworksCustom` deployments in `foundry-fireworks-byow-lora` run a meter from creation to deletion, whether or not they serve traffic. A plan-time PTU gate blocks the deployment until an approver is recorded and the total is within the agreed cap. The resource group budget is a backstop only, because budgets are evaluated daily. Remove the deployments as soon as a session ends.
- **Destroy purges soft-deleted accounts.** The BYOW root purges the Foundry account and Key Vault on destroy, because charges for deployments on a soft-deleted account continue until it is purged.
- **Subscription registrations persist.** Resource provider registrations and the `Fireworks.EnableDeploy` feature are subscription-wide and are not removed by `terraform destroy`.
- **Fireworks data handling.** Fireworks processes customer data outside Microsoft facilities and is excluded from EU Data Boundary commitments. Review the [data handling guidance](https://learn.microsoft.com/azure/foundry/how-to/fireworks/privacy-compliance-faq) before you enable it.
- **Preview features.** Importing LoRA adapters to Fireworks on Foundry is in preview. Preview features are provided under the [Supplemental Terms of Use for Microsoft Azure Previews](https://azure.microsoft.com/support/legal/preview-supplemental-terms/); read them before you use a preview feature.
- **Proofs of concept.** The baselines keep public network access on. Private networking, alerting, retention and cost ownership need to be added before production use.

## Licence

Released under the [MIT License](LICENSE). Copyright (c) 2026 ZimCanIT.
