#!/bin/bash
#
# seal-secret.sh - Helper script to seal secrets for homelab-k8s
#
# Usage:
#   ./scripts/seal-secret.sh <chart-name> <secret-name> [namespace]
#
# Example:
#   kubectl create secret generic immich-secrets \
#     --from-literal=DB_PASSWORD='mypassword' \
#     --from-literal=JWT_SECRET='mysecret' \
#     --dry-run=client -o yaml | \
#     ./scripts/seal-secret.sh immich immich-secrets
#

set -e

CHART=$1
SECRET_NAME=$2
NAMESPACE=${3:-default}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ -z "$CHART" ] || [ -z "$SECRET_NAME" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 <chart-name> <secret-name> [namespace]"
    echo ""
    echo "Example:"
    echo "  kubectl create secret generic immich-secrets \\"
    echo "    --from-literal=DB_PASSWORD='mypassword' \\"
    echo "    --from-literal=JWT_SECRET='mysecret' \\"
    echo "    --dry-run=client -o yaml | \\"
    echo "    $0 immich immich-secrets"
    exit 1
fi

# Check if kubeseal is installed
if ! command -v kubeseal &> /dev/null; then
    echo -e "${RED}Error: kubeseal is not installed${NC}"
    echo ""
    echo "Install kubeseal:"
    echo "  # For ARM64 (Raspberry Pi)"
    echo "  wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/kubeseal-0.27.1-linux-arm64.tar.gz"
    echo "  tar xfz kubeseal-0.27.1-linux-arm64.tar.gz"
    echo "  sudo install -m 755 kubeseal /usr/local/bin/kubeseal"
    echo ""
    echo "  # For AMD64 (x86_64)"
    echo "  wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/kubeseal-0.27.1-linux-amd64.tar.gz"
    echo "  tar xfz kubeseal-0.27.1-linux-amd64.tar.gz"
    echo "  sudo install -m 755 kubeseal /usr/local/bin/kubeseal"
    exit 1
fi

# Check if sealed-secrets controller is running
if ! kubectl get deployment sealed-secrets -n kube-system &> /dev/null; then
    echo -e "${YELLOW}Warning: sealed-secrets controller may not be running in kube-system namespace${NC}"
    echo "Install with: helm install sealed-secrets ./charts/sealed-secrets --namespace kube-system"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create chart sealed-secrets directory if it doesn't exist
SEALED_DIR="charts/${CHART}/sealed-secrets"
if [ ! -d "$SEALED_DIR" ]; then
    echo -e "${YELLOW}Creating directory: ${SEALED_DIR}${NC}"
    mkdir -p "$SEALED_DIR"
fi

OUTPUT_FILE="${SEALED_DIR}/${SECRET_NAME}-sealed.yaml"

echo -e "${GREEN}Sealing secret...${NC}"
echo "  Chart: $CHART"
echo "  Secret: $SECRET_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Output: $OUTPUT_FILE"
echo ""

# Read from stdin and seal
cat | kubeseal \
    --controller-namespace kube-system \
    --controller-name sealed-secrets \
    --format yaml \
    --namespace "$NAMESPACE" \
    > "$OUTPUT_FILE"

echo -e "${GREEN}✓ Sealed secret created successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review the sealed secret: cat $OUTPUT_FILE"
echo "  2. Apply to cluster: kubectl apply -f $OUTPUT_FILE"
echo "  3. Commit to git: git add $OUTPUT_FILE && git commit -m \"Add sealed secret for ${CHART}\""
echo ""
echo "The sealed secret is safe to commit to public repositories!"
