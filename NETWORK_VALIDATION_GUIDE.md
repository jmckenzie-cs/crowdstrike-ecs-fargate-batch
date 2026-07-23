# Falcon Sensor Network Validation Guide
## AWS Batch + ECS Fargate Deployment

**Environment validated:** AWS Account 597047870845, us-east-1, Falcon Cloud us-2
**Sensor version:** 7.39.0-7802
**Validated:** 2026-07-23

---

## Overview

This guide covers network connectivity validation for a CrowdStrike Falcon sensor deployed
via the `falconutil` image-patching approach on AWS Batch + ECS Fargate. All tests are run
from **inside the running container** using `aws ecs execute-command`.

---

## Prerequisites

### 1. ECS Exec must be enabled on the job definition

The job definition's `containerProperties` must include:

```json
"enableExecuteCommand": true
```

This is NOT the default for AWS Batch. If omitted, all `execute-command` calls will fail
with `ExecuteCommandError: Execute command failed`.

### 2. IAM task role must have SSM permissions

The role used as both `jobRoleArn` and `executionRoleArn` needs this inline policy:

```json
{
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
}
```

Without this, the exec session silently fails to establish.

### 3. Session Manager plugin must be installed locally

```bash
brew install --cask session-manager-plugin   # macOS
# or: use AWS CloudShell (plugin pre-installed)
```

---

## How to Exec Into the Container

### Get the ECS Task ID from the Batch Job

```bash
aws batch describe-jobs --jobs <JOB_ID> --region us-east-1 \
  --query 'jobs[0].container.taskArn' --output text
# arn:aws:ecs:us-east-1:597047870845:task/<CLUSTER>/<TASK_ID>
```

### Get the ECS Cluster Name

```bash
aws batch describe-compute-environments \
  --compute-environments cs-fargate-ce \
  --query 'computeEnvironments[0].ecsClusterArn' --output text --region us-east-1
```

### Open an interactive shell

```bash
aws ecs execute-command \
  --cluster <CLUSTER_NAME> \
  --task <TASK_ID> \
  --container default \
  --interactive \
  --command "/bin/bash" \
  --region us-east-1
```

> **Note:** `--container default` is the ECS container name AWS Batch assigns when no
> explicit name is set in `containerProperties`. This is separate from `CS_CONTAINER`,
> which is a Falcon-internal env var.

---

## Network Validation Tests

Run each block from within the container (via `execute-command`) or chain them in a
single `/bin/sh -c '...'` invocation.

### Validated environment

| Field | Value |
|---|---|
| Hostname | `ip-172-31-86-137.ec2.internal` |
| Container IP | `172.31.86.137` (VPC private) |
| Outbound public IP | `174.129.112.174` (Fargate ENI, assigned via `assignPublicIp: ENABLED`) |
| DNS resolver | `172.31.0.2` (AWS VPC resolver, standard for all VPCs) |

---

### Test 1 — DNS Resolution

**What it proves:** The container can resolve CrowdStrike cloud hostnames. Failure here
means a DNS misconfiguration or that the container has no path to the VPC resolver.

```bash
for host in ts01-b.cloudsink.net lfodown01-b.cloudsink.net api.us-2.crowdstrike.com; do
  result=$(nslookup "$host" 2>&1 | grep "Address" | grep -v "#53")
  echo "$host -> $result"
done
```

**Validated output (us-2):**

```
ts01-b.cloudsink.net ->
  Address: 54.183.142.105
  Address: 54.183.140.32
  Address: 2600:1f1c:8aa:1002:1:2:3:40d   (IPv6)
  Address: 2600:1f1c:8aa:1001:1:2:3:40d   (IPv6)

lfodown01-b.cloudsink.net ->
  Address: 54.67.108.17
  Address: 54.241.183.232
  Address: 2600:1f1c:8aa:1001:1:2:3:405   (IPv6)
  Address: 2600:1f1c:8aa:1002:1:2:3:405   (IPv6)

api.us-2.crowdstrike.com ->
  Address: 50.112.127.55
  Address: 50.112.127.4
  Address: 50.112.111.36
```

**What to check if DNS fails:**
- VPC must have `enableDnsSupport: true` and `enableDnsHostnames: true`
- Security group must allow **outbound UDP/TCP port 53** to `172.31.0.2`
- If using custom DNS (Route53 Resolver rules), confirm CrowdStrike domains are not
  forwarded to a resolver with no internet path

---

### Test 2 — TCP 443 Reachability

**What it proves:** The container can complete a TCP handshake and TLS negotiation to
CrowdStrike's cloud on port 443. This is the actual channel the sensor uses. DNS
resolution passing but this test failing indicates a firewall or security group issue.

```bash
for host in ts01-b.cloudsink.net lfodown01-b.cloudsink.net api.us-2.crowdstrike.com; do
  result=$(curl -s -o /dev/null -w "%{http_code} connect=%{time_connect}s" \
    --connect-timeout 5 --max-time 10 "https://$host")
  echo "$host:443 -> $result"
done
```

**Validated output (us-2):**

```
ts01-b.cloudsink.net:443      -> 200  connect=0.074s   ✓ PASS
lfodown01-b.cloudsink.net:443 -> 200  connect=0.076s   ✓ PASS
api.us-2.crowdstrike.com:443  -> 404  connect=0.066s   ✓ PASS (404 = TLS succeeded, no resource at /)
```

**Interpreting curl HTTP codes:**

