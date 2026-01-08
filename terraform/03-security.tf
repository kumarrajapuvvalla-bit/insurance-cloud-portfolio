# ============================================================
# FILE: 03-security.tf
# PURPOSE: Secret Manager, Service Accounts, IAM permissions
# ============================================================
# ANALOGY: If networking is the building, security is:
# - The safe (Secret Manager = stores passwords/keys)
# - Staff ID badges (Service Accounts = identities for your apps)
# - Access control list (IAM = who can do what)
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 18: Secret Manager - DSS Load Credentials
# - Component 19: Secret Manager - CE Data API Credentials
# - Component 26: Secret Manager - Azure AD Credentials
# - Service Accounts for each application
# ============================================================

# -----------------------------------
# SERVICE ACCOUNTS
# -----------------------------------
# WHAT IS A SERVICE ACCOUNT:
# A Service Account is an identity for a NON-HUMAN (an application/service).
# Just like you have a username and password to log into things,
# your Cloud Run service needs an identity to access other GCP services.
#
# WHY NOT USE YOUR OWN ACCOUNT:
# Your personal account has admin access to everything.
# If your app gets hacked and it uses your account, the hacker has everything.
# Service accounts get ONLY the permissions they need (least privilege).
#
# ANALOGY: A bank employee badge that only opens the vault they work in,
# not every vault in the bank.

# Service account for the Cloud Run API service
resource "google_service_account" "api_sa" {
  project = var.gcp_project_id

  # account_id becomes the email: api-sa@PROJECT_ID.iam.gserviceaccount.com
  account_id   = "insurance-api-sa"
  display_name = "Insurance API Service Account"
  description  = "Service account for the CE Data API (Cloud Run). Has read access to Cloud SQL and Secret Manager."
}

# Service account for Cloud Functions (DSS data loading)
resource "google_service_account" "functions_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-functions-sa"
  display_name = "Insurance Cloud Functions Service Account"
  description  = "Service account for DSS Load Cloud Functions. Has write access to Cloud SQL and read access to Cloud Storage."
}

# Service account for Dialogflow CX chatbot
resource "google_service_account" "dialogflow_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-dialogflow-sa"
  display_name = "Insurance Dialogflow CX Service Account"
  description  = "Service account for Dialogflow CX agent. Has access to call the CE API."
}

# Service account for CI/CD pipeline (Azure DevOps deploying to GCP)
resource "google_service_account" "cicd_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-cicd-sa"
  display_name = "Insurance CI/CD Service Account"
  description  = "Service account for Azure DevOps pipeline to deploy to GCP. Limited to deployment actions only."
}

# -----------------------------------
# IAM BINDINGS (Permissions)
# -----------------------------------
# IAM = Identity and Access Management
# This is where you say "WHO can do WHAT on WHICH resource"
#
# Format: google_[resource_type]_iam_[binding_type]
# binding = sets a specific list of members (overwrites existing)
# member  = adds one member without affecting others

# Give API service account permission to READ secrets
# (It needs the DB password from Secret Manager)
resource "google_project_iam_member" "api_secret_accessor" {
  project = var.gcp_project_id
  # Role format: roles/service.roleName
  # secretmanager.secretAccessor = can READ secret values (not create/delete)
  role    = "roles/secretmanager.secretAccessor"
  # member format: serviceAccount:EMAIL
  member  = "serviceAccount:${google_service_account.api_sa.email}"
}

# Give API service account permission to connect to Cloud SQL
resource "google_project_iam_member" "api_cloudsql_client" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  # cloudsql.client = can connect to Cloud SQL instances but not admin them
  member  = "serviceAccount:${google_service_account.api_sa.email}"
}

# Give Functions service account permission to read secrets
resource "google_project_iam_member" "functions_secret_accessor" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

# Give Functions service account permission to connect to Cloud SQL
resource "google_project_iam_member" "functions_cloudsql_client" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

