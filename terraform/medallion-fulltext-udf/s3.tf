# Bronze bucket — Iceberg tables written here by the Glue ETL job
resource "aws_s3_bucket" "bronze" {
  bucket = "${var.project_name}-bronze-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
    Layer       = "bronze"
  }
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket                  = aws_s3_bucket.bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Silver bucket — validated Iceberg tables (and their quarantine counterparts)
# written here by the bronze_to_silver Glue ETL job
resource "aws_s3_bucket" "silver" {
  bucket = "${var.project_name}-silver-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
    Layer       = "silver"
  }
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket                  = aws_s3_bucket.silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Athena query results bucket — Athena writes query output here before returning results
resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-athena-results-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Glue scripts bucket — stores the Python ETL script so Glue can access it at runtime
resource "aws_s3_bucket" "glue_scripts" {
  bucket = "${var.project_name}-glue-scripts-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "glue_scripts" {
  bucket                  = aws_s3_bucket.glue_scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Terms bucket — large `terms` text offloaded here (claim-check pattern), one
# object per row (terms/{id}.txt). The Iceberg table stores only the s3://
# pointer to each object instead of the full text.
resource "aws_s3_bucket" "terms" {
  bucket = "${var.project_name}-terms-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
    Layer       = "terms-offload"
  }
}

resource "aws_s3_bucket_versioning" "terms" {
  bucket = aws_s3_bucket.terms.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terms" {
  bucket = aws_s3_bucket.terms.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terms" {
  bucket                  = aws_s3_bucket.terms.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
