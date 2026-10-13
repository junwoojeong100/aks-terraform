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

# 노드 NSG: AKS 는 서브넷에 연결한 NSG 를 수정하지 않으므로 필요한 인바운드 허용 규칙이 Terraform 에 있어야 합니다.
run "nodes_nsg_allows_overlay_and_gateway_traffic" {
  command = plan

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_nodes_to_pods.source_address_prefix == var.subnet_cidrs.aks_nodes &&
      azurerm_network_security_rule.nodes_allow_nodes_to_pods.destination_address_prefix == var.pod_cidr
    )
    error_message = "노드 서브넷 → Pod CIDR 인바운드를 허용해야 합니다 (Azure CNI Overlay 의 Service 트래픽 라우팅)."
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_pods_to_pods.source_address_prefix == var.pod_cidr &&
      azurerm_network_security_rule.nodes_allow_pods_to_pods.destination_address_prefix == var.pod_cidr
    )
    error_message = "Pod CIDR 간 인바운드를 허용해야 합니다 (나중에 Deny 규칙이 추가되어도 노드 간 Pod 통신이 끊기지 않게)."
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_apiserver.source_address_prefix == var.subnet_cidrs.aks_apiserver &&
      azurerm_network_security_rule.nodes_allow_apiserver.destination_address_prefixes == toset([var.subnet_cidrs.aks_nodes, var.pod_cidr])
    )
    error_message = "API 서버 서브넷 → 노드/Pod CIDR 인바운드를 허용해야 합니다."
  }

  assert {
    condition = (
      length(azurerm_network_security_rule.nodes_allow_gateway) == 1 &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.nodes_allow_gateway[0].destination_port_ranges == toset(["80", "443"])
    )
    error_message = "기본값(공용 Gateway)에서는 인터넷 → 80/443 인바운드를 허용해야 합니다."
  }
}

run "gateway_rule_with_multiple_cidrs" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["203.0.113.0/24", "198.51.100.10/32"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefixes == toset(["203.0.113.0/24", "198.51.100.10/32"]) &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == null
    )
    error_message = "출발지가 여러 개이면 복수 속성(source_address_prefixes)만 써야 합니다."
  }
}

run "gateway_rule_with_single_cidr" {
  command = plan

  variables {
    # 중복은 하나로 합쳐지므로 값이 1개일 때와 같이 단수 속성을 씁니다.
    gateway_allowed_source_prefixes = ["203.0.113.10/32", "203.0.113.10/32"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == "203.0.113.10/32" &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefixes == null
    )
    error_message = "출발지가 하나뿐이면 단수 속성(source_address_prefix)만 써야 합니다."
  }
}

run "no_gateway_rule_for_internal_only" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = []
  }

  assert {
    condition     = length(azurerm_network_security_rule.nodes_allow_gateway) == 0
    error_message = "gateway_allowed_source_prefixes = [] 이면 공용 Gateway 허용 규칙을 만들지 않아야 합니다."
  }
}

run "rejects_internet_tag_mixed_with_cidr" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["Internet", "203.0.113.0/24"]
  }

  expect_failures = [var.gateway_allowed_source_prefixes]
}

run "rejects_invalid_gateway_source" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["not-a-cidr"]
  }

  expect_failures = [var.gateway_allowed_source_prefixes]
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
