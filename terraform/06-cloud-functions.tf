# ============================================================
# FILE: 06-cloud-functions.tf
# PURPOSE: Serverless functions for data processing pipeline
# ============================================================
# ANALOGY: Cloud Functions are like automated workers.
# You don't hire them full time (no server running 24/7).
# They wake up when there's a task, do the work, then go back to sleep.
# You only pay for the time they're actually working.
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 21: Cloud Functions (DSS Load) - loads CSV to Cloud SQL
# - Component 23: Workflow orchestrator - sequences the steps
# ============================================================

# -----------------------------------
# DSS LOAD CLOUD FUNCTION (Component 21)
# -----------------------------------
# PURPOSE: When a CSV file is uploaded to the staging bucket,
# this function wakes up, reads the file, and loads the data
# into Cloud SQL. This is your ETL pipeline.
#
# ETL = Extract, Transform, Load
# Extract  = read CSV from Cloud Storage
# Transform = clean and validate the data
# Load     = insert into Cloud SQL database
#
# MAPS TO: Component 21 - "Cloud Functions (DSS Load)"

# First, package the function code and upload to Cloud Storage
# Cloud Functions need their code in a ZIP file in Cloud Storage

data "archive_file" "dss_load_zip" {
  type        = "zip"
  # Zip the contents of the functions/dss_load folder
  source_dir  = "${path.module}/../functions/dss_load"
  output_path = "/tmp/dss_load_function.zip"
  # path.module = the directory containing this terraform file
  # ../functions/dss_load = go up one level, then into functions/dss_load
}

resource "google_storage_bucket_object" "dss_load_code" {
  name   = "functions/dss_load_${data.archive_file.dss_load_zip.output_md5}.zip"
  # Including the MD5 hash in the filename ensures Cloud Functions
  # detects the change when you update your code.
  # Without this, GCP might not notice the file was updated.

  bucket = google_storage_bucket.private_artifacts.name
  source = data.archive_file.dss_load_zip.output_path
}

# The actual Cloud Function resource
resource "google_cloudfunctions2_function" "dss_load" {
  depends_on = [
    google_project_service.cloudfunctions_api,
    google_vpc_access_connector.private_connector,
  ]

  project  = var.gcp_project_id
  name     = "insurance-${var.environment}-dss-load"
  location = var.gcp_region

  description = "ETL function: loads insurance data from Cloud Storage CSV files into Cloud SQL"

  build_config {
    # runtime = programming language and version
    runtime     = "python311"
    # python311 = Python 3.11
    # Other options: python310, nodejs20, go122, java21

    # entry_point = the function name in your code that gets called
    entry_point = "load_dss_data"
    # In functions/dss_load/main.py, there must be a function called load_dss_data

    source {
      storage_source {
        bucket = google_storage_bucket.private_artifacts.name
        object = google_storage_bucket_object.dss_load_code.name
        # Where to find the zipped code
      }
    }
  }

  service_config {
    # max_instance_count = maximum parallel function executions
    # If 10 files are uploaded at once, max 5 instances run simultaneously
    max_instance_count = 5

    min_instance_count = 0
    # min = 0 means scale to zero when idle (saves money)

    available_memory   = "512M"
    # Memory allocated to each function instance
    # 512MB is plenty for reading CSV and inserting to DB
    # More memory also means more CPU (they scale together)

    timeout_seconds = 300
    # Maximum run time = 5 minutes
    # If the function runs longer, it's killed automatically
    # Plan your function to finish well within this

    # Environment variables passed to the function
    # Note: these are NOT secrets - just non-sensitive config
    environment_variables = {
      DB_NAME          = var.db_name
      DB_USER          = var.db_user
      GCP_PROJECT_ID   = var.gcp_project_id
      ENVIRONMENT      = var.environment
      # The actual DB password is fetched from Secret Manager at runtime
      # NEVER put passwords in environment variables
    }

    # Secret environment variables - fetched from Secret Manager automatically
    secret_environment_variables {
      key        = "DB_PASSWORD"
      # This env var name will be available in the function as os.environ["DB_PASSWORD"]
      project_id = var.gcp_project_id
      secret     = google_secret_manager_secret.db_password_dss.secret_id
      version    = "latest"
      # "latest" = always use the most recent version of the secret
    }

    # Connect the function to our private VPC
    # This allows the function to reach Cloud SQL's private IP
    vpc_connector = google_vpc_access_connector.private_connector.id

    # ALL_TRAFFIC = route all outbound traffic through VPC (including internet traffic)
    # PRIVATE_RANGES_ONLY = only route private IP traffic through VPC
    vpc_connector_egress_settings = "ALL_TRAFFIC"

    # Run as the functions service account (not default compute SA)
    service_account_email = google_service_account.functions_sa.email
  }

  # What triggers this function
  event_trigger {
    trigger_region = var.gcp_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    # This event type = a message was published to a Pub/Sub topic
    # Our staging bucket publishes a message when a file is uploaded

    pubsub_topic   = google_pubsub_topic.dss_load_trigger.id
    # Which topic to listen to

    retry_policy   = "RETRY_POLICY_RETRY"
    # If the function fails, retry automatically
    # Alternative: RETRY_POLICY_DO_NOT_RETRY
    # For data loading, retrying is safe (the function checks for duplicates)
  }
}

