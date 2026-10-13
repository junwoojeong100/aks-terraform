# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/07-ingress test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}

run "plan_public_gateway" {
  command = plan

  assert {
    condition     = !contains(keys(local.gateway_spec), "infrastructure")
    error_message = "공용 Gateway 에는 infrastructure(annotation)가 없어야 합니다."
  }
}

run "plan_internal_gateway" {
  command = plan

  variables {
    internal_gateway = true
  }

  assert {
    condition     = local.gateway_spec.infrastructure.annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "내부 Gateway 는 internal LB annotation 이 있어야 합니다."
  }
}
