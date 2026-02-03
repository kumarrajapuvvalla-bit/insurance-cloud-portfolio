# Random suffix for resources that require globally unique names (e.g. storage buckets)
resource "random_id" "suffix" {
  byte_length = 4
}

# -----------------------------------
# ENABLE REQUIRED APIs
# -----------------------------------
# GCP APIs are disabled by default — each service must be explicitly enabled

resource "google_project_service" "compute_api" {
  project            = var.gcp_project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin_api" {
  project            = var.gcp_project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run_api" {
  project            = var.gcp_project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudfunctions_api" {
  project            = var.gcp_project_id
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager_api" {
  project            = var.gcp_project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "bigquery_api" {
  project            = var.gcp_project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "vpcaccess_api" {
  project            = var.gcp_project_id
  service            = "vpcaccess.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicedirectory_api" {
  project            = var.gcp_project_id
  service            = "servicedirectory.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dialogflow_api" {
  project            = var.gcp_project_id
  service            = "dialogflow.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "workflows_api" {
  project            = var.gcp_project_id
  service            = "workflows.googleapis.com"
  disable_on_destroy = false
}

# -----------------------------------
# VPC
# -----------------------------------

resource "google_compute_network" "main_vpc" {
  depends_on = [google_project_service.compute_api]

  project                 = var.gcp_project_id
  name                    = "insurance-${var.environment}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  description             = "Main VPC for Insurance CE Platform - ${var.environment}"
}

# -----------------------------------
# SUBNETS
# -----------------------------------

resource "google_compute_subnetwork" "public_subnet" {
  depends_on = [google_compute_network.main_vpc]

  project                  = var.gcp_project_id
  name                     = "insurance-${var.environment}-public-subnet"
  region                   = var.gcp_region
  network                  = google_compute_network.main_vpc.self_link
  ip_cidr_range            = var.public_subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.0.10.0/24"
  }
}

resource "google_compute_subnetwork" "private_subnet" {
  depends_on = [google_compute_network.main_vpc]

  project                  = var.gcp_project_id
  name                     = "insurance-${var.environment}-private-subnet"
  region                   = var.gcp_region
  network                  = google_compute_network.main_vpc.self_link
  ip_cidr_range            = var.private_subnet_cidr
  private_ip_google_access = true
}

# Separate subnet for Cloud SQL — limits blast radius if the private subnet is compromised
resource "google_compute_subnetwork" "sql_subnet" {
  depends_on = [google_compute_network.main_vpc]

  project                  = var.gcp_project_id
  name                     = "insurance-${var.environment}-sql-subnet"
  region                   = var.gcp_region
  network                  = google_compute_network.main_vpc.self_link
  ip_cidr_range            = var.sql_subnet_cidr
  private_ip_google_access = true
}

# -----------------------------------
# CLOUD ROUTER + NAT
# -----------------------------------

resource "google_compute_router" "main_router" {
  depends_on = [google_compute_network.main_vpc]

  project = var.gcp_project_id
  name    = "insurance-${var.environment}-router"
  region  = var.gcp_region
  network = google_compute_network.main_vpc.self_link
}

resource "google_compute_router_nat" "main_nat" {
  project                            = var.gcp_project_id
  name                               = "insurance-${var.environment}-nat"
  router                             = google_compute_router.main_router.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# -----------------------------------
# VPC ACCESS CONNECTORS
# -----------------------------------
# Serverless services (Cloud Run, Functions) run outside the VPC.
# Connectors bridge them into the private network so they can reach Cloud SQL.

resource "google_vpc_access_connector" "public_connector" {
  depends_on = [
    google_project_service.vpcaccess_api,
    google_compute_subnetwork.public_subnet,
  ]

  project = var.gcp_project_id
  # Name capped at 25 characters
  name    = "insurance-${var.environment}-pub-conn"
  region  = var.gcp_region

  subnet {
    name = google_compute_subnetwork.public_subnet.name
  }

  machine_type  = "e2-micro"
  min_instances = 2
  max_instances = 3
}

resource "google_vpc_access_connector" "private_connector" {
  depends_on = [
    google_project_service.vpcaccess_api,
    google_compute_subnetwork.private_subnet,
  ]

  project = var.gcp_project_id
  name    = "insurance-${var.environment}-priv-conn"
  region  = var.gcp_region

  subnet {
    name = google_compute_subnetwork.private_subnet.name
  }

  machine_type  = "e2-micro"
  min_instances = 2
  max_instances = 3
}

# -----------------------------------
# PRIVATE SERVICE CONNECTION (Cloud SQL)
# -----------------------------------
# Cloud SQL with private IP requires Private Service Access —
# a dedicated peered IP range for Google-managed services.

resource "google_compute_global_address" "private_ip_range" {
  project       = var.gcp_project_id
  name          = "insurance-${var.environment}-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main_vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

# -----------------------------------
# FIREWALL RULES
# -----------------------------------

resource "google_compute_firewall" "allow_https" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-allow-https"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["load-balancer"]
  description   = "Allow HTTPS traffic from internet to load balancer only"
}

resource "google_compute_firewall" "allow_http" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-allow-http"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["load-balancer"]
  description   = "Allow HTTP — redirect to HTTPS handled at load balancer level"
}

resource "google_compute_firewall" "allow_internal" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-allow-internal"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [
    var.public_subnet_cidr,
    var.private_subnet_cidr,
    var.sql_subnet_cidr,
  ]

  description = "Allow all traffic between subnets within the VPC"
}

resource "google_compute_firewall" "allow_health_checks" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-allow-health-checks"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  # GCP load balancer health check source ranges (documented by Google)
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["load-balancer", "http-server"]
  description   = "Allow GCP load balancer health checks"
}

resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-deny-all-ingress"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Default deny — explicit allow rules above take priority"
}

# -----------------------------------
# PRIVATE SERVICE CONNECT
# -----------------------------------

resource "google_compute_service_attachment" "api_attachment" {
  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-api-attachment"
  region      = var.gcp_region
  description = "Private Service Connect attachment for CE API"

  connection_preference = "ACCEPT_AUTOMATIC"
  nat_subnets           = [google_compute_subnetwork.public_subnet.self_link]
  enable_proxy_protocol = false
}
