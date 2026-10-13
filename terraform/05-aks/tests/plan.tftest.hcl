# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/05-aks test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "azapi" {}

variables {
  allowed_ip_ranges = ["203.0.113.10/32"]
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "userAssignedNATGateway"
    error_message = "아웃바운드는 BYO NAT Gateway 여야 합니다."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "로컬 계정(정적 kubeconfig)은 비활성화해야 합니다."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 0
    error_message = "기본값에서는 Spot 풀이 없어야 합니다."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 1
    error_message = "기본값에서는 Gateway API 를 활성화해야 합니다."
  }
}

run "plan_private_cluster_with_options" {
  command = plan

  variables {
    enable_private_cluster = true
    enable_spot_pool       = true
    enable_defender        = true
    enable_gateway_api     = false
    sku_tier               = "Premium"
    admin_principal_ids    = ["11111111-1111-1111-1111-111111111111"]
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 1
    error_message = "Spot 풀이 생성되어야 합니다."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 0
    error_message = "enable_gateway_api=false 이면 azapi 업데이트가 없어야 합니다."
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 2
    error_message = "추가 관리자 1명 + 현재 사용자 = 2개의 역할 할당이어야 합니다."
  }
}

run "plan_group_admin_only" {
  command = plan

  variables {
    grant_current_user_admin = false
    admin_principal_ids      = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 1
    error_message = "현재 사용자 자동 부여를 끄면 지정한 그룹 1개만 관리자여야 합니다."
  }
}

run "rejects_cluster_without_admin" {
  command = plan

  variables {
    grant_current_user_admin = false
  }

  expect_failures = [var.grant_current_user_admin]
}

run "rejects_malformed_version" {
  command = plan

  variables {
    kubernetes_version = "v1.36"
  }

  expect_failures = [var.kubernetes_version]
}
