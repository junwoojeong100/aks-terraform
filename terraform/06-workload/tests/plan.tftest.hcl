# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/06-workload test
# (ephemeral 리소스는 mock provider 가 지원하지 않으므로 random 은 실제 provider 를 사용합니다. 자격 증명은 필요 없습니다.)
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}
mock_provider "time" {}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_federated_identity_credential.app.subject == "system:serviceaccount:demo:workload-sa"
    error_message = "federated credential subject 는 system:serviceaccount:<ns>:<sa> 형식이어야 합니다."
  }

  assert {
    condition     = azurerm_federated_identity_credential.app.audience == tolist(["api://AzureADTokenExchange"])
    error_message = "audience 는 api://AzureADTokenExchange 여야 합니다."
  }
}
