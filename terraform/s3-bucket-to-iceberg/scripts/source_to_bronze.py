"""
source_to_bronze.py

Purpose: Read CSV files dropped in the source S3 bucket, add ingestion metadata,
and write the result as an Apache Iceberg table in the bronze S3 bucket.

How Glue jobs work (quick primer):
  - AWS Glue runs this script on a managed Spark cluster — you don't manage servers.
  - PySpark is Python's API for Apache Spark (a distributed data processing framework).
  - A "DynamicFrame" is Glue's wrapper around a Spark DataFrame; both represent tables
    of data distributed across the cluster.
  - Iceberg is a table format layered on top of S3 that adds features like ACID
    transactions, schema evolution, and time-travel queries.
"""

import sys
from datetime import datetime, timezone

from awsglue.utils import getResolvedOptions
from pyspark import SparkConf
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import input_file_name, lit

# ---------------------------------------------------------------------------
# 1. Parse job parameters
#    getResolvedOptions reads these from sys.argv — Glue injects them at startup
#    from the job's default_arguments (set in Terraform). "JOB_NAME" is automatic.
#    We parse args BEFORE creating SparkContext so we can pass bronze_bucket
#    into the Spark catalog configuration below.
# ---------------------------------------------------------------------------
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "source_bucket",
        "bronze_bucket",
        "database_name",
        "table_name",
    ],
)

# ---------------------------------------------------------------------------
# 2. Configure Iceberg catalog BEFORE starting Spark
#    Spark catalog settings must be baked into SparkConf at startup — you cannot
#    register a new catalog after the SparkSession is already running.
#
#    What each setting does:
#      spark.sql.extensions          — loads Iceberg's SQL syntax (e.g. MERGE INTO)
#      spark.sql.catalog.glue_catalog — registers "glue_catalog" as an Iceberg catalog
#                                       backed by the AWS Glue Data Catalog (metastore)
#      warehouse                     — where Iceberg stores table data files in S3
#      catalog-impl                  — tells Iceberg to use Glue as the metadata backend
#      io-impl                       — tells Iceberg to use S3 for file I/O
# ---------------------------------------------------------------------------
conf = SparkConf()
conf.set(
    "spark.sql.extensions",
    "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
)
conf.set("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
conf.set(
    "spark.sql.catalog.glue_catalog.warehouse",
    f"s3://{args['bronze_bucket']}/",
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
#    Pass the conf we built above to SparkContext so catalog settings are active
#    from the moment Spark starts up.
#    GlueContext wraps SparkContext with AWS-specific connectors.
#    Job tracks state; we must call job.commit() at the end.
# ---------------------------------------------------------------------------
sc = SparkContext(conf=conf)
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# ---------------------------------------------------------------------------
# 4. Read all CSV files from the source bucket
#    create_dynamic_frame.from_options reads files from S3 into a DynamicFrame.
#    "recurse: True" scans all sub-folders under the path.
#    "withHeader: True" treats the first row of each CSV as column names.
#    Glue infers the data type of each column automatically.
# ---------------------------------------------------------------------------
source_path = f"s3://{args['source_bucket']}/"

source_dyf = glue_context.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={"paths": [source_path], "recurse": True},
    format="csv",
    format_options={"withHeader": True, "separator": ","},
)

# ---------------------------------------------------------------------------
# 5. Convert DynamicFrame → Spark DataFrame
#    DataFrames are the standard Spark API. We convert so we can use built-in
#    Spark functions like lit() and input_file_name().
#    This conversion is free — no data is copied or moved.
# ---------------------------------------------------------------------------
df = source_dyf.toDF()

# ---------------------------------------------------------------------------
# 6. Add metadata columns
#    Bronze-layer convention: track when and where each row came from.
#    _ingestion_timestamp — UTC timestamp of this job run (same value for all rows)
#    _source_file         — S3 path of the specific file each row was read from
#
#    lit()             — scalar constant: every row gets the same value
#    input_file_name() — returns the S3 URI of the source file per row
# ---------------------------------------------------------------------------
ingestion_ts = datetime.now(timezone.utc).isoformat()

df = (
    df.withColumn("_ingestion_timestamp", lit(ingestion_ts))
      .withColumn("_source_file", input_file_name())
)

# ---------------------------------------------------------------------------
# 7. Write as an Iceberg table to the bronze bucket
#    "glue_catalog" here refers to the catalog we registered in step 2.
#    Spark resolves "glue_catalog.database.table" as:
#      catalog   = glue_catalog  (our Iceberg/Glue catalog)
#      database  = database_name (the Glue catalog database from Terraform)
#      table     = table_name    (default: "raw_data", overridable at runtime)
#
#    .createOrReplace() — creates the table on first run; replaces all data on reruns.
#                         Good for initial validation. Switch to .append() once confirmed.
# ---------------------------------------------------------------------------
full_table_name = f"glue_catalog.{args['database_name']}.{args['table_name']}"

(
    df.writeTo(full_table_name)
      .tableProperty("write.format.default", "parquet")
      .tableProperty("write.target-file-size-bytes", "134217728")  # 128 MB target file size
      .using("iceberg")
      .createOrReplace()
)

# ---------------------------------------------------------------------------
# 8. Commit the job
#    Signals to Glue that the job finished successfully.
#    Glue uses this to update the job run status in the console.
# ---------------------------------------------------------------------------
job.commit()
