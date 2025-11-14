# homelab-k8s ☸️

A 4-node HA Kubernetes cluster on Raspberry Pi hardware running self-hosted services with automated backups.

## features 🚀
1. highly-available pods (for the most part 😅)
2. dns server w/ ad-blocking via pihole
3. graceful shutdown in the event of a power outage
> my setup is a bit scuffed because my UPS does not have a direct connection to monitor its status, so instead I plugged the UPS into a smart plug and read off of that (see charts/power-monitor) to coordinate the shutdown of nodes

## hardware ⚙️

- `pi4-01` (4GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + lightweight services
- `pi4-02` (4GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + Zigbee worker (Home Assistant)
- `pi5-01` (8GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + storage worker with HDD
- `pi5-02` (8GB RAM w/ [PoE+ Hat](https://www.raspberrypi.com/products/poe-plus-hat/)): Control plane + [NUT-like server](https://networkupstools.org/index.html)

Case: [DeskPi T1 Rackmate](https://deskpi.com/products/deskpi-rackmate-t1-2)

Pi Mount: [DeskPi 2U Rack Mount](https://deskpi.com/products/deskpi-rackmate-10-inch-2u-rack-mount-with-pcie-nvme-board-for-raspberry-pi-5-4b)

Network Switch: [TP-Link 8-Port Gigabit Easy Smart Switch with 4-Port PoE+](https://www.tp-link.com/us/business-networking/poe-switch/tl-sg108pe/)

Uninterruptible Power Supply (UPS): [Tripp Lite Standby UPS](https://tripplite.eaton.com/standby-ups-600va-300w-4-outlets-120v-energy-star~BC600R)

## architecture 🗺️

<img src="docs/homelab.svg" width="100%" style="max-width: 800px;" />
<br/>

**services:**
- **immich** - Photo management (10.0.0.101 / https://img.home)
- **homeassistant** - Home automation with Zigbee (10.0.0.102 / https://assistant.home)
- **pihole** - DNS + ad blocking (10.0.0.53 / https://pi.home)
- **filebrowser** - Web file manager (10.0.0.103 / https://files.home)

**infra:**
- **nginx** - Reverse proxy with TLS (10.0.0.200)
- **metallb** - LoadBalancer implementation
- **cert-manager** - Automatic TLS certificates
- **sealed-secrets** - Encrypted secrets in Git
- **restic** - Monthly backups to Backblaze B2

**monitoring:**
- **prometheus** - Metrics collection and time-series database
- **grafana** - Dashboards and visualization (https://grafana.home)
- **loki** - Log aggregation and querying
- **alloy** - Log and metrics collection agent

<img src="docs/grafana-dashboard.png" width="100%" style="max-width: 800px;" />
<br/>

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

sudo -E rpi-eeprom-config --edit
# set BOOT_ORDER=0x1 (sd card only)

# Pi 5 #2 (control plane + NUT)
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<pi4-1-ip>:6443 --token <TOKEN> \
  --disable traefik \
  --disable servicelb
```

### 2. tool setup 🛠️

```bash
make setup-repos         # Add Helm repos
make build-deps          # Build chart dependencies
make install-infra       # Install MetalLB, cert-manager, nginx-ingress, etc.
make install-monitoring  # Install Prometheus, Grafana, Loki, Alloy
make deploy-all          # Deploy all application services
```

**Or install everything at once:**
```bash
make install-all  # Runs all setup commands sequentially
```

## troubleshooting 🕵️

- **Pods pending:** Check PVC status (`kubectl get pvc`), node labels, and resources
- **LoadBalancer pending:** Verify MetalLB is running and has available IPs
- **Ingress 404:** Ensure cert-manager has issued certificates and ingress rules are correct
- **Grafana not loading:** Check ingress and TLS certificate: `kubectl get ingress -n monitoring`
- **Missing metrics:** Verify ServiceMonitors exist: `kubectl get servicemonitor -n monitoring`
- **NFS mount issues:** Check NFS server exports and client packages on all nodes