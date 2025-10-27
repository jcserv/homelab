# Adding Services with HTTPS Access

This guide explains how to add new services to your homelab with HTTPS access through the nginx ingress controller.

## Architecture Overview

```
Client (Browser)
    ↓
Pi-hole DNS (10.0.0.202) - Resolves *.home to 10.0.0.200
    ↓
NGINX Ingress (10.0.0.200) - Routes HTTPS traffic + Terminates TLS
    ↓
Your Service (ClusterIP) - Receives HTTP traffic
```

## Prerequisites

- NGINX Ingress Controller deployed and running on `10.0.0.200`
- cert-manager with wildcard certificate for `*.home` domains
- Pi-hole DNS service running on `10.0.0.202`
- Client machines configured to use `10.0.0.202` as DNS server
- CA certificate installed on client devices

## Step-by-Step Guide

### 1. Create Your Service Chart

Create your Helm chart as usual, but use **ClusterIP** instead of LoadBalancer:

```yaml
# charts/myapp/values.yaml
replicaCount: 1

image:
  repository: myorg/myapp
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP  # Use ClusterIP when using ingress
  port: 8080

resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"
```

### 2. Add Ingress Configuration

Add the ingress section to your `values.yaml`:

```yaml
# Ingress configuration for HTTPS access
ingress:
  enabled: true
  className: nginx
  host: myapp.home  # Your custom .home domain
  tlsSecretName: wildcard-home-tls  # Shared wildcard cert
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # Add other annotations as needed:
    # nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    # nginx.ingress.kubernetes.io/websocket-services: "myapp"
```

### 3. Create Ingress Template

