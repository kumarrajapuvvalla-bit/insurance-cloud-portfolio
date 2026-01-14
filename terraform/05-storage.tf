# ============================================================
# FILE: 05-storage.tf
# PURPOSE: Cloud Storage buckets for staging data and artifacts
# ============================================================
# ANALOGY: Cloud Storage is like Google Drive for your applications.
# Files are stored in "buckets" (like folders) and can be
# accessed programmatically by your code.
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 20: Cloud Storage (DSS Staging) - where CSV files land
# - Component 13: Cloud Storage (Public Artifact Bucket) - Docker images
# - Component 14: Cloud Storage (Private Artifact Bucket) - private artifacts
# ============================================================

# -----------------------------------
# DSS STAGING BUCKET (Component 20)
# -----------------------------------
# PURPOSE: Where insurance data files (CSV) are uploaded
# before being processed and loaded into Cloud SQL.
#
# DATA FLOW:
# CSV file uploaded here → triggers Cloud Function → data loaded to Cloud SQL
#
# MAPS TO: Component 20 - "Cloud Storage (DSS Staging)"

resource "google_storage_bucket" "dss_staging" {
  project = var.gcp_project_id
  name    = "${var.gcp_project_id}-${var.environment}-dss-staging"
  # WHY PROJECT_ID IN NAME: Bucket names must be GLOBALLY unique across ALL
  # GCP customers worldwide. Using project_id (which is already unique)
  # as a prefix guarantees your bucket name won't conflict with others.

  location      = var.gcp_region
  # Location = where data is physically stored
  # Using the same region as other resources reduces latency and egress costs

  storage_class = "STANDARD"
  # Storage classes and use cases:
  # STANDARD  = frequently accessed data (~$0.02/GB/month)
  # NEARLINE  = accessed < once per month (~$0.01/GB/month)
  # COLDLINE  = accessed < once per quarter (~$0.004/GB/month)
  # ARCHIVE   = accessed < once per year (~$0.0012/GB/month)
  # Staging files are accessed frequently so STANDARD is correct

  # force_destroy = true means terraform destroy will delete the bucket
  # even if it contains files. Good for dev, risky for production.
  force_destroy = true

  # uniform_bucket_level_access = true enforces consistent access control
  # Either you have access to the bucket or you don't - no per-file permissions
  # This is a security best practice recommended by Google
  uniform_bucket_level_access = true

  # public_access_prevention = "enforced" means files can NEVER be made public
  # This is CRITICAL for insurance data - customer data must never be public
  public_access_prevention = "enforced"

  # versioning keeps previous versions of files when overwritten
  versioning {
    enabled = false
    # Disabled for staging bucket - we process and delete files quickly
    # No need to keep old versions of input files
  }

  # lifecycle rules automatically manage file retention
  lifecycle_rule {
    condition {
      age = 7
      # age = how many days old the file must be
    }
    action {
      type = "Delete"
      # Delete files older than 7 days automatically
      # Staging files are processed quickly - no need to keep them
      # This also keeps storage costs down
    }
  }

  # encryption - uses Google-managed key by default
  # For extra security you could use customer-managed keys (CMEK)
  # but that adds complexity and cost - not needed for portfolio

  labels = {
    environment = var.environment
    purpose     = "dss-staging"
    data_class  = "sensitive"
    # Labels help you track costs and organize resources
  }
}

# -----------------------------------
# BUCKET NOTIFICATION (triggers Cloud Function)
# -----------------------------------
# This tells GCP: "When a new file is uploaded to this bucket,
# send a notification to Pub/Sub, which triggers the Cloud Function"
#
# DATA FLOW: File uploaded → notification → Pub/Sub → Cloud Function triggered

resource "google_storage_notification" "dss_staging_notification" {
  bucket = google_storage_bucket.dss_staging.name

  payload_format = "JSON_API_V1"
  # JSON_API_V1 = notification message format
  # Contains file name, size, bucket, event type etc.

  topic = google_pubsub_topic.dss_load_trigger.id
  # Which Pub/Sub topic to send notifications to
  # The Cloud Function subscribes to this topic

  event_types = ["OBJECT_FINALIZE"]
  # OBJECT_FINALIZE = a file upload is COMPLETE (not just started)
  # Other options: OBJECT_DELETE, OBJECT_ARCHIVE, OBJECT_METADATA_UPDATE
  # We only want to trigger when upload is complete, not during upload

  depends_on = [google_pubsub_topic_iam_member.storage_publisher]
  # Must set up permissions before creating notification
}

