# ---------------------------------------------------------------------------
# Observability (equivalent to CloudWatch Logs / Amazon Managed Prometheus / Amazon Managed Grafana)
#   - Log Analytics workspace : log storage and KQL queries (CloudWatch Logs + Logs Insights)
#   - Azure Monitor workspace : Managed Prometheus metric store (AMP workspace)
#   - Azure Managed Grafana   : dashboards (AMG)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  local_authentication_enabled = false # Allow only Entra ID (managed identity) authentication instead of shared keys

  tags = local.tags
}

resource "azurerm_monitor_workspace" "this" {
  name                = module.naming.names.monitor_workspace
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_dashboard_grafana" "this" {
  count = var.enable_grafana ? 1 : 0

  name                  = module.naming.names.grafana
  location              = azurerm_resource_group.platform.location
  resource_group_name   = azurerm_resource_group.platform.name
  grafana_major_version = "13"

  api_key_enabled               = false
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  # Automatically connects Managed Prometheus as a Grafana data source.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  tags = local.tags
}

# Grant Monitoring Data Reader so Grafana can read Prometheus metrics
resource "azurerm_role_assignment" "grafana_reads_prometheus" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Grant Grafana Admin so the lab user can sign in to Grafana and view dashboards (skipped if grant_current_user_roles = false)
resource "azurerm_role_assignment" "operator_grafana_admin" {
  count = var.enable_grafana && var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_dashboard_grafana.this[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
