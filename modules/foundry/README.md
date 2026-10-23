# foundry

Microsoft Foundry account (`AIServices`) with an optional project, an optional model deployment, diagnostics and optional project connections. AzureRM creates the resources. AzAPI covers the project connections that AzureRM cannot express yet.

The defaults build the account that the first video deploys. Every option below is off or neutral until it is set, so existing roots plan with no change. Local key authentication is always off.

## Example

```hcl
module "foundry" {
  source = "../../modules/foundry"

  name                                   = "aif-example-dev-uks-001"
  location                               = "uksouth"
  resource_group_name                    = azurerm_resource_group.this.name
  log_analytics_workspace_id             = module.azure_monitor.log_analytics_workspace_id
  application_insights_connection_string = module.azure_monitor.application_insights_connection_string
}
```

## Options that change behaviour

| Input | Default | Effect |
| --- | --- | --- |
| `security_profile` | `baseline` | `production` adds the plan-time checks below. |
| `public_network_access_enabled` | `true` | Whether the account accepts traffic from public networks. |
| `network_acls` | `Allow`, no bypass, no rules | Default action, bypass, IP rules and subnet rules. Rules apply only with `Deny`, so the variable rejects them otherwise. |
| `managed_identities` | system-assigned | Adds user-assigned identities to the account. The account always keeps an identity, because the AzureRM documentation requires one on an account that hosts projects [Research]. The system-assigned identity must stay on while an Azure AI Search connection is set, because the search role assignments use it. |
| `project_managed_identities` | system-assigned | The same for the project. The role assignments and connections that this module creates use the system-assigned identity, so it stays on while `create_project = true`. |
| `model_deployment` | `null` | Checked at plan time: positive whole-number capacity, a known `version_upgrade_option`, a set `model_version` while the option is `NoAutoUpgrade`, and a plain SKU name. The provider checks the SKU name against its own list. |

## Security profile

`security_profile = "production"` fails the plan unless all of these hold:

1. Public network access is off, or `network_acls.default_action` is `Deny`.
2. `diagnostic_log_categories` has at least one entry.
3. `role_assignments` has no `Owner`, `Contributor` or `User Access Administrator`.

The checks are `lifecycle` preconditions on the account. They inspect settings only. The module does not create private endpoints, private DNS, Agent capability hosts or customer-managed keys. A production landing zone adds those in its own root.

## Outputs

The original outputs are unchanged. Added outputs:

| Output | Value |
| --- | --- |
| `resource_id`, `name` | Aliases of `account_id` and `account_name`, named as in the AVM cognitive services account module [Research]. |
| `system_assigned_mi_principal_id` | Object ID of the system-assigned identity of the account, or `null` when the account has none. Named as in the same AVM module [Research]. |
| `project_resource_id` | Alias of `project_id`. |
| `diagnostic_setting_id` | Resource ID of the account diagnostic setting. |
| `role_assignment_ids` | Resource IDs of `role_assignments`, keyed by label. |
| `model_deployment_metadata` | `null`, or the deployment ID, name, format, model name, model version, SKU name, capacity, upgrade option and RAI policy. |

## Tests

```bash
cd modules/foundry
terraform init -backend=false
terraform test
```

Both providers are mocked, so the tests need no credentials and nothing reaches Azure. The five files in `tests/` hold 37 runs: `defaults`, `security_profile`, `identity`, `network` and `model_deployment`. The defaults run pins the baseline account, the four diagnostic categories, the absence of every optional resource and the optional outputs. The other files cover each validation and each production check, with one broken rule per run.

- [Measured] All 37 runs pass on AzureRM 5.8.0 and on AzureRM 5.10.0 (2026-10-23).
- [Measured] Six deliberate regressions in a scratch copy – each of the three production checks disabled, the Deny default action ignored, local key authentication switched on and the project identity IDs dropped – were each caught by at least one run (2026-10-23).
- [To measure] The tests prove module logic and provider schema validity. They do not prove that Azure accepts a variant, such as an account with only a user-assigned identity. Only the default settings are planned against the real provider, by the environment roots.

Modules carry no lock file. The local `.terraform.lock.hcl` and `.terraform` folder that `terraform init` creates are git-ignored.

## Comparison with the AVM pattern module

Read on 2026-10-23 against `Azure/terraform-azurerm-avm-ptn-aiml-ai-foundry` v0.12.0 and `Azure/avm-res-cognitiveservices-account/azurerm` 0.11.1 [Research]. The table covers the settings that decide whether a root can use each module. It is not a list of every input.

