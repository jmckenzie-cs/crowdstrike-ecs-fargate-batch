#!/usr/bin/env bash
# Enable ECS Exec on an existing AWS Batch job definition (prepare-only)
# Usage: [JOB_DEFINITION=...] [JOB_QUEUE=...] [REGION=...] [SSM_POLICY_NAME=...] ./enable-troubleshooting.sh
#
# What this script does:
#   1. Fetches the latest ACTIVE revision of the job definition
#   2. Derives the task role from containerProperties.jobRoleArn
#   3. Attaches (or refreshes) the ssmmessages:* inline policy on that role
#   4. Registers a new revision with enableExecuteCommand: true (if not already set)
#   5. Prints the submit-job and execute-command invocations to use next
#
# IMPORTANT: enableExecuteCommand is applied only at task launch. A task already
# running without it CANNOT be exec'd into — Fargate injects the SSM agent only at
# startup. You must submit a fresh job using the new revision printed at the end.

set -euo pipefail

JOB_DEFINITION="${JOB_DEFINITION:-cs-falcon-job}"
JOB_QUEUE="${JOB_QUEUE:-cs-fargate-queue}"
REGION="${REGION:-us-east-1}"
SSM_POLICY_NAME="${SSM_POLICY_NAME:-ECSExecSSMPermissions}"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }

# ── 1. Preflight ──────────────────────────────────────────────────────────────

log "Preflight checks..."

for cmd in aws jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found in PATH. Install it and retry." >&2
    exit 1
  fi
done

CALLER=$(aws sts get-caller-identity --region "$REGION" --output json 2>&1) || {
  echo "ERROR: aws sts get-caller-identity failed. Check credentials and region." >&2
  exit 1
}
ACCOUNT=$(echo "$CALLER" | jq -r '.Account')
CALLER_ARN=$(echo "$CALLER" | jq -r '.Arn')
log "  AWS account : $ACCOUNT"
log "  Caller      : $CALLER_ARN"
log "  Region      : $REGION"

# ── 2. Fetch latest ACTIVE revision ───────────────────────────────────────────

log "Fetching latest ACTIVE revision of job definition '$JOB_DEFINITION'..."

ALL_DEFS=$(aws batch describe-job-definitions \
  --job-definition-name "$JOB_DEFINITION" \
  --status ACTIVE \
  --region "$REGION" \
  --output json 2>&1) || {
  echo "ERROR: Failed to describe job definitions for '$JOB_DEFINITION'." >&2
  exit 1
}

LATEST_DEF=$(echo "$ALL_DEFS" | jq '.jobDefinitions | sort_by(.revision) | last // empty')

if [[ -z "$LATEST_DEF" || "$LATEST_DEF" == "null" ]]; then
  echo "ERROR: No ACTIVE revision found for job definition '$JOB_DEFINITION'." >&2
  echo "       Verify the name is correct and the definition has an ACTIVE status." >&2
  exit 1
fi

CURRENT_REVISION=$(echo "$LATEST_DEF" | jq -r '.revision')
CURRENT_ARN=$(echo "$LATEST_DEF" | jq -r '.jobDefinitionArn')
log "  Found: $CURRENT_ARN (revision $CURRENT_REVISION)"

# ── 3. Guard rails — only single-container containerProperties Fargate defs ───

if echo "$LATEST_DEF" | jq -e '.nodeProperties' &>/dev/null; then
  warn "This job definition uses nodeProperties (multi-node parallel). Only single-container"
  warn "containerProperties FARGATE definitions are supported by this script. Exiting."
  exit 1
fi

if echo "$LATEST_DEF" | jq -e '.ecsProperties' &>/dev/null; then
  warn "This job definition uses ecsProperties (multi-container ECS format). Only single-container"
  warn "containerProperties FARGATE definitions are supported by this script. Exiting."
  exit 1
fi

if echo "$LATEST_DEF" | jq -e '.eksProperties' &>/dev/null; then
  warn "This job definition uses eksProperties (EKS). Only single-container containerProperties"
  warn "FARGATE definitions are supported by this script. Exiting."
  exit 1
fi

if ! echo "$LATEST_DEF" | jq -e '.containerProperties' &>/dev/null; then
  echo "ERROR: Job definition has no containerProperties. Cannot proceed." >&2
  exit 1
fi

# ── 4. Derive task role from containerProperties.jobRoleArn ───────────────────

JOB_ROLE_ARN=$(echo "$LATEST_DEF" | jq -r '.containerProperties.jobRoleArn // empty')

if [[ -z "$JOB_ROLE_ARN" ]]; then
  echo "ERROR: containerProperties.jobRoleArn is not set on this job definition." >&2
  echo "       ECS Exec requires a task role with ssmmessages:* permissions." >&2
  echo "       Add 'jobRoleArn' to the job definition first, then re-run this script." >&2
  exit 1
