# bootstrap-sops.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Colors
$Red = "`e[31m"
$Green = "`e[32m"
$Yellow = "`e[33m"
$Blue = "`e[34m"
$NC = "`e[0m"

# Script directory and repo root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot = (git rev-parse --show-toplevel).Trim()
$SopsDir = Join-Path $RepoRoot "sops"

Write-Host "${Blue}🔐 SOPS Bootstrap Script${NC}"
Write-Host "${Blue}========================${NC}"
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
$confirm = Read-Host "Are you sure you want to proceed? This will overwrite existing keys! (y/N)"
if ($confirm -notmatch "^[Yy]$") {
    Write-Host "Aborted."
    exit 1
}

Write-Host ""
Write-Host "${Yellow}⚠️  WARNING: This will overwrite any existing SOPS configuration!${NC}"
$confirm2 = Read-Host "Type 'CONFIRM' to continue"
if ($confirm2 -ne "CONFIRM") {
    Write-Host "Aborted."
    exit 1
}

Write-Host ""
Write-Host "${Blue}📋 Checking prerequisites...${NC}"

if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
    Write-Host "${Red}❌ SOPS not found. Please install it first:${NC}"
    Write-Host "   winget install Mozilla.sops"
    exit 1
}
if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Write-Host "${Red}❌ age not found. Please install it first:${NC}"
    Write-Host "   winget install FiloSottile.age"
    exit 1
}
if (-not (git rev-parse --git-dir 2>$null)) {
    Write-Host "${Red}❌ Not in a git repository${NC}"
    exit 1
}

Write-Host "${Green}✅ Prerequisites met${NC}"