terraform {
  # S3 backend의 use_lockfile(네이티브 잠금)은 1.10부터 지원
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 부트스트랩은 state 버킷 자체를 만드는 단계이므로 로컬 state를 사용한다.
  # terraform.tfstate는 .gitignore로 커밋에서 제외한다.
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "00-bootstrap"
    }
  }
}