Create `charts/myapp/templates/ingress.yaml`:

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "myapp.fullname" . }}
  labels:
    app: {{ include "myapp.name" . }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
  - hosts:
    - {{ .Values.ingress.host }}
    secretName: {{ .Values.ingress.tlsSecretName }}
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {{ include "myapp.fullname" . }}
            port:
              number: {{ .Values.service.port }}
{{- end }}
```

**Note:** If your chart doesn't use `include` helper functions (like dozzle), use:
```yaml
name: {{ .Chart.Name }}
```

### 4. Add DNS Entry to Pi-hole

Since Pi-hole v6 stores DNS records in `/etc/pihole/pihole.toml`, you need to manually add them:

```bash
# Replace 'myapp' with your service name
SERVICE_NAME="myapp"

for pod in pihole-0 pihole-1 pihole-2; do
  kubectl exec $pod -- sh -c "
    # Add new DNS entry after dozzle.home (or the last entry)
    sed -i 's/\"10.0.0.200 dozzle.home\"/\"10.0.0.200 dozzle.home\",\n    \"10.0.0.200 $SERVICE_NAME.home\"/' /etc/pihole/pihole.toml
    pihole reloaddns
  "
done

# Verify DNS resolution
sleep 3
host $SERVICE_NAME.home 10.0.0.202
```

**Expected output:**
```
myapp.home has address 10.0.0.200
```

### 5. Deploy Your Service

```bash
helm upgrade --install myapp ./charts/myapp -f charts/myapp/values.yaml
```

### 6. Verify Deployment

```bash
# Check pods are running
kubectl get pods -l app=myapp

# Check service was created
kubectl get svc myapp

# Check ingress was created
kubectl get ingress myapp

# Should show:
# NAME    CLASS   HOSTS        ADDRESS      PORTS     AGE
# myapp   nginx   myapp.home   10.0.0.200   80, 443   1m
```

### 7. Test HTTPS Access

From your browser or command line (with DNS set to 10.0.0.202):

```bash
# Test HTTPS
curl -v https://myapp.home

# Or open in browser
open https://myapp.home
```

## Helper Script

Save this as `scripts/add-service-dns.sh`:

```bash
#!/bin/bash
# Script to add a new service DNS entry to Pi-hole

SERVICE_NAME=$1

if [ -z "$SERVICE_NAME" ]; then
  echo "Usage: $0 <service-name>"
  echo "Example: $0 myapp"
  exit 1
fi

echo "Adding $SERVICE_NAME.home to Pi-hole DNS..."

for pod in pihole-0 pihole-1 pihole-2; do
  echo "  Updating $pod..."
  kubectl exec $pod -- sh -c "
    sed -i 's/\"10.0.0.200 dozzle.home\"/\"10.0.0.200 dozzle.home\",\n    \"10.0.0.200 $SERVICE_NAME.home\"/' /etc/pihole/pihole.toml
    pihole reloaddns
  " 2>&1 | grep -v "readonly variable" || true
done

echo ""
echo "Waiting for DNS propagation..."
sleep 3

echo ""
echo "Testing DNS resolution..."
host $SERVICE_NAME.home 10.0.0.202

echo ""
echo "Done! You can now access your service at https://$SERVICE_NAME.home"
```

Make it executable:
```bash
chmod +x scripts/add-service-dns.sh
```

Usage:
```bash
./scripts/add-service-dns.sh myapp
```

## Troubleshooting

### DNS Not Resolving

```bash
# Check Pi-hole DNS entries
kubectl exec pihole-0 -- cat /etc/pihole/hosts/custom.list

# Manually test DNS
host myapp.home 10.0.0.202

# Check your computer's DNS settings
# macOS: System Settings → Network → DNS Servers
# Should include 10.0.0.202
```

### Ingress Not Working

```bash
# Check ingress was created
kubectl get ingress myapp

# Check ingress details
kubectl describe ingress myapp

# Check nginx ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50

# Verify certificate exists
kubectl get secret wildcard-home-tls -n default
```

### Certificate Warnings

If you see SSL certificate warnings:

1. **Extract the CA certificate** (if not already done):
   ```bash
   kubectl get secret homelab-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
   ```

2. **Install on macOS**:
   ```bash
   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt
   ```

3. **Restart your browser** after installing the certificate

### Service Returns 404

```bash
# Check service exists and has endpoints
kubectl get svc myapp
kubectl get endpoints myapp

# Check pod is running
kubectl get pods -l app=myapp

# Test service directly (from within cluster)
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://myapp:8080
```

## Advanced Configuration

### WebSocket Support

If your service uses WebSockets:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/websocket-services: "myapp"
```

### Large File Uploads

For services that handle large file uploads:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
```

### Custom Timeouts

For long-running requests:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
```

### Client Certificate Authentication

For additional security:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
    nginx.ingress.kubernetes.io/auth-tls-secret: "default/ca-secret"
```

## Common Ingress Annotations Reference

```yaml
ingress:
  annotations:
    # Force HTTPS redirect
    nginx.ingress.kubernetes.io/ssl-redirect: "true"

    # CORS headers
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "*"

    # Rate limiting
    nginx.ingress.kubernetes.io/limit-rps: "10"

    # Basic auth
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"

    # Custom headers
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Frame-Options: DENY";
      more_set_headers "X-Content-Type-Options: nosniff";
```

## Alternative: Automated DNS Management

If you want to avoid manual DNS entry updates, consider:

1. **Downgrade to Pi-hole v5** which has better file-based config support
2. **Use CoreDNS** with a custom ConfigMap
3. **Use external-dns** with Kubernetes annotations
4. **Create a CronJob** that syncs a ConfigMap to Pi-hole's database

## Quick Checklist

When adding a new service:

- [ ] Service uses `ClusterIP` type
- [ ] Added `ingress` section to values.yaml
- [ ] Created `ingress.yaml` template
- [ ] Added DNS entry to Pi-hole (all 3 pods)
- [ ] Deployed service with Helm
- [ ] Verified ingress was created
- [ ] Tested DNS resolution
- [ ] Tested HTTPS access in browser

## Example Services

See existing services for reference:
- `charts/pihole/` - Pi-hole admin interface
- `charts/beszel/` - Beszel monitoring
- `charts/dozzle/` - Dozzle container logs

All use the same pattern for ingress configuration.
