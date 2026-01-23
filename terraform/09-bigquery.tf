# ============================================================
# FILE: 09-bigquery.tf
# PURPOSE: Analytics, logging and reporting data warehouse
# ============================================================
# ANALOGY: BigQuery is like a giant spreadsheet that can hold
# billions of rows and answer complex questions in seconds.
# Regular databases (Cloud SQL) are for running your app.
# BigQuery is for analysing what happened after the fact.
#
# Think of it like: Cloud SQL = the shop till (real-time transactions)
#                   BigQuery = the accountant's books (analysis)
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 27: BigQuery (CX Raw Logs)
# - Component 28: Scheduled Queries
# - Component 29: BigQuery (Reporting - Processed Logs)
# ============================================================

# -----------------------------------
# BIGQUERY DATASET - RAW LOGS (Component 27)
# -----------------------------------
# A dataset in BigQuery is like a folder - it contains tables.
# This dataset holds raw, unprocessed log data from the API.

resource "google_bigquery_dataset" "cx_raw_logs" {
  depends_on = [google_project_service.bigquery_api]

  project    = var.gcp_project_id
  dataset_id = "insurance_${var.environment}_cx_raw_logs"
  # dataset_id can only contain letters, numbers, underscores
  # No hyphens allowed (unlike most other GCP resource names)

  friendly_name = "CX Raw Logs - ${var.environment}"
  description   = "Raw API request and response logs from CX interactions. Component 27 in architecture."

  location = var.gcp_region
  # WHERE data is stored physically
  # Keep same region as your other services to avoid cross-region data transfer costs

  # How long to keep data before auto-deletion (in milliseconds)
  default_table_expiration_ms = null
  # null = no expiration (keep forever)
  # For raw logs you might set: 7776000000 (90 days = 90 * 24 * 60 * 60 * 1000)

  # delete_contents_on_destroy = true allows terraform destroy to delete non-empty datasets
  delete_contents_on_destroy = true
  # Set to false in production to protect data from accidental deletion

  labels = {
    environment = var.environment
    purpose     = "cx-raw-logs"
    data_class  = "operational"
  }
}

# -----------------------------------
# BIGQUERY TABLE - API Request Logs
# -----------------------------------
# The actual table that stores log entries.
# Schema defines what columns each row has.

resource "google_bigquery_table" "api_request_logs" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.cx_raw_logs.dataset_id
  table_id   = "api_request_logs"

  description = "Raw log of every API request. One row per request."

  deletion_protection = false
  # false = allow deleting this table via terraform destroy

  # time_partitioning makes queries faster and cheaper
  # Instead of scanning all data, queries only scan the relevant partition
  time_partitioning {
    type  = "DAY"
    # Partition by day - each day's data is stored separately
    # A query for "last 7 days" only scans 7 partitions instead of all data

    field = "request_timestamp"
    # Which column to partition on (must be a TIMESTAMP or DATE column)

    expiration_ms = 7776000000
    # Auto-delete partitions older than 90 days
    # Raw logs don't need to be kept forever
  }

  # clustering further organises data within each partition for faster queries
  clustering = ["endpoint", "response_status_code"]
  # Within each day partition, data is sorted by endpoint then status code
  # A query like "all 500 errors on /claims yesterday" is very fast

  # Schema - the columns of this table
  # BigQuery uses JSON schema definition
  schema = jsonencode([
    {
      name        = "request_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Unique identifier for this request (UUID)"
    },
    {
      name        = "request_timestamp"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "When the request was received (UTC)"
    },
    {
      name        = "endpoint"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "API endpoint called. e.g. /api/v1/policies/{id}"
    },
    {
      name        = "http_method"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "HTTP method: GET, POST, PUT, DELETE"
    },
    {
      name        = "response_status_code"
      type        = "INTEGER"
      mode        = "REQUIRED"
      description = "HTTP response code: 200, 201, 400, 404, 500 etc"
    },
    {
      name        = "response_time_ms"
      type        = "INTEGER"
      mode        = "REQUIRED"
      description = "How long the request took in milliseconds"
    },
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "ID of the authenticated user (null for unauthenticated requests)"
    },
    {
      name        = "session_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Dialogflow CX session ID if request came from chatbot"
    },
    {
      name        = "request_source"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Where request came from: dialogflow, genesys, direct_api"
    },
    {
      name        = "error_message"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Error details if request failed (null for successful requests)"
    },
    {
      name        = "cloud_run_instance"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Which Cloud Run instance handled this request"
    }
  ])

  labels = {
    environment = var.environment
  }
}

