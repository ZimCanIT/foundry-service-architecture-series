# Development checks

Install Git, Python, pre-commit, Terraform, TFLint, `curl` and `unzip` before working with this repository. TFLint 0.64.0 and the AzureRM ruleset 0.32.0 are configured for consistent linting. The TFLint hook uses a `tflint` already on your `PATH`. If none is found, it downloads 0.64.0 on first use, which needs network access. The download step does not work on Windows, so Windows contributors should install 0.64.0 first, for example with `winget install --id TerraformLinters.tflint --version 0.64.0`.

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
