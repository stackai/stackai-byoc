#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SOPS_DIR="${REPO_ROOT}/sops"

echo -e "${BLUE}🔐 SOPS Secrets Recreation Script${NC}"
echo -e "${BLUE}==================================${NC}"
echo
echo "This script helps recreate encrypted secrets after SOPS bootstrap."
echo "It will create:"
echo "  - ACR (Azure Container Registry) secret"
echo "  - Stackend license secret"
echo "Both will be encrypted with the current SOPS configuration."
echo

# Check prerequisites
echo -e "${BLUE}📋 Checking prerequisites...${NC}"

if ! command -v sops &> /dev/null; then
    echo -e "${RED}❌ SOPS not found. Please install it first:${NC}"
    echo "   brew install sops"
    exit 1
fi

if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
    echo -e "${RED}❌ SOPS_AGE_KEY_FILE not set${NC}"
    echo "Please set: export SOPS_AGE_KEY_FILE='${SOPS_DIR}/key.age'"
    exit 1
fi

if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
    echo -e "${RED}❌ SOPS key file not found: $SOPS_AGE_KEY_FILE${NC}"
    exit 1
fi

if [[ ! -f "${REPO_ROOT}/.sops.yaml" ]]; then
    echo -e "${RED}❌ .sops.yaml not found. Please run bootstrap-sops.sh first.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites met${NC}"

# Function to create ACR secret
create_acr_secret() {
    echo -e "\n${BLUE}🔑 Creating ACR (Azure Container Registry) Secret...${NC}"
    
    echo "Please provide your Azure Container Registry credentials:"
    read -p "ACR Registry URL [stackai.azurecr.io]: " ACR_REGISTRY
    ACR_REGISTRY=${ACR_REGISTRY:-stackai.azurecr.io}
    read -p "ACR Username: " ACR_USERNAME
    read -s -p "ACR Password: " ACR_PASSWORD
    echo
    
    if [[ -z "$ACR_REGISTRY" || -z "$ACR_USERNAME" || -z "$ACR_PASSWORD" ]]; then
        echo -e "${RED}❌ All ACR fields are required${NC}"
        return 1
    fi
    
    # Create dockerconfigjson
    DOCKER_CONFIG_JSON=$(cat << EOF
{
  "auths": {
    "${ACR_REGISTRY}": {
      "username": "${ACR_USERNAME}",
      "password": "${ACR_PASSWORD}"
    }
  }
}
EOF
)
    
    # Base64 encode the docker config
    DOCKER_CONFIG_B64=$(echo -n "$DOCKER_CONFIG_JSON" | base64 | tr -d '\n')
    
    # Create unencrypted secret
    cat > "${REPO_ROOT}/acr-secret.temp.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: acr-secret
  namespace: flux-system
type: kubernetes.io/dockerconfigjson
data:
  # This is a full dockerconfigjson:
  # {"auths":{"${ACR_REGISTRY}":{"username":"${ACR_USERNAME}","password":"[REDACTED]"}}}
  # cat acr.credentials.file | base64
  .dockerconfigjson: ${DOCKER_CONFIG_B64}
EOF
    
    # Encrypt the secret
    sops --encrypt "${REPO_ROOT}/acr-secret.temp.yaml" > "${REPO_ROOT}/components/kustomizations/configuration-setup/VERSION/base/acr-secret.enc.yaml"
    
    # Clean up
    rm "${REPO_ROOT}/acr-secret.temp.yaml"
    
    echo -e "${GREEN}✅ ACR secret created and encrypted${NC}"
}

# Function to create Stackend license secret
create_stackend_license_secret() {
    echo -e "\n${BLUE}🔑 Creating Stackend License Secret...${NC}"
    
    echo "Please provide your Stackend license key:"
    read -s -p "License Key: " LICENSE_KEY
    echo
    
    if [[ -z "$LICENSE_KEY" ]]; then
        echo -e "${RED}❌ License key is required${NC}"
        return 1
    fi
    
    # Base64 encode the license key
    LICENSE_B64=$(echo -n "$LICENSE_KEY" | base64 | tr -d '\n')
    
    # Create unencrypted secret
    cat > "${REPO_ROOT}/stackend-licence-secret.temp.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: stackend-licence-secret
  namespace: flux-system
type: Opaque
data:
  # Base64 encoded licence key
  # To encode your licence: echo -n "YOUR_LICENCE_KEY_HERE" | base64
  licence: ${LICENSE_B64}
EOF
    
    # Encrypt the secret
    sops --encrypt "${REPO_ROOT}/stackend-licence-secret.temp.yaml" > "${REPO_ROOT}/components/kustomizations/configuration-setup/VERSION/base/stackend-licence-secret.enc.yaml"
    
    # Clean up
    rm "${REPO_ROOT}/stackend-licence-secret.temp.yaml"
    
    echo -e "${GREEN}✅ Stackend license secret created and encrypted${NC}"
}

