# ============================================================
# FILE: 01-variables.tf
# PURPOSE: Define ALL input variables for the entire project
# ============================================================
# ANALOGY: Variables are like blank forms.
# This file creates the form with labels and descriptions.
# The terraform.tfvars file (which you create separately and
# NEVER commit to Git) fills in the actual values.
#
# This separation means:
# - Your code structure is public (safe to share on GitHub)
# - Your actual values/secrets stay private (in .tfvars)
# ============================================================

# -----------------------------------
# GCP PROJECT SETTINGS
# -----------------------------------

variable "gcp_project_id" {
  # The type tells Terraform what kind of value to expect
  type = string

  # Description explains what this variable is for
  # This appears in Terraform documentation and error messages
  description = "Your GCP Project ID. Found in GCP Console top bar. Format: my-project-123456"

  # No default - this MUST be provided. If missing, Terraform stops and asks for it.
  # For sensitive values like project IDs, never set a default.
}

variable "gcp_region" {
  type    = string
  default = "us-central1"
  # WHY us-central1: It's Google's cheapest and most feature-complete region.
  # For a portfolio project this is the best choice.
  # Other options: europe-west2 (London), asia-east1 (Taiwan)
  description = "GCP region to deploy resources. Default: us-central1 (Iowa, USA) - cheapest region"
}

variable "gcp_zone" {
  type    = string
  default = "us-central1-a"
  # Zones are named as: region + letter (a, b, c)
  # us-central1 has zones: a, b, c, f
  description = "GCP zone within the region. Must be within gcp_region."
}

variable "gcp_project_number" {
  type        = string
  description = "Your GCP Project NUMBER (different from ID). Found in GCP Console > Project Info widget."
  # WHY NEEDED: Some GCP APIs need the project number not the project ID
  # The number looks like: 123456789012 (just numbers)
  # The ID looks like: my-project-123456 (letters and numbers)
}

# -----------------------------------
# ENVIRONMENT SETTINGS
# -----------------------------------

variable "environment" {
  type    = string
  default = "dev"
  # In real companies there are multiple environments:
  # dev = development (where you build and test)
  # staging = pre-production (final testing before going live)
  # prod = production (real users, real data)
  # For your portfolio, we use "dev" only
  description = "Environment name. Used in resource naming. Values: dev, staging, prod"

  # Validation ensures only valid values are accepted
  # If you type "development" instead of "dev" Terraform will error with this message
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod"
  }
}

# -----------------------------------
# NETWORKING VARIABLES
# -----------------------------------
# CIDR NOTATION EXPLAINED:
# 10.0.0.0/16 means:
# - 10.0.0.0 is the starting IP address
# - /16 means the first 16 bits are fixed (the "network" part)
# - This gives you 65,536 possible IP addresses (10.0.0.0 to 10.0.255.255)
# - /24 gives you 256 addresses, /28 gives you 16 addresses

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "IP address range for the entire VPC. /16 gives 65,536 addresses - plenty for a portfolio project"
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "IP range for the public subnet (load balancer, public services). /24 = 256 addresses"
  # PUBLIC SUBNET: Resources here CAN receive traffic from the internet
  # Load balancer lives here
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "IP range for the private subnet (database, internal functions). /24 = 256 addresses"
  # PRIVATE SUBNET: Resources here CANNOT be reached from internet directly
  # Database and internal Cloud Functions live here
}

variable "sql_subnet_cidr" {
  type        = string
  default     = "10.0.3.0/24"
  description = "IP range for the SQL VPC subnet (Cloud SQL private IP). /24 = 256 addresses"
  # SQL gets its own subnet for extra isolation
  # Mirrors the SQL VPC (component 15) in the architecture diagram
}

# -----------------------------------
# DATABASE VARIABLES
# -----------------------------------

variable "db_name" {
  type        = string
  default     = "insurance_db"
  description = "Name of the PostgreSQL database to create inside Cloud SQL"
}

variable "db_user" {
  type        = string
  default     = "insurance_app"
  description = "Database username for the application to connect with"
  # NOT the root/admin user - applications should use limited-permission users
  # This is a security best practice called "principle of least privilege"
}

variable "db_password" {
  type        = string
  description = "Database password. Store this in terraform.tfvars ONLY - never hardcode here"
  # sensitive = true means Terraform will HIDE this value in all output and logs
  # You won't see it printed when Terraform runs - just shows as (sensitive)
  sensitive = true
}

variable "db_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Cloud SQL machine size. db-f1-micro is the smallest and cheapest - perfect for dev/portfolio"
  # Machine tiers and approximate costs (us-central1):
  # db-f1-micro  = 1 vCPU shared, 0.6GB RAM  ~$7/month  ← USE THIS for portfolio
  # db-g1-small  = 1 vCPU shared, 1.7GB RAM  ~$25/month
  # db-n1-standard-1 = 1 vCPU, 3.75GB RAM   ~$50/month
}

# -----------------------------------
# APPLICATION VARIABLES
# -----------------------------------

variable "api_image" {
  type        = string
  default     = "gcr.io/PROJECT_ID/insurance-api:latest"
  description = "Docker image URL for the FastAPI application. Replace PROJECT_ID after you create your GCP project"
  # gcr.io = Google Container Registry (where Docker images are stored)
  # Format: gcr.io/YOUR_PROJECT_ID/IMAGE_NAME:TAG
}

variable "api_min_instances" {
  type        = number
  default     = 0
  description = "Minimum Cloud Run instances. 0 means scale to zero when no traffic (saves money)"
  # SCALE TO ZERO: When nobody is using your API, Cloud Run shuts it down
  # Cost = $0 when idle. For portfolio this is perfect.
  # Downside: first request after idle takes ~2 seconds to "cold start"
}

variable "api_max_instances" {
  type        = number
  default     = 3
  description = "Maximum Cloud Run instances. Limits how many copies run simultaneously (controls cost)"
}

# -----------------------------------
# AZURE VARIABLES
# -----------------------------------

variable "azure_subscription_id" {
  type        = string
  description = "Azure Subscription ID. Found in Azure Portal > Subscriptions"
  sensitive   = true
}

variable "azure_location" {
  type        = string
  default     = "East US"
  description = "Azure region for DevOps resources. East US is cheapest."
}

# -----------------------------------
# NOTIFICATION VARIABLES
# -----------------------------------

variable "alert_email" {
  type        = string
  description = "Email address to receive system alerts and notifications (PagerDuty equivalent for portfolio)"
}
