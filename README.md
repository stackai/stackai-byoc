# StackAI BYOC

Deploy StackAI into your Kubernetes cluster with StackAI BYOC (Bring Your Own Cloud).

## Azure installation guide

### Install dependencies

```sh
brew install az terraform helm
```

### Login into Azure and select the tenant and subscription

```sh
az login
```

### Customize defaults

1.  Check flux defaults on [flux-bootstrap-aks.sh](terraform/aks/scripts/flux-bootstrap-aks.sh#L4)
2.  Customize your AKS cluster name `cluster_name` on [variables.tf](terraform/aks/variables.tf#L1)
3.  Customize your AKS user sufix `user_suffix` on [variables.tf](terraform/aks/variables.tf#L61)

### Create a fine-grained personal access token

[Generate a personal access token](https://github.com/settings/tokens/new?scopes=repo,admin:public_key,admin:repo_hook&description=StackAI+BYOC+Flux+GitOps+Token) on GitHub. The required scopes are `repo`, `admin:public_key`, and `admin:repo_hook` - the form is pre-filled for quick setup with the link above.

```sh
# set the generated token as an environment variable
export GITHUB_TOKEN=[your-fine-grained-token-here]
```

### Boostrap and init terraform

```sh
# Bootstrap SOPS (Secrets OPerationS)
./sops/scripts/bootstrap-sops.sh

# Initialize Terraform
cd terraform/aks
terraform init
terraform apply -auto-approve
```

## Troubleshooting

### SOPS Key Mismatch Issues

If you encounter SOPS decryption errors:

```sh
# Validate SOPS key consistency
cd terraform/aks
./scripts/validate-sops-keys.sh

# Recreate all secrets with current key (interactive)
export SOPS_AGE_KEY_FILE="../../sops/key.age"
./scripts/recreate-sops-secrets.sh
```

### Flux Reconciliation Issues

Check Flux status and force reconciliation:

```sh
# Check all Kustomizations
flux get kustomizations -A

# Force reconciliation
flux reconcile ks -n flux-system flux-system --with-source
flux reconcile ks -n flux-system configuration-setup
```

### Deployment Timeout Issues

The `create_login_user` script has been improved with longer timeouts. If it still times out:

```sh
# Check what's failing
kubectl get pods -A
flux get kustomizations -A

# Manually run the login user creation
cd terraform/aks
export KUBECONFIG=./kubeconfig_*
./scripts/create_login_user.sh
```

## Technical Support

[Enable and request just-in-time access for Azure Managed Applications](https://learn.microsoft.com/en-us/azure/azure-resource-manager/managed-applications/request-just-in-time-access)
