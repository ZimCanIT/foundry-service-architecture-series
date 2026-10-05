resource "azapi_resource" "this" {
  type                      = "Microsoft.Bing/accounts@2025-05-01-preview"
  name                      = var.name
  parent_id                 = var.resource_group_id
  location                  = "global"
  schema_validation_enabled = false

  body = {
    kind = "Bing.Grounding"
    sku = {
      name = "G1"
    }
  }

  response_export_values = ["properties.endpoint"]

  # Azure normalises tag keys to lowercase; match that in state to avoid a
  # perpetual AzAPI diff on every plan.
  tags = { for key, value in var.tags : lower(key) => value }
}

data "azapi_resource_action" "keys" {
  type        = "Microsoft.Bing/accounts@2025-05-01-preview"
  resource_id = azapi_resource.this.id
  action      = "listKeys"

  sensitive_response_export_values = ["key1"]

  depends_on = [azapi_resource.this]
}
