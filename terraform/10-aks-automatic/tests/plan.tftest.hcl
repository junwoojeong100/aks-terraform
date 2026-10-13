# Verify only the plan logic, without Azure: terraform -chdir=terraform/10-aks-automatic test
mock_provider "azurerm" {
  source = "../mocks"
}

variables {
  allowed_ip_ranges = ["203.0.113.10/32"]
}

run "plan_managed_vnet" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_network.byo) == 0
    error_message = "The default (managed VNet) does not create a VNet."
  }
}

run "plan_group_admin_only" {
  command = plan

  variables {
    grant_current_user_admin = false
    admin_principal_ids      = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 1 && length(azurerm_role_assignment.cluster_user) == 1
    error_message = "With the automatic grant to the current user turned off, only the one specified group must be an admin."
  }
}

run "rejects_cluster_without_admin" {
  command = plan

  variables {
    grant_current_user_admin = false
  }

  expect_failures = [var.grant_current_user_admin]
}

run "plan_byo_vnet" {
  command = plan

  variables {
    use_byo_network = true
  }

  assert {
    condition     = length(azurerm_subnet.api_server) == 1 && azurerm_subnet.api_server[0].address_prefixes[0] == "10.20.0.0/28"
    error_message = "The API server subnet must be a /28."
  }
}
