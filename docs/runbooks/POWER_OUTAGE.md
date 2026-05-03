# POWER_OUTAGE

In the event of a power outage, perform the following steps.

## Cluster topology

All 4 nodes are HA control-plane + etcd members (no dedicated agents). Etcd quorum = 3, so once the 2nd node stops, the API server becomes unavailable. **Do all `kubectl` work before stopping any node.**

| Node   | IP         | Notes                                       |
| ------ | ---------- | ------------------------------------------- |
| pi4-01 | 10.2.1.54  |                                             |
| pi4-02 | 10.2.1.160 | `zigbee=true` (Home Assistant USB)          |
| pi5-01 | 10.2.1.28  | `storage=true` (Immich ML) — shut down last |
| pi5-02 | 10.2.1.156 |                                             |

## Power-down

1. In the Unifi console, change the DNS server of relevant networks from 10.2.1.202 to Auto-DNS

2. Run backup jobs

```bash
kubectl create job --from=cronjob/immich-db-backup immich-db-backup-preoutage -n default
kubectl create job --from=cronjob/authentik-backup authentik-backup-preoutage -n default
make backup
```

This should take up to 21 minutes for the last job. Wait for completion:

```bash
kubectl get jobs -A
```

3. Quiesce stateful workloads (optional but cleaner — lets DBs flush)

```bash
kubectl scale deploy immich-server immich-ml --replicas=0 -n default
kubectl scale deploy immich-postgres --replicas=0 -n default
kubectl scale deploy authentik-postgres --replicas=0 -n default
kubectl scale deploy home-assistant --replicas=0 -n default
```

4. Cordon + drain non-primary nodes (do this while all 4 are still up — quorum required)

```bash
make drain NODE=pi4-01
make drain NODE=pi4-02
make drain NODE=pi5-02
# leave pi5-01 (primary) for last
```

5. Shutdown

SSH into each node and run `sudo shutdown -h now`. Systemd will stop k3s cleanly — no need to `systemctl stop k3s` separately. Order: pi4-01 → pi4-02 → pi5-02 → pi5-01.

```bash
ssh pi4-01 'sudo shutdown -h now'
ssh pi4-02 'sudo shutdown -h now'
ssh pi5-02 'sudo shutdown -h now'
ssh pi5-01 'sudo shutdown -h now'
```

6. NAS at 10.2.1.147 — immich NFS + media stack live there. If on the same circuit, shut it down gracefully via UGREEN web UI. Otherwise pods will come back up faster than NFS on power-up and crashloop briefly (harmless but noisy).

7. UPS check — if anything is on a UPS, verify runtime so it doesn't drain mid-outage and hard-cut.

## Power-up

1. NAS first, wait for it to be reachable (`ping 10.2.1.147`)
2. Power on pi5-01 (primary), wait for `kubectl get nodes` to show it Ready
3. Power on remaining Pis (pi5-02, pi4-02, pi4-01)
4. `kubectl uncordon <node>` for each, watch pods settle (`make status`)
5. Scale stateful workloads back up:

```bash
kubectl scale sts immich-postgresql --replicas=1 -n default
kubectl scale sts authentik-postgresql --replicas=1 -n default
kubectl scale deploy immich-server immich-machine-learning --replicas=1 -n default
kubectl scale deploy home-assistant --replicas=1 -n default
```

6. In the Unifi console, restore DNS server to 10.2.1.202