# Function to trigger Flux reconciliation
trigger_flux_reconciliation() {
    echo -e "\n${BLUE}🔄 Triggering comprehensive Flux reconciliation...${NC}"
    
    if ! command -v flux &> /dev/null; then
        echo -e "${YELLOW}⚠️  Flux CLI not found. Please install it or manually trigger reconciliation${NC}"
        echo "   brew install fluxcd/tap/flux"
        echo "   Or manually: kubectl annotate gitrepository flux-system -n flux-system reconcile.fluxcd.io/requestedAt=\"$(date +%s)\""
        return 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        echo -e "${YELLOW}⚠️  kubectl not found. Please install it${NC}"
        return 1
    fi
    
    echo "Reconciling flux-system (with source)..."
    flux reconcile ks -n flux-system flux-system --with-source
    
    echo "Reconciling crds..."
    flux reconcile ks -n flux-system crds
    
    echo "Reconciling system..."
    flux reconcile ks -n flux-system system
    
    echo "Reconciling stackend..."
    flux reconcile ks -n flux-system stackend
    
    echo "Reconciling stackweb..."
    flux reconcile ks -n flux-system stackweb
    
    echo -e "\n${BLUE}📋 Checking pod status...${NC}"
    kubectl get pods --all-namespaces
    
    echo -e "\n${GREEN}✅ Comprehensive Flux reconciliation completed${NC}"
    echo "All Flux Kustomizations have been reconciled and secrets decrypted/applied."
}

# Main menu
echo -e "\n${BLUE}📋 What would you like to do?${NC}"
echo "1. Create ACR secret only"
echo "2. Create Stackend license secret only" 
echo "3. Create both secrets"
echo "4. Create both secrets AND trigger Flux reconciliation"
echo

read -p "Choose an option (1-4): " CHOICE

case $CHOICE in
    1)
        create_acr_secret
        ;;
    2)
        create_stackend_license_secret
        ;;
    3)
        create_acr_secret
        create_stackend_license_secret
        ;;
    4)
        create_acr_secret
        create_stackend_license_secret
        trigger_flux_reconciliation
        ;;
    *)
        echo -e "${RED}❌ Invalid choice${NC}"
        exit 1
        ;;
esac

echo -e "\n${GREEN}🎉 Operation completed successfully!${NC}"

echo -e "\n${BLUE}📁 Files created/updated:${NC}"
if [[ $CHOICE == 1 || $CHOICE == 3 || $CHOICE == 4 ]]; then
    echo "   ✅ components/kustomizations/configuration-setup/VERSION/base/acr-secret.enc.yaml"
fi
if [[ $CHOICE == 2 || $CHOICE == 3 || $CHOICE == 4 ]]; then
    echo "   ✅ components/kustomizations/configuration-setup/VERSION/base/stackend-licence-secret.enc.yaml"
fi

if [[ $CHOICE == 4 ]]; then
    echo -e "\n${BLUE}🔄 Flux reconciliation:${NC}"
    echo "   ✅ Triggered Flux to decrypt and apply secrets automatically"
    echo "   ✅ Secrets will be available in flux-system namespace"
fi

echo -e "\n${BLUE}📋 Next Steps:${NC}"
echo "1. Commit the encrypted files to git:"
echo "   git add components/kustomizations/configuration-setup/VERSION/base/*.enc.yaml"
echo "   git commit -m 'Update encrypted secrets with new SOPS keys'"
echo

if [[ $CHOICE != 4 ]]; then
    echo "2. Trigger comprehensive Flux reconciliation:"
    echo "   flux reconcile ks -n flux-system flux-system --with-source"
    echo "   flux reconcile ks -n flux-system crds"
    echo "   flux reconcile ks -n flux-system system"
    echo "   flux reconcile ks -n flux-system stackend"
    echo "   flux reconcile ks -n flux-system stackweb"
    echo "   kubectl get pods --all-namespaces"
    echo
fi

echo -e "${YELLOW}⚠️  Note about ACR secret distribution:${NC}"
echo "The ACR secret is created in flux-system namespace only."
echo "If your deployments in other namespaces (celery, stackend, stackweb) need it,"
echo "consider implementing proper secret replication using:"
echo "  - External Secrets Operator"
echo "  - Kubernetes Secret Replication tools"
echo "  - Or update deployments to use a centralized image pull secret"

echo -e "\n${GREEN}✅ Done!${NC}"