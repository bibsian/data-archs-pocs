"""
dq_checks.py

Configurable, extensible data-quality checks for the silver layer.

Design goal: adding or changing a QA rule should never require touching
bronze_to_silver.py (the pipeline script) or redeploying a Glue job. Instead:

  1. Which checks run, and on which columns, is driven entirely by a small
     JSON config (see scripts/config/dq_rules.json), deployed as an S3
     object and read by bronze_to_silver.py at job runtime via
     `--dq_config_s3_path`.
  2. New *types* of checks are added here by subclassing `DQCheck` and
     registering the subclass in `CHECK_REGISTRY`. No other code changes
     are needed.

A "check" inspects one column of a Spark DataFrame and adds exactly one
boolean result column: True means the row PASSES that check.

This module is shipped to the Glue job via `--extra-py-files` (see glue.tf)
so it can be imported like any other Python module.
"""

from pyspark.sql import DataFrame
from pyspark.sql.functions import array, array_remove, col, concat_ws, length, lit, trim, when


class DQCheck:
    """Base class for a single data-quality rule.

    Subclasses must set `self.column` (the column being checked) and
    implement `evaluate()`.
    """

    def __init__(self, column: str, **kwargs):
        self.column = column
        self.kwargs = kwargs

    @property
    def result_column(self) -> str:
        """Name of the boolean column this check adds to the DataFrame."""
        raise NotImplementedError

    def evaluate(self, df: DataFrame) -> DataFrame:
        """Return `df` with one new boolean column (`self.result_column`).
        True = row passes this check, False = row fails it.
        """
        raise NotImplementedError


class NotNullCheck(DQCheck):
    """Fails any row where `column` is NULL."""

    @property
    def result_column(self) -> str:
        return f"_dq_not_null_{self.column}"

    def evaluate(self, df: DataFrame) -> DataFrame:
        return df.withColumn(self.result_column, col(self.column).isNotNull())


class NotEmptyStringCheck(DQCheck):
    """Fails any row where `column` is NULL, or an empty/whitespace-only string."""

    @property
    def result_column(self) -> str:
        return f"_dq_not_empty_{self.column}"

    def evaluate(self, df: DataFrame) -> DataFrame:
        return df.withColumn(
            self.result_column,
            col(self.column).isNotNull() & (length(trim(col(self.column))) > 0),
        )


# ---------------------------------------------------------------------------
# Registry mapping a config "type" string to the DQCheck subclass that
# implements it. To add a new check type:
#   1. Subclass DQCheck above.
#   2. Add one line here: "your_type_name": YourCheckClass.
#   3. Reference "your_type_name" from scripts/config/dq_rules.json.
# ---------------------------------------------------------------------------
CHECK_REGISTRY = {
    "not_null": NotNullCheck,
    "not_empty_string": NotEmptyStringCheck,
}


def build_checks(config: dict) -> list:
    """Instantiate DQCheck objects from a parsed JSON config's `checks` list.

    Expected shape:
        {"checks": [{"type": "not_null", "columns": ["id", "terms"]}, ...]}

    Each entry may use "columns" (a list) or "column" (a single string).
    """
    checks = []
    for entry in config.get("checks", []):
        check_type = entry["type"]
        if check_type not in CHECK_REGISTRY:
            raise ValueError(
                f"Unknown DQ check type: {check_type!r}. "
                f"Registered types: {sorted(CHECK_REGISTRY)}"
            )
        cls = CHECK_REGISTRY[check_type]
        columns = entry.get("columns") or [entry["column"]]
        extra_kwargs = {k: v for k, v in entry.items() if k not in ("type", "columns", "column")}
        for column in columns:
            checks.append(cls(column=column, **extra_kwargs))
    return checks


def apply_checks(df: DataFrame, checks: list) -> DataFrame:
    """Run every check against `df`, then add two summary columns:

      _dq_passed        — True only if every check passed for that row
      _dq_failed_checks  — comma-joined names of any failed checks (or "")

    Returns the annotated DataFrame; the per-check result columns are also
    left in place so callers can inspect exactly which check(s) failed.
    """
    if not checks:
        return df.withColumn("_dq_passed", lit(True)).withColumn(
            "_dq_failed_checks", lit("").cast("string")
        )

    result_cols = []
    for check in checks:
        df = check.evaluate(df)
        result_cols.append(check.result_column)

    passed_col = col(result_cols[0])
    for c in result_cols[1:]:
        passed_col = passed_col & col(c)

    failed_names = array(*[when(~col(c), lit(c)) for c in result_cols])

    df = df.withColumn("_dq_passed", passed_col)
    df = df.withColumn("_dq_failed_checks", concat_ws(",", array_remove(failed_names, None)))
    return df
