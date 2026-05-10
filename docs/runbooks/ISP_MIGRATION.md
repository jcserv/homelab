# ISP_MIGRATION

For migrating to a new ISP and/or router. The current target is Beanfield 8 Gbps fiber with the supplied Nokia Beacon WiFi 7 router. The cluster lives on `10.2.1.0/24` and has 50+ references to `10.2.1.x` across charts, runbooks, scripts, and external systems — the goal of this runbook is "swap day is purely physical, plus at most one config-file edit if the LAN subnet has to change."

This runbook covers the Beanfield/Nokia case but the procedure generalizes. Pair it with `POWER_OUTAGE.md` for the cluster shutdown/startup sequence.

## Cluster topology (current)

| Node   | IP         | Notes                                       |
| ------ | ---------- | ------------------------------------------- |
| pi4-01 | 10.2.1.54  |                                             |
| pi4-02 | 10.2.1.160 | `zigbee=true` (Home Assistant USB)          |
| pi5-01 | 10.2.1.28  | `storage=true` (Immich ML)                  |
| pi5-02 | 10.2.1.156 |                                             |
| NAS    | 10.2.1.147 | UGREEN — Immich NFS + media stack           |
| LB     | 10.2.1.200 | nginx-ingress LoadBalancer                  |
| LB     | 10.2.1.202 | pihole DNS LoadBalancer                     |
| Pool   | 10.2.1.200-210 | MetalLB pool                            |

Single source of truth for all of this: `values/network.yaml`.

## Pre-flight (before swap day)

Confirm the following with Beanfield support and via the Nokia Beacon admin UI before scheduling the cutover. If any answer is "no," route to Path B (replace UCG-Fiber) or Path C (subnet renumber) below.

1. **Bridge mode availability** — can the Nokia Beacon run in bridge / pass-through mode so the existing Unifi UCG-Fiber stays the LAN router? Beanfield has historically required a support ticket to enable this; confirm in advance.
2. **WAN handoff method** — PPPoE, DHCP, or static? If PPPoE, the UCG-Fiber needs the credentials configured before swap day.
3. **Custom LAN subnet support** — if Nokia routes the LAN, can it be set to `10.2.1.0/24`? The default is usually `192.168.1.0/24` or `192.168.86.0/24`. If the Beacon does not allow custom subnets, you must use bridge mode (Path A) or accept a renumber (Path C).
4. **DHCP reservation support** — capacity for ~10 reservations (4 Pis + NAS + a few clients). Alternative: static IPs on each Pi via `/etc/dhcpcd.conf` or `/etc/netplan`.
5. **DNS server override** — does the router's DHCP let you push a custom DNS (10.2.1.202 / pihole)? If not, every client device will need manual DNS config or pihole loses its purpose.
6. **MetalLB pool exclusion** — the DHCP pool **must not** overlap `10.2.1.200-210`. The MetalLB pool needs to be statically allocated outside of DHCP.
7. **8 Gbps WAN** — verify the UCG-Fiber's WAN port can handle 8 Gbps (the UCG-Fiber's WAN is 10 GbE, so this is fine, but worth a sanity check on cable + SFP).

## Architecture decision tree

Pick a path based on the pre-flight answers.

### Path A — Bridge mode, keep UCG-Fiber (preferred)

Nokia Beacon is a dumb modem; UCG-Fiber stays the router. LAN configuration is unchanged. **Zero chart changes, zero `values/network.yaml` edits.** Swap day is a 5-minute physical operation.

Trade-off: WiFi 7 from the Beacon is unused (the UCG-Fiber drives existing UAPs). If you want WiFi 7, add the Beacon as a downstream AP on the existing LAN.

### Path B — Nokia routes everything, same subnet

Nokia replaces the UCG-Fiber. LAN is configured as `10.2.1.0/24` on the Nokia. DHCP reservations and pool exclusion replicated. **Zero chart changes** as long as `10.2.1.0/24` is preserved. Loss of UCG-Fiber features (Unifi UI, IDS/IPS, advanced firewall rules — back up the Unifi config first).

### Path C — Subnet renumber

Nokia (or new router) cannot host `10.2.1.0/24`. Pick a new subnet (e.g. `192.168.10.0/24`) and:

