"""
silver_to_gold.py

Purpose: Copy the silver-layer Iceberg table into a native Redshift "gold"
schema, so downstream consumers get local Redshift storage/performance
instead of querying through Spectrum every time.

This runs as a lightweight Glue Python Shell job — no Spark needed. The
copy itself is just SQL, executed through the Redshift Data API against
the `lake_external` Spectrum schema (the same schema Terraform creates in
redshift.tf, which already exposes every Iceberg table registered in the
Glue catalog database, including the silver table written by
bronze_to_silver.py):

    DROP TABLE IF EXISTS gold.<gold_table>;
    CREATE TABLE gold.<gold_table> AS
    SELECT * FROM lake_external.<silver_table>;

Full-refresh strategy (DROP + CREATE TABLE AS SELECT), matching the
createOrReplace() full-refresh convention used by the bronze and silver
Spark jobs. Swap this for MERGE/UPSERT SQL later if incremental gold loads
are needed.
"""

import sys
import time

import boto3
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(
    sys.argv,
    [
        "cluster_identifier",
        "redshift_database",
        "secret_arn",
        "external_schema",
        "silver_table_name",
        "gold_schema",
        "gold_table_name",
    ],
)

POLL_INTERVAL_SECONDS = 5
TERMINAL_STATES = ("FINISHED", "FAILED", "ABORTED")

client = boto3.client("redshift-data")

# DROP + CREATE run together via BatchExecuteStatement so they execute as a
# single transaction (one Id to poll, one pass/fail outcome).
sqls = [
    f"DROP TABLE IF EXISTS {args['gold_schema']}.{args['gold_table_name']};",
    (
        f"CREATE TABLE {args['gold_schema']}.{args['gold_table_name']} AS "
        f"SELECT * FROM {args['external_schema']}.{args['silver_table_name']};"
    ),
]

response = client.batch_execute_statement(
    ClusterIdentifier=args["cluster_identifier"],
    Database=args["redshift_database"],
    SecretArn=args["secret_arn"],
    Sqls=sqls,
)
statement_id = response["Id"]

# Python Shell jobs are synchronous, so block here polling the Data API
# instead of relying on an async callback (no Lambda/EventBridge needed).
while True:
    status = client.describe_statement(Id=statement_id)
    state = status["Status"]
    if state in TERMINAL_STATES:
        break
    time.sleep(POLL_INTERVAL_SECONDS)

if state != "FINISHED":
    raise RuntimeError(f"Gold copy failed (state={state}): {status.get('Error')}")

print(
    f"Gold copy complete: {args['gold_schema']}.{args['gold_table_name']} "
    f"<- {args['external_schema']}.{args['silver_table_name']}"
)