| Code | Meaning | Action |
|---|---|---|
| `200` | Full success | Pass |
| `404` | TLS + TCP succeeded; no resource at `/` (expected for API root) | Pass |
| `403` | TLS succeeded; auth required at that endpoint | Pass (connectivity is fine) |
| `000` | Connection failed before HTTP | Fail — firewall or DNS issue |
| `curl: SSL` error | TCP connected, TLS failed | Possible TLS inspection proxy |

**What to check if TCP 443 fails (`000`):**
- Security group **outbound rules** must allow TCP 443 to `0.0.0.0/0`
- For **private subnets**: a NAT Gateway must be present; `assignPublicIp` can be `DISABLED`
- For **public subnets**: `assignPublicIp: ENABLED` required (no NAT needed)
- Check for network ACLs blocking outbound 443 or inbound ephemeral ports (1024–65535)
- If behind a TLS-inspecting proxy, ensure CrowdStrike domains are in the bypass list

---

### Test 3 — Outbound Public IP

**What it proves:** Confirms what IP the sensor appears to originate from. Useful for
customers who need to whitelist CrowdStrike traffic at a perimeter firewall.

```bash
curl -s --connect-timeout 5 https://checkip.amazonaws.com
```

**Validated output:**
```
174.129.112.174
```

This is the Fargate task's public ENI IP (assigned by `assignPublicIp: ENABLED`). In
production environments using NAT Gateways, this will be the NAT Gateway's Elastic IP
instead, and will be consistent across all containers in the subnet.

---

## Endpoint Reference (Falcon Cloud us-2)

| Endpoint | Port | Purpose | DNS Resolves? | TCP 443? |
|---|---|---|---|---|
| `ts01-b.cloudsink.net` | 443 | Primary sensor telemetry | ✓ | ✓ 200 |
| `lfodown01-b.cloudsink.net` | 443 | Large file / content downloads | ✓ | ✓ 200 |
| `lfodown02-b.cloudsink.net` | 443 | (us-1 only — NXDOMAIN on us-2) | ✗ NXDOMAIN | N/A |
| `api.us-2.crowdstrike.com` | 443 | Falcon API / console backend | ✓ | ✓ 404 |

> **Important:** `lfodown02-b.cloudsink.net` does not exist in the us-2 cloud.
> If you see DNS failure for this hostname, it is **expected and not a problem**.
> Do not include it in customer connectivity checklists for us-2 deployments.

---

## Sensor Registration Check

> **Alpine / musl libc caveat:** The Falcon sensor binaries are built for RHEL/glibc.
> Running them directly on Alpine will produce `no such file or directory` even though
> the files exist. You must invoke them via the sensor's own bundled dynamic linker.

```bash
LOADER="/opt/CrowdStrike/rootfs/lib64/ld-linux-x86-64.so.2"
LIBPATH="/opt/CrowdStrike/rootfs/lib64:/opt/CrowdStrike/rootfs/usr/lib64"
FALCONCTL="/opt/CrowdStrike/rootfs/usr/bin/falconctl"

$LOADER --library-path $LIBPATH $FALCONCTL -g --aid
```

**Healthy output:**
```
aid="c354950c4852416c99c0806327627233"
```

**Empty AID** (`aid=""`) means the sensor started but has not registered. Check:
1. TCP 443 to `ts01-b.cloudsink.net` (see Test 2 above)
2. Correct CID embedded in image: `docker inspect <patched-image> --format '{{json .Config.Env}}'` and confirm `FALCONCTL_OPTS=--cid=<your-cid>`
3. Wrong Falcon cloud — us-1 CID used with us-2 sensor build, or vice versa

---

## Common Failure Scenarios

### "No such file or directory" when running falconctl

The binary exists but Alpine's musl loader can't exec glibc binaries. Use the loader
workaround described in the Sensor Registration Check section above.

### execute-command hangs or returns `ExecuteCommandError`

1. Confirm `"enableExecuteCommand": true` is in the job definition
2. Confirm the SSM inline policy is attached to the task role
3. Fargate platform version must be `1.4.0` or `LATEST` — check with:
   ```bash
   aws ecs describe-tasks --cluster <cluster> --tasks <task> \
     --query 'tasks[0].platformVersion' --output text --region us-east-1
   ```

### Sensor registers but disappears from console after a few minutes

The sensor lifecycle is tied to the container's process lifetime. When the Batch job
completes or the container exits, the sensor deregisters. For persistent sensor
visibility, the container workload must run continuously (e.g., the `while true; sleep 30`
loop in this test image).

### Container can reach ts01 but not lfodown01

Outbound to lfodown is needed for streaming prevention updates and content downloads.
Same firewall rules apply (TCP 443 outbound). Verify the security group doesn't have a
specific allow-list that covers `ts01-b` but not `lfodown01-b`.

---

## Quick Validation Checklist

```
[ ] ECS Exec: enableExecuteCommand: true in job definition
[ ] IAM: ssmmessages:* inline policy on task role
[ ] DNS: ts01-b.cloudsink.net resolves to IP (not NXDOMAIN)
[ ] DNS: lfodown01-b.cloudsink.net resolves to IP
[ ] TCP: ts01-b.cloudsink.net:443 returns curl code 200 (not 000)
[ ] TCP: lfodown01-b.cloudsink.net:443 returns curl code 200 (not 000)
[ ] TCP: api.us-2.crowdstrike.com:443 returns curl code 200 or 404 (not 000)
[ ] Sensor: falconctl -g --aid returns a 32-char hex AID (not empty)
[ ] Console: host appears in Falcon > Host Management within 2 min of RUNNING state
```
