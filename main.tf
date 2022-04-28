data "aws_iam_policy_document" "this" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.this.json
  tags               = var.tags
}

data "aws_iam_policy" "instance" {
  name = "AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "instance" {
  role       = aws_iam_role.instance.name
  policy_arn = data.aws_iam_policy.instance.arn
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-ecs-instance"
  role = aws_iam_role.instance.name
}

resource "aws_key_pair" "this" {
  key_name   = var.name
  public_key = var.public_key
}

resource "aws_launch_configuration" "this" {
  name_prefix                 = "${var.name}-"
  security_groups             = var.security_groups
  image_id                    = var.ami
  instance_type               = var.instance_type
  associate_public_ip_address = var.associate_public_ip_address
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  key_name                    = aws_key_pair.this.key_name

  user_data = <<EOF
#!/bin/bash
echo 'ECS_CLUSTER=${var.name}' >> /etc/ecs/ecs.config
echo 'ECS_DISABLE_PRIVILEGED=true' >> /etc/ecs/ecs.config
EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                 = var.name
  vpc_zone_identifier  = var.subnets
  min_size             = var.min_size
  max_size             = var.max_size
  launch_configuration = aws_launch_configuration.this.name

  lifecycle {
    ignore_changes        = [desired_capacity]
    create_before_destroy = true
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = var.name })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

resource "aws_ecs_capacity_provider" "this" {
  depends_on = [aws_autoscaling_group.this]
  name       = var.name
  tags       = var.tags

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.this.arn

    managed_scaling {
      status          = "ENABLED"
      target_capacity = var.target_capacity
    }
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.name
  tags = var.tags

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.this.name]
}

data "aws_iam_role" "task_execution" {
  name = "ecsTaskExecutionRole"
}

data "aws_iam_role" "service" {
  name = "ecsServiceRole"
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = merge([
  for s in var.services : {
  for c in s.container_definitions : "${var.name}/${s.name}/${c.name}" => {
    log_retention_days = lookup(c, "log_retention_days", 7)
  }
  }
  ]...)
  name              = "/ecs/${each.key}"
  retention_in_days = each.value.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  for_each           = {for s in var.services : s.name => s}
  family             = "${var.name}-${each.value.name}"
  execution_role_arn = data.aws_iam_role.task_execution.arn
  network_mode       = lookup(each.value, "network_mode", "bridge")
  tags               = var.tags

  dynamic "volume" {
    for_each = lookup(each.value, "volumes", [])

    content {
      name      = volume.value.name
      host_path = lookup(volume.value, "host_path", null)

      dynamic "efs_volume_configuration" {
        for_each = lookup(volume.value, "efs_volume_configuration", [])

        content {
          file_system_id          = efs_volume_configuration.value.file_system_id
          root_directory          = lookup(efs_volume_configuration.value, "root_directory", null)
          transit_encryption      = lookup(efs_volume_configuration.value, "transit_encryption", null)
          transit_encryption_port = lookup(efs_volume_configuration.value, "transit_encryption_port", null)

          dynamic "authorization_config" {
            for_each = lookup(efs_volume_configuration.value, "authorization_config", [])

            content {
              iam             = lookup(authorization_config.value, "iam_auth", null)
              access_point_id = lookup(authorization_config.value, "access_point_id", null)
            }
          }
        }
      }
    }
  }

  container_definitions = jsonencode([
  for c in each.value.container_definitions : {
    name              = c.name
    image             = c.image
    essential         = lookup(c, "essential", true)
    portMappings      = lookup(c, "portMappings", null)
    healthCheck       = lookup(c, "healthCheck", null)
    linuxParameters   = lookup(c, "linuxParameters", null)
    cpu               = c.cpu
    memoryReservation = c.memoryReservation
    environment       = lookup(c, "environment", null)
    mountPoints       = lookup(c, "mountPoints", null)
    logConfiguration : {
      "logDriver" : "awslogs",
      "options" : {
        "awslogs-region" : var.region,
        "awslogs-group" : aws_cloudwatch_log_group.this["${var.name}/${each.value.name}/${c.name}"].name,
        "awslogs-stream-prefix" : "ecs"
      }
    }
  }
  ])
}

