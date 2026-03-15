output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  value = aws_subnet.database[*].id
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "nlb_dns_name" {
  value = aws_lb.network.dns_name
}

output "nlb_arn" {
  value = aws_lb.network.arn
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.main[*].id
}

output "nlb_public_ips" {
  value = aws_eip.nlb[*].public_ip
}