# homelab-k8s ☸️

A 3-node HA Kubernetes cluster on Raspberry Pi hardware running self-hosted services with automated backups.

## hardware ⚙️

- **Pi 4 #1 (4GB)**: Control plane + lightweight services
- **Pi 4 #2 (4GB)**: Control plane + Zigbee worker (Home Assistant)
- **Pi 5 (8GB)**: Control plane + storage worker with HDD

## architecture 🗺️

**Services:**
- **Immich** - Photo management (10.0.0.101 / https://img.home)
- **Home Assistant** - Home automation with Zigbee (10.0.0.102 / https://assistant.home)
- **Pi-hole** - DNS + ad blocking (10.0.0.53 / https://pi.home)
- **FileBrowser** - Web file manager (10.0.0.103 / https://files.home)
- **Beszel** - System monitoring (10.0.0.104 / https://beszel.home)
- **Dozzle** - Container log viewer (https://dozzle.home)

**Infrastructure:**
- **NGINX Ingress** - Reverse proxy with TLS (10.0.0.200)
- **MetalLB** - LoadBalancer implementation
- **cert-manager** - Automatic TLS certificates
- **sealed-secrets** - Encrypted secrets in Git
- **NFS provisioner** - Shared storage from Pi 5 HDD
- **Restic** - Monthly backups to Backblaze B2

## getting started ✅

### 1. k3s cluster setup

```bash
# Pi 4 #1 (first control plane)
curl -sfL https://get.k3s.io | sh -s - server --cluster-init --disable traefik
sudo cat /var/lib/rancher/k3s/server/node-token  # Get token for other nodes

# Pi 4 #2 (control plane + Zigbee)
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 --token <token> \
  --disable traefik --node-label zigbee=true

# Pi 5 (control plane + storage) - Mount HDD at /mnt/hd1 first
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 --token <token> \
  --disable traefik --node-label storage=true
```

### 2. tool setup 🛠️

```bash
make setup-repos      # Add Helm repos
make build-deps       # Build chart dependencies
make install-infra    # Install MetalLB, cert-manager, nginx-ingress, etc.
```

**Note:** NFS provisioner requires manual setup on Pi 5 before running `make install-infra`. See [NFS Setup](#nfs-storage-setup).

### 3. configure dns 🌳

- point your router's DNS to `10.0.0.202` (Pi-hole) for `.home` domain resolution and ad blocking
- or, set your devices to use `10.0.0.202` as a custom dns server

## 4. nfs server setup 🗄️

On **Pi 5** (before running `make install-infra`):

```bash
# Install NFS server
sudo apt update && sudo apt install nfs-kernel-server -y

# Configure export
echo "/mnt/hd1    10.0.0.0/24(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -ra && sudo systemctl restart nfs-kernel-server

# Install NFS clients on Pi 4 nodes
sudo apt install nfs-common -y

# Then install NFS provisioner
helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  -f charts/nfs-provisioner/values.yaml -n kube-system
```

**Restore:** See [charts/restic-backup/](charts/restic-backup/) for restore instructions.

## troubleshooting 🕵️

- **Pods pending:** Check PVC status (`kubectl get pvc`), node labels, and resources
- **LoadBalancer pending:** Verify MetalLB is running and has available IPs
- **Ingress 404:** Ensure cert-manager has issued certificates and ingress rules are correct
- **NFS mount issues:** Check NFS server exports and client packages on all nodes