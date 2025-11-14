#!/bin/bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
SERVICE_ACCOUNT="github-actions"
NAMESPACE="gitops-system"
CLUSTER_NAME="homelab-k8s"

echo -e "${BLUE}=== GitHub Actions Kubeconfig Generator ===${NC}\n"

# Check if service account exists
if ! kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: ServiceAccount '$SERVICE_ACCOUNT' not found in namespace '$NAMESPACE'${NC}"
    echo -e "${YELLOW}Please apply the RBAC configuration first:${NC}"
    echo -e "  kubectl apply -f k8s/rbac/github-actions-serviceaccount.yaml"
    exit 1
fi

echo -e "${GREEN}✓${NC} ServiceAccount found: $SERVICE_ACCOUNT"

# Create a token for the service account
echo -e "\n${BLUE}Creating service account token...${NC}"

# Try modern kubectl create token command first (k8s 1.22+)
if TOKEN=$(kubectl create token "$SERVICE_ACCOUNT" -n "$NAMESPACE" --duration=8760h 2>/dev/null); then
    echo -e "${GREEN}✓${NC} Token created (valid for 1 year)"
else
    # Fallback: Create a Secret object for older kubectl/k8s versions
    echo -e "${YELLOW}Note: Using legacy Secret-based token (no expiration)${NC}"

    SECRET_NAME="${SERVICE_ACCOUNT}-token"

    # Create Secret if it doesn't exist
    if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $SERVICE_ACCOUNT
type: kubernetes.io/service-account-token
EOF
        echo -e "${GREEN}✓${NC} Secret created"

        # Wait for token to be populated
        echo -e "${BLUE}Waiting for token to be generated...${NC}"
        for i in {1..10}; do
            TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
            if [ -n "$TOKEN" ]; then
                break
            fi
            sleep 1
        done

        if [ -z "$TOKEN" ]; then
            echo -e "${RED}Error: Token was not generated${NC}"
            exit 1
        fi
    else
        # Secret already exists, get the token
        TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
    fi

    echo -e "${GREEN}✓${NC} Token retrieved from Secret"
fi

# Get the cluster CA certificate
echo -e "\n${BLUE}Extracting cluster CA certificate...${NC}"
CA_CERT=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

if [ -z "$CA_CERT" ]; then
    # If CA is not embedded, try to read from file
    CA_FILE=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}')
    if [ -n "$CA_FILE" ]; then
        CA_CERT=$(base64 < "$CA_FILE" | tr -d '\n')
    else
        echo -e "${RED}Error: Could not extract CA certificate${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓${NC} CA certificate extracted"

# Get the cluster server URL
echo -e "\n${BLUE}Getting cluster server URL...${NC}"
SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')

echo -e "${YELLOW}Current server URL: $SERVER${NC}"
echo -e "\n${YELLOW}⚠️  Important: You need to replace this with your Tailscale IP!${NC}"
echo -e "${YELLOW}Example: https://100.x.x.x:6443${NC}\n"

read -p "Enter your Kubernetes API server Tailscale URL (or press Enter to use current): " TAILSCALE_SERVER

if [ -n "$TAILSCALE_SERVER" ]; then
    SERVER="$TAILSCALE_SERVER"
fi

echo -e "${GREEN}✓${NC} Using server: $SERVER"

# Generate the kubeconfig
echo -e "\n${BLUE}Generating kubeconfig...${NC}"

KUBECONFIG_CONTENT=$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $CLUSTER_NAME
  cluster:
    certificate-authority-data: $CA_CERT
    server: $SERVER
contexts:
- name: $SERVICE_ACCOUNT@$CLUSTER_NAME
  context:
    cluster: $CLUSTER_NAME
    namespace: default
    user: $SERVICE_ACCOUNT
current-context: $SERVICE_ACCOUNT@$CLUSTER_NAME
users:
- name: $SERVICE_ACCOUNT
  user:
    token: $TOKEN
EOF
)

# Encode in base64 for GitHub secrets
KUBECONFIG_BASE64=$(echo "$KUBECONFIG_CONTENT" | base64)

echo -e "${GREEN}✓${NC} Kubeconfig generated"

# Output the results
echo -e "\n${GREEN}=== Success! ===${NC}\n"

echo -e "${BLUE}Add this to your GitHub repository secrets:${NC}\n"

echo -e "${YELLOW}Secret name:${NC} KUBE_CONFIG"
echo -e "${YELLOW}Secret value:${NC}"
echo "---"
echo "$KUBECONFIG_BASE64"
echo "---"

# Save to file for reference
OUTPUT_FILE="/tmp/github-actions-kubeconfig-$(date +%Y%m%d-%H%M%S).yaml"
echo "$KUBECONFIG_CONTENT" > "$OUTPUT_FILE"

echo -e "\n${GREEN}✓${NC} Kubeconfig also saved to: $OUTPUT_FILE"
echo -e "\n${YELLOW}Next steps:${NC}"
echo -e "  1. Copy the base64 value above"
echo -e "  2. Go to your GitHub repository → Settings → Secrets and variables → Actions"
echo -e "  3. Create a new secret named ${BLUE}KUBE_CONFIG${NC}"
echo -e "  4. Paste the base64 value"
echo -e "\n${YELLOW}Security notes:${NC}"
echo -e "  - Token is valid for 1 year (expires $(date -d '+1 year' '+%Y-%m-%d' 2>/dev/null || date -v+1y '+%Y-%m-%d' 2>/dev/null || echo 'in 1 year'))"
echo -e "  - Rotate the token before expiration"
echo -e "  - Keep the kubeconfig file secure and delete it when done"
echo -e "  - Service account has limited RBAC permissions (ClusterRole: github-actions-deployer)"
