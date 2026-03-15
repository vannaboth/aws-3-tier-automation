output "asg_name" {
  value = aws_autoscaling_group.main.name
}

output "asg_arn" {
  value = aws_autoscaling_group.main.arn
}

output "launch_template_id" {
  value = aws_launch_template.main.id
}