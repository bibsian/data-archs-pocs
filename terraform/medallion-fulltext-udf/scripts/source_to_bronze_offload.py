"""
source_to_bronze_offload.py

Purpose: Read CSV files dropped in the source S3 bucket, offload the large
free-text `terms` field for each row to its own object in a dedicated S3
bucket, replace that field in the row with a pointer (the object's s3://
URI), add ingestion metadata, and write the resulting flat file as an
Apache Iceberg table in the bronze S3 bucket. While the original `terms`
text is still in hand (before it's overwritten with the pointer), this job
also writes a queryable `terms_text` Parquet catalog (id, terms_text,
s3_uri) — see step 7 below.

This is the "claim-check" pattern: instead of storing large text blobs
inline in every table row (which bloats file sizes, slows scans, and can
hit engine-specific string limits like Redshift's 65535-byte VARCHAR cap),
each blob is written once to S3 and the row keeps a lightweight pointer to
it. Consumers dereference the pointer only when they actually need the
full text — either via the `terms_text` Spectrum table (bulk/joins) or the
`get_text_from_s3` Lambda UDF (single/few records).

This is the sole bronze entry point for the pipeline: it reads the source
bucket, writes `raw_data_with_pointers` as Iceberg, and feeds the silver
(bronze_to_silver.py) and gold (silver_to_gold.py) jobs downstream.

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

import boto3
from awsglue.utils import getResolvedOptions
from pyspark import SparkConf
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, input_file_name, lit, udf
from pyspark.sql.types import StringType

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
        "terms_bucket",
        "database_name",
        "table_name",
    ],
)

TERMS_PREFIX = "terms/"
TERMS_CATALOG_PREFIX = "terms_catalog/"

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
#    Spark functions like lit(), input_file_name(), and our offload udf().
#    This conversion is free — no data is copied or moved.
# ---------------------------------------------------------------------------
df = source_dyf.toDF()

# ---------------------------------------------------------------------------
# 6. Offload the `terms` text to its own S3 bucket, replace it with a pointer
#
#    Why a UDF + boto3 instead of a bulk Spark writer?
#      Spark's built-in file writers (text/CSV/etc.) don't let you name each
#      output file after a per-row value like `id`. Since we need exactly one
#      object per row named "{id}.txt", we make a direct S3 PutObject call per
#      row instead. A plain Python UDF runs once per row on the executor that
#      owns that row's partition.
#
#    The boto3 client is created lazily and cached in a module-level global.
#    Spark reuses the same Python worker process for many rows in a partition,
#    so this avoids re-creating a client (and re-resolving credentials) on
#    every single row while still working correctly under multiprocessing.
# ---------------------------------------------------------------------------
_s3_client = None


def _get_s3_client():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


def _offload_terms_to_s3(row_id, terms_text, bucket, prefix):
    """Write `terms_text` to s3://bucket/prefix{row_id}.txt and return its URI."""
    if terms_text is None or row_id is None:
        return None
    key = f"{prefix}{row_id}.txt"
    _get_s3_client().put_object(
        Bucket=bucket,
        Key=key,
        Body=terms_text.encode("utf-8"),
        ContentType="text/plain; charset=utf-8",
    )
    return f"s3://{bucket}/{key}"


offload_udf = udf(
    lambda row_id, terms_text: _offload_terms_to_s3(
        row_id, terms_text, args["terms_bucket"], TERMS_PREFIX
    ),
    StringType(),
)

# Compute the pointer into its own column first (rather than overwriting
# `terms` immediately) so both the original text *and* the pointer are still
# available afterward — the terms_text catalog in step 7 needs both.
#
# .cache() matters here for correctness, not just performance: this
# DataFrame feeds two separate write actions below (the terms_text Parquet
# catalog, then the bronze Iceberg table). Spark is lazy, so without
# caching, each action would independently re-evaluate offload_udf —
# including its S3 PutObject side effect — writing every terms/{id}.txt
# object twice per job run instead of once.
df = df.withColumn("_terms_s3_uri", offload_udf(col("id"), col("terms"))).cache()

# ---------------------------------------------------------------------------
# 7. Write the terms_text catalog — a queryable Parquet table (id,
#    terms_text, s3_uri) so the full `terms` text can be JOINed into any
#    Redshift table (native or Spectrum) instead of being dereferenced by
#    hand, one s3:// pointer at a time. Registered as a Glue table directly
#    in Terraform (aws_glue_catalog_table.terms_text in glue.tf) at this
#    same S3 location, in the same `lake` database that `lake_external`
#    maps to — so it's queryable as lake_external.terms_text with no
#    additional Redshift-side changes.
#
#    Full refresh (.mode("overwrite")) on every run, matching the
#    createOrReplace() convention used for the Iceberg write below.
# ---------------------------------------------------------------------------
(
    df.select(
        col("id"),
        col("terms").alias("terms_text"),
        col("_terms_s3_uri").alias("s3_uri"),
    )
    .write.mode("overwrite")
    .format("parquet")
    .save(f"s3://{args['bronze_bucket']}/{TERMS_CATALOG_PREFIX}")
)

# Now overwrite the `terms` column in place: same column name and position
# in the schema, but the value is the s3:// pointer instead of the raw text.
# The other columns (character_length, utf8_byte_length,
# exceeds_redshift_varchar_65535_bytes) are left untouched — they still
# describe the size of the *original* text, which is useful audit metadata.
df = df.withColumn("terms", col("_terms_s3_uri")).drop("_terms_s3_uri")

# ---------------------------------------------------------------------------
# 8. Add metadata columns
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
# 9. Write as an Iceberg table to the bronze bucket
#    "glue_catalog" here refers to the catalog we registered in step 2.
#    Spark resolves "glue_catalog.database.table" as:
#      catalog   = glue_catalog  (our Iceberg/Glue catalog)
#      database  = database_name (the Glue catalog database from Terraform)
#      table     = table_name    (default: "raw_data_with_pointers", overridable at runtime)
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
# 10. Commit the job
#    Signals to Glue that the job finished successfully.
#    Glue uses this to update the job run status in the console.
# ---------------------------------------------------------------------------
job.commit()
