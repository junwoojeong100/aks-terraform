output "backend_hcl" {
  description = "Save with `terraform output -raw backend_hcl > ../backend.hcl` and use it as the partial backend configuration of the other stacks."
  value       = <<-EOT
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    use_azuread_auth     = true
  EOT
}

output "tfstate_storage_account_name" {
  description = "Name of the storage account that holds state"
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_resource_group_name" {
  description = "Name of the resource group for state storage"
  value       = azurerm_resource_group.tfstate.name
}
