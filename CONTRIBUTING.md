# Development checks

Install Git, Python, pre-commit, Terraform and TFLint before working with this repository. TFLint 0.64.0 and the AzureRM ruleset 0.32.0 are configured for consistent linting. The TFLint hook runs the `tflint` on your `PATH` and does not download it, so install 0.64.0 first, for example on Windows with `winget install --id TerraformLinters.tflint --version 0.64.0`. `tflint --init` downloads the AzureRM ruleset, which needs network access.

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
