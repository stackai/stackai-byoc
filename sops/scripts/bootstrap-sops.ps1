# bootstrap-sops.ps1
# This script will create a complete SOPS key infrastructure from scratch for Windows.

# Colors for output (PowerShell equivalent)
$RED = "\033[0;31m"
$GREEN = "\033[0;32m"
$YELLOW = "\033[1;33m"
$BLUE = "\033[0;34m"
$NC = "\033[0m" # No Color

Write-Host "$($BLUE)🔐 SOPS Bootstrap Script$($NC)"
Write-Host "$($BLUE)========================$($NC)"
Write-Host ""
Write-Host "This script will create a complete SOPS key infrastructure from scratch."
Write-Host "It will generate:"
Write-Host "  - Master AGE key"
Write-Host "  - GitHub repository AGE key"
Write-Host "  - Cluster AGE key"
Write-Host "  - Update .sops.yaml configuration"
Write-Host "  - Create encrypted cluster key secret"
Write-Host ""

# Confirm before proceeding
$confirm = Read-Host "Are you sure you want to proceed? This will overwrite existing keys! (y/N): "
if ($confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Aborted."
    exit 1
}

Write-Host "`n$($YELLOW)⚠️  WARNING: This will overwrite any existing SOPS configuration!$($NC)"
$confirm = Read-Host "Type 'CONFIRM' to continue: "
if ($confirm -ne "CONFIRM") {
    Write-Host "Aborted."
    exit 1
}

Write-Host ""

# Check prerequisites
Write-Host "$($BLUE)📋 Checking prerequisites...$($NC)"

# Check for sops
try {
    (Get-Command sops -ErrorAction Stop).Path | Out-Null
} catch {
    Write-Host "$($RED)❌ SOPS not found. Please install it first:$($NC)"
    Write-Host "   choco install sops"
    exit 1
}

# Check for age
try {
    (Get-Command age -ErrorAction Stop).Path | Out-Null
} catch {
    Write-Host "$($RED)❌ age not found. Please install it first:$($NC)"
    Write-Host "   choco install age"
    exit 1
}

# Check for git repository
try {
    git rev-parse --is-inside-work-tree | Out-Null
} catch {
    Write-Host "$($RED)❌ Not in a git repository$($NC)"
    exit 1
}

Write-Host "$($GREEN)✅ Prerequisites met$($NC)"

# Script directory and repo root
$SCRIPT_DIR = (Get-Item -Path $MyInvocation.MyCommand.Definition).Directory.FullName
$REPO_ROOT = (git rev-parse --show-toplevel).Trim()
$SOPS_DIR = Join-Path $REPO_ROOT "sops"

# Create sops directory if it doesn't exist
New-Item -ItemType Directory -Force -Path $SOPS_DIR | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $SOPS_DIR "clusters\aks") | Out-Null

Set-Location $SOPS_DIR

# Step 1: Generate Master Key
Write-Host "`n$($BLUE)🔑 Step 1: Generating Master Key...$($NC)"
if (Test-Path "key.age") {
    Copy-Item "key.age" "key.age.backup.$((Get-Date).ToString('yyyyMMddHHmmss'))"
    Write-Host "$($YELLOW)   Backed up existing master key$($NC)"
    Remove-Item "key.age"
}

Invoke-Expression "age-keygen -o key.age"
$MASTER_PUBLIC_KEY = (Get-Content key.age | Select-String "public key:" | ForEach-Object { $_.ToString().Split(' ')[3] }).Trim()
Write-Host "$($GREEN)✅ Master key generated$($NC)"
Write-Host "   Public key: $($MASTER_PUBLIC_KEY)"

# Step 2: Generate GitHub Repo Key
Write-Host "`n$($BLUE)🔑 Step 2: Generating GitHub Repository Key...$($NC)"
Invoke-Expression "age-keygen -o github-repo-key.temp"
$GITHUB_PUBLIC_KEY = (Get-Content github-repo-key.temp | Select-String "public key:" | ForEach-Object { $_.ToString().Split(' ')[3] }).Trim()

# Encrypt GitHub repo key with master key
$env:SOPS_AGE_KEY_FILE = (Join-Path $SOPS_DIR "key.age")
Invoke-Expression "sops --encrypt --age \"$($MASTER_PUBLIC_KEY)\" github-repo-key.temp | Set-Content github-secret.age.enc"

# Clean up temp file
Remove-Item "github-repo-key.temp"

Write-Host "$($GREEN)✅ GitHub repository key generated and encrypted$($NC)"
Write-Host "   Public key: $($GITHUB_PUBLIC_KEY)"

# Step 3: Generate Cluster Key
Write-Host "`n$($BLUE)🔑 Step 3: Generating Cluster Key...$($NC)"
Invoke-Expression "age-keygen -o cluster-key.temp"
$CLUSTER_PUBLIC_KEY = (Get-Content cluster-key.temp | Select-String "public key:" | ForEach-Object { $_.ToString().Split(' ')[3] }).Trim()

Write-Host "$($GREEN)✅ Cluster key generated$($NC)"
Write-Host "   Public key: $($CLUSTER_PUBLIC_KEY)"

