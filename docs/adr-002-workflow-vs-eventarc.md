# ADR-002: Cloud Workflows over Eventarc for the DSS data pipeline

**Date:** 2026-01-16
**Status:** Accepted

## Context

When a CSV file lands in the DSS staging bucket, we need to:
1. Validate the file format
2. Load the data into Cloud SQL
3. Handle failures and retries

Two options were evaluated: **Eventarc** (event-driven, direct trigger) and **Cloud Workflows** (orchestration engine).

The initial implementation used Eventarc to trigger the Cloud Function directly on bucket upload. This worked but caused problems:

- If the load step failed mid-way, there was no visibility into which step failed
- Retries re-ran the entire function including the validation step
- Adding a second step (e.g. post-load notification) meant functions calling functions directly — tight coupling with no central error handling

## Decision

Replace the direct Eventarc trigger with Cloud Workflows as the orchestrator. The bucket notification still fires via Pub/Sub, but it now triggers a Workflow instead of the function directly.

## Reasons

**Visibility.** Each step of the pipeline is a named step in the Workflow YAML. When something fails, the Cloud Console shows exactly which step failed and why. With direct function chaining, failures appeared as unstructured logs.

**Retries at the step level.** Workflows can retry individual steps rather than the whole pipeline. If validation passes but the load fails, only the load step retries.

**Decoupling.** The Cloud Function does one thing — load data. The Workflow owns the sequence. Adding a notification step or an archive step doesn't require changing the function code.

**Auditability.** Every Workflow execution is logged with inputs, outputs, and timing per step. This is useful for the insurance context where data pipeline runs need to be auditable.

## Trade-offs accepted

- Added complexity — two resources to manage (Workflow + Function) instead of one
- Slightly higher latency per pipeline run — the Workflow adds ~1 second of overhead
- Workflow YAML syntax has a learning curve

## Rejected alternative

Eventarc with direct trigger was kept in a branch for comparison. It is simpler to set up but lacks the observability and step-level control that makes the pipeline maintainable as requirements grow.
