# ============================================================
# FILE: 02-networking.tf
# PURPOSE: Build the entire network foundation
# ============================================================
# ANALOGY: Think of this file as building the roads and
# buildings of a city before anyone moves in.
# 
# VPC = The entire city (private, fenced off from the world)
# Subnets = Different neighbourhoods within the city
# Firewall Rules = The security guards at each neighbourhood entrance
# VPC Access Connector = A secure tunnel between neighbourhoods
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 3: Shared VPC foundation
# - Component 7: Public subnet (CE pub)
# - Component 8: Private subnet (CE priv)
# - Component 15: SQL VPC subnet
# - Component 9 & 10: VPC Access Connectors
# - Component 6: VPC SC Perimeter (foundation)
# - Component 41: Private Service Connect
# ============================================================

# -----------------------------------
# RANDOM SUFFIX FOR UNIQUE NAMES
# -----------------------------------
# WHY: GCP requires some resource names to be globally unique.
# Adding a random suffix prevents naming conflicts.
# Example: "insurance-dev-bucket-a3f2" instead of just "insurance-dev-bucket"
resource "random_id" "suffix" {
  byte_length = 4
  # byte_length = 4 generates an 8-character hex string (e.g. "a3f2b1c9")
}

# -----------------------------------
# ENABLE REQUIRED GCP APIS
# -----------------------------------
# WHY: GCP services are disabled by default for security and billing control.
# You must explicitly enable each API before using it.
# Like installing apps - you can't use Google Maps until you install it.

resource "google_project_service" "compute_api" {
  # The project to enable the API on
  project = var.gcp_project_id
  # The API identifier - always in format "service.googleapis.com"
  service = "compute.googleapis.com"
  # compute API = everything networking related (VPC, subnets, firewall, load balancer)

  # disable_on_destroy = false means: when we terraform destroy, don't disable the API
  # WHY: Disabling APIs can break other things in your project
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin_api" {
  project            = var.gcp_project_id
  service            = "sqladmin.googleapis.com"
  # sqladmin = Cloud SQL management API
  disable_on_destroy = false
}

resource "google_project_service" "run_api" {
  project            = var.gcp_project_id
  service            = "run.googleapis.com"
  # run = Cloud Run (serverless containers)
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
  # vpcaccess = VPC Access Connector (lets serverless talk to VPC)
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
# MAIN VPC (Virtual Private Cloud)
# -----------------------------------
# WHAT IS A VPC:
# A VPC is your private, isolated section of Google's network.
# Nobody outside can access resources inside unless you explicitly allow it.
# It's like having your own private office building inside Google's data center.
#
# MAPS TO: The outer boundary labeled "CE Landing Zone" in the architecture diagram

resource "google_compute_network" "main_vpc" {
  # depends_on ensures the Compute API is enabled before creating the VPC
  # Terraform would fail trying to create a VPC if the API isn't enabled yet
  depends_on = [google_project_service.compute_api]

  project = var.gcp_project_id

  # Resource naming convention: service-environment-description
  # Using interpolation (${}) to insert variable values into strings
  name = "insurance-${var.environment}-vpc"
  # Result example: "insurance-dev-vpc"

  # auto_create_subnetworks = false means WE control the subnets
  # If true, GCP would automatically create a subnet in every region
  # We want manual control for security and to match our architecture
  auto_create_subnetworks = false

  # Routing mode GLOBAL means routes are shared across all regions
  # REGIONAL would mean each region is isolated
  # GLOBAL is better for multi-region architectures
  routing_mode = "GLOBAL"

  description = "Main VPC for Insurance CE Platform - ${var.environment} environment"
}

# -----------------------------------
# PUBLIC SUBNET (CE pub zone)
# -----------------------------------
# WHO LIVES HERE: Load Balancer, Cloud Run services that receive external traffic
# INTERNET ACCESS: YES (with firewall rules controlling what gets through)
# MAPS TO: Component 7 - "Pub subnet" in architecture diagram

resource "google_compute_subnetwork" "public_subnet" {
  depends_on = [google_compute_network.main_vpc]

  project = var.gcp_project_id
  name    = "insurance-${var.environment}-public-subnet"
  region  = var.gcp_region

  # The VPC this subnet belongs to (referenced by self_link - a unique URL identifier)
  network = google_compute_network.main_vpc.self_link

  # IP range for this subnet - defined in variables.tf
  # 10.0.1.0/24 = addresses from 10.0.1.0 to 10.0.1.255
  ip_cidr_range = var.public_subnet_cidr

  # private_ip_google_access = true means resources WITHOUT external IPs
  # can still reach Google APIs (like Secret Manager, BigQuery)
  # This is important for security - resources don't need public IPs to work
  private_ip_google_access = true

  # Secondary IP ranges are used by services like Google Kubernetes Engine
  # We define them here for future use even though we don't use GKE now
  # Named ranges make it clear what each range is for
  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.0.10.0/24"
  }
}