| Area | AVM pattern module v0.12.0 | This module |
| --- | --- | --- |
| Provider constraints | Terraform `>= 1.12, < 2.0`, AzureRM `~> 4.38`, AzAPI `~> 2.12`, plus the `modtm`, `random` and `time` providers. `~> 4.38` excludes AzureRM 5.x, which upstream tracks in issue #144. | Terraform `>= 1.10.0, < 2.0.0`, AzureRM `>= 5.8.0`, AzAPI `>= 2.13.0`. The roots pin AzureRM `~> 5.8.0`. |
| Local key authentication | `ai_foundry.disable_local_auth` defaults to `false`. | Always off. |
| Public network access | Derived from `create_private_endpoints` unless overridden. `network_acls = null` allows all networks. | On in the baseline. Set with `public_network_access_enabled` and `network_acls`. The production profile refuses an open account at plan time. |
| Private endpoints, DNS, network injection, Agent capability hosts, bring-your-own resources, customer-managed keys | Supported (`create_private_endpoints`, `network_injections`, `create_ai_agent_service`, `create_byor`, `customer_managed_key`). | Not supported. Private networking belongs in its own root. |
| Identities | Account: system-assigned and user-assigned. Project: `SystemAssigned` is fixed in `modules/ai-foundry-project/main.tf`. | Account and project accept user-assigned identities next to the system-assigned one. |
| Model deployments | A map of deployments. `version_upgrade_option` defaults to `OnceNewDefaultVersionAvailable`. The variable has no validation block. | One deployment per module call. `version_upgrade_option` defaults to `NoAutoUpgrade`. Capacity, upgrade option, version pinning and SKU format are validated at plan time. |
| Diagnostics | A map of settings with log groups (default `allLogs`), metric categories (default `AllMetrics`) and workspace, storage, Event Hub or partner destinations. | One Log Analytics setting on the account with explicit categories (default four log categories, no metrics), plus an optional project setting. |
| Role assignments and lock | Role assignments by name or ID, with `skip_service_principal_aad_check` and delegated identities. No lock input. | Role assignments by name, with ABAC conditions. An optional management lock. |
| Fixed waits | `time_sleep` resources with literal durations: 60 s for key role propagation, 5 min after the account, 10 s for project identities and 60 s before the capability host. | None. Role assignments and connections depend on the resources they use. |

[Research] for every AVM cell: `terraform.tf`, `variables.tf`, `variables.foundry.tf`, `main.foundry.tf` and `modules/ai-foundry-project/main.tf` in the v0.12.0 source. [Repo] for every cell of this module: `versions.tf`, `variables.tf`, `main.tf` and `outputs.tf`.

This module is not a replacement for the AVM pattern module. It is narrower and stricter by default. It fits a root that needs AzureRM 5.x, local key authentication off by construction, pinned model versions and a single account with an optional project. The AVM pattern module fits a design that needs private endpoints, Agent capability hosts, bring-your-own storage, Cosmos DB or Search, customer-managed keys, several deployments in one call or diagnostics sent to storage or Event Hub, provided the root can stay on AzureRM 4.x.

## Reference

Generated by terraform-docs from the module code. Do not edit by hand.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.10.0, < 2.0.0 |
| azapi | >= 2.13.0 |
| azurerm | >= 5.8.0 |

### Providers

