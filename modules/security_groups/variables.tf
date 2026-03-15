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

variable "vpc_cidr" {
  type = string
}