# Foundry Basic Chat

This environment deploys the Microsoft Foundry chat proof of concept with Terraform, following the Azure Architecture Center reference and adding Azure AI Search grounding and Microsoft Entra Easy Auth.

The root module composes the Foundry account and optional project, GPT-4.1 deployment, Azure AI Search, Bing grounding, monitoring and App Service. Bootstrap scripts create a synthetic Search fixture and named prompt agent after the project connections exist. The public, single-region design is for proof of concept work and is not production ready.

## Prerequisites

- Azure CLI, Terraform, TFLint, Python 3 and `curl` installed.
- An Azure subscription with permissions to create the listed resources and role assignments. The deployment identity needs `Owner`, `Role Based Access Control Administrator` or `User Access Administrator` at the deployment scope to create role assignments.
- An Azure CLI session for the intended tenant and subscription. Terraform uses that session for authentication and stores state locally in this directory.
- For service-principal sign-in, set the credentials in your shell and run:

  ```bash
  az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --password "$AZURE_CLIENT_SECRET" \
    --tenant "$AZURE_TENANT_ID"
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  ```

  Do not put credentials in this README, a Terraform variable file or source control. Check the selected context with `az account show` before deployment.

## Configure Easy Auth

The web app uses Microsoft Entra authentication through App Service Easy Auth. Create its single-tenant app registration before the first Terraform apply so the web app can be configured with its client ID and secret.

The signed-in identity needs permission to create an app registration and add a client secret. For interactive users, Microsoft documents the **Application Developer** role, subject to tenant policy. When using a service principal, grant it Microsoft Graph's **Application.ReadWrite.OwnedBy** application permission and tenant admin consent. Azure subscription `Owner` alone does not grant Microsoft Graph permissions.

From the repository root, run the create-only script with the exact globally unique App Service name used by this environment:

```bash
bash scripts/create_easy_auth_app.sh \
  --web-app-name app-zimcnait-basic-chat-uat-001
```

The script configures the callback URI, enables ID-token issuance required by Easy Auth's hybrid sign-in response, creates a one-year client secret and writes the client ID and secret to the ignored `environments/foundry-basic-chat/easy-auth.auto.tfvars.json` file with permissions restricted to the current user. Access-token issuance remains disabled. It does not print the secret. It refuses to overwrite an existing credential file or create a duplicate registration. If this file already exists, keep and reuse it. If the file is lost, inspect the existing registration and rotate its credential rather than blindly re-running the create script.

Terraform state also contains the Easy Auth secret after deployment. Keep both the variable file and local state private. For more detail on the script's permissions and behaviour, see [the scripts guide](../../scripts/README.md).

## Configure and deploy

Copy the example variables file and set the workload, environment, region, instance and resource group values for your Azure estate. The example is already set to the CAF-style UAT names used by this deployment.

```bash
cp terraform.tfvars.example terraform.tfvars
```

The generated `easy-auth.auto.tfvars.json` file supplies the Easy Auth values automatically. Both populated files and Terraform state are ignored by Git. Do not commit them.

From this directory, initialise Terraform, check the configuration, and review the plan before applying:

```bash
terraform init
terraform fmt -check -recursive
terraform validate
tflint --init
tflint --recursive
terraform plan
terraform apply
```

The deployment uses local state in this environment directory. Do not run the same environment concurrently from another working directory, and back up the state securely before changing machines.

## Create the Search fixture and agent

After the Azure resources and Foundry project connections are ready, install the Python dependencies in a local virtual environment, create the synthetic Search fixture, and create the named prompt agent:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ../../scripts/requirements.txt

python ../../scripts/bootstrap_search.py \
  --endpoint "$(terraform output -raw search_endpoint)" \
  --index "$(terraform output -raw search_index_name)"

python ../../scripts/bootstrap_agent.py
terraform apply
```

The agent bootstrap writes its exact name and version to the ignored `agent.auto.tfvars.json` file. The second Terraform apply configures the web app to use that version.

## Deploy and verify the web app

Deploy the checksum-verified sample package pinned to the Azure sample commit, then verify that the agent can answer using both Azure AI Search and Bing grounding:

```bash
bash ../../scripts/deploy_chat_web_app.sh
python ../../scripts/verify_agent.py
```

Open the URL printed by `terraform output -raw web_app_url` and complete Microsoft Entra sign-in through Easy Auth. The verification script checks the unique Search fixture marker and citation, an external Bing citation, and that both responses use the same conversation and Terraform-managed agent version. Traces may take a few minutes to appear in the Foundry project's **Agents > Traces** view.

The Search and Bing checks make model and grounding calls that can incur charges. This architecture deliberately retains proof of concept trade-offs, including public service endpoints and single-instance capacity.
