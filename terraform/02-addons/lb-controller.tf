locals {
  lb_controller_namespace       = "kube-system"
  lb_controller_service_account = "aws-load-balancer-controller"
}

# Ingress를 보고 ALB를 만드는 컨트롤러에 필요한 IAM 권한을 Pod Identity로 부여
module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${var.project}-aws-lb-controller"

  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = local.cluster_name
      namespace       = local.lb_controller_namespace
      service_account = local.lb_controller_service_account
    }
  }
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = local.lb_controller_namespace

  values = [yamlencode({
    clusterName = local.cluster_name
    region      = var.region
    vpcId       = local.vpc_id
    serviceAccount = {
      create = true
      name   = local.lb_controller_service_account
    }
  })]

  # 권한이 연결된 뒤에 컨트롤러가 떠야 ALB 생성 시 권한 오류가 나지 않는다
  depends_on = [module.lb_controller_pod_identity]
}
