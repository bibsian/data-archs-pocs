#!/usr/bin/env bash
# One-shot demo/smoke test: runs the local bronze offload job, then the
# local bronze -> silver job, against the local filesystem Iceberg catalog.
# Requires the container to already be up (see scripts/up.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Step 1/2: local_bronze_offload.py =="
"${SCRIPT_DIR}/submit.sh" spark/jobs/local_bronze_offload.py

echo ""
echo "== Step 2/2: local_bronze_to_silver.py =="
"${SCRIPT_DIR}/submit.sh" spark/jobs/local_bronze_to_silver.py

echo ""
echo "Done. Inspect results with spark/scripts/shell.sh, e.g.:"
echo '  spark.sql("SELECT * FROM local_catalog.silver.silver_data LIMIT 5").show()'
echo '  spark.sql("SELECT * FROM local_catalog.silver.silver_data_quarantine LIMIT 5").show()'
