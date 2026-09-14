terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  profile = "pluralsight"
  region  = var.aws_region
}

# Source bucket — drop raw CSV files here to trigger the ETL pipeline
resource "aws_s3_bucket" "source" {
  bucket = "${var.project_name}-source-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
    Layer       = "source"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}
