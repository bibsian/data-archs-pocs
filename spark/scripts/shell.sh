#!/usr/bin/env bash
# Open an interactive pyspark REPL inside the running sandbox container.
# Requires the container to already be up (see scripts/up.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

docker compose -f "${COMPOSE_FILE}" exec pyspark pyspark
