# lambda_text_udf.tf
#
# Backs the Redshift external function gold.get_text_from_s3(s3_uri) with a
# small, fast Lambda that fetches a single offloaded `terms` object's text
# from S3 (see s3.tf's `terms` bucket, keys `terms/{id}.txt`) and returns it
# inline in SQL. Two guardrails live inside the Lambda itself
# (scripts/get_text_from_s3/handler.py):
#   1. Batch-row-count cap (text_udf_max_batch_rows) — Lambda only ever sees
#      one invocation batch at a time, so this approximates "query-level"
#      bulk detection using num_records of that batch.
#   2. Per-object size cap (text_udf_max_object_bytes) — protects against any
#      single oversized document regardless of batch size.
# Both return a human-readable message in the row's result slot instead of
# failing the query, since these results are read directly by non-technical
# analysts in a SQL result cell.
#
# This function is for single/few-record inline retrieval only, not bulk
# export — see the SQL comment above the CREATE EXTERNAL FUNCTION statement
# below.

# ---------------------------------------------------------------------------
# Lambda function code
# ---------------------------------------------------------------------------
data "archive_file" "get_text_from_s3" {
  type        = "zip"
  source_file = "${path.module}/scripts/get_text_from_s3/handler.py"
  output_path = "${path.module}/scripts/get_text_from_s3/handler.zip"
}

# Explicit log group (rather than letting Lambda create one implicitly) so
# the execution role's logging permissions can be scoped to this exact ARN
# instead of a wildcard across all log groups.
resource "aws_cloudwatch_log_group" "get_text_from_s3" {
  name              = "/aws/lambda/${var.text_udf_lambda_function_name}"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Lambda execution role — least privilege: read-only access to the terms
# offload objects this function is allowed to fetch, plus logging scoped to
# its own log group.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_text_udf_exec" {
  name               = "${var.project_name}-get-text-from-s3-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "lambda_text_udf_exec" {
  # Only read access, only to the terms-offload prefix this function needs.
  statement {
    sid       = "ReadTermsObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.terms.arn}/terms/*"]
  }

  statement {
    sid       = "CreateOwnLogGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.text_udf_lambda_function_name}"]
  }

  statement {
    sid    = "WriteOwnLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.text_udf_lambda_function_name}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_text_udf_exec" {
  name   = "get-text-from-s3-exec-policy"
  role   = aws_iam_role.lambda_text_udf_exec.id
  policy = data.aws_iam_policy_document.lambda_text_udf_exec.json
}

# ---------------------------------------------------------------------------
# Lambda function — fast, low-memory config; no heavy compute happens here.
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "get_text_from_s3" {
  function_name = var.text_udf_lambda_function_name
  role          = aws_iam_role.lambda_text_udf_exec.arn

  filename         = data.archive_file.get_text_from_s3.output_path
  source_code_hash = data.archive_file.get_text_from_s3.output_base64sha256

  runtime = "python3.12"
  handler = "handler.lambda_handler"

  memory_size = 128
  timeout     = 10

  environment {
    variables = {
      MAX_BATCH_ROWS   = tostring(var.text_udf_max_batch_rows)
      MAX_OBJECT_BYTES = tostring(var.text_udf_max_object_bytes)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.get_text_from_s3,
    aws_iam_role_policy.lambda_text_udf_exec,
  ]

  tags = {
    Project = var.project_name
    Layer   = "gold"
  }
}

# ---------------------------------------------------------------------------
# Separate IAM role Redshift assumes to invoke this Lambda. Reuses the same
# redshift.amazonaws.com trust policy already defined for Spectrum
# (data.aws_iam_policy_document.redshift_assume in redshift.tf), but with a
# permissions policy scoped to lambda:InvokeFunction on this one function's
# ARN only — this role has no S3/Glue/Spectrum access.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "redshift_lambda_invoke" {
  name               = "${var.project_name}-redshift-lambda-invoke"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume.json

  tags = {
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "redshift_lambda_invoke" {
  statement {
    sid       = "InvokeGetTextFromS3Only"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.get_text_from_s3.arn]
  }
}

resource "aws_iam_role_policy" "redshift_lambda_invoke" {
  name   = "redshift-invoke-get-text-from-s3"
  role   = aws_iam_role.redshift_lambda_invoke.id
  policy = data.aws_iam_policy_document.redshift_lambda_invoke.json
}

# IAM propagation buffer before Redshift registers/uses the external
# function, matching the pattern already used for the Spectrum and
# EventBridge roles elsewhere in this project.
resource "time_sleep" "wait_for_redshift_lambda_invoke_role" {
  depends_on      = [aws_iam_role_policy.redshift_lambda_invoke, aws_redshift_cluster.spectrum]
  create_duration = "30s"
}

# ---------------------------------------------------------------------------
# Register the external function. gold schema must already exist
# (create_gold_schema in redshift.tf).
# ---------------------------------------------------------------------------
resource "aws_redshiftdata_statement" "create_get_text_from_s3_function" {
  cluster_identifier = aws_redshift_cluster.spectrum.cluster_identifier
  database           = aws_redshift_cluster.spectrum.database_name
  secret_arn         = aws_redshift_cluster.spectrum.master_password_secret_arn
  statement_name     = "${var.project_name}-create-get-text-from-s3-function"

  sql = <<-SQL
    -- get_text_from_s3: single/few-record inline retrieval only, NOT for bulk
    -- export. Each call is a separate Lambda invocation; querying this
    -- across large unfiltered result sets will exhaust Redshift query slots
    -- and Lambda concurrency. The Lambda enforces a hard cap (default
    -- ${var.text_udf_max_batch_rows} rows per invocation batch) and a
    -- per-object size cap (default ${var.text_udf_max_object_bytes} bytes),
    -- returning a clear message in the result cell instead of failing the
    -- query when either is exceeded. Recommended usage:
    --   SELECT id, ${var.gold_schema_name}.get_text_from_s3(terms) AS full_text
    --   FROM ${var.gold_schema_name}.${var.gold_table_name}
    --   WHERE id IN ('1', '2', '3');
    CREATE OR REPLACE EXTERNAL FUNCTION ${var.gold_schema_name}.get_text_from_s3(s3_uri VARCHAR)
    RETURNS VARCHAR
    STABLE
    LAMBDA '${aws_lambda_function.get_text_from_s3.function_name}'
    IAM_ROLE '${aws_iam_role.redshift_lambda_invoke.arn}';
  SQL

  depends_on = [
    aws_redshiftdata_statement.create_gold_schema,
    time_sleep.wait_for_redshift_lambda_invoke_role,
  ]
}
