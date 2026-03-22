#!/bin/bash
# pihole-check.sh — Detect and fix false DNS blocks caused by cached upstream failures
# When Pi-hole caches a transient NXDOMAIN as EXTERNAL_BLOCKED_NXRA, legitimate
# domains get blocked. This script detects that and triggers a DNS reload on
# affected pods to clear the bad cache entries.

set -euo pipefail

PIHOLE_LB="10.2.1.202"
PIHOLE_NAMESPACE="default"
PIHOLE_PODS=("pihole-0" "pihole-1" "pihole-2" "pihole-3")

TEST_DOMAINS=(
  "www.youtube.com"
  "www.google.com"
  "github.com"
  "www.reddit.com"
  "www.amazon.com"
)

BLOCKED_RESPONSES=("0.0.0.0" "::" "")

flagged_domains=()
fixed_pods=()

echo "=== Pi-hole False Block Check ==="
echo "Querying Pi-hole LB at $PIHOLE_LB..."
echo ""

# Step 1: Check each domain against the LoadBalancer
for domain in "${TEST_DOMAINS[@]}"; do
  result=$(dig @"$PIHOLE_LB" "$domain" +short 2>/dev/null | head -1)

  if [[ -z "$result" || "$result" == "0.0.0.0" || "$result" == "::" ]]; then
    echo "[BLOCKED] $domain -> ${result:-(empty)}"
    flagged_domains+=("$domain")
  else
    echo "[OK]      $domain -> $result"
  fi
done

echo ""

if [[ ${#flagged_domains[@]} -eq 0 ]]; then
  echo "All clear — no false blocks detected."
  exit 0
fi

echo "Found ${#flagged_domains[@]} potentially false-blocked domain(s). Checking pods..."
echo ""

# Step 2: Identify which pod(s) have the bad cache and fix them
for pod in "${PIHOLE_PODS[@]}"; do
  pod_needs_fix=false

  for domain in "${flagged_domains[@]}"; do
    # Query the individual pod's DNS directly
    pod_ip=$(kubectl get pod "$pod" -n "$PIHOLE_NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [[ -z "$pod_ip" ]]; then
      echo "  [$pod] Could not get pod IP, skipping"
      continue 2
    fi

    pod_result=$(dig @"$pod_ip" "$domain" +short 2>/dev/null | head -1)
    if [[ -z "$pod_result" || "$pod_result" == "0.0.0.0" || "$pod_result" == "::" ]]; then
      echo "  [$pod] FALSE BLOCK: $domain -> ${pod_result:-(empty)}"
      pod_needs_fix=true
    fi
  done

  if $pod_needs_fix; then
    echo "  [$pod] Reloading DNS..."
    kubectl exec "$pod" -n "$PIHOLE_NAMESPACE" -- pihole dns reload 2>/dev/null \
      || kubectl exec "$pod" -n "$PIHOLE_NAMESPACE" -- pihole reloaddns 2>/dev/null \
      || echo "  [$pod] WARNING: reload command failed"
    fixed_pods+=("$pod")
  fi
done

echo ""

# Step 3: Re-verify after fix
if [[ ${#fixed_pods[@]} -gt 0 ]]; then
  echo "Reloaded DNS on: ${fixed_pods[*]}"
  echo "Waiting 3 seconds for DNS to settle..."
  sleep 3
  echo ""
  echo "=== Re-verification ==="

  all_clear=true
  for domain in "${flagged_domains[@]}"; do
    result=$(dig @"$PIHOLE_LB" "$domain" +short 2>/dev/null | head -1)
    if [[ -z "$result" || "$result" == "0.0.0.0" || "$result" == "::" ]]; then
      echo "[STILL BLOCKED] $domain -> ${result:-(empty)}"
      all_clear=false
    else
      echo "[FIXED]          $domain -> $result"
    fi
  done

  echo ""
  if $all_clear; then
    echo "All flagged domains now resolving correctly."
  else
    echo "WARNING: Some domains are still blocked. Manual investigation needed."
    exit 1
  fi
else
  echo "No individual pods found with bad cache — the block may be from gravity/blocklists."
  echo "Check Pi-hole admin for intentional blocks on: ${flagged_domains[*]}"
  exit 1
fi
