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

echo -e "${BLUE}🔐 SOPS Bootstrap Script${NC}"
echo -e "${BLUE}========================${NC}"
echo
echo "This script will create a complete SOPS key infrastructure from scratch."
echo "It will generate:"
echo "  - Master AGE key"
echo "  - GitHub repository AGE key" 
echo "  - Cluster AGE key"
echo "  - Update .sops.yaml configuration"
echo "  - Create encrypted cluster key secret"
echo

# Confirm before proceeding
read -p "Are you sure you want to proceed? This will overwrite existing keys! (y/N): " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo -e "\n${YELLOW}⚠️  WARNING: This will overwrite any existing SOPS configuration!${NC}"
read -p "Type 'CONFIRM' to continue: " -r
if [[ $REPLY != "CONFIRM" ]]; then
    echo "Aborted."
    exit 1
fi

echo

# Check prerequisites
echo -e "${BLUE}📋 Checking prerequisites...${NC}"

if ! command -v sops &> /dev/null; then
    echo -e "${RED}❌ SOPS not found. Please install it first:${NC}"
    echo "   brew install sops"
    exit 1
fi

if ! command -v age &> /dev/null; then
    echo -e "${RED}❌ age not found. Please install it first:${NC}"
    echo "   brew install age"
    exit 1
fi

if ! git rev-parse --git-dir &> /dev/null; then
    echo -e "${RED}❌ Not in a git repository${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites met${NC}"

# Create sops directory if it doesn't exist
mkdir -p "${SOPS_DIR}"
mkdir -p "${SOPS_DIR}/clusters/aks"

cd "${SOPS_DIR}"

# Step 1: Generate Master Key
echo -e "\n${BLUE}🔑 Step 1: Generating Master Key...${NC}"
if [[ -f "key.age" ]]; then
    cp "key.age" "key.age.backup.$(date +%s)"
    echo -e "${YELLOW}   Backed up existing master key${NC}"
    rm "key.age"
fi

age-keygen -o key.age
MASTER_PUBLIC_KEY=$(grep "public key:" key.age | cut -d' ' -f4)
echo -e "${GREEN}✅ Master key generated${NC}"
echo -e "   Public key: ${MASTER_PUBLIC_KEY}"

# Step 2: Generate GitHub Repo Key
echo -e "\n${BLUE}🔑 Step 2: Generating GitHub Repository Key...${NC}"
age-keygen -o github-repo-key.temp
GITHUB_PUBLIC_KEY=$(grep "public key:" github-repo-key.temp | cut -d' ' -f4)

# Encrypt GitHub repo key with master key
export SOPS_AGE_KEY_FILE="${SOPS_DIR}/key.age"
sops --encrypt --age "${MASTER_PUBLIC_KEY}" github-repo-key.temp > github-secret.age.enc

# Clean up temp file
rm github-repo-key.temp

echo -e "${GREEN}✅ GitHub repository key generated and encrypted${NC}"
echo -e "   Public key: ${GITHUB_PUBLIC_KEY}"

# Step 3: Generate Cluster Key
echo -e "\n${BLUE}🔑 Step 3: Generating Cluster Key...${NC}"
age-keygen -o cluster-key.temp
CLUSTER_PUBLIC_KEY=$(grep "public key:" cluster-key.temp | cut -d' ' -f4)

echo -e "${GREEN}✅ Cluster key generated${NC}"
echo -e "   Public key: ${CLUSTER_PUBLIC_KEY}"

# Step 4: Create .sops.yaml configuration
echo -e "\n${BLUE}⚙️  Step 4: Creating .sops.yaml configuration...${NC}"