# -----------------------------------
# PRIVATE SUBNET (CE priv zone)
# -----------------------------------
# WHO LIVES HERE: Cloud Functions for data processing, VPC Access Connectors
# INTERNET ACCESS: NO (can only be reached from within the VPC)
# MAPS TO: Component 8 - "Priv subnet" in architecture diagram

resource "google_compute_subnetwork" "private_subnet" {
  depends_on = [google_compute_network.main_vpc]

  project       = var.gcp_project_id
  name          = "insurance-${var.environment}-private-subnet"
  region        = var.gcp_region
  network       = google_compute_network.main_vpc.self_link
  ip_cidr_range = var.private_subnet_cidr

  # Same as public subnet - allows reaching Google APIs without public IP
  private_ip_google_access = true
}

# -----------------------------------
# SQL SUBNET (Database isolation)
# -----------------------------------
# WHO LIVES HERE: Cloud SQL database
# INTERNET ACCESS: ABSOLUTELY NOT (database should never be internet-facing)
# MAPS TO: Component 15 - "SQL VPC" in architecture diagram
# 
# WHY SEPARATE SUBNET FOR DATABASE:
# Extra isolation layer. Even if someone breaks into the private subnet,
# they still can't reach the database without crossing another boundary.

resource "google_compute_subnetwork" "sql_subnet" {
  depends_on = [google_compute_network.main_vpc]

  project       = var.gcp_project_id
  name          = "insurance-${var.environment}-sql-subnet"
  region        = var.gcp_region
  network       = google_compute_network.main_vpc.self_link
  ip_cidr_range = var.sql_subnet_cidr

  private_ip_google_access = true
}

# -----------------------------------
# CLOUD ROUTER
# -----------------------------------
# WHAT IS A ROUTER:
# A Cloud Router enables dynamic routing within your VPC.
# Required for Cloud NAT (below) to work.
# Think of it as the traffic director for your private network.

resource "google_compute_router" "main_router" {
  depends_on = [google_compute_network.main_vpc]

  project = var.gcp_project_id
  name    = "insurance-${var.environment}-router"
  region  = var.gcp_region
  network = google_compute_network.main_vpc.self_link
}

# -----------------------------------
# CLOUD NAT (Network Address Translation)
# -----------------------------------
# WHAT IS NAT:
# Private resources have no public IP, so they can't access the internet.
# But sometimes they need to (download packages, call external APIs).
# NAT acts as a proxy - private resources send requests TO NAT,
# NAT sends them to the internet on their behalf, returns the response.
#
# ANALOGY: Like a post office for private resources.
# Your house (private resource) doesn't have a public address.
# You send mail to the post office (NAT), it sends it with ITS address.
# Replies come back to the post office, which delivers to you.

