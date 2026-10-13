# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/08-governance test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "time" {}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_security_center_subscription_pricing.containers) == 0
    error_message = "기본값에서는 구독 단위 Defender 플랜을 켜지 않습니다."
  }

  assert {
    condition     = length(azurerm_resource_group_policy_assignment.pod_security) == 2
    error_message = "baseline / restricted 이니셔티브 2개가 할당되어야 합니다."
  }
}

run "plan_everything_enabled" {
  command = plan

  variables {
    enable_defender_plan  = true
    enable_resource_locks = true
    enable_budget         = true
    budget_alert_emails   = ["ops@example.com"]
    policy_effect         = "Deny"
  }

  assert {
    condition     = length(azurerm_management_lock.network) == 1 && length(azurerm_consumption_budget_subscription.workload) == 1
    error_message = "잠금과 예산이 생성되어야 합니다."
  }
}

run "budget_requires_email" {
  command = plan

  variables {
    enable_budget = true
  }

  expect_failures = [azurerm_consumption_budget_subscription.workload]
}
