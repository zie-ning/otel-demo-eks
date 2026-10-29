output "tfstate_bucket" {
  description = "01-cluster, 02-addons의 S3 backend에 지정할 버킷 이름"
  value       = aws_s3_bucket.tfstate.bucket
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}
