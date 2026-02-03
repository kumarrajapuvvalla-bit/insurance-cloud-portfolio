# -----------------------------------
# GCP PROJECT
# -----------------------------------

variable "gcp_project_id" {
  type        = string
  description = "GCP Project ID (e.g. my-project-123456)"
}

variable "gcp_region" {
  type        = string
  default     = "us-central1"
  description = "GCP region for all resources"
}

variable "gcp_zone" {
  type        = string
  default     = "us-central1-a"
  description = "GCP zone within gcp_region"
}

variable "gcp_project_number" {
  type        = string
  description = "GCP Project number — required by some APIs that don't accept the project ID"
}

# -----------------------------------
# ENVIRONMENT
# -----------------------------------

variable "environment" {
  type    = string
  default = "dev"
  description = "Deployment environment: dev, staging, or prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod"
  }
}

# -----------------------------------
# NETWORKING
# -----------------------------------

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "IP range for the VPC"
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "IP range for the public subnet (load balancer, external-facing services)"
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "IP range for the private subnet (internal functions, connectors)"
}

variable "sql_subnet_cidr" {
  type        = string
  default     = "10.0.3.0/24"
  description = "IP range for the SQL subnet — isolated to limit database blast radius"
}

# -----------------------------------
# DATABASE
# -----------------------------------

variable "db_name" {
  type        = string
  default     = "insurance_db"
  description = "PostgreSQL database name"
}

variable "db_user" {
  type        = string
  default     = "insurance_app"
  description = "Application database user (not the root admin)"
}

variable "db_password" {
  type        = string
  description = "Database password — provide via terraform.tfvars, never hardcode"
  sensitive   = true
}

variable "db_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Cloud SQL machine tier. db-f1-micro (~$7/month) is sufficient for dev/portfolio"
}

# -----------------------------------
# APPLICATION
# -----------------------------------

variable "api_image" {
  type        = string
  default     = "gcr.io/PROJECT_ID/insurance-api:latest"
  description = "Docker image URI for the CE Data API Cloud Run service"
}

variable "api_min_instances" {
  type        = number
  default     = 0
  description = "Minimum Cloud Run instances. 0 enables scale-to-zero when idle"
}

variable "api_max_instances" {
  type        = number
  default     = 3
  description = "Maximum Cloud Run instances to cap concurrent scaling"
}

# -----------------------------------
# AZURE
# -----------------------------------

variable "azure_subscription_id" {
  type        = string
  description = "Azure Subscription ID for DevOps pipeline resources"
  sensitive   = true
}

variable "azure_location" {
  type        = string
  default     = "East US"
  description = "Azure region for DevOps resources"
}

# -----------------------------------
# NOTIFICATIONS
# -----------------------------------

variable "alert_email" {
  type        = string
  description = "Email address for Cloud Monitoring alert notifications"
}
