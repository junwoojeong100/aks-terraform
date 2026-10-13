# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/02-bootstrap test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_storage_account.tfstate.shared_access_key_enabled == false
    error_message = "state 저장소는 계정 키 인증을 꺼야 합니다 (Entra ID 인증만 사용)."
  }

  assert {
    condition     = azurerm_storage_account.tfstate.blob_properties[0].versioning_enabled
    error_message = "state 복구를 위해 Blob 버전 관리를 켜야 합니다."
  }
}