| Name | Version |
| ---- | ------- |
| azapi | >= 2.13.0 |
| azurerm | >= 5.8.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [azapi_resource.application_insights_connection](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.azure_ai_search_connection](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.bing_connection](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) | resource |
| [azurerm_cognitive_account.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_account) | resource |
| [azurerm_cognitive_account_project.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_account_project) | resource |
| [azurerm_cognitive_deployment.model](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_deployment) | resource |
| [azurerm_management_lock.account](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock) | resource |
| [azurerm_monitor_diagnostic_setting.account](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.project](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_role_assignment.account](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.account_search_index_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.account_search_service_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.deployment_account_foundry_user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.deployment_project_manager](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.project_account_foundry_user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.project_app_insights_metrics_publisher](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.project_search_index_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.project_search_service_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| application\_insights\_connection\_string | Application Insights connection string required by the Foundry project trace connection. | `string` | n/a | yes |
| location | Azure region shared by the Foundry account and optional project. | `string` | n/a | yes |
| log\_analytics\_workspace\_id | Destination workspace for Foundry account diagnostic logs. | `string` | n/a | yes |
| name | Name and custom subdomain for the Microsoft Foundry account. | `string` | n/a | yes |
| resource\_group\_name | Resource group containing the Foundry account. | `string` | n/a | yes |
| bing\_grounding\_key | Sensitive key for the Foundry project Bing Grounding connection. | `string` | `null` | no |
| create\_project | Whether to create a Foundry project under the account. | `bool` | `false` | no |
| deployment\_principal\_id | Optional object ID of the deployment principal that creates project connections and agents. | `string` | `null` | no |
| diagnostic\_log\_categories | Log categories sent from the account to the workspace. Audit and RequestResponse are the useful ones; AzureOpenAIRequestUsage and ManagedNetworkEvent carry an export charge, and Trace is emitted only by custom question answering. All categories land in the shared AzureDiagnostics table. | `set(string)` | ```[ "Audit", "RequestResponse", "AzureOpenAIRequestUsage", "Trace" ]``` | no |
| diagnostic\_metric\_categories | Metric categories sent by the same diagnostic setting. Empty by default because roots that already route AllMetrics through a separate setting cannot send the same category to the same workspace twice. | `set(string)` | `[]` | no |
| lock | Optional management lock on the account. kind is CanNotDelete or ReadOnly. Null creates no lock. | ```object({ kind = string name = optional(string) })``` | `null` | no |
| managed\_identities | Managed identities on the Foundry account. The system-assigned identity stays on by default because the Azure AI Search role assignments and the principal ID outputs use it; user-assigned identities can be added next to it. | ```object({ system_assigned = optional(bool, true) user_assigned_resource_ids = optional(set(string), []) })``` | `{}` | no |
| model\_deployment | Optional model deployment to create on the Foundry account. Set to null to create no deployment. | ```object({ name = string model_name = string model_version = string sku_name = string capacity = number format = optional(string, "OpenAI") rai_policy_name = optional(string, "Microsoft.DefaultV2") version_upgrade_option = optional(string, "NoAutoUpgrade") })``` | `null` | no |
| network\_acls | Network rules for the account. The defaults (Allow, no bypass, no rules) reproduce the fixed block this module used before. IP and subnet rules apply only when default\_action is Deny; subnets need the Microsoft.CognitiveServices service endpoint. | ```object({ default_action = optional(string, "Allow") bypass = optional(string, "None") ip_rules = optional(set(string), []) virtual_network_subnet_ids = optional(set(string), []) })``` | `{}` | no |
| project\_connections | Optional per-service connections to create in the Foundry project. | ```object({ application_insights = optional(object({ resource_id = string location = string })) bing_grounding = optional(object({ resource_id = string endpoint = string })) azure_ai_search = optional(object({ resource_id = string endpoint = string location = string connection_name = optional(string, "azure-ai-search") })) })``` | `{}` | no |
| project\_description | Description of the optional Foundry project. | `string` | `"Microsoft Foundry project for this workload."` | no |
| project\_diagnostic\_log\_categories | Log categories for the project diagnostic setting. | `set(string)` | ```[ "Audit", "Trace" ]``` | no |
| project\_diagnostics\_enabled | Creates a diagnostic setting on the project (Audit and Trace logs plus AllMetrics). Requires create\_project. | `bool` | `false` | no |
| project\_display\_name | Display name of the optional Foundry project. | `string` | `"Microsoft Foundry Project"` | no |
| project\_managed\_identities | Managed identities on the optional Foundry project. The system-assigned identity stays on because the role assignments and connections created by this module use it; user-assigned identities can be added next to it. | ```object({ system_assigned = optional(bool, true) user_assigned_resource_ids = optional(set(string), []) })``` | `{}` | no |
| project\_name | Name of the optional Foundry project. | `string` | `"project"` | no |
| public\_network\_access\_enabled | Whether the account accepts traffic from public networks. The baseline keeps this on; private networking belongs in its own root. | `bool` | `true` | no |
| role\_assignments | Additional role assignments on the Foundry account, keyed by a stable label. Use built-in role names such as Foundry User or Foundry Owner; conditions use ABAC condition syntax with condition\_version 2.0. | ```map(object({ role_definition_name = string principal_id = string principal_type = string description = optional(string) condition = optional(string) condition_version = optional(string) }))``` | `{}` | no |
| security\_profile | baseline keeps the current behaviour. production adds plan-time checks on the account: public access off or a Deny default action, at least one diagnostic log category, and no Owner, Contributor or User Access Administrator in role\_assignments. Local key authentication is off in both profiles. | `string` | `"baseline"` | no |
| tags | Tags applied to the Foundry account and project. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| account\_endpoint | Endpoint of the Microsoft Foundry account. |
| account\_id | Resource ID of the Microsoft Foundry account. |
| account\_identity\_principal\_id | System-assigned identity object ID of the Foundry account. |
| account\_name | Name of the Microsoft Foundry account. |
| application\_insights\_connection\_id | Resource ID of the optional Application Insights project connection. |
| azure\_ai\_search\_connection\_id | Resource ID of the optional Azure AI Search project connection. |
| bing\_connection\_id | Resource ID of the optional Bing Grounding project connection. |
| diagnostic\_setting\_id | Resource ID of the account diagnostic setting. |
| model\_deployment\_metadata | Name, model, version, SKU, capacity and upgrade policy of the optional model deployment, or null when no deployment is created. |
| model\_deployment\_name | Name of the optional model deployment, or null when no deployment is created. |
| name | Name of the Foundry account (alias of account\_name). |
| project\_endpoint | Foundry API endpoint for the optional project, or null when no project is created. |
| project\_id | Resource ID of the optional Foundry project, or null when no project is created. |
| project\_identity\_principal\_id | System-assigned identity object ID of the optional project. |
| project\_name | Name of the optional Foundry project, or null when no project is created. |
| project\_resource\_id | Resource ID of the optional project (alias of project\_id). |
| resource\_id | Resource ID of the Foundry account (alias of account\_id). |
| role\_assignment\_ids | Resource IDs of the generic account role assignments, keyed by label. |
| system\_assigned\_mi\_principal\_id | Object ID of the system-assigned identity of the account (alias of account\_identity\_principal\_id), or null when the account has only user-assigned identities. |
<!-- END_TF_DOCS -->
