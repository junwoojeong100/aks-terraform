# Test the plan logic only, without Azure: terraform -chdir=terraform/05-aks test
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
    error_message = "Outbound must use the BYO NAT Gateway."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "Local accounts (static kubeconfig) must be disabled."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 0
    error_message = "With the defaults, there must be no Spot pool."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 1
    error_message = "With the defaults, Gateway API must be enabled."
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
    error_message = "A Spot pool must be created."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 0
    error_message = "With enable_gateway_api=false, there must be no azapi update."
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 2
    error_message = "There must be 2 role assignments: 1 additional admin + the current user."
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
    error_message = "With the automatic grant to the current user turned off, only the 1 specified group must be an admin."
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