# -----------------------------------
# WORKFLOW ORCHESTRATOR (Component 23)
# -----------------------------------
# PURPOSE: Coordinates the sequence of steps in the data pipeline.
# Instead of functions calling each other directly (tight coupling),
# the Workflow defines the sequence and handles errors centrally.
#
# DATA FLOW WITH WORKFLOW:
# File uploaded → Pub/Sub → Workflow starts →
#   Step 1: Validate file format
#   Step 2: Run DSS Load function
#   Step 3: Verify load succeeded
#   Step 4: Send notification
#   Step 5: Archive processed file
#
# MAPS TO: Component 23 - Workflow orchestrator

resource "google_workflows_workflow" "dss_pipeline" {
  depends_on = [
    google_project_service.workflows_api,
    google_cloudfunctions2_function.dss_load,
  ]

  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-dss-pipeline"
  region      = var.gcp_region
  description = "Orchestrates the DSS data loading pipeline: validate → load → verify → notify"

  service_account = google_service_account.functions_sa.email

  # The workflow definition in YAML format (inline)
  # In a real project this would be in a separate .yaml file
  source_contents = <<-EOF
    # DSS Data Loading Pipeline Workflow
    # This YAML defines the steps the workflow runs in sequence
    
    main:
      params: [args]
      steps:
        - init:
            assign:
              - project: $${sys.get_env("GOOGLE_CLOUD_PROJECT_ID")}
              - bucket: $${args.bucket}
              - file: $${args.name}
        
        - log_start:
            call: sys.log
            args:
              text: $${"DSS Pipeline started for file: " + file}
              severity: INFO
        
        - validate_file:
            call: http.post
            args:
              url: $${"https://${var.gcp_region}-" + project + ".cloudfunctions.net/insurance-${var.environment}-dss-load"}
              auth:
                type: OIDC
              body:
                action: validate
                bucket: $${bucket}
                file: $${file}
            result: validation_result
        
        - check_validation:
            switch:
              - condition: $${validation_result.body.valid == true}
                next: load_data
              - condition: true
                next: handle_invalid_file
        
        - load_data:
            call: http.post
            args:
              url: $${"https://${var.gcp_region}-" + project + ".cloudfunctions.net/insurance-${var.environment}-dss-load"}
              auth:
                type: OIDC
              body:
                action: load
                bucket: $${bucket}
                file: $${file}
            result: load_result
        
        - log_success:
            call: sys.log
            args:
              text: $${"DSS Pipeline completed. Rows loaded: " + string(load_result.body.rows_loaded)}
              severity: INFO
        
        - return_result:
            return: $${load_result.body}
        
        - handle_invalid_file:
            call: sys.log
            args:
              text: $${"Invalid file detected: " + file + ". Skipping load."}
              severity: WARNING
        
        - return_invalid:
            return:
              status: skipped
              reason: invalid_file_format
  EOF
}

# -----------------------------------
# CLOUD FUNCTION: API REQUEST LOGGER
# -----------------------------------
# PURPOSE: Every time the API handles a request, log it to BigQuery
# This is a secondary function triggered by the API via Pub/Sub

resource "google_pubsub_topic" "api_logs_topic" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-api-logs"
}

data "archive_file" "api_logger_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/api_logger"
  output_path = "/tmp/api_logger_function.zip"
}

resource "google_storage_bucket_object" "api_logger_code" {
  name   = "functions/api_logger_${data.archive_file.api_logger_zip.output_md5}.zip"
  bucket = google_storage_bucket.private_artifacts.name
  source = data.archive_file.api_logger_zip.output_path
}

resource "google_cloudfunctions2_function" "api_logger" {
  depends_on = [
    google_project_service.cloudfunctions_api,
    google_cloudfunctions2_function.dss_load,
    # Deploy after the main function to avoid API enabling race conditions
  ]

  project  = var.gcp_project_id
  name     = "insurance-${var.environment}-api-logger"
  location = var.gcp_region
  description = "Logs API requests to BigQuery for analytics"

  build_config {
    runtime     = "python311"
    entry_point = "log_api_request"
    source {
      storage_source {
        bucket = google_storage_bucket.private_artifacts.name
        object = google_storage_bucket_object.api_logger_code.name
      }
    }
  }

  service_config {
    max_instance_count = 10
    min_instance_count = 0
    available_memory   = "256M"
    # 256MB is plenty for just writing a row to BigQuery
    timeout_seconds    = 60

    environment_variables = {
      GCP_PROJECT_ID = var.gcp_project_id
      BQ_DATASET     = "insurance_${var.environment}_analytics"
      BQ_TABLE       = "api_request_logs"
    }

    service_account_email = google_service_account.functions_sa.email
  }

  event_trigger {
    trigger_region = var.gcp_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.api_logs_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}
