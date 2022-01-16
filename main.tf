locals {
  envyml = yamldecode(file("env.yml"))
}

data "external" "function_names" {
  program = ["sh", "-c", "aws lambda list-functions --query 'Functions[].FunctionName' --region ${local.envyml.project_region} --output json --profile ${local.envyml.profile_name} | jq 'INDEX(.)'"]
}

resource "aws_sns_topic" "alarm_topic" {
  name = "${local.envyml.project_name}-alarm-topic"
}

module "metric_alarms" {
  source = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarms-by-multiple-dimensions"

  alarm_name          = "${local.envyml.project_name}-lambda-alarms"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1
  period              = 60

  namespace     = "AWS/Lambda"
  metric_name   = "Errors"
  statistic     = "Maximum"
  dimensions    = { for idx, f in keys(data.external.function_names.result) : "${local.envyml.project_name}-alarm-${f}" => { "FunctionName" = f } }
  alarm_actions = [aws_sns_topic.alarm_topic.arn]
}


resource "aws_iam_role" "chatbot_role" {
  name = "${local.envyml.project_name}-chatbot-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "chatbot.amazonaws.com"
        }
      },
    ]
  })

  inline_policy {
    name = "${local.envyml.project_name}-chatbot-role-inline-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "cloudwatch:Describe*",
            "cloudwatch:Get*",
            "cloudwatch:List*",
            "logs:StopQuery",
            "logs:StartQuery",
            "logs:GetQueryResults",
            "logs:DescribeLogGroups",
          ]
          Effect   = "Allow"
          Resource = "*"
        },
      ]
    })
  }
}


resource "aws_cloudformation_stack" "network" {
  name          = local.envyml.project_name
  capabilities  = ["CAPABILITY_NAMED_IAM"]
  template_body = <<-STACK
  Resources:
    ChatbotConfiguration:
      Type: AWS::Chatbot::SlackChannelConfiguration
      Properties:
        ConfigurationName: "${local.envyml.project_name}"
        IamRoleArn: "${aws_iam_role.chatbot_role.arn}"
        SlackChannelId: "${local.envyml.slack_channel_id}"
        SlackWorkspaceId: "${local.envyml.slack_workspace_id}"
        SnsTopicArns: 
          - "${aws_sns_topic.alarm_topic.arn}"
  STACK
}
