output "cluster_name" {
  description = "AKS Automatic cluster name"
  value       = azurerm_kubernetes_automatic_cluster.this.name
}

output "resource_group_name" {
  description = "Cluster resource group"
  value       = azurerm_resource_group.automatic.name
}

output "kubernetes_version" {
  description = "Current Kubernetes version (managed automatically by AKS through the stable channel)"
  value       = azurerm_kubernetes_automatic_cluster.this.current_kubernetes_version
}

output "get_credentials_command" {
  description = "Get the kubeconfig and convert it for kubelogin"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.automatic.name} --name ${azurerm_kubernetes_automatic_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
