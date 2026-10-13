output "resource_group_name" {
  description = "Resource group for the platform shared services"
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
  description = "Managed Grafana URL (null if enable_grafana=false)"
  value       = var.enable_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "acr_name" {
  description = "ACR name"
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "ACR login server (e.g., <name>.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.this.vault_uri
}

output "aks_cluster_identity" {
  description = "Control plane UAMI name (looked up by naming convention in 05-aks)"
  value       = azurerm_user_assigned_identity.aks_cluster.name
}

output "aks_kubelet_identity" {
  description = "kubelet UAMI name (looked up by naming convention in 05-aks)"
  value       = azurerm_user_assigned_identity.aks_kubelet.name
}
