output "resource_group_name" {
  description = "Cluster resource group"
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  description = "Current control plane version (including patch)"
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "Resource group where AKS created the node VMSS, load balancer, etc."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer that Workload Identity federated credentials trust"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "available_kubernetes_versions" {
  description = "Kubernetes versions supported as GA in this region"
  value       = data.azurerm_kubernetes_service_versions.current.versions
}

output "get_credentials_command" {
  description = "Command that fetches the kubeconfig and converts it to Entra ID sign-in (kubelogin) format"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
