"""
Optional: schedule the validation pipeline with Apache Airflow.

Watches nothing fancy - it simply runs the pipeline daily against whatever submission
is in the data folder. In a council setting the trigger would be a new submission
arriving (e.g. a file sensor on the as-constructed inbox).
Requires Airflow 2.4+ (uses the `schedule` argument).
"""
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

PROJECT = "/opt/projects/asset-dq-framework"   # change to your project path

with DAG(
    dag_id="asset_dq_as_constructed_validation",
    start_date=datetime(2026, 11, 1),
    schedule="@daily",
    catchup=False,
    default_args={"retries": 1, "retry_delay": timedelta(minutes=5)},
    tags=["asset-management", "data-quality"],
) as dag:
    run_pipeline = BashOperator(
        task_id="validate_and_integrate",
        bash_command=f"cd {PROJECT} && python src/run_pipeline.py --no-score",
    )
