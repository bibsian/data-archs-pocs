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
    "--source_bucket" = aws_s3_bucket.source.bucket
    "--bronze_bucket" = aws_s3_bucket.bronze.bucket
    "--database_name" = aws_glue_catalog_database.lake.name
    "--table_name"    = var.table_name

    # Standard Glue settings
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
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

# Upload the offload ETL script to S3 so Glue can fetch it at job startup
resource "aws_s3_object" "source_to_bronze_offload" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/source_to_bronze_offload.py"
  source = "${path.module}/scripts/source_to_bronze_offload.py"
  etag   = filemd5("${path.module}/scripts/source_to_bronze_offload.py")
}

# Glue ETL job — reads CSVs from source, offloads `terms` text to the terms
# bucket (claim-check pattern), and writes the pointer-flattened rows as
# Iceberg to bronze. Additive alongside source_to_bronze — separate job,
# separate table, original pipeline untouched.
resource "aws_glue_job" "source_to_bronze_offload" {
  name         = "${var.project_name}-source-to-bronze-offload"
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/source_to_bronze_offload.py"
    python_version  = "3"
  }

  worker_type       = var.worker_type
  number_of_workers = var.num_workers

  default_arguments = {
    # Enable Iceberg support in Glue 4.0
    "--datalake-formats" = "iceberg"

    # Job parameters — these are available inside source_to_bronze_offload.py via getResolvedOptions
    # Iceberg catalog settings are configured directly in the Python script via SparkConf
    "--source_bucket" = aws_s3_bucket.source.bucket
    "--bronze_bucket" = aws_s3_bucket.bronze.bucket
    "--terms_bucket"  = aws_s3_bucket.terms.bucket
    "--database_name" = aws_glue_catalog_database.lake.name
    "--table_name"    = var.offload_table_name

    # Standard Glue settings
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }

  tags = {
    Project = var.project_name
    Layer   = "bronze"
  }
}

# On-demand trigger — start this manually via the AWS console or CLI:
#   aws glue start-trigger --name <trigger_name> --profile pluralsight
resource "aws_glue_trigger" "source_to_bronze_offload" {
  name = "${var.project_name}-source-to-bronze-offload-trigger"
  type = "ON_DEMAND"

  actions {
    job_name = aws_glue_job.source_to_bronze_offload.name
  }

  tags = {
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Silver layer — validates raw_data_with_pointers and splits it into a
# clean silver table plus a quarantine table of rows that failed DQ checks.
# ---------------------------------------------------------------------------

# Shared, extensible DQ check framework — shipped to the job via
# --extra-py-files so bronze_to_silver.py can `import dq_checks`.
resource "aws_s3_object" "dq_checks" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/dq_checks.py"
  source = "${path.module}/scripts/dq_checks.py"
  etag   = filemd5("${path.module}/scripts/dq_checks.py")
}

# Declarative DQ rule config — which checks run and on which columns. Edit
# this file (no script/job changes needed) to add, remove, or retarget checks.
resource "aws_s3_object" "dq_rules_config" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/config/dq_rules.json"
  source = "${path.module}/scripts/config/dq_rules.json"
  etag   = filemd5("${path.module}/scripts/config/dq_rules.json")
}

# Upload the bronze -> silver ETL script to S3 so Glue can fetch it at job startup
resource "aws_s3_object" "bronze_to_silver" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/bronze_to_silver.py"
  source = "${path.module}/scripts/bronze_to_silver.py"
  etag   = filemd5("${path.module}/scripts/bronze_to_silver.py")
}

# Glue ETL job — reads the bronze Iceberg table, runs the configured DQ
# checks, and writes silver + silver-quarantine Iceberg tables.
resource "aws_glue_job" "bronze_to_silver" {
  name         = "${var.project_name}-bronze-to-silver"
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/bronze_to_silver.py"
    python_version  = "3"
  }

  worker_type       = var.worker_type
  number_of_workers = var.num_workers

  default_arguments = {
    # Enable Iceberg support in Glue 4.0
    "--datalake-formats" = "iceberg"

    # Ship the shared DQ-check module alongside the job script
    "--extra-py-files" = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/dq_checks.py"

    # Job parameters — available inside bronze_to_silver.py via getResolvedOptions
    "--database_name"                = aws_glue_catalog_database.lake.name
    "--bronze_table_name"            = var.offload_table_name
    "--silver_bucket"                = aws_s3_bucket.silver.bucket
    "--silver_table_name"            = var.silver_table_name
    "--silver_quarantine_table_name" = var.silver_quarantine_table_name
    "--dq_config_s3_path"            = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/config/dq_rules.json"

    # Standard Glue settings
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }

  tags = {
    Project = var.project_name
    Layer   = "silver"
  }
}

# On-demand trigger — start this manually via the AWS console or CLI:
#   aws glue start-trigger --name <trigger_name> --profile pluralsight
resource "aws_glue_trigger" "bronze_to_silver" {
  name = "${var.project_name}-bronze-to-silver-trigger"
  type = "ON_DEMAND"

  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }

  tags = {
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Gold layer — copies the silver Iceberg table into a native Redshift
# schema via the Redshift Data API. No Spark needed, so this runs as a
# lightweight Glue Python Shell job instead of a glueetl job.
# ---------------------------------------------------------------------------

# Upload the silver -> gold script to S3 so Glue can fetch it at job startup
resource "aws_s3_object" "silver_to_gold" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/silver_to_gold.py"
  source = "${path.module}/scripts/silver_to_gold.py"
  etag   = filemd5("${path.module}/scripts/silver_to_gold.py")
}

# Glue Python Shell job — runs a DROP + CREATE TABLE AS SELECT through the
# Redshift Data API, reading the silver table via the lake_external
# Spectrum schema and writing it into the native gold schema.
resource "aws_glue_job" "silver_to_gold" {
  name         = "${var.project_name}-silver-to-gold"
  role_arn     = aws_iam_role.glue_job.arn
  max_capacity = 0.0625 # smallest Python Shell capacity — no Spark needed

  command {
    name            = "pythonshell"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/silver_to_gold.py"
    python_version  = "3.9"
  }

  default_arguments = {
    # Job parameters — available inside silver_to_gold.py via getResolvedOptions
    "--cluster_identifier" = aws_redshift_cluster.spectrum.cluster_identifier
    "--redshift_database"  = aws_redshift_cluster.spectrum.database_name
    "--secret_arn"         = aws_redshift_cluster.spectrum.master_password_secret_arn
    "--external_schema"    = var.redshift_external_schema_name
    "--silver_table_name"  = var.silver_table_name
    "--gold_schema"        = var.gold_schema_name
    "--gold_table_name"    = var.gold_table_name

    "--enable-continuous-cloudwatch-log" = "true"
  }

  tags = {
    Project = var.project_name
    Layer   = "gold"
  }
}

# On-demand trigger — start this manually via the AWS console or CLI:
#   aws glue start-trigger --name <trigger_name> --profile pluralsight
resource "aws_glue_trigger" "silver_to_gold" {
  name = "${var.project_name}-silver-to-gold-trigger"
  type = "ON_DEMAND"

  actions {
    job_name = aws_glue_job.silver_to_gold.name
  }

  tags = {
    Project = var.project_name
  }
}
