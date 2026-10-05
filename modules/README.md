# Terraform Modules

This directory contains cohesive capabilities used by the Series 1 basic Microsoft Foundry chat environment.

| Module | Responsibility |
| --- | --- |
| `foundry` | Foundry account, optional project, optional model deployment, diagnostics, scoped provisioning roles and optional project connections. |
| `azure-ai-search` | Azure AI Search service, diagnostics and deployment-principal access for index bootstrap. |
| `bing-grounding` | Bing Grounding resource and sensitive key retrieval. |
| `azure-monitor` | Log Analytics workspace and Application Insights resource. |
| `web-app` | Reusable Linux web application configuration and diagnostics. It creates a dedicated App Service plan with the AVM by default, or accepts an existing shared plan. |

The environment root uses the Azure Verified Module for Resource Groups. The reusable `web-app` module uses the Azure Verified Module for App Service plans. The web application itself remains a direct AzureRM resource so sensitive Easy Auth settings can be passed through a sensitive Terraform input. The current published Foundry account, Azure AI Search, Application Insights and Log Analytics AVMs constrain AzureRM to version 4.x or `< 5.0.0`, while this root uses AzureRM 5.8.0 for the Foundry project API. Those resources therefore remain on provider resources in this implementation.

Foundry account and project resources share one module because the project is a child resource whose identity and connections are configured against its account. The module can also deploy only the account, add a project without a model deployment, or create the account with a model deployment and no project. Project connections are independently optional.
