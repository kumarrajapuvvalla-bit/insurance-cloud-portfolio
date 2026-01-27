# ============================================================
# FILE: 10-dialogflow.tf
# PURPOSE: Dialogflow CX chatbot agent
# ============================================================
# ANALOGY: Dialogflow CX is like a smart phone tree system.
# But instead of "press 1 for claims, press 2 for policies",
# customers just speak or type naturally:
# "I want to check my claim" → system understands and responds.
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 24: Dialogflow CX Agents (VA & Messenger)
# ============================================================

# -----------------------------------
# DIALOGFLOW CX AGENT (Component 24)
# -----------------------------------
# An "agent" in Dialogflow CX is the chatbot itself.
# It contains:
# - Intents (what the user wants: "check claim status")
# - Entities (key info: claim ID, policy number)
# - Flows (conversation paths: greeting → ask for ID → look up → respond)
# - Pages (individual conversation steps)
# - Webhooks (calls to your API to get real data)

resource "google_dialogflow_cx_agent" "insurance_bot" {
  depends_on = [google_project_service.dialogflow_api]

  project      = var.gcp_project_id
  display_name = "Insurance CE Agent - ${var.environment}"
  # The name shown in the Dialogflow CX console

  location = "global"
  # Dialogflow CX agents are typically "global" (not region-specific)
  # This gives best latency for users worldwide

  default_language_code = "en"
  # Primary language of the chatbot
  # You can add more languages later: es (Spanish), fr (French) etc.

  time_zone = "America/New_York"
  # Timezone for time-based responses ("your appointment is tomorrow at 3pm")

  description = "Insurance Customer Experience Agent. Handles policy lookups, claims filing and status checks."

  # avatar_uri = URL to the chatbot's profile picture
  # Can be set in the console - not managed by Terraform

  # speech_to_text_settings for voice interactions (phone channel)
  speech_to_text_settings {
    enable_speech_adaptation = true
    # Speech adaptation improves accuracy for domain-specific terms
    # The model learns insurance words: "deductible", "premium", "policyholder"
  }

  # advanced_settings for the agent
  advanced_settings {
    # audio_export_gcs_destination for recording conversations (compliance)
    # Uncomment and configure for production use:
    # audio_export_gcs_destination {
    #   uri = "gs://${google_storage_bucket.private_artifacts.name}/dialogflow-audio/"
    # }

    # logging_settings controls what gets logged
    logging_settings {
      enable_stackdriver_logging   = true
      # Log conversations to Cloud Logging (visible in GCP Console)

      enable_interaction_logging   = true
      # Log each turn of conversation (useful for debugging and improvement)
    }
  }
}

# -----------------------------------
# DIALOGFLOW WEBHOOK
# -----------------------------------
# Webhooks connect Dialogflow to your API.
# When the chatbot needs real data (policy details, claim status),
# it calls the webhook, which calls your CE Data API.
#
# Flow:
# User: "What's my claim status for claim #12345?"
# Dialogflow: extracts claim_id=12345 → calls webhook
# Webhook: calls GET /api/v1/claims/12345
# API: returns claim status from Cloud SQL
# Webhook: returns data to Dialogflow
# Dialogflow: "Your claim #12345 is currently Under Review"

resource "google_dialogflow_cx_webhook" "api_webhook" {
  parent       = google_dialogflow_cx_agent.insurance_bot.id
  display_name = "Insurance API Webhook"

  generic_web_service {
    uri = "${google_cloud_run_v2_service.nextgen_proxy.uri}/webhook/dialogflow"
    # The URL Dialogflow will POST to when it needs data
    # Your CE API must have a POST /webhook/dialogflow endpoint

    # request_headers passed with every webhook call
    request_headers = {
      "X-Webhook-Source" = "dialogflow-cx"
      "X-Environment"    = var.environment
      # Custom headers help your API identify the request source
    }
  }

  timeout = "5s"
  # Dialogflow will wait 5 seconds for a webhook response
  # If no response in 5 seconds, it uses a fallback message
  # Keep your API fast - webhook timeouts cause poor user experience
}

# -----------------------------------
# DIALOGFLOW ENVIRONMENT
# -----------------------------------
# Dialogflow CX has environments (like dev/staging/prod for the chatbot).
# This lets you test changes without affecting the live chatbot.

resource "google_dialogflow_cx_environment" "main_env" {
  parent       = google_dialogflow_cx_agent.insurance_bot.id
  display_name = var.environment
  description  = "Insurance CE Agent ${var.environment} environment"

  # version_configs links specific versions of flows to this environment
  # We'll leave this empty initially - configured after flows are created
  # version_configs {
  #   version = google_dialogflow_cx_version.main_flow_v1.id
  # }
}

# -----------------------------------
# SERVICE DIRECTORY (Component 40)
# -----------------------------------
# Service Directory is a managed service registry.
# Like a phone book for your microservices.
# Services register their endpoints here, and other services look them up.
# This prevents hardcoding URLs - services find each other dynamically.
#
# MAPS TO: Component 40 - "Service Directory (CCS Service Directory)"

resource "google_service_directory_namespace" "main" {
  depends_on = [google_project_service.servicedirectory_api]

  project      = var.gcp_project_id
  namespace_id = "insurance-${var.environment}"
  location     = var.gcp_region

  labels = {
    environment = var.environment
  }
}

resource "google_service_directory_service" "ce_api_service" {
  name       = "ce-data-api"
  namespace  = google_service_directory_namespace.main.id

  annotations = {
    description = "CE Data API - insurance policy and claims REST API"
    version     = "v1"
    environment = var.environment
  }
}

resource "google_service_directory_endpoint" "ce_api_endpoint" {
  endpoint_id = "primary"
  service     = google_service_directory_service.ce_api_service.id

  address = google_compute_global_address.lb_ip.address
  # The IP address of the load balancer
  port    = 443

  annotations = {
    cloud_run_url = google_cloud_run_v2_service.nextgen_proxy.uri
  }
}
