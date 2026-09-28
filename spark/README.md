# Local Spark sandbox

A standalone, **fully offline** local-mode PySpark environment for debugging
PySpark/Iceberg code. This folder is self-contained: it isn't referenced by
any Terraform project, nothing in it is deployed anywhere, and it doesn't
touch AWS. It exists purely so you can run and step through PySpark logic
against a local `local[*]` Spark session before/without ever running it as a
real AWS Glue job.

It's built on AWS's own local-development image for Glue 5.0 jobs
(`public.ecr.aws/glue/aws-glue-libs:5`), so the Spark (3.5.4), Python
(3.11), and Iceberg (1.7.1) versions match what the real jobs under
[terraform/medallion-fulltext-udf/scripts/](../terraform/medallion-fulltext-udf/scripts/)
run in production. That image supports `arm64` natively, so it runs without
emulation on Apple Silicon.

## Prerequisites

- Docker Desktop (or another Docker Engine) running locally.

No AWS credentials, profile, or network access are required for anything in
this folder.

## Quick start

```bash
# Build the image and start the container (JupyterLab starts automatically)
spark/scripts/up.sh

# Terminal-based debugging (pick either/both):
spark/scripts/shell.sh                                   # pyspark REPL
spark/scripts/submit.sh spark/jobs/local_bronze_offload.py  # spark-submit

# Notebook-based debugging:
open http://localhost:8888   # token-less JupyterLab, rooted at the repo root

# Stop the container when done
spark/scripts/down.sh
```

Spark UI (while a job or REPL session is active) is at
http://localhost:4040.

## What's in here

| Path | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | Extends `aws-glue-libs:5` with JupyterLab + ipykernel. |
| [docker-compose.yml](docker-compose.yml) | Single `pyspark` service; mounts the whole repo at `/home/hadoop/workspace`. |
| [scripts/up.sh](scripts/up.sh) / [down.sh](scripts/down.sh) | Build+start / stop the container. |
| [scripts/shell.sh](scripts/shell.sh) | Interactive `pyspark` REPL inside the running container. |
| [scripts/submit.sh](scripts/submit.sh) | Runs `spark-submit <path> [args...]` inside the running container. `<path>` is relative to the repo root. |
| [scripts/run-local-pipeline.sh](scripts/run-local-pipeline.sh) | Runs the two `jobs/` scripts below in sequence, end to end. |
| [lib/local_spark.py](lib/local_spark.py) | `get_local_spark(app_name)` -- a local-mode `SparkSession` wired to a local filesystem Iceberg catalog (`local_catalog`, warehouse at `spark/warehouse/`). Import this from any script or notebook instead of hand-rolling Spark/Iceberg config. |
| [jobs/local_bronze_offload.py](jobs/local_bronze_offload.py) | Offline analog of `source_to_bronze_offload.py`: offloads `terms` text to local files instead of S3, writes an Iceberg bronze table locally. |
| [jobs/local_bronze_to_silver.py](jobs/local_bronze_to_silver.py) | Offline analog of `bronze_to_silver.py`: imports the **real, unmodified** `dq_checks.py` and `config/dq_rules.json` from `terraform/medallion-fulltext-udf/scripts/`, runs the same DQ checks, and splits into local silver / quarantine Iceberg tables. |
| `warehouse/` (git-ignored, created on first run) | The local Iceberg catalog's data + `_terms/` text blobs. |

`silver_to_gold.py` isn't mirrored here: it has no Spark transformation
logic of its own (it's a `DROP`/`CREATE TABLE AS SELECT` issued through the
Redshift Data API), so there's nothing local-mode Spark can help debug
there.

## Demo: run the bronze -> silver pipeline locally

```bash
spark/scripts/up.sh
spark/scripts/run-local-pipeline.sh
```

This reads the sample CSV in [data/](../data/), offloads `terms` to local
files, writes the bronze Iceberg table, runs the DQ checks from the real
`dq_rules.json`, and writes silver + quarantine Iceberg tables -- all under
`spark/warehouse/`. Inspect the results:

```bash
spark/scripts/shell.sh
```

```python
spark.sql("SELECT * FROM local_catalog.bronze.raw_data_with_pointers LIMIT 5").show()
spark.sql("SELECT * FROM local_catalog.silver.silver_data LIMIT 5").show()
spark.sql("SELECT * FROM local_catalog.silver.silver_data_quarantine LIMIT 5").show()
```

## Debugging your own PySpark code

From a notebook or a new script under `spark/jobs/`:

```python
import sys
sys.path.insert(0, "/home/hadoop/workspace/spark/lib")
from local_spark import get_local_spark

spark = get_local_spark("my-debug-session")
df = spark.read.csv("/home/hadoop/workspace/data/your_file.csv", header=True, inferSchema=True)
df.show()
```

To debug a real Glue script's *pure-Spark* logic (no `awsglue`/S3/Glue
Catalog calls), you can also import functions directly from it -- as
`local_bronze_to_silver.py` does with `dq_checks.py` -- by adding
`terraform/medallion-fulltext-udf/scripts/` to `sys.path`.

## Resetting the local catalog

The local Iceberg warehouse and offloaded `terms` files are just plain
files on your host at `spark/warehouse/` (git-ignored). To start over:

```bash
rm -rf spark/warehouse
```

## Graduating logic back to the real pipeline

Once you've validated some logic here (e.g. a new DQ check type, a
transformation tweak), port the change into the real files under
`terraform/medallion-fulltext-udf/scripts/` and redeploy via Terraform as
usual (see the root [README.md](../README.md)). Nothing in `spark/` is
picked up by Terraform or any deploy process -- it's a debugging aid only.
