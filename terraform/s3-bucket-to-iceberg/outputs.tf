output "source_bucket_name" {
  description = "Source S3 bucket — drop CSV files here"
  value       = aws_s3_bucket.source.bucket
}

output "bronze_bucket_name" {
  description = "Bronze S3 bucket — Iceberg tables written here after ETL"
  value       = aws_s3_bucket.bronze.bucket
}

output "glue_catalog_database" {
  description = "Glue catalog database name — query tables here via Athena"
  value       = aws_glue_catalog_database.lake.name
}

output "athena_workgroup" {
  description = "Athena workgroup name — select this in the console before running queries"
  value       = aws_athena_workgroup.main.name
}

output "athena_results_bucket" {
  description = "S3 bucket where Athena writes query result files"
  value       = aws_s3_bucket.athena_results.bucket
}

output "terms_bucket_name" {
  description = "Terms S3 bucket — offloaded `terms` text objects (terms/{id}.txt) live here"
  value       = aws_s3_bucket.terms.bucket
}

output "glue_offload_job_name" {
  description = "Name of the Glue ETL job that offloads `terms` text and writes pointer rows to Iceberg"
  value       = aws_glue_job.source_to_bronze_offload.name
}

output "glue_workflow_name" {
  description = "Glue workflow that runs automatically when a .csv lands in the source bucket — chains source_to_bronze_offload -> bronze_to_silver -> silver_to_gold"
  value       = aws_glue_workflow.source_to_bronze.name
}

output "silver_bucket_name" {
  description = "Silver S3 bucket — validated (and quarantined) Iceberg tables written here by bronze_to_silver"
  value       = aws_s3_bucket.silver.bucket
}

output "glue_silver_job_name" {
  description = "Name of the Glue ETL job that validates bronze data and writes silver/quarantine Iceberg tables"
  value       = aws_glue_job.bronze_to_silver.name
}

output "glue_gold_job_name" {
  description = "Name of the Glue Python Shell job that copies the silver Iceberg table into the native Redshift gold schema"
  value       = aws_glue_job.silver_to_gold.name
}

output "glue_terms_catalog_job_name" {
  description = "Name of the Glue Python Shell job that reshapes terms/{id}.txt objects into the queryable terms_text Parquet table"
  value       = aws_glue_job.terms_to_catalog.name
}

output "eventbridge_rule_name" {
  description = "EventBridge rule watching the source bucket for new .csv uploads"
  value       = aws_cloudwatch_event_rule.source_csv_uploaded.name
}

output "redshift_cluster_identifier" {
  description = "Provisioned private Redshift cluster identifier; use with the Redshift Data API"
  value       = aws_redshift_cluster.spectrum.cluster_identifier
}

output "redshift_cluster_endpoint" {
  description = "Private Redshift cluster endpoint"
  value       = aws_redshift_cluster.spectrum.endpoint
}

output "redshift_admin_secret_arn" {
  description = "AWS-managed Redshift administrator credential ARN for Redshift Data API requests"
  value       = aws_redshift_cluster.spectrum.master_password_secret_arn
}

output "redshift_external_schema" {
  description = "Redshift Spectrum schema backed by the Glue lake database"
  value       = var.redshift_external_schema_name
}

output "redshift_database_name" {
  description = "Redshift database used by the Data API and external schema"
  value       = aws_redshift_cluster.spectrum.database_name
}

output "redshift_offload_table" {
  description = "Redshift query target for the offload Iceberg table after its first Glue job run"
  value       = "${var.redshift_external_schema_name}.${var.offload_table_name}"
}

output "redshift_silver_table" {
  description = "Redshift query target for the silver Iceberg table (via Spectrum) after the bronze_to_silver job runs"
  value       = "${var.redshift_external_schema_name}.${var.silver_table_name}"
}

output "redshift_silver_quarantine_table" {
  description = "Redshift query target for rows that failed DQ checks (via Spectrum) after the bronze_to_silver job runs"
  value       = "${var.redshift_external_schema_name}.${var.silver_quarantine_table_name}"
}

output "redshift_gold_schema" {
  description = "Native Redshift schema populated by the silver_to_gold job"
  value       = var.gold_schema_name
}

output "redshift_gold_table" {
  description = "Redshift query target for the native gold table after the silver_to_gold job runs"
  value       = "${var.gold_schema_name}.${var.gold_table_name}"
}

output "redshift_terms_table" {
  description = "Redshift query target for the terms text table (via Spectrum) after the terms_to_catalog job runs"
  value       = "${var.redshift_external_schema_name}.${var.terms_catalog_table_name}"
}
