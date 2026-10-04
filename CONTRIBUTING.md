# Development checks

Install Git, Python, pre-commit, Terraform, TFLint, `curl` and `unzip` before working with this repository. The pinned TFLint hook downloads its binary and AzureRM ruleset on first use, so network access is also required. TFLint 0.64.0 and the AzureRM ruleset 0.32.0 are configured for consistent linting.

From the repository root, install the local Git hook and initialise the AzureRM TFLint ruleset:

```bash
pre-commit install
tflint --init
```

Run all checks manually with:

```bash
pre-commit run --all-files
```

The commit hook runs file hygiene checks and, when Terraform files are added, Terraform formatting, validation and TFLint. Formatting may update Terraform files; review and stage those changes before committing. Terraform validation and linting do not require Azure credentials. Authenticate to Azure separately for Terraform deployment operations.
