# Terraform / OpenTofu Architecture Scoping — homelab-k8s

**Status:** Proposal / scoping document
**Author:** Platform architecture review
**Date:** 2026-06-23
**Decision:** **OpenTofu** (not Terraform). See §2.

---

## Executive summary

Introduce OpenTofu to manage *only* the external/cloud and bootstrap "gap" — Backblaze B2 buckets & keys, DNS records, Tailscale ACLs/tags, Authentik OAuth apps/groups, and the **structure** of the Infisical platform (folders, machine identities, access policies) — while the working Helm + GitHub Actions pipeline keeps owning every in-cluster workload untouched. This is high-value because those resources are today click-ops, undocumented, and the single most likely thing to be unrecoverable after a laptop/account loss, whereas the Helm pipeline already gives you GitOps reviewability for workloads. The hard problem is not the Terraform itself but two bootstrap loops: state lives in B2 but B2 keys could be TF-managed, and TF manages Infisical but needs an Infisical identity to read secrets — both are solved by a small, documented set of manually-seeded root credentials. Do **not** put Helm releases or Kubernetes workload manifests under OpenTofu; that would fork your deployment model for no gain.

**Recommendation: PARTIAL-GO.** Adopt OpenTofu for the external-resource gap in phases, starting with B2 + DNS (read-mostly, import-friendly, disaster-recovery payoff). Explicitly *exclude* the `helm` and most of the `kubernetes` provider surface. If after Phase 1 the maintenance tax outweighs the documentation value, stop — the phases are independent.

---

## 1. Scope boundary

**OpenTofu OWNS (the gap):**

| Domain | Concrete resources | Why TF |
|---|---|---|
| Backblaze B2 | `b2_bucket` (restic, immich-db, ha, open-archiver), `b2_application_key` scoped per-bucket | Click-ops today; lifecycle + retention rules belong in code; DR-critical |
| DNS | per-record `*.jarrodservilla.com` (A/AAAA/CNAME for ingress hostnames) | Currently hand-edited; drift-prone; trivially declarative |
| Tailscale | `tailscale_acl`, `tailscale_tailnet_key` (CI auth key rotation), device `tags` | ACL is already a JSON document — natural fit; CI auth path is security-sensitive |
| Authentik | `authentik_application`, `authentik_provider_oauth2`, `authentik_group`, scope mappings | OAuth wiring for Grafana/others is invisible config; recreating by hand is error-prone |
| Infisical **structure** | `infisical_project`, folders, `infisical_identity` (machine), `infisical_identity_*_auth`, access policies | Defines the secret platform's shape — see §5. TF owns *structure*, never *values* |
| Cluster node metadata | node labels `zigbee=true` (pi4-02), `storage=true` (pi5-01) via narrow `kubernetes_labels` | Bootstrap concern, today undocumented tribal knowledge; tiny, safe k8s surface |

**Helm/CI KEEPS (unchanged):**

- All `charts/**` workloads, including infra charts (metallb, cert-manager, nginx-ingress, sealed-secrets, network-policies), monitoring, apps, backup CronJobs.
- `helm upgrade --install` driven by `git diff HEAD~1` in `.github/workflows/ci.yml`.
- Namespace derivation from `values.yaml`, `values/network.yaml` globals, `values.local.yaml` overlays.

**Ambiguous — ruled on explicitly:**

- **Helm releases via the `helm` provider → NO.** You already have a working, reviewable Helm deploy path. Wrapping it in `helm_release` forks the source of truth (Chart.lock vs TF state), breaks the `git diff` deploy trigger, and adds a state dependency to every workload change. Not worth it for a single operator.
- **`kubernetes` provider → MINIMAL ONLY.** Node labels qualify (bootstrap, not workload, and not expressible in Helm). Do **not** use it for namespaces, CRDs, or RBAC that charts already create. Drawing this line tightly is what keeps the two systems from colliding.
- **MetalLB IP pool values → STAYS IN HELM.** `values/network.yaml` is already the single source of truth (per `docs/runbooks/ISP_MIGRATION.md`). Don't split network config across two tools.
- **B2 buckets for backups vs. the *backup schedules* (CronJobs)** → bucket+key in TF, CronJob in Helm. The seam is the bucket name + key, passed as a non-secret value (bucket name) and an Infisical secret (key).

---

## 2. Provider selection — **OpenTofu over Terraform**

**Why OpenTofu:** MPL-licensed, no BUSL rug-pull risk, drop-in CLI (`tofu`), native **state encryption** (see §3) which Terraform lacks without external tooling — directly relevant given state sits next to secrets. For a hobbyist repo there is zero downside and one concrete feature win.

