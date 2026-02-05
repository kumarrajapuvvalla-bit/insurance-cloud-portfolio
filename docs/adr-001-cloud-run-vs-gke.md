# ADR-001: Cloud Run over GKE for API services

**Date:** 2026-01-14
**Status:** Accepted

## Context

The CE Data API and NextGen Proxy need to be containerised and deployed to GCP. The two main options were Google Kubernetes Engine (GKE) and Cloud Run.

The platform handles insurance policy and claims queries. Traffic is bursty — high during business hours, near-zero overnight and on weekends.

## Decision

Use Cloud Run for both the CE Data API and NextGen Proxy.

## Reasons

**Scale to zero.** Cloud Run shuts down when there's no traffic. For a platform with predictable off-peak periods, this eliminates the cost of idle compute. GKE requires a minimum node pool running 24/7 (~$70+/month for even the smallest cluster).

**No cluster management.** GKE requires managing node pools, upgrades, autoscaler configuration, and network policies. Cloud Run offloads all of that to Google. For a team without a dedicated platform engineer, that operational overhead isn't justified.

**Cold start is acceptable.** The main downside of scale-to-zero is cold starts (~1-2 seconds). For an internal insurance API where users tolerate slight delays, this is acceptable. A customer-facing checkout flow would be a different decision.

**Deployment simplicity.** Cloud Run deployments are a single `gcloud run deploy` command. Canary deployments (10% → 100%) are built in via traffic splitting. Replicating this in GKE requires Istio or a custom ingress setup.

## Trade-offs accepted

- No persistent storage per instance (stateless only) — acceptable since all state lives in Cloud SQL
- Limited control over networking compared to GKE — acceptable since VPC connector covers our requirements
- Max 60-minute request timeout — acceptable for our use case

## Rejected alternative

GKE Autopilot was considered as a middle ground. Rejected because it still requires cluster-level thinking and costs more than Cloud Run at our scale.
