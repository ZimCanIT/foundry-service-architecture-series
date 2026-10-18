# Fireworks AI on Microsoft Foundry

This environment plans a Foundry account, project, monitoring, and a Global Standard deployment of DeepSeek V4.1 Flash. The example uses Sweden Central.

## Prerequisites

- Install Azure CLI, Terraform, and TFLint. Set `ARM_SUBSCRIPTION_ID` to the target subscription.
- Sign in as the deploying user with subscription-level permission to register resource providers and features (for example `Contributor` at subscription scope), `Contributor` on the workload, and `Role Based Access Control Administrator` permissions. Terraform assigns that user the `Foundry Owner` role on the Foundry account. The project's managed identity receives `Foundry User` so it can access the Foundry project.
- Review the [Fireworks service terms](https://learn.microsoft.com/en-us/azure/foundry/how-to/fireworks/enable-fireworks-models) and [data handling guidance](https://learn.microsoft.com/azure/foundry/how-to/fireworks/privacy-compliance-faq) against organizational requirements before registration. Fireworks processes customer data outside Microsoft facilities and is excluded from EU Data Boundary commitments.

## Configure and plan

Terraform registers the subscription-wide prerequisites. The AzureRM provider registers the `Microsoft.CognitiveServices` resource provider through `resource_providers_to_register`. An AzAPI `POST` action then requests the `Fireworks.EnableDeploy` pre-release feature. Both are idempotent, and `terraform destroy` unregisters neither, so other workloads that depend on Fireworks are unaffected.

Azure approves the feature asynchronously. On a new subscription the first apply can stop before the model deployment, with a message that the feature is not yet `Registered`. Check its state, then plan and apply again once it reports `Registered`:

```bash
az login
az account set --subscription "$ARM_SUBSCRIPTION_ID"
az feature registration show \
  --provider-namespace Microsoft.CognitiveServices \
  --name Fireworks.EnableDeploy \
  --subscription "$ARM_SUBSCRIPTION_ID" \
  --query 'properties.state' \
  --output tsv
```

Query the model catalog and select an approved version and available quota:

```bash
az cognitiveservices model list \
  --location swedencentral \
  --subscription "$ARM_SUBSCRIPTION_ID" \
  --query "[?model.name=='FW-DeepSeek-V4.1-Flash'].{name:model.name,version:model.version,format:model.format}" \
  --output table
```

From `environments/foundry-fireworks-ai`, copy the [example variables](terraform.tfvars.example), replace IDs and organizational tags, and set `model_version` and `model_capacity` (TPM) for the approved offer:

```bash
cp terraform.tfvars.example terraform.tfvars
# Replace placeholder IDs, tags, model_version, and model_capacity before continuing.
terraform init -lockfile=readonly
terraform fmt -check -recursive
terraform validate
tflint --init --config=../../.tflint.hcl
tflint --config=../../.tflint.hcl
terraform plan -out=fireworks.tfplan
```

Planning rejects a placeholder model version, and the deployment is blocked until the feature is `Registered`. Review the saved plan before an explicit apply. `NoAutoUpgrade` pins the model version; plan and review a supported replacement before retirement.

## Operational notes

- Public network access is enabled; local key authentication is disabled. Log Analytics collects Audit, RequestResponse, AzureOpenAIRequestUsage, and Trace logs. Confirm approved networking, authentication, and application permissions before production use.
- Configure retention, latency/error/throttling alerts, and cost ownership before production use.
- Use one authoritative execution machine with restricted access and encrypted storage/backups. Local state locking cannot coordinate separate copies on multiple machines. Keep populated `.tfvars`, state, and saved plans private and out of Git; document recovery.
