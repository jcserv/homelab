# Homelab Kubernetes Architecture

## Overview

This document describes the architecture for migrating from a single Raspberry Pi 5 running Docker to a highly available Kubernetes cluster using K3s.

**Key Design Principle:** Flexible scheduling with minimal hard requirements. Most services can reschedule to any node if a node fails.

## Hardware Layout

### Cluster Nodes (Optimal Distribution with HA Control Plane)

```
Pi 4 #1 (Control Plane #1 - 4GB)
├── k3s server + etcd (~700MB)
├── nginx-proxy-manager replica 1 (SOFT: prefers this node)
├── pihole replica 1 (SOFT: prefers this node)
├── beszel hub (SOFT: prefers this node)
├── beszel agent (DaemonSet: runs on ALL nodes)
└── Total: ~1.1GB / 4GB = 2.9GB free

Pi 4 #2 (Control Plane #2 + Zigbee - 4GB)
├── k3s server + etcd (~700MB)
├── home-assistant (HARD: requires Zigbee USB)
├── nginx-proxy-manager replica 2 (SOFT: prefers this node)
├── pihole replica 2 (SOFT: prefers this node)
├── beszel agent (DaemonSet: runs on ALL nodes)
├── immich-redis (SOFT: moved from Pi 4 #1 for space)
└── Total: ~2.85GB / 4GB = 1.15GB free

Pi 5 (Control Plane #3 + Storage - 8GB)
├── k3s server + etcd (~700MB)
├── immich-server (HARD: requires HDD access)
├── immich-postgres (SOFT: uses local-path storage on Pi 5)
├── immich-machine-learning (SOFT: moved from Pi 4 #2 for space)
├── immich-redis (SOFT: uses local-path storage on Pi 5)
├── filebrowser (HARD: requires HDD access)
├── beszel agent (DaemonSet: runs on ALL nodes)
└── Total: ~4.5GB / 8GB = 3.5GB free
```

