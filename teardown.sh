#!/usr/bin/env bash
# Teardown script for Cigna Falcon/Batch test environment
# AWS Account: 597047870845 | Region: us-east-1

set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="597047870845"

JOB_DEFINITION="cs-falcon-job"
JOB_QUEUE="cs-fargate-queue"
COMPUTE_ENV="cs-fargate-ce"

ECR_REPOS=(
  "cs-batch-test"
  "falcon-sensor/falcon-container"
  "cs-batch-test-patched"
)

# ecsTaskExecutionRole may be shared — skipped by default
DELETE_IAM_ROLE=false
IAM_ROLE="ecsTaskExecutionRole"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }

wait_for_queue_status() {
  local queue=$1 desired=$2
  log "Waiting for job queue '$queue' to reach status '$desired'..."
  for i in $(seq 1 30); do
    local status
    status=$(aws batch describe-job-queues \
      --job-queues "$queue" \
      --region "$REGION" \
      --query "jobQueues[0].status" \
      --output text 2>/dev/null || echo "NOTFOUND")
    [[ "$status" == "$desired" || "$status" == "NOTFOUND" ]] && return 0
    sleep 5
  done
  warn "Timed out waiting for queue '$queue' to reach '$desired'"
  return 1
}

wait_for_ce_status() {
  local ce=$1 desired=$2
  log "Waiting for compute env '$ce' to reach status '$desired'..."
  for i in $(seq 1 30); do
    local status
    status=$(aws batch describe-compute-environments \
      --compute-environments "$ce" \
      --region "$REGION" \
      --query "computeEnvironments[0].status" \
      --output text 2>/dev/null || echo "NOTFOUND")
    [[ "$status" == "$desired" || "$status" == "NOTFOUND" ]] && return 0
    sleep 5
  done
  warn "Timed out waiting for compute env '$ce' to reach '$desired'"
  return 1
}

# ── 1. Deregister all revisions of the job definition ────────────────────────

log "Deregistering job definition revisions for '$JOB_DEFINITION'..."
ARNS=$(aws batch describe-job-definitions \
  --job-definition-name "$JOB_DEFINITION" \
  --status ACTIVE \
  --region "$REGION" \
  --query "jobDefinitions[].jobDefinitionArn" \
  --output text 2>/dev/null || true)

if [[ -n "$ARNS" ]]; then
  for arn in $ARNS; do
    log "  Deregistering $arn"
    aws batch deregister-job-definition --job-definition "$arn" --region "$REGION"
  done
else
  log "  No active revisions found — skipping"
fi

# ── 2. Disable then delete the job queue ─────────────────────────────────────

log "Disabling job queue '$JOB_QUEUE'..."
aws batch update-job-queue \
  --job-queue "$JOB_QUEUE" \
  --state DISABLED \
  --region "$REGION" 2>/dev/null || { warn "Queue '$JOB_QUEUE' not found — skipping"; }

wait_for_queue_status "$JOB_QUEUE" "VALID"

log "Deleting job queue '$JOB_QUEUE'..."
aws batch delete-job-queue \
  --job-queue "$JOB_QUEUE" \
  --region "$REGION" 2>/dev/null || warn "Queue '$JOB_QUEUE' already gone"

wait_for_queue_status "$JOB_QUEUE" "NOTFOUND"

# ── 3. Disable then delete the compute environment ───────────────────────────

log "Disabling compute environment '$COMPUTE_ENV'..."
aws batch update-compute-environment \
  --compute-environment "$COMPUTE_ENV" \
  --state DISABLED \
  --region "$REGION" 2>/dev/null || { warn "Compute env '$COMPUTE_ENV' not found — skipping"; }

wait_for_ce_status "$COMPUTE_ENV" "VALID"

log "Deleting compute environment '$COMPUTE_ENV'..."
aws batch delete-compute-environment \
  --compute-environment "$COMPUTE_ENV" \
  --region "$REGION" 2>/dev/null || warn "Compute env '$COMPUTE_ENV' already gone"

wait_for_ce_status "$COMPUTE_ENV" "NOTFOUND"

# ── 4. Delete ECR repositories ───────────────────────────────────────────────

for repo in "${ECR_REPOS[@]}"; do
  log "Deleting ECR repository '$repo'..."
  aws ecr delete-repository \
    --repository-name "$repo" \
    --force \
    --region "$REGION" 2>/dev/null || warn "Repo '$repo' not found — skipping"
done

# ── 5. Remove ECS Exec inline policy ─────────────────────────────────────────

log "Removing inline policy 'ECSExecSSMPermissions' from '$IAM_ROLE'..."
aws iam delete-role-policy \
  --role-name "$IAM_ROLE" \
  --policy-name ECSExecSSMPermissions 2>/dev/null || warn "Policy 'ECSExecSSMPermissions' not found — skipping"

# ── 6. (Optional) Delete IAM role ────────────────────────────────────────────

if [[ "$DELETE_IAM_ROLE" == "true" ]]; then
  log "Detaching policies from IAM role '$IAM_ROLE'..."
  POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE" \
    --query "AttachedPolicies[].PolicyArn" \
    --output text 2>/dev/null || true)
  for policy in $POLICIES; do
    log "  Detaching $policy"
    aws iam detach-role-policy --role-name "$IAM_ROLE" --policy-arn "$policy"
  done
  log "Deleting IAM role '$IAM_ROLE'..."
  aws iam delete-role --role-name "$IAM_ROLE" 2>/dev/null || warn "Role '$IAM_ROLE' not found"
else
  log "Skipping IAM role deletion (set DELETE_IAM_ROLE=true to include)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

log "Teardown complete."
