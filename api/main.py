# ============================================================
# FILE: api/main.py
# PURPOSE: The main FastAPI REST API application
# ============================================================
# This is the CE Data API (Component 25 in architecture)
# It handles all policy and claims operations.
# The Dialogflow chatbot calls this API to get real data.
# ============================================================

import os
import json
import uuid
import time
import logging
from datetime import datetime
from typing import Optional

# FastAPI imports
from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# Google Cloud imports
from google.cloud import secretmanager
from google.cloud import pubsub_v1
import sqlalchemy
from sqlalchemy import create_engine, text

# -----------------------------------
# LOGGING SETUP
# -----------------------------------
# structured logging = logs in JSON format (easier to query in GCP Logging)
logging.basicConfig(
    level=logging.INFO,
    format='{"timestamp": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

# -----------------------------------
# CONFIGURATION
# -----------------------------------
# All config comes from environment variables
# Environment variables are set in the Cloud Run config (Terraform 07-cloud-run.tf)

PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")
DB_NAME = os.environ.get("DB_NAME", "insurance_db")
DB_USER = os.environ.get("DB_USER", "insurance_app")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")  # Injected from Secret Manager
INSTANCE_CONNECTION_NAME = os.environ.get("INSTANCE_CONNECTION_NAME", "")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
LOGS_TOPIC = os.environ.get("LOGS_TOPIC", "")

# -----------------------------------
# DATABASE CONNECTION
# -----------------------------------
def get_db_engine():
    """
    Creates a SQLAlchemy database engine.
    Uses Cloud SQL Python connector for secure connection without Cloud SQL Proxy.
    """
    # Cloud SQL connection via Unix socket (when running on Cloud Run)
    # The path format is /cloudsql/PROJECT:REGION:INSTANCE
    db_socket_dir = os.environ.get("DB_SOCKET_DIR", "/cloudsql")
    cloud_sql_connection_name = INSTANCE_CONNECTION_NAME
    
    pool = create_engine(
        sqlalchemy.engine.url.URL.create(
            drivername="postgresql+pg8000",
            username=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME,
            query={
                "unix_sock": f"{db_socket_dir}/{cloud_sql_connection_name}/.s.PGSQL.5432"
            }
        ),
        pool_size=5,          # Keep 5 connections ready
        max_overflow=2,       # Allow 2 extra connections if all 5 are busy
        pool_timeout=30,      # Wait 30 seconds for a connection before erroring
        pool_recycle=1800,    # Replace connections older than 30 minutes
    )
    return pool

# Initialize DB engine (created once at startup, reused for all requests)
db_engine = None

def get_db():
    """Dependency injection for database connection"""
    global db_engine
    if db_engine is None:
        db_engine = get_db_engine()
    with db_engine.connect() as conn:
        yield conn

# -----------------------------------
# PUBSUB LOGGING
# -----------------------------------
publisher = pubsub_v1.PublisherClient()

def publish_log(request_id, endpoint, method, status_code, response_time_ms, 
                user_id=None, session_id=None, source=None, error=None):
    """Send log entry to Pub/Sub for BigQuery ingestion"""
    if not LOGS_TOPIC or not PROJECT_ID:
        return  # Skip logging if not configured
    
    log_entry = {
        "request_id": request_id,
        "request_timestamp": datetime.utcnow().isoformat(),
        "endpoint": endpoint,
        "http_method": method,
        "response_status_code": status_code,
        "response_time_ms": response_time_ms,
        "user_id": user_id,
        "session_id": session_id,
        "request_source": source,
        "error_message": error,
        "cloud_run_instance": os.environ.get("K_REVISION", "unknown")
    }
    
    try:
        topic_path = publisher.topic_path(PROJECT_ID, LOGS_TOPIC)
        data = json.dumps(log_entry).encode("utf-8")
        publisher.publish(topic_path, data=data)
    except Exception as e:
        # Log but don't fail the request if logging fails
        logger.warning(f"Failed to publish log: {e}")

# -----------------------------------
# FASTAPI APP
# -----------------------------------
app = FastAPI(
    title="Insurance CE Data API",
    description="Customer Experience Data API for Insurance Platform. Handles policies and claims.",
    version="1.0.0",
    docs_url="/docs",       # Swagger UI at /docs
    redoc_url="/redoc",     # ReDoc UI at /redoc
)

# CORS middleware - controls which websites can call this API
# Important for security - restrict to your actual frontend domain in production
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],        # Allow all origins (restrict in production)
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -----------------------------------
# MIDDLEWARE - Request logging
# -----------------------------------
@app.middleware("http")
async def log_requests(request: Request, call_next):
    """Log every request for monitoring and debugging"""
    request_id = str(uuid.uuid4())
    start_time = time.time()
    
    # Add request ID to response headers (useful for debugging)
    response = await call_next(request)
    
    response_time_ms = int((time.time() - start_time) * 1000)
    
    # Log to Pub/Sub for BigQuery
    publish_log(
        request_id=request_id,
        endpoint=str(request.url.path),
        method=request.method,
        status_code=response.status_code,
        response_time_ms=response_time_ms,
        source=request.headers.get("X-Webhook-Source")
    )
    
    logger.info(f"request_id={request_id} method={request.method} path={request.url.path} status={response.status_code} time_ms={response_time_ms}")
    
    response.headers["X-Request-ID"] = request_id
    return response

