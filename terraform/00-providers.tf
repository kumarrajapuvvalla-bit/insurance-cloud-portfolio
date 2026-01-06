# ============================================================
# FILE: 00-providers.tf
# PURPOSE: Tell Terraform WHICH cloud platforms we are using
# ============================================================
# ANALOGY: Think of providers like installing apps on your phone.
# Before you can use Google Maps, you install it first.
# Before Terraform can talk to GCP or Azure, you "install"
# the provider plugin that knows how to speak to that cloud's API.
# ============================================================
# WHY THIS FILE IS NUMBERED 00:
# Terraform runs files in alphabetical order.
# By numbering files 00, 01, 02... we control the order.
# Providers MUST be defined before anything else, so they go first.
# ============================================================

# -----------------------------------
# TERRAFORM CORE SETTINGS
# -----------------------------------
terraform {
  # This block sets the minimum Terraform version required.
  # Like saying "this app requires iOS 16 or higher"
  required_version = ">= 1.5.0"

  # Required providers tells Terraform which plugins to download
  # when you run "terraform init" for the first time
  required_providers {

    # Google Cloud Platform provider
    # This plugin knows how to create/manage GCP resources
    # Source: where to download it from (Terraform's public registry)
    # Version: which version to use (>= means "this version or newer")
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }

    # Google Beta provider - same as above but gives access to
    # GCP features that are still in "beta" (preview/testing)
    # Some services like VPC Service Controls need beta features
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0.0"
    }

    # Azure provider - for Azure DevOps CI/CD pipeline resources
    # We use Azure for the deployment pipeline (mirroring the original architecture)
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0.0"
    }

    # Random provider - generates random strings
    # Used to create unique names for resources (like storage bucket names)
    # Bucket names must be globally unique across ALL GCP users worldwide
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }

  # -----------------------------------
  # REMOTE STATE STORAGE (OPTIONAL)
  # -----------------------------------
  # WHAT IS STATE: Terraform keeps a "memory" file called terraform.tfstate
  # This file records everything Terraform has built.
  # Without it, Terraform doesn't know what already exists.
  #
  # WHY REMOTE: By default state is saved locally on your laptop.
  # If your laptop breaks, you lose the state and Terraform gets confused.
  # Remote state saves it in a GCP bucket instead - safe and shareable.
  #
  # HOW TO USE: Uncomment this block after you create your GCP project
  # and replace YOUR_PROJECT_ID and YOUR_BUCKET_NAME with real values
  #
  # backend "gcs" {
  #   bucket = "YOUR_PROJECT_ID-terraform-state"  # GCS bucket to store state
  #   prefix = "terraform/state"                  # Folder path inside the bucket
  # }
}

# -----------------------------------
# CONFIGURE THE GCP PROVIDER
# -----------------------------------
# This tells the GCP provider your project details
# Think of this as "logging in" to your GCP account via Terraform
provider "google" {
  # Your GCP project ID - replace when you create your project
  # This is NOT the project name, it's the unique ID (e.g. "my-project-123456")
  project = var.gcp_project_id

  # The default region where resources will be created
  # A region is a geographic location (us-central1 = Iowa, USA)
  # We use var. to reference variables defined in 01-variables.tf
  region = var.gcp_region

  # The default zone within the region
  # A zone is like a specific building within a city
  # Zones give you redundancy - if one zone fails, others keep running
  zone = var.gcp_zone
}

# Same configuration for the beta provider
# Must match the regular google provider settings
provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# -----------------------------------
# CONFIGURE THE AZURE PROVIDER
# -----------------------------------
provider "azurerm" {
  # This empty features block is REQUIRED by the Azure provider
  # Even if empty, it must be here or Terraform will error
  # It can contain optional feature flags to customize Azure behavior
  features {}

  # Your Azure subscription ID
  # Found in Azure Portal > Subscriptions
  subscription_id = var.azure_subscription_id
}

# -----------------------------------
# RANDOM PROVIDER
# -----------------------------------
# No configuration needed for the random provider
# It works out of the box
provider "random" {}
