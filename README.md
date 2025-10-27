# Homelab Kubernetes

A highly available Kubernetes (K3s) homelab cluster running on Raspberry Pi hardware, featuring self-hosted services including Immich, Home Assistant, Pi-hole, and more.

## Overview

This repository contains Helm charts and configuration for migrating from a single-Pi Docker setup to a 3-node Kubernetes cluster with high availability where possible.

### Hardware

- **Pi 4 #1 (4GB)**: Control plane + lightweight services
- **Pi 4 #2 (4GB)**: Control plane + Zigbee worker (Home Assistant)
- **Pi 5 (8GB)**: Control plane + storage worker with HDD

## Quick Start

### Prerequisites

1. Three Raspberry Pi devices (2x Pi 4 4GB, 1x Pi 5 8GB)
2. Raspberry Pi OS Lite (64-bit) installed on all nodes
3. Network connectivity between all nodes
4. External HDD mounted on Pi 5
5. USB Zigbee adapter connected to Pi 4 #2

### Installation

#### 1. K3s Cluster Setup

**Install control plane nodes sequentially (wait for each to complete before proceeding):**

On **Pi 4 #1** (first control plane node):
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable traefik \
  --tls-san <pi4-1-ip> \
  --tls-san <pi4-2-ip> \
  --tls-san <pi5-ip>

# Get the node token for additional servers
sudo cat /var/lib/rancher/k3s/server/node-token
```

On **Pi 4 #2** (second control plane node + zigbee worker):
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 \
  --token <token-from-pi4-1> \
  --disable traefik \
  --node-label zigbee=true
```

On **Pi 5** (third control plane node + storage worker):
```bash
# look for hdd (usually /dev/sda, /dev/sdb, etc.)
sudo fdisk -l

sudo mkdir -p /mnt/hd1

sudo mount /dev/sdX1 /mnt/hd1

# add entry to fstab so it mounts on boot
sudo blkid /dev/sdX1

sudo vi /etc/fstab
UUID=your-uuid-here /mnt/hd1 ext4 defaults 0 2
```

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 \
  --token <token-from-pi4-1> \
  --disable traefik \
  --node-label storage=true
  --node-label storage-type=hdd
```

**HA Benefits:**
- ✅ Cluster survives any single node failure
- ✅ etcd quorum maintained with 2 of 3 control plane nodes
- ✅ Can still deploy/manage workloads when 1 node is down

#### 2. Install Infrastructure Components

```bash
# Add Helm repositories
helm repo add metallb https://metallb.github.io/metallb
helm repo add jetstack https://charts.jetstack.io
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# Build chart dependencies
helm dependency build ./charts/metallb
helm dependency build ./charts/cert-manager
helm dependency build ./charts/sealed-secrets

helm install metallb ./charts/metallb --create-namespace --namespace metallb-system # dedicated namespaces, best practice
helm install cert-manager ./charts/cert-manager --create-namespace --namespace cert-manager
helm install sealed-secrets ./charts/sealed-secrets --namespace kube-system # kube-system is fine for this simple controller
```

#### 3. Storage Setup

```bash
# K3s comes with local-path storage provisioner by default
kubectl get storageclass
# Should see: local-path (default)

# install nfs server
sudo apt update
sudo apt install nfs-kernel-server -y

# configure NFS export for the entire drive
sudo vi /etc/exports

# Add:
/mnt/hd1    10.0.0.0/24(rw,sync,no_subtree_check,no_root_squash)

# apply and restart
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server

# add to helm repo
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    -f charts/nfs-provisioner/values.yaml \
    -n kube-system

# install nfs clients on the other pis
sudo apt-get update && sudo apt-get install -y nfs-common
```

#### 4. Deploy Services

```bash
helm install beszel ./charts/beszel
helm install pihole ./charts/pihole
helm install nginx-proxy-manager ./charts/nginx-proxy-manager
helm install filebrowser ./charts/filebrowser
helm install home-assistant ./charts/home-assistant
helm install immich ./charts/immich
helm install restic-backup ./charts/restic-backup
```

## Configuration

### Secrets Management

Before deploying, you'll need to configure secrets for each service:

1. **Immich**: Database password, JWT secret
2. **Pi-hole**: Web admin password
3. **Restic**: Backblaze B2 credentials

#### Option 1: Direct Secrets (Development)

Create secrets manually:
```bash
kubectl create secret generic immich-secrets \
  --from-literal=DB_PASSWORD='your-password' \
  --from-literal=JWT_SECRET='your-jwt-secret'

kubectl create secret generic pihole-secrets \
  --from-literal=WEBPASSWORD='your-password'