# Give Functions service account permission to READ from Cloud Storage
# (It needs to read the CSV files uploaded for data loading)
resource "google_project_iam_member" "functions_storage_viewer" {
  project = var.gcp_project_id
  role    = "roles/storage.objectViewer"
  # storage.objectViewer = can download/read files but not upload or delete
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

# Give Functions service account permission to WRITE logs to BigQuery
resource "google_project_iam_member" "functions_bigquery_writer" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  # dataEditor = can read, write, delete data but not create/delete datasets
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

# Give CI/CD service account permission to deploy Cloud Run services
resource "google_project_iam_member" "cicd_cloudrun_admin" {
  project = var.gcp_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# Give CI/CD service account permission to push Docker images
resource "google_project_iam_member" "cicd_storage_admin" {
  project = var.gcp_project_id
  role    = "roles/storage.admin"
  # storage.admin = full control of Cloud Storage (needed to push Docker images to GCR)
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# Give CI/CD service account permission to use other service accounts
# (Needed to deploy Cloud Run and associate a service account with it)
resource "google_project_iam_member" "cicd_sa_user" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# -----------------------------------
# SECRET MANAGER SECRETS
# -----------------------------------
# WHAT IS SECRET MANAGER:
# A secure vault for sensitive values (passwords, API keys, certificates).
# Instead of putting "password123" in your code or config files,
# you store it in Secret Manager and your app fetches it at runtime.
#
# HOW IT WORKS:
# 1. You create a "secret" (like an empty locked box with a name)
# 2. You add a "secret version" (the actual value inside the box)
# 3. Your app calls the Secret Manager API to get the value
# 4. All access is logged - you can see who accessed what and when
#
# MAPS TO:
# Component 18: DB credentials for DSS Load function
# Component 19: DB credentials for CE Data API
# Component 26: Azure AD credentials for NextGen authentication

# Secret: Database password for DSS Load function (Component 18)
resource "google_secret_manager_secret" "db_password_dss" {
  depends_on = [google_project_service.secretmanager_api]

  project   = var.gcp_project_id
  secret_id = "insurance-db-password-dss-load"
  # secret_id is the NAME you'll use to look it up

  labels = {
    environment = var.environment
    component   = "dss-load"
    # Labels are key-value tags for organizing and filtering resources
  }

  replication {
    # auto = GCP automatically chooses where to replicate the secret
    # This provides high availability without you managing it
    auto {}
  }
}

# Store the actual DB password value as a "secret version"
# WHY SEPARATE: Secrets and their values are separate.
# This lets you rotate (update) the password without changing the secret's name.
# Your app always points to the LATEST version automatically.
resource "google_secret_manager_secret_version" "db_password_dss_version" {
  secret = google_secret_manager_secret.db_password_dss.id

  # secret_data is the actual value
  # We use var.db_password which comes from your terraform.tfvars (never committed to Git)
  secret_data = var.db_password

  # enabled = true means this version is active and can be accessed
  enabled = true
}

# Secret: Database password for CE Data API (Component 19)
resource "google_secret_manager_secret" "db_password_api" {
  depends_on = [google_project_service.secretmanager_api]

  project   = var.gcp_project_id
  secret_id = "insurance-db-password-ce-api"

  labels = {
    environment = var.environment
    component   = "ce-data-api"
  }

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password_api_version" {
  secret      = google_secret_manager_secret.db_password_api.id
  secret_data = var.db_password
  enabled     = true
}

# Secret: Azure AD Client Secret for NextGen Proxy authentication (Component 26)
# WHY: The NextGen Proxy (Cloud Run Router) authenticates users via Azure AD
# The client secret is the "password" for your Azure AD app registration
resource "google_secret_manager_secret" "azure_ad_secret" {
  depends_on = [google_project_service.secretmanager_api]

  project   = var.gcp_project_id
  secret_id = "insurance-azure-ad-client-secret"

  labels = {
    environment = var.environment
    component   = "nextgen-proxy"
  }

  replication {
    auto {}
  }
}

# NOTE: We don't create the version here because we don't have
# the Azure AD secret value yet (you get it when you set up Azure AD)
# You'll add the version manually or via the Azure pipeline later:
# gcloud secrets versions add insurance-azure-ad-client-secret --data-file=secret.txt

# Secret: SSL Certificate private key (for HTTPS)
resource "google_secret_manager_secret" "ssl_private_key" {
  depends_on = [google_project_service.secretmanager_api]

  project   = var.gcp_project_id
  secret_id = "insurance-ssl-private-key"

  labels = {
    environment = var.environment
    component   = "load-balancer"
  }

  replication {
    auto {}
  }
}

# -----------------------------------
# SECRET ACCESS PERMISSIONS
# -----------------------------------
# These grant specific service accounts access to specific secrets
# More granular than the project-level IAM above
# PRINCIPLE: Each service can only read the secrets IT needs

resource "google_secret_manager_secret_iam_member" "api_reads_api_password" {
  project   = var.gcp_project_id
  secret_id = google_secret_manager_secret.db_password_api.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "functions_reads_dss_password" {
  project   = var.gcp_project_id
  secret_id = google_secret_manager_secret.db_password_dss.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.functions_sa.email}"
}

# -----------------------------------
# NOTIFICATION CHANNELS
# -----------------------------------
# MAPS TO: Components 11 and 12 - Notification Channels (pub and priv)
# These send alerts when something goes wrong (like PagerDuty in the original)
# For portfolio we use email notifications instead of PagerDuty

resource "google_monitoring_notification_channel" "email_alerts" {
  project      = var.gcp_project_id
  display_name = "Insurance Platform Email Alerts"
  type         = "email"
  # type options: email, sms, pagerduty, slack, webhook

  labels = {
    # The email address to send alerts to
    email_address = var.alert_email
  }

  enabled = true
}

# Alert policy: Notify if API error rate is too high
resource "google_monitoring_alert_policy" "api_error_rate" {
  project      = var.gcp_project_id
  display_name = "Insurance API High Error Rate"
  combiner     = "OR"
  # combiner = how multiple conditions combine
  # OR = alert if ANY condition is met
  # AND = alert only if ALL conditions are met

  conditions {
    display_name = "Error rate above 5%"

    condition_threshold {
      # What metric to monitor
      filter = "resource.type = \"cloud_run_revision\" AND metric.type = \"run.googleapis.com/request_count\""

      # How to aggregate the data
      aggregations {
        alignment_period   = "60s" # Look at 60-second windows
        per_series_aligner = "ALIGN_RATE" # Calculate rate of change
      }

      # Trigger alert if value is above this threshold
      comparison = "COMPARISON_GT" # Greater than
      threshold_value = 0.05       # 5% error rate

      duration = "300s" # Must be above threshold for 5 minutes before alerting
    }
  }

  # Send to our email notification channel defined above
  notification_channels = [google_monitoring_notification_channel.email_alerts.name]

  documentation {
    content   = "The Insurance API error rate has exceeded 5%. Check Cloud Run logs for details."
    mime_type = "text/markdown"
  }
}
