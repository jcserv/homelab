# GitOps Deployment Guide

This repository uses a lightweight GitOps approach with GitHub Actions to automatically deploy Helm chart changes to your Kubernetes cluster.

## Overview

**How it works:**
1. You make changes to Helm charts and open a pull request
2. CI workflow runs (linting and testing)
3. After merge to `main`, CD workflow automatically:
   - Detects which charts changed
   - Connects to your cluster via Tailscale
   - Updates chart dependencies
   - Deploys changed charts with Helm

## Prerequisites

- Kubernetes cluster running (your Raspberry Pi k3s cluster)
- Tailscale installed on your Kubernetes control plane nodes
- GitHub repository with Actions enabled
- Helm installed on your cluster

## Initial Setup

### 1. Install Tailscale on Your Raspberry Pi Nodes

On each Raspberry Pi running k3s:

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate and connect
sudo tailscale up

# Get your Tailscale IP
tailscale ip -4
# Note this IP (e.g., 100.x.x.x) - you'll need it later
```

### 2. Deploy the RBAC Configuration

This creates a service account with limited permissions for GitHub Actions:

```bash
kubectl apply -f k8s/rbac/github-actions-serviceaccount.yaml
```

Verify it was created:

```bash
kubectl get serviceaccount github-actions -n gitops-system
```

### 3. Generate Kubeconfig for GitHub Actions

Run the helper script to generate a kubeconfig with the service account token:

```bash
./scripts/generate-kubeconfig.sh
```

The script will:
- Create a long-lived token (1 year validity)
- Generate a kubeconfig file
- Prompt you for your Tailscale IP
- Output a base64-encoded kubeconfig for GitHub secrets

**Important:** When prompted, enter your Kubernetes API server Tailscale URL in the format:
```
https://100.x.x.x:6443
```

Replace `100.x.x.x` with the Tailscale IP from step 1.

### 4. Create Tailscale OAuth Credentials

To allow GitHub Actions to connect to your Tailscale network:

#### Step 4a: Create a Tag for GitHub Actions

1. Go to [Tailscale Admin Console → Access Controls](https://login.tailscale.com/admin/acls)
2. Add a tag definition to your ACL policy (click **Edit** if needed):

```json
{
  "tagOwners": {
    "tag:github-actions": ["autogroup:admin"]
  }
}
```

3. Click **Save** to apply the ACL changes

This creates a `tag:github-actions` tag that will be applied to devices created by the OAuth client.

#### Step 4b: Generate OAuth Client

1. Go to [Tailscale Admin Console → OAuth Clients](https://login.tailscale.com/admin/settings/oauth)
2. Click **Generate OAuth client**
3. Under **Scopes**, select:
   - **Devices: Write**
4. Under **Tags** (required for write scope), add:
   - `tag:github-actions`
5. Click **Generate client**
6. Copy the **Client ID** and **Client Secret** (you won't be able to see the secret again!)

**Note:** Devices created by this OAuth client will automatically be ephemeral and tagged with `tag:github-actions`

### 5. Configure GitHub Secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Create these secrets:

| Secret Name | Value | Where to Get It |
|-------------|-------|-----------------|
| `TS_OAUTH_CLIENT_ID` | Your Tailscale OAuth client ID | From Tailscale admin console |
| `TS_OAUTH_SECRET` | Your Tailscale OAuth client secret | From Tailscale admin console |
| `KUBE_CONFIG` | Base64-encoded kubeconfig | Output from `generate-kubeconfig.sh` |

### 6. Test the Deployment

Make a small change to a Helm chart (e.g., update a comment), commit to a branch, open a PR, and merge to `main`. The CD workflow should trigger automatically.

Monitor the deployment:
- Go to **Actions** tab in GitHub
- Click on the latest **Continuous Deployment** workflow run
- Watch the deployment logs

## How to Deploy Changes

### Standard Workflow

1. **Create a branch:**
   ```bash
   git checkout -b update-chart-name
   ```

2. **Make changes to your chart:**
   ```bash
   # Edit chart files
   vim charts/your-chart/values.yaml
   ```

3. **Commit and push:**
   ```bash
   git add charts/your-chart/
   git commit -m "update: description of changes"
   git push origin update-chart-name
   ```

4. **Open a pull request:**
   - CI will run linting and tests
   - Review the changes
   - Merge to `main`

5. **Automatic deployment:**
   - CD workflow detects the changed chart
   - Connects via Tailscale
   - Deploys automatically

### What Gets Deployed

The CD workflow only deploys **changed** charts. It uses `helm/chart-testing` to detect which charts were modified in the commit.

**Chart change detection includes:**
- Changes to `Chart.yaml`
- Changes to `values.yaml`
- Changes to templates in `templates/`
- Changes to dependency definitions

## Deployment Behavior

### Helm Upgrade Strategy

Charts are deployed using:
```bash
helm upgrade --install <chart-name> <chart-path> \
  --namespace <namespace> \
  --create-namespace \
  --wait \
  --timeout 5m \
  --atomic
