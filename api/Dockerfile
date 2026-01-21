# ============================================================
# FILE: api/Dockerfile
# PURPOSE: Package the FastAPI app into a Docker container
# ============================================================
# ANALOGY: A Dockerfile is like a recipe.
# Docker follows it step by step to build a "container image".
# The image is a snapshot of the app + everything it needs to run.
# Cloud Run takes this image and runs it for you.
#
# WHY CONTAINERS:
# "It works on my laptop but not on the server" is a classic problem.
# Containers solve this - the app runs in the same environment everywhere.
# ============================================================

# -----------------------------------
# BASE IMAGE
# -----------------------------------
# Start FROM an existing image that already has Python installed
# "python:3.11-slim" = Python 3.11 on minimal Linux (slim = small image size)
# Smaller image = faster deployments, less storage cost
FROM python:3.11-slim

# -----------------------------------
# SECURITY: Run as non-root user
# -----------------------------------
# By default containers run as root (admin) which is a security risk
# We create a regular user and switch to it
RUN groupadd -r appuser && useradd -r -g appuser appuser

# -----------------------------------
# WORKING DIRECTORY
# -----------------------------------
# WORKDIR sets the "current folder" for all subsequent commands
# Like cd /app in the terminal
WORKDIR /app

# -----------------------------------
# INSTALL SYSTEM DEPENDENCIES
# -----------------------------------
# Some Python packages need system libraries to compile
# Install them before installing Python packages
RUN apt-get update && apt-get install -y \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*
# rm -rf /var/lib/apt/lists/* = clean up apt cache to keep image small

# -----------------------------------
# INSTALL PYTHON DEPENDENCIES
# -----------------------------------
# COPY requirements.txt first (before the rest of the code)
# WHY: Docker caches each layer. If requirements.txt hasn't changed,
# Docker reuses the cached layer instead of reinstalling packages.
# This makes rebuilds much faster.
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt
# --no-cache-dir = don't cache pip downloads (keeps image smaller)

# -----------------------------------
# COPY APPLICATION CODE
# -----------------------------------
# Copy all files from the api/ folder into /app in the container
COPY . .

# Change ownership to our non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# -----------------------------------
# EXPOSE PORT
# -----------------------------------
# Tell Docker which port the app listens on
# This is documentation only - doesn't actually open the port
# Cloud Run handles port routing externally
EXPOSE 8080

# -----------------------------------
# HEALTH CHECK
# -----------------------------------
# Docker periodically runs this to check if the container is healthy
# Cloud Run also uses the /health endpoint we defined in main.py
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

# -----------------------------------
# START COMMAND
# -----------------------------------
# CMD is the command that runs when the container starts
# uvicorn runs our FastAPI application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
# --host 0.0.0.0 = accept connections from any IP
# --port 8080 = listen on port 8080
# --workers 1 = one worker process (Cloud Run scales by adding containers, not workers)
