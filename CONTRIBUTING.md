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

Every file Git detects as text uses LF line endings, in the repository and in your working copy. `.gitattributes` sets `eol=lf`, which overrides `core.autocrlf` and `core.eol`, so clones on Windows get LF as well. This keeps shell scripts runnable in bash and Azure Cloud Shell, and leaves the `mixed-line-ending` hook nothing to rewrite.

A clone made before this rule may still hold CRLF copies, shown as `w/crlf` by `git ls-files --eol`. A plain `git checkout` leaves them as they are. Commit or stash your work first, because the second command discards uncommitted changes, then run from the repository root:

```bash
git rm --cached -r -q .
git reset --hard
```

## Continuous integration

The `Checks` workflow (`.github/workflows/checks.yml`) runs on pull requests into `main`, on pushes to `main`, every Monday at 06:23 UTC and on demand. No job needs Azure access. On Mondays only the `secrets` job and the module tests run. Tool versions are pinned in the workflow.

- `pre-commit`: runs `pre-commit run --all-files`, then actionlint 1.7.12 and zizmor 1.30.1 on the workflows in `.github/`.
- `secrets`: scans the Git history with Betterleaks 1.9.0. A pull request scans its own commits, a push scans the commits it adds (the whole history for a new branch), and the Monday and manual runs scan the whole history. Findings are redacted, and no secret is checked against a live service.
- `module tests (pinned providers)`: runs `terraform init`, `validate` and `test` on each module under `modules/`, using the provider versions in the lock file of `environments/foundry-fireworks-model-deployment`.
- `module tests (latest providers)`: runs the same steps with the newest provider versions that the constraints allow. This job is advisory on pull requests, so a failure is reported but does not block a merge. On the Monday run it fails, so a breaking provider release is reported.
- `branch name`: pull requests only. The branch is named `<type>/<topic>`, where the type is one of the commit types below and the topic is lower-case words joined by hyphens, for example `feat/module-test-runner` or `fix/fireworks-model-name`. Dependabot branches are exempt.
- `commit messages`: pull requests only. commitlint checks each commit in the pull request against the Conventional Commits preset and `.commitlintrc.yml`. The allowed types are `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style` and `test`. The first line, type included, is 72 characters or fewer. Merge commits are ignored, and pull requests that Dependabot opens skip this check.
- `terraform docs`: fails when the generated section of a module README (between the `BEGIN_TF_DOCS` and `END_TF_DOCS` markers) is out of date. To refresh one, run `terraform-docs -c .terraform-docs.yml modules/<name>` from the repository root.
- `branch protection`: checks that `main` has the deletion, non-fast-forward, pull request and required status check rules. The workflow token cannot read repository settings, so automatic deletion of merged branches is not checked here.

To run the module tests locally, from the repository root:

```bash
python scripts/shared/module_tests.py --providers pinned --lock-from environments/foundry-fireworks-model-deployment
python scripts/shared/module_tests.py --providers latest
```

To run actionlint and zizmor locally, from the repository root. On Git Bash for Windows, prefix each command with `MSYS_NO_PATHCONV=1`:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/zizmorcore/zizmor:1.30.1 --offline --no-progress .github/
```

The local zizmor run is offline, so it skips the online audits that CI runs with its token.
