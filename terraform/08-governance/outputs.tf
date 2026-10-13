output "policy_assignments" {
  description = "클러스터 리소스 그룹에 할당된 정책 이름"
  value = concat(
    [for a in azurerm_resource_group_policy_assignment.pod_security : a.name],
    [for a in azurerm_resource_group_policy_assignment.cluster_config : a.name],
  )
}

output "compliance_command" {
  description = "정책 준수 상태 조회 (평가는 최초 할당 후 최대 수십 분 소요)"
  value       = "az policy state summarize --resource-group ${module.naming.names.rg_aks}"
}
