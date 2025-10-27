#!/bin/bash
# Script to add a new service DNS entry to Pi-hole
# Usage: ./scripts/add-service-dns.sh <service-name>
# Example: ./scripts/add-service-dns.sh myapp

set -e

SERVICE_NAME=$1

if [ -z "$SERVICE_NAME" ]; then
  echo "Usage: $0 <service-name>"
  echo "Example: $0 myapp"
  echo ""
  echo "This will add $SERVICE_NAME.home pointing to 10.0.0.200 in Pi-hole DNS"
  exit 1
fi

echo "Adding $SERVICE_NAME.home to Pi-hole DNS..."
echo ""

# Update all three Pi-hole pods
SUCCESS_COUNT=0
for pod in pihole-0 pihole-1 pihole-2; do
  echo "  Updating $pod..."
  if kubectl exec $pod -- sh -c "
    sed -i 's/\"10.0.0.200 dozzle.home\"/\"10.0.0.200 dozzle.home\",\n    \"10.0.0.200 $SERVICE_NAME.home\"/' /etc/pihole/pihole.toml
    pihole reloaddns
  " 2>&1 | grep -v "readonly variable" > /dev/null; then
    echo "    ✓ $pod updated successfully"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "    ✗ Failed to update $pod"
  fi
done

echo ""

if [ $SUCCESS_COUNT -eq 0 ]; then
  echo "❌ Failed to update any Pi-hole pods"
  exit 1
fi

echo "Waiting for DNS propagation..."
sleep 3

echo ""
echo "Testing DNS resolution..."
if host $SERVICE_NAME.home 10.0.0.202 > /dev/null 2>&1; then
  echo "✓ DNS resolution successful:"
  host $SERVICE_NAME.home 10.0.0.202
else
  echo "⚠️  DNS resolution failed. You may need to wait a bit longer or check Pi-hole logs."
  exit 1
fi

echo ""
echo "✅ Done! You can now access your service at https://$SERVICE_NAME.home"
echo ""
echo "Next steps:"
echo "  1. Make sure your service has an ingress configured"
echo "  2. Deploy your service: helm upgrade --install $SERVICE_NAME ./charts/$SERVICE_NAME"
echo "  3. Verify ingress: kubectl get ingress $SERVICE_NAME"
