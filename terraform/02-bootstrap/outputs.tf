output "backend_hcl" {
  description = "`terraform output -raw backend_hcl > ../backend.hcl` 로 저장해 다른 스택의 partial backend 설정으로 사용합니다."
  value       = <<-EOT
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    use_azuread_auth     = true
  EOT
}

output "tfstate_storage_account_name" {
  description = "state 저장용 스토리지 계정 이름"
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_resource_group_name" {
  description = "state 저장용 리소스 그룹 이름"
  value       = azurerm_resource_group.tfstate.name
}