fi

# Extract role name — everything after the last "role/"
# ARN format: arn:aws:iam::ACCOUNT:role/ROLENAME (colon before "role", not slash)
TASK_ROLE_NAME="${JOB_ROLE_ARN##*:role/}"
log "  Task role   : $TASK_ROLE_NAME ($JOB_ROLE_ARN)"

# ── 5. Add SSM inline policy to the task role (idempotent) ───────────────────

log "Attaching inline policy '$SSM_POLICY_NAME' to role '$TASK_ROLE_NAME'..."

SSM_POLICY_DOC='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel"
    ],
    "Resource": "*"
  }]
}'

aws iam put-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-name "$SSM_POLICY_NAME" \
  --policy-document "$SSM_POLICY_DOC" 2>&1 || {
  echo "ERROR: Failed to put inline policy on role '$TASK_ROLE_NAME'." >&2
  echo "       Ensure your IAM user has iam:PutRolePolicy permission." >&2
  exit 1
}

log "  Done — '$SSM_POLICY_NAME' is in place on '$TASK_ROLE_NAME'"

# ── 6. Check whether exec is already enabled ─────────────────────────────────

EXEC_ENABLED=$(echo "$LATEST_DEF" | jq -r '.containerProperties.enableExecuteCommand // false')

if [[ "$EXEC_ENABLED" == "true" ]]; then
  log "Latest revision ($CURRENT_ARN) already has enableExecuteCommand: true."
  log "IAM policy was refreshed above. No new revision needed."
  NEW_DEF_ARN="$CURRENT_ARN"
  NEW_REVISION="$CURRENT_REVISION"
else
  # ── 7. Build new containerProperties with enableExecuteCommand: true ─────────

  log "Building updated containerProperties with enableExecuteCommand: true..."

  NEW_CONTAINER_PROPS=$(echo "$LATEST_DEF" | \
    jq '.containerProperties.enableExecuteCommand = true | .containerProperties')

  # ── 8. Re-register the job definition ─────────────────────────────────────────

  log "Registering new revision of '$JOB_DEFINITION'..."

  # Collect optional top-level fields into a JSON object so we can pass them
  # only when present. Start with the required fields.
  REGISTER_ARGS=(
    --job-definition-name "$JOB_DEFINITION"
    --type "$(echo "$LATEST_DEF" | jq -r '.type')"
    --container-properties "$NEW_CONTAINER_PROPS"
    --region "$REGION"
  )

  # platformCapabilities (array — convert to JSON string for CLI)
  if echo "$LATEST_DEF" | jq -e '.platformCapabilities | length > 0' &>/dev/null; then
    PLATFORM_CAPS=$(echo "$LATEST_DEF" | jq -c '.platformCapabilities')
    REGISTER_ARGS+=(--platform-capabilities "$PLATFORM_CAPS")
  fi

  # parameters (object)
  if echo "$LATEST_DEF" | jq -e '.parameters | length > 0' &>/dev/null; then
    PARAMS=$(echo "$LATEST_DEF" | jq -c '.parameters')
    REGISTER_ARGS+=(--parameters "$PARAMS")
  fi

  # retryStrategy
  if echo "$LATEST_DEF" | jq -e '.retryStrategy' &>/dev/null; then
    RETRY=$(echo "$LATEST_DEF" | jq -c '.retryStrategy')
    REGISTER_ARGS+=(--retry-strategy "$RETRY")
  fi

  # timeout
  if echo "$LATEST_DEF" | jq -e '.timeout' &>/dev/null; then
    TIMEOUT_VAL=$(echo "$LATEST_DEF" | jq -c '.timeout')
    REGISTER_ARGS+=(--timeout "$TIMEOUT_VAL")
  fi

  # propagateTags
  if echo "$LATEST_DEF" | jq -e '.propagateTags == true' &>/dev/null; then
    REGISTER_ARGS+=(--propagate-tags)
  fi

  # tags (object)
  if echo "$LATEST_DEF" | jq -e '.tags | length > 0' &>/dev/null; then
    TAGS=$(echo "$LATEST_DEF" | jq -c '.tags')
    REGISTER_ARGS+=(--tags "$TAGS")
  fi

  # schedulingPriority
  if echo "$LATEST_DEF" | jq -e '.schedulingPriority' &>/dev/null; then
    SCHED=$(echo "$LATEST_DEF" | jq -r '.schedulingPriority')
    REGISTER_ARGS+=(--scheduling-priority "$SCHED")
  fi

  NEW_REG=$(aws batch register-job-definition "${REGISTER_ARGS[@]}" --output json 2>&1) || {
    echo "ERROR: register-job-definition failed:" >&2
    echo "$NEW_REG" >&2
    exit 1
  }

  NEW_DEF_ARN=$(echo "$NEW_REG" | jq -r '.jobDefinitionArn')
  NEW_REVISION=$(echo "$NEW_REG" | jq -r '.revision')
  log "  Registered: $NEW_DEF_ARN (revision $NEW_REVISION)"
