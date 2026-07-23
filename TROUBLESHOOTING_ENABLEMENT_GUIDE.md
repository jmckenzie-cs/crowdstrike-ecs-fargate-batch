# ECS Exec Troubleshooting Enablement Guide
## AWS Batch + ECS Fargate — Falcon Sensor Deployments

**Environment:** AWS Account <YOUR_AWS_ACCOUNT_ID>, us-east-1, Falcon Cloud us-2
**Validated:** 2026-07-23

---

## When to use this

You have a running AWS Batch + ECS Fargate workload with the Falcon sensor deployed via
the `falconutil` image-patching approach. You need to exec into the container to:

- Run `falconctl -g --aid` to confirm the sensor registered and get its Agent ID
- Run DNS or TCP connectivity checks to the Falcon cloud
- Interactively troubleshoot a sensor that appears in the Falcon console but is not
  generating detections

The standard `aws ecs execute-command` fails because either the job definition is missing
`enableExecuteCommand: true`, the task role is missing the `ssmmessages:*` inline policy,
or both.

---

## The running-task caveat — read this first

> **`enableExecuteCommand` is applied only at task launch.**

When Fargate starts a task, it injects the SSM agent if and only if the task was started
with `enableExecuteCommand: true`. A task already running without it **can never be
retrofitted** — there is no API to add exec capability to a live task.

This means:

1. Updating the IAM role alone is not enough.
2. Even registering a new job definition revision is not enough by itself.
3. You must **submit a fresh job** using the new revision for the changes to take effect.

The old running task can continue until it completes or you cancel it. The new task will
have exec enabled from the moment it enters RUNNING state.

---

## Option A — Run the script

`enable-troubleshooting.sh` handles both IAM and job definition in a single idempotent
invocation. It does **not** submit or cancel jobs — it only prepares the prerequisites and
prints the exact commands to run next.

### Usage

```bash
# Defaults match this environment:
./enable-troubleshooting.sh

# Override any parameter via env var:
JOB_DEFINITION=my-other-job \
JOB_QUEUE=my-other-queue \
REGION=us-west-2 \
SSM_POLICY_NAME=ECSExecSSMPermissions \
  ./enable-troubleshooting.sh
```

### Parameters

| Env var | Default | Description |
|---|---|---|
| `JOB_DEFINITION` | `cs-falcon-job` | Batch job definition name (without `:revision`) |
| `JOB_QUEUE` | `cs-fargate-queue` | Job queue — used only to print the submit command |
| `REGION` | `us-east-1` | AWS region |
| `SSM_POLICY_NAME` | `ECSExecSSMPermissions` | Name for the inline IAM policy |

### What the script does

1. **Preflight** — verifies `aws` and `jq` are in PATH; confirms caller identity.
2. **Fetch** — retrieves the latest `ACTIVE` revision of the job definition. Errors if none
   found.
3. **Guard rail** — exits if the definition uses `nodeProperties`, `ecsProperties`, or
   `eksProperties`. Only single-container `containerProperties` FARGATE definitions are
   supported.
4. **Derive role** — reads `containerProperties.jobRoleArn` and extracts the role name.
   Errors if absent (exec is impossible without a task role).
5. **IAM** — runs `put-role-policy` to attach the `ssmmessages:*` policy. Idempotent:
   overwrites safely if already present.
6. **Idempotency check** — if the latest revision already has `enableExecuteCommand: true`,
   skips re-registration and reports the existing ARN. The IAM step still runs to ensure
   the policy is current.
7. **Register** — builds new `containerProperties` with `enableExecuteCommand: true` and
   registers a new revision, preserving all other fields (`type`, `platformCapabilities`,
   `parameters`, `retryStrategy`, `timeout`, `propagateTags`, `tags`,
   `schedulingPriority`).
8. **Print** — outputs the exact `submit-job`, cluster/task-ID derivation, `execute-command`,
   and `falconctl` invocations to run next.

### Sample output (new revision needed)

```
[10:23:01] Preflight checks...
[10:23:01]   AWS account : <YOUR_AWS_ACCOUNT_ID>
[10:23:01]   Caller      : arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:user/<your-iam-user>
[10:23:01]   Region      : us-east-1
[10:23:02] Fetching latest ACTIVE revision of job definition 'cs-falcon-job'...
[10:23:02]   Found: arn:aws:batch:us-east-1:<YOUR_AWS_ACCOUNT_ID>:job-definition/cs-falcon-job:1 (revision 1)
[10:23:02]   Task role   : ecsTaskExecutionRole (arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/ecsTaskExecutionRole)
[10:23:02] Attaching inline policy 'ECSExecSSMPermissions' to role 'ecsTaskExecutionRole'...
[10:23:03]   Done — 'ECSExecSSMPermissions' is in place on 'ecsTaskExecutionRole'
[10:23:03] Building updated containerProperties with enableExecuteCommand: true...
[10:23:03] Registering new revision of 'cs-falcon-job'...
[10:23:04]   Registered: arn:aws:batch:us-east-1:<YOUR_AWS_ACCOUNT_ID>:job-definition/cs-falcon-job:2 (revision 2)

═══════════════════════════════════════════════════════════════════════════
  Troubleshooting enablement complete
═══════════════════════════════════════════════════════════════════════════

  Job definition : arn:aws:batch:.../cs-falcon-job:2
  Task role      : ecsTaskExecutionRole
  SSM policy     : ECSExecSSMPermissions  ✓ in place

  !! The currently running task (if any) CANNOT be retrofitted.
  ...
```

### Sample output (already enabled)

