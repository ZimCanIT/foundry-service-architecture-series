# Terraform Environments

Each implemented directory below this path is an independently deployable Terraform root module with its own state, inputs, outputs, prerequisites, deployment instructions, and cleanup steps.

The [Foundry basic chat](foundry-basic-chat/README.md) environment is the initial proof of concept. The `foundry-agent-service` directory is reserved for the next architecture stage and contains no deployment yet. Add a root module when that architecture is in scope and needs its own state boundary.

See the [module catalogue](../modules/README.md) for the full repository design and capability boundaries.
