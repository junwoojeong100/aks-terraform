# ---------------------------------------------------------------------------
# Azure Key Vault  (AWS KMS + Secrets Manager + ACM 을 한 서비스로 합친 것에 가깝습니다)
#   - 키(Key) / 시크릿(Secret) / 인증서(Certificate) 를 모두 보관
#   - Access policy 대신 Azure RBAC(rbac_authorization_enabled) 사용 → IAM 정책 모델과 동일한 방식
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                = module.naming.names.key_vault
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = 7

  # 공용 엔드포인트는 "관리자 IP + 신뢰된 Azure 서비스(bypass)" 만 허용하고 나머지는 차단합니다.
  # 파드(CSI Driver)는 Private Endpoint 로 접근합니다. 신뢰된 Azure 서비스까지 막으려면 bypass = "None" 으로 바꾸세요.
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = local.key_vault_ip_rules
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${module.naming.names.key_vault}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-key-vault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.key_vault.id]
  }

  tags = local.tags
}

# 시크릿/키 접근 감사 로그 (AuditEvent) → Log Analytics. CloudTrail 의 KMS/SecretsManager 이벤트에 해당.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
