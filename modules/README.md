# Terraform Modules

This directory contains only the module boundaries needed by the initial Microsoft Foundry basic chat implementation. Each directory contains a `.gitkeep` marker so Git tracks the structure; no Terraform configuration is included.

| Module | Basic architecture responsibility |
| --- | --- |
| `foundry-account` | Foundry resource, model deployment, account diagnostics, and account-level access. |
| `foundry-project` | Foundry project and identity, including its Bing Grounding and Application Insights connections. |
| `bing-grounding` | Bing Grounding resource used by the prompt agent. |
| `observability` | Log Analytics workspace, Application Insights resource, and shared telemetry foundation. |
| `chat-web-app` | App Service plan and web app, workload identity, application settings, diagnostics, and the app identity's Foundry access. |

Connections are kept with `foundry-project` because the basic implementation has one project and its connections are configured as part of that project. Add another module boundary only when a later implementation demonstrates a cohesive capability that needs separate ownership or reuse.
