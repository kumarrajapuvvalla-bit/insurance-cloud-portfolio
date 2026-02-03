# -----------------------------------
# CE DATA API
# -----------------------------------
# Main REST API for policy and claims operations.
# Restricted to load balancer ingress — not directly callable from the internet.

resource "google_cloud_run_v2_service" "ce_data_api" {
  depends_on = [
    google_project_service.run_api,
    google_sql_database_instance.main_db,
    google_secret_manager_secret_version.db_password_api_version,
  ]

  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-ce-data-api"
  location    = var.gcp_region
  description = "CE Data API - handles policy and claims operations"
  ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.api_sa.email

    labels = {
      environment = var.environment
      component   = "ce-data-api"
    }

    scaling {
      min_instance_count = var.api_min_instances
      max_instance_count = var.api_max_instances
    }

    vpc_access {
      connector = google_vpc_access_connector.public_connector.id
      # ALL_TRAFFIC ensures database traffic goes through the VPC connector,
      # not around it via the public internet
      egress = "ALL_TRAFFIC"
    }

    containers {
      image = var.api_image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name  = "DB_NAME"
        value = var.db_name
      }
      env {
        name  = "DB_USER"
        value = var.db_user
      }
      env {
        name  = "GCP_PROJECT_ID"
        value = var.gcp_project_id
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = "${var.gcp_project_id}:${var.gcp_region}:${google_sql_database_instance.main_db.name}"
      }
      env {
        name  = "LOGS_TOPIC"
        value = google_pubsub_topic.api_logs_topic.name
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password_api.secret_id
            version = "latest"
          }
        }
      }

      liveness_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 10
        period_seconds        = 30
        failure_threshold     = 3
      }

      startup_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 10
      }

      ports {
        container_port = 8080
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# Authentication is handled upstream by the load balancer and proxy
resource "google_cloud_run_v2_service_iam_member" "api_load_balancer_invoker" {
  project  = var.gcp_project_id
  location = var.gcp_region
  name     = google_cloud_run_v2_service.ce_data_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# -----------------------------------
# NEXTGEN PROXY ROUTER
# -----------------------------------
# Sits between the load balancer and CE Data API.
# Handles routing, Azure AD authentication, and request logging.

resource "google_cloud_run_v2_service" "nextgen_proxy" {
  depends_on = [google_cloud_run_v2_service.ce_data_api]

  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-nextgen-proxy"
  location    = var.gcp_region
  description = "NextGen Proxy Router - handles routing and Azure AD authentication"
  ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.api_sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    vpc_access {
      connector = google_vpc_access_connector.public_connector.id
      egress    = "ALL_TRAFFIC"
    }

    containers {
      image = "gcr.io/${var.gcp_project_id}/insurance-nextgen-proxy:latest"

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle = true
      }

      env {
        name  = "DOWNSTREAM_API_URL"
        value = google_cloud_run_v2_service.ce_data_api.uri
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      env {
        name = "AZURE_CLIENT_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.azure_ad_secret.secret_id
            version = "latest"
          }
        }
      }

      ports {
        container_port = 8080
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

resource "google_cloud_run_v2_service_iam_member" "proxy_load_balancer_invoker" {
  project  = var.gcp_project_id
  location = var.gcp_region
  name     = google_cloud_run_v2_service.nextgen_proxy.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# -----------------------------------
# ROUTER AVAILABILITY SERVICE
# -----------------------------------
# Lightweight always-on service for load balancer health checks.
# min_instance_count = 1 so it's never cold when the LB probes it.

resource "google_cloud_run_v2_service" "router_availability" {
  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-router-availability"
  location    = var.gcp_region
  description = "Router availability check service for load balancer health checks"
  ingress     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = 2
    }

    containers {
      image = "nginx:alpine"

      resources {
        limits = {
          cpu    = "0.5"
          memory = "128Mi"
        }
      }

      ports {
        container_port = 80
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

resource "google_cloud_run_v2_service_iam_member" "availability_invoker" {
  project  = var.gcp_project_id
  location = var.gcp_region
  name     = google_cloud_run_v2_service.router_availability.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