resource "aws_ecs_service" "this" {
  depends_on                         = [aws_ecs_cluster_capacity_providers.this]
  for_each                           = {for s in var.services : s.name => s if var.create_ecs_service}
  name                               = each.value.name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this[each.value.name].arn
  deployment_minimum_healthy_percent = lookup(each.value, "deployment_minimum_healthy_percent", null)
  deployment_maximum_percent         = lookup(each.value, "deployment_maximum_percent", null)
  scheduling_strategy                = lookup(each.value, "scheduling_strategy", "REPLICA")
  health_check_grace_period_seconds  = lookup(each.value, "health_check_grace_period_seconds", null)
  iam_role                           = lookup(each.value, "load_balancers", []) != [] ? data.aws_iam_role.service.arn : null
  wait_for_steady_state              = lookup(each.value, "wait_for_steady_state", true)
  tags                               = var.tags

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  dynamic "ordered_placement_strategy" {
    for_each = lookup(each.value, "ordered_placement_strategies", [])

    content {
      field = ordered_placement_strategy.value.field
      type  = ordered_placement_strategy.value.type
    }
  }

  dynamic "load_balancer" {
    for_each = lookup(each.value, "load_balancers", [])

    content {
      target_group_arn = load_balancer.value.target_group_arn
      container_name   = load_balancer.value.container_name
      container_port   = load_balancer.value.container_port
    }
  }
}

resource "aws_appautoscaling_target" "this" {
  depends_on         = [aws_ecs_service.this]
  for_each           = {for s in var.services : s.name => s if var.create_ecs_service && lookup(s, "enable_autoscaling", true)}
  min_capacity       = lookup(each.value, "min_capacity", 1)
  max_capacity       = coalesce(lookup(each.value, "max_capacity", null), lookup(each.value, "min_capacity", 1))
  resource_id        = "service/${var.name}/${each.value.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "scale_out" {
  for_each           = {for s in var.services : s.name => s if var.create_ecs_service && lookup(s, "enable_autoscaling", true) && lookup(s, "scale_cooldown", null) != null}
  name               = "${var.name}-${each.value.name}-scale-out"
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = each.value.scale_cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "scale_in" {
  for_each           = {for s in var.services : s.name => s if var.create_ecs_service && lookup(s, "enable_autoscaling", true) && lookup(s, "scale_cooldown", null) != null}
  name               = "${var.name}-${each.value.name}-scale-in"
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = each.value.scale_cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  for_each            = {for s in var.services : s.name => s if var.create_ecs_service && lookup(s, "enable_autoscaling", true) && lookup(s, "scale_cooldown", null) != null}
  alarm_name          = "${var.name}-${each.value.name}-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  statistic           = "Maximum"
  threshold           = lookup(each.value, "max_cpu_threshold", 40)
  period              = lookup(each.value, "max_cpu_period", 60)
  evaluation_periods  = lookup(each.value, "max_cpu_evaluation_periods", 1)
  alarm_actions       = [aws_appautoscaling_policy.scale_out[each.key].arn]
  tags                = var.tags

  dimensions = {
    ClusterName = var.name
    ServiceName = aws_ecs_service.this[each.key].name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  for_each            = {for s in var.services : s.name => s if var.create_ecs_service && lookup(s, "enable_autoscaling", true) && lookup(s, "scale_cooldown", null) != null}
  alarm_name          = "${var.name}-${each.value.name}-cpu-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  statistic           = "Average"
  threshold           = lookup(each.value, "min_cpu_threshold", 10)
  period              = lookup(each.value, "min_cpu_period", 60)
  evaluation_periods  = lookup(each.value, "min_cpu_evaluation_periods", 3)
  alarm_actions       = [aws_appautoscaling_policy.scale_in[each.key].arn]
  tags                = var.tags

  dimensions = {
    ClusterName = var.name
    ServiceName = aws_ecs_service.this[each.key].name
  }
}
