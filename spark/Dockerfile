# Local PySpark debugging sandbox.
#
# Extends AWS's own local-development image for Glue 5.0 jobs, which already
# ships Spark 3.5.4, Python 3.11, the `awsglue` library, and Iceberg/Hudi/Delta
# on the classpath -- matching what the real jobs under
# terraform/medallion-fulltext-udf/scripts/ use. This image is NOT deployed
# anywhere; it only exists to give you a local `local[*]` Spark session to
# debug PySpark code against, fully offline.
#
# See: https://docs.aws.amazon.com/glue/latest/dg/develop-local-docker-image.html
FROM public.ecr.aws/glue/aws-glue-libs:5

USER hadoop

# JupyterLab isn't bundled in the Glue 5.0 image (it was dropped upstream).
# We add just enough to run a notebook whose Python kernel can `import
# pyspark` directly -- no Livy/SparkMagic remote-kernel machinery needed for
# a single local container.
RUN python3.11 -m pip install --no-cache-dir --user jupyterlab ipykernel

ENV PATH="/home/hadoop/.local/bin:${PATH}"

WORKDIR /home/hadoop/workspace
