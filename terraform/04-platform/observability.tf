# ---------------------------------------------------------------------------
# 관측성 (CloudWatch Logs / Amazon Managed Prometheus / Amazon Managed Grafana 에 해당)
#   - Log Analytics workspace : 로그 저장·KQL 쿼리 (CloudWatch Logs + Logs Insights)
#   - Azure Monitor workspace : Managed Prometheus 메트릭 저장소 (AMP workspace)
#   - Azure Managed Grafana   : 대시보드 (AMG)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  local_authentication_enabled = false # 공유 키 대신 Entra ID(관리 ID) 인증만 허용

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

  # Managed Prometheus 를 Grafana 데이터 소스로 자동 연결합니다.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  tags = local.tags
}

# Grafana 가 Prometheus 메트릭을 읽을 수 있도록 Monitoring Data Reader 부여
resource "azurerm_role_assignment" "grafana_reads_prometheus" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# 실습자가 Grafana 에 로그인해서 대시보드를 볼 수 있도록 Grafana Admin 부여 (grant_current_user_roles = false 이면 생략)
resource "azurerm_role_assignment" "operator_grafana_admin" {
  count = var.enable_grafana && var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_dashboard_grafana.this[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
