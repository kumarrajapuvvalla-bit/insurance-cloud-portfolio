# ============================================================
# FILE: 04-database.tf
# PURPOSE: Cloud SQL PostgreSQL database setup
# ============================================================
# ANALOGY: If the VPC is a city and subnets are neighbourhoods,
# the database is a secure bank vault inside the most
# restricted neighbourhood - only authorised staff with the
# right keycard (service account + password) can enter.
#
# ARCHITECTURE COMPONENTS BUILT HERE:
# - Component 16: Cloud SQL (DSS Database)
# - Component 17: Cloud SQL Backups
# - Component 22: Cloud SQL Admin API access
# ============================================================

# -----------------------------------
# CLOUD SQL INSTANCE
# -----------------------------------
# WHAT IS CLOUD SQL:
# A fully managed relational database service.
# "Managed" means Google handles: backups, updates, failover, scaling.
# You just use the database - no server maintenance needed.
#
# WHY POSTGRESQL:
# PostgreSQL is the most popular open-source relational database.
# It's what most enterprise insurance systems use.
# Employers recognise it immediately.

resource "google_sql_database_instance" "main_db" {
  depends_on = [
    google_service_networking_connection.private_vpc_connection,
    # Must wait for private VPC connection before creating DB with private IP
  ]

  project          = var.gcp_project_id
  name             = "insurance-${var.environment}-db-${random_id.suffix.hex}"
  # Random suffix ensures globally unique name
  # GCP requires Cloud SQL instance names to be globally unique (not just in your project)
  # Once deleted, the name can't be reused for 7 days - random suffix avoids conflicts

  database_version = "POSTGRES_15"
  # POSTGRES_15 = PostgreSQL version 15 (latest stable as of 2024)
  # Other options: POSTGRES_14, POSTGRES_13 (older but still supported)

  region = var.gcp_region

  # deletion_protection = true prevents accidental deletion
  # In production this should ALWAYS be true
  # For dev/portfolio set to false so you can destroy cleanly
  deletion_protection = false

  settings {
    # Machine tier - controls CPU and RAM
    tier = var.db_tier
    # db-f1-micro: shared vCPU, 0.6GB RAM - perfect for portfolio (~$7/month)

    # availability_type controls high availability:
    # ZONAL = single zone (one copy, if zone fails DB is down) - cheaper
    # REGIONAL = two zones (automatic failover if one zone fails) - production use
    availability_type = "ZONAL"
    # We use ZONAL for portfolio to save costs

    disk_size = 10
    # Minimum 10GB disk - more than enough for sample insurance data
    # GCP charges per GB so keep this small for portfolio

    disk_type = "PD_SSD"
    # PD_SSD = SSD disk (faster, better for databases)
    # PD_HDD = HDD disk (cheaper but slower)

    disk_autoresize = true
    # disk_autoresize = automatically increase disk if it gets full
    # Prevents your database from going down due to disk space

    disk_autoresize_limit = 50
    # Maximum disk size in GB - prevents unexpected cost spikes

    # -----------------------------------
    # NETWORK SETTINGS (Private IP only)
    # -----------------------------------
    ip_configuration {
      # ipv4_enabled = false means NO public IP address
      # The database is ONLY accessible from within the VPC
      # This is the most important security setting for a database
      ipv4_enabled    = false

      # private_network = which VPC to connect the DB to
      private_network = google_compute_network.main_vpc.id

      # require_ssl = true forces all connections to use SSL encryption
      # Without this, data travelling between your app and DB is unencrypted
      require_ssl = true

      # ssl_mode: ENCRYPTED_ONLY = accept SSL connections only
      ssl_mode = "ENCRYPTED_ONLY"
    }

    # -----------------------------------
    # BACKUP CONFIGURATION (Component 17)
    # -----------------------------------
    # WHAT ARE BACKUPS:
    # Automatic copies of your database at regular intervals.
    # If something goes wrong (bad query, accidental delete, corruption),
    # you can restore to a previous point in time.
    #
    # MAPS TO: Component 17 - Cloud SQL Backups

    backup_configuration {
      enabled = true
      # enabled = true turns on automatic daily backups

      start_time = "02:00"
      # Time to start backup (24hr format, UTC timezone)
      # 2am UTC = low traffic time for most users

      point_in_time_recovery_enabled = true
      # PITR = Point In Time Recovery
      # Lets you restore to ANY point in the last 7 days, not just daily snapshots
      # Example: "restore to exactly 3:47pm yesterday before the bad query ran"

      transaction_log_retention_days = 7
      # How many days of transaction logs to keep (used for PITR)

      backup_retention_settings {
        retained_backups = 7
        # Keep 7 backup copies (one per day for a week)
        retention_unit   = "COUNT"
        # COUNT = keep N backups | TIME = keep backups for N days
      }
    }

    # -----------------------------------
    # MAINTENANCE WINDOW
    # -----------------------------------
    # When GCP can perform maintenance (updates, patches)
    # Schedule this for your lowest traffic time

    maintenance_window {
      day          = 7    # 7 = Sunday (least traffic day for insurance)
      hour         = 3    # 3am UTC
      update_track = "stable"
      # stable = tested updates (vs canary = bleeding edge)
    }

    # -----------------------------------
    # DATABASE FLAGS
    # -----------------------------------
    # PostgreSQL configuration settings
    # Like settings.ini for the database engine itself

    database_flags {
      name  = "max_connections"
      value = "100"
      # Maximum simultaneous database connections
      # db-f1-micro can handle ~25 connections practically
      # 100 is the safe maximum for this tier
    }

    database_flags {
      name  = "log_connections"
      value = "on"
      # Log every new connection to the database
      # Useful for debugging and security auditing
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
      # Log every disconnection
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
      # Log any query that takes longer than 1000ms (1 second)
      # Helps identify slow queries for optimization
    }

    # -----------------------------------
    # INSIGHTS (Query performance monitoring)
    # -----------------------------------
    insights_config {
      query_insights_enabled  = true
      # Captures slow queries and execution plans
      # Visible in GCP Console > Cloud SQL > Query Insights

      query_string_length     = 1024
      # How many characters of the query to capture

      record_application_tags = true
      # Capture tags your app sends with queries (for grouping)

      record_client_address   = false
      # Don't record client IP for privacy
    }
  }
}

