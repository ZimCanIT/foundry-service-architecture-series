config {
  call_module_type = "all"
}

plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Auto-heal recycle thresholds need workload latency and traffic data. A generic
# threshold can interrupt legitimate long-running model requests in this PoC.
rule "azurerm_app_service_missing_auto_heal_setting" {
  enabled = false
}