| Provider | Source | Maturity / maintenance risk | ARM64 / runner notes |
|---|---|---|---|
| B2 | `Backblaze/b2` | Official, stable, low risk | Provider binary runs on the **runner**, not the Pis — `linux/amd64` GitHub runner fine. Wraps the B2 Go SDK |
| DNS | depends on registrar (see assumption) — `cloudflare/cloudflare` if CF | CF provider: very mature. Generic `hashicorp/dns` (RFC2136) only if you self-host DNS | amd64 runner; no Pi involvement |
| Tailscale | `tailscale/tailscale` | Official, active | amd64 runner; needs OAuth client or API key (you already use TS OAuth in CI) |
| Authentik | `goauthentik/authentik` | Vendor-maintained, tracks server version — **pin provider to your Authentik version** | amd64 runner; talks to Authentik API over Tailscale/ingress |
| Infisical | `Infisical/infisical` | Newer, smaller; **highest maintenance risk** of the set — pin tightly, expect breaking changes | amd64 runner; talks to self-hosted Infisical API |
| Kubernetes | `hashicorp/kubernetes` | Mature | **Used minimally** (node labels). Runs from runner over Tailscale via existing kubeconfig |

**No provider runs on the ARM64 Pis** — OpenTofu executes on the GitHub Actions amd64 runner (or your laptop). ARM64 only matters if you `tofu` from a Pi, which you shouldn't.

**Assumptions flagged:** DNS registrar unknown (assuming Cloudflare — *confirm*); B2 region unknown; Tailscale tier (ACL-as-code via API needs the OAuth client you already have — assuming current tier supports it); Authentik version unknown (*pin provider to match*); **Infisical assumed self-hosted in-cluster** (evidence: `charts/infisical`, `.infisical.json`) — this drives the bootstrap loop in §7.

---

## 3. State management

**Backend: B2 via the S3-compatible endpoint** (`s3` backend with `endpoints.s3` override). You already pay for B2; a dedicated `tofu-state` bucket costs pennies.

```hcl
terraform {
  backend "s3" {
    bucket                      = "homelab-tofu-state"
    key                         = "global/terraform.tfstate"
    region                      = "us-west-004"            # ASSUMPTION: confirm B2 region
    endpoints = { s3 = "https://s3.us-west-004.backblazeb2.com" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}
```

**Locking — the real limitation:** B2's S3 API does **not** support DynamoDB-style locking, and OpenTofu's S3 backend lockfile support depends on conditional-write semantics B2 historically lacked. **Mitigation for a single operator: serialize applies through CI** (one workflow, concurrency group `terraform`) so two applies never race. With exactly one human and one CI runner, lock contention is a non-issue if you never run `apply` locally and in CI simultaneously. Document this; don't engineer around a problem you don't have.

**Encryption (the reason for OpenTofu):** Enable OpenTofu **native state encryption** with a PBKDF2/AES-GCM key, so the state blob in B2 is encrypted at rest independent of B2's own encryption. The passphrase is itself a seeded root secret (§7) — it can **not** live in Infisical (state may contain the Infisical bootstrap creds). Store it in GitHub Actions secrets (`TF_STATE_PASSPHRASE`) and your password manager.

```hcl
terraform {
  encryption {
    key_provider "pbkdf2" "k" { passphrase = var.state_passphrase }
    method "aes_gcm" "m" { keys = key_provider.pbkdf2.k }
    state  { method = method.aes_gcm.m }
    plan   { method = method.aes_gcm.m }
  }
}
```

**Interaction with Infisical migration:** state will contain Infisical machine-identity secrets and B2 keys as resource attributes. Treat the state file as Tier-0 secret material — hence encryption + restricted bucket key + never committed. This is *why* secret **values** stay in Infisical and TF only manages structure (§5): minimizing secret material that lands in state.

---

## 4. Repo layout

Single cluster, single environment → **directory-per-domain, NOT per-environment, NOT workspaces.** Multi-env abstraction (`dev`/`prod` workspaces) is premature complexity for one cluster; adding it now buys nothing and taxes every change. Use a flat `terraform/` tree with one module per external domain.

```
terraform/
├── README.md                  # bootstrap order, seeded creds, how to run
├── versions.tf                # required_version, provider pins
├── backend.tf                 # B2 s3 backend + encryption block
├── providers.tf               # provider configs (creds from env/Infisical)
├── main.tf                    # module wiring
├── variables.tf
├── outputs.tf                 # bucket names, identity IDs (non-secret)
└── modules/
    ├── b2/                    # buckets + scoped app keys
    ├── dns/                   # *.jarrodservilla.com records
    ├── tailscale/             # ACL doc + CI auth key + tags
    ├── authentik/             # OAuth apps/providers/groups
    ├── infisical-platform/    # projects, folders, machine identities, policies (STRUCTURE only)
    └── cluster-bootstrap/     # node labels only
```

Keep it one root module + child modules (no remote module registry, no Terragrunt — overkill for one operator). Phase gating (§8) is done by commenting module blocks in `main.tf`, not by separate roots.

