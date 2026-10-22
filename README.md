# Foundry Service Architecture Series

This repository holds the reference deployments for the ZimCanIT YouTube series on Microsoft Foundry in Azure. Each episode covers one part of Foundry, such as basic chat architecture, Foundry Agent Service, tools integration or partner model providers, and has a Terraform environment you can plan, deploy and remove on your own subscription.

The environments are proofs of concept. Each README states the trade-offs, such as public endpoints or single-region capacity, that you would need to address before production use.

## Repository layout

- `environments/`: one Terraform root per architecture, each with its own local state, inputs, outputs, prerequisites and clean-up steps. The [environments overview](environments/README.md) lists them; start with the README of the one you want.
- `modules/`: reusable modules the environments compose, such as the Foundry account and project, Azure Monitor and Azure AI Search. See the [module catalogue](modules/README.md).
- `scripts/environments/<environment>/`: Python and shell helpers for each environment, such as agent bootstrap and verification.
- `case-studies/`: complete, end-to-end deployments of solutions that use Foundry alongside other Azure services, such as image classification or content filtering. Each case study has its own folder with a README and decision record. Their helper scripts live under `scripts/case-studies/<slug>/`.

## Working with the code

You need an Azure subscription, Azure CLI, Terraform `>= 1.10.0, < 2.0.0` and TFLint, plus Python 3 for the helper scripts. The roots pin AzureRM `~> 5.8.0` and AzAPI `~> 2.13.0`; `terraform init` fails on other versions. Sign in with `az login` and set `ARM_SUBSCRIPTION_ID` before you plan. The deployments are keyless by default: Entra ID, managed identities and role assignments in Terraform, with local key authentication disabled.

The general flow for an environment is:

```bash
cd environments/<environment>
cp terraform.tfvars.example terraform.tfvars   # then set your own values
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform destroy                              # when you have finished
```

Applying creates billable Azure resources, so destroy each environment when you have finished with it. Keep `terraform.tfvars`, state files and saved plans private. Git ignores them because they can hold subscription IDs and other sensitive values. For linting and the pre-commit hooks, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

See [LICENSE](LICENSE).
