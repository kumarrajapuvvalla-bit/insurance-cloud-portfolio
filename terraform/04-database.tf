# -----------------------------------
# CLOUD SQL INSTANCE
# -----------------------------------
# Random suffix in name avoids the 7-day cooldown on reused Cloud SQL instance names

resource "google_sql_database_instance" "main_db" {
  depends_on = [google_service_networking_connection.private_vpc_connection]

  project          = var.gcp_project_id
  name             = "insurance-${var.environment}-db-${random_id.suffix.hex}"
  database_version = "POSTGRES_15"
  region           = var.gcp_region
  deletion_protection = false

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    disk_autoresize_limit = 50

    ip_configuration {
      # No public IP — database is only reachable from within the VPC
      ipv4_enabled    = false
      private_network = google_compute_network.main_vpc.id
      require_ssl     = true
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    # Sunday 3am — lowest traffic window for insurance workloads
    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }

    database_flags {
      name  = "max_connections"
      value = "100"
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false
    }
  }
}

# -----------------------------------
# DATABASE + USER
# -----------------------------------

resource "google_sql_database" "insurance_db" {
  project   = var.gcp_project_id
  name      = var.db_name
  instance  = google_sql_database_instance.main_db.name
  charset   = "UTF8"
  collation = "en_US.UTF8"
}

# Application user — not the root admin
resource "google_sql_user" "app_user" {
  project  = var.gcp_project_id
  name     = var.db_user
  instance = google_sql_database_instance.main_db.name
  password = var.db_password
  type     = "BUILT_IN"
}