# Step 4: Create .sops.yaml configuration
Write-Host "`n$($BLUE)⚙️  Step 4: Creating .sops.yaml configuration...$($NC)"

$sopsYamlContent = @"
creation_rules:
  # Encrypt cluster keys in sops/clusters with master and GitHub keys
  - path_regex: sops/clusters/.*\\.age\\.enc$
    encrypted_regex: ^(data|stringData)$
    age: >-
      $($MASTER_PUBLIC_KEY),
      $($GITHUB_PUBLIC_KEY)
  
  # Encrypt all YAML files in sops/clusters with master and GitHub keys
  - path_regex: sops/clusters/.*\\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      $($MASTER_PUBLIC_KEY),
      $($GITHUB_PUBLIC_KEY)
  
  # Encrypt all YAML files in the clusters directory with master and cluster keys
  - path_regex: clusters/.*\\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      $($MASTER_PUBLIC_KEY),
      $($CLUSTER_PUBLIC_KEY)
  
  # Encrypt secrets in components directory with all three keys
  - path_regex: components/.*secret.*\\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      $($MASTER_PUBLIC_KEY),
      $($GITHUB_PUBLIC_KEY),
      $($CLUSTER_PUBLIC_KEY)
  
  # Default rule for any other files
  - encrypted_regex: ^(data|stringData)$
    age: $($MASTER_PUBLIC_KEY)
"@

Set-Content -Path (Join-Path $REPO_ROOT ".sops.yaml") -Value $sopsYamlContent

Write-Host "$($GREEN)✅ .sops.yaml configuration created$($NC)"

# Step 5: Create Cluster Key Secret
Write-Host "`n$($BLUE)🔐 Step 5: Creating encrypted cluster key secret...$($NC)"

# Create unencrypted Kubernetes secret
$secretTempYamlContent = @"
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
stringData:
  age.agekey: |
"@

$clusterKeyContent = Get-Content cluster-key.temp | ForEach-Object { "    " + $_ }
$secretTempYamlContent += "`n" + ($clusterKeyContent -join "`n")

Set-Content -Path "sops-age-key-secret.temp.yaml" -Value $secretTempYamlContent

# Encrypt the secret
Invoke-Expression "sops --encrypt sops-age-key-secret.temp.yaml | Set-Content (Join-Path (Join-Path $SOPS_DIR \"clusters\") \"aks\sops-age-key-secret.enc.yaml\")"

# Clean up temp files
Remove-Item "sops-age-key-secret.temp.yaml"
Remove-Item "cluster-key.temp"

Write-Host "$($GREEN)✅ Encrypted cluster key secret created$($NC)"

# Step 6: Summary and next steps
Write-Host "`n$($GREEN)🎉 SOPS Bootstrap Complete!$($NC)"
Write-Host "`n$($BLUE)📁 Files created:$($NC)"
Write-Host "   ✅ sops\key.age (Master key - keep this secure!)"
Write-Host "   ✅ sops\github-secret.age.enc (Encrypted GitHub repo key)"
Write-Host "   ✅ sops\clusters\aks\sops-age-key-secret.enc.yaml (Encrypted cluster key)"
Write-Host "   ✅ .sops.yaml (SOPS configuration)"

Write-Host "`n$($BLUE)🔑 Key Summary:$($NC)"
Write-Host "   Master key:  $($MASTER_PUBLIC_KEY)"
Write-Host "   GitHub key:  $($GITHUB_PUBLIC_KEY)"
Write-Host "   Cluster key: $($CLUSTER_PUBLIC_KEY)"

Write-Host "`n$($BLUE)📋 Next Steps:$($NC)"
Write-Host "1. Set environment variable:"
Write-Host "   $env:SOPS_AGE_KEY_FILE = '$($SOPS_DIR)\key.age'"
Write-Host ""

Write-Host "2. Add GitHub Actions secret:"
Write-Host "   - Go to GitHub repository settings -> Secrets and variables -> Actions"
Write-Host "   - Create secret named 'SOPS_AGE_KEY'"
Write-Host "   - Extract GitHub repo key:"
Write-Host "     sops --decrypt sops\github-secret.age.enc | Select-String 'AGE-SECRET-KEY'"
Write-Host "   - Copy the AGE-SECRET-KEY line as the secret value"
Write-Host ""

Write-Host "3. Apply cluster key to Kubernetes:"
Write-Host "   sops --decrypt sops\clusters\aks\sops-age-key-secret.enc.yaml | kubectl apply -f -"
Write-Host ""

Write-Host "4. Recreate other secrets (you'll need the actual secret values):"
Write-Host "   .\terraform\aks\scripts\recreate-sops-secrets.ps1"
Write-Host "   This script will help you create:"
Write-Host "   - components\kustomizations\configuration-setup\VERSION\base\acr-secret.enc.yaml"
Write-Host "   - components\kustomizations\configuration-setup\VERSION\base\stackend-licence-secret.enc.yaml"
Write-Host ""

Write-Host "$($YELLOW)⚠️  IMPORTANT: Back up your master key (sops\key.age) securely!$($NC)"
Write-Host "$($YELLOW)   This key is the only way to decrypt your secrets.$($NC)"

Write-Host "`n$($GREEN)✅ Bootstrap complete!$($NC)"


