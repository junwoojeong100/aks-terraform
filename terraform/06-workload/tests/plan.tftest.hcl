# Verify only the plan logic, without Azure: terraform -chdir=terraform/06-workload test
# (The mock provider does not support ephemeral resources, so random uses the real provider. No credentials are needed.)
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}
mock_provider "time" {}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_federated_identity_credential.app.subject == "system:serviceaccount:demo:workload-sa"
    error_message = "The federated credential subject must have the format system:serviceaccount:<ns>:<sa>."
  }

  assert {
    condition     = azurerm_federated_identity_credential.app.audience == tolist(["api://AzureADTokenExchange"])
    error_message = "The audience must be api://AzureADTokenExchange."
  }
}
