#!/usr/bin/env bash
# Stop and remove the local Spark sandbox container. Data written to
# spark/warehouse/ on the host is untouched (it's a bind mount, not a
# container volume) -- see scripts/reset-warehouse.sh-equivalent note in
# spark/README.md if you want to wipe it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

docker compose -f "${COMPOSE_FILE}" down
