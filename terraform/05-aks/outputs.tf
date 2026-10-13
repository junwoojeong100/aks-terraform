output "resource_group_name" {
  description = "클러스터 리소스 그룹"
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "AKS 클러스터 이름"
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS 클러스터 리소스 ID"
  value       = azurerm_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  description = "현재 컨트롤 플레인 버전 (patch 포함)"
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "AKS 가 노드 VMSS/로드밸런서 등을 만든 리소스 그룹"
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "Workload Identity 의 federated credential 이 신뢰할 OIDC issuer"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "available_kubernetes_versions" {
  description = "이 리전에서 GA 로 지원되는 Kubernetes 버전"
  value       = data.azurerm_kubernetes_service_versions.current.versions
}

output "get_credentials_command" {
  description = "kubeconfig 를 받아 Entra ID 로그인(kubelogin) 형식으로 변환하는 명령"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
