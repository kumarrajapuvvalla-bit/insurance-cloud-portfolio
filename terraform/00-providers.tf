terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }

    # google-beta needed for VPC Service Controls and other preview features
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0.0"
    }

    # random suffix to ensure globally unique resource names (e.g. storage buckets)
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }

  # Uncomment to enable remote state in GCS (recommended for team environments)
  # backend "gcs" {
  #   bucket = "YOUR_PROJECT_ID-terraform-state"
  #   prefix = "terraform/state"
  # }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

provider "azurerm" {
  # features block is required by the azurerm provider even when empty
  features {}
  subscription_id = var.azure_subscription_id
}

provider "random" {}