```
[10:31:17] Latest revision (arn:.../cs-falcon-job:2) already has enableExecuteCommand: true.
[10:31:17] IAM policy was refreshed above. No new revision needed.
```

---

## Option B — Manual steps

If you prefer to run the three operations yourself:

### Step 1 — Attach the SSM inline policy

```bash
aws iam put-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-name ECSExecSSMPermissions \
  --policy-document '{
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
```

This is idempotent — safe to run even if the policy already exists.

### Step 2 — Register a new job definition revision with enableExecuteCommand: true

Fetch the current revision and pipe it into a new registration:

```bash
# Fetch current definition
CURRENT=$(aws batch describe-job-definitions \
  --job-definition-name cs-falcon-job \
  --status ACTIVE \
  --region us-east-1 \
  --output json | jq '.jobDefinitions | sort_by(.revision) | last')

# Build updated containerProperties
NEW_CONTAINER_PROPS=$(echo "$CURRENT" | \
  jq '.containerProperties.enableExecuteCommand = true | .containerProperties')

# Register
aws batch register-job-definition \
  --job-definition-name cs-falcon-job \
  --type container \
  --platform-capabilities '["FARGATE"]' \
  --container-properties "$NEW_CONTAINER_PROPS" \
  --region us-east-1
```

Note the new revision number from the output (e.g., `:2`).

### Step 3 — Submit a fresh job using the new revision

```bash
JOB_ID=$(aws batch submit-job \
  --job-name troubleshooting-run \
  --job-queue cs-fargate-queue \
  --job-definition cs-falcon-job:2 \
  --region us-east-1 \
  --query 'jobId' --output text)

echo "Job ID: $JOB_ID"
```

---

## Verify

### Confirm enableExecuteCommand: true on the running task

Once the job reaches RUNNING state, describe the ECS task to confirm the flag was applied:

```bash
# Get cluster and task ID from the job
TASK_ARN=$(aws batch describe-jobs --jobs $JOB_ID --region us-east-1 \
  --query 'jobs[0].container.taskArn' --output text)
TASK_ID=$(echo "$TASK_ARN" | awk -F/ '{print $NF}')

CLUSTER=$(aws batch describe-compute-environments \
  --compute-environments cs-fargate-ce --region us-east-1 \
  --query 'computeEnvironments[0].ecsClusterArn' --output text \
  | sed 's|.*/cluster/||')

aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks "$TASK_ID" \
  --region us-east-1 \
  --query 'tasks[0].enableExecuteCommand'
# Expected: true
```

### Open an interactive shell

```bash
aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ID" \
  --container default \
  --interactive \
  --command "/bin/bash" \
  --region us-east-1
```

> **Note:** `--container default` is the ECS container name assigned by AWS Batch when no
> explicit name is set in `containerProperties`. This is separate from `CS_CONTAINER`, which
> is a Falcon-internal env var set by `falconutil`.

> **Session Manager plugin required:** You need `session-manager-plugin` installed locally.
> On macOS: `brew install --cask session-manager-plugin`. Alternatively, use AWS CloudShell,
> which has it pre-installed.

### Confirm sensor registration with falconctl

```bash
# Alpine / musl workaround — invoke via sensor's own glibc dynamic linker:
/opt/CrowdStrike/rootfs/lib64/ld-linux-x86-64.so.2 \
  --library-path /opt/CrowdStrike/rootfs/lib64:/opt/CrowdStrike/rootfs/usr/lib64 \
  /opt/CrowdStrike/rootfs/usr/bin/falconctl -g --aid
```

**Expected healthy output:**
```
aid="<agent-id>"
```

**Empty AID** (`aid=""`) means the sensor started but hasn't registered. Check network
connectivity — see [NETWORK_VALIDATION_GUIDE.md](NETWORK_VALIDATION_GUIDE.md) for DNS and
TCP 443 validation steps.

> **Why the loader workaround?** Falcon sensor binaries are compiled for RHEL/glibc. Alpine
> uses musl libc, which cannot exec glibc binaries. Running `falconctl` directly produces
> `no such file or directory` even though the binary is present. Invoking through the
> sensor's bundled dynamic linker (`ld-linux-x86-64.so.2`) bypasses this. This is only
> needed on Alpine-based workload images; RHEL/Ubuntu-based images can call `falconctl`
> directly.

### Run as a non-interactive one-shot

```bash
aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ID" \
  --container default \
  --interactive \
  --command "/opt/CrowdStrike/rootfs/lib64/ld-linux-x86-64.so.2 --library-path /opt/CrowdStrike/rootfs/lib64:/opt/CrowdStrike/rootfs/usr/lib64 /opt/CrowdStrike/rootfs/usr/bin/falconctl -g --aid" \
  --region us-east-1
```

---

## Cleanup

The inline SSM policy is removed automatically by `teardown.sh` (step 5):

```bash
aws iam delete-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-name ECSExecSSMPermissions
```

Job definition revisions registered by this script are also deregistered by `teardown.sh`
(step 1), which deregisters all ACTIVE revisions of `cs-falcon-job`.

---

## Quick checklist

```
[ ] Script run (or manual steps completed)
[ ] IAM: aws iam get-role-policy --role-name ecsTaskExecutionRole --policy-name ECSExecSSMPermissions → shows ssmmessages:* policy
[ ] Job definition: new revision registered with enableExecuteCommand: true
[ ] Fresh job submitted using new revision
[ ] ECS task describe-tasks → enableExecuteCommand: true
[ ] aws ecs execute-command connects (Session Manager plugin installed)
[ ] falconctl -g --aid returns 32-char hex AID (use glibc loader workaround on Alpine)
[ ] If AID empty: run network validation — see NETWORK_VALIDATION_GUIDE.md
```
