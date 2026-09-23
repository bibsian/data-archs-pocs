# data-archs

Experimentation repo for AWS using Pluralsight cloud sandboxes.

## Prerequisites

Install these tools once:

```bash
# AWS CLI
brew install awscli

# Terraform
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# AWS SAM CLI (for serverless)
brew tap aws/tap && brew install aws-sam-cli

# Node.js (if not installed)
brew install node
```

---

## Every new sandbox session

Pluralsight sandbox credentials expire after ~4 hours. Each time you start a new sandbox:

### 1. Get your access keys

1. Log into the AWS Console with your sandbox username/password (use incognito)
2. Click your **username** (top-right corner) → **Security credentials**
3. Under **Access keys** → **Create access key**
4. Copy the **Access Key ID** and **Secret Access Key**

### 2. Configure the CLI

```bash
bash scripts/configure-sandbox.sh
```

This saves credentials to the `pluralsight` AWS profile. Nothing is committed to git.

### 3. Verify

```bash
aws sts get-caller-identity --profile pluralsight
```

### 4. Clean up stale state (if any)

```bash
bash scripts/tf-guard.sh
```

Each new sandbox session spins up a brand-new AWS account. This scans every project under `terraform/` and archives any local state left over from a previous (now-defunct) sandbox account, so `terraform plan`/`apply` won't hit cross-account `AccessDenied` errors.

### Before deploying a new Lambda-backed integration

```bash
bash scripts/service-integration-guard.sh
```

Static, advisory checks (no AWS credentials needed) for the bug classes that broke the `get_text_from_s3` Redshift Lambda UDF the first time it was deployed: Lambda handlers returning a raw dict instead of `json.dumps(...)` for synchronous external-function-style callers, unqualified `VARCHAR`/`CHAR` sizes in Terraform-embedded SQL, and overly-broad `resources = ["*"]` in IAM policies. See [.cursor/rules/lambda-service-integration-lessons.mdc](.cursor/rules/lambda-service-integration-lessons.mdc) for the full write-up.

---

## Terraform

```bash
cd terraform/<_terraform_proejcts_>

# First time only
terraform init

# Preview changes
terraform plan -var="project_name=data-archs"

# Deploy
terraform apply -var="project_name=data-archs"

# Tear down (important — sandbox resources may persist billing)
terraform destroy
```

### `medallion-fulltext-udf` — automatic trigger

Uploading a `.csv` to the source bucket automatically kicks off the full medallion pipeline — bronze → silver → gold — via a single Glue Workflow (see `eventbridge.tf`):

1. **Bronze** — `source_to_bronze_offload` (S3 → EventBridge trigger) reads the CSV, offloads `terms` text (claim-check pattern), writes `raw_data_with_pointers` as Iceberg.
2. **Silver** — once bronze `SUCCEEDED`, a `CONDITIONAL` trigger starts `bronze_to_silver`, which runs the configurable DQ checks in `scripts/config/dq_rules.json` (implemented in `scripts/dq_checks.py`) and splits the result into `silver_data` (passed) and `silver_data_quarantine` (failed) Iceberg tables.
3. **Gold** — once silver `SUCCEEDED`, another `CONDITIONAL` trigger starts `silver_to_gold`, a lightweight Glue Python Shell job that runs `DROP TABLE` + `CREATE TABLE AS SELECT` through the Redshift Data API, copying `silver_data` into the native `gold.gold_data` table.

`source_to_bronze_offload` is the sole bronze entry point — the standalone `source_to_bronze` job/`raw_data` table has been removed; every CSV upload now flows straight through bronze → silver → gold.

```bash
# Upload a test file to trigger the pipeline
aws s3 cp sample.csv s3://<source_bucket_name>/ --profile pluralsight

# Check for a new workflow run (covers bronze -> silver -> gold)
aws glue get-workflow-runs --name <glue_workflow_name> --profile pluralsight
```

The bucket/workflow names are printed as Terraform outputs (`source_bucket_name`, `glue_workflow_name`) after `apply`. All three jobs (`glue_offload_job_name`, `glue_silver_job_name`, `glue_gold_job_name`) also have their own `ON_DEMAND` triggers for manual re-runs.

#### Configuring silver-layer DQ checks

`scripts/config/dq_rules.json` controls which checks run and on which columns — no code changes needed:

```json
{
  "checks": [
    { "type": "not_null", "columns": ["id", "terms"] }
  ]
}
```

To add a new *kind* of check (beyond `not_null` / `not_empty_string`), subclass `DQCheck` and register it in `CHECK_REGISTRY` in `scripts/dq_checks.py`, then reference the new type from the JSON config above.

### Query bronze/silver (Spectrum) and gold (native) from Redshift

This project provisions a private, single-node Redshift `ra3.large` cluster.
It is administered through the Redshift Data API, so no inbound network access
or desktop SQL client is required. Terraform creates `lake_external`, an
external schema that maps to the project's Glue catalog database.

That Glue database is shared by the bronze and silver jobs, so Redshift
discovers `raw_data_with_pointers`, `silver_data`, and `silver_data_quarantine`
through `lake_external` as soon as each job has run at least once.
`gold.gold_data` is different: it's a native Redshift table (not Spectrum)
that `silver_to_gold` populates via `CREATE TABLE AS SELECT`.