```

**Flags explained:**
- `--install`: Install if not already present
- `--create-namespace`: Create namespace if it doesn't exist
- `--wait`: Wait for resources to be ready
- `--timeout 5m`: Wait up to 5 minutes
- `--atomic`: Rollback on failure

### Namespace Selection

By default, charts are deployed to a namespace matching the chart name. You can override this by setting `namespace` in your chart's `values.yaml`:

```yaml
namespace: custom-namespace
```

### Dependency Management

If your chart has dependencies listed in `Chart.yaml`, they are automatically updated before deployment:

```yaml
dependencies:
  - name: postgresql
    version: "12.0.0"
    repository: "https://charts.bitnami.com/bitnami"
```

The workflow runs `helm dependency update` to fetch the latest matching versions.

## Monitoring Deployments

### GitHub Actions UI

1. Go to **Actions** tab in your repository
2. Click on a **Continuous Deployment** run
3. Expand the **Deploy changed charts** step
4. View real-time deployment logs

### Deployment Summary

After each deployment, a summary is added to the workflow run showing:
- Which charts were changed
- Deployment status (success/failure)

### Cluster-side Verification

Check deployment status on your cluster:

```bash
# List all Helm releases
helm list --all-namespaces

# Check specific release
helm status <chart-name> -n <namespace>

# View release history
helm history <chart-name> -n <namespace>

# Check pod status
kubectl get pods -n <namespace>
```

## Troubleshooting

### Workflow Fails: "Cannot connect to cluster"

**Possible causes:**
1. Tailscale connection failed
2. Kubeconfig secret is incorrect
3. Service account token expired

**Solutions:**
```bash
# Verify Tailscale is running on your Pi
tailscale status

# Regenerate kubeconfig
./scripts/generate-kubeconfig.sh

# Update KUBE_CONFIG secret in GitHub
```

### Workflow Fails: "RBAC permissions denied"

The service account may need additional permissions for new resource types.

**Solution:**
Edit `k8s/rbac/github-actions-serviceaccount.yaml` to add required permissions, then apply:
```bash
kubectl apply -f k8s/rbac/github-actions-serviceaccount.yaml
```

### Chart Deployment Fails: "timeout waiting for resources"

The chart may have resource constraints or dependencies not ready.

**Solutions:**
1. Check pod status: `kubectl get pods -n <namespace>`
2. Check pod logs: `kubectl logs <pod-name> -n <namespace>`
3. Increase timeout in `.github/workflows/cd.yml` (currently 5m)
4. Check resource availability: `kubectl describe nodes`

### Helm Release Stuck in Pending-Upgrade

If a deployment is interrupted, Helm may leave the release in a pending state.

**Solution:**
```bash
# Rollback to previous version
helm rollback <chart-name> -n <namespace>

# Or force delete the pending release
helm delete <chart-name> -n <namespace> --no-hooks
```

### Changes Not Detected

If you modify a chart but the CD workflow doesn't deploy it:

**Possible causes:**
1. Changes are not on `main` branch
2. Chart testing can't detect changes (modified files outside chart directory)
3. Workflow triggered but no charts marked as changed

**Solutions:**
```bash
# Manually check what changed
git diff main~1 main -- charts/

