# ---------------------------------------------------------------------------
# Azure Container Registry  (Amazon ECR 에 해당)
#   - ECR 은 리전/계정 단위 레지스트리 + 리포지토리, ACR 은 "레지스트리 1개 = 로그인 서버 1개" 입니다.
#   - Private Endpoint / 방화벽 규칙 / 영역 중복은 Premium SKU 에서 제공합니다.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "Premium"

  admin_enabled            = false # 정적 admin 계정 대신 Entra ID + RBAC 사용
  anonymous_pull_enabled   = false
  zone_redundancy_enabled  = true
  retention_policy_in_days = 7 # 태그 없는(untagged) 매니페스트 자동 정리 (ECR 라이프사이클 정책과 유사)

  # 공용 엔드포인트는 "관리자 IP + 신뢰된 Azure 서비스(network_rule_bypass_option 기본값 AzureServices)" 만 허용하고 나머지는 Deny.
  # 노드/파드는 Private Endpoint 로 pull 합니다.
  # (azurerm 5.x 에서는 network_rule_set 이 중첩 속성이라 `= [{ ... }]` 형태로 작성합니다.)
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

# 레지스트리 로그인/이미지 push·pull 이벤트를 Log Analytics 로 전송 (CloudTrail data events 와 유사)
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
