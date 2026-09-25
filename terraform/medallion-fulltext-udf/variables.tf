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

variable "offload_table_name" {
  description = "Name of the Iceberg table created by the terms-offload job (terms column replaced with s3:// pointers)"
  type        = string
  default     = "raw_data_with_pointers"
}

variable "silver_table_name" {
  description = "Name of the Iceberg table created in the silver layer for rows that pass all DQ checks"
  type        = string
  default     = "silver_data"
}

variable "silver_quarantine_table_name" {
  description = "Name of the Iceberg table created in the silver layer for rows that fail one or more DQ checks"
  type        = string
  default     = "silver_data_quarantine"
}

variable "gold_schema_name" {
  description = "Native Redshift schema that the gold layer copies silver data into"
  type        = string
  default     = "gold"
}

variable "gold_table_name" {
  description = "Name of the native Redshift table created in the gold schema"
  type        = string
  default     = "gold_data"
}

variable "redshift_database_name" {
  description = "Database created in the provisioned Redshift cluster"
  type        = string
  default     = "dev"
}

variable "redshift_master_username" {
  description = "Redshift administrator username; its password is managed by AWS Secrets Manager"
  type        = string
  default     = "admin"
}

variable "redshift_node_type" {
  description = "Provisioned Redshift node type; ra3.large is the selected private single-node sandbox baseline"
  type        = string
  default     = "ra3.large"
}

variable "redshift_external_schema_name" {
  description = "Redshift external schema that maps to the Glue lake database"
  type        = string
  default     = "lake_external"
}

variable "terms_catalog_table_name" {
  description = "Name of the Glue table that catalogs the offloaded `terms` text objects as structured rows (id, terms_text, s3_uri)"
  type        = string
  default     = "terms_text"
}

variable "text_udf_lambda_function_name" {
  description = "Name of the Lambda function backing the gold.get_text_from_s3 Redshift external function"
  type        = string
  default     = "get-text-from-s3"
}

variable "text_udf_max_batch_rows" {
  description = "Guardrail: max rows Lambda will resolve individually in one Redshift invocation batch before returning a 'too many documents' message for every row in that batch instead"
  type        = number
  default     = 100
}

variable "text_udf_max_object_bytes" {
  description = "Guardrail: max S3 object size (bytes) Lambda will return inline; larger objects return a 'document too large' message instead of the body. Kept safely under Redshift's 65,535-byte VARCHAR limit"
  type        = number
  default     = 60000
}
