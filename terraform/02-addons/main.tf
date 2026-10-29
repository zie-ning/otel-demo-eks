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
}
