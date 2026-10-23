resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${local.regional_name}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "fwbyowlora"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.budget.alert_email_addresses
    content {
      name                    = "budget-${index(sort(tolist(var.budget.alert_email_addresses)), email_receiver.value) + 1}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# Backstop for the hourly PTU meter: budgets are evaluated daily, so the PTU gate and the stop
# plan are the controls. The deployments depend on this resource, so it exists before the meter starts.
resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "bud-${local.regional_name}"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.budget.amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget.start_date
    end_date   = var.budget.end_date
  }

  dynamic "notification" {
    for_each = var.budget.actual_thresholds
    content {
      enabled        = true
      threshold      = notification.value
      threshold_type = "Actual"
      operator       = "GreaterThanOrEqualTo"
      contact_groups = [azurerm_monitor_action_group.this.id]
    }
  }

  dynamic "notification" {
    for_each = var.budget.forecasted_thresholds
    content {
      enabled        = true
      threshold      = notification.value
      threshold_type = "Forecasted"
      operator       = "GreaterThanOrEqualTo"
      contact_groups = [azurerm_monitor_action_group.this.id]
    }
  }
}