---

## 5. Secrets flow — two distinct layers

**Layer (a): TF *manages* the Infisical platform.** The `infisical-platform` module creates `infisical_project`, folder structure, `infisical_identity` (machine identities for the operator + each consumer), and access policies. It defines **structure and access**, and writes **zero secret values**. The actual secret material (B2 keys, DB passwords, OAuth client secrets) is typed into Infisical by hand or written by the *resource that generates it* — e.g. a B2 app key created by TF is written into Infisical via `infisical_secret` **only if** you accept it landing in state; preferred alternative: TF outputs the key once to the operator, who pastes it into Infisical, keeping it out of long-lived state.

**Layer (b): TF *consumes* secrets from Infisical at plan/apply.** Provider credentials (Authentik API token, Tailscale OAuth, DNS API token) are read from Infisical via the `infisical` provider's data sources, or injected as env vars by the Infisical CLI wrapping `tofu` (`infisical run -- tofu apply`). The latter is simpler and matches your existing `infisical scan` CI usage.

**The bootstrap loop:** TF needs an Infisical machine identity to read the creds it needs — but that identity can't live inside the Infisical it's managing. **Resolution:** one manually-created, long-lived **Infisical "bootstrap" machine identity** (Universal Auth client-id/secret), seeded by hand in the Infisical UI, stored in GitHub Actions secrets (`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET`) and your password manager — never in Infisical, never in state. Everything else (consumer identities, scoped tokens) is then TF-managed. **Avoiding a second source of truth:** secret *values* live only in Infisical; TF owns the *containers and access rules*. No plaintext is ever committed; the only secrets outside Infisical are the irreducible bootstrap roots in §7.

---

## 6. CI/CD integration

Add a sibling workflow `.github/workflows/terraform.yml` — **do not** entangle it with `ci.yml`'s Helm job. Mirror the existing patterns (Tailscale OAuth action, Infisical CLI, path filters).

- **Trigger:** `pull_request` + `push: main`, both `paths: ['terraform/**']` so Helm-only changes don't run TF and vice-versa.
- **Plan on PR:** `tofu plan` against a `terraform/**` diff, post plan as PR comment. No cluster mutation. Read-only providers (B2/DNS/Authentik/Tailscale) plan fine; the Infisical/k8s providers need API reachability.
- **Apply on merge:** `push: main` runs `tofu apply` with a `concurrency: { group: terraform, cancel-in-progress: false }` guard (the locking substitute from §3).
- **Manual-approval gate:** wrap `apply` in a GitHub **Environment** (`terraform-prod`) with required reviewer = you. One-click approval, full audit trail.
- **Drift detection:** scheduled `tofu plan` (weekly cron) that opens/updates an issue if drift is found. Low effort, high value for click-ops resources that get hand-edited.
- **When apply needs cluster access:** only the `cluster-bootstrap` (node labels) and `infisical-platform` modules talk to the cluster. Reuse the **exact existing path** — `tailscale/github-action@v4` + base64 `KUBE_CONFIG` secret → `~/.kube/config`. No new connectivity mechanism.
- **Secrets into TF:** `infisical run --env=prod -- tofu apply`, with the bootstrap identity from GH secrets. Mirrors how `infisical scan` already runs in `ci.yml`.

---

## 7. Bootstrap & dependency ordering

The chicken-and-egg knot has **four** seeded roots. These are the *only* manually-created credentials; everything downstream is TF-managed.

**Manually seeded (Tier-0, live in password manager + GitHub Actions secrets, never in state, never in Infisical):**

