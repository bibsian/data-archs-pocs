variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "aws-learn"
}

variable "worker_type" {
  description = "Glue worker type (G.1X is the smallest and cheapest)"
  type        = string
  default     = "G.1X"
}

variable "num_workers" {
  description = "Number of Glue workers to allocate for the ETL job"
  type        = number
  default     = 2
}

variable "table_name" {
  description = "Name of the Iceberg table created in the bronze layer"
  type        = string
  default     = "raw_data"
}

variable "offload_table_name" {
  description = "Name of the Iceberg table created by the terms-offload job (terms column replaced with s3:// pointers)"
  type        = string
  default     = "raw_data_with_pointers"
}
