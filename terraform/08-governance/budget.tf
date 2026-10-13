# ---------------------------------------------------------------------------
# Budget alerts (equivalent to AWS Budgets)
# Tracks only the cost of resources whose workload tag matches, across the whole subscription. Resources in the
# AKS node resource group inherit the cluster tags, so they are counted too.
# ---------------------------------------------------------------------------
resource "time_static" "budget_start" {}

locals {
  # The budget start date must be "00:00Z on the 1st of the current month". It is pinned to the month of the first creation.
  budget_start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", time_static.budget_start.rfc3339)
}

resource "azurerm_consumption_budget_subscription" "workload" {
  count = var.enable_budget ? 1 : 0

  name            = "budget-${module.naming.base}"
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  filter {
    tag {
      name   = "workload"
      values = [var.workload]
    }
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  lifecycle {
    precondition {
      condition     = length(var.budget_alert_emails) > 0
      error_message = "If enable_budget = true, specify at least one email address in budget_alert_emails."
    }
  }
}
