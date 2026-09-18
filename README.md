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

### `s3-bucket-to-iceberg` — automatic trigger

Uploading a `.csv` to the source bucket automatically kicks off the `source_to_bronze_offload` Glue job (via a native S3 → EventBridge → Glue Workflow chain — see `eventbridge.tf`). The `source_to_bronze` job is still available via its `ON_DEMAND` trigger for manual re-runs.

```bash
# Upload a test file to trigger the pipeline
aws s3 cp sample.csv s3://<source_bucket_name>/ --profile pluralsight

# Check for a new workflow run
aws glue get-workflow-runs --name <glue_workflow_name> --profile pluralsight
```

The bucket/workflow names are printed as Terraform outputs (`source_bucket_name`, `glue_workflow_name`) after `apply`.

### Query the offload Iceberg table from Redshift

This project provisions a private, single-node Redshift `ra3.large` cluster.
It is administered through the Redshift Data API, so no inbound network access
or desktop SQL client is required. Terraform creates `lake_external`, an
external schema that maps to the project's Glue catalog database.

That Glue database is shared by both bronze jobs, so Redshift discovers both
`raw_data` and `raw_data_with_pointers`. For the EventBridge-triggered offload
pipeline, query `raw_data_with_pointers` after its first successful workflow
run.

```bash
cd terraform/s3-bucket-to-iceberg

aws redshift-data execute-statement \
  --cluster-identifier "$(terraform output -raw redshift_cluster_identifier)" \
  --database "$(terraform output -raw redshift_database_name)" \
  --secret-arn "$(terraform output -raw redshift_admin_secret_arn)" \
  --sql "SELECT * FROM $(terraform output -raw redshift_offload_table) LIMIT 10" \
  --profile pluralsight
```

The command returns an `Id`. Inspect it with `aws redshift-data describe-statement --id <Id> --profile pluralsight`, then retrieve rows with `aws redshift-data get-statement-result --id <Id> --profile pluralsight`.

## Project structure

Each IaC framework has its own folder, with individual projects as subdirectories.
To add a new project, create a new subdirectory (e.g. `terraform/vpc/` or `serverless/my-api/`).

```
aws_learn/
├── scripts/
│   ├── configure-sandbox.sh       # Set sandbox credentials each session
│   └── tf-guard.sh                # Archive stale state from a previous sandbox account
├── terraform/
│   └── s3-bucket-to-iceberg/                 # Project: S3 bucket example
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── eventbridge.tf          # S3 -> EventBridge -> Glue Workflow auto-trigger
│       └── scripts/
│           └── source_to_bronze.py # EMR job to pickup files from s3 and convert to icerberg
```