resource "google_compute_router_nat" "main_nat" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-nat"
  router  = google_compute_router.main_router.name
  region  = var.gcp_region

  # AUTO_ONLY = let GCP automatically assign public IPs for NAT
  # Alternative: MANUAL_ONLY (you specify which public IPs to use)
  nat_ip_allocate_option = "AUTO_ONLY"

  # ALL_SUBNETWORKS_ALL_IP_RANGES = apply NAT to all private subnets
  # Alternative: LIST_OF_SUBNETWORKS (specify which subnets use NAT)
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Keep NAT logs for debugging connectivity issues
  log_config {
    enable = true
    filter = "ERRORS_ONLY" # Only log failed connections (keeps costs down)
  }
}

# -----------------------------------
# VPC ACCESS CONNECTOR - PUBLIC ZONE
# -----------------------------------
# WHAT IS A VPC ACCESS CONNECTOR:
# Cloud Run and Cloud Functions are "serverless" - they run outside your VPC.
# But your database is INSIDE your VPC (private).
# A VPC Access Connector is a bridge that lets serverless services
# reach resources inside your private VPC.
#
# ANALOGY: Like a secure revolving door between two buildings.
# Without it, the serverless service can't enter the VPC building.
#
# MAPS TO: Component 9 - "VPC Access Connector" in CE pub zone

resource "google_vpc_access_connector" "public_connector" {
  depends_on = [
    google_project_service.vpcaccess_api,
    google_compute_subnetwork.public_subnet
  ]

  project = var.gcp_project_id
  name    = "insurance-${var.environment}-pub-conn"
  # Name limit: max 25 characters, so we abbreviate
  region  = var.gcp_region

  # Which subnet this connector bridges INTO
  subnet {
    name = google_compute_subnetwork.public_subnet.name
  }

  # Machine type for the connector instances
  # e2-micro is smallest and cheapest - fine for portfolio
  machine_type = "e2-micro"

  # Min/max instances for the connector
  # More instances = more throughput but more cost
  min_instances = 2 # Minimum 2 for high availability
  max_instances = 3
}

# -----------------------------------
# VPC ACCESS CONNECTOR - PRIVATE ZONE
# -----------------------------------
# Same as above but for the private subnet
# MAPS TO: Component 10 - "VPC Access Connector" in CE priv zone

resource "google_vpc_access_connector" "private_connector" {
  depends_on = [
    google_project_service.vpcaccess_api,
    google_compute_subnetwork.private_subnet
  ]

  project      = var.gcp_project_id
  name         = "insurance-${var.environment}-priv-conn"
  region       = var.gcp_region

  subnet {
    name = google_compute_subnetwork.private_subnet.name
  }

  machine_type  = "e2-micro"
  min_instances = 2
  max_instances = 3
}

# -----------------------------------
# PRIVATE SERVICE CONNECTION (for Cloud SQL)
# -----------------------------------
# WHY: Cloud SQL with private IP needs a special connection called
# "Private Service Access" to communicate with your VPC.
# This allocates a range of IPs specifically for Google-managed services.

resource "google_compute_global_address" "private_ip_range" {
  project       = var.gcp_project_id
  name          = "insurance-${var.environment}-private-ip-range"
  purpose       = "VPC_PEERING"
  # VPC_PEERING = this IP range is for peering with Google services

  address_type  = "INTERNAL"
  # INTERNAL = private IPs (not public internet IPs)

  prefix_length = 16
  # /16 gives 65,536 IP addresses for Google's managed services

  network       = google_compute_network.main_vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network = google_compute_network.main_vpc.id
  service = "servicenetworking.googleapis.com"
  # This is the Google service that manages private connections

  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  # Use the IP range we allocated above
}

# -----------------------------------
# FIREWALL RULES
# -----------------------------------
# WHAT ARE FIREWALL RULES:
# Rules that control what traffic is allowed IN (ingress) or OUT (egress)
# of your VPC. Like a bouncer at a club checking IDs.
#
# Each rule has:
# - direction: INGRESS (incoming) or EGRESS (outgoing)
# - priority: lower number = checked first (1000 is default)
# - action: allow or deny
# - target: which resources this applies to (by network tag)
# - source/destination: where traffic comes from or goes to

