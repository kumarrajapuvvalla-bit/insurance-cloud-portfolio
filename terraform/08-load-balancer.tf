# ============================================================
# FILE: 08-load-balancer.tf
# PURPOSE: HTTPS load balancer with SSL certificate
# ============================================================
# ANALOGY: The load balancer is like a hotel receptionist.
# Every guest (request) comes to the front desk first.
# The receptionist (load balancer):
# - Checks ID (verifies HTTPS/SSL)
# - Decides which room/floor to send them to (routing rules)
# - If one elevator is broken (service down), uses another
# - Handles the security check so hotel rooms don't have to
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 38: Cloud Load Balancing (CCS Load Balancer)
# - Component 39: SSL Certificate (CCS Load Balancer Cert)
# ============================================================

# -----------------------------------
# SSL CERTIFICATE (Component 39)
# -----------------------------------
# WHAT IS SSL/TLS:
# SSL (Secure Sockets Layer) / TLS (Transport Layer Security) encrypts
# all data between the browser and your server.
# Without it: passwords, data, everything travels as plain text.
# With it: data is encrypted - even if intercepted, it's unreadable.
#
# HTTPS = HTTP + SSL/TLS
#
# Google-managed certificates are FREE and auto-renew.
# You just specify your domain name and Google handles the rest.
#
# MAPS TO: Component 39 - "SSL Cert (CCS Load Balancer Cert)"

resource "google_compute_managed_ssl_certificate" "api_cert" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-api-cert"

  managed {
    # The domain names this certificate covers
    # Replace with your actual domain when you have one
    # For portfolio, you can use the default Cloud Run URL (no custom domain needed)
    domains = ["api.${var.gcp_project_id}.example.com"]
    # Format: ["yourdomain.com", "www.yourdomain.com"]
    # Note: Certificate provisioning takes 10-60 minutes after DNS is configured
  }

  lifecycle {
    create_before_destroy = true
    # Create new cert before destroying old one during updates
    # Prevents downtime during certificate rotation
  }
}

# -----------------------------------
# BACKEND SERVICES
# -----------------------------------
# Backend services connect the load balancer to your Cloud Run services.
# They also handle health checks and session affinity.

# Backend: NextGen Proxy (main entry point)
resource "google_compute_backend_service" "api_backend" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-api-backend"

  protocol    = "HTTPS"
  # Protocol between load balancer and backend
  # HTTPS = encrypted even on internal network (defense in depth)

  timeout_sec = 30
  # If backend doesn't respond in 30 seconds, return error to client

  # health_checks monitors if backend instances are responding
  # health_checks = [google_compute_health_check.api_health.id]
  # (Defined below)

  # Session affinity: should the same user always go to same instance?
  # NONE = don't care (stateless API, any instance can handle any request)
  session_affinity = "NONE"

  # Load balancing scheme
  load_balancing_scheme = "EXTERNAL_MANAGED"
  # EXTERNAL_MANAGED = modern, global HTTP(S) load balancer

  # Cloud Run backend - connects load balancer to Cloud Run service
  backend {
    group           = google_compute_region_network_endpoint_group.api_neg.id
    # NEG = Network Endpoint Group - represents the Cloud Run service
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  # Cloud CDN - cache responses at edge locations for faster delivery
  enable_cdn = false
  # Disabled for API (APIs usually return dynamic data that shouldn't be cached)
  # Enable for static content like images or documents

  # Logging for the backend
  log_config {
    enable      = true
    sample_rate = 1.0
    # sample_rate = 1.0 = log 100% of requests
    # In production you might reduce this to 0.1 (10%) to save costs
  }
}

# Network Endpoint Group - represents Cloud Run as a load balancer backend
# NEG is required to use Cloud Run with a load balancer
resource "google_compute_region_network_endpoint_group" "api_neg" {
  project               = var.gcp_project_id
  name                  = "insurance-${var.environment}-api-neg"
  network_endpoint_type = "SERVERLESS"
  # SERVERLESS = this NEG points to a serverless service (Cloud Run)

  region = var.gcp_region

  cloud_run {
    service = google_cloud_run_v2_service.nextgen_proxy.name
    # Which Cloud Run service this NEG represents
  }
}

