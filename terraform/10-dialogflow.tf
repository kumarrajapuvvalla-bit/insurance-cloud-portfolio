# -----------------------------------
# DIALOGFLOW CX AGENT
# -----------------------------------
# Handles customer queries for policy lookups, claims filing, and status checks.
# Deployed globally for lowest latency across regions.

resource "google_dialogflow_cx_agent" "insurance_bot" {
  depends_on = [google_project_service.dialogflow_api]

  project               = var.gcp_project_id
  display_name          = "Insurance CE Agent - ${var.environment}"
  location              = "global"
  default_language_code = "en"
  time_zone             = "America/New_York"
  description           = "Insurance Customer Experience Agent — policy lookups, claims filing and status checks"

  speech_to_text_settings {
    # Speech adaptation improves recognition accuracy for insurance terminology
    enable_speech_adaptation = true
  }

  advanced_settings {
    logging_settings {
      enable_stackdriver_logging = true
      enable_interaction_logging = true
    }
  }
}

# -----------------------------------
# WEBHOOK
# -----------------------------------
# Dialogflow calls this endpoint when it needs real data from Cloud SQL.
# Flow: user intent → webhook POST → CE API lookup → response back to agent

resource "google_dialogflow_cx_webhook" "api_webhook" {
  parent       = google_dialogflow_cx_agent.insurance_bot.id
  display_name = "Insurance API Webhook"

  generic_web_service {
    uri = "${google_cloud_run_v2_service.nextgen_proxy.uri}/webhook/dialogflow"

    request_headers = {
      "X-Webhook-Source" = "dialogflow-cx"
      "X-Environment"    = var.environment
    }
  }

  # Dialogflow falls back to a static response if webhook exceeds 5s
  timeout = "5s"
}

# -----------------------------------
# DIALOGFLOW ENVIRONMENT
# -----------------------------------

resource "google_dialogflow_cx_environment" "main_env" {
  parent       = google_dialogflow_cx_agent.insurance_bot.id
  display_name = var.environment
  description  = "Insurance CE Agent ${var.environment} environment"
}

# -----------------------------------
# SERVICE DIRECTORY
# -----------------------------------
# Services register their endpoints here rather than hardcoding URLs.
# Allows the proxy and Dialogflow webhook to discover the API dynamically.

resource "google_service_directory_namespace" "main" {
  depends_on   = [google_project_service.servicedirectory_api]
  project      = var.gcp_project_id
  namespace_id = "insurance-${var.environment}"
  location     = var.gcp_region

  labels = {
    environment = var.environment
  }
}

resource "google_service_directory_service" "ce_api_service" {
  name      = "ce-data-api"
  namespace = google_service_directory_namespace.main.id

  annotations = {
    description = "CE Data API - insurance policy and claims REST API"
    version     = "v1"
    environment = var.environment
  }
}

resource "google_service_directory_endpoint" "ce_api_endpoint" {
  endpoint_id = "primary"
  service     = google_service_directory_service.ce_api_service.id
  address     = google_compute_global_address.lb_ip.address
  port        = 443

  annotations = {
    cloud_run_url = google_cloud_run_v2_service.nextgen_proxy.uri
  }
}
