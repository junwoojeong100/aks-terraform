# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/03-network test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_subnet.aks_apiserver.delegation) == 1
    error_message = "API 서버 서브넷은 Microsoft.ContainerService/managedClusters 로 위임되어야 합니다."
  }

  assert {
    condition     = azurerm_subnet.aks_nodes.default_outbound_access_enabled == false
    error_message = "노드 서브넷은 기본 아웃바운드 IP 에 의존하지 않아야 합니다 (NAT Gateway 사용)."
  }
}

run "plan_standard_nat" {
  command = plan

  variables {
    nat_gateway_sku = "Standard"
  }

  assert {
    condition     = azurerm_nat_gateway.this.zones == toset(["1"])
    error_message = "Standard NAT Gateway 는 단일 가용 영역에 배치해야 합니다."
  }
}

run "rejects_invalid_cidr" {
  command = plan

  variables {
    subnet_cidrs = {
      aks_nodes         = "not-a-cidr"
      aks_apiserver     = "10.10.1.0/28"
      ingress           = "10.10.2.0/27"
      private_endpoints = "10.10.3.0/27"
    }
  }

  expect_failures = [var.subnet_cidrs]
}