**HA Benefits:**
- ✅ Cluster survives any **single node failure**
- ✅ etcd quorum maintained with 2 of 3 control plane nodes
- ✅ Can still deploy/manage workloads when 1 node is down
- ✅ Automatic leader election for API server
- ⚠️ Requires **2 of 3 nodes** to maintain quorum (can't lose 2 simultaneously)

**Legend:**
- **HARD** = Must run on this node (requiredDuringScheduling)
- **SOFT** = Prefers this node but can run elsewhere (preferredDuringScheduling)
- **DaemonSet** = Runs one pod on EVERY node automatically (used for monitoring agents)

**Note on Beszel Agents:** The beszel-agent is deployed as a DaemonSet, which means Kubernetes automatically ensures exactly one agent runs on each node to collect metrics. When you add new nodes, agents are automatically deployed to them.

### Node Labels

| Node | Labels | Purpose |
|------|--------|---------|
| Pi 4 #1 | `node-role.kubernetes.io/control-plane=true` | HA control plane node #1 + lightweight services |
| Pi 4 #2 | `node-role.kubernetes.io/control-plane=true`, `zigbee=true` | HA control plane node #2 + Zigbee worker |
| Pi 5 | `node-role.kubernetes.io/control-plane=true`, `storage=true`, `storage-type=hdd` | HA control plane node #3 + storage worker (HDD only) |

## Design Decisions

### Why This Architecture?

**Pi 5 as Storage Node:**
- **HDD mount** (`/mnt/hd1`) for immich photo library storage
- 8GB RAM perfect for immich-ml (machine learning is memory-hungry)
- Faster CPU for image processing and ML inference
- PostgreSQL + Redis use K3s default local-path storage (faster SD card/storage on Pi 5)

**3-Node HA Control Plane:**
- All 3 nodes run k3s server with embedded etcd
- etcd quorum requires 2 of 3 nodes (fault tolerance of 1 node)
- Automatic API server leader election
- Cluster remains manageable even when 1 control plane node is down
- Each node also runs workloads (not dedicated control plane)

**Workload Distribution:**
- **Pi 4 #1**: Lightest workloads (nginx, pihole, beszel hub)
- **Pi 4 #2**: Medium workloads (Home Assistant + replicas)
- **Pi 5**: Heaviest workloads (Immich suite, databases)

### K3s vs K8s

Using **K3s** (lightweight Kubernetes) because:
- Built-in containerd (no Docker needed)
- Lower memory footprint (~700MB for server vs 2GB+ for full k8s)
- Optimized for ARM/edge devices
- **Embedded etcd** for HA control plane (no external etcd needed)
- Perfect for Raspberry Pi clusters
- Supports multi-server HA out of the box

### Storage Strategy

**Two Storage Types:**

1. **local-path** (K3s default storage)
   - PostgreSQL databases (on Pi 5)
   - Redis cache (on Pi 5)
   - Application state
   - Uses `/var/lib/rancher/k3s/storage` on each node

2. **local-hdd** (Bulk storage on Pi 5 via hostPath)
   - Immich photo library
   - FileBrowser user files
   - Backup staging

**Directory Structure on Pi 5:**
```
/mnt/hd1/
├── Library/         → immich photos (hostPath PV)
├── Files/           → filebrowser files (hostPath PV)
└── backups/         → local backup staging

/var/lib/rancher/k3s/storage/
├── postgres-pv-*/   → immich database (local-path)
├── redis-pv-*/      → redis cache (local-path)
└── ...              → other dynamic PVs
```

### High Availability Approach

**Stateless Services (HA enabled):**
- **nginx-proxy-manager**: 2 replicas across Pi 4 nodes
- **pihole**: 2 replicas across Pi 4 nodes
- Uses MetalLB for LoadBalancer IPs
- Automatic failover if a node goes down

**Stateful Services (Single instance with node affinity):**
- **immich**: Pinned to Pi 5 (requires fast storage)
- **home-assistant**: Pinned to Pi 4 #2 (requires USB Zigbee adapter)
- **postgres**: Pinned to Pi 5

**Why not full HA for databases?**
- PostgreSQL multi-master setup is complex and resource-intensive
- 4GB RAM nodes insufficient for database replication overhead
- Instead: rely on frequent backups via Restic
- Restoration from backup is acceptable for homelab use case

## Network Architecture

### MetalLB LoadBalancer IPs

| Service | IP | Replicas | Ports |
|---------|-----|----------|-------|
| nginx-proxy-manager | 10.0.0.100 | 2 | 80, 443, 81 |
| pihole | 10.0.0.53 | 2 | 53/tcp, 53/udp, 80 |
| immich | 10.0.0.101 | 1 | 2283 |
| home-assistant | 10.0.0.102 | 1 | 8123 |
| filebrowser | 10.0.0.103 | 1 | 8081 |
| beszel | 10.0.0.104 | 1 | 8090 |

### DNS Configuration

- Pi-hole runs as primary/secondary DNS (HA across 2 nodes)
- Configure router to use `10.0.0.53` as DNS server
- Local domains (*.home) resolved via Pi-hole
- SSL termination handled by cert-manager + nginx

### SSL/TLS Strategy

- **cert-manager** for certificate management
- Migrate existing mkcert certificates or use Let's Encrypt
- nginx-proxy-manager handles SSL termination
- Internal cluster traffic can be plaintext (mTLS optional)

## Resource Allocation

### Pi 4 #1 (Control Plane) - 4GB RAM

| Component | Memory | CPU |
|-----------|--------|-----|
| k3s server | 500MB | 0.5 |
| nginx-proxy | 200MB | 0.1 |
| pihole | 300MB | 0.1 |
| beszel | 100MB | 0.1 |
| **Total** | **~1.1GB** | **0.8** |
| **Headroom** | **2.9GB** | **3.2** |

### Pi 4 #2 (Zigbee) - 4GB RAM

| Component | Memory | CPU |
|-----------|--------|-----|
| k3s agent | 200MB | 0.3 |
| home-assistant | 800MB | 0.5 |
| nginx-proxy (replica) | 200MB | 0.1 |
| pihole (replica) | 300MB | 0.1 |
| **Total** | **~1.5GB** | **1.0** |
| **Headroom** | **2.5GB** | **3.0** |

### Pi 5 (Storage) - 8GB RAM

| Component | Memory | CPU |
|-----------|--------|-----|
| k3s agent | 200MB | 0.3 |
| immich-server | 1GB | 1.0 |
| immich-ml | 2GB | 2.0 |
| immich-postgres | 500MB | 0.5 |
| redis | 200MB | 0.1 |
| filebrowser | 100MB | 0.1 |
| **Total** | **~4GB** | **4.0** |
| **Headroom** | **4GB** | **0.0** |

## Service Migration Strategy

### Migration Order (Lowest to Highest Risk)

1. **Beszel** - Simplest, good test case
2. **FileBrowser** - Requires storage node affinity
3. **Nginx Proxy Manager** - Can run alongside existing
4. **Pi-hole** - DNS critical, test thoroughly before cutover
5. **Immich** - Largest data migration, most complex
6. **Home Assistant** - Requires USB device mapping
7. **Restic** - Convert to Kubernetes CronJob

### Node Affinity Requirements

**Home Assistant** (USB Zigbee adapter):
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: zigbee
          operator: In
          values:
          - "true"
```

**Immich + FileBrowser** (HDD storage requirements):
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: storage-type
          operator: In
          values:
          - "hdd"
```

## Backup Strategy

### Restic Backup

- Runs as Kubernetes **CronJob** (monthly schedule)
- Backs up to Backblaze B2 (S3-compatible storage)
- Source: `/mnt/hd1` (photo library + user files)
- Encryption: Restic built-in (password required for restore)
- Retention policy:
  - Last 3 backups
  - Last 7 daily snapshots
  - Last 4 weekly snapshots
  - Last 6 monthly snapshots

### Database Backups

- **PostgreSQL**: pg_dump run daily via CronJob
- Stored on sd card locally + synced to Restic backup
- Enables point-in-time recovery for Immich

## Infrastructure Components

### Core Cluster Components

1. **MetalLB** - LoadBalancer implementation for bare-metal
2. **cert-manager** - SSL certificate management
3. **sealed-secrets** - Encrypted secret management in Git

### Monitoring & Observability

- **Beszel** - Lightweight system monitoring (existing)

## Security Considerations

### Network Security

- Firewall rules (UFW) on each node
- Allow only necessary ports between nodes
- Restrict external access to LoadBalancer IPs
- Tailscale VPN for remote access

### Secrets Management

- **sealed-secrets** for GitOps-friendly secret storage
- Encrypt secrets before committing to Git
- Store unsealing key securely (separate from repo)

### Pod Security

- Run containers as non-root where possible
- ReadOnlyRootFilesystem for stateless services
- Resource limits to prevent resource exhaustion
- Network policies to restrict inter-pod communication (future)

## Disaster Recovery

### Node Failure Scenarios

**Pi 4 #1 (Control Plane) Failure:**
- Cluster API unavailable (can't schedule new pods)
- Existing workloads continue running
- Recovery: Restore from k3s backup or rebuild control plane

**Pi 4 #2 (Zigbee) Failure:**
- Home Assistant down (no HA possible with USB device)
- nginx/pihole failover to Pi 4 #1 automatically
- Recovery: Fix node and let pods reschedule

**Pi 5 (Storage) Failure:**
- Immich and FileBrowser down (no HA due to local storage)
- Recovery: Fix node, restore from Restic backup if needed

### Data Recovery

1. **Immich photos**: Restore from Restic backup
2. **PostgreSQL**: Restore from daily pg_dump backups
3. **Home Assistant config**: Git-tracked (can redeploy)
4. **Secrets**: Restore from sealed-secrets backup

## Future Enhancements

### Potential Improvements

1. **Longhorn** for distributed storage (HA for databases)
2. **Network policies** for pod-to-pod security
3. **Horizontal Pod Autoscaling** (HPA) for services

### Scaling Considerations

- Add more Pi 4/5 nodes for additional capacity
- Move to external NAS for shared storage
- Use external etcd cluster for control plane HA

## References

- [K3s Documentation](https://docs.k3s.io/)
- [MetalLB Configuration](https://metallb.universe.tf/)
- [cert-manager Docs](https://cert-manager.io/docs/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [Helm Charts Best Practices](https://helm.sh/docs/chart_best_practices/)
