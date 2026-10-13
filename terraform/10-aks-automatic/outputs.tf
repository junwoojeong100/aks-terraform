output "cluster_name" {
  description = "AKS Automatic 클러스터 이름"
  value       = azurerm_kubernetes_automatic_cluster.this.name
}

output "resource_group_name" {
  description = "클러스터 리소스 그룹"
  value       = azurerm_resource_group.automatic.name
}

output "kubernetes_version" {
  description = "현재 Kubernetes 버전 (AKS 가 stable 채널로 자동 관리)"
  value       = azurerm_kubernetes_automatic_cluster.this.current_kubernetes_version
}

output "get_credentials_command" {
  description = "kubeconfig 받기 + kubelogin 변환"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.automatic.name} --name ${azurerm_kubernetes_automatic_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
