# -----------------------------------
# DSS STAGING BUCKET
# -----------------------------------
# Landing zone for incoming CSV data files.
# Upload here triggers the ETL pipeline via Pub/Sub → Cloud Function.
# Project ID prefix ensures globally unique bucket name.

resource "google_storage_bucket" "dss_staging" {
  project                     = var.gcp_project_id
  name                        = "${var.gcp_project_id}-${var.environment}-dss-staging"
  location                    = var.gcp_region
  storage_class               = "STANDARD"
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = false
  }

  # Auto-delete processed files after 7 days to keep storage costs flat
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    environment = var.environment
    purpose     = "dss-staging"
    data_class  = "sensitive"
  }
}

# Pub/Sub topic that the staging bucket publishes to on file upload
resource "google_pubsub_topic" "dss_load_trigger" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-dss-load-trigger"
}

# Grant Cloud Storage permission to publish to the topic
resource "google_pubsub_topic_iam_member" "storage_publisher" {
  project = var.gcp_project_id
  topic   = google_pubsub_topic.dss_load_trigger.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

data "google_storage_project_service_account" "gcs_account" {
  project = var.gcp_project_id
}

resource "google_storage_notification" "dss_staging_notification" {
  bucket         = google_storage_bucket.dss_staging.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.dss_load_trigger.id
  # Only trigger on completed uploads, not intermediate multipart chunks
  event_types    = ["OBJECT_FINALIZE"]
  depends_on     = [google_pubsub_topic_iam_member.storage_publisher]
}

# -----------------------------------
# PRIVATE ARTIFACT BUCKET
# -----------------------------------
# Stores Cloud Function deployment ZIPs and internal CI/CD artifacts.
# Versioning on so previous deployments can be rolled back.

resource "google_storage_bucket" "private_artifacts" {
  project                     = var.gcp_project_id
  name                        = "${var.gcp_project_id}-${var.environment}-priv-artifacts"
  location                    = var.gcp_region
  storage_class               = "STANDARD"
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    environment = var.environment
    purpose     = "private-artifacts"
    data_class  = "internal"
  }
}

# -----------------------------------
# PUBLIC ZONE ARTIFACT BUCKET
# -----------------------------------
# Artifacts for services in the public subnet.
# "Public" refers to the network zone, not internet accessibility —
# public_access_prevention is still enforced.

resource "google_storage_bucket" "public_artifacts" {
  project                     = var.gcp_project_id
  name                        = "${var.gcp_project_id}-${var.environment}-pub-artifacts"
  location                    = var.gcp_region
  storage_class               = "STANDARD"
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = {
    environment = var.environment
    purpose     = "public-zone-artifacts"
    data_class  = "internal"
  }
}

# -----------------------------------
# TERRAFORM STATE BUCKET
# -----------------------------------
# NOTE: Create this bucket manually before enabling the GCS backend in 00-providers.tf.
# Terraform cannot manage the bucket that stores its own state file.
#
# gsutil mb -p YOUR_PROJECT_ID -l us-central1 gs://YOUR_PROJECT_ID-terraform-state
# gsutil versioning set on gs://YOUR_PROJECT_ID-terraform-state

resource "google_storage_bucket" "terraform_state" {
  project                     = var.gcp_project_id
  name                        = "${var.gcp_project_id}-terraform-state"
  location                    = var.gcp_region
  storage_class               = "STANDARD"
  # Never force-destroy the state bucket — losing it means Terraform loses track of all resources
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = {
    environment = var.environment
    purpose     = "terraform-state"
    data_class  = "internal"
  }
}
