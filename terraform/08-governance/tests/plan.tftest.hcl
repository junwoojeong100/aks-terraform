# Verify only the plan logic, without Azure: terraform -chdir=terraform/08-governance test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "time" {}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_security_center_subscription_pricing.containers) == 0
    error_message = "The subscription-level Defender plan is not enabled by default."
  }

  assert {
    condition     = length(azurerm_resource_group_policy_assignment.pod_security) == 2
    error_message = "Two initiatives, baseline and restricted, must be assigned."
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
    error_message = "The lock and the budget must be created."
  }
}

run "budget_requires_email" {
  command = plan

  variables {
    enable_budget = true
  }

  expect_failures = [azurerm_consumption_budget_subscription.workload]
}
