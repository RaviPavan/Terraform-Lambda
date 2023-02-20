################
# Creating resource variable
################


variable "function_name_s3_notification" {}
variable "function_name_sqs_processor" {}
variable "handler_name" {}
variable "runtime" {}
variable "timeout" {}
variable brightdata_bucket_name {}
variable lambda_role_name {}
variable file_name_s3_notification_to_sqs {}
variable file_name_sqs_to_webhook {}
variable sqs_queue_for_dl {}
variable sqs_queue_main {}

###############
# fetching current account id
###############
data "aws_caller_identity" "current" {}
#######
#role - this role is used by lambda function
######


data "aws_iam_policy_document" "policy_doc_for_lambda" {
  # https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html#events-sqs-queueconfig
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    #resources = [aws_sqs_queue.terraform_queue.arn]
  }
}



resource "aws_iam_role" "lambda_role_name" {
  name = var.lambda_role_name
  assume_role_policy = data.aws_iam_policy_document.policy_doc_for_lambda.json
}


###############
# Creating Lambda resource
################
resource "aws_lambda_function" "test_lambda" {
  function_name = var.function_name_s3_notification
  role          = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.lambda_role_name}"
  handler       = "lambda_function.lambda_handler"
  runtime       = var.runtime
  timeout       = var.timeout

  filename = var.file_name_s3_notification_to_sqs
  source_code_hash = filebase64sha256(var.file_name_s3_notification_to_sqs)


  environment {
    variables = {
    CreatedBy = "Terraform" 
    queue_url= aws_sqs_queue.terraform_queue.url}
  }
   depends_on = [
    aws_sqs_queue.terraform_queue
  ]
}


##################
# Creating s3 resource for invoking to lambda function
##################
resource "aws_s3_bucket" "brightdata_bucket" {
  bucket = var.brightdata_bucket_name
  acl    = "private"
  tags = {
    Name        = "Brightdata bucket"
    Environment = "Dev"
  }
}
##################
# Adding S3 bucket as trigger to my lambda and giving the permissions
##################
resource "aws_s3_bucket_notification" "aws-lambda-trigger" {
  bucket = aws_s3_bucket.brightdata_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.test_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    #filter_prefix       = "file-prefix"
    #filter_suffix       = "file-extension"
  }
}
resource "aws_lambda_permission" "test" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.test_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = "arn:aws:s3:::${aws_s3_bucket.brightdata_bucket.id}"
}


###########
# SQS queue 1
###########
resource "aws_sqs_queue" "terraform_queue_dlq" {
  name                      = var.sqs_queue_for_dl
  delay_seconds             = 90
  max_message_size          = 2048
  message_retention_seconds = 86400
  receive_wait_time_seconds = 10


}


###########
# SQS queue 1
###########
resource "aws_sqs_queue" "terraform_queue" {
  name                      = var.sqs_queue_main
  delay_seconds             = 90
  max_message_size          = 2048
  message_retention_seconds = 86400
  visibility_timeout_seconds = 900
  receive_wait_time_seconds = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.terraform_queue_dlq.arn
    maxReceiveCount     = 4
  })

  tags = {
    Environment = "dev"
  }
}

###############
# Creating Lambda resource for sqs
################
resource "aws_lambda_function" "s3_notification_to_sqs" {
  function_name = var.function_name_sqs_processor
  role          = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.lambda_role_name}"
  handler       = "lambda_function.lambda_handler"
  runtime       = var.runtime
  timeout       = var.timeout

  filename = var.file_name_sqs_to_webhook
  source_code_hash = filebase64sha256(var.file_name_sqs_to_webhook)


  environment {
    variables = {
    CreatedBy = "Terraform" }
  }
}

data "aws_iam_policy_document" "policy_doc" {
  # https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html#events-sqs-queueconfig
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:SendMessage"
    ]
    resources = [aws_sqs_queue.terraform_queue.arn]
  }
}


resource "aws_iam_policy" "sqs_policy" {
  name="sqs_policy"
  policy      = data.aws_iam_policy_document.policy_doc.json
  description = "Grant the Lambda function the required SQS permissions."
}


resource "aws_iam_role_policy_attachment" "sqs_role_policy" {
  policy_arn = aws_iam_policy.sqs_policy.arn
  role       = var.lambda_role_name
}

data "aws_iam_policy" "LambdaBasicExecution" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "cw_policy" {
  policy_arn = data.aws_iam_policy.LambdaBasicExecution.arn
  role       = var.lambda_role_name
}

##################
# Adding S3 bucket as trigger to my lambda and giving the permissions
##################

resource "aws_lambda_event_source_mapping" "aws-lambda-trigger-sqs" {
  event_source_arn = aws_sqs_queue.terraform_queue.arn
  enabled          = true
  function_name    = aws_lambda_function.s3_notification_to_sqs.arn
  batch_size       = 1

  depends_on = [
    aws_iam_role_policy_attachment.sqs_role_policy
  ]
}


###########
# output of lambda arn
###########
output "arn" {
  value = aws_lambda_function.test_lambda.arn
}