# RULE 1: Allow HTTPS traffic to the load balancer from anywhere
resource "google_compute_firewall" "allow_https" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-allow-https"
  network = google_compute_network.main_vpc.name

  direction = "INGRESS" # Incoming traffic

  allow {
    protocol = "tcp"  # TCP is the protocol (vs UDP)
    ports    = ["443"] # 443 = HTTPS port
  }

  # 0.0.0.0/0 means "from anywhere on the internet"
  # We ONLY allow this for HTTPS to the load balancer
  source_ranges = ["0.0.0.0/0"]

  # target_tags means this rule only applies to resources WITH this tag
  # Only the load balancer will have the "load-balancer" tag
  target_tags = ["load-balancer"]

  description = "Allow HTTPS traffic from internet to load balancer only"
}

# RULE 2: Allow HTTP (but only to redirect to HTTPS)
resource "google_compute_firewall" "allow_http" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-allow-http"
  network = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80"] # 80 = HTTP port
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["load-balancer"]
  description   = "Allow HTTP to redirect to HTTPS"
}

# RULE 3: Allow internal VPC traffic
# Resources within the VPC need to talk to each other
resource "google_compute_firewall" "allow_internal" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-allow-internal"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["0-65535"] # All TCP ports for internal communication
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"] # All UDP ports
  }

  allow {
    protocol = "icmp" # ICMP = ping (useful for debugging)
  }

  # Only allow traffic FROM within the VPC's own IP ranges
  source_ranges = [
    var.public_subnet_cidr,  # From public subnet
    var.private_subnet_cidr, # From private subnet
    var.sql_subnet_cidr      # From SQL subnet
  ]

  description = "Allow all internal VPC traffic between subnets"
}

# RULE 4: Allow Google health checks
# Load balancers send health checks to make sure your app is running
# These come from Google's special health check IP ranges
resource "google_compute_firewall" "allow_health_checks" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-allow-health-checks"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  # These are Google's official health check IP ranges
  # MUST be allowed or load balancer thinks your app is down
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["load-balancer", "http-server"]
  description   = "Allow GCP load balancer health checks"
}

# RULE 5: Deny all other ingress (default deny)
# After the above allows, block everything else
# This is the security principle: "deny by default, allow explicitly"
resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.gcp_project_id
  name      = "insurance-${var.environment}-deny-all-ingress"
  network   = google_compute_network.main_vpc.name
  direction = "INGRESS"
  priority  = 65534 # Very high number = checked LAST (after all allow rules)

  deny {
    protocol = "all" # Block everything not explicitly allowed above
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Default deny all ingress - must be last rule checked"
}

# -----------------------------------
# PRIVATE SERVICE CONNECT
# -----------------------------------
# MAPS TO: Component 41 - "Private Service Connect Service Attachment"
# PURPOSE: Allows services to be consumed privately without exposing
# them to the public internet. Like a private back door for services.

resource "google_compute_service_attachment" "api_attachment" {
  # This depends on the load balancer forwarding rule (defined in 08-load-balancer.tf)
  # We comment it out here and it will be uncommented after load balancer is built
  # Uncomment when load balancer is set up:
  # target_service = google_compute_forwarding_rule.api_forwarding_rule.id

  project     = var.gcp_project_id
  name        = "insurance-${var.environment}-api-attachment"
  region      = var.gcp_region
  description = "Private Service Connect attachment for CE API"

  # ACCEPT_AUTOMATIC = automatically accept connection requests
  # Alternative: ACCEPT_MANUAL (you approve each connection request)
  connection_preference = "ACCEPT_AUTOMATIC"

  # Which subnets to use for the NAT (network address translation) of this attachment
  nat_subnets = [google_compute_subnetwork.public_subnet.self_link]

  # enable_proxy_protocol sends client IP info through the connection
  enable_proxy_protocol = false
}