# -----------------------------------
# BIGQUERY TABLE - Policy Activity Logs
# -----------------------------------
resource "google_bigquery_table" "policy_activity_logs" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.cx_raw_logs.dataset_id
  table_id   = "policy_activity_logs"

  description = "Log of all policy-related actions (views, updates)"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "activity_timestamp"
  }

  schema = jsonencode([
    {
      name        = "activity_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Unique ID for this activity record"
    },
    {
      name        = "activity_timestamp"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "When the activity occurred"
    },
    {
      name        = "policy_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "The policy that was accessed or modified"
    },
    {
      name        = "action_type"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "What happened: VIEW, UPDATE, CLAIM_FILED, CLAIM_STATUS_CHECK"
    },
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Who performed the action"
    },
    {
      name        = "channel"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "How they accessed it: chatbot, web_portal, api_direct"
    }
  ])
}

# -----------------------------------
# BIGQUERY DATASET - REPORTING (Component 29)
# -----------------------------------
# This dataset holds processed, aggregated data ready for reporting.
# Data flows from cx_raw_logs → scheduled queries → this dataset.
#
# MAPS TO: Component 29 - "BigQuery (Reporting Processed Logs)"

resource "google_bigquery_dataset" "reporting" {
  project    = var.gcp_project_id
  dataset_id = "insurance_${var.environment}_reporting"

  friendly_name = "Reporting - ${var.environment}"
  description   = "Processed and aggregated reporting data. Fed by scheduled queries from raw logs. Component 29."

  location                    = var.gcp_region
  delete_contents_on_destroy  = true

  labels = {
    environment = var.environment
    purpose     = "reporting"
  }
}

# Reporting table - daily summary
resource "google_bigquery_table" "daily_api_summary" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.reporting.dataset_id
  table_id   = "daily_api_summary"

  description = "Daily aggregated API metrics. Generated by scheduled query."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "report_date"
  }

  schema = jsonencode([
    {
      name        = "report_date"
      type        = "DATE"
      mode        = "REQUIRED"
      description = "The date this summary covers"
    },
    {
      name        = "total_requests"
      type        = "INTEGER"
      mode        = "REQUIRED"
      description = "Total API requests that day"
    },
    {
      name        = "successful_requests"
      type        = "INTEGER"
      mode        = "REQUIRED"
      description = "Requests that returned 2xx status"
    },
    {
      name        = "error_requests"
      type        = "INTEGER"
      mode        = "REQUIRED"
      description = "Requests that returned 4xx or 5xx status"
    },
    {
      name        = "error_rate_pct"
      type        = "FLOAT"
      mode        = "REQUIRED"
      description = "Error percentage: error_requests / total_requests * 100"
    },
    {
      name        = "avg_response_time_ms"
      type        = "FLOAT"
      mode        = "REQUIRED"
      description = "Average response time in milliseconds"
    },
    {
      name        = "p99_response_time_ms"
      type        = "FLOAT"
      mode        = "REQUIRED"
      description = "99th percentile response time (slowest 1% of requests)"
    },
    {
      name        = "unique_users"
      type        = "INTEGER"
      mode        = "REQUIRED"
      description = "Count of distinct users who made requests"
    },
    {
      name        = "chatbot_sessions"
      type        = "INTEGER"
      mode        = "NULLABLE"
      description = "Number of Dialogflow CX chatbot sessions"
    },
    {
      name        = "claims_filed"
      type        = "INTEGER"
      mode        = "NULLABLE"
      description = "Number of new claims filed via API"
    }
  ])
}

