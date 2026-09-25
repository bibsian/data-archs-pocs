# Glue catalog database — the metadata store where Iceberg tables are registered.
# Once the job runs, you can query the table here via Athena.
resource "aws_glue_catalog_database" "lake" {
  name        = replace("${var.project_name}_${random_id.suffix.hex}", "-", "_")
  description = "Medallion architecture data catalog — bronze layer Iceberg tables"
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
# Iceberg to bronze. This is the sole bronze entry point for the pipeline —
# it feeds the silver and gold jobs below.
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

# ---------------------------------------------------------------------------
# Terms catalog — reshapes the claim-check terms/{id}.txt objects into a
# queryable Parquet table (id, terms_text, s3_uri) so the full `terms` text
# can be joined against any Redshift table (native or Spectrum) instead of
# being dereferenced by hand, one s3:// pointer at a time.
# ---------------------------------------------------------------------------

# Glue table declared directly in Terraform (not job-inferred). It lives in
# the same `lake` database that the `lake_external` Spectrum schema already
# maps to (redshift.tf), so it becomes queryable as lake_external.terms_text
# with no further Redshift-side changes. Its location is a prefix under the
# existing bronze bucket, so no new bucket or IAM policy is required: the
# glue_job role's ReadWriteBronze/GlueCatalog statements and the
# redshift_spectrum role's ReadBronzeIcebergFiles/Objects statements in
# iam.tf already cover the whole bronze bucket ARN and the `lake` database.
resource "aws_glue_catalog_table" "terms_text" {
  name          = var.terms_catalog_table_name
  database_name = aws_glue_catalog_database.lake.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"      = "parquet"
    "EXTERNAL"            = "true"
    "parquet.compression" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.bronze.bucket}/terms_catalog/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "id"
      type = "string"
    }
    columns {
      name = "terms_text"
      type = "string"
    }
    columns {
      name = "s3_uri"
      type = "string"
    }
  }
}

# Upload the terms -> catalog reshaping script to S3 so Glue can fetch it at job startup
resource "aws_s3_object" "terms_to_catalog" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/terms_to_catalog.py"
  source = "${path.module}/scripts/terms_to_catalog.py"
  etag   = filemd5("${path.module}/scripts/terms_to_catalog.py")
}

# Glue Python Shell job — reads every terms/{id}.txt object's full body via
# boto3 (never splitting multi-line text on newlines), derives `id` from the
# filename, and (re)writes the Parquet file backing the terms_text table
# declared above. Full-refresh on every run, matching the createOrReplace()
# convention used by the Spark jobs.
resource "aws_glue_job" "terms_to_catalog" {
  name         = "${var.project_name}-terms-to-catalog"
  role_arn     = aws_iam_role.glue_job.arn
  max_capacity = 0.0625 # smallest Python Shell capacity — no Spark needed

  command {
    name            = "pythonshell"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/terms_to_catalog.py"
    python_version  = "3.9"
  }

  default_arguments = {
    # pyarrow isn't guaranteed to be preinstalled on the Python Shell 3.9
    # runtime, so pull it explicitly at job startup.
    "--additional-python-modules" = "pyarrow"

    # Job parameters — available inside terms_to_catalog.py via getResolvedOptions
    "--terms_bucket"   = aws_s3_bucket.terms.bucket
    "--terms_prefix"   = "terms/"
    "--catalog_bucket" = aws_s3_bucket.bronze.bucket
    "--catalog_prefix" = "terms_catalog/"

    "--enable-continuous-cloudwatch-log" = "true"
  }

  tags = {
    Project = var.project_name
    Layer   = "terms-catalog"
  }
}

# On-demand trigger — start this manually via the AWS console or CLI:
#   aws glue start-trigger --name <trigger_name> --profile pluralsight
resource "aws_glue_trigger" "terms_to_catalog" {
  name = "${var.project_name}-terms-to-catalog-trigger"
  type = "ON_DEMAND"

  actions {
    job_name = aws_glue_job.terms_to_catalog.name
  }

  tags = {
    Project = var.project_name
  }
}
