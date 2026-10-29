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

variable "kubernetes_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "사용할 가용 영역 (EKS는 최소 2개 필요)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "admin_cidrs" {
  description = "EKS API 엔드포인트에 접근을 허용할 CIDR 목록 (본인 공인 IP/32, terraform.tfvars에서 지정)"
  type        = list(string)
}

variable "node_instance_types" {
  description = "워커 노드 인스턴스 타입. 계정이 AWS 무료 플랜이라 프리티어 대상 타입만 실행 가능 (2 vCPU / 8GB)"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "app_node_count" {
  description = "앱 노드그룹 노드 수"
  type        = number
  default     = 2
}

variable "monitoring_node_count" {
  description = "모니터링 노드그룹 노드 수"
  type        = number
  default     = 1
}

variable "node_disk_size_gb" {
  description = "워커 노드 루트 볼륨 크기(GB). 데모와 관측 스택 이미지가 많아 기본값 20GB보다 크게 잡는다"
  type        = number
  default     = 50
}
