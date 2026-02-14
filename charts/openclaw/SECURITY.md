# OpenClaw Security Operations

## Architecture

```
Internet <-- HTTPS --> Squid Proxy (domain allowlist)
                           ^
                           |
                     OpenClaw Pod
                           |
                           v
                      LiteLLM Proxy --> Anthropic API
```

- **LiteLLM** holds the real `ANTHROPIC_API_KEY`. OpenClaw only has a virtual proxy key.
- **Squid** filters all outbound HTTPS to an explicit domain allowlist.
- **NetworkPolicy** restricts pod-to-pod traffic: OpenClaw can only reach LiteLLM, Squid, Authentik, and DNS.

## Token Rotation

### 1. Rotate Anthropic API Key (stored in LiteLLM)

Generate a new API key at https://console.anthropic.com, then:

```bash
# Create new sealed secret for LiteLLM
kubectl create secret generic litellm-secrets \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-NEW_KEY_HERE" \
  --from-literal=LITELLM_MASTER_KEY="sk-litellm-EXISTING_OR_NEW" \
  --dry-run=client -o yaml | \
  make seal-secret CHART=litellm SECRET=litellm-secrets

# Deploy
make upgrade SERVICE=litellm
```

OpenClaw does **not** need restarting — it talks to LiteLLM, not Anthropic directly.

### 2. Rotate LiteLLM Proxy Key (used by OpenClaw)

```bash
# Generate a new proxy key
NEW_KEY="sk-litellm-$(openssl rand -hex 16)"

# Update LiteLLM master key
kubectl create secret generic litellm-secrets \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-EXISTING" \
  --from-literal=LITELLM_MASTER_KEY="$NEW_KEY" \
  --dry-run=client -o yaml | \
  make seal-secret CHART=litellm SECRET=litellm-secrets

# Update OpenClaw secret with the new proxy key
kubectl create secret generic openclaw-secrets \
  --from-literal=ANTHROPIC_API_KEY="$NEW_KEY" \
  --from-literal=TELEGRAM_BOT_TOKEN="EXISTING" \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="EXISTING" \
  --dry-run=client -o yaml | \
  make seal-secret CHART=openclaw SECRET=openclaw-secrets

# Deploy both
make upgrade SERVICE=litellm
make upgrade SERVICE=openclaw
```

### 3. Rotate Gateway Token

```bash
NEW_TOKEN=$(openssl rand -hex 32)

kubectl create secret generic openclaw-secrets \
  --from-literal=ANTHROPIC_API_KEY="EXISTING_PROXY_KEY" \
  --from-literal=TELEGRAM_BOT_TOKEN="EXISTING" \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="$NEW_TOKEN" \
  --dry-run=client -o yaml | \
  make seal-secret CHART=openclaw SECRET=openclaw-secrets

make upgrade SERVICE=openclaw
```

### 4. Rotate Telegram Bot Token

Revoke and regenerate via @BotFather, then:

```bash
kubectl create secret generic openclaw-secrets \
  --from-literal=ANTHROPIC_API_KEY="EXISTING_PROXY_KEY" \
  --from-literal=TELEGRAM_BOT_TOKEN="NEW_BOT_TOKEN" \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="EXISTING" \
  --dry-run=client -o yaml | \
  make seal-secret CHART=openclaw SECRET=openclaw-secrets

make upgrade SERVICE=openclaw
```

## Rotation Schedule

| Secret | Frequency | Owner |
|--------|-----------|-------|
| Anthropic API Key | Quarterly | LiteLLM sealed secret |
| LiteLLM Proxy Key | Quarterly | LiteLLM + OpenClaw sealed secrets |
| Gateway Token | Quarterly | OpenClaw sealed secret |
| Telegram Bot Token | Annually | OpenClaw sealed secret |

## Squid Domain Allowlist

Edit `charts/squid-proxy/values.yaml` to modify allowed domains:

```yaml
allowedDomains:
  - ".anthropic.com"
  - ".telegram.org"
  - "api.telegram.org"
  - ".github.com"
  - "api.github.com"
  - "raw.githubusercontent.com"
  - "github.com"
```

Deploy with `make upgrade SERVICE=squid-proxy`.

## Security Audit

A weekly CronJob validates the deployment against expected security settings. Check results:

```bash
# View last audit output
kubectl logs job/$(kubectl get jobs -l app.kubernetes.io/name=openclaw-security-audit --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2) 2>/dev/null

# Trigger manual audit
kubectl create job --from=cronjob/openclaw-security-audit manual-audit-$(date +%s)
```

Alerts fire to Prometheus/Alertmanager if:
- Audit job fails (security check not passing)
- Audit hasn't run in 8 days
- Audit takes longer than 5 minutes
