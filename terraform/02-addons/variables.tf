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

variable "lb_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm 차트 버전"
  type        = string
  default     = "3.6.2"
}
