# Terraform Modules

This directory is the catalogue of reusable Terraform capabilities for the Microsoft Foundry series. Modules are composed by independent roots under `environments/`; they do not own state and do not call sibling modules.

The directory names mark the intended capability boundaries for the whole repo. Empty directories contain only `.gitkeep` and are architecture placeholders, not implemented modules. Implement a module when its first environment or lab needs it. Series 1 uses only the modules required by `environments/series-1/basic-chat`.

| Module | Capability boundary | First intended series |
| --- | --- | --- |
| `foundry-account` | Foundry resource, model deployments, account diagnostics, and account-level access. | 1 |
| `foundry-project` | Foundry project and its project identity. | 1 |
| `foundry-connections` | Explicit connections from a project to knowledge, tools, and telemetry resources. | 1 |
| `bing-grounding` | Bing Grounding resource and project integration. | 1 |
| `chat-web-app` | App Service chat UI, workload identity, configuration, and required Foundry access. | 1 |
| `observability` | Log Analytics, Application Insights, diagnostic settings, and reusable telemetry foundations. | 1 |
| `agent-service-dependencies` | Customer-managed Search, Storage, Cosmos DB, and identity dependencies for agent service deployments. | 2 |
| `hosted-agent-workload` | Hosted agent runtime configuration and customer-owned identity, networking, and telemetry. | 2 |
| `agent-tool-hosting` | Governed hosting boundary for agent tools, including authentication, ingress, and diagnostics. | 2 |
| `mcp-server-workload` | MCP server hosting and its identity, ingress, egress, and logging boundaries. | 2 |
| `private-networking` | Private Foundry connectivity, workload subnets, private endpoints, and DNS integration. | 3 |
| `controlled-egress` | Firewall, routes, allow rules, and egress diagnostics. | 3 |
| `ai-gateway-apim` | API Management gateway configuration for Foundry authentication, routing, quotas, and policy. | 1 |
| `identity-and-rbac` | Reusable workload identity and least-privilege role assignment patterns. | 2 |
| `policy-governance` | Azure Policy definitions or assignments and platform guardrails. | 3 |
| `knowledge-grounding` | Enterprise knowledge resources and integration boundaries for retrieval and Foundry IQ scenarios. | 2 |
| `agent-state-store` | Customer-managed state and memory resources with retention and access boundaries. | 2 |
| `voice-agent-workload` | Azure infrastructure around a Voice Live application. | 2 |
| `coding-agent-sandbox` | Isolated execution environment and controls for coding agents. | 2 |
| `cost-controls` | Budgets, alerts, and resource-level cost guardrails. | 4 |
| `regional-resilience` | Multi-region workload composition and traffic distribution. | 1 |
| `disaster-recovery` | Recovery resources and configuration for application, data, and agent dependencies. | 1 |

A video does not necessarily need a new module or environment. Keep benchmarking harnesses, prompt evaluation code, application logic, and other non-infrastructure assets outside Terraform modules. Add a module only when it packages a cohesive Azure capability that is reused or has a clear owner-managed lifecycle.
