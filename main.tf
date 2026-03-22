terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {
    bucket       = "dev-terrraform-state"
    key          = "3tier/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

module "vpc" {
  source             = "./modules/vpc"
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  database_subnets   = var.database_subnets
}

module "security_groups" {
  source      = "./modules/security_groups"
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  alb_sg_id   = module.vpc.alb_sg_id
}

module "ec2_instances" {
  source             = "./modules/ec2"
  environment        = var.environment
  private_subnet_ids = module.vpc.private_subnet_ids
  target_group_arns  = [module.vpc.target_group_arn]
  security_group_ids = [module.security_groups.private_sg_id]
  instance_type      = var.instance_type
  min_size           = var.min_size
  max_size           = var.max_size
  desired_capacity   = var.desired_capacity
}

module "database" {
  source             = "./modules/rds"
  environment        = var.environment
  private_subnet_ids = module.vpc.database_subnet_ids
  db_sg_id           = module.security_groups.db_sg_id
  db_instance_class  = var.db_instance_class
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
}