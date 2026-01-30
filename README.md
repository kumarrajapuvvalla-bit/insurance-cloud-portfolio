# 🏥 Insurance Cloud Platform — Architecture Portfolio Project

> A full-stack, enterprise-grade cloud architecture replicating a real insurance company's Customer Experience (CE) platform. Built on GCP + Azure using Terraform, Cloud Run, Dialogflow CX, BigQuery, and Azure DevOps CI/CD.

---

## 📐 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Landing Zone (GCP)                           │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │                     Private Zone                             │     │
│  │                                                                │     │
│  │  [Cloud Storage] ──► [Workflow] ──► [Cloud Functions DSS Load] │     │
│  │  (DSS Staging)                                                 │     │
│  │                                          │                     │     │
│  │                                          ▼                     │     │
│  │  ┌─────────────────────────────────────────────────────────┐   │     │
│  │  │                     SQL VPC                             │   │     │
│  │  │      [Cloud SQL Database] ◄──► [Cloud SQL Backups]      │   │     │
│  │  └─────────────────────────────────────────────────────────┘   │     │
│  │                                                                │     │
│  │  [Secret Manager: DSS Credentials]                             │     │
│  │  [Secret Manager: API Credentials]                             │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │                     Public Zone                              │     │
│  │                                                                │     │
│  │  Internet ──► [Load Balancer + SSL Certificate]                │     │
│  │                          │                                     │     │
│  │                          ▼                                     │     │
│  │         [NextGen Proxy Router] ──► [CE Data API]               │     │
│  │                  │                        │                    │     │
│  │                  ▼                        ▼                    │     │
│  │  [Service Directory]        [BigQuery Raw Logs]                │     │
│  │                                      │                        │     │
│  │                             [Scheduled Queries]                │     │
│  │                                      │                        │     │
│  │                             [BigQuery Reporting]               │     │
│  │                                                                │     │
│  │  [Dialogflow CX Chatbot] ──► [VPC Service Controls Perimeter]  │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                         │
│  [Networking] ◄──► [Shared VPC]   [VPC Service Controls Perimeter]      │
└─────────────────────────────────────────────────────────────────────────┘

External Integrations:
  [Azure DevOps CI/CD Pipeline] ──deploy──► GCP
  [Genesys Call Centre] ──► [CX Connector] ──► Dialogflow Chatbot
  [Email / PagerDuty Alerts] ◄── Cloud Monitoring
  [SonarCloud Code Quality] ◄── Azure DevOps Pipeline
```

---

## 🗂️ Project Structure

```
insurance-cloud-portfolio/
├── terraform/                    # All infrastructure as code
│   ├── 00-providers.tf           # GCP + Azure provider configuration
│   ├── 01-variables.tf           # All input variable definitions
│   ├── 02-networking.tf          # VPC, subnets, firewall rules, Cloud NAT
│   ├── 03-security.tf            # IAM, service accounts, Secret Manager
│   ├── 04-database.tf            # Cloud SQL PostgreSQL + backups
│   ├── 05-storage.tf             # Cloud Storage buckets
│   ├── 06-cloud-functions.tf     # DSS Load ETL function + API logger
│   ├── 07-cloud-run.tf           # CE Data API + NextGen Proxy Router
│   ├── 08-load-balancer.tf       # HTTPS load balancer + SSL certificate
│   ├── 09-bigquery.tf            # Analytics datasets + scheduled queries
│   ├── 10-dialogflow.tf          # Chatbot agent + webhooks + service directory
│   ├── outputs.tf                # Useful values printed after deployment
│   └── terraform.tfvars.example  # Template showing all required values
├── api/                          # FastAPI REST application
│   ├── main.py                   # All API endpoints + Dialogflow webhook
│   ├── requirements.txt          # Python dependencies
│   └── Dockerfile                # Container definition for Cloud Run
├── functions/                    # Serverless Cloud Functions
│   ├── dss_load/
│   │   ├── main.py               # ETL function: CSV → Cloud SQL
│   │   ├── requirements.txt
│   │   └── schema.sql            # Database table definitions
│   └── api_logger/
│       ├── main.py               # Logs API requests to BigQuery
│       └── requirements.txt
├── data/
│   └── sample_policies.csv       # 10 sample insurance policies for testing
└── .azure/
    └── pipeline.yml              # Full Azure DevOps CI/CD pipeline
