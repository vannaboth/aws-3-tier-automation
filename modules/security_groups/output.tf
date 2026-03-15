output "public_sg_id" {
  value = aws_security_group.public.id
}

output "private_sg_id" {
  value = aws_security_group.private.id
}

output "db_sg_id" {
  value = aws_security_group.database.id
}