# Pub/Sub topic for the staging bucket trigger
resource "google_pubsub_topic" "dss_load_trigger" {
  project = var.gcp_project_id
  name    = "insurance-${var.environment}-dss-load-trigger"
  # Pub/Sub = messaging service. Think of it as a notification system.
  # Cloud Storage publishes a message here when a file is uploaded.
  # Cloud Function subscribes and gets triggered.
}

# Give Cloud Storage permission to publish to the Pub/Sub topic
resource "google_pubsub_topic_iam_member" "storage_publisher" {
  project = var.gcp_project_id
  topic   = google_pubsub_topic.dss_load_trigger.name
  role    = "roles/pubsub.publisher"

  # GCS_ACCOUNT is the special service account that GCS uses internally
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# Get the GCS service account email for the project
data "google_storage_project_service_account" "gcs_account" {
  project = var.gcp_project_id
  # data sources in Terraform fetch existing info (vs creating new resources)
  # This gets the email of GCS's built-in service account for your project
}

# -----------------------------------
# PRIVATE ARTIFACT BUCKET (Component 14)
# -----------------------------------
# PURPOSE: Store private build artifacts, deployment packages,
# and any other files the CI/CD pipeline produces internally.
#
# MAPS TO: Component 14 - "Cloud Storage (Priv Artifact Bucket)"

resource "google_storage_bucket" "private_artifacts" {
  project  = var.gcp_project_id
  name     = "${var.gcp_project_id}-${var.environment}-priv-artifacts"
  location = var.gcp_region

  storage_class            = "STANDARD"
  force_destroy            = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
    # versioning ON for artifacts - you want to be able to roll back
    # to a previous version of a deployment artifact if something breaks
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      # Keep only the 5 most recent versions of each file
    }
    action {
      type = "Delete"
      # Delete older versions automatically
    }
  }

  labels = {
    environment = var.environment
    purpose     = "private-artifacts"
    data_class  = "internal"
  }
}

# -----------------------------------
# PUBLIC ARTIFACT BUCKET (Component 13)
# -----------------------------------
# PURPOSE: Store build artifacts that need to be accessed
# by public-facing services (like Cloud Run startup scripts).
#
# NOTE: "Public" here means accessible within GCP, NOT open to the internet.
# public_access_prevention is still enforced.
#
# MAPS TO: Component 13 - "Cloud Storage (Priv Artifact Bucket)" in CE pub zone

resource "google_storage_bucket" "public_artifacts" {
  project  = var.gcp_project_id
  name     = "${var.gcp_project_id}-${var.environment}-pub-artifacts"
  location = var.gcp_region

  storage_class               = "STANDARD"
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Still enforced even though it's called "public" - the name refers to
  # it being in the CE pub zone, not being open to the internet

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
# PURPOSE: Store Terraform's state file remotely (instead of your laptop)
# This is the bucket referenced in the backend config in 00-providers.tf
#
# IMPORTANT: Create this MANUALLY first, THEN enable the backend.
# You can't use Terraform to create the bucket that stores Terraform's state
# (chicken-and-egg problem).
#
# Manual creation command (run once):
# gsutil mb -p YOUR_PROJECT_ID -l us-central1 gs://YOUR_PROJECT_ID-terraform-state
# gsutil versioning set on gs://YOUR_PROJECT_ID-terraform-state

resource "google_storage_bucket" "terraform_state" {
  project  = var.gcp_project_id
  name     = "${var.gcp_project_id}-terraform-state"
  location = var.gcp_region

  storage_class               = "STANDARD"
  force_destroy               = false
  # force_destroy = FALSE for state bucket - NEVER accidentally delete this
  # Losing the state file means Terraform doesn't know what it built

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
    # versioning ON - lets you recover if state file gets corrupted
  }

  labels = {
    environment = var.environment
    purpose     = "terraform-state"
    data_class  = "internal"
  }
}
