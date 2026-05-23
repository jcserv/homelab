# Infisical Secrets Operator

The operator pulls secrets from the self-hosted Infisical platform
(`charts/infisical`, https://infisical.jarrodservilla.com) and materializes
them as native Kubernetes `Secret`s via the `InfisicalSecret` CRD. This is the
alternative to sealing secrets into git with `sealed-secrets`.

- **Operator chart:** `charts/infisical-secrets-operator` (wraps the upstream
  `secrets-operator` chart). Runs cluster-scoped in the
  `infisical-secrets-operator` namespace, watching all namespaces.
- **POC consumer:** `charts/pihole` — gated behind `infisical.enabled`
  (default `false`). When on, the operator owns the `pihole-secrets` Secret
  (key `WEBPASSWORD`), replacing `sealed-secrets/pihole-secrets-sealed.yaml`.

## Architecture

```
Infisical platform (project / env=prod / path=/pihole)
        │  Universal Auth (machine identity)
        ▼
infisical-machine-identity Secret  (ns: infisical-secrets-operator, sealed)
        │  credentialsRef
        ▼
secrets-operator  ──reads──►  InfisicalSecret CR (pihole, ns: default)
        │
        └──writes──►  Secret/pihole-secrets (ns: default, key WEBPASSWORD)
                              │
                              ▼  secretKeyRef
                      pihole StatefulSet
```

The machine-identity creds are the **one** secret still sealed in git. Every
`InfisicalSecret` CR references it via `credentialsRef`; everything else lives
in Infisical.

## One-time setup

### 1. Install the operator

```bash
make build-deps          # vendors the secrets-operator subchart + CRDs
make install-infra       # installs the operator (among other infra)
# or, just the operator:
helm upgrade --install infisical-secrets-operator ./charts/infisical-secrets-operator \
  -n infisical-secrets-operator --create-namespace -f values/network.yaml
```

Verify the CRDs and controller:

```bash
kubectl get crd | grep infisical            # infisicalsecrets.secrets.infisical.com ...
kubectl -n infisical-secrets-operator get pods
```

### 2. Create a machine identity in Infisical

1. Infisical UI → **Access Control → Machine Identities → Create**.
2. Auth method: **Universal Auth**. Copy the **Client ID** and **Client Secret**.
3. Project → **Access Control** → add the identity with **read** access to the
   project/environment (`prod`) and path (`/pihole`) the CR references.

### 3. Seal the machine-identity credentials

Template: `charts/infisical-secrets-operator/sealed-secrets/infisical-machine-identity.template`.

```bash
kubectl create secret generic infisical-machine-identity \
  --namespace infisical-secrets-operator \
  --from-literal=clientId=<CLIENT_ID> \
  --from-literal=clientSecret=<CLIENT_SECRET> \
  --dry-run=client -o yaml | \
  make seal-secret CHART=infisical-secrets-operator SECRET=infisical-machine-identity
```

Commit the resulting `*-sealed.yaml`, then apply it (sealed secrets are applied
out-of-band in this repo, not by helm):

```bash
kubectl apply -f charts/infisical-secrets-operator/sealed-secrets/infisical-machine-identity-sealed.yaml
```

## Enabling the pihole POC

1. In Infisical, add a secret `WEBPASSWORD` under env `prod`, path `/pihole`.
   Use the same value currently sealed in `pihole-secrets-sealed.yaml`.
2. Set the project slug + flip the flag in `charts/pihole/values.yaml`:

   ```yaml
   infisical:
     enabled: true
     projectSlug: "<your-project-slug>"   # Project → Settings
   ```

3. Deploy: `make upgrade SERVICE=pihole` (or push to main).
4. Verify the operator created the Secret and it matches:

   ```bash
   kubectl get infisicalsecret pihole-infisical -n default
   kubectl get secret pihole-secrets -n default -o jsonpath='{.data.WEBPASSWORD}' | base64 -d; echo
   ```

5. Once confirmed, retire the SealedSecret so there's a single source of truth:

   ```bash
   git rm charts/pihole/sealed-secrets/pihole-secrets-sealed.yaml
   # the operator now owns Secret/pihole-secrets (creationPolicy: Owner)
   ```

   > Order matters: only delete the SealedSecret **after** the operator is
   > successfully managing `pihole-secrets`, or pihole loses its admin password.

## Rollback

Flip `infisical.enabled: false` and re-apply the SealedSecret. Because the CR
uses `creationPolicy: Owner`, deleting the CR deletes the managed Secret — so
restore the sealed one in the same change.

## Notes / gotchas

- **Resync:** `syncConfig.resyncInterval: 60s`. Rotations in Infisical
  propagate within that window; consumers reading env vars still need a pod
  restart unless they watch the Secret.
- **Availability:** with secrets sourced from Infisical, the platform being
  down blocks *new* secret creation. Existing managed Secrets persist
  (operator doesn't delete on transient API errors).
- **Scope creep:** to onboard another chart, copy the `infisical:` values block
  and `templates/infisical-secret.yaml` pattern, pointing at its own
  `secretsPath`. The same machine identity can serve all of them if granted
  access.
```
