"""
terms_to_catalog.py

Purpose: Reshape the claim-check `terms/{id}.txt` objects (written by
source_to_bronze_offload.py) into a queryable Parquet table: one row per
object, with columns `id`, `terms_text`, and `s3_uri`.

Why not a raw external TEXTFILE table over `terms/` directly? Redshift
Spectrum/Athena text SerDes split rows on newlines and have no way to
recover `id` (it only lives in the filename, not the file content). Since
`terms` is free-form text that can legitimately span multiple lines, that
approach would silently corrupt data. Reading each object's *entire* body
via boto3 (instead of a line-based reader) sidesteps both problems.

This runs as a lightweight Glue Python Shell job (no Spark needed). Its
output lands under the bronze bucket at `terms_catalog/`, the same S3
location declared by the `aws_glue_catalog_table.terms_text` Terraform
resource in glue.tf. Because that table lives in the same Glue database
that the `lake_external` Redshift Spectrum schema maps to, the reshaped
table is queryable as `lake_external.terms_text` immediately — no
additional Redshift-side Terraform changes are needed.

Full-refresh strategy, matching the createOrReplace() convention used by
the Spark jobs: delete any previously written Parquet files at the catalog
prefix, then write a fresh one.
"""

import io
import sys

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(
    sys.argv,
    ["terms_bucket", "terms_prefix", "catalog_bucket", "catalog_prefix"],
)

s3 = boto3.client("s3")

# ---------------------------------------------------------------------------
# 1. List every offloaded `terms/{id}.txt` object and read its full body.
#    get_object (not a line-based reader) so multi-line `terms` text is
#    never split into multiple rows.
# ---------------------------------------------------------------------------
ids, terms_texts, s3_uris = [], [], []

paginator = s3.get_paginator("list_objects_v2")
for page in paginator.paginate(Bucket=args["terms_bucket"], Prefix=args["terms_prefix"]):
    for obj in page.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".txt"):
            continue

        row_id = key[len(args["terms_prefix"]) : -len(".txt")]
        body = s3.get_object(Bucket=args["terms_bucket"], Key=key)["Body"].read()

        ids.append(row_id)
        terms_texts.append(body.decode("utf-8"))
        s3_uris.append(f"s3://{args['terms_bucket']}/{key}")

# ---------------------------------------------------------------------------
# 2. Build a Parquet file in memory and upload it, replacing any Parquet
#    files from a previous run (full refresh — no incremental append).
# ---------------------------------------------------------------------------
table = pa.table({"id": ids, "terms_text": terms_texts, "s3_uri": s3_uris})

buffer = io.BytesIO()
pq.write_table(table, buffer, compression="snappy")
buffer.seek(0)

existing = s3.list_objects_v2(Bucket=args["catalog_bucket"], Prefix=args["catalog_prefix"])
for obj in existing.get("Contents", []):
    s3.delete_object(Bucket=args["catalog_bucket"], Key=obj["Key"])

output_key = f"{args['catalog_prefix']}terms_text.parquet"
s3.put_object(Bucket=args["catalog_bucket"], Key=output_key, Body=buffer.getvalue())

print(f"Wrote {len(ids)} rows to s3://{args['catalog_bucket']}/{output_key}")
