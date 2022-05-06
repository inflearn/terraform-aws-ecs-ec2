output "cluster_id" {
  value = aws_ecs_cluster.this.id
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "task_definitions" {
  value = {for k, v in aws_ecs_task_definition.this : k => v.arn}
}

output "services" {
  value = {for k, v in aws_ecs_service.this : k => v.id}
}
