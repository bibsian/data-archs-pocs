# Event-driven trigger — automatically runs source_to_bronze_offload when a
# .csv lands in the source bucket, via native S3 -> EventBridge -> Glue
# Workflow integration. The source_to_bronze job keeps its manual ON_DEMAND
# trigger in glue.tf for ad-hoc re-runs.

# 1. Enable EventBridge notifications on the source bucket (native S3
#    integration — no CloudTrail trail required).
resource "aws_s3_bucket_notification" "source_eventbridge" {
  bucket      = aws_s3_bucket.source.id
  eventbridge = true
}

# 2. Glue Workflow — required wrapper for EVENT-type triggers. EventBridge
#    can only target a Glue Workflow ARN, not a trigger or job ARN directly.
resource "aws_glue_workflow" "source_to_bronze" {
  name        = "${var.project_name}-source-to-bronze-workflow"
  description = "Event-driven wrapper - starts source_to_bronze_offload job when a CSV lands in the source bucket"

  tags = {
    Project = var.project_name
  }
}

# 3. EVENT-type trigger inside that workflow. Must be created (and stay)
#    with enabled = false — unlike ON_DEMAND/SCHEDULED/CONDITIONAL triggers,
#    EVENT triggers have no activate/deactivate lifecycle at all: the Glue
#    API rejects StartTrigger/StopTrigger unconditionally for this type
#    (see https://github.com/hashicorp/terraform-provider-aws/issues/49407).
#    Once created in the CREATED state and wired to a workflow with an
#    enabled EventBridge rule/target, it is already fully functional — no
#    separate activation step is needed or possible.
resource "aws_glue_trigger" "source_to_bronze_on_upload" {
  name          = "${var.project_name}-source-to-bronze-event-trigger"
  type          = "EVENT"
  workflow_name = aws_glue_workflow.source_to_bronze.name
  enabled       = false

  actions {
    job_name = aws_glue_job.source_to_bronze_offload.name
  }

  event_batching_condition {
    batch_size   = 1 # fire immediately per matching upload, no batching
    batch_window = 900
  }

  tags = {
    Project = var.project_name
  }
}

# 4. IAM role EventBridge assumes to notify the Glue workflow.
data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_to_glue" {
  name               = "${var.project_name}-eventbridge-to-glue"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json

  tags = {
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "eventbridge_to_glue" {
  statement {
    sid       = "NotifyGlueWorkflow"
    effect    = "Allow"
    actions   = ["glue:NotifyEvent"]
    resources = [aws_glue_workflow.source_to_bronze.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_to_glue" {
  name   = "eventbridge-notify-glue"
  role   = aws_iam_role.eventbridge_to_glue.id
  policy = data.aws_iam_policy_document.eventbridge_to_glue.json
}

# 5. IAM propagation buffer. We previously hit a Glue job run failure caused
#    by IAM eventual consistency (a freshly created role wasn't assumable by
#    another AWS service seconds after creation). Guard against the same
#    class of failure here before EventBridge's target tries to assume this
#    role for the first time.
resource "time_sleep" "wait_for_eventbridge_role" {
  depends_on      = [aws_iam_role_policy.eventbridge_to_glue]
  create_duration = "20s"
}

# 6. EventBridge rule — matches S3 "Object Created" events on the source
#    bucket, filtered to .csv keys only.
resource "aws_cloudwatch_event_rule" "source_csv_uploaded" {
  name = "${var.project_name}-source-csv-uploaded"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.source.bucket] }
      object = { key = [{ suffix = ".csv" }] }
    }
  })

  tags = {
    Project = var.project_name
  }

  depends_on = [aws_s3_bucket_notification.source_eventbridge]
}

# 7. EventBridge target — the Glue Workflow ARN, invoked via the role above.
resource "aws_cloudwatch_event_target" "trigger_glue_workflow" {
  rule     = aws_cloudwatch_event_rule.source_csv_uploaded.name
  arn      = aws_glue_workflow.source_to_bronze.arn
  role_arn = aws_iam_role.eventbridge_to_glue.arn

  depends_on = [time_sleep.wait_for_eventbridge_role]
}

# 8. Medallion chaining — CONDITIONAL triggers extend the same workflow so
#    the full bronze -> silver -> gold pipeline runs automatically for every
#    CSV upload, with no extra EventBridge rules needed. Unlike the EVENT
#    trigger above, CONDITIONAL triggers do support start/stop; setting
#    start_on_creation = true activates them immediately on `apply`.
resource "aws_glue_trigger" "start_silver_on_bronze_success" {
  name          = "${var.project_name}-start-silver-on-bronze-success"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.source_to_bronze.name

  start_on_creation = true

  predicate {
    conditions {
      job_name = aws_glue_job.source_to_bronze_offload.name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }

  tags = {
    Project = var.project_name
  }
}

# Fans out in parallel with start_silver_on_bronze_success above — both fire
# off the same bronze SUCCEEDED condition, so the terms_text catalog stays
# in sync with every CSV upload without adding latency to the silver/gold
# chain.
resource "aws_glue_trigger" "start_terms_catalog_on_bronze_success" {
  name          = "${var.project_name}-start-terms-catalog-on-bronze-success"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.source_to_bronze.name

  start_on_creation = true

  predicate {
    conditions {
      job_name = aws_glue_job.source_to_bronze_offload.name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.terms_to_catalog.name
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_glue_trigger" "start_gold_on_silver_success" {
  name          = "${var.project_name}-start-gold-on-silver-success"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.source_to_bronze.name

  start_on_creation = true

  predicate {
    conditions {
      job_name = aws_glue_job.bronze_to_silver.name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.silver_to_gold.name
  }

  tags = {
    Project = var.project_name
  }
}
