#!/usr/bin/env bash
# Run `spark-submit` inside the running sandbox container.
# Requires the container to already be up (see scripts/up.sh).
#
# Usage:
#   spark/scripts/submit.sh spark/jobs/local_bronze_offload.py [job-args...]
#
# The script path is relative to the repo root (the container's workspace
# root), matching where you'd reference it from your own shell.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-script-relative-to-repo-root> [args...]" >&2
  exit 1
fi

SCRIPT_PATH="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

docker compose -f "${COMPOSE_FILE}" exec pyspark \
  spark-submit "/home/hadoop/workspace/${SCRIPT_PATH#/}" "$@"
