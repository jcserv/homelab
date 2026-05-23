# Infisical Migration Plan — SealedSecrets → Infisical Operator

Migrate app secrets off `kubeseal` SealedSecrets onto the self-hosted Infisical
platform via the Secrets Operator. Mirrors the pihole `WEBPASSWORD` POC
(`charts/pihole/templates/infisical-secret.yaml`).

Decisions:
- **Backup creds**: subfolders per job (`/backup/immich`, `/backup/restic`,
  `/backup/home-assistant`) — avoids flat-folder key collision on `AWS_*`.
- **CR wiring**: copy the pihole template into each chart, parameterized via
  `values.yaml` `infisical:` block. No shared library chart.

## Scope

### Migrate (8 charts, 10 SealedSecrets)

| Chart | SealedSecret file | Target K8s Secret | NS | Infisical folder | Keys |
|---|---|---|---|---|---|
| authentik | authentik-secrets-sealed | `authentik-secrets` | default | `/authentik` | `AUTHENTIK_POSTGRESQL__PASSWORD`, `AUTHENTIK_POSTGRESQL__USER`, `AUTHENTIK_SECRET_KEY` |
| authentik | outpost-token-sealed | `authentik-outpost-token` | default | `/authentik` | `token` |
| cert-manager | cloudflare-api-token-sealed | `cloudflare-api-token-secret` | cert-manager | `/cert-manager` | `api-token` |
| home-assistant | oauth-secrets-sealed | `home-assistant-oauth` | default | `/home-assistant` | `client_id`, `client_secret` |
| home-assistant-backup | homeassistant-backup-secrets-sealed | `homeassistant-backup-secrets` | default | `/backup/home-assistant` | `HA_API_TOKEN` |
| immich | immich-secrets-sealed | `immich-secrets` | default | `/immich` | `DB_PASSWORD`, `JWT_SECRET` |
| immich-db-backup | app-backups-b2-secrets-sealed | `app-backups-b2-secrets` | default | `/backup/immich` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| kube-prometheus-stack | grafana-admin-sealed | `grafana-admin-secret` | monitoring | `/monitoring` | `admin-user`, `admin-password` |
| recipe-rip | recipe-rip-secrets-sealed | `recipe-rip-secrets` | default | `/recipe-rip` | `anthropic-api-key`, `better-auth-secret`, `transcript-api-key` |
| restic-backup | restic-b2-secrets-sealed | `restic-b2-secrets` | default | `/backup/restic` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RESTIC_PASSWORD`, `RESTIC_REPOSITORY` |
| pihole | pihole-custom-blocklist-sealed | `pihole-custom-blocklist` | default | `/pihole` | `pihole-blocklist.txt` ⚠️ multiline file |
| pihole | pihole-nebula-sync-sealed | `pihole-nebula-sync` | default | `/pihole` | `PRIMARY`, `REPLICAS` ⚠️ may be multiline |

### Do NOT migrate (bootstrap chicken-egg, stay SealedSecret)

- `charts/infisical/sealed-secrets/infisical-secrets-sealed.yaml` — the platform's
  own Postgres/Redis/auth creds. Operator can't fetch secrets for the service
  that serves them.
- `charts/infisical-secrets-operator/sealed-secrets/infisical-machine-identity-sealed.yaml`
  — the universal-auth creds the operator uses to reach Infisical. This IS the
  auth root.

## Phase 1 — Seed Infisical (manual, needs plaintext)

SealedSecret values are encrypted; plaintext comes from the live cluster or
`.env`. For each row, read current value then create in Infisical.

Read a live value:
```bash
kubectl get secret <name> -n <ns> -o jsonpath='{.data.<KEY>}' | base64 -d
```

Create folders/subfolders (UI or `infisical` CLI), then add secrets per the
table. Subfolders to create under existing `backup`:
- `backup/immich`, `backup/restic`, `backup/home-assistant`

Per-app machine-identity scoping (optional hardening): give each folder its own
read-only identity. Initial pass can reuse the existing
`infisical-machine-identity` with project-wide read.

**Verify before moving on**: every key in the table above exists in its folder
with the correct value.

## Phase 2 — Add InfisicalSecret CR per chart

For each chart, copy `charts/pihole/templates/infisical-secret.yaml` →
`charts/<chart>/templates/infisical-secret.yaml` and adjust:

- `managedKubeSecretReferences[].secretName` → target Secret name (table col 3)
- `secretNamespace` → `.Release.Namespace` (cert-manager + grafana deploy into
  their own namespace, so the CR ships inside that chart → resolves correctly)
- `template.data` → map every key (drop `includeAllSecrets:false` + explicit map
  to keep Secret keys byte-identical to the old SealedSecret)
- `secretsScope.secretsPath` → the folder (e.g. `/authentik`, `/backup/restic`)

Add an `infisical:` block to each `values.yaml` (copy pihole lines 90–102),
defaulting `enabled: false` until seeded + verified, then flip to `true`.

Shared `credentialsRef`:
```yaml
credentialsRef:
  secretName: infisical-machine-identity
  secretNamespace: infisical-secrets-operator
```

⚠️ **Watch items**
- **Cross-namespace** (cert-manager, monitoring): operator is cluster-scoped
  (`scopedNamespaces: []`) so it can write into any NS. CR + managed Secret both
  live in the chart's own NS. `credentialsRef` points at the operator NS — OK.
- **Multiline `pihole-blocklist.txt`**: store the file as one multiline Infisical
  value; template maps it to the same key. Confirm newlines survive round-trip.
- **`grafana-admin-secret`**: the SealedSecret has a `template:` block; replicate
  any labels Grafana's chart expects, else Grafana won't pick it up.
- **Owner policy**: `creationPolicy: Owner` means the operator creates the Secret.
  The old SealedSecret + operator must not both own the same Secret name at once
  — sequence per Phase 3 (deploy CR first while SealedSecret still present is
  fine; both reconcile the same content; remove SealedSecret right after verify).

## Phase 3 — Per-chart cutover (one chart at a time)

For each chart, in order, lowest-blast-radius first
(cert-manager → recipe-rip → grafana → home-assistant → backups → immich →
authentik). Do NOT batch.

1. Seed the chart's secrets in Infisical (Phase 1).
2. Commit + push CR template with `infisical.enabled: true`.
3. CI deploys. Verify materialized Secret matches:
   ```bash
   kubectl get secret <name> -n <ns> -o jsonpath='{.data.<KEY>}' | base64 -d
   ```
   and the app pod is healthy (login / probe / backup dry-run).
4. **Only then** delete `charts/<chart>/sealed-secrets/<file>-sealed.yaml`
   (and the `sealed-secrets/` dir if now empty). Commit + push.
5. Confirm next reconcile still healthy before starting the next chart.

Rollback: re-add the SealedSecret file + `helm upgrade` restores the prior
Secret; set `infisical.enabled: false`.

## Phase 4 — Hardening (optional, after all charts migrated)

- Per-app machine identities scoped to each folder (replace shared identity).
- `instantUpdates: true` + Stakater Reloader → rolling restart on secret change
  (enables rotation without manual redeploy).
- Wire Infisical audit logs into Loki/Grafana.

## Done criteria

- All 10 SealedSecret files in the table removed.
- Only `infisical-secrets` + `infisical-machine-identity` SealedSecrets remain.
- All apps healthy reading operator-materialized Secrets.
