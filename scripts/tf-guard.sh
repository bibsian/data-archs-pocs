#!/usr/bin/env bash
# Detects Terraform state left over from a previous (now-defunct) Pluralsight
# sandbox account, for every project under terraform/, and archives it before
# it can cause cross-account AccessDenied errors on plan/apply.
#
# Usage: ./scripts/tf-guard.sh   (run from the repo root, after configuring
# sandbox credentials for the current session)
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root
PROFILE="pluralsight"

CURRENT_ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null || true)
if [ -z "$CURRENT_ACCOUNT" ]; then
  echo "Could not determine current AWS account via 'aws sts get-caller-identity --profile $PROFILE'. Skipping check."
  exit 0
fi

shopt -s nullglob
found_any=false
for state_file in terraform/*/terraform.tfstate; do
  found_any=true
  project_dir=$(dirname "$state_file")
  project_name=$(basename "$project_dir")

  state_accounts=$(python3 -c "
import json, re
with open('$state_file') as f:
    state = json.load(f)
ids = set()
def walk(obj):
    if isinstance(obj, str):
        m = re.search(r'arn:aws:[a-z0-9-]+:[a-z0-9-]*:(\d{12}):', obj)
        if m: ids.add(m.group(1))
    elif isinstance(obj, dict):
        for v in obj.values(): walk(v)
    elif isinstance(obj, list):
        for v in obj: walk(v)
walk(state)
print(' '.join(sorted(ids)))
")

  if [ -z "$state_accounts" ]; then
    echo "[$project_name] No account IDs found in state — nothing to check."
    continue
  fi

  if echo "$state_accounts" | grep -qw "$CURRENT_ACCOUNT"; then
    echo "[$project_name] State matches current sandbox account ($CURRENT_ACCOUNT). OK."
    continue
  fi

  echo "[$project_name] Stale state detected (state account(s): $state_accounts, current: $CURRENT_ACCOUNT). Archiving..."
  timestamp=$(date +%Y%m%d-%H%M%S)
  archive_dir="$project_dir/.stale-state-backup/$timestamp"
  mkdir -p "$archive_dir"
  mv "$project_dir/terraform.tfstate" "$archive_dir/" 2>/dev/null || true
  mv "$project_dir/terraform.tfstate.backup" "$archive_dir/" 2>/dev/null || true
  echo "[$project_name] Archived stale state to $archive_dir/."
done

if [ "$found_any" = false ]; then
  echo "No terraform.tfstate files found under terraform/*/. Nothing to check."
fi
