# Terraform Modules

This directory contains reusable capabilities shared by the environments in the Microsoft Foundry Service Architecture series. Each environment focuses on one aspect of Foundry, such as basic chat architecture, hosted agents, tools integration or model provider integration, and composes the modules it needs.

| Module | Responsibility |
| --- | --- |
| `foundry` | Foundry account, optional project, optional model deployment checked at plan time, diagnostics with selectable log categories, optional project diagnostics, network rules, user-assigned identities, a `security_profile` whose production setting checks the account at plan time, scoped provisioning roles, generic role assignments, optional management lock and optional project connections. Mocked `terraform test` coverage and a comparison with the AVM pattern module are in the module README. |
| `azure-ai-search` | Azure AI Search service, diagnostics and deployment-principal access for index bootstrap. |
| `bing-grounding` | Bing Grounding resource and sensitive key retrieval. |
| `azure-monitor` | Log Analytics workspace and Application Insights, keyless by default, with optional retention and quota settings, per-table retention, workspace role assignments and a management lock. |
| `web-app` | Reusable Linux web application configuration and diagnostics. It creates a dedicated App Service plan with the AVM by default, or accepts an existing shared plan. |

Each environment root creates its resource group directly with `azurerm_resource_group`. The reusable `web-app` module uses the Azure Verified Module for App Service plans. The web application itself remains a direct AzureRM resource so sensitive Easy Auth settings can be passed through a sensitive Terraform input. The current published Foundry account, Azure AI Search, Application Insights and Log Analytics AVMs constrain AzureRM to version 4.x or `< 5.0.0`, while the environment roots use AzureRM 5.8.0 for the Foundry project API. Those resources therefore remain on provider resources in this implementation.

Foundry account and project resources share one module because the project is a child resource whose identity and connections are configured against its account. The module can also deploy only the account, add a project without a model deployment, or create the account with a model deployment and no project. Project connections are independently optional.