cat > "${REPO_ROOT}/.sops.yaml" << EOF
creation_rules:
  # Encrypt cluster keys in sops/clusters with master and GitHub keys
  - path_regex: sops/clusters/.*\.age\.enc$
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${MASTER_PUBLIC_KEY},
      ${GITHUB_PUBLIC_KEY}
  
  # Encrypt all YAML files in sops/clusters with master and GitHub keys
  - path_regex: sops/clusters/.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${MASTER_PUBLIC_KEY},
      ${GITHUB_PUBLIC_KEY}
  
  # Encrypt all YAML files in the clusters directory with master and cluster keys
  - path_regex: clusters/.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${MASTER_PUBLIC_KEY},
      ${CLUSTER_PUBLIC_KEY}
  
  # Encrypt secrets in components directory with all three keys
  - path_regex: components/.*secret.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${MASTER_PUBLIC_KEY},
      ${GITHUB_PUBLIC_KEY},
      ${CLUSTER_PUBLIC_KEY}
  
  # Default rule for any other files
  - encrypted_regex: ^(data|stringData)$
    age: ${MASTER_PUBLIC_KEY}
EOF

echo -e "${GREEN}✅ .sops.yaml configuration created${NC}"

# Step 5: Create Cluster Key Secret
echo -e "\n${BLUE}🔐 Step 5: Creating encrypted cluster key secret...${NC}"

# Create unencrypted Kubernetes secret
cat > sops-age-key-secret.temp.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
stringData:
  age.agekey: |
EOF

# Append the cluster key content (with proper indentation)
sed 's/^/    /' cluster-key.temp >> sops-age-key-secret.temp.yaml

# Encrypt the secret
sops --encrypt sops-age-key-secret.temp.yaml > clusters/aks/sops-age-key-secret.enc.yaml

# Clean up temp files
rm sops-age-key-secret.temp.yaml cluster-key.temp

echo -e "${GREEN}✅ Encrypted cluster key secret created${NC}"

# Step 6: Summary and next steps
echo -e "\n${GREEN}🎉 SOPS Bootstrap Complete!${NC}"
echo -e "\n${BLUE}📁 Files created:${NC}"
echo "   ✅ sops/key.age (Master key - keep this secure!)"
echo "   ✅ sops/github-secret.age.enc (Encrypted GitHub repo key)"
echo "   ✅ sops/clusters/aks/sops-age-key-secret.enc.yaml (Encrypted cluster key)"
echo "   ✅ .sops.yaml (SOPS configuration)"

echo -e "\n${BLUE}🔑 Key Summary:${NC}"
echo "   Master key:  ${MASTER_PUBLIC_KEY}"
echo "   GitHub key:  ${GITHUB_PUBLIC_KEY}"
echo "   Cluster key: ${CLUSTER_PUBLIC_KEY}"

echo -e "\n${BLUE}📋 Next Steps:${NC}"
echo "1. Set environment variable:"
echo "   export SOPS_AGE_KEY_FILE='${SOPS_DIR}/key.age'"
echo

echo "2. Add GitHub Actions secret:"
echo "   - Go to GitHub repository settings → Secrets and variables → Actions"
echo "   - Create secret named 'SOPS_AGE_KEY'"
echo "   - Extract GitHub repo key:"
echo "     sops --decrypt sops/github-secret.age.enc | grep 'AGE-SECRET-KEY'"
echo "   - Copy the AGE-SECRET-KEY line as the secret value"
echo

echo "3. Apply cluster key to Kubernetes:"
echo "   sops --decrypt sops/clusters/aks/sops-age-key-secret.enc.yaml | kubectl apply -f -"
echo

echo "4. Recreate other secrets (you'll need the actual secret values):"
echo "   ./terraform/aks/scripts/recreate-sops-secrets.sh"
echo "   This script will help you create:"
echo "   - components/kustomizations/configuration-setup/VERSION/base/acr-secret.enc.yaml"
echo "   - components/kustomizations/configuration-setup/VERSION/base/stackend-licence-secret.enc.yaml"
echo

echo -e "${YELLOW}⚠️  IMPORTANT: Back up your master key (sops/key.age) securely!${NC}"
echo -e "${YELLOW}   This key is the only way to decrypt your secrets.${NC}"

echo -e "\n${GREEN}✅ Bootstrap complete!${NC}"