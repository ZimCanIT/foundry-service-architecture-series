# Basic chat deployment scripts

Run these commands from `environments/foundry-basic-chat` after Azure CLI authentication and Terraform prerequisites are ready. Python 3, Azure CLI, Terraform, and `curl` are required. Install the script dependencies into a local virtual environment if they are not already available:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ../../scripts/requirements.txt
```

Copy `terraform.tfvars.example` to the ignored `terraform.tfvars` and set the CAF workload, environment, region code, instance and resource group name. The Easy Auth credentials are held separately in the ignored `easy-auth.auto.tfvars.json` file. Keep all populated variable files private; Terraform state also contains sensitive values.

To create the dedicated Easy Auth app registration with Azure CLI, authenticate to the intended tenant with an identity permitted to register applications, then run this from the repository root:

```bash
bash scripts/create_easy_auth_app.sh --web-app-name app-zimcnait-basic-chat-uat-001
```

The script creates a single-tenant registration, configures the callback, enables ID-token issuance required by Easy Auth's hybrid sign-in response, and writes its client ID and one-year secret to the ignored `environments/foundry-basic-chat/easy-auth.auto.tfvars.json` file with mode `0600`. Access-token issuance remains disabled. It checks for duplicate registrations among those owned by the signed-in identity and refuses to overwrite an existing credentials file. For an interactive user, Microsoft documents the **Application Developer** role (or tenant policy allowing users to register apps) for creating registrations; that role can also add a secret to an app the user owns. For service-principal automation using this script's create, inspect and add-credential steps, grant the automation identity Microsoft Graph's **Application.ReadWrite.OwnedBy** application permission and tenant admin consent. That permission can create and manage applications owned by the calling app, including their credentials. Microsoft Graph also documents **AppRegistration.Create** as the least-privileged permission for app creation alone; it does not cover the separate add-password operation, which requires **Application.ReadWrite.OwnedBy**. Azure subscription Owner does not grant Microsoft Graph permissions. The secret remains in local Terraform state after deployment; do not print, commit or share either file. See [App Service Microsoft Entra sign-in](https://learn.microsoft.com/azure/app-service/configure-authentication-provider-aad), [Easy Auth OAuth flow behaviour](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization#client-type-and-oauth-flow-behavior), the [Microsoft Graph create application permissions](https://learn.microsoft.com/graph/api/application-post-applications?view=graph-rest-1.0#permissions), the [application add-password permissions](https://learn.microsoft.com/graph/api/application-addpassword?view=graph-rest-1.0#permissions), and [Application Developer role](https://learn.microsoft.com/entra/identity/role-based-access-control/permissions-reference#application-developer).

Initialise and review the local-state deployment:

```bash
terraform init
terraform fmt -check -recursive
terraform validate
tflint --init
tflint --recursive
terraform plan
terraform apply
```

After the services and project connections are ready, create the text index and synthetic grounding fixture, then create the named prompt agent. These scripts use the active Azure CLI identity and do not print access tokens:

```bash
python ../../scripts/bootstrap_search.py \
  --endpoint "$(terraform output -raw search_endpoint)" \
  --index "$(terraform output -raw search_index_name)"

python ../../scripts/bootstrap_agent.py
terraform apply
```

The agent script writes `agent.auto.tfvars.json` with the exact name and version returned by Foundry. The file is ignored by Git and is restricted to the current user. The second apply updates the application settings to reference that version.

Deploy the checksum-verified application package pinned to the Azure sample commit, then test the agent response:

```bash
bash ../../scripts/deploy_chat_web_app.sh
python ../../scripts/verify_agent.py
```

Open the `web_app_url` Terraform output in a browser and complete Microsoft Entra sign-in, then send a chat message through the UI. The Python verification creates a Responses API conversation and sends two requests to the exact Terraform-referenced agent version. It checks that the Search response contains the unique fixture marker and cites its synthetic source URL, that the Bing response includes an external HTTPS citation, and that both responses retain the same conversation ID. It prints response IDs so you can find the corresponding spans in the Foundry project's **Agents > Traces** view and confirm the Search/Bing tool calls and model usage. Tracing can take a few minutes to appear.

The agent uses a simple full-text Search query and does not generate vector embeddings. The index includes an empty vector field to match the current Search tool schema. The Search and Bing checks make model and grounding calls that can incur charges. Basic App Service authentication, public service endpoints, single-instance capacity, and Bing grounding charges are proof of concept trade-offs; this topology is not production ready.
