# Terraform Environments

Each implemented directory below this path is an independently deployable Terraform root module with its own state key, inputs, outputs, prerequisites, deployment instructions, and cleanup steps.

Series 1 contains exactly one environment: [basic Microsoft Foundry chat](series-1/basic-chat/README.md). The `.gitkeep` markers in later series directories reserve the series boundaries without implying that deployments have been implemented. Add a root module when a later architecture requires a distinct deployment and state boundary.

See the [module catalogue](../modules/README.md) for the full repository design and capability boundaries.
