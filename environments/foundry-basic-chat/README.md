# Foundry Basic Chat

Deploy Foundry, GPT-4.1, Azure AI Search, Bing grounding, Azure Monitor and an App Service chat UI with Easy Auth. This public, single-region architecture is for proof of concept use.

## What gets created

You do not need to create these workload resources manually:

| Resource or configuration | Created by |
| --- | --- |
| Dedicated resource group | Terraform |
| Foundry account (S0), project and GPT-4.1 model deployment (Global Standard, capacity 50) | Terraform |
| Azure AI Search service (Basic) and Bing Grounding resource (G1) | Terraform |
| Linux App Service plan (B1, one instance) and .NET 10 web app | Terraform |
| Log Analytics workspace and Application Insights | Terraform |
| Managed identities, role assignments, project connections, diagnostics and web app authentication settings | Terraform |
| Easy Auth app registration and client secret for website sign-in | Script in step 2 |
| Search index, sample document and versioned prompt agent | Scripts in step 4 |

The chat application code is deployed separately in step 5.

## Prerequisites

- Use a Linux or WSL Bash terminal with Git, [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), [Terraform](https://developer.hashicorp.com/terraform/install) 1.10+ (1.x), [TFLint](https://github.com/terraform-linters/tflint#installation), Python 3.10+ with `venv`/`pip`, `curl` and `sha256sum` installed. Clone this repository and open its root directory in the terminal.
- Use a paid or pay-as-you-go Azure subscription eligible for [Bing Grounding](https://learn.microsoft.com/azure/foundry-classic/agents/how-to/tools-classic/bing-grounding). Check model availability and quota for the deployment above in your chosen region; the example uses Sweden Central.
- Prepare a **deployment service principal**, an application identity used by Azure CLI and Terraform. The current code expects this identity type.

If you do not already have a deployment identity, have an authorised administrator complete these steps:

1. In **Microsoft Entra ID > App registrations**, register a single-tenant application, such as `foundry-deployer`. Under **Certificates & secrets**, create a client secret and securely save its **Value**. See [Microsoft's service principal setup guide](https://learn.microsoft.com/entra/identity-platform/howto-create-service-principal-portal).
2. In the target subscription's **Access control (IAM)**, assign that identity **Contributor** and **Role Based Access Control Administrator**. An existing **Owner** assignment also covers these deployment operations. Subscription scope is needed here because Terraform creates the resource group.
3. On the deployment app's **API permissions**, add **Microsoft Graph > Application permissions > Application.ReadWrite.OwnedBy**. An administrator authorised to consent to Microsoft Graph application permissions, such as a **Privileged Role Administrator**, must [grant admin consent](https://learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent). Azure subscription roles do not grant this permission.

This deployment identity is separate from the Easy Auth application created in step 2 below.

## 1. Authenticate and configure

Find the **Application (client) ID** and **Directory (tenant) ID** on the deployment app's Overview page, and the **Subscription ID** on the subscription's Overview page. From the repository root, enter them at the prompts; the client secret input is hidden:

```bash
cd environments/foundry-basic-chat
umask 077
read -r -p "Application (client) ID: " AZURE_CLIENT_ID
read -r -p "Directory (tenant) ID: " AZURE_TENANT_ID
read -r -p "Subscription ID: " AZURE_SUBSCRIPTION_ID
read -r -s -p "Client secret value: " AZURE_CLIENT_SECRET
printf '\n'
az login --service-principal \
  --username "$AZURE_CLIENT_ID" --password "$AZURE_CLIENT_SECRET" \
  --tenant "$AZURE_TENANT_ID"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
az account show --output table
[ -f terraform.tfvars ] || cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`: choose a distinct `workload_name` for globally unique service names, confirm the resource group name and region, and set your tags. **Run every remaining command from this directory.** Terraform uses Azure CLI authentication and local state.

## 2. Create Easy Auth

Use the exact App Service name: `app-<workload_name>-<environment>-<instance>`. For the example values:

```bash
bash ../../scripts/create_easy_auth_app.sh --web-app-name app-zimcnait-basic-chat-uat-001
```

The script sets the callback and required ID-token issuance, then saves a one-year secret in the ignored, mode-`0600` `easy-auth.auto.tfvars.json`. Reuse an existing file only while its app and credential remain valid. The script refuses duplicates and overwrites; see [recovery guidance](../../scripts/README.md) if credentials are missing or stale.

## 3. Deploy infrastructure

Run the commands in order and stop if one fails. `init` downloads dependencies; `plan` previews changes; `apply` provisions resources after you review the changes and enter `yes`.

```bash
terraform init
terraform fmt -check -recursive ../..
terraform validate
tflint --init --config=../../.tflint.hcl
tflint --config=../../.tflint.hcl
terraform plan
terraform apply
```

## 4. Create the Search fixture and agent

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ../../scripts/requirements.txt

python ../../scripts/bootstrap_search.py \
  --endpoint "$(terraform output -raw search_endpoint)" \
  --index "$(terraform output -raw search_index_name)"

python ../../scripts/bootstrap_agent.py \
  --search-index "$(terraform output -raw search_index_name)" \
  --agent-name "$(terraform output -raw agent_name)"
terraform apply
```

The bootstrap saves the agent name and version in ignored `agent.auto.tfvars.json`. The second apply updates the web app to use that exact version.

## 5. Deploy and verify the web app

```bash
bash ../../scripts/deploy_chat_web_app.sh
python ../../scripts/verify_agent.py
terraform output -raw web_app_url
```

The deployment script verifies the pinned package checksum; the verifier checks Search and Bing grounding. Open the printed URL, sign in with a user from the same Entra tenant and send a chat message. Review traces under **Agents > Traces** in Foundry. Usage incurs Azure charges.

Keep state, plans and populated variable files private and out of Git. Retain local state for future changes and teardown; run only one deployment at a time.
