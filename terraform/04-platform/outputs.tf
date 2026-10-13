output "resource_group_name" {
  description = "플랫폼 공용 서비스 리소스 그룹"
  value       = azurerm_resource_group.platform.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID"
  value       = azurerm_log_analytics_workspace.this.id
}

output "monitor_workspace_id" {
  description = "Azure Monitor workspace(Managed Prometheus) ID"
  value       = azurerm_monitor_workspace.this.id
}

output "grafana_endpoint" {
  description = "Managed Grafana URL (enable_grafana=false 이면 null)"
  value       = var.enable_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "acr_name" {
  description = "ACR 이름"
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "ACR 로그인 서버 (예: <name>.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_name" {
  description = "Key Vault 이름"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.this.vault_uri
}

output "aks_cluster_identity" {
  description = "컨트롤 플레인 UAMI 이름 (05-aks 에서 이름 규칙으로 조회)"
  value       = azurerm_user_assigned_identity.aks_cluster.name
}

output "aks_kubelet_identity" {
  description = "kubelet UAMI 이름 (05-aks 에서 이름 규칙으로 조회)"
  value       = azurerm_user_assigned_identity.aks_kubelet.name
}
