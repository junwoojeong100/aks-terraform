# ---------------------------------------------------------------------------
# Azure Container Registry  (equivalent to Amazon ECR)
#   - ECR is a per-region/per-account registry plus repositories, while ACR is "one registry = one login server".
#   - Private Endpoint / firewall rules / zone redundancy are available in the Premium SKU.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "Premium"

  admin_enabled            = false # Use Entra ID + RBAC instead of a static admin account
  anonymous_pull_enabled   = false
  zone_redundancy_enabled  = true
  retention_policy_in_days = 7 # Automatically clean up untagged manifests (similar to ECR lifecycle policies)

  # The public endpoint allows only "admin IPs + trusted Azure services (network_rule_bypass_option defaults to
  # AzureServices)" and denies everything else. Nodes/pods pull through the Private Endpoint.
  # (In azurerm 5.x, network_rule_set is a nested attribute, so it is written as `= [{ ... }]`.)
  public_network_access_enabled = true

  network_rule_set = [{
    default_action = "Deny"
    ip_rule = [for cidr in var.allowed_ip_ranges : {
      action   = "Allow"
      ip_range = cidr
    }]
  }]

  tags = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${module.naming.names.acr}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.acr.id]
  }

  tags = local.tags
}

# Send registry login and image push/pull events to Log Analytics (similar to CloudTrail data events)
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