```

---

## 🧩 Components Built

### Networking & Security
| Component | GCP Service | Purpose |
|-----------|-------------|---------|
| VPC | Virtual Private Cloud | Private isolated network for all resources |
| Public Subnet | VPC Subnetwork | Network zone for internet-facing services |
| Private Subnet | VPC Subnetwork | Network zone for internal services only |
| SQL Subnet | VPC Subnetwork | Isolated network zone for the database |
| VPC Access Connector (Public) | Serverless VPC Access | Bridge: Cloud Run → private VPC |
| VPC Access Connector (Private) | Serverless VPC Access | Bridge: Cloud Functions → private VPC |
| Firewall Rules | Compute Firewall | Default deny, explicit allow only |
| Cloud NAT | Cloud NAT | Outbound internet for private resources |
| VPC Service Controls | VPC SC Perimeter | Security boundary around sensitive data |
| Private Service Connect | PSC Attachment | Expose services privately without public IP |

### Data Layer
| Component | GCP Service | Purpose |
|-----------|-------------|---------|
| Insurance Database | Cloud SQL PostgreSQL | Stores policies and claims data |
| Automated Backups | Cloud SQL Backups | Daily backups with point-in-time recovery |
| DSS Staging Bucket | Cloud Storage | Landing zone for incoming CSV data files |
| Artifact Buckets | Cloud Storage | Stores CI/CD build artifacts |
| DSS Load Function | Cloud Functions Gen2 | ETL pipeline: reads CSV, loads to database |
| Workflow Orchestrator | Cloud Workflows | Sequences and manages the data pipeline steps |

### API & Application Layer
| Component | GCP Service | Purpose |
|-----------|-------------|---------|
| CE Data API | Cloud Run | Main REST API for policies and claims |
| NextGen Proxy Router | Cloud Run | Handles routing and Azure AD authentication |
| Router Availability | Cloud Run | Lightweight health check target for load balancer |
| HTTPS Load Balancer | Cloud Load Balancing | Single entry point for all external traffic |
| SSL Certificate | Google Managed SSL | Encrypts all traffic with HTTPS |
| Service Directory | Service Directory | Registry where services discover each other |

### AI & Analytics
| Component | GCP Service | Purpose |
|-----------|-------------|---------|
| Dialogflow CX Agent | Dialogflow CX | Customer chatbot for policy and claims queries |
| CX Raw Logs | BigQuery | Stores every API request as a log entry |
| Scheduled Queries | BigQuery Data Transfer | Runs daily SQL to aggregate raw logs |
| Reporting Dataset | BigQuery | Processed data ready for business reporting |

### Security & Credentials
| Component | GCP Service | Purpose |
|-----------|-------------|---------|
| Secret Manager (DSS) | Secret Manager | Database password for the ETL function |
| Secret Manager (API) | Secret Manager | Database password for the CE Data API |
| Secret Manager (Azure AD) | Secret Manager | Azure credentials for authentication |
| API Service Account | IAM | Identity for the CE Data API (least privilege) |
| Functions Service Account | IAM | Identity for Cloud Functions (least privilege) |
| CI/CD Service Account | IAM | Identity for Azure DevOps to deploy to GCP |
| Notification Channels | Cloud Monitoring | Email alerts when errors occur |

---

## 🚀 Deployment Guide

### Prerequisites
- GCP account with billing enabled
- Azure account (free tier)
- Terraform >= 1.5.0 installed
- Google Cloud SDK (gcloud) installed
- Docker Desktop installed

### Step 1 — Clone and configure

```bash
git clone https://github.com/kumarrajapuvvalla-bit/insurance-cloud-portfolio.git
cd insurance-cloud-portfolio/terraform

# Copy the example config file
cp terraform.tfvars.example terraform.tfvars

# Open and fill in your real values
# (GCP project ID, Azure subscription ID, database password etc.)
notepad terraform.tfvars
```

### Step 2 — Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

### Step 3 — Initialise Terraform

```bash
terraform init
# Downloads all provider plugins (~200MB, takes 1-2 minutes)
```

### Step 4 — Preview what will be created

```bash
terraform plan
# Carefully read the output
# Should show approximately 55-65 resources to create
```

### Step 5 — Deploy the infrastructure

```bash
terraform apply
# Type "yes" when prompted
# Takes approximately 10-15 minutes to complete
# At the end, important values are printed (API URL, DB connection string etc.)
```

### Step 6 — Build and deploy the API

```bash
# Configure Docker to push to GCP
gcloud auth configure-docker gcr.io

