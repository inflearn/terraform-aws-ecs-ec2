terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.10.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

module "vpc" {
  source         = "git::ssh://git@github.com/inflearn/terraform-aws-vpc.git?ref=v3.14.0"
  name           = "example-inflab-ecs-ec2"
  cidr           = "10.0.0.0/16"
  azs            = ["ap-northeast-2a", "ap-northeast-2c"]
  public_subnets = ["10.0.0.0/24", "10.0.1.0/24"]

  tags = {
    iac  = "terraform"
    temp = "true"
  }
}

module "security_group_alb" {
  source              = "git::ssh://git@github.com/inflearn/terraform-aws-security-group.git?ref=v4.9.0"
  name                = "example-inflab-ecs-ec2-alb"
  description         = "Security group terraform example elasticache"
  vpc_id              = module.vpc.vpc_id
  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules        = ["all-all"]
  egress_cidr_blocks  = ["0.0.0.0/0"]
}

module "security_group_ecs" {
  source      = "git::ssh://git@github.com/inflearn/terraform-aws-security-group.git?ref=v4.9.0"
  name        = "example-inflab-ecs-ec2-ecs"
  description = "Security group terraform example elasticache"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 32768
      to_port                  = 65535
      protocol                 = 6
      description              = "HTTP from ALB"
      source_security_group_id = module.security_group_alb.security_group_id
    },
  ]
  egress_rules       = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]
}

module "alb" {
  source = "git::ssh://git@github.com/inflearn/terraform-aws-alb.git?ref=v6.9.0"

  name               = "example-inflab-ecs-ec2"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.security_group_alb.security_group_id]

  target_groups = [
    {
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    iac  = "terraform"
    temp = "true"
  }
}

module "ecs" {
  source                      = "../../"
  name                        = "example-inflab-ecs-ec2"
  vpc_id                      = module.vpc.vpc_id
  subnet_ids                  = module.vpc.public_subnets
  region                      = "ap-northeast-2"
  ami                         = "ami-0ddef7b72b2854433"
  instance_type               = "t3a.micro"
  public_key                  = ""
  security_groups             = [module.security_group_ecs.security_group_id]
  min_size                    = 1
  max_size                    = 1
  target_capacity             = 90
  associate_public_ip_address = true
  enable_container_insights   = true

  services = [
    {
      name                               = "example-service"
      network_mode                       = "bridge"
      deployment_minimum_healthy_percent = 100
      deployment_maximum_percent         = 200
      scheduling_strategy                = "REPLICA"
      health_check_grace_period_seconds  = 30
      wait_for_steady_state              = true
      ordered_placement_strategies       = [
        {
          type  = "binpack"
          field = "cpu"
        }
      ]
      load_balancers = [
        {
          target_group_arn = module.alb.target_group_arns[0]
          container_name   = "example-container"
          container_port   = 80
        }
      ]
      volumes = [
        {
          name      = "example-volume"
          host_path = "/tmp/example-volume"
        }
      ]
      container_definitions = [
        {
          name               = "example-container"
          log_retention_days = 731
          image              = "nginx:latest"
          essential          = true
          portMappings       = [
            {
              containerPort = 80
              hostPort      = 0
              protocol      = "tcp"
            }
          ]
          healthCheck = {
            command  = ["CMD-SHELL", "curl -f -LI http://localhost/"]
            interval = 30
            timeout  = 5
            retries  = 3
          }
          linuxParameters = {
            capabilities = {
              add  = []
              drop = []
            }
          }
          cpu               = 2048
          memoryReservation = 900
          environment       = [
            {
              name  = "TEST_ENV"
              value = "test"
            }
          ]
          mountPoints = [
            {
              sourceVolume  = "example-volume"
              containerPath = "/example-volume"
              readOnly      = false
            }
          ]

        }
      ]
    }
  ]

  tags = {
    iac  = "terraform"
    temp = "true"
  }
}
