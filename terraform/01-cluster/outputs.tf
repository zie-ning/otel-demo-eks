output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "02-addons(Load Balancer Controller)에서 사용"
  value       = module.vpc.vpc_id
}

output "kubeconfig_command" {
  description = "로컬 kubeconfig 갱신 명령"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.aws_profile}"
}