```bash
cd terraform/medallion-fulltext-udf

# Bronze/silver — read through Spectrum
aws redshift-data execute-statement \
  --cluster-identifier "$(terraform output -raw redshift_cluster_identifier)" \
  --database "$(terraform output -raw redshift_database_name)" \
  --secret-arn "$(terraform output -raw redshift_admin_secret_arn)" \
  --sql "SELECT * FROM $(terraform output -raw redshift_offload_table) LIMIT 10" \
  --profile pluralsight

# Silver — clean rows vs. quarantined (failed DQ) rows
aws redshift-data execute-statement \
  --cluster-identifier "$(terraform output -raw redshift_cluster_identifier)" \
  --database "$(terraform output -raw redshift_database_name)" \
  --secret-arn "$(terraform output -raw redshift_admin_secret_arn)" \
  --sql "SELECT * FROM $(terraform output -raw redshift_silver_quarantine_table) LIMIT 10" \
  --profile pluralsight

# Gold — native Redshift table, no Spectrum involved
aws redshift-data execute-statement \
  --cluster-identifier "$(terraform output -raw redshift_cluster_identifier)" \
  --database "$(terraform output -raw redshift_database_name)" \
  --secret-arn "$(terraform output -raw redshift_admin_secret_arn)" \
  --sql "SELECT * FROM $(terraform output -raw redshift_gold_table) LIMIT 10" \
  --profile pluralsight
```

Each command returns an `Id`. Inspect it with `aws redshift-data describe-statement --id <Id> --profile pluralsight`, then retrieve rows with `aws redshift-data get-statement-result --id <Id> --profile pluralsight`.

### Query full text via the Lambda UDF

`gold.gold_data.terms` holds an `s3://` pointer, not the offloaded text itself (the claim-check pattern — see above). To read the actual text inline in SQL, `terraform apply` also registers a Redshift external function, `gold.get_text_from_s3(s3_uri)`, backed by a small Lambda (`get-text-from-s3`) that fetches one object from the terms bucket per call:

```sql
-- Recommended pattern: filter to a handful of known documents first, then
-- dereference the pointer only for those rows.
SELECT id, terms, gold.get_text_from_s3(terms) AS full_text
FROM gold.gold_data
WHERE id IN ('1', '2', '3');
```

This is for **single/few-record inline retrieval only, not bulk export** — every row triggers its own Lambda invocation. Two guardrails are built into the Lambda itself (`scripts/get_text_from_s3/handler.py`), so a query that fans out too wide gets a clear message in the result cell instead of a slow/silent failure:

- **Batch-row-count cap** (`text_udf_max_batch_rows`, default 100) — if a single invocation batch has more rows than this, every row in it gets `"Too many documents requested in a single query - limit your query to 100 documents or fewer for inline retrieval."` instead of its text.
- **Per-object size cap** (`text_udf_max_object_bytes`, default 60,000 bytes — safely under Redshift's 65,535-byte VARCHAR limit) — if a fetched object is larger than this, that row gets `"Document too large for inline retrieval (<size> bytes) - limit your query to 100 documents or less."` instead of its text.

Both are configurable via Terraform variables (`text_udf_max_batch_rows`, `text_udf_max_object_bytes`) and passed to the Lambda as environment variables. Other per-row failures (missing object, access denied, malformed `s3_uri`) also return a human-readable message rather than failing the whole query — see the function names/ARNs in Terraform outputs (`text_udf_lambda_function_name`, `redshift_get_text_from_s3_function`, etc.) for quick reference or Redshift Data API testing.

## Project structure

Each IaC framework has its own folder, with individual projects as subdirectories.
To add a new project, create a new subdirectory (e.g. `terraform/vpc/` or `serverless/my-api/`).

```
aws_learn/
├── scripts/
│   ├── configure-sandbox.sh       # Set sandbox credentials each session
│   └── tf-guard.sh                # Archive stale state from a previous sandbox account
├── terraform/
│   └── medallion-fulltext-udf/                # Project: medallion pipeline + guardrailed full-text Lambda UDF
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── eventbridge.tf          # S3 -> EventBridge -> Glue Workflow auto-trigger,
│       │                           # plus CONDITIONAL triggers chaining bronze -> silver -> gold
│       ├── glue.tf                 # Glue jobs/triggers for bronze, silver, and gold
│       ├── redshift.tf             # Redshift cluster, lake_external schema, gold schema
│       ├── lambda_text_udf.tf      # get-text-from-s3 Lambda + IAM roles + gold.get_text_from_s3 external function
│       └── scripts/
│           ├── source_to_bronze_offload.py # CSV -> bronze Iceberg w/ terms claim-check (raw_data_with_pointers)
│           ├── dq_checks.py                # Extensible DQCheck framework + CHECK_REGISTRY
│           ├── config/
│           │   └── dq_rules.json           # Declarative DQ rule config (which checks, which columns)
│           ├── bronze_to_silver.py          # bronze Iceberg -> silver + silver_quarantine Iceberg
│           ├── silver_to_gold.py            # silver Iceberg -> native gold.gold_data (Redshift Data API)
│           └── get_text_from_s3/
│               └── handler.py               # Lambda behind gold.get_text_from_s3 (guardrailed inline text retrieval)
```
