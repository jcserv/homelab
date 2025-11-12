#!/bin/bash
#
# beszel-setup-universal-auth.sh - Setup beszel agents with universal token
#
# This script automates the setup of beszel agents using universal token authentication.
# It will fetch the public key from the hub and use the universal token to create
# sealed secrets for all agent nodes.
#
# Prerequisites:
# - kubectl, kubeseal, curl, jq installed
# - Access to beszel hub
# - Universal token from hub (/settings/tokens)
#
# Usage:
#   BESZEL_EMAIL="your@email.com" \
#   BESZEL_PASSWORD="yourpassword" \
#   UNIVERSAL_TOKEN="your-universal-token" \
#   ./scripts/beszel-setup-universal-auth.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="default"
CHART="beszel"
HUB_URL="${BESZEL_HUB_URL:-http://localhost:8090}"
NODES=("pi4-01" "pi4-02" "pi5-01")

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Beszel Universal Auth Setup${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Check for required tools
for tool in kubectl kubeseal curl jq; do
    if ! command -v $tool &> /dev/null; then
        echo -e "${RED}Error: $tool is not installed${NC}"
        exit 1
    fi
done

# Check for required environment variables
if [ -z "$BESZEL_EMAIL" ] || [ -z "$BESZEL_PASSWORD" ]; then
    echo -e "${RED}Error: BESZEL_EMAIL and BESZEL_PASSWORD are required${NC}"
    echo ""
    echo "Usage:"
    echo "  export BESZEL_EMAIL='your@email.com'"
    echo "  export BESZEL_PASSWORD='yourpassword'"
    echo "  export UNIVERSAL_TOKEN='your-universal-token'  # from /settings/tokens"
    echo "  export BESZEL_HUB_URL='http://localhost:8090'  # optional, defaults to localhost"
    echo "  $0"
    exit 1
fi

if [ -z "$UNIVERSAL_TOKEN" ]; then
    echo -e "${RED}Error: UNIVERSAL_TOKEN is required${NC}"
    echo ""
    echo "Get your universal token from the beszel hub:"
    echo "  1. Access the hub UI (e.g., https://beszel.home)"
    echo "  2. Go to Settings > Tokens (/settings/tokens)"
    echo "  3. Copy the universal token"
    echo "  4. Run: export UNIVERSAL_TOKEN='your-token'"
    exit 1
fi

echo -e "${YELLOW}Authenticating with beszel hub...${NC}"
AUTH_RESPONSE=$(curl -s -X POST "${HUB_URL}/api/collections/users/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"${BESZEL_EMAIL}\",\"password\":\"${BESZEL_PASSWORD}\"}")

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token')

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo -e "${RED}Authentication failed. Check your credentials.${NC}"
    echo "Response: $AUTH_RESPONSE"
    exit 1
fi

echo -e "${GREEN}✓ Authenticated${NC}"
echo ""

# Get public key from hub
echo -e "${YELLOW}Fetching public key from hub...${NC}"
KEY_RESPONSE=$(curl -s "${HUB_URL}/api/beszel/getkey" -H "Authorization: ${TOKEN}")
PUBLIC_KEY=$(echo "$KEY_RESPONSE" | jq -r '.key')

if [ "$PUBLIC_KEY" == "null" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Failed to get public key from hub${NC}"
    echo "Response: $KEY_RESPONSE"
    exit 1
fi

echo -e "${GREEN}✓ Public key retrieved${NC}"
echo "  Key: ${PUBLIC_KEY:0:50}..."
echo ""

# Create sealed secrets directory
SEALED_DIR="charts/${CHART}/sealed-secrets"
mkdir -p "$SEALED_DIR"

# Generate sealed secrets
echo -e "${YELLOW}Generating sealed secrets...${NC}"
echo ""

for NODE in "${NODES[@]}"; do
    echo -e "${BLUE}Processing: ${NODE}${NC}"
    SECRET_NAME="beszel-agent-${NODE}-secrets"

    # Create secret and seal it
    kubectl create secret generic "${SECRET_NAME}" \
        --from-literal=KEY="${PUBLIC_KEY}" \
        --from-literal=TOKEN="${UNIVERSAL_TOKEN}" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | \
    kubeseal \
        --controller-namespace kube-system \
        --controller-name sealed-secrets \
        --format yaml \
        --namespace "${NAMESPACE}" \
        > "${SEALED_DIR}/${SECRET_NAME}-sealed.yaml"

    echo -e "  ${GREEN}✓ Sealed secret created${NC}"
done

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Sealed Secrets Generated!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "${YELLOW}Generated sealed secrets with:${NC}"
echo "  Universal Token: ${UNIVERSAL_TOKEN:0:20}..."
echo "  Public Key: ${PUBLIC_KEY:0:50}..."
echo ""

# Ask if user wants to apply immediately
read -p "Apply changes and restart agents now? (y/N) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${YELLOW}[1/4] Applying sealed secrets...${NC}"
    kubectl apply -f "${SEALED_DIR}/"
    echo -e "${GREEN}✓ Sealed secrets applied${NC}"
    echo ""

    echo -e "${YELLOW}[2/4] Deleting old secrets to force recreation...${NC}"
    kubectl delete secret beszel-agent-pi4-01-secrets beszel-agent-pi4-02-secrets beszel-agent-pi5-01-secrets 2>/dev/null || echo "No existing secrets found"
    sleep 3
    echo -e "${GREEN}✓ Old secrets removed${NC}"
    echo ""

    echo -e "${YELLOW}[3/4] Upgrading beszel helm chart...${NC}"
    helm upgrade --install beszel ./charts/beszel --namespace="${NAMESPACE}"
    echo -e "${GREEN}✓ Helm chart upgraded${NC}"
    echo ""

    echo -e "${YELLOW}[4/4] Waiting for agents to restart...${NC}"
    sleep 5
    kubectl wait --for=condition=ready pod -l component=agent --timeout=60s 2>/dev/null || true
    echo -e "${GREEN}✓ Agents restarted${NC}"
    echo ""

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "${YELLOW}Agent Status:${NC}"
    kubectl get pods -l component=agent
    echo ""
    echo -e "${YELLOW}Recent Logs:${NC}"
    kubectl logs -l component=agent --tail=3 --prefix=true 2>/dev/null | grep -E "WebSocket connected|WARN|ERROR" || echo "No connection logs yet"
    echo ""
    echo -e "${BLUE}Check beszel hub UI: https://beszel.home${NC}"
    echo ""
    echo -e "${YELLOW}To commit changes:${NC}"
    echo "  git add ${SEALED_DIR}/*.yaml"
    echo "  git commit -m \"chore: update beszel agent secrets\""
else
    echo ""
    echo -e "${YELLOW}Sealed secrets generated but not applied.${NC}"
    echo ""
    echo -e "${YELLOW}To apply manually:${NC}"
    echo ""
    echo "1. Apply the sealed secrets:"
    echo "   ${BLUE}kubectl apply -f ${SEALED_DIR}/${NC}"
    echo ""
    echo "2. Delete old secrets (if upgrading):"
    echo "   ${BLUE}kubectl delete secret beszel-agent-pi4-01-secrets beszel-agent-pi4-02-secrets beszel-agent-pi5-01-secrets${NC}"
    echo ""
    echo "3. Deploy/upgrade the beszel chart:"
    echo "   ${BLUE}helm upgrade --install beszel ./charts/beszel${NC}"
    echo ""
    echo "4. Monitor agent connection:"
    echo "   ${BLUE}kubectl logs -l component=agent --tail=20 -f${NC}"
    echo ""
    echo "5. Check beszel hub UI:"
    echo "   ${BLUE}https://beszel.home${NC}"
    echo ""
    echo "6. Commit changes:"
    echo "   ${BLUE}git add ${SEALED_DIR}/*.yaml${NC}"
    echo "   ${BLUE}git commit -m \"chore: update beszel agent secrets\"${NC}"
fi
echo ""
