variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be one of: dev, staging, prod."
  }
}

variable "vpc_id" {
  type = string
}

variable "alb_sg_id" {
  description = "ALB security group ID to allow traffic into private instances"
  type        = string
}