# Force deploy by modifying Chart.yaml version
# Edit charts/<name>/Chart.yaml and bump version
```

## Security Considerations

### Service Account Permissions

The `github-actions` service account has broad permissions to deploy resources. Review the ClusterRole in `k8s/rbac/github-actions-serviceaccount.yaml` and restrict as needed.

### Token Expiration

Service account tokens expire after 1 year. Set a calendar reminder to regenerate before expiration:

```bash
# Check token expiration
kubectl get secret -n gitops-system

# Regenerate
./scripts/generate-kubeconfig.sh
```

### Tailscale Security

- Use OAuth ephemeral keys (nodes auto-removed after job)
- Regularly review connected devices in Tailscale admin
- Consider using Tailscale ACLs to restrict which nodes GitHub Actions can access

### Secrets in Charts

**Never** commit sensitive values directly in `values.yaml`. Use one of these approaches:

1. **Sealed Secrets** (recommended, already set up):
   ```bash
   ./scripts/seal-secret.sh <namespace> <secret-name> <secret-file>
   ```

2. **GitHub Secrets** (for chart-specific secrets):
   Add secrets to GitHub and reference in workflow

3. **External Secrets Operator** (future enhancement)

## Rollback Procedures

### Automatic Rollback

Failed deployments automatically rollback due to the `--atomic` flag.

### Manual Rollback

If you need to rollback a successful deployment:

```bash
# View release history
helm history <chart-name> -n <namespace>

# Rollback to previous version
helm rollback <chart-name> -n <namespace>

# Rollback to specific revision
helm rollback <chart-name> <revision> -n <namespace>
```

### Git-based Rollback

The safest approach is to revert the Git commit:

```bash
# Revert the merge commit
git revert <commit-hash>
git push origin main

# CD workflow will deploy the reverted state
```

## Advanced Configuration

### Customizing Deployment Behavior

Edit `.github/workflows/cd.yml` to customize:

- **Timeout:** Change `--timeout 5m` to a longer duration
- **Parallel deployments:** Remove `--wait` to deploy multiple charts concurrently
- **Deployment order:** Add logic to deploy infrastructure charts before apps
- **Dry-run mode:** Add `--dry-run` for testing
- **Notifications:** Add Slack/Discord notifications on deployment success/failure

### Deploying Specific Charts Only

To prevent certain charts from auto-deploying, add logic to skip them:

```yaml
# In .github/workflows/cd.yml, add a filter:
if [[ "$chart_name" == "critical-service" ]]; then
  echo "Skipping auto-deploy of $chart_name"
  continue
fi
```

### Using Environments

For staging/production separation, use GitHub Environments:

1. Create environments in GitHub: Settings → Environments
2. Add environment-specific secrets
3. Modify CD workflow to deploy to different clusters based on branch

## Maintenance

### Regular Tasks

- **Monthly:** Review deployed charts and cleanup unused releases
- **Quarterly:** Rotate service account tokens
- **Annually:** Regenerate kubeconfig before token expiration
- **As needed:** Update RBAC permissions for new resource types

### Monitoring Long-term

Consider setting up:
- Prometheus alerts for failed Helm releases
- Grafana dashboard showing deployment frequency and success rate
- ArgoCD or FluxCD for more advanced GitOps features (future migration path)

## Migration from Manual Deployment

If you were previously using the Makefile for deployments:

**Old workflow:**
```bash
make upgrade SERVICE=home-assistant
```

**New workflow:**
```bash
# Make changes to chart
vim charts/home-assistant/values.yaml

# Commit and push
git add charts/home-assistant/
git commit -m "update: home-assistant configuration"
git push origin main

# Deployment happens automatically via CD workflow
```

You can still use the Makefile for manual deployments when needed (e.g., testing, emergency fixes).

## Further Reading

- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Tailscale GitHub Action](https://github.com/tailscale/github-action)
- [GitHub Actions Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [GitOps Principles](https://opengitops.dev/)
