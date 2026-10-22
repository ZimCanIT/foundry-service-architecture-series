# Fireworks AI on Microsoft Foundry

This environment shows how to enable Fireworks AI models in Azure. Terraform registers the `Microsoft.CognitiveServices` provider and the `Fireworks.EnableDeploy` feature on the subscription, then creates a Foundry account and project and a Global Standard deployment of DeepSeek V4.1 Flash (`FW-DeepSeek-V4.1-Flash-1017`, the latest build) through Fireworks AI. The shared Foundry module also needs Log Analytics and Application Insights, so the plan includes them. There are no agents, tools or model comparisons. The example uses Sweden Central.

The account name ends in a five-character random suffix from the `random` provider. The name doubles as the custom subdomain of the account's endpoint, which must be unique and cannot be changed after creation, so the suffix keeps it globally unique. It is stored in state, so a destroy followed by an apply produces a new name. See [custom subdomain names](https://learn.microsoft.com/azure/ai-services/cognitive-services-custom-subdomains). [Learn]

## Prerequisites

- Install Azure CLI, Terraform, and TFLint. Set `ARM_SUBSCRIPTION_ID` to the target subscription.
- Sign in as the deploying user with subscription-level permission to register resource providers and features (for example `Contributor` at subscription scope), `Contributor` on the workload, and `Role Based Access Control Administrator` permissions. Terraform assigns that user the `Foundry Owner` role on the Foundry account. The project's managed identity receives `Foundry User` so it can access the Foundry project.
- Review the [Fireworks service terms](https://learn.microsoft.com/en-us/azure/foundry/how-to/fireworks/enable-fireworks-models) and [data handling guidance](https://learn.microsoft.com/azure/foundry/how-to/fireworks/privacy-compliance-faq) against organizational requirements before registration. Fireworks processes customer data outside Microsoft facilities and is excluded from EU Data Boundary commitments.

## Configure and plan

Terraform registers the subscription-wide prerequisites. The AzureRM provider registers the `Microsoft.CognitiveServices` resource provider through `resource_providers_to_register`. An AzAPI `POST` action then requests the `Fireworks.EnableDeploy` pre-release feature. Both are idempotent, and `terraform destroy` unregisters neither, so other workloads that depend on Fireworks are unaffected.

Azure approves the feature asynchronously. On a new subscription the first apply can stop before the model deployment, with a message that the feature is `Pending`. Check its state, then plan and apply again once it reports `Registered`. If the feature is unregistered later, Terraform sees the change on the next plan and sends the request again on apply:

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

Once the feature is `Registered`, check which Fireworks models the subscription can deploy in the region, with their versions, quota and available capacity. From the repository root:

```bash
bash scripts/shared/check_foundry_model_capacity.sh --location swedencentral --model deepseek --provider fireworks
```

The script wraps `az cognitiveservices model list`, `az cognitiveservices usage list` and the Model Capacities API, and changes nothing in Azure. Take `model_version` from the Version column and `model_capacity_thousand_tpm` from the Quota and Available columns, and check Status and Retires before pinning a version. While the feature is still `NotRegistered`, the catalogue lists no Fireworks models and the script reports no matches. [Measured] `bash scripts/shared/check_foundry_model_capacity.sh --help` describes the other options, such as `--provider anthropic` on its own or `--no-capacity` for a faster run.

From `environments/foundry-fireworks-model-deployment`, copy the [example variables](terraform.tfvars.example), replace IDs and organizational tags, and set `model_version` and `model_capacity_thousand_tpm` for the approved offer:

```bash
cp terraform.tfvars.example terraform.tfvars
# Replace placeholder IDs, tags, model_version, and model_capacity_thousand_tpm before continuing.
terraform init -lockfile=readonly
terraform fmt -check -recursive
terraform validate
tflint --init --config=../../.tflint.hcl
tflint --config=../../.tflint.hcl
terraform plan -out=fireworks.tfplan
```

Planning rejects a placeholder model version, and the deployment is blocked until the feature is `Registered`. Review the saved plan before an explicit apply. `NoAutoUpgrade` pins the model version; plan and review a supported replacement before retirement.

## Operational notes

- Public network access is enabled; local key authentication is disabled. Log Analytics receives the Audit, RequestResponse, AzureOpenAIRequestUsage and Trace logs (`AzureDiagnostics` table) through the shared module, and the account's platform metrics (`AzureMetrics` table) through a second diagnostic setting in this root. Confirm approved networking, authentication, and application permissions before production use.
- Configure retention, latency/error/throttling alerts, and cost ownership before production use.
- Use one authoritative execution machine with restricted access and encrypted storage/backups. Local state locking cannot coordinate separate copies on multiple machines. Keep populated `.tfvars`, state, and saved plans private and out of Git; document recovery.
