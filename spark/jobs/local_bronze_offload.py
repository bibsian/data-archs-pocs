"""
local_bronze_offload.py

Fully offline local-mode analog of
terraform/medallion-fulltext-udf/scripts/source_to_bronze_offload.py.

Same claim-check idea as the real job -- offload the large `terms` text
field to its own object and replace it with a pointer -- but everything
happens on the local filesystem inside the sandbox container instead of S3,
and the Iceberg table goes into the local Hadoop catalog (see
spark/lib/local_spark.py) instead of the AWS Glue Data Catalog. No AWS
credentials, S3, or Glue involved.

Run via:
    spark/scripts/submit.sh spark/jobs/local_bronze_offload.py [source_csv]

`source_csv` is optional and relative to the repo root; defaults to the
sample CSV already committed under data/.
"""

import os
import sys

sys.path.insert(0, "/home/hadoop/workspace/spark/lib")

from local_spark import TERMS_LOCAL_DIR, WAREHOUSE_PATH, get_local_spark  # noqa: E402
from pyspark.sql.functions import col, lit, udf  # noqa: E402
from pyspark.sql.types import StringType  # noqa: E402
from datetime import datetime, timezone  # noqa: E402

DEFAULT_SOURCE_CSV = "data/data_poems_300_excel_safe_redshift_test.csv"
WORKSPACE_ROOT = "/home/hadoop/workspace"
BRONZE_TABLE = "local_catalog.bronze.raw_data_with_pointers"


def _offload_terms_locally(row_id, terms_text):
    """Write `terms_text` to TERMS_LOCAL_DIR/{row_id}.txt and return a
    file:// pointer -- the local-filesystem equivalent of the real job's
    s3://<terms_bucket>/terms/{row_id}.txt pointer.
    """
    if terms_text is None or row_id is None:
        return None
    os.makedirs(TERMS_LOCAL_DIR, exist_ok=True)
    path = os.path.join(TERMS_LOCAL_DIR, f"{row_id}.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write(terms_text)
    return f"file://{path}"


def main():
    source_arg = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOURCE_CSV
    source_path = (
        source_arg
        if source_arg.startswith("/")
        else os.path.join(WORKSPACE_ROOT, source_arg)
    )

    spark = get_local_spark("local-bronze-offload")

    df = spark.read.csv(source_path, header=True, inferSchema=True)

    offload_udf = udf(_offload_terms_locally, StringType())
    df = df.withColumn("terms", offload_udf(col("id"), col("terms")))

    ingestion_ts = datetime.now(timezone.utc).isoformat()
    df = df.withColumn("_ingestion_timestamp", lit(ingestion_ts)).withColumn(
        "_source_file", lit(source_path)
    )

    (
        df.writeTo(BRONZE_TABLE)
        .tableProperty("write.format.default", "parquet")
        .using("iceberg")
        .createOrReplace()
    )

    print(f"Wrote {df.count()} rows to {BRONZE_TABLE}")
    print(f"Terms offloaded under: {TERMS_LOCAL_DIR}")
    print(f"Local Iceberg warehouse: {WAREHOUSE_PATH}")

    spark.stop()


if __name__ == "__main__":
    main()
