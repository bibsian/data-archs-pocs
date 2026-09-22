"""
handler.py

Lambda entry point behind the Redshift external (scalar) function
`gold.get_text_from_s3(s3_uri VARCHAR)`.

Redshift Lambda UDF invocation contract (per AWS docs):

  Request  (Redshift -> Lambda):
    {
      "request_id": "...",
      "cluster": "...",
      "database": "...",
      "user": "...",
      "external_function": "gold.get_text_from_s3",
      "query_id": 1234,
      "num_records": 4,
      "arguments": [
        ["s3://bucket/terms/1.txt"],
        ["s3://bucket/terms/2.txt"],
        [null],
        ["not-a-valid-uri"]
      ]
    }

  Response (Lambda -> Redshift):
    {
      "success": true,
      "num_records": 4,
      "results": ["<text or human-readable error>", ...]
    }
    (on a hard, whole-batch failure: {"success": false, "num_records": N,
    "error_msg": "..."} — this aborts the entire query, so it is reserved
    for malformed-request situations, not per-row problems.)

Important: the protocol has no per-row error field. Per-row failures
(missing object, access denied, malformed URI, oversized document) are
represented by returning `success: true` and putting a human-readable
message directly in that row's `results[i]` slot instead of the object's
text — this is what a non-technical analyst sees in their SQL result
cell, and it never fails the surrounding query.

Two guardrails, both enforced here (see project README/plan for context):
  1. Batch-row-count cap (MAX_BATCH_ROWS, default 100) — approximates
     "query-level" bulk detection using the only thing Lambda actually
     sees: the num_records of a single invocation batch.
  2. Per-object size cap (MAX_OBJECT_BYTES, default 60,000 bytes, safely
     under Redshift's 65,535-byte VARCHAR limit) — protects against any
     single oversized document regardless of batch size.
"""

import os
import re

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")

MAX_BATCH_ROWS = int(os.environ.get("MAX_BATCH_ROWS", "100"))
MAX_OBJECT_BYTES = int(os.environ.get("MAX_OBJECT_BYTES", "60000"))

# Matches s3://bucket/key ; key may contain further slashes.
S3_URI_RE = re.compile(r"^s3://([^/]+)/(.+)$")


def _too_many_rows_message():
    return (
        f"Too many documents requested in a single query - limit your query "
        f"to {MAX_BATCH_ROWS} documents or fewer for inline retrieval."
    )


def _too_large_message(size_bytes):
    return (
        f"Document too large for inline retrieval ({size_bytes:,} bytes) - "
        f"limit your query to {MAX_BATCH_ROWS} documents or less."
    )


def _resolve_row(s3_uri):
    """Return the document text, or a human-readable error string, for one row."""
    if not s3_uri or not isinstance(s3_uri, str):
        return "Missing s3_uri value - cannot retrieve document text."

    match = S3_URI_RE.match(s3_uri.strip())
    if not match:
        return f"Malformed s3_uri '{s3_uri}' - expected format s3://bucket/key."

    bucket, key = match.group(1), match.group(2)

    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "Unknown")
        if code in ("NoSuchKey", "404"):
            return "Document not found in S3 - the s3_uri may be stale or incorrect."
        if code == "NoSuchBucket":
            return "Document bucket not found - the s3_uri may be malformed."
        if code in ("AccessDenied", "403"):
            return "Access denied reading document from S3 - contact a data engineer."
        return f"Error retrieving document from S3 ({code})."
    except Exception as exc:  # noqa: BLE001 - last-resort guard, must never raise
        return f"Unexpected error retrieving document: {exc}"

    size = obj.get("ContentLength", 0)
    if size > MAX_OBJECT_BYTES:
        return _too_large_message(size)

    try:
        return obj["Body"].read().decode("utf-8")
    except Exception:  # noqa: BLE001 - decoding failures must surface, not raise
        return "Error decoding document contents - the object may not be UTF-8 text."


def lambda_handler(event, context):
    num_records = event.get("num_records", len(event.get("arguments", [])))
    arguments = event.get("arguments", [])

    # Guardrail 1: batch-row-count cap. If Redshift is clearly asking for a
    # bulk-sized batch, every row in it gets the same guidance message
    # instead of triggering num_records separate S3 calls.
    if num_records > MAX_BATCH_ROWS:
        message = _too_many_rows_message()
        return {
            "success": True,
            "num_records": num_records,
            "results": [message] * num_records,
        }

    # Guardrail 2 (per-object size) is enforced inside _resolve_row, per row,
    # after the object is fetched.
    results = [_resolve_row(row[0] if row else None) for row in arguments]

    return {
        "success": True,
        "num_records": num_records,
        "results": results,
    }
