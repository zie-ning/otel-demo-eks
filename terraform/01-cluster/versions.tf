terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 00-bootstrap에서 만든 버킷에 state 저장. use_lockfile로 S3 네이티브 잠금 사용
  backend "s3" {
    bucket       = "otel-demo-tfstate-520426835144"
    key          = "01-cluster/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "terraform-admin"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "01-cluster"
    }
  }
}
