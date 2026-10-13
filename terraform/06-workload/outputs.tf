output "app_identity_client_id" {
  description = "Client ID of the app UAMI (value for the ServiceAccount annotation)"
  value       = azurerm_user_assigned_identity.app.client_id
}

output "namespace" {
  description = "Demo namespace"
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "verify_command" {
  description = "Check that the Key Vault secret is mounted in the pod"
  value       = "kubectl -n ${var.app_namespace} exec deploy/${local.app_name} -- cat /mnt/secrets-store/demo-secret"
}
