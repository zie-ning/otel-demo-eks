# 01-cluster의 출력값(클러스터 이름, VPC ID)을 S3 state에서 읽는다
data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket  = "otel-demo-tfstate-520426835144"
    key     = "01-cluster/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile
  }
}

locals {
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name
  vpc_id       = data.terraform_remote_state.cluster.outputs.vpc_id
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# kubectl top, HPA에 필요한 리소스 메트릭 제공 (EKS 관리형 애드온)
resource "aws_eks_addon" "metrics_server" {
  cluster_name = local.cluster_name
  addon_name   = "metrics-server"

  # LB Controller는 Service 변경을 검사하는 웹훅(mservice.elbv2.k8s.aws)을 등록한다.
  # 동시에 만들면 웹훅 파드가 뜨기 전에 metrics-server의 Service 생성이 거부되어 CREATE_FAILED가 된다(2026-11-01).
  # helm_release는 기본값(wait = true)으로 파드가 준비될 때까지 기다리므로 그 뒤에 만든다
  depends_on = [helm_release.lb_controller]
}
