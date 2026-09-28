"""
local_bronze_to_silver.py

Fully offline local-mode analog of
terraform/medallion-fulltext-udf/scripts/bronze_to_silver.py.

Reads the local bronze Iceberg table (written by local_bronze_offload.py),
runs the DQ checks, and splits into silver / silver_quarantine Iceberg
tables -- all in the local filesystem catalog (see spark/lib/local_spark.py).

Crucially, this imports the REAL, unmodified `dq_checks.py` and the REAL
`config/dq_rules.json` from terraform/medallion-fulltext-udf/scripts/, so any
DQ-rule logic you debug here is exercised against the actual production
code, not a copy of it. Nothing under terraform/ is modified or deployed by
this script.

Run via:
    spark/scripts/submit.sh spark/jobs/local_bronze_to_silver.py
"""

import json
import sys

sys.path.insert(0, "/home/hadoop/workspace/spark/lib")
sys.path.insert(0, "/home/hadoop/workspace/terraform/medallion-fulltext-udf/scripts")

from local_spark import WAREHOUSE_PATH, get_local_spark  # noqa: E402
from dq_checks import apply_checks, build_checks  # noqa: E402
from pyspark.sql.functions import col, lit  # noqa: E402
from datetime import datetime, timezone  # noqa: E402

BRONZE_TABLE = "local_catalog.bronze.raw_data_with_pointers"
SILVER_TABLE = "local_catalog.silver.silver_data"
SILVER_QUARANTINE_TABLE = "local_catalog.silver.silver_data_quarantine"
DQ_CONFIG_PATH = (
    "/home/hadoop/workspace/terraform/medallion-fulltext-udf/scripts/config/dq_rules.json"
)


def main():
    spark = get_local_spark("local-bronze-to-silver")

    df = spark.table(BRONZE_TABLE)

    with open(DQ_CONFIG_PATH, encoding="utf-8") as f:
        dq_config = json.load(f)

    checks = build_checks(dq_config)
    result_columns = [check.result_column for check in checks]

    df = apply_checks(df, checks)

    processed_ts = datetime.now(timezone.utc).isoformat()
    df = df.withColumn("_silver_processed_at", lit(processed_ts))

    passed_df = df.filter(col("_dq_passed")).drop(
        "_dq_passed", "_dq_failed_checks", *result_columns
    )
    quarantined_df = df.filter(~col("_dq_passed"))

    (
        passed_df.writeTo(SILVER_TABLE)
        .tableProperty("write.format.default", "parquet")
        .using("iceberg")
        .createOrReplace()
    )
    (
        quarantined_df.writeTo(SILVER_QUARANTINE_TABLE)
        .tableProperty("write.format.default", "parquet")
        .using("iceberg")
        .createOrReplace()
    )

    print(f"Silver (passed):      {passed_df.count()} rows -> {SILVER_TABLE}")
    print(f"Silver (quarantined): {quarantined_df.count()} rows -> {SILVER_QUARANTINE_TABLE}")
    print(f"Local Iceberg warehouse: {WAREHOUSE_PATH}")

    spark.stop()


if __name__ == "__main__":
    main()
