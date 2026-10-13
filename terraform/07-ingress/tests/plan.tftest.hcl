# Verify only the plan logic, without Azure: terraform -chdir=terraform/07-ingress test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}

run "plan_public_gateway" {
  command = plan

  assert {
    condition     = !contains(keys(local.gateway_spec), "infrastructure")
    error_message = "A public Gateway must not have infrastructure (annotations)."
  }
}

run "plan_internal_gateway" {
  command = plan

  variables {
    internal_gateway = true
  }

  assert {
    condition     = local.gateway_spec.infrastructure.annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "An internal Gateway must have the internal LB annotation."
  }
}
