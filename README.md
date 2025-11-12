# homelab-k8s ☸️

A 3-node HA Kubernetes cluster on Raspberry Pi hardware running self-hosted services with automated backups.

## features 🚀
1. high-availability via redundancy
2. 

## hardware ⚙️

- `pi4-01` (4GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + lightweight services
- `pi4-02` (4GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + Zigbee worker (Home Assistant)
- `pi5-01` (8GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + storage worker with HDD

<!-- - `pi5-02` (8GB RAM): Control plane/[NUT server](https://networkupstools.org/index.html) -->

Case: [DeskPi T1 Rackmate](https://deskpi.com/products/deskpi-rackmate-t1-2)

Pi Mount: [DeskPi 2U Rack Mount](https://deskpi.com/products/deskpi-rackmate-10-inch-2u-rack-mount-with-pcie-nvme-board-for-raspberry-pi-5-4b)

Uninterruptible Power Supply (UPS): [Tripp Lite Standby UPS](https://tripplite.eaton.com/standby-ups-600va-300w-4-outlets-120v-energy-star~BC600R)

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
  --disable traefik --disable servicelb --node-label zigbee=true

# Pi 5 #1 (control plane + storage) - Mount HDD at /mnt/hd1 first
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 --token <token> \
  --disable traefik --disable servicelb --node-label storage=true

# Pi 5 #2 (control plane + NUT)
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 --token <TOKEN> \
  --disable traefik \
  --disable servicelb

```

### 2. tool setup 🛠️

```bash
make setup-repos      # Add Helm repos
make build-deps       # Build chart dependencies
make install-infra    # Install MetalLB, cert-manager, nginx-ingress, etc.
```

### 3. configure dns 🌳

- point your router's DNS to `10.0.0.202` (Pi-hole) for `.home` domain resolution and ad blocking
- or, set your devices to use `10.0.0.202` as a custom dns server

### 4. restore from backup 🔄

**Restore:** See [charts/restic-backup/](charts/restic-backup/) for restore instructions.

## troubleshooting 🕵️

- **Pods pending:** Check PVC status (`kubectl get pvc`), node labels, and resources
- **LoadBalancer pending:** Verify MetalLB is running and has available IPs
- **Ingress 404:** Ensure cert-manager has issued certificates and ingress rules are correct
- **NFS mount issues:** Check NFS server exports and client packages on all nodes