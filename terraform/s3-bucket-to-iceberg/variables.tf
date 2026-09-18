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
