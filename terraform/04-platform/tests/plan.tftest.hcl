# Verify only the plan logic, without Azure: terraform -chdir=terraform/04-platform test
mock_provider "azurerm" {
  source = "../mocks"
}

variables {
  allowed_ip_ranges = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].ip_rules == toset(["203.0.113.10", "198.51.100.0/24"])
    error_message = "/32 in the Key Vault IP rules must be converted to a single IP."
  }

  assert {
    condition     = azurerm_container_registry.this.sku == "Premium"
    error_message = "ACR must be Premium to use a Private Endpoint."
  }
}

run "plan_without_grafana" {
  command = plan

  variables {
    enable_grafana = false
  }

  assert {
    condition     = length(azurerm_dashboard_grafana.this) == 0
    error_message = "If enable_grafana=false, Grafana must not be created."
  }
}

run "plan_without_operator_roles" {
  command = plan

  variables {
    grant_current_user_roles = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator_acr_push) == 0 && length(azurerm_role_assignment.operator_grafana_admin) == 0
    error_message = "If grant_current_user_roles=false, the ACR/Grafana roles must not be granted to the principal running Terraform."
  }
}

run "rejects_empty_ip_list" {
  command = plan

  variables {
    allowed_ip_ranges = []
  }

  expect_failures = [var.allowed_ip_ranges]
}
