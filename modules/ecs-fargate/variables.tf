# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------

# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY

# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED PARAMETERS
# You must provide a value for each of these parameters.
# ---------------------------------------------------------------------------------------------------------------------

variable "aws_region" {
}

variable "service_name" {
}

variable "vpc_id" {
}

variable "subnet_ids" {
  type        = list(string)
}

variable "cluster_arn" {
}

variable "allowed_inbound_cidr_blocks" {
  type        = list(string)
  default     = []
}

variable "allowed_inbound_security_group_ids" {
  type        = list(string)
}

variable "image" {
}

variable "image_version" {
}

variable "cpu" {
}

variable "memory" {
}

variable "number_of_tasks" {
}

variable "inbound_port" {
}

variable "cloudwatch_log_group" {
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These parameters have reasonable defaults.
# ---------------------------------------------------------------------------------------------------------------------

variable "assign_public_ip" {
  default = false
}

variable "is_associated_with_lb" {
  default = false
}

variable "lb_arn" {
  default = ""
}

variable "env_vars" {
  type    = map(string)
  default = {}
}
