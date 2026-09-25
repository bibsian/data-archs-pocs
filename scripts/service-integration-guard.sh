#!/usr/bin/env bash
# Static, advisory checks for the classes of bugs that broke the
# get_text_from_s3 Redshift Lambda UDF integration (see
# .cursor/rules/lambda-service-integration-lessons.mdc for the full
# write-up). Generic to any Lambda-backed AWS service integration built in
# this repo, not just that one project.
#
# All checks here are static (no AWS credentials needed) and purely
# informational: this script never exits non-zero. It's meant to be run by
# hand before deploying a new Lambda-backed integration, the same way
# tf-guard.sh is run by hand each sandbox session.
#
# Usage: ./scripts/service-integration-guard.sh   (run from anywhere; it
# cd's to the repo root itself)
set -uo pipefail

cd "$(dirname "$0")/.."   # repo root

any_warning=false

echo "=== Check 1: Lambda handlers returning a raw dict instead of JSON ==="
# Plain newline-delimited `grep -l` output (not -Z/--null): macOS's default
# BSD grep doesn't null-terminate filenames the way GNU grep's -Z does, so a
# NUL-delimited read loop silently never runs on macOS. Source file paths
# here won't contain newlines, so plain newline splitting is safe and
# portable across both grep implementations.
found=false
while IFS= read -r file; do
  [ -z "${file:-}" ] && continue
  if grep -q 'json\.dumps(' "$file" 2>/dev/null; then
    continue
  fi
  echo "[WARN] $file defines a Lambda handler but never calls json.dumps() anywhere in the file."
  found=true
  any_warning=true
done < <(grep -rlE 'def[[:space:]]+(lambda_handler|handler)\(' --include='*.py' . 2>/dev/null || true)

if [ "$found" = false ]; then
  echo "OK: no Lambda handler files missing json.dumps() found."
else
  echo "     If any of these back a synchronous external-function-style caller (Redshift Lambda"
  echo "     UDF, Athena UDF, etc.), return json.dumps(response) instead of a bare dict/object."
  echo "     A raw dict auto-serializes fine for a direct 'aws lambda invoke' test — the failure"
  echo "     only shows up against the real caller, with no CloudWatch error to point at it."
fi

echo
echo "=== Check 2: Unqualified VARCHAR/CHAR in Terraform files ==="
found=false
while IFS=: read -r file line content; do
  [ -z "${file:-}" ] && continue
  echo "[WARN] $file:$line:$content"
  found=true
  any_warning=true
done < <(grep -rnE '\b(VARCHAR|CHAR)\b' --include='*.tf' . 2>/dev/null | grep -vE '(VARCHAR|CHAR)\(' | grep -vE '^[^:]+:[0-9]+: *(description|#)' || true)

if [ "$found" = false ]; then
  echo "OK: no unqualified VARCHAR/CHAR usages found."
else
  echo "     Specify an explicit length (e.g. VARCHAR(65535)) on both sides of a Lambda UDF"
  echo "     signature. An unqualified VARCHAR defaults to VARCHAR(256) in Redshift and silently"
  echo "     truncates larger values with 'Value too long for character type'."
fi

echo
echo "=== Check 3: Overly-broad IAM policy resources ==="
found=false
while IFS=: read -r file line content; do
  [ -z "${file:-}" ] && continue
  echo "[WARN] $file:$line:$content"
  found=true
  any_warning=true
done < <(grep -rnE 'resources[[:space:]]*=[[:space:]]*\[[[:space:]]*"\*"[[:space:]]*\]' --include='*.tf' . 2>/dev/null || true)

if [ "$found" = false ]; then
  echo "OK: no overly-broad IAM policy resources found."
else
  echo "     resources = [\"*\"] should be scoped to a specific resource/prefix unless the action"
  echo "     genuinely has no resource-level permission support (e.g. redshift-data:* actions --"
  echo "     see the RedshiftDataApiForGold comment in terraform/medallion-fulltext-udf/iam.tf for"
  echo "     a documented, legitimate exception)."
fi

echo
if [ "$any_warning" = true ]; then
  echo "service-integration-guard: findings above are advisory -- review before deploying."
else
  echo "service-integration-guard: no findings."
fi
exit 0