# Health check - load balancer uses this to verify backend is healthy
resource "google_compute_health_check" "api_health" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-api-health"

  check_interval_sec  = 10  # Check every 10 seconds
  timeout_sec         = 5   # Declare unhealthy if no response in 5 seconds
  healthy_threshold   = 2   # Need 2 consecutive successes to mark healthy
  unhealthy_threshold = 3   # Need 3 consecutive failures to mark unhealthy

  https_health_check {
    port         = "443"
    request_path = "/health"
    # Load balancer sends HTTPS GET /health to each backend instance
  }
}

# -----------------------------------
# URL MAP (Routing Rules)
# -----------------------------------
# URL maps define how requests are routed based on path or hostname.
# Like a switchboard that says "requests to /api/* go to backend X"

resource "google_compute_url_map" "api_url_map" {
  project         = var.gcp_project_id
  name            = "insurance-${var.environment}-url-map"
  default_service = google_compute_backend_service.api_backend.id
  # default_service = where to send requests that don't match any rules

  # Host rules - route based on domain name
  host_rule {
    hosts        = ["*"] # Match any hostname
    path_matcher = "api-paths"
  }

  # Path matchers - route based on URL path
  path_matcher {
    name            = "api-paths"
    default_service = google_compute_backend_service.api_backend.id

    # Route specific paths to specific backends
    path_rule {
      paths   = ["/api/*", "/v1/*"]
      service = google_compute_backend_service.api_backend.id
    }

    # Health check path goes to router availability service
    path_rule {
      paths   = ["/ping", "/ready"]
      service = google_compute_backend_service.api_backend.id
    }
  }
}

# HTTP redirect - redirect all HTTP to HTTPS
resource "google_compute_url_map" "http_redirect" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-http-redirect"

  default_url_redirect {
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    # 301 = Moved Permanently - browser and search engines remember this
    https_redirect         = true
    # Redirect to the HTTPS version
    strip_query            = false
    # Keep query parameters (e.g., ?page=2 stays in the redirect)
  }
}

# -----------------------------------
# HTTPS PROXY (Component 38)
# -----------------------------------
# WHAT IS A TARGET PROXY:
# The target proxy is the actual HTTPS listener.
# It holds the SSL certificate and terminates TLS connections.
# "Terminates" means: decrypts HTTPS → sends plain HTTP to backend
# (but we re-encrypt to backend so it stays secure)
#
# MAPS TO: Component 38 - "Cloud Load Balancing (CCS Load Balancer)"

resource "google_compute_target_https_proxy" "api_https_proxy" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-https-proxy"

  url_map = google_compute_url_map.api_url_map.id
  # Which URL map to use for routing decisions

  ssl_certificates = [google_compute_managed_ssl_certificate.api_cert.id]
  # Which SSL certificate to present to clients

  # SSL policy - defines which TLS versions and ciphers are allowed
  # Google's managed policy blocks old insecure TLS versions (TLS 1.0, 1.1)
  # ssl_policy = google_compute_ssl_policy.modern_tls.id
}

# HTTP proxy (for the redirect)
resource "google_compute_target_http_proxy" "http_redirect_proxy" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

# -----------------------------------
# GLOBAL IP ADDRESS
# -----------------------------------
# A static IP address for the load balancer.
# "Global" means it works with Google's global load balancer.
# Users are routed to the nearest Google edge location automatically.

resource "google_compute_global_address" "lb_ip" {
  project      = var.gcp_project_id
  name         = "insurance-${var.environment}-lb-ip"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
  # EXTERNAL = a public IP address accessible from the internet
  # This is the IP your DNS record will point to
}

# -----------------------------------
# FORWARDING RULES
# -----------------------------------
# Forwarding rules are the "front door" of the load balancer.
# They listen on a specific IP:port and forward to a proxy.

# HTTPS forwarding rule (port 443)
resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  project    = var.gcp_project_id
  name       = "insurance-${var.environment}-https-fwd-rule"
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "443"
  # Listen on port 443 (HTTPS)

  target = google_compute_target_https_proxy.api_https_proxy.id
  # Forward to the HTTPS proxy

  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# HTTP forwarding rule (port 80) - just to redirect to HTTPS
resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  project    = var.gcp_project_id
  name       = "insurance-${var.environment}-http-fwd-rule"
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "80"

  target = google_compute_target_http_proxy.http_redirect_proxy.id

  load_balancing_scheme = "EXTERNAL_MANAGED"
}
