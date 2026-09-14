# Glue catalog database — the metadata store where Iceberg tables are registered.
# Once the job runs, you can query the table here via Athena.
resource "aws_glue_catalog_database" "lake" {
  name        = replace("${var.project_name}_${random_id.suffix.hex}", "-", "_")
  description = "Medallion architecture data catalog — bronze layer Iceberg tables"
}

# Upload the Python ETL script to S3 so Glue can fetch it at job startup
resource "aws_s3_object" "source_to_bronze" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/source_to_bronze.py"
  source = "${path.module}/scripts/source_to_bronze.py"
  etag   = filemd5("${path.module}/scripts/source_to_bronze.py")
}

# Glue ETL job — reads CSVs from source, writes Iceberg to bronze
resource "aws_glue_job" "source_to_bronze" {
  name         = "${var.project_name}-source-to-bronze"
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/source_to_bronze.py"
    python_version  = "3"
  }

  worker_type       = var.worker_type
  number_of_workers = var.num_workers

  default_arguments = {
    # Enable Iceberg support in Glue 4.0
    "--datalake-formats" = "iceberg"

    # Job parameters — these are available inside source_to_bronze.py via getResolvedOptions
    # Iceberg catalog settings are configured directly in the Python script via SparkConf
    "--source_bucket"  = aws_s3_bucket.source.bucket
    "--bronze_bucket"  = aws_s3_bucket.bronze.bucket
    "--database_name"  = aws_glue_catalog_database.lake.name
    "--table_name"     = var.table_name

    # Standard Glue settings
    "--job-language"               = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"             = "true"
  }

  tags = {
    Project = var.project_name
    Layer   = "bronze"
  }
}

# On-demand trigger — start this manually via the AWS console or CLI:
#   aws glue start-trigger --name <trigger_name> --profile pluralsight
resource "aws_glue_trigger" "source_to_bronze" {
  name = "${var.project_name}-source-to-bronze-trigger"
  type = "ON_DEMAND"

  actions {
    job_name = aws_glue_job.source_to_bronze.name
  }

  tags = {
    Project = var.project_name
  }
}
