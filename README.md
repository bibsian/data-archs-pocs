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
│       └── outputs.tf
│       └── scripts/
│           └── source_to_bronze.py # EMR job to pickup files from s3 and convert to icerberg
```
