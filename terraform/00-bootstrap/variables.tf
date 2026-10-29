variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "로컬 AWS CLI 프로필 이름"
  type        = string
  default     = "terraform-admin"
}

variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "otel-demo"
}

variable "monthly_budget_usd" {
  description = "월 예산 상한(USD). 50%와 100% 도달 시 알림"
  type        = number
  default     = 40
}

variable "budget_alert_email" {
  description = "예산 알림을 받을 이메일 주소 (terraform.tfvars에서 지정)"
  type        = string
}
