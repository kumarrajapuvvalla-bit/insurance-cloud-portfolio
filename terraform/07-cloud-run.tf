# ============================================================
# FILE: 07-cloud-run.tf
# PURPOSE: Deploy containerised API and routing services
# ============================================================
# ANALOGY: Cloud Run is like a waiter in a restaurant.
# When no customers are there, the waiter goes home (scale to zero).
# When customers arrive, the waiter comes in immediately.
# More customers = more waiters automatically.
# You only pay when waiters are actively serving.
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 25: Cloud Run (CE Data API) - main insurance API
# - Component 37: Cloud Run (NextGen Proxy Router)
# - Component 35: Cloud Run (Router Availability check)
# ============================================================

# -----------------------------------
# CE DATA API (Component 25)
# -----------------------------------
# PURPOSE: The main REST API that the chatbot and external systems call.
# Handles: policy lookups, claims filing, claims status checks.
#
# MAPS TO: Component 25 - "Cloud Run/Cloud Functions Gen2 (CE Data API)"

resource "google_cloud_run_v2_service" "ce_data_api" {
  depends_on = [
    google_project_service.run_api,
    google_sql_database_instance.main_db,
    google_secret_manager_secret_version.db_password_api_version,
  ]

  project  = var.gcp_project_id
  name     = "insurance-${var.environment}-ce-data-api"
  location = var.gcp_region

  description = "CE Data API - handles policy and claims operations"

  # ingress controls which traffic can reach this service
  # INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER = only traffic from the load balancer
  # This prevents direct access - all traffic MUST go through the load balancer
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    # Use our dedicated service account (not default)
    service_account = google_service_account.api_sa.email

    # Labels for filtering and cost tracking
    labels = {
      environment = var.environment
      component   = "ce-data-api"
    }

    # Scaling configuration
    scaling {
      min_instance_count = var.api_min_instances
      # 0 = scale to zero (saves money when idle)

      max_instance_count = var.api_max_instances
      # 3 = maximum 3 containers running simultaneously
    }

    # Connect to the VPC so the API can reach Cloud SQL's private IP
    vpc_access {
      connector = google_vpc_access_connector.public_connector.id
      egress    = "ALL_TRAFFIC"
      # ALL_TRAFFIC = all outbound traffic goes through VPC
      # This ensures even internet-bound traffic from the API goes through our VPC NAT
    }

    containers {
      # The Docker image to run
      # Replace with your actual image after building and pushing
      image = var.api_image
      # Format: gcr.io/YOUR_PROJECT_ID/insurance-api:latest

      # Resource limits per container instance
      resources {
        limits = {
          cpu    = "1"    # 1 vCPU per instance
          memory = "512Mi" # 512 megabytes RAM per instance
        }
        # cpu_idle = true means CPU is only allocated when requests are being handled
        # Saves cost between requests
        cpu_idle = true

        startup_cpu_boost = true
        # Gives extra CPU during container startup (cold start)
        # Makes cold starts faster - reduces the 2 second delay
      }

      # Environment variables available to the application
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
        # Cloud SQL connection string format: project:region:instance
        value = "${var.gcp_project_id}:${var.gcp_region}:${google_sql_database_instance.main_db.name}"
      }
      env {
        name  = "LOGS_TOPIC"
        value = google_pubsub_topic.api_logs_topic.name
      }

      # Secret environment variables (fetched from Secret Manager automatically)
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password_api.secret_id
            version = "latest"
          }
        }
      }

      # Health check - Cloud Run pings this endpoint to verify the app is healthy
      # If health check fails, Cloud Run stops routing traffic to that instance
      liveness_probe {
        http_get {
          path = "/health"
          # Your API must have a GET /health endpoint that returns 200 OK
        }
        initial_delay_seconds = 10  # Wait 10s after start before first check
        period_seconds        = 30  # Check every 30 seconds
        failure_threshold     = 3   # Mark unhealthy after 3 consecutive failures
      }

      startup_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 10  # Allow up to 50 seconds for startup (5s * 10)
      }

      # The port your application listens on inside the container
      ports {
        container_port = 8080
        # FastAPI will be configured to listen on port 8080
        # Cloud Run expects your app on this port
      }
    }
  }

  # traffic routing
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
    # 100% of traffic goes to the latest deployment
    # You can do canary deployments by splitting traffic:
    # e.g., 90% to latest, 10% to previous version
  }
}

# -----------------------------------
# CLOUD RUN IAM - Allow load balancer to invoke
# -----------------------------------
# By default Cloud Run services require authentication.
# We need to allow the load balancer (which handles auth externally)
# to call the API.

resource "google_cloud_run_v2_service_iam_member" "api_load_balancer_invoker" {
  project  = var.gcp_project_id
  location = var.gcp_region
  name     = google_cloud_run_v2_service.ce_data_api.name
  role     = "roles/run.invoker"
  # run.invoker = permission to call/invoke this Cloud Run service

  member = "allUsers"
  # allUsers = anyone (no auth required)
  # WHY: The load balancer handles authentication upstream.
  # The API trusts that anyone reaching it has already been authenticated.
  # In production you'd use a more specific member like a service account.
}

# -----------------------------------
# NEXTGEN PROXY ROUTER (Component 37)
# -----------------------------------
# PURPOSE: Routes requests to the correct backend service.
# Acts as an intelligent router that can:
# - Route /policies/* to the policies service
# - Route /claims/* to the claims service
# - Handle authentication (Azure AD integration)
# - Rate limiting
#
# MAPS TO: Component 37 - "Cloud Run/Cloud Functions Gen2 (NextGen Proxy)"

resource "google_cloud_run_v2_service" "nextgen_proxy" {
  depends_on = [
    google_cloud_run_v2_service.ce_data_api,
  ]

  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-nextgen-proxy"
  location    = var.gcp_region
  description = "NextGen Proxy Router - handles routing and Azure AD authentication"

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

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
      # You'll build this image as part of Phase 6 (CI/CD)

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
        # The URL of the CE Data API - proxy forwards requests there
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      # Azure AD client secret for authentication
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

# Allow load balancer to invoke the proxy
resource "google_cloud_run_v2_service_iam_member" "proxy_load_balancer_invoker" {
  project  = var.gcp_project_id
  location = var.gcp_region
  name     = google_cloud_run_v2_service.nextgen_proxy.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# -----------------------------------
# ROUTER AVAILABILITY SERVICE (Component 35)
# -----------------------------------
# PURPOSE: A lightweight health check service.
# The load balancer checks this to know if the system is available
# before routing traffic to the main proxy.
#
# MAPS TO: Component 35 - "Cloud Run (Router Availability)"

resource "google_cloud_run_v2_service" "router_availability" {
  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-router-availability"
  location    = var.gcp_region
  description = "Router availability check service for load balancer health checks"

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    scaling {
      min_instance_count = 1
      # min = 1 (NOT zero) - always available for health checks
      # Load balancer needs this available at all times
      max_instance_count = 2
    }

    containers {
      # Using a simple nginx image - just returns 200 OK
      # In production this would check downstream services too
      image = "nginx:alpine"

      resources {
        limits = {
          cpu    = "0.5"
          memory = "128Mi"
          # Very lightweight - just returns 200 OK
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
