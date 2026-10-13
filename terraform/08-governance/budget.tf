# ---------------------------------------------------------------------------
# 예산 알림 (AWS Budgets 에 해당)
# 구독 전체에서 workload 태그가 일치하는 비용만 추적합니다. AKS 노드 리소스 그룹의 리소스도
# 클러스터 태그를 상속하므로 함께 집계됩니다.
# ---------------------------------------------------------------------------
resource "time_static" "budget_start" {}

locals {
  # 예산 시작일은 "이번 달 1일 00:00Z" 여야 합니다. 최초 생성 시점의 달로 고정합니다.
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
      error_message = "enable_budget = true 이면 budget_alert_emails 에 이메일을 1개 이상 지정하세요."
    }
  }
}