# -----------------------------------
# SCHEDULED QUERIES (Component 28)
# -----------------------------------
# Scheduled queries run automatically on a schedule.
# Like a cron job that runs SQL.
# They read from raw logs and write aggregated data to reporting.
#
# MAPS TO: Component 28 - "via Scheduled Queries"

resource "google_bigquery_data_transfer_config" "daily_summary_query" {
  depends_on = [
    google_bigquery_table.api_request_logs,
    google_bigquery_table.daily_api_summary,
  ]

  project        = var.gcp_project_id
  display_name   = "Daily API Summary Query"
  location       = var.gcp_region
  data_source_id = "scheduled_query"
  # data_source_id = "scheduled_query" means this is a scheduled SQL query

  schedule = "every 24 hours"
  # Runs once per day
  # Other formats:
  # "every 1 hours" = hourly
  # "every monday 09:00" = weekly on Mondays at 9am
  # "1 of month 00:00" = first day of month at midnight

  destination_dataset_id = google_bigquery_dataset.reporting.dataset_id
  # Where to write results

  params = {
    query = <<-SQL
      -- Daily API Summary Query
      -- Runs every 24 hours to aggregate previous day's logs into reporting table
      
      INSERT INTO `${var.gcp_project_id}.insurance_${var.environment}_reporting.daily_api_summary`
      
      SELECT
        DATE(request_timestamp) AS report_date,
        COUNT(*) AS total_requests,
        COUNTIF(response_status_code BETWEEN 200 AND 299) AS successful_requests,
        COUNTIF(response_status_code >= 400) AS error_requests,
        ROUND(
          COUNTIF(response_status_code >= 400) / COUNT(*) * 100, 2
        ) AS error_rate_pct,
        ROUND(AVG(response_time_ms), 2) AS avg_response_time_ms,
        ROUND(
          PERCENTILE_CONT(response_time_ms, 0.99) OVER(), 2
        ) AS p99_response_time_ms,
        COUNT(DISTINCT user_id) AS unique_users,
        COUNTIF(request_source = 'dialogflow') AS chatbot_sessions,
        COUNTIF(
          endpoint LIKE '/api/v1/claims%' AND http_method = 'POST'
        ) AS claims_filed
        
      FROM `${var.gcp_project_id}.insurance_${var.environment}_cx_raw_logs.api_request_logs`
      
      WHERE
        -- Only process yesterday's data
        DATE(request_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
      
      GROUP BY
        DATE(request_timestamp)
    SQL

    destination_table_name_template = "daily_api_summary"
    write_disposition                = "WRITE_APPEND"
    # WRITE_APPEND = add new rows (don't overwrite existing data)
  }
}

# -----------------------------------
# BIGQUERY VIEWS (Component 30)
# -----------------------------------
# Views are saved SQL queries that look like tables.
# Useful for creating simplified views of complex data for reporting.

resource "google_bigquery_table" "weekly_claims_report" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.reporting.dataset_id
  table_id   = "weekly_claims_report"

  description = "View showing weekly claims activity for management reporting"
  deletion_protection = false

  # view = a saved SQL query (not stored data)
  view {
    query = <<-SQL
      SELECT
        DATE_TRUNC(report_date, WEEK) AS week_starting,
        SUM(claims_filed) AS total_claims_filed,
        SUM(total_requests) AS total_api_requests,
        ROUND(AVG(error_rate_pct), 2) AS avg_error_rate,
        ROUND(AVG(avg_response_time_ms), 2) AS avg_response_time_ms
      FROM
        `${var.gcp_project_id}.insurance_${var.environment}_reporting.daily_api_summary`
      GROUP BY
        DATE_TRUNC(report_date, WEEK)
      ORDER BY
        week_starting DESC
    SQL

    use_legacy_sql = false
    # use_legacy_sql = false means use standard SQL (not BigQuery's old legacy syntax)
    # Always use false - legacy SQL is deprecated
  }
}
