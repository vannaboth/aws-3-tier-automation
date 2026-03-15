resource "aws_db_subnet_group" "main" {
  name       = "${var.environment}-db-subnet-group"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "main" {
  identifier                 = "${var.environment}-db"
  engine                     = "mysql"
  engine_version             = "8.0"
  instance_class             = var.db_instance_class
  allocated_storage          = var.environment == "prod" ? 100 : 20
  storage_type               = "gp3"
  auto_minor_version_upgrade = true
  db_name                    = var.db_name
  username                   = var.db_username
  password                   = var.db_password
  db_subnet_group_name       = aws_db_subnet_group.main.name
  vpc_security_group_ids     = [var.db_sg_id]
  multi_az                   = var.environment == "prod" ? true : false
  storage_encrypted          = true
  deletion_protection        = var.environment == "prod" ? true : false
  skip_final_snapshot        = var.environment == "prod" ? false : true
  backup_retention_period    = var.environment == "prod" ? 7 : 0
}