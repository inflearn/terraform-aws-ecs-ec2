variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnets" {
  type = list(string)
}

variable "security_groups" {
  type    = list(string)
  default = []
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "public_key" {
  type = string
}

variable "ami" {
  type = string
}

variable "associate_public_ip_address" {
  type    = bool
  default = false
}

variable "instance_type" {
  type = string
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 1
}

variable "target_capacity" {
  type    = number
  default = 90
}

variable "enable_container_insights" {
  type    = bool
  default = true
}

variable "create_ecs_service" {
  type    = bool
  default = true
}

variable "task_role_arn" {
  type    = string
  default = null
}

variable "services" {
  type    = any
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
