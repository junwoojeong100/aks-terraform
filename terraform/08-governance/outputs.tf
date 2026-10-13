output "policy_assignments" {
  description = "Names of the policies assigned to the cluster resource group"
  value = concat(
    [for a in azurerm_resource_group_policy_assignment.pod_security : a.name],
    [for a in azurerm_resource_group_policy_assignment.cluster_config : a.name],
  )
}

output "compliance_command" {
  description = "Query the policy compliance state (the initial evaluation can take up to tens of minutes after assignment)"
  value       = "az policy state summarize --resource-group ${module.naming.names.rg_aks}"
}
