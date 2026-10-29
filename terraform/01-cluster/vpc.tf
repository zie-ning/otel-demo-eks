# NAT Gateway 비용을 없애기 위해 퍼블릭 서브넷만 사용한다.
# 노드는 퍼블릭 IP로 이미지를 받고, 외부 인바운드는 보안 그룹으로 막는다.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.project
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  # AWS Load Balancer Controller가 인터넷용 ALB를 배치할 서브넷을 찾는 태그
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
