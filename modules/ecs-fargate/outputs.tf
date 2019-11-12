output "target_group_arn" {
  value = element(concat(aws_lb_target_group.service.*.arn, [""]), 0)
}

output "task_iam_role_id" {
  value = aws_iam_role.task.id
}

