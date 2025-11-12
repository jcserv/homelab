# NGINX Ingress Controller

This chart deploys the NGINX Ingress Controller to provide HTTPS access to your homelab services via custom `.home` domains.

## Architecture

The setup consists of:
1. **NGINX Ingress Controller**: Routes HTTPS traffic to backend services
2. **cert-manager**: Manages TLS certificates
3. **Self-signed CA**: Issues certificates for `*.home` domains
4. **Pi-hole**: Provides DNS resolution for `.home` domains

## Prerequisites

- MetalLB configured with IP pool (for LoadBalancer service)
- cert-manager installed and configured
- Pi-hole with custom DNS entries pointing to nginx ingress IP

## Installation

1. **Deploy cert-manager and CA issuer** (if not already deployed):
   ```bash
   helm upgrade --install cert-manager ./charts/cert-manager --namespace cert-manager --create-namespace
   ```

2. **Deploy NGINX Ingress Controller**:
   ```bash
   # First, update dependencies
   cd charts/nginx-ingress
   helm dependency update

   # Deploy the chart
   helm upgrade --install nginx-ingress ./charts/nginx-ingress --namespace ingress-nginx --create-namespace
   ```

3. **Verify the wildcard certificate is created**:
   ```bash
   kubectl get certificate -n cert-manager
   kubectl get secret wildcard-home-tls -n cert-manager
   ```

4. **Update Pi-hole DNS entries** to point all `.home` domains to the nginx ingress IP (10.0.0.200)

5. **Deploy services with ingress enabled**:
   ```bash
   # Example: Deploy beszel with ingress
   helm upgrade --install beszel ./charts/beszel --namespace default -f charts/beszel/values.yaml
   ```

## Configuration

### Ingress IP Address

The ingress controller uses IP `10.0.0.200` by default. To change this, edit `values.yaml`:

```yaml
ingress-nginx:
  controller:
    service:
      loadBalancerIP: 10.0.0.XXX  # Your desired IP
```

### TLS Certificate

The wildcard certificate `*.home` is automatically created by cert-manager and stored in the `wildcard-home-tls` secret in the `cert-manager` namespace.

### Adding Ingress to Services

To expose a service via HTTPS, add the following to your service's Helm chart:

1. **Create ingress template** (`templates/ingress.yaml`):
   ```yaml
   {{- if .Values.ingress.enabled }}
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: {{ include "myapp.fullname" . }}
     annotations:
       {{- toYaml .Values.ingress.annotations | nindent 4 }}
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

2. **Add values** (`values.yaml`):
   ```yaml
   service:
     type: ClusterIP  # Use ClusterIP when ingress is enabled
     port: 8080

   ingress:
     enabled: true
     className: nginx
     host: myapp.home
     tlsSecretName: wildcard-home-tls
     annotations:
       cert-manager.io/cluster-issuer: homelab-ca-issuer
       nginx.ingress.kubernetes.io/ssl-redirect: "true"
   ```

3. **Add DNS entry in Pi-hole**:
   ```yaml
   customDnsEntries:
     - "10.0.0.200 myapp.home"
   ```

## Trust the Self-Signed CA

To avoid browser certificate warnings, import the CA certificate on your devices:

1. **Extract the CA certificate**:
   ```bash
   kubectl get secret homelab-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
   ```

2. **Import on your device**:
   - **macOS**: Open Keychain Access → File → Import Items → Select `homelab-ca.crt` → Set trust to "Always Trust"
   - **Windows**: Double-click `homelab-ca.crt` → Install Certificate → Local Machine → Place in "Trusted Root Certification Authorities"
   - **Linux**: Copy to `/usr/local/share/ca-certificates/` and run `sudo update-ca-certificates`
   - **iOS/Android**: Email the certificate to yourself and install from Settings

## Troubleshooting

### Check ingress controller status
```bash
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

### Check certificate status
```bash
kubectl get certificate -n cert-manager
kubectl describe certificate wildcard-home-cert -n cert-manager
```

### Check ingress resources
```bash
kubectl get ingress --all-namespaces
kubectl describe ingress <ingress-name> -n <namespace>
```

### Test DNS resolution
```bash
nslookup beszel.home <pihole-ip>
```

### Test HTTPS access
```bash
curl -k https://beszel.home
```

## Architecture Diagram

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │ https://beszel.home
       ↓
┌─────────────┐
│   Pi-hole   │ DNS: beszel.home → 10.0.0.200
└──────┬──────┘
       │
       ↓
┌─────────────────────┐
│ NGINX Ingress       │ IP: 10.0.0.200
│ (LoadBalancer)      │ TLS: wildcard-home-tls
└──────┬──────────────┘
       │
       ├──→ beszel.home ──→ beszel-service:8090
       ├──→ pi.home ──────→ pihole-admin:80
       └──→ dozzle.home ──→ dozzle-service:8080
```