1. **B2 master/management app key** — needed to create the state bucket *and* to let the b2 provider create other buckets. Create the `homelab-tofu-state` bucket **by hand** (it can't be TF-managed; it stores the state that would manage it).
2. **OpenTofu state passphrase** (`TF_STATE_PASSPHRASE`) — encrypts state; can't live in Infisical because state holds Infisical creds.
3. **Infisical bootstrap machine identity** (`INFISICAL_CLIENT_ID/SECRET`) — lets TF manage Infisical; can't live in the Infisical it manages.
4. **Cluster kubeconfig** (`KUBE_CONFIG`, already exists) + **Tailscale OAuth** (already exists) — for the minimal cluster-touching modules.

**Bootstrap sequence (one-time, manual then automated):**

```
0. (manual) Create B2 mgmt key + `homelab-tofu-state` bucket.
1. (manual) Create Infisical bootstrap machine identity in UI.
2. (manual) Seed the 4 Tier-0 secrets into GitHub Actions secrets + password manager.
3. tofu init  (backend points at the hand-made state bucket, encryption on)
4. tofu apply -target=module.infisical-platform   # creates projects/folders/identities
5. (manual) Paste real secret VALUES into the newly-created Infisical folders.
6. tofu apply  # b2 (other buckets/keys), dns, tailscale, authentik, cluster-bootstrap
7. (import existing live resources — see §8)
```

**Self-hosted Infisical caveat:** because Infisical runs *in the cluster* (`charts/infisical`), the platform that holds your secrets depends on the cluster being up, and TF managing Infisical depends on Infisical being up. This is fine in steady state but means **full DR cannot bootstrap from Infisical** — the 4 Tier-0 roots in your password manager are the true recovery root. Document this in `terraform/README.md` as the disaster-recovery entry point.

---

## 8. Migration path

**Phase 1 (do this first): B2 + DNS via `import`.** Lowest risk (read-mostly, no cluster dependency, no Infisical dependency for the providers if you seed their keys directly), highest DR payoff (these are the resources you most need and least have documented). Both import cleanly.

- **Phase 2:** Tailscale ACL + CI auth key (security value, ACL already JSON).
- **Phase 3:** Infisical platform structure (unlocks §5 properly).
- **Phase 4:** Authentik OAuth apps/groups.
- **Phase 5 (optional):** cluster node labels.

**Import, never recreate.** Every resource here is live and stateful — recreating a B2 bucket orphans backups; recreating DNS causes resolution outages; recreating an Authentik provider breaks Grafana SSO. Use `import` blocks (OpenTofu 1.6+ declarative imports) so the import itself is reviewable in a PR plan:

```hcl
import {
  to = module.b2.b2_bucket.restic
  id = "<bucket-id>"
}
```

**Orphaning risk & mitigation:** the danger is a `plan` that shows *destroy+recreate* instead of *no-op* after import (usually from an attribute the provider computes differently). **Rule: never approve a Phase-1 apply that shows any `destroy` on a B2 bucket or DNS record.** Import, run plan, confirm it's a clean no-op or in-place update only, *then* merge. For backups specifically, B2 bucket lifecycle/retention attributes are the usual culprit — set them in HCL to match reality *before* the first apply.

---

## 9. Risks & anti-patterns

- **Forking the deployment model.** The biggest risk is scope creep into Helm/workloads. If a future change tempts you toward `helm_release`, stop — that's the line this whole doc exists to hold.
- **Single-operator maintenance tax.** Provider upgrades (esp. Infisical and Authentik, which track server versions) will break plans. Pin everything; budget for occasional breakage. If you're not running `tofu` monthly, drift detection + the seeded roots matter more than coverage.
- **State-as-liability.** State now contains secret material. A leaked state file ≈ leaked B2 keys + Infisical creds. Encryption + restricted bucket key are mandatory, not optional.
- **Locking false-confidence.** B2 backend locking is weak; the CI concurrency group is the real guard. Don't run local `apply` while CI might.
- **When NOT to use TF here:** anything Helm already does well; anything expressible in `values/network.yaml`; one-off resources you'll never change; secret *values* (Infisical's job). If a domain has <3 resources and never changes, importing it may cost more than it saves — node labels are borderline; do them only if Phase 1–4 prove the workflow.
- **Premature multi-env.** Resisted in §4 — re-flag here so it doesn't creep back.

---

## First-PR task list (one sitting)

Scope: **stand up the skeleton + Phase 1 B2 import, plan-only.** No apply of new resources yet.

1. **Decide & confirm assumptions:** DNS registrar (Cloudflare?), B2 region, Tailscale tier, Authentik version, Infisical self-hosted confirmation. Block on these for provider pins.
2. **Manually seed Tier-0:** create B2 mgmt key + `homelab-tofu-state` bucket; generate `TF_STATE_PASSPHRASE`; create Infisical bootstrap identity. Store all in password manager + GitHub Actions secrets.
3. **Create `terraform/` skeleton:** `versions.tf` (pin OpenTofu + providers), `backend.tf` (B2 s3 + native encryption), `providers.tf`, empty `main.tf`/`variables.tf`/`outputs.tf`, and `README.md` documenting the §7 bootstrap + DR roots.
4. **Add `modules/b2/`:** `b2_bucket` + scoped `b2_application_key` resources for the 4 backup buckets, attributes matching current reality (lifecycle/retention).
5. **Add `import` blocks** for the existing B2 buckets; run `tofu plan`; confirm **clean no-op** (zero destroys).
6. **Add `.github/workflows/terraform.yml`:** `paths: ['terraform/**']`, plan-on-PR (comment), apply-on-merge behind a `terraform-prod` GitHub Environment + `concurrency: terraform`. Reuse Tailscale OAuth + Infisical CLI patterns from `ci.yml`.
7. **Update `.gitignore`** for `*.tfstate*`, `.terraform/`, `*.tfplan`; add `terraform/` note to `CLAUDE.md` so the deployment-model boundary (TF=gap, Helm=workloads) is documented for future sessions.
