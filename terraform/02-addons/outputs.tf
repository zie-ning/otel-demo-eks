output "lb_controller_role_arn" {
  value = module.lb_controller_pod_identity.iam_role_arn
}
