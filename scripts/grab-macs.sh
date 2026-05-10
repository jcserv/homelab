#!/usr/bin/env bash
# Grab MAC + IP for cluster nodes + NAS so DHCP reservations can be added on
# the new router. Run while on the OLD wifi (cluster reachable on 10.2.1.x).
# Output is ready to paste into a router's static reservation UI.
set -euo pipefail

HOSTS=(
  "pi4-01:10.2.1.54"
  "pi4-02:10.2.1.160"
  "pi5-01:10.2.1.28"
  "pi5-02:10.2.1.156"
  "nas:10.2.1.147"
)

printf "%-10s %-15s %-20s %s\n" "HOST" "IP" "MAC" "IFACE"
printf "%-10s %-15s %-20s %s\n" "----" "--" "---" "-----"

for entry in "${HOSTS[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"

  # SSH alias preferred (~/.ssh/config), fall back to user@ip.
  if ssh -o ConnectTimeout=3 -o BatchMode=yes "$name" true 2>/dev/null; then
    target="$name"
  else
    target="$ip"
  fi

  result=$(ssh -o ConnectTimeout=5 "$target" "ip -o link show | awk -F': ' '\$2 !~ /^(lo|docker|cni|veth|flannel|tailscale|cilium|kube)/ {print \$2, \$0}' | head -1" 2>/dev/null || echo "")

  if [[ -z "$result" ]]; then
    printf "%-10s %-15s %-20s %s\n" "$name" "$ip" "UNREACHABLE" "-"
    continue
  fi

  iface=$(echo "$result" | awk '{print $1}')
  mac=$(echo "$result" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)

  printf "%-10s %-15s %-20s %s\n" "$name" "$ip" "$mac" "$iface"
done