# -----------------------------------
# PYDANTIC MODELS (Request/Response schemas)
# -----------------------------------
# Pydantic models define the shape of your JSON data
# FastAPI uses them for automatic validation and documentation

class Policy(BaseModel):
    """A single insurance policy"""
    policy_id: str
    customer_name: str
    policy_type: str        # auto, home, life, health
    premium_amount: float
    coverage_amount: float
    start_date: str
    end_date: str
    status: str             # active, expired, cancelled

class Claim(BaseModel):
    """A single insurance claim"""
    claim_id: Optional[str] = None  # Auto-generated if not provided
    policy_id: str
    claim_date: str
    claim_amount: float
    description: str
    status: Optional[str] = "pending"  # pending, under_review, approved, denied

class ClaimResponse(BaseModel):
    """Response when creating a new claim"""
    claim_id: str
    message: str
    status: str

class WebhookRequest(BaseModel):
    """Dialogflow CX webhook request format"""
    sessionInfo: dict
    intentInfo: Optional[dict] = None
    text: Optional[str] = None

# -----------------------------------
# HEALTH CHECK ENDPOINT
# -----------------------------------
@app.get("/health")
async def health_check():
    """
    Health check endpoint.
    Load balancer and Cloud Run call this to verify the app is running.
    Must return 200 OK for the service to receive traffic.
    """
    return {
        "status": "healthy",
        "environment": ENVIRONMENT,
        "timestamp": datetime.utcnow().isoformat(),
        "version": "1.0.0"
    }

@app.get("/")
async def root():
    """Root endpoint with API info"""
    return {
        "api": "Insurance CE Data API",
        "version": "1.0.0",
        "environment": ENVIRONMENT,
        "docs": "/docs"
    }

# -----------------------------------
# POLICY ENDPOINTS
# -----------------------------------

