# Terraform Environments

Each implemented directory below this path is an independently deployable Terraform root module with its own state, inputs, outputs, prerequisites, deployment instructions, and cleanup steps.

| Environment | What it deploys |
| --- | --- |
| [foundry-basic-chat](foundry-basic-chat/README.md) | The initial proof of concept: Foundry with GPT-4.1, Azure AI Search, Bing grounding, Azure Monitor and an App Service chat UI with Easy Auth. |
| [foundry-fireworks-model-deployment](foundry-fireworks-model-deployment/README.md) | Enables Fireworks AI on the subscription and deploys DeepSeek V4.1 Flash to a Foundry account and project. |

The `foundry-agent-service` directory is reserved for the next architecture stage and contains no deployment yet. Add a root module when that architecture is in scope and needs its own state boundary, and add a row to this table.

See the [module catalogue](../modules/README.md) for the full repository design and capability boundaries.
