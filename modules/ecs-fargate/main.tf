terraform {
  required_version = ">= 0.12"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE ECS SERVICE AND ITS TASK DEFINITION
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_ecs_service" "ecs_fargate_without_lb" {
  count = var.is_associated_with_lb ? 0 : 1

  name            = var.service_name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = var.number_of_tasks
  launch_type     = "FARGATE"

  network_configuration {
    # subnets implicitly provide to ECS service the AZs
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }
}

resource "aws_ecs_service" "ecs_fargate_with_lb" {
  count = var.is_associated_with_lb ? 1 : 0

  name            = var.service_name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = var.number_of_tasks
  launch_type     = "FARGATE"

  network_configuration {
    # subnets implicitly provide to ECS service the AZs
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }

  # By depending on the null_resource, this resource effectively depends on the ALB existing.
  # cf https://github.com/hashicorp/terraform/issues/12634#issuecomment-371555338
  depends_on = [null_resource.alb_exists]

  load_balancer {
    target_group_arn = aws_lb_target_group.service[0].arn
    container_name   = local.container_name
    container_port   = local.container_port
  }
}

resource "aws_ecs_task_definition" "task" {
  family             = var.service_name
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = data.template_file.container_definitions.rendered

  requires_compatibilities = ["FARGATE"]

  # Fargate launch type requires the mode "awsvpc"
  network_mode = "awsvpc"

  # cpu & memory are required with Fargate
  cpu    = var.cpu
  memory = var.memory
}

# TODO do we need to do something like this https://github.com/blinkist/terraform-aws-airship-ecs-service/blob/master/modules/ecs_container_definition/outputs.tf !? I don't think so for the moment maybe if we want to support multiple containers
data "template_file" "container_definitions" {
  template = file("${path.module}/container-definitions.json")

  vars = {
    container_name = local.container_name
    image          = "${var.image}:${var.image_version}"
    # Fargate launch type requires the mode "awsvpc"
    network_mode          = "awsvpc"
    environment           = "[${join(",", data.template_file.env_vars.*.rendered)}]"
    container_port        = local.container_port
    host_port             = local.container_port
    protocol              = "tcp"
    awslogs_group         = var.cloudwatch_log_group
    awslogs_region        = var.aws_region
    awslogs_stream_prefix = var.service_name
  }
  # container cpu & memory values are not specify here because only one container per task is currently supported
  # and this container can used all the task cpu & memory values (TaskDefinition arguments) 
}

data "template_file" "env_vars" {
  count = length(var.env_vars)

  template = <<EOF
{
  "name": "${element(keys(var.env_vars), count.index)}",
  "value": "${var.env_vars[element(keys(var.env_vars), count.index)]}"
}
EOF

}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE IAM POLICY DOCUMENT FOR THE TRUST RELATIONSHIP OF THE TASK & EXECUTION ROLES
# IT LETS FARGATE ASSUME THE ROLE
# ---------------------------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assume-role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE ECS TASK EXECUTION ROLE AND ATTACH APPROPRIATE AWS MANAGED POLICY
# The task execution role allow the ECS Container Agent associated to the task to: 
# - pull the container image(s) from Amazon ECR.
# - use the awslogs log driver.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${var.service_name}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume-role.json
  # following error can be seen in the ECS service events. But it is not fatal, the task launch successfully a bit later without doing anything.
  #   service <service_name> failed to launch a task with (error ECS was unable to assume the role '<role_arn>' that was provided for this task.
  #   Please verify that the role being passed has the proper trust relationship and permissions and that your IAM user has permissions to pass this role.).
  # maybe we can avoid this non-fatal "issue", by following this workaround (found in a simular issue https://github.com/terraform-providers/terraform-provider-aws/issues/3972)
  #
  # AWS returns success for IAM change but change is not yet available for a few seconds. Sleep to miss the race condition failure.
  # provisioner "local-exec" {
  #   interpreter = ["bash", "-c"]
  #   command = "sleep 30"
  # }
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE ECS TASK ROLE THAT ALLOWS TO DEFINE APPLICATION LEVEL PERMISSIONS 
# The task role allow the ECS Task/Container to call AWS APIs (for example, read objects from an S3 bucket)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.service_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.assume-role.json
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE ECS SERVICE SECURITY GROUP AND ITS ASSOCIATED RULES
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "service" {
  name = var.service_name

  // TODO add a description to avoid default "Managed by Terraform"
  vpc_id = var.vpc_id
}

# Allow all outbound traffic
resource "aws_security_group_rule" "allow_all_outbound" {
  security_group_id = aws_security_group.service.id

  type        = "egress"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "allow_inbound_cidr_blocks" {
  count = length(var.allowed_inbound_cidr_blocks) >= 1 ? 1 : 0

  security_group_id = aws_security_group.service.id

  type        = "ingress"
  from_port   = var.inbound_port
  to_port     = var.inbound_port
  protocol    = "tcp"
  cidr_blocks = var.allowed_inbound_cidr_blocks
}

resource "aws_security_group_rule" "allow_inbound_security_groups" {
  count = length(var.allowed_inbound_security_group_ids)

  security_group_id = aws_security_group.service.id

  type                     = "ingress"
  from_port                = var.inbound_port
  to_port                  = var.inbound_port
  protocol                 = "tcp"
  source_security_group_id = element(var.allowed_inbound_security_group_ids, count.index)
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE THE LOAD BALANCER TARGET GROUP
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_lb_target_group" "service" {
  count = var.is_associated_with_lb ? 1 : 0

  name = var.service_name

  # this port is required but it is not the one that will be actually used. The effective port is provided by Docker dynamically.
  # see https://stackoverflow.com/questions/42715647/whats-the-target-group-port-for-when-using-application-load-balancer-ec2-con#comment96712548_42823808
  port = 80

  # ALB support HTTP & HTTPS. FYI NLB, not yet supported by this module, support TCP
  # HTTP is what is currently supported.
  # For HTTPS between the ALB & the container, we need a self-signed certificate and the app must support HTTPS.
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # By depending on the null_resource, this resource effectively depends on the ALB existing.
  # cf https://github.com/hashicorp/terraform/issues/12634#issuecomment-371555338
  depends_on = [null_resource.alb_exists]
}

resource "null_resource" "alb_exists" {
  triggers = {
    alb_name = var.lb_arn
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# LOCALS VARIABLES
# ---------------------------------------------------------------------------------------------------------------------

locals {
  container_name = var.service_name
  container_port = var.inbound_port
}