1. Edit `values/network.yaml` — replace every `10.2.1.x` with the new equivalent.
2. Push to a feature branch and verify with `helm template charts/<chart> -f values/network.yaml` for each affected chart.
3. Update Pi node static IPs (see `/etc/dhcpcd.conf` on each Pi) and reboot one at a time, watching for quorum.
4. Update SSH config + kubeconfig (see "External dependencies" below).
5. Merge to `main` — CI redeploys all charts in one batch.
6. Restart MetalLB speaker DaemonSet so it picks up the new pool: `kubectl rollout restart ds -n metallb-system`.

This path is doable in a single day but is the highest-risk option. Schedule a 4-hour maintenance window.

## Cutover procedure

1. **Pre-flight checklist** — all items in "Pre-flight" above are answered. Path selected.
2. **Backups** — run the same backup jobs as `POWER_OUTAGE.md` step 2:

   ```bash
   kubectl create job --from=cronjob/immich-db-backup immich-db-backup-preisp -n default
   kubectl create job --from=cronjob/authentik-backup authentik-backup-preisp -n default
   make backup
   ```

3. **Snapshot Unifi config** — `Settings → System → Backups → Download Backup` (UCG-Fiber UI). Keep the file off-site.
4. **Cluster power-down** — follow `POWER_OUTAGE.md` "Power-down" section steps 1–7. (Skip step 1 — DNS auto-DNS is irrelevant here since we're swapping the router that hands out DNS).
5. **Physical swap**:
   - Disconnect old ISP equipment.
   - Connect Beanfield ONT/Nokia Beacon. If Path A: connect Nokia → UCG-Fiber WAN port. If Path B/C: connect Nokia LAN → switch.
   - Power on Nokia, wait for WAN sync (LEDs solid).
6. **Router config** (Path B/C only):
   - Configure LAN subnet, DHCP pool (excluding 10.2.1.200-210), DHCP reservations for Pis + NAS, DNS override to pihole.
   - Verify via a laptop on the LAN: `ping 10.2.1.1` (gateway), `nslookup google.com` (resolution).
7. **`values/network.yaml` edit** (Path C only) — apply the renumber edit on a branch, push, watch CI.
8. **Cluster power-up** — follow `POWER_OUTAGE.md` "Power-up" section steps 1–6. After NAS is up:
   - For Path C: SSH each Pi via its **new** IP and verify k3s came up clean.
9. **Post-cutover verification** — see next section.

## Post-cutover verification

Run all of these. Anything red is a blocker.

```bash
# Cluster healthy
kubectl get nodes                               # all 4 Ready
kubectl get pods -A | grep -v Running | grep -v Completed   # should be empty

# LoadBalancer IPs assigned and reachable
kubectl get svc -A | grep LoadBalancer
ping 10.2.1.200                                 # nginx-ingress (or new IP)
ping 10.2.1.202                                 # pihole

# Pi-hole DNS responding
dig @10.2.1.202 google.com +short
dig @10.2.1.202 pi.jarrodservilla.com +short

# cert-manager still healthy (existing certs valid; renewal works)
kubectl get certificate -A
kubectl describe clusterissuer letsencrypt-prod | tail -20

# Tailscale CI deploys still working — push a no-op commit to a feature
# branch and confirm CI lint passes; merge a trivial chart change to main
# and confirm the deploy job reaches the cluster.

# NAS NFS mounts (immich, restic-backup)
kubectl get pv | grep nfs
kubectl logs -l app=immich-server -n default --tail=20

# External access (off-LAN, e.g. from phone on cellular)
curl -I https://img.jarrodservilla.com         # 200 or 401
curl -I https://homeassistant.jarrodservilla.com
```

If any check fails, see `POWER_OUTAGE.md` troubleshooting, or roll back via Unifi backup restore + `git revert` of the `values/network.yaml` edit (Path C).

## External dependencies

These references live outside this repository. They were audited on 2026-05-07 against `10.2.1.x`. On a renumber (Path C), each one needs manual update **after** the cluster is reachable on the new IPs.

| Reference | Path / source | Current value | Notes |
| --- | --- | --- | --- |
| Local kubeconfig server URL | `~/.kube/config` `clusters[].cluster.server` | `https://10.2.1.54:6443` | Hardcoded to pi4-01. **Will break on renumber.** Consider switching to a Tailscale name (e.g. `https://pi4-01:6443` resolved via Tailscale MagicDNS) for resilience. |
| Local SSH config | `~/.ssh/config` | `pi4-01 → 10.2.1.54`, `pi4-02 → 10.2.1.160`, `pi5-01 → 10.2.1.28`, `pi5-02 → 10.2.1.156`, `nas → 10.2.1.147` | Each entry is `HostName <ip>`. Update all 5 on renumber, or switch `HostName` to Tailscale machine names. |
| GitHub Actions `KUBE_CONFIG` secret | Repo secret (consumed at `ci.yml:127`) | base64 of kubeconfig | Same problem as local kubeconfig — if its server URL is an IP, the secret needs rotation. Rotate via `kubectl config view --raw \| base64 \| gh secret set KUBE_CONFIG`. |
| Tailscale subnet route | `tailscale up --advertise-routes=10.2.1.0/24` (run on a node, current state unknown — Tailscale was stopped on the workstation at audit time) | Possibly advertised by one of the Pis | If a Pi advertises `10.2.1.0/24` to Tailscale, the route advertisement needs to change to the new subnet. Check with `tailscale status --peers` on each node (SSH in). |
| NAS Docker compose | `docker/media-stack.yml:15`, `docker/media-stack.example.yml:15` | `FIREWALL_OUTBOUND_SUBNETS=10.2.1.0/24,10.42.0.0/16` | Gluetun firewall whitelist. Lives on the NAS itself, not in k8s. Update + `docker compose up -d` on the NAS post-renumber. |
| Pi-hole check script | `scripts/pihole-check.sh:9` | `PIHOLE_LB="10.2.1.202"` | Standalone diagnostic script. Update if pihole LB IP changes. |
| Blackbox exporter probe target | `charts/prometheus-blackbox-exporter/values.yaml:148` | `url: 10.2.1.202:53` | Pi-hole DNS probe. Not centralized in `values/network.yaml` (overriding requires duplicating the full 17-target list). Edit in place if pihole LB changes. |
| POWER_OUTAGE runbook | `docs/runbooks/POWER_OUTAGE.md` | Node IPs + DNS server reference | Documentation only; update for accuracy after renumber. |
| SECURITY runbook | `docs/runbooks/../SECURITY.md` (and any UFW rules already applied to nodes) | `10.2.1.0/24` in three `ufw` rule examples | If UFW rules were applied to nodes, they need re-applying with the new CIDR. |
| README + CLAUDE.md | `README.md:42,47`, `CLAUDE.md:54,67` | Mentions of `10.2.1.200`, `10.2.1.202`, `10.2.1.147` | Documentation only. |
| Unifi UCG-Fiber DNS override | Unifi UI → Network → DHCP → DNS Server | `10.2.1.202` | Set per-network (e.g. "Trusted VLAN"). Update post-renumber. |
| Pi node static IPs | `/etc/dhcpcd.conf` on each Pi (k3s does not auto-update on IP change) | One static block per node | On renumber, edit + reboot each node one at a time, watching etcd quorum. |
| CoreDNS configmap (optional check) | `kubectl get configmap -n kube-system coredns -o yaml` | Verify no forwarder pointing at `10.2.1.x` (typically forwards to `/etc/resolv.conf` upstream, which uses node DNS) | Run pre-cutover to be sure. |

**Not in scope of this audit but worth a sanity check pre-cutover:**
- Grafana data sources (`kubectl get configmap -n monitoring -o yaml \| grep -E "(datasource\|10\.2)"`) — Prometheus + Loki are referenced by service DNS, so they should be subnet-agnostic.
- Authentik provider redirect URIs — these are HTTPS hostnames (`*.jarrodservilla.com`), not IPs; should be fine.

## See also

- `POWER_OUTAGE.md` — cluster shutdown/startup procedure (referenced from cutover step 4)
- `values/network.yaml` — single source of truth for IP/network config
- `.github/workflows/ci.yml:207` — where the global values file is wired into CI deploys
