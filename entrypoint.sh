#!/bin/bash
set -euo pipefail

echo "=== CS Batch Test Job Starting ==="
echo "Hostname: $(hostname)"
echo "Date: $(date -u)"
echo ""

COUNTER=0
while true; do
  COUNTER=$((COUNTER + 1))
  echo "[$(date -u +%H:%M:%S)] Iteration $COUNTER — workload running"
  sleep 30
done
