# ============================================================
# FILE: outputs.tf
# PURPOSE: Display important values after terraform apply
# ============================================================
# ANALOGY: After building a house, outputs are like the
# summary sheet the contractor gives you:
# "Here is your address, your gas meter number, your
# electricity account number, your alarm code..."
#
# After "terraform apply" completes, these values are printed
# to the terminal. Very useful for knowing what was created.
# ============================================================

# -----------------------------------
# NETWORKING OUTPUTS
# -----------------------------------

output "vpc_id" {
  value       = google_compute_network.main_vpc.id
  description = "The ID of the main VPC"
}

output "vpc_name" {
  value       = google_compute_network.main_vpc.name
  description = "The name of the main VPC"
}

output "public_subnet_id" {
  value       = google_compute_subnetwork.public_subnet.id
  description = "ID of the public subnet (CE pub zone)"
}

output "private_subnet_id" {
  value       = google_compute_subnetwork.private_subnet.id
  description = "ID of the private subnet (CE priv zone)"
}

output "load_balancer_ip" {
  value       = google_compute_global_address.lb_ip.address
  description = "Public IP of the load balancer. Point your DNS A record to this IP."
}

# -----------------------------------
# DATABASE OUTPUTS
# -----------------------------------

output "database_instance_name" {
  value       = google_sql_database_instance.main_db.name
  description = "Cloud SQL instance name. Used in connection strings."
}

output "database_connection_name" {
  value       = google_sql_database_instance.main_db.connection_name
  description = "Cloud SQL connection name. Format: project:region:instance. Used by Cloud SQL Proxy."
}

output "database_private_ip" {
  value       = google_sql_database_instance.main_db.private_ip_address
  description = "Private IP of Cloud SQL. Only accessible from within the VPC."
}

output "local_connection_command" {
  value       = "cloud_sql_proxy -instances=${google_sql_database_instance.main_db.connection_name}=tcp:5432"
  description = "Command to connect to Cloud SQL from your laptop via Cloud SQL Auth Proxy"
}

# -----------------------------------
# CLOUD RUN OUTPUTS
# -----------------------------------

output "api_url" {
  value       = google_cloud_run_v2_service.ce_data_api.uri
  description = "Direct URL of the CE Data API Cloud Run service"
}

output "proxy_url" {
  value       = google_cloud_run_v2_service.nextgen_proxy.uri
  description = "URL of the NextGen Proxy Router Cloud Run service"
}

output "public_api_url" {
  value       = "https://${google_compute_global_address.lb_ip.address}"
  description = "Public HTTPS URL via load balancer. Use this for all external access."
}

# -----------------------------------
# STORAGE OUTPUTS
# -----------------------------------

output "staging_bucket_name" {
  value       = google_storage_bucket.dss_staging.name
  description = "DSS staging bucket. Upload CSV files here to trigger the data pipeline."
}

output "artifacts_bucket_name" {
  value       = google_storage_bucket.private_artifacts.name
  description = "Private artifacts bucket for CI/CD pipeline"
}

output "upload_data_command" {
  value       = "gsutil cp your_data.csv gs://${google_storage_bucket.dss_staging.name}/"
  description = "Command to upload a CSV file and trigger the DSS Load pipeline"
}

# -----------------------------------
# SERVICE ACCOUNT OUTPUTS
# -----------------------------------

output "api_service_account" {
  value       = google_service_account.api_sa.email
  description = "Service account email for the CE Data API"
}

output "cicd_service_account" {
  value       = google_service_account.cicd_sa.email
  description = "Service account email for CI/CD pipeline. Add this to Azure DevOps."
}

output "cicd_sa_key_command" {
  value       = "gcloud iam service-accounts keys create cicd-key.json --iam-account=${google_service_account.cicd_sa.email}"
  description = "Command to create a key for the CI/CD service account (for Azure DevOps)"
  # IMPORTANT: After creating the key, add it to Azure DevOps as a secret variable
  # Then delete cicd-key.json from your laptop
}

# -----------------------------------
# BIGQUERY OUTPUTS
# -----------------------------------

output "raw_logs_dataset" {
  value       = google_bigquery_dataset.cx_raw_logs.dataset_id
  description = "BigQuery dataset ID for raw CX logs (Component 27)"
}

output "reporting_dataset" {
  value       = google_bigquery_dataset.reporting.dataset_id
  description = "BigQuery dataset ID for processed reporting data (Component 29)"
}

output "bigquery_query_url" {
  value       = "https://console.cloud.google.com/bigquery?project=${var.gcp_project_id}"
  description = "Direct link to BigQuery console for this project"
}

# -----------------------------------
# DIALOGFLOW OUTPUTS
# -----------------------------------

output "dialogflow_agent_id" {
  value       = google_dialogflow_cx_agent.insurance_bot.name
  description = "Dialogflow CX agent ID. Used in API calls to the chatbot."
}

output "dialogflow_console_url" {
  value       = "https://dialogflow.cloud.google.com/cx/projects/${var.gcp_project_id}/locations/global/agents"
  description = "Direct link to the Dialogflow CX console for this project"
}

# -----------------------------------
# USEFUL COMMANDS SUMMARY
# -----------------------------------

output "next_steps" {
  value = <<-EOT
    
    ============================================================
    DEPLOYMENT COMPLETE - NEXT STEPS
    ============================================================
    
    1. PUSH DOCKER IMAGE:
       docker build -t gcr.io/${var.gcp_project_id}/insurance-api:latest ./api
       docker push gcr.io/${var.gcp_project_id}/insurance-api:latest
       
    2. CONFIGURE DNS:
       Point your domain A record to: ${google_compute_global_address.lb_ip.address}
       Wait 10-60 minutes for SSL certificate to provision.
    
    3. LOAD SAMPLE DATA:
       gsutil cp data/sample_policies.csv gs://${google_storage_bucket.dss_staging.name}/
    
    4. TEST THE API:
       curl https://${google_compute_global_address.lb_ip.address}/health
    
    5. VIEW LOGS:
       gcloud logging read "resource.type=cloud_run_revision" --limit=50
    
    6. OPEN DIALOGFLOW:
       https://dialogflow.cloud.google.com/cx/projects/${var.gcp_project_id}/locations/global/agents
    
    ============================================================
  EOT
  description = "Summary of next steps after deployment"
}