# -----------------------------------
# DATABASE
# -----------------------------------
# This creates the actual DATABASE inside the Cloud SQL instance.
# Instance = the server
# Database = the container of tables inside the server
# (One instance can have multiple databases)

resource "google_sql_database" "insurance_db" {
  project  = var.gcp_project_id
  name     = var.db_name
  # var.db_name = "insurance_db" (from variables.tf)

  instance = google_sql_database_instance.main_db.name
  # Which Cloud SQL instance to create this database in

  charset   = "UTF8"
  # Character encoding - UTF8 supports all international characters
  # Important for insurance data that may have names with accents

  collation = "en_US.UTF8"
  # Collation = how text is sorted and compared
  # en_US.UTF8 = English sorting rules with UTF8 encoding
}

# -----------------------------------
# DATABASE USER
# -----------------------------------
# The application's database user
# NOT the root/admin user - follows principle of least privilege

resource "google_sql_user" "app_user" {
  project  = var.gcp_project_id
  name     = var.db_user
  # var.db_user = "insurance_app" (from variables.tf)

  instance = google_sql_database_instance.main_db.name

  password = var.db_password
  # var.db_password comes from terraform.tfvars (never committed to Git)
  # This password is ALSO stored in Secret Manager (03-security.tf)
  # The app fetches it from Secret Manager at runtime

  type = "BUILT_IN"
  # BUILT_IN = standard username/password authentication
  # Alternative: CLOUD_IAM_USER (authenticate with service account instead of password)
}

# -----------------------------------
# DATABASE SCHEMA (Initial Setup)
# -----------------------------------
# NOTE: Terraform manages infrastructure, not usually database content.
# Schema (table definitions) are typically managed with a migration tool
# like Flyway or Alembic.
#
# However for this portfolio project, we include a null_resource
# that runs SQL to create initial tables.
# In a real project, use Flyway or a startup migration script.

# The actual table creation SQL will be in a separate migration file
# See: functions/dss_load/schema.sql

# -----------------------------------
# CLOUD SQL PROXY (for local development)
# -----------------------------------
# NOTE: This is NOT a Terraform resource, but important to document here.
# Cloud SQL has no public IP, so you can't connect to it directly from
# your laptop. You use Cloud SQL Auth Proxy which creates a secure tunnel.
#
# To connect locally, run:
# cloud_sql_proxy -instances=YOUR_PROJECT:REGION:INSTANCE_NAME=tcp:5432
# Then connect to: postgresql://insurance_app:PASSWORD@127.0.0.1:5432/insurance_db
#
# The CI/CD pipeline uses this to run database migrations automatically.
