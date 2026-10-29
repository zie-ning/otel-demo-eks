# 클러스터를 끄지 않아 비용이 쌓이는 사고를 막기 위한 월 예산 알림
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 무료 플랜 크레딧이 비용을 상쇄하면 알림이 오지 않으므로 크레딧 차감 전 금액으로 계산
  cost_types {
    include_credit = false
  }

  # 실제 비용 50% 도달 (기본값 기준 $20)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # 실제 비용 100% 도달 (기본값 기준 $40)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # 이번 달 예상 비용이 상한을 넘을 것으로 보일 때 미리 알림
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