# Build the Docker image
docker build -t gcr.io/YOUR_PROJECT_ID/insurance-api:latest ./api

# Push to Google Container Registry
docker push gcr.io/YOUR_PROJECT_ID/insurance-api:latest
```

### Step 7 — Create the database tables

```bash
# Start Cloud SQL Auth Proxy (creates a secure tunnel to your private database)
cloud_sql_proxy -instances=YOUR_PROJECT_ID:us-central1:INSTANCE_NAME=tcp:5432 &

# Run the schema SQL to create tables
psql "host=127.0.0.1 dbname=insurance_db user=insurance_app password=YOUR_PASSWORD" \
  -f functions/dss_load/schema.sql
```

### Step 8 — Load sample data

```bash
# Upload the sample CSV to trigger the ETL pipeline automatically
gsutil cp data/sample_policies.csv gs://YOUR_PROJECT_ID-dev-dss-staging/
```

### Step 9 — Test everything works

```bash
# Health check
curl https://YOUR_LOAD_BALANCER_IP/health

# Get a policy
curl https://YOUR_LOAD_BALANCER_IP/api/v1/policies/POL-001

# List all policies
curl https://YOUR_LOAD_BALANCER_IP/api/v1/policies
```

---

## 💰 Estimated Monthly Cost

| Service | Cost |
|---------|------|
| Cloud SQL (smallest tier) | ~$7/month |
| Cloud Run | ~$0/month (scales to zero when idle) |
| Cloud Storage | ~$0.50/month |
| BigQuery | ~$0/month (within free tier) |
| Cloud Functions | ~$0/month (within free tier) |
| Load Balancer | ~$18/month |
| **Total** | **~$25/month** |

> 💡 To save money: run `terraform destroy -target=google_compute_global_forwarding_rule.https_forwarding_rule` to remove the load balancer (~$18 saving) when not actively demonstrating the project.

---

## 🔐 Security Decisions

- **Database has no public IP** — only reachable from within the private VPC
- **All credentials in Secret Manager** — never hardcoded or in environment variables
- **Every service has its own service account** — if one service is compromised it cannot access others
- **Default deny firewall** — all traffic is blocked unless explicitly allowed
- **HTTPS only** — HTTP traffic is automatically redirected to HTTPS
- **VPC Service Controls** — data cannot leave the defined security perimeter

---

## 💬 Interview Talking Points

**On architecture choices:**
- "I chose Cloud Run over Kubernetes because the API is stateless and event-driven — scale-to-zero saves cost and there's no cluster to manage"
- "I separated the public and private subnets so the database zone is completely unreachable from the internet even if the API layer is compromised"
- "The Workflow orchestrator means the ETL pipeline steps are visible, retryable and auditable — rather than functions blindly calling each other"

**On security:**
- "Every service runs as its own service account with only the permissions it needs — the API can read secrets and connect to the database, nothing else"
- "The database only accepts connections from within the VPC via the VPC Access Connector — there is no way to reach it from the internet"

**On CI/CD:**
- "The Azure DevOps pipeline does a canary deployment to production — 10% of traffic goes to the new version first, monitored for 5 minutes, then promoted to 100%"
- "SonarCloud scans every pull request for security vulnerabilities before code is merged"

**On cost:**
- "Cloud Run scales to zero — when nobody is using the API the cost is literally zero"
- "BigQuery partitioning means queries only scan the relevant days of data instead of the entire table — dramatically reduces query cost at scale"

---

## 📚 Technologies Used

| Category | Technology |
|----------|------------|
| Cloud Platform | Google Cloud Platform (GCP) |
| CI/CD | Azure DevOps |
| Infrastructure as Code | Terraform |
| API Framework | Python FastAPI |
| Container Runtime | Docker + Cloud Run |
| Database | PostgreSQL on Cloud SQL |
| Serverless Functions | Cloud Functions Gen2 |
| Chatbot | Dialogflow CX |
| Analytics | BigQuery |
| Secret Management | GCP Secret Manager |
| Code Quality | SonarCloud |
| Alerting | Cloud Monitoring + Email |

---

*Built as a portfolio project to demonstrate enterprise DevOps and cloud architecture skills.*
