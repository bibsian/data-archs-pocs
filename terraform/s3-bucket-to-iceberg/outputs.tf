output "source_bucket_name" {
  description = "Source S3 bucket — drop CSV files here"
  value       = aws_s3_bucket.source.bucket
}

output "bronze_bucket_name" {
  description = "Bronze S3 bucket — Iceberg tables written here after ETL"
  value       = aws_s3_bucket.bronze.bucket
}

output "glue_job_name" {
  description = "Name of the Glue ETL job (source → bronze)"
  value       = aws_glue_job.source_to_bronze.name
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
  description = "Glue workflow that runs automatically when a .csv lands in the source bucket — starts source_to_bronze_offload"
  value       = aws_glue_workflow.source_to_bronze.name
}

output "eventbridge_rule_name" {
  description = "EventBridge rule watching the source bucket for new .csv uploads"
  value       = aws_cloudwatch_event_rule.source_csv_uploaded.name
}