@app.get("/api/v1/policies/{policy_id}", response_model=Policy)
async def get_policy(policy_id: str, db=Depends(get_db)):
    """
    Get a specific insurance policy by ID.
    
    Called by: Dialogflow webhook when customer asks "what's my policy?"
    """
    try:
        result = db.execute(
            text("SELECT * FROM policies WHERE policy_id = :policy_id"),
            {"policy_id": policy_id}
        ).fetchone()
        
        if not result:
            raise HTTPException(
                status_code=404,
                detail=f"Policy {policy_id} not found"
            )
        
        return {
            "policy_id": result.policy_id,
            "customer_name": result.customer_name,
            "policy_type": result.policy_type,
            "premium_amount": float(result.premium_amount),
            "coverage_amount": float(result.coverage_amount),
            "start_date": str(result.start_date),
            "end_date": str(result.end_date),
            "status": result.status
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error fetching policy {policy_id}: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

@app.get("/api/v1/policies")
async def list_policies(db=Depends(get_db)):
    """List all policies (limited to 100 for safety)"""
    try:
        results = db.execute(
            text("SELECT policy_id, customer_name, policy_type, status FROM policies LIMIT 100")
        ).fetchall()
        
        return {
            "policies": [
                {
                    "policy_id": r.policy_id,
                    "customer_name": r.customer_name,
                    "policy_type": r.policy_type,
                    "status": r.status
                }
                for r in results
            ],
            "count": len(results)
        }
    except Exception as e:
        logger.error(f"Error listing policies: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

# -----------------------------------
# CLAIMS ENDPOINTS
# -----------------------------------

@app.get("/api/v1/claims/{claim_id}")
async def get_claim(claim_id: str, db=Depends(get_db)):
    """
    Get claim status by claim ID.
    
    Called by: Dialogflow webhook when customer asks "what's my claim status?"
    """
    try:
        result = db.execute(
            text("SELECT * FROM claims WHERE claim_id = :claim_id"),
            {"claim_id": claim_id}
        ).fetchone()
        
        if not result:
            raise HTTPException(
                status_code=404,
                detail=f"Claim {claim_id} not found"
            )
        
        return {
            "claim_id": result.claim_id,
            "policy_id": result.policy_id,
            "claim_date": str(result.claim_date),
            "claim_amount": float(result.claim_amount),
            "description": result.description,
            "status": result.status,
            "last_updated": str(result.last_updated)
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error fetching claim {claim_id}: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

@app.get("/api/v1/policies/{policy_id}/claims")
async def get_policy_claims(policy_id: str, db=Depends(get_db)):
    """Get all claims for a specific policy"""
    try:
        results = db.execute(
            text("SELECT * FROM claims WHERE policy_id = :policy_id ORDER BY claim_date DESC"),
            {"policy_id": policy_id}
        ).fetchall()
        
        return {
            "policy_id": policy_id,
            "claims": [
                {
                    "claim_id": r.claim_id,
                    "claim_date": str(r.claim_date),
                    "claim_amount": float(r.claim_amount),
                    "status": r.status,
                    "description": r.description
                }
                for r in results
            ],
            "count": len(results)
        }
    except Exception as e:
        logger.error(f"Error fetching claims for policy {policy_id}: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/api/v1/claims", response_model=ClaimResponse)
async def create_claim(claim: Claim, db=Depends(get_db)):
    """
    File a new insurance claim.
    
    Called by: Dialogflow webhook when customer says "I want to file a claim"
    Also called by: Genesys Data Actions when agent files claim for customer
    """
    try:
        # Verify the policy exists and is active
        policy = db.execute(
            text("SELECT status FROM policies WHERE policy_id = :policy_id"),
            {"policy_id": claim.policy_id}
        ).fetchone()
        
        if not policy:
            raise HTTPException(status_code=404, detail=f"Policy {claim.policy_id} not found")
        
        if policy.status != "active":
            raise HTTPException(
                status_code=400,
                detail=f"Cannot file claim - policy is {policy.status}"
            )
        
        # Generate unique claim ID
        claim_id = f"CLM-{uuid.uuid4().hex[:8].upper()}"
        
        # Insert the claim
        db.execute(
            text("""
                INSERT INTO claims (claim_id, policy_id, claim_date, claim_amount, description, status, last_updated)
                VALUES (:claim_id, :policy_id, :claim_date, :claim_amount, :description, :status, NOW())
            """),
            {
                "claim_id": claim_id,
                "policy_id": claim.policy_id,
                "claim_date": claim.claim_date,
                "claim_amount": claim.claim_amount,
                "description": claim.description,
                "status": "pending"
            }
        )
        db.commit()
        
        logger.info(f"New claim created: {claim_id} for policy {claim.policy_id}")
        
        return {
            "claim_id": claim_id,
            "message": f"Claim {claim_id} successfully filed. You will receive updates via email.",
            "status": "pending"
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error creating claim: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

# -----------------------------------
# DIALOGFLOW WEBHOOK ENDPOINT
# -----------------------------------
@app.post("/webhook/dialogflow")
async def dialogflow_webhook(request: Request, db=Depends(get_db)):
    """
    Webhook endpoint for Dialogflow CX.
    
    Dialogflow calls this when it needs real data to respond to a customer.
    The request contains session parameters (like policy_id collected during conversation).
    We return fulfillment messages that Dialogflow speaks/texts back to the customer.
    """
    body = await request.json()
    
    # Extract session parameters from Dialogflow request
    session_params = body.get("sessionInfo", {}).get("parameters", {})
    tag = body.get("fulfillmentInfo", {}).get("tag", "")
    
    logger.info(f"Dialogflow webhook called with tag: {tag}")
    
    # Route based on the fulfillment tag
    # Tags are set in Dialogflow CX routes to identify which action to take
    
    if tag == "get_policy_info":
        policy_id = session_params.get("policy_id", "")
        if not policy_id:
            return {"fulfillmentResponse": {"messages": [{"text": {"text": ["I need your policy number. Could you please provide it?"]}}]}}
        
        result = db.execute(
            text("SELECT * FROM policies WHERE policy_id = :pid"),
            {"pid": policy_id}
        ).fetchone()
        
        if not result:
            message = f"I couldn't find policy number {policy_id}. Please check the number and try again."
        else:
            message = f"Your {result.policy_type} policy {policy_id} is currently {result.status}. Your coverage amount is ${result.coverage_amount:,.2f} and your monthly premium is ${result.premium_amount:,.2f}."
    
    elif tag == "get_claim_status":
        claim_id = session_params.get("claim_id", "")
        if not claim_id:
            return {"fulfillmentResponse": {"messages": [{"text": {"text": ["I need your claim ID. It starts with CLM- followed by letters and numbers."]}}]}}
        
        result = db.execute(
            text("SELECT * FROM claims WHERE claim_id = :cid"),
            {"cid": claim_id}
        ).fetchone()
        
        if not result:
            message = f"I couldn't find claim {claim_id}. Please double check the claim ID."
        else:
            message = f"Your claim {claim_id} is currently {result.status}. It was filed on {result.claim_date} for ${result.claim_amount:,.2f}."
    
    elif tag == "file_new_claim":
        policy_id = session_params.get("policy_id", "")
        claim_amount = session_params.get("claim_amount", 0)
        description = session_params.get("claim_description", "Claim filed via chatbot")
        
        if not policy_id or not claim_amount:
            message = "I need your policy number and claim amount to file a claim."
        else:
            claim_id = f"CLM-{uuid.uuid4().hex[:8].upper()}"
            db.execute(
                text("""
                    INSERT INTO claims (claim_id, policy_id, claim_date, claim_amount, description, status, last_updated)
                    VALUES (:claim_id, :policy_id, CURRENT_DATE, :claim_amount, :description, 'pending', NOW())
                """),
                {
                    "claim_id": claim_id,
                    "policy_id": policy_id,
                    "claim_amount": claim_amount,
                    "description": description
                }
            )
            db.commit()
            message = f"I've filed your claim successfully. Your claim ID is {claim_id}. You'll receive email updates about the status."
    
    else:
        message = "I'm here to help! You can ask me about your policy details, check a claim status, or file a new claim."
    
    # Dialogflow CX response format
    return {
        "fulfillmentResponse": {
            "messages": [
                {
                    "text": {
                        "text": [message]
                    }
                }
            ]
        },
        "sessionInfo": {
            "parameters": session_params
        }
    }

# -----------------------------------
# RUN THE SERVER
# -----------------------------------
if __name__ == "__main__":
    import uvicorn
    # uvicorn is the ASGI server that runs FastAPI
    # Port 8080 matches what Cloud Run expects
    uvicorn.run(
        "main:app",
        host="0.0.0.0",  # Listen on all interfaces
        port=8080,
        reload=False      # No auto-reload in production
    )
