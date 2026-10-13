# ---------------------------------------------------------------------------
# Azure Key Vault  (close to AWS KMS + Secrets Manager + ACM combined into one service)
#   - Stores keys, secrets, and certificates
#   - Uses Azure RBAC (rbac_authorization_enabled) instead of access policies → the same approach as the IAM policy model
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

  # The public endpoint allows only "admin IPs + trusted Azure services (bypass)" and blocks everything else.
  # Pods (CSI Driver) connect through the Private Endpoint. To block trusted Azure services too, change bypass to "None".
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

# Secret/key access audit logs (AuditEvent) → Log Analytics. Equivalent to the KMS/SecretsManager events in CloudTrail.
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
