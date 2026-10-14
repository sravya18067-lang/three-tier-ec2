variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "three-tier"
}

variable "admin_cidr" {
  description = "The ONLY IP/CIDR allowed to SSH in, e.g. 203.0.113.25/32"
  type        = string
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "key_name" {
  description = "Name of an EXISTING EC2 key pair in the chosen region"
  type        = string
}

variable "db_password" {
  description = "PostgreSQL password (letters and digits only, min 12 chars)"
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[A-Za-z0-9]{12,}$", var.db_password))
    error_message = "db_password must be alphanumeric and at least 12 characters."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "public_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}