kubectl create secret generic restic-b2-secrets \
  --from-literal=AWS_ACCESS_KEY_ID='your-key-id' \
  --from-literal=AWS_SECRET_ACCESS_KEY='your-secret-key' \
  --from-literal=RESTIC_REPOSITORY='s3:s3.us-west-004.backblazeb2.com/bucket-name' \
  --from-literal=RESTIC_PASSWORD='your-encryption-password'
```

#### Option 2: Sealed Secrets (Production)

Use sealed-secrets for GitOps-friendly secret management:
```bash
# Install kubeseal CLI
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/kubeseal-0.27.1-linux-arm64.tar.gz
tar xfz kubeseal-0.27.1-linux-arm64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# Create and seal a secret
kubectl create secret generic immich-secrets \
  --from-literal=DB_PASSWORD='your-password' \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > values/immich-sealed-secret.yaml

# Apply sealed secret
kubectl apply -f values/immich-sealed-secret.yaml
```

### Custom Values

Override default values for each chart:

```bash
# Create custom values file
cat > values/production.yaml <<EOF
# Add custom configuration here
EOF

# Install with custom values
helm install immich ./charts/immich -f values/production.yaml
```

## Data Migration

### Migrating from Docker

1. **Backup existing data** on current Pi
2. **Copy data to new cluster**:
   - Immich photos: Copy to `/mnt/hd1/Library` on Pi 5
   - Home Assistant config: Copy to PVC or use Git
   - Pi-hole config: Export Teleporter backup, import after deployment
   - FileBrowser files: Copy to `/mnt/hd1/Files` on Pi 5

3. **Import databases**:
```bash
# Immich PostgreSQL
kubectl exec -it immich-postgres-<pod-id> -- psql -U postgres immich < backup.sql
```

## Monitoring

Access service dashboards:

- **Nginx Proxy Manager**: http://10.0.0.100:81 or https://nginx.home
- **Pi-hole**: http://10.0.0.53 or https://pi.home
- **Immich**: http://10.0.0.101:2283 or https://img.home
- **Home Assistant**: http://10.0.0.102:8123 or https://homeassistant.home
- **FileBrowser**: http://10.0.0.103 or https://files.home
- **Beszel**: http://10.0.0.104:8090 or https://beszel.home

Configure your router to use `10.0.0.53` as the primary DNS server for local domain resolution.

## Backup & Recovery

### Automated Backups

Restic runs monthly backups to Backblaze B2. Check status:
```bash
kubectl get cronjobs
kubectl logs -l app=restic-backup
```

### Manual Backup

```bash
kubectl create job --from=cronjob/restic-backup restic-manual-backup
```

### Restore from Backup

```bash
# Create a restore pod
kubectl run restic-restore --rm -it --image=restic/restic \
  --env-from=secret/restic-b2-secrets \
  --overrides='{"spec":{"nodeSelector":{"storage":"true"}}}' \
  -- sh

# Inside the pod
restic snapshots
restic restore latest --target /restore
```

## Troubleshooting

### Check Cluster Status

```bash
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get svc --all-namespaces
```

### Check Service Logs

```bash
kubectl logs -l app=immich -c immich-server
kubectl logs -l app=home-assistant
kubectl logs -l app=pihole
```

### Verify Node Affinity

```bash
# Check if pods are on correct nodes
kubectl get pods -o wide

# Check node labels
kubectl get nodes --show-labels
```

### Common Issues

**Pod stuck in Pending:**
- Check PVC binding: `kubectl get pvc`
- Check node affinity: `kubectl describe pod <pod-name>`
- Check resources: `kubectl describe node <node-name>`

**LoadBalancer stuck in Pending:**
- Verify MetalLB is running: `kubectl get pods -n metallb-system`
- Check IP pool configuration: `kubectl get ipaddresspool -n metallb-system`

**Storage issues:**
- Verify mounts on nodes: `df -h`
- Check PV/PVC status: `kubectl get pv,pvc`

## Maintenance

### Updating Services

```bash
# Update image tags in values.yaml
helm upgrade immich ./charts/immich
```

### Scaling Services

```bash
# Scale nginx replicas
helm upgrade nginx-proxy-manager ./charts/nginx-proxy-manager \
  --set replicaCount=3
```

### Draining a Node

```bash
kubectl cordon pi5-01
kubectl drain pi5-01 --ignore-daemonsets --delete-emptydir-data

# do your stuff

kubectl uncordon <node-name>
```

## References

- [K3s Documentation](https://docs.k3s.io/)
- [Helm Documentation](https://helm.sh/docs/)
- [Immich](https://immich.app)
- [Home Assistant](https://www.home-assistant.io)
- [Pi-hole](https://pi-hole.net)
- [Restic](https://restic.net)