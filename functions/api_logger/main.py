"""
FILE: functions/api_logger/main.py
PURPOSE: Receives API log events from Pub/Sub and writes to BigQuery
"""
import os
import json
import base64
import logging
from datetime import datetime

from google.cloud import bigquery
import functions_framework

logger = logging.getLogger(__name__)

PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")
BQ_DATASET = os.environ.get("BQ_DATASET", "")
BQ_TABLE = os.environ.get("BQ_TABLE", "api_request_logs")

bq_client = bigquery.Client()


@functions_framework.cloud_event
def log_api_request(cloud_event):
    """Write API request log to BigQuery"""
    message = cloud_event.data.get("message", {})
    data = message.get("data", "")
    
    if not data:
        return
    
    try:
        log_entry = json.loads(base64.b64decode(data).decode("utf-8"))
    except Exception as e:
        logger.error(f"Failed to decode message: {e}")
        return
    
    table_id = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"
    
    errors = bq_client.insert_rows_json(table_id, [log_entry])
    
    if errors:
        logger.error(f"BigQuery insert errors: {errors}")
    else:
        logger.info(f"Logged request {log_entry.get('request_id')} to BigQuery")
