module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.project
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  # 퍼블릭 엔드포인트는 본인 IP만 허용한다.
  # 노드는 퍼블릭 서브넷에 있지만 프라이빗 엔드포인트로 API 서버에 붙으므로
  # 노드의 퍼블릭 IP를 허용 목록에 넣을 필요가 없다.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs
  endpoint_private_access      = true

  # terraform을 실행한 IAM 사용자에게 클러스터 관리자 권한 부여
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # 자주 생성·삭제하는 클러스터라 비용과 잔여 리소스를 만드는 항목은 끈다.
  # - 컨트롤 플레인 로그(CloudWatch 과금)
  # - 시크릿 암호화용 KMS 키(삭제 대기 기간 동안 키가 남음). EKS 기본 암호화로 대체
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null

  addons = {
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  # 앱과 관측 스택을 다른 노드에 두어, 앱 장애가 관측 도구까지 번지지 않게 한다
  eks_managed_node_groups = {
    app = merge(local.node_group_defaults, {
      min_size     = 1
      max_size     = var.app_node_count + 1
      desired_size = var.app_node_count

      labels = {
        role = "app"
      }
    })

    # 관측 스택 전용. taint를 견디는 toleration이 있는 파드만 올라간다
    monitoring = merge(local.node_group_defaults, {
      min_size     = 1
      max_size     = var.monitoring_node_count + 1
      desired_size = var.monitoring_node_count

      labels = {
        role = "monitoring"
      }

      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "monitoring"
          effect = "NO_SCHEDULE"
        }
      }
    })
  }
}

locals {
  node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = var.node_instance_types
    capacity_type  = "ON_DEMAND"

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = var.node_disk_size_gb
          volume_type           = "gp3"
          delete_on_termination = true
        }
      }
    }
  }
}
