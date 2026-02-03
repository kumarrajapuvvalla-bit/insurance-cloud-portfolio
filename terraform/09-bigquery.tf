# -----------------------------------
# RAW LOGS DATASET
# -----------------------------------

resource "google_bigquery_dataset" "cx_raw_logs" {
  depends_on = [google_project_service.bigquery_api]

  project       = var.gcp_project_id
  dataset_id    = "insurance_${var.environment}_cx_raw_logs"
  friendly_name = "CX Raw Logs - ${var.environment}"
  description   = "Raw API request logs from all CX interactions"
  location      = var.gcp_region

  default_table_expiration_ms = null
  delete_contents_on_destroy  = true

  labels = {
    environment = var.environment
    purpose     = "cx-raw-logs"
    data_class  = "operational"
  }
}

resource "google_bigquery_table" "api_request_logs" {
  project             = var.gcp_project_id
  dataset_id          = google_bigquery_dataset.cx_raw_logs.dataset_id
  table_id            = "api_request_logs"
  description         = "One row per API request"
  deletion_protection = false

  # Day partitioning keeps query costs low — scans only the relevant days
  time_partitioning {
    type          = "DAY"
    field         = "request_timestamp"
    expiration_ms = 7776000000 # 90 days
  }

  # Clustering on endpoint + status code speeds up the most common filter patterns
  clustering = ["endpoint", "response_status_code"]

  schema = jsonencode([
    { name = "request_id",          type = "STRING",    mode = "REQUIRED", description = "Unique request UUID" },
    { name = "request_timestamp",   type = "TIMESTAMP", mode = "REQUIRED", description = "Request time (UTC)" },
    { name = "endpoint",            type = "STRING",    mode = "REQUIRED", description = "API path, e.g. /api/v1/policies/{id}" },
    { name = "http_method",         type = "STRING",    mode = "REQUIRED", description = "GET, POST, PUT, DELETE" },
    { name = "response_status_code",type = "INTEGER",   mode = "REQUIRED", description = "HTTP response code" },
    { name = "response_time_ms",    type = "INTEGER",   mode = "REQUIRED", description = "Request duration in milliseconds" },
    { name = "user_id",             type = "STRING",    mode = "NULLABLE", description = "Authenticated user ID" },
    { name = "session_id",          type = "STRING",    mode = "NULLABLE", description = "Dialogflow CX session ID" },
    { name = "request_source",      type = "STRING",    mode = "NULLABLE", description = "dialogflow | genesys | direct_api" },
    { name = "error_message",       type = "STRING",    mode = "NULLABLE", description = "Error detail on failure" },
    { name = "cloud_run_instance",  type = "STRING",    mode = "NULLABLE", description = "Cloud Run instance that handled the request" }
  ])

  labels = {
    environment = var.environment
  }
}

resource "google_bigquery_table" "policy_activity_logs" {
  project             = var.gcp_project_id
  dataset_id          = google_bigquery_dataset.cx_raw_logs.dataset_id
  table_id            = "policy_activity_logs"
  description         = "Audit log of all policy-related actions"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "activity_timestamp"
  }

  schema = jsonencode([
    { name = "activity_id",        type = "STRING",    mode = "REQUIRED", description = "Unique activity ID" },
    { name = "activity_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When the activity occurred" },
    { name = "policy_id",          type = "STRING",    mode = "REQUIRED", description = "Policy that was accessed or modified" },
    { name = "action_type",        type = "STRING",    mode = "REQUIRED", description = "VIEW | UPDATE | CLAIM_FILED | CLAIM_STATUS_CHECK" },
    { name = "user_id",            type = "STRING",    mode = "NULLABLE", description = "Who performed the action" },
    { name = "channel",            type = "STRING",    mode = "NULLABLE", description = "chatbot | web_portal | api_direct" }
  ])
}

# -----------------------------------
# REPORTING DATASET
# -----------------------------------
# Aggregated data produced by scheduled queries from raw logs.
# Kept separate from raw logs so reporting queries don't compete with ingestion.

resource "google_bigquery_dataset" "reporting" {
  project    = var.gcp_project_id
  dataset_id = "insurance_${var.environment}_reporting"

  friendly_name              = "Reporting - ${var.environment}"
  description                = "Aggregated reporting data. Populated by daily scheduled queries."
  location                   = var.gcp_region
  delete_contents_on_destroy = true

  labels = {
    environment = var.environment
    purpose     = "reporting"
  }
}

