# Athena workgroup — groups queries together and enforces the query result location.
# When you run a query in the Athena console, select this workgroup so results
# are automatically written to the athena_results S3 bucket.
resource "aws_athena_workgroup" "main" {
  name        = "${var.project_name}-workgroup"
  description = "Medallion pipeline — query bronze Iceberg tables"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Prevent accidental full-table scans on large datasets
    bytes_scanned_cutoff_per_query = 1073741824 # 1 GB limit per query
  }

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
  }
}