fi

# ── 9. Print next steps ───────────────────────────────────────────────────────

# Derive short name:revision for the submit command
JOB_DEF_REF="${JOB_DEFINITION}:${NEW_REVISION}"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Troubleshooting enablement complete"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Job definition : $NEW_DEF_ARN"
echo "  Task role      : $TASK_ROLE_NAME"
echo "  SSM policy     : $SSM_POLICY_NAME  ✓ in place"
echo ""
echo "  !! The currently running task (if any) CANNOT be retrofitted."
echo "  !! enableExecuteCommand is applied only at task launch."
echo "  !! You must submit a fresh job using the new revision below."
echo ""
echo "──────────────────────────────────────────────────────────────────────────"
echo "  Step 1 — Submit a fresh job"
echo "──────────────────────────────────────────────────────────────────────────"
echo ""
echo "  JOB_ID=\$(aws batch submit-job \\"
echo "    --job-name troubleshooting-run \\"
echo "    --job-queue ${JOB_QUEUE} \\"
echo "    --job-definition ${JOB_DEF_REF} \\"
echo "    --region ${REGION} \\"
echo "    --query 'jobId' --output text)"
echo "  echo \"Job ID: \$JOB_ID\""
echo ""
echo "  # Wait for RUNNING:"
echo "  aws batch describe-jobs --jobs \$JOB_ID --region ${REGION} \\"
echo "    --query 'jobs[0].{status:status,taskArn:container.taskArn}'"
echo ""
echo "──────────────────────────────────────────────────────────────────────────"
echo "  Step 2 — Get cluster + task ID"
echo "──────────────────────────────────────────────────────────────────────────"
echo ""
echo "  CLUSTER=\$(aws batch describe-compute-environments \\"
echo "    --compute-environments \$(aws batch describe-job-queues \\"
echo "      --job-queues ${JOB_QUEUE} --region ${REGION} \\"
echo "      --query 'jobQueues[0].computeEnvironmentOrder[0].computeEnvironment' \\"
echo "      --output text) \\"
echo "    --region ${REGION} \\"
echo "    --query 'computeEnvironments[0].ecsClusterArn' --output text \\"
echo "    | sed 's|.*/cluster/||')"
echo ""
echo "  TASK_ID=\$(aws batch describe-jobs --jobs \$JOB_ID --region ${REGION} \\"
echo "    --query 'jobs[0].container.taskArn' --output text | awk -F/ '{print \$NF}')"
echo ""
echo "──────────────────────────────────────────────────────────────────────────"
echo "  Step 3 — Exec into the container"
echo "──────────────────────────────────────────────────────────────────────────"
echo ""
echo "  aws ecs execute-command \\"
echo "    --cluster \$CLUSTER \\"
echo "    --task \$TASK_ID \\"
echo "    --container default \\"
echo "    --interactive \\"
echo "    --command \"/bin/bash\" \\"
echo "    --region ${REGION}"
echo ""
echo "──────────────────────────────────────────────────────────────────────────"
echo "  Step 4 — Run falconctl inside the container"
echo "──────────────────────────────────────────────────────────────────────────"
echo ""
echo "  # Alpine/musl workaround — invoke via sensor's own glibc dynamic linker:"
echo "  /opt/CrowdStrike/rootfs/lib64/ld-linux-x86-64.so.2 \\"
echo "    --library-path /opt/CrowdStrike/rootfs/lib64:/opt/CrowdStrike/rootfs/usr/lib64 \\"
echo "    /opt/CrowdStrike/rootfs/usr/bin/falconctl -g --aid"
echo ""
echo "  # Expected output: aid=\"<32-char-hex>\""
echo "  # Empty AID means sensor hasn't registered — check network (NETWORK_VALIDATION_GUIDE.md)"
echo ""
echo "  # For a non-interactive one-shot exec:"
echo "  aws ecs execute-command \\"
echo "    --cluster \$CLUSTER --task \$TASK_ID --container default --interactive \\"
echo "    --command \"/opt/CrowdStrike/rootfs/lib64/ld-linux-x86-64.so.2 --library-path /opt/CrowdStrike/rootfs/lib64:/opt/CrowdStrike/rootfs/usr/lib64 /opt/CrowdStrike/rootfs/usr/bin/falconctl -g --aid\" \\"
echo "    --region ${REGION}"
echo ""
echo "══════════════════════════════════════════════════════════════════════════="
