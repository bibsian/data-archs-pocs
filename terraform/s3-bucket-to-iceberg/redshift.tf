# Redshift Spectrum — query the Glue-managed Iceberg tables in the bronze lake
# without copying them into Redshift storage. The cluster is private; all
# administration and validation use the Redshift Data API.

# The sandbox's default VPC supplies subnets; publicly_accessible = false keeps
# the cluster endpoint private even though the default VPC itself has public
# routing.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_vpc" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_redshift_subnet_group" "main" {
  name        = "${var.project_name}-redshift-subnets-${random_id.suffix.hex}"
  description = "Subnet group for the private ${var.project_name} Redshift cluster"
  subnet_ids  = data.aws_subnets.default_vpc.ids

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
  }
}

# No inbound rule is needed: this cluster is not reachable from a desktop SQL
# client. Redshift Data API requests are made through the AWS service endpoint.
resource "aws_security_group" "redshift" {
  name        = "${var.project_name}-redshift-${random_id.suffix.hex}"
  description = "Private Redshift cluster security group"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
  }
}

# Create Redshift's service-linked role ourselves instead of letting
# CreateCluster create it implicitly. Implicit creation races IAM
# propagation on a fresh account and can fail with "InvalidParameterValue:
# Unable to assume the SLR on the customer account".
resource "aws_iam_service_linked_role" "redshift" {
  aws_service_name = "redshift.amazonaws.com"
}

# IAM propagation buffer, matching the pattern already used for the
# EventBridge-to-Glue role in eventbridge.tf.
resource "time_sleep" "wait_for_redshift_slr" {
  depends_on      = [aws_iam_service_linked_role.redshift]
  create_duration = "30s"
}

resource "aws_redshift_cluster" "spectrum" {
  cluster_identifier = "${var.project_name}-redshift-${random_id.suffix.hex}"
  cluster_type       = "single-node"
  node_type          = var.redshift_node_type

  database_name   = var.redshift_database_name
  master_username = var.redshift_master_username

  # Redshift creates the administrator password in Secrets Manager. Terraform
  # never receives or stores the password value in state.
  manage_master_password = true

  cluster_subnet_group_name = aws_redshift_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.redshift.id]
  iam_roles                 = [aws_iam_role.redshift_spectrum.arn]
  default_iam_role_arn      = aws_iam_role.redshift_spectrum.arn

  encrypted           = true
  publicly_accessible = false

  # This is a temporary sandbox cluster. A final snapshot is unnecessary on
  # destroy and would otherwise block cleanup with a generated name.
  skip_final_snapshot = true

  tags = {
    Project     = var.project_name
    Environment = "sandbox"
  }

  depends_on = [time_sleep.wait_for_redshift_slr]
}

# The Glue database exists before any Glue job run. The external schema can be
# created immediately; tables registered later by the jobs become visible in
# this schema without another Terraform apply.
resource "aws_redshiftdata_statement" "create_lake_external_schema" {
  cluster_identifier = aws_redshift_cluster.spectrum.cluster_identifier
  database           = aws_redshift_cluster.spectrum.database_name
  secret_arn         = aws_redshift_cluster.spectrum.master_password_secret_arn
  statement_name     = "${var.project_name}-create-lake-external-schema"

  sql = <<-SQL
    CREATE EXTERNAL SCHEMA IF NOT EXISTS ${var.redshift_external_schema_name}
    FROM DATA CATALOG
    DATABASE '${aws_glue_catalog_database.lake.name}'
    REGION '${var.aws_region}'
    IAM_ROLE '${aws_iam_role.redshift_spectrum.arn}';
  SQL

  depends_on = [
    aws_iam_role_policy.redshift_spectrum,
    aws_glue_catalog_database.lake,
  ]
}

# Native Redshift schema for the gold layer. Unlike lake_external, this is
# regular Redshift-managed storage — the silver_to_gold Glue job copies data
# into it with CREATE TABLE AS SELECT ... FROM lake_external.<silver_table>.
# Created once here; the job itself only creates/replaces tables within it.
resource "aws_redshiftdata_statement" "create_gold_schema" {
  cluster_identifier = aws_redshift_cluster.spectrum.cluster_identifier
  database           = aws_redshift_cluster.spectrum.database_name
  secret_arn         = aws_redshift_cluster.spectrum.master_password_secret_arn
  statement_name     = "${var.project_name}-create-gold-schema"

  sql = "CREATE SCHEMA IF NOT EXISTS ${var.gold_schema_name};"
}
