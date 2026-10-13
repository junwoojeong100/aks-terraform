# Verify only the plan logic, without Azure: terraform -chdir=terraform/02-bootstrap test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_storage_account.tfstate.shared_access_key_enabled == false
    error_message = "The state storage account must disable account-key authentication (Entra ID authentication only)."
  }

  assert {
    condition     = azurerm_storage_account.tfstate.blob_properties[0].versioning_enabled
    error_message = "Blob versioning must be enabled so that state can be recovered."
  }
}
