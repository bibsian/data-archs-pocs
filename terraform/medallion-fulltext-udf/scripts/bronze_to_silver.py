"""
bronze_to_silver.py

Purpose: Read the bronze Iceberg table (`raw_data_with_pointers`), run a
configurable set of data-quality (DQ) checks against it, and split the
result into two Iceberg tables in the silver bucket:

  - silver_table_name            — rows that passed every DQ check
  - silver_quarantine_table_name — rows that failed at least one check,
                                    with the per-check results and a
                                    `_dq_failed_checks` column kept intact
                                    so failures can be inspected/queried

Which checks run, and on which columns, is NOT hardcoded here. It comes
from a small JSON config file (scripts/config/dq_rules.json) uploaded to S3
by Terraform and read at runtime via `--dq_config_s3_path`. The check
*types* themselves (e.g. "not_null") live in dq_checks.py, shipped to this
job via `--extra-py-files`. To add a new kind of check: implement it in
dq_checks.py, register it in CHECK_REGISTRY, then reference it from the
JSON config — no changes to this script are needed.

How Glue jobs work (quick primer):
  - AWS Glue runs this script on a managed Spark cluster — you don't manage servers.
  - PySpark is Python's API for Apache Spark (a distributed data processing framework).
  - Iceberg is a table format layered on top of S3 that adds features like ACID
    transactions, schema evolution, and time-travel queries.
"""

import json
import sys
from datetime import datetime, timezone

import boto3
from awsglue.utils import getResolvedOptions
from pyspark import SparkConf
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, lit

from dq_checks import apply_checks, build_checks

# ---------------------------------------------------------------------------
# 1. Parse job parameters
#    getResolvedOptions reads these from sys.argv — Glue injects them at startup
#    from the job's default_arguments (set in Terraform). "JOB_NAME" is automatic.
#    We parse args BEFORE creating SparkContext so we can pass silver_bucket
#    into the Spark catalog configuration below.
# ---------------------------------------------------------------------------
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "database_name",
        "bronze_table_name",
        "silver_bucket",
        "silver_table_name",
        "silver_quarantine_table_name",
        "dq_config_s3_path",
    ],
)

# ---------------------------------------------------------------------------
# 2. Configure Iceberg catalog BEFORE starting Spark
#    Same "glue_catalog" catalog name as the bronze jobs, so
#    glue_catalog.<database>.<bronze_table_name> resolves to the existing
#    bronze table (its actual S3 location comes from Glue catalog metadata,
#    not from this warehouse setting). The warehouse setting below only
#    controls where *new* tables created by this job — the silver and
#    quarantine tables — are stored.
# ---------------------------------------------------------------------------
conf = SparkConf()
conf.set(
    "spark.sql.extensions",
    "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
)
conf.set("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
conf.set(
    "spark.sql.catalog.glue_catalog.warehouse",
    f"s3://{args['silver_bucket']}/",
)
conf.set(
    "spark.sql.catalog.glue_catalog.catalog-impl",
    "org.apache.iceberg.aws.glue.GlueCatalog",
)
conf.set(
    "spark.sql.catalog.glue_catalog.io-impl",
    "org.apache.iceberg.aws.s3.S3FileIO",
)

# ---------------------------------------------------------------------------
# 3. Initialize Spark and Glue
# ---------------------------------------------------------------------------
sc = SparkContext(conf=conf)
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# ---------------------------------------------------------------------------
# 4. Read the bronze Iceberg table via the Glue Data Catalog
# ---------------------------------------------------------------------------
bronze_full_name = f"glue_catalog.{args['database_name']}.{args['bronze_table_name']}"
df = spark.table(bronze_full_name)

# ---------------------------------------------------------------------------
# 5. Load the DQ config from S3 and build the configured checks
#    Config format (scripts/config/dq_rules.json):
#      {"checks": [{"type": "not_null", "columns": ["id", "terms"]}]}
# ---------------------------------------------------------------------------
_s3_uri = args["dq_config_s3_path"].removeprefix("s3://")
_config_bucket, _config_key = _s3_uri.split("/", 1)
_config_obj = boto3.client("s3").get_object(Bucket=_config_bucket, Key=_config_key)
dq_config = json.loads(_config_obj["Body"].read())

checks = build_checks(dq_config)
result_columns = [check.result_column for check in checks]

df = apply_checks(df, checks)

# ---------------------------------------------------------------------------
# 6. Add silver-layer metadata and split into passed / quarantined rows
#    _silver_processed_at — UTC timestamp of this job run (same value for all rows)
# ---------------------------------------------------------------------------
processed_ts = datetime.now(timezone.utc).isoformat()
df = df.withColumn("_silver_processed_at", lit(processed_ts))

# Passing rows: drop the per-check/summary DQ columns — they're clean by
# definition — and write to the main silver table.
passed_df = df.filter(col("_dq_passed")).drop("_dq_passed", "_dq_failed_checks", *result_columns)

# Failing rows: keep every DQ column so failures can be inspected/queried
# directly from the quarantine table.
quarantined_df = df.filter(~col("_dq_passed"))

# ---------------------------------------------------------------------------
# 7. Write both Iceberg tables to the silver bucket
#    .createOrReplace() — full refresh each run, matching the bronze jobs'
#    convention. Switch to .append()/MERGE once incremental loads are needed.
# ---------------------------------------------------------------------------
silver_full_name = f"glue_catalog.{args['database_name']}.{args['silver_table_name']}"
quarantine_full_name = (
    f"glue_catalog.{args['database_name']}.{args['silver_quarantine_table_name']}"
)

(
    passed_df.writeTo(silver_full_name)
    .tableProperty("write.format.default", "parquet")
    .tableProperty("write.target-file-size-bytes", "134217728")  # 128 MB target file size
    .using("iceberg")
    .createOrReplace()
)

(
    quarantined_df.writeTo(quarantine_full_name)
    .tableProperty("write.format.default", "parquet")
    .tableProperty("write.target-file-size-bytes", "134217728")
    .using("iceberg")
    .createOrReplace()
)

# ---------------------------------------------------------------------------
# 8. Commit the job
# ---------------------------------------------------------------------------
job.commit()
