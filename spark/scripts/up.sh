#!/usr/bin/env bash
# Build (if needed) and start the local Spark sandbox container in the
# background. JupyterLab will be available at http://localhost:8888 once the
# container is up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

docker compose -f "${COMPOSE_FILE}" up -d --build

echo ""
echo "Local Spark sandbox is up."
echo "  JupyterLab:  http://localhost:8888"
echo "  Spark UI:    http://localhost:4040 (while a job/session is active)"
echo ""
echo "Terminal access:"
echo "  spark/scripts/shell.sh            # pyspark REPL"
echo "  spark/scripts/submit.sh <script>  # spark-submit"