resource "google_bigquery_table" "daily_api_summary" {
  project             = var.gcp_project_id
  dataset_id          = google_bigquery_dataset.reporting.dataset_id
  table_id            = "daily_api_summary"
  description         = "Daily API metrics. Populated by scheduled query."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "report_date"
  }

  schema = jsonencode([
    { name = "report_date",          type = "DATE",    mode = "REQUIRED", description = "Date this row covers" },
    { name = "total_requests",       type = "INTEGER", mode = "REQUIRED", description = "Total API requests" },
    { name = "successful_requests",  type = "INTEGER", mode = "REQUIRED", description = "2xx responses" },
    { name = "error_requests",       type = "INTEGER", mode = "REQUIRED", description = "4xx + 5xx responses" },
    { name = "error_rate_pct",       type = "FLOAT",   mode = "REQUIRED", description = "Error %" },
    { name = "avg_response_time_ms", type = "FLOAT",   mode = "REQUIRED", description = "Average response time" },
    { name = "p99_response_time_ms", type = "FLOAT",   mode = "REQUIRED", description = "p99 response time" },
    { name = "unique_users",         type = "INTEGER", mode = "REQUIRED", description = "Distinct users" },
    { name = "chatbot_sessions",     type = "INTEGER", mode = "NULLABLE", description = "Dialogflow CX sessions" },
    { name = "claims_filed",         type = "INTEGER", mode = "NULLABLE", description = "New claims filed" }
  ])
}

# -----------------------------------
# SCHEDULED QUERY
# -----------------------------------

resource "google_bigquery_data_transfer_config" "daily_summary_query" {
  depends_on = [
    google_bigquery_table.api_request_logs,
    google_bigquery_table.daily_api_summary,
  ]

  project                = var.gcp_project_id
  display_name           = "Daily API Summary Query"
  location               = var.gcp_region
  data_source_id         = "scheduled_query"
  schedule               = "every 24 hours"
  destination_dataset_id = google_bigquery_dataset.reporting.dataset_id

  params = {
    query = <<-SQL
      INSERT INTO `${var.gcp_project_id}.insurance_${var.environment}_reporting.daily_api_summary`
      SELECT
        DATE(request_timestamp)                                                    AS report_date,
        COUNT(*)                                                                   AS total_requests,
        COUNTIF(response_status_code BETWEEN 200 AND 299)                         AS successful_requests,
        COUNTIF(response_status_code >= 400)                                       AS error_requests,
        ROUND(COUNTIF(response_status_code >= 400) / COUNT(*) * 100, 2)           AS error_rate_pct,
        ROUND(AVG(response_time_ms), 2)                                            AS avg_response_time_ms,
        ROUND(PERCENTILE_CONT(response_time_ms, 0.99) OVER(), 2)                  AS p99_response_time_ms,
        COUNT(DISTINCT user_id)                                                    AS unique_users,
        COUNTIF(request_source = 'dialogflow')                                     AS chatbot_sessions,
        COUNTIF(endpoint LIKE '/api/v1/claims%' AND http_method = 'POST')          AS claims_filed
      FROM `${var.gcp_project_id}.insurance_${var.environment}_cx_raw_logs.api_request_logs`
      WHERE DATE(request_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
      GROUP BY DATE(request_timestamp)
    SQL

    destination_table_name_template = "daily_api_summary"
    write_disposition                = "WRITE_APPEND"
  }
}

# -----------------------------------
# REPORTING VIEW
# -----------------------------------

resource "google_bigquery_table" "weekly_claims_report" {
  project             = var.gcp_project_id
  dataset_id          = google_bigquery_dataset.reporting.dataset_id
  table_id            = "weekly_claims_report"
  description         = "Weekly claims activity view for management reporting"
  deletion_protection = false

  view {
    query = <<-SQL
      SELECT
        DATE_TRUNC(report_date, WEEK)        AS week_starting,
        SUM(claims_filed)                    AS total_claims_filed,
        SUM(total_requests)                  AS total_api_requests,
        ROUND(AVG(error_rate_pct), 2)        AS avg_error_rate,
        ROUND(AVG(avg_response_time_ms), 2)  AS avg_response_time_ms
      FROM `${var.gcp_project_id}.insurance_${var.environment}_reporting.daily_api_summary`
      GROUP BY DATE_TRUNC(report_date, WEEK)
      ORDER BY week_starting DESC
    SQL
    use_legacy_sql = false
  }
}
