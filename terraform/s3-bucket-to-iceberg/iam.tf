data "aws_caller_identity" "current" {}

# Trust policy — allows the Glue service to assume this role
data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job" {
  name               = "${var.project_name}-glue-job"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json

  tags = {
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "glue_job" {
  # Read raw CSV files from the source bucket
  statement {
    sid    = "ReadSource"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.source.arn,
      "${aws_s3_bucket.source.arn}/*",
    ]
  }

  # Read and write Iceberg table data to the bronze bucket
  statement {
    sid    = "ReadWriteBronze"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.bronze.arn,
      "${aws_s3_bucket.bronze.arn}/*",
    ]
  }

  # Read the Python script at job startup
  statement {
    sid    = "ReadGlueScripts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.glue_scripts.arn,
      "${aws_s3_bucket.glue_scripts.arn}/*",
    ]
  }

  # Read and write offloaded `terms` text objects (claim-check pattern)
  statement {
    sid    = "ReadWriteTerms"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.terms.arn,
      "${aws_s3_bucket.terms.arn}/*",
    ]
  }

  # Manage Iceberg table metadata in the Glue catalog
  statement {
    sid    = "GlueCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.lake.name}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.lake.name}/*",
    ]
  }

  # Write job logs to CloudWatch for debugging
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue_job" {
  name   = "glue-job-policy"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job.json
}

# Redshift assumes this role to read Iceberg metadata from the Glue catalog and
# data/metadata files from the bronze bucket through Redshift Spectrum.
data "aws_iam_policy_document" "redshift_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift_spectrum" {
  name               = "${var.project_name}-redshift-spectrum"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume.json

  tags = {
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "redshift_spectrum" {
  statement {
    sid    = "ReadBronzeIcebergFiles"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.bronze.arn]
  }

  statement {
    sid       = "ReadBronzeIcebergObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bronze.arn}/*"]
  }

  statement {
    sid    = "ReadGlueCatalog"
    effect = "Allow"
    actions = [
      "glue:BatchGetPartition",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.lake.name}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.lake.name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "redshift_spectrum" {
  name   = "redshift-spectrum-read-lake"
  role   = aws_iam_role.redshift_spectrum.id
  policy = data.aws_iam_policy_document.redshift_spectrum.json
}
