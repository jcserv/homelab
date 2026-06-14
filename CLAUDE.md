# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A 4-node HA K3s cluster on Raspberry Pi hardware (2x Pi4 4GB, 2x Pi5 8GB) running self-hosted services with GitOps-style deployment via Helm charts. Pushes to `main` trigger CI/CD that lints and deploys changed charts to the cluster over Tailscale.

## Common Commands

```bash
make help                  # Show all available targets

# Linting
make lint                  # Lint all YAML files with yamllint
make lint FILE=charts/pihole/Chart.yaml  # Lint a single file
make fix                   # Auto-fix YAML formatting with yamlfix

# Chart management
make setup-repos           # Add all required Helm repositories
make build-deps            # Build chart dependencies from Chart.lock
make update-deps           # Update dependencies and regenerate Chart.lock

# Deployment (requires cluster access)
make install-infra         # Install MetalLB, cert-manager, nginx-ingress, sealed-secrets
make install-monitoring    # Install Prometheus, Grafana, Loki, Alloy
make deploy-all            # Deploy all application services
make upgrade SERVICE=pihole                    # Upgrade a chart (default namespace)
make upgrade SERVICE=alloy NAMESPACE=monitoring # Upgrade with explicit namespace

# Operations
make status                # Show nodes, pods, services, PVCs
make logs SERVICE=immich   # Tail logs for a service
make backup                # Trigger manual Restic backup
make drain NODE=pi5-01     # Drain node for maintenance
make seal-secret CHART=immich SECRET=test      # Seal a secret (piped from kubectl)
```

## CI/CD Pipeline

`.github/workflows/ci.yml` runs on push to main and PRs:
- **Lint job**: Uses `ct lint` (chart-testing) on changed charts
- **Deploy job** (main only): Connects via Tailscale, detects changed charts via `git diff HEAD~1 HEAD`, runs `helm upgrade --install` with `--wait --atomic` for critical infra charts (cert-manager, nginx-ingress, metallb, sealed-secrets) and standard timeouts for application charts

Namespace is derived from `values.yaml` field `namespace` (falls back to chart name).

## Architecture

### Chart Categories

All Helm charts live under `charts/`. Each chart follows: `Chart.yaml`, `values.yaml`, `templates/`, and optionally `sealed-secrets/` and `charts/` (bundled dependencies).

**Infrastructure** (deployed first, critical for cluster):
- `metallb` — LoadBalancer IPs (nginx at 10.2.1.200, pihole at 10.2.1.202)
- `cert-manager` — TLS certificates
- `nginx-ingress` — DaemonSet reverse proxy, SSL passthrough, restricted source ranges
- `sealed-secrets` — kubeseal-encrypted secrets safe for Git
- `network-policies` — Egress/ingress policies

**Monitoring** (`monitoring` namespace):
- `kube-prometheus-stack` — Prometheus + Grafana (Authentik OAuth)
- `loki` — Log aggregation (SingleBinary mode, 72h retention)
- `alloy` — DaemonSet log/metrics collection agent
- `prometheus-blackbox-exporter` — Service health probes

**Applications** (`default` namespace unless noted):
- `immich` — Photo management with PostgreSQL + ML (NFS to NAS at 10.2.1.147)
- `home-assistant` — Home automation, host-network, privileged (must run on `pi4-02` for Zigbee USB)
- `pihole` — DNS + ad-blocking, 4 replicas spread across nodes
- `authentik` — SSO/identity provider with PostgreSQL
- `nas-services` — External service routing to UGREEN NAS
- `open-archiver` — Email archiving (B2 S3 storage, shared valkey, dedicated PostgreSQL + Meilisearch)

**Backups** (CronJobs):
- `restic-backup` — Monthly NAS files/library to Backblaze B2
- `immich-db-backup` — Daily PostgreSQL dump to B2
- `home-assistant-backup` — Daily config snapshot to B2
- `authentik-backup` — Authentik data backup

### Secrets Management

Secrets are sealed with `kubeseal` and stored in `charts/<name>/sealed-secrets/`. To create a sealed secret:
```bash
kubectl create secret generic <name> --from-literal=key=val --dry-run=client -o yaml | make seal-secret CHART=<chart> SECRET=<name>
```
The `.env` file (not committed) holds raw credentials. Never commit unsealed secrets.

### Node Affinity Constraints

- `pi4-02`: label `zigbee=true` — Home Assistant (USB dongle at `/dev/ttyUSB0`)
- `pi5-01`: label `storage=true` — Immich ML, workloads needing local HDD
- Loki excludes Pi4 nodes (prefers Pi5 for memory)

### Dependency Management

Renovate auto-creates PRs for Helm chart and Docker image updates (config in `renovate.json`). PostgreSQL updates in `charts/authentik/values.yaml` are disabled (requires manual migration). Renovate auto-bumps chart versions in `Chart.yaml` on dependency changes.

### Non-Kubernetes Components

`docker/` contains Docker Compose configs running on the NAS (not part of the K8s cluster):
- `media-stack.yml` — Gluetun VPN + media apps (qBittorrent, Radarr, Sonarr, Jellyfin, etc.)
- `node-exporter.yml` — Prometheus node exporter for NAS metrics
