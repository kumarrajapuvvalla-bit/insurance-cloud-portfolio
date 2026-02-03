# -----------------------------------
# SSL CERTIFICATE
# -----------------------------------
# Google-managed certificate — free and auto-renewed.
# create_before_destroy prevents downtime during certificate rotation.

resource "google_compute_managed_ssl_certificate" "api_cert" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-api-cert"

  managed {
    domains = ["api.${var.gcp_project_id}.example.com"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------
# BACKEND SERVICES
# -----------------------------------

resource "google_compute_backend_service" "api_backend" {
  project               = var.gcp_project_id
  name                  = "insurance-${var.environment}-api-backend"
  protocol              = "HTTPS"
  timeout_sec           = 30
  session_affinity      = "NONE"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group           = google_compute_region_network_endpoint_group.api_neg.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  enable_cdn = false

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# Serverless NEG is required to use Cloud Run as a load balancer backend
resource "google_compute_region_network_endpoint_group" "api_neg" {
  project               = var.gcp_project_id
  name                  = "insurance-${var.environment}-api-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.gcp_region

  cloud_run {
    service = google_cloud_run_v2_service.nextgen_proxy.name
  }
}

resource "google_compute_health_check" "api_health" {
  project             = var.gcp_project_id
  name                = "insurance-${var.environment}-api-health"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  https_health_check {
    port         = "443"
    request_path = "/health"
  }
}

# -----------------------------------
# URL MAP
# -----------------------------------

resource "google_compute_url_map" "api_url_map" {
  project         = var.gcp_project_id
  name            = "insurance-${var.environment}-url-map"
  default_service = google_compute_backend_service.api_backend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "api-paths"
  }

  path_matcher {
    name            = "api-paths"
    default_service = google_compute_backend_service.api_backend.id

    path_rule {
      paths   = ["/api/*", "/v1/*"]
      service = google_compute_backend_service.api_backend.id
    }

    path_rule {
      paths   = ["/ping", "/ready"]
      service = google_compute_backend_service.api_backend.id
    }
  }
}

resource "google_compute_url_map" "http_redirect" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-http-redirect"

  default_url_redirect {
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    https_redirect         = true
    strip_query            = false
  }
}

# -----------------------------------
# PROXIES
# -----------------------------------

resource "google_compute_target_https_proxy" "api_https_proxy" {
  project          = var.gcp_project_id
  name             = "insurance-${var.environment}-https-proxy"
  url_map          = google_compute_url_map.api_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.api_cert.id]
}

resource "google_compute_target_http_proxy" "http_redirect_proxy" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

# -----------------------------------
# GLOBAL IP + FORWARDING RULES
# -----------------------------------

resource "google_compute_global_address" "lb_ip" {
  project      = var.gcp_project_id
  name         = "insurance-${var.environment}-lb-ip"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  project               = var.gcp_project_id
  name                  = "insurance-${var.environment}-https-fwd-rule"
  ip_address            = google_compute_global_address.lb_ip.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.api_https_proxy.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  project               = var.gcp_project_id
  name                  = "insurance-${var.environment}-http-fwd-rule"
  ip_address            = google_compute_global_address.lb_ip.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_redirect_proxy.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
