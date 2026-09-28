"""
local_spark.py

Shared helper for the local Spark sandbox (spark/). Builds a plain
SparkSession running in local mode (`local[*]`) with a *local filesystem*
Iceberg catalog -- no S3, no AWS Glue Data Catalog, no AWS credentials.

This intentionally does NOT use awsglue.context.GlueContext / getResolvedOptions:
the real jobs under terraform/medallion-fulltext-udf/scripts/ use those because
they run as actual AWS Glue jobs. Here we just want a fast, fully offline
Spark session to debug PySpark/Iceberg logic against, using the same Iceberg
version bundled in the aws-glue-libs:5 image so behavior matches production
as closely as possible.

Usage (from a script run via `spark/scripts/submit.sh` or the pyspark REPL):

    import sys
    sys.path.insert(0, "/home/hadoop/workspace/spark/lib")
    from local_spark import get_local_spark, WAREHOUSE_PATH

    spark = get_local_spark("my-debug-job")
    df = spark.table("local_catalog.bronze.raw_data_with_pointers")
"""

from pyspark.sql import SparkSession

# All local Iceberg tables live under this path (a real directory on the
# host at spark/warehouse/, since the whole repo is bind-mounted into the
# container at /home/hadoop/workspace). Delete this directory to reset the
# local catalog entirely.
WAREHOUSE_PATH = "/home/hadoop/workspace/spark/warehouse"

# Where the offload step writes the "terms" text blobs it would otherwise
# put in S3 (see local_bronze_offload.py).
TERMS_LOCAL_DIR = f"{WAREHOUSE_PATH}/_terms"

CATALOG_NAME = "local_catalog"


def get_local_spark(app_name: str = "local-debug") -> SparkSession:
    """Return a local-mode SparkSession with `local_catalog` registered as a
    Hadoop-type Iceberg catalog rooted at WAREHOUSE_PATH.
    """
    return (
        SparkSession.builder.appName(app_name)
        .master("local[*]")
        .config(
            "spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
        )
        .config(
            f"spark.sql.catalog.{CATALOG_NAME}",
            "org.apache.iceberg.spark.SparkCatalog",
        )
        .config(f"spark.sql.catalog.{CATALOG_NAME}.type", "hadoop")
        .config(
            f"spark.sql.catalog.{CATALOG_NAME}.warehouse",
            f"file://{WAREHOUSE_PATH}",
        )
        .getOrCreate()
    )
