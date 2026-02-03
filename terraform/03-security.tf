# -----------------------------------
# SERVICE ACCOUNTS
# -----------------------------------
# Each service runs under its own identity with only the permissions it needs.
# This limits the blast radius if any single service is compromised.

resource "google_service_account" "api_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-api-sa"
  display_name = "Insurance API Service Account"
  description  = "Identity for the CE Data API (Cloud Run). Read access to Cloud SQL and Secret Manager."
}

resource "google_service_account" "functions_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-functions-sa"
  display_name = "Insurance Cloud Functions Service Account"
  description  = "Identity for DSS Load functions. Write access to Cloud SQL, read access to Cloud Storage."
}

resource "google_service_account" "dialogflow_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-dialogflow-sa"
  display_name = "Insurance Dialogflow CX Service Account"
  description  = "Identity for Dialogflow CX agent webhook calls."
}

resource "google_service_account" "cicd_sa" {
  project      = var.gcp_project_id
  account_id   = "insurance-cicd-sa"
  display_name = "Insurance CI/CD Service Account"
  description  = "Identity for Azure DevOps pipeline deployments to GCP."
}

# -----------------------------------
# IAM BINDINGS
# -----------------------------------

resource "google_project_iam_member" "api_secret_accessor" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.api_sa.email}"
}

resource "google_project_iam_member" "api_cloudsql_client" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api_sa.email}"
}

resource "google_project_iam_member" "functions_secret_accessor" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "functions_cloudsql_client" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "functions_storage_viewer" {
  project = var.gcp_project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "functions_bigquery_writer" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "cicd_cloudrun_admin" {
  project = var.gcp_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_project_iam_member" "cicd_storage_admin" {
  project = var.gcp_project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# Required for the CI/CD SA to associate service accounts when deploying Cloud Run
resource "google_project_iam_member" "cicd_sa_user" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# -----------------------------------
# SECRET MANAGER
# -----------------------------------

resource "google_secret_manager_secret" "db_password_dss" {
  depends_on = [google_project_service.secretmanager_api]

  project   = var.gcp_project_id
  secret_id = "insurance-db-password-dss-load"

  labels = {
    environment = var.environment
    component   = "dss-load"
  }

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password_dss_version" {
  secret      = google_secret_manager_secret.db_password_dss.id
  secret_data = var.db_password
  enabled     = true
}

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

# Azure AD client secret for NextGen Proxy authentication
# Version is added manually after the Azure AD app registration is created:
# gcloud secrets versions add insurance-azure-ad-client-secret --data-file=secret.txt
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
# SECRET-LEVEL IAM
# -----------------------------------
# Scoped per-secret so each service can only read what it needs

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
# MONITORING & ALERTS
# -----------------------------------

resource "google_monitoring_notification_channel" "email_alerts" {
  project      = var.gcp_project_id
  display_name = "Insurance Platform Email Alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }

  enabled = true
}

resource "google_monitoring_alert_policy" "api_error_rate" {
  project      = var.gcp_project_id
  display_name = "Insurance API High Error Rate"
  combiner     = "OR"

  conditions {
    display_name = "Error rate above 5%"

    condition_threshold {
      filter = "resource.type = \"cloud_run_revision\" AND metric.type = \"run.googleapis.com/request_count\""

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }

      comparison      = "COMPARISON_GT"
      threshold_value = 0.05
      duration        = "300s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alerts.name]

  documentation {
    content   = "The Insurance API error rate has exceeded 5%. Check Cloud Run logs for details."
    mime_type = "text/markdown"
  }
}
