# Optional vault for the Fireworks API key. Terraform never creates the secret, because AzureRM
# keeps azurerm_key_vault_secret values in plain text in state; set_fireworks_secret.py writes it.

# Recreated when the vault is turned off and on, so a soft-deleted name is not reused.
resource "random_string" "key_vault_suffix" {
  count = var.key_vault.enabled ? 1 : 0

  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  # Shorter than local.regional_name because Key Vault names are 3 to 24 characters and globally unique.
  # The fixed parts are known at plan time, unlike the random suffix, so the length check uses them:
  # "kv-" + stem + "-" + environment + "-" + region_code + "-" + five-character suffix.
  key_vault_name_stem   = "${var.key_vault.name_stem}-${var.environment}-${var.region_code}"
  key_vault_name_length = length(local.key_vault_name_stem) + 9
  key_vault_name        = var.key_vault.enabled ? "kv-${var.key_vault.name_stem}-${var.environment}-${var.region_code}-${random_string.key_vault_suffix[0].result}" : null
}

resource "azurerm_key_vault" "fireworks" {
  count = var.key_vault.enabled ? 1 : 0

  name                       = local.key_vault_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = var.key_vault.soft_delete_retention_days
  purge_protection_enabled   = var.key_vault.purge_protection_enabled
  tags                       = local.tags

  lifecycle {
    precondition {
      condition     = local.key_vault_name_length <= 24 && !strcontains(local.key_vault_name_stem, "--")
      error_message = "The Key Vault name kv-${local.key_vault_name_stem}-<suffix> would be ${local.key_vault_name_length} characters; the limit is 24 with no consecutive hyphens. Shorten key_vault.name_stem, environment or region_code."
    }
  }
}

# Owner and Contributor do not reach secret values on an RBAC vault.
resource "azurerm_role_assignment" "key_vault_secrets_officer" {
  count = var.key_vault.enabled ? 1 : 0

  scope                = azurerm_key_vault.fireworks[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
  principal_type       = "User"
}

# Logs every read of the secret to the workspace.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count = var.key_vault.enabled ? 1 : 0

  name                       = "kv-audit-to-law"
  target_resource_id         = azurerm_key_vault.fireworks[0].id
  log_analytics_workspace_id = module.azure_monitor.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
}
