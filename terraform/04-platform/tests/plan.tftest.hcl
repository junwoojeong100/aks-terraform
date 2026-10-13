# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/04-platform test
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
    error_message = "Key Vault IP 규칙에서 /32 는 단일 IP 로 변환되어야 합니다."
  }

  assert {
    condition     = azurerm_container_registry.this.sku == "Premium"
    error_message = "Private Endpoint 를 쓰려면 ACR 은 Premium 이어야 합니다."
  }
}

run "plan_without_grafana" {
  command = plan

  variables {
    enable_grafana = false
  }

  assert {
    condition     = length(azurerm_dashboard_grafana.this) == 0
    error_message = "enable_grafana=false 이면 Grafana 를 만들지 않아야 합니다."
  }
}

run "plan_without_operator_roles" {
  command = plan

  variables {
    grant_current_user_roles = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator_acr_push) == 0 && length(azurerm_role_assignment.operator_grafana_admin) == 0
    error_message = "grant_current_user_roles=false 이면 실행 주체에게 ACR/Grafana 역할을 부여하지 않아야 합니다."
  }
}

run "rejects_empty_ip_list" {
  command = plan

  variables {
    allowed_ip_ranges = []
  }

  expect_failures = [var.allowed_ip_ranges]
}
