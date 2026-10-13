output "app_identity_client_id" {
  description = "앱 UAMI 의 client ID (ServiceAccount annotation 값)"
  value       = azurerm_user_assigned_identity.app.client_id
}

output "namespace" {
  description = "데모 네임스페이스"
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "verify_command" {
  description = "Key Vault 시크릿이 파드에 마운트되었는지 확인"
  value       = "kubectl -n ${var.app_namespace} exec deploy/${local.app_name} -- cat /mnt/secrets-store/demo-secret"
}
