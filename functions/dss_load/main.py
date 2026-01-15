"""
FILE: functions/dss_load/main.py
PURPOSE: Cloud Function that loads CSV data into Cloud SQL

This function is triggered when a CSV file is uploaded to the staging bucket.
It reads the file, validates the data, and inserts it into Cloud SQL.

COMPONENT: 21 - Cloud Functions (DSS Load)
"""

import os
import csv
import json
import logging
from io import StringIO
from datetime import datetime

from google.cloud import storage
import sqlalchemy
from sqlalchemy import create_engine, text
import functions_framework

# Setup structured logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment variables
PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")
DB_NAME = os.environ.get("DB_NAME", "insurance_db")
DB_USER = os.environ.get("DB_USER", "insurance_app")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
INSTANCE_CONNECTION_NAME = os.environ.get("INSTANCE_CONNECTION_NAME", "")

def get_db_engine():
    """Create database connection using Unix socket (Cloud Run/Cloud Functions)"""
    db_socket_dir = "/cloudsql"
    
    return create_engine(
        sqlalchemy.engine.url.URL.create(
            drivername="postgresql+pg8000",
            username=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME,
            query={
                "unix_sock": f"{db_socket_dir}/{INSTANCE_CONNECTION_NAME}/.s.PGSQL.5432"
            }
        ),
        pool_size=1,        # Functions only need 1 connection
        max_overflow=0,
        pool_timeout=30,
    )


@functions_framework.cloud_event
def load_dss_data(cloud_event):
    """
    Main entry point - triggered by Pub/Sub message from Cloud Storage.
    
    Args:
        cloud_event: Contains the Pub/Sub message with file details
    """
    # Extract file info from the Pub/Sub message
    # The message is base64 encoded JSON
    import base64
    
    message_data = cloud_event.data.get("message", {})
    attributes = message_data.get("attributes", {})
    
    bucket_name = attributes.get("bucketId", "")
    file_name = attributes.get("objectId", "")
    
    if not bucket_name or not file_name:
        logger.error("Missing bucket or file name in event")
        return
    
    logger.info(f"Processing file: gs://{bucket_name}/{file_name}")
    
    # Determine file type and route to appropriate loader
    if "policies" in file_name.lower():
        rows_loaded = load_policies(bucket_name, file_name)
    elif "claims" in file_name.lower():
        rows_loaded = load_claims(bucket_name, file_name)
    else:
        logger.warning(f"Unknown file type: {file_name}. Skipping.")
        return
    
    logger.info(f"Successfully loaded {rows_loaded} rows from {file_name}")
    return {"rows_loaded": rows_loaded, "file": file_name}


def read_csv_from_gcs(bucket_name: str, file_name: str) -> list:
    """Download and parse a CSV file from Cloud Storage"""
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(file_name)
    
    # Download as string
    content = blob.download_as_string().decode("utf-8")
    
    # Parse CSV
    reader = csv.DictReader(StringIO(content))
    rows = list(reader)
    
    logger.info(f"Read {len(rows)} rows from {file_name}")
    return rows


def load_policies(bucket_name: str, file_name: str) -> int:
    """
    Load policies from CSV into the policies table.
    
    Expected CSV columns:
    policy_id, customer_name, policy_type, premium_amount,
    coverage_amount, start_date, end_date, status
    """
    rows = read_csv_from_gcs(bucket_name, file_name)
    
    if not rows:
        logger.warning("Empty file, nothing to load")
        return 0
    
    engine = get_db_engine()
    loaded = 0
    errors = 0
    
    with engine.connect() as conn:
        for row in rows:
            try:
                # Validate required fields
                required = ["policy_id", "customer_name", "policy_type"]
                if not all(row.get(f) for f in required):
                    logger.warning(f"Skipping row with missing required fields: {row}")
                    errors += 1
                    continue
                
                # Upsert: insert if not exists, update if exists
                # This makes the function idempotent (safe to run multiple times)
                conn.execute(
                    text("""
                        INSERT INTO policies 
                            (policy_id, customer_name, policy_type, premium_amount, 
                             coverage_amount, start_date, end_date, status, last_updated)
                        VALUES 
                            (:policy_id, :customer_name, :policy_type, :premium_amount,
                             :coverage_amount, :start_date, :end_date, :status, NOW())
                        ON CONFLICT (policy_id) DO UPDATE SET
                            customer_name = EXCLUDED.customer_name,
                            policy_type = EXCLUDED.policy_type,
                            premium_amount = EXCLUDED.premium_amount,
                            coverage_amount = EXCLUDED.coverage_amount,
                            start_date = EXCLUDED.start_date,
                            end_date = EXCLUDED.end_date,
                            status = EXCLUDED.status,
                            last_updated = NOW()
                    """),
                    {
                        "policy_id": row["policy_id"].strip(),
                        "customer_name": row["customer_name"].strip(),
                        "policy_type": row.get("policy_type", "auto").strip(),
                        "premium_amount": float(row.get("premium_amount", 0)),
                        "coverage_amount": float(row.get("coverage_amount", 0)),
                        "start_date": row.get("start_date", "2024-01-01"),
                        "end_date": row.get("end_date", "2025-01-01"),
                        "status": row.get("status", "active").strip()
                    }
                )
                loaded += 1
                
            except Exception as e:
                logger.error(f"Error loading row {row.get('policy_id', 'unknown')}: {e}")
                errors += 1
        
        conn.commit()
    
    logger.info(f"Policies: {loaded} loaded, {errors} errors")
    return loaded


def load_claims(bucket_name: str, file_name: str) -> int:
    """Load claims from CSV into the claims table."""
    rows = read_csv_from_gcs(bucket_name, file_name)
    
    if not rows:
        return 0
    
    engine = get_db_engine()
    loaded = 0
    
    with engine.connect() as conn:
        for row in rows:
            try:
                conn.execute(
                    text("""
                        INSERT INTO claims
                            (claim_id, policy_id, claim_date, claim_amount, description, status, last_updated)
                        VALUES
                            (:claim_id, :policy_id, :claim_date, :claim_amount, :description, :status, NOW())
                        ON CONFLICT (claim_id) DO UPDATE SET
                            status = EXCLUDED.status,
                            last_updated = NOW()
                    """),
                    {
                        "claim_id": row["claim_id"].strip(),
                        "policy_id": row["policy_id"].strip(),
                        "claim_date": row.get("claim_date", datetime.today().date()),
                        "claim_amount": float(row.get("claim_amount", 0)),
                        "description": row.get("description", ""),
                        "status": row.get("status", "pending").strip()
                    }
                )
                loaded += 1
            except Exception as e:
                logger.error(f"Error loading claim {row.get('claim_id', 'unknown')}: {e}")
        
        conn.commit()
    
    return loaded
