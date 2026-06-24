# terraform/ — OpenTofu for the external/cloud gap

OpenTofu (`tofu`, **not** Terraform) manages **only** the external/cloud + bootstrap "gap":
B2 buckets/keys, DNS, Tailscale, Authentik, and the *structure* of Infisical. Every
in-cluster workload stays owned by Helm + `.github/workflows/ci.yml` — unchanged.

**This is Phase 0 (skeleton) + Phase 1 (B2 import), plan-only.** End state: `tofu plan`
is a clean no-op over the live B2 buckets. No resources created, none destroyed.

Region for everything: **`ca-east-006`**.

## Scope boundary

- TF **owns**: B2, DNS, Tailscale, Authentik, Infisical structure, node labels (Phase 5).
- TF **never touches**: `helm_release`, workload `kubernetes` resources, `charts/**`, `ci.yml`.
- Secret **values** live in Infisical; TF owns containers/access only. Bucket *names* are
  non-secret values; bucket *keys* are Infisical secrets.

## Tier-0 seeded roots (the DR recovery root)

These are the **only** hand-made credentials; everything downstream is TF-managed. They live
in the **password manager** + **GitHub Actions secrets** — never in state, never in Infisical.
Because Infisical runs *in the cluster*, full DR cannot bootstrap from Infisical — **the
password manager is the true recovery root.**

1. **B2 management app key** — account-wide create/list buckets+keys. GH secrets
   `B2_APPLICATION_KEY_ID` / `B2_APPLICATION_KEY`. The **b2 provider** reads these directly.
   The **s3 state backend** uses the AWS SDK and reads the standard `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` env vars — set those to the *same* B2 keyID/appKey (AWS-named).
2. **State bucket `homelab-tofu-state-dd43bf5b`** — made by hand (private, `ca-east-006`).
   Can't be TF-managed: it stores the state that would manage it.
3. **`TF_STATE_PASSPHRASE`** — PBKDF2 passphrase for native state encryption. GH secret +
   PM. **Not in Infisical** (state holds Infisical creds). Injected as `TF_VAR_state_passphrase`.
4. **Infisical bootstrap machine identity** (Universal Auth) — `INFISICAL_CLIENT_ID` /
   `INFISICAL_CLIENT_SECRET` in GH secrets + PM. Not consumed by this B2-only PR (seeded for
   Phase 3). **Not in Infisical**, never in state.

Already-existing GH secrets reused later: `KUBE_CONFIG`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`.

## Bootstrap order (§7)

```
0. (manual, DONE) B2 mgmt key + hand-made state bucket homelab-tofu-state-dd43bf5b.
1. (manual, DONE) Infisical bootstrap machine identity.
2. (manual, DONE) Seed the 4 Tier-0 secrets into GH Actions + password manager.
3. tofu init            # backend = hand-made encrypted state bucket
4. fill real bucket IDs in import blocks (main.tf), then tofu plan  <-- this PR
5. (later) tofu apply for app keys / dns / tailscale / authentik / node labels
```

## Running

```bash
cd terraform
unset AWS_PROFILE                       # stop the AWS SDK using a shared-config profile
export TF_VAR_state_passphrase=...      # = TF_STATE_PASSPHRASE
export B2_APPLICATION_KEY_ID=...        # b2 provider: B2 mgmt key (keyID)
export B2_APPLICATION_KEY=...           # b2 provider: B2 mgmt key (appKey)
export AWS_ACCESS_KEY_ID=$B2_APPLICATION_KEY_ID      # s3 backend: same B2 keyID
export AWS_SECRET_ACCESS_KEY=$B2_APPLICATION_KEY     # s3 backend: same B2 appKey
tofu init
tofu plan                               # must be a CLEAN no-op for B2 buckets
```

Get the bucket IDs to fill `import` blocks:

```bash
b2 list-buckets            # bucketId is the `id =` value (NOT the name)
```

restic's bucket name is confirmed from Infisical `/backup/restic` -> `RESTIC_REPOSITORY`.

## Locking

B2's S3 API has no DynamoDB-style locking. **Mitigation: serialize applies through CI**
(`concurrency: { group: terraform, cancel-in-progress: false }`). **Never run `tofu apply`
locally** while CI might — one human + one runner = no contention if you don't race them.

## Phase 2: Tailscale

Brings the tailnet under TF: **ACL-as-code** and a **TF-managed tailnet auth key**.
Module: `modules/tailscale/`.

**Not fully plan-only.** The ACL is import->no-op (mirror the B2 discipline). The
**one apply** is `tailscale_tailnet_key.ci` — a key's `key` secret is never returned
on import, so it is inherently a CREATE.

**Device tags deferred.** The cluster nodes (`pi4-01/02`, `pi5-01/02`) are
**user-owned (untagged) live**, so TF-managing their tags would be a real
ownership-changing mutation, not an import-no-op — it would subject them to ACL tag
rules and risk cluster connectivity. Tagging is left to a deliberate follow-up: add
the node tag to `tagOwners` + the necessary `grants` in `acl.hujson`, then apply.

### New OAuth client + GH secrets (Tier-0-adjacent, hand-made)

The Tailscale **provider** authenticates with a **new** OAuth client, distinct from
the node-auth `TS_OAUTH_*` (which the `tailscale/github-action` uses to self-mint
ephemeral node keys). Create it in the admin console with scopes (new UI names):

- **General → Policy File** (read + write) — manage the ACL
- **Keys → Auth Keys** (read + write) — create the tailnet key
- **Devices → Core** (read + write) — reserved for the deferred device-tag follow-up

It must **own every tag it manages** (currently `tag:github-actions`; add node tags
when tagging lands). Seed its id/secret into GH Actions secrets
`TS_TF_OAUTH_CLIENT_ID` / `TS_TF_OAUTH_CLIENT_SECRET` (+ password manager). The
provider reads env `TAILSCALE_OAUTH_CLIENT_ID` / `TAILSCALE_OAUTH_CLIENT_SECRET`. It
hits the public `api.tailscale.com` — **no cluster VPN**, so `terraform.yml`'s
commented `Connect to Tailscale` step stays commented.

### Required inputs before plan

- `modules/tailscale/acl.hujson` — the live ACL, exported verbatim (HuJSON
  formatting/comments are the drift culprit). Must declare `tagOwners` for every tag
  used or the provider rejects it.

### Running (adds to the env in "Running" above)

```bash
export TAILSCALE_OAUTH_CLIENT_ID=...      # new ACL-scoped OAuth client
export TAILSCALE_OAUTH_CLIENT_SECRET=...
tofu init
tofu plan   # ACL = no-op; tailscale_tailnet_key.ci = the only create
```

After apply, read the key once: `tofu output -raw ci_auth_key` (Infisical storage
deferred to Phase 3). The key is for manual/other node joins (NAS, re-imaging a Pi);
CI does not consume it.

## Phase 6: GitHub Actions secrets (implemented)

Closes the loop on **TF-generated secrets** by writing them straight into GitHub Actions
secrets, instead of a human running `tofu output -raw …` and pasting into the repo settings.
Fits the boundary cleanly: GitHub config is **external gap**, not in-cluster — no `helm_release`,
no `charts/**`. Module: `modules/github/`.

**Final scope landed**: candidate 1 (`TS_TF_CI_AUTH_KEY`, fed from `module.tailscale.ci_auth_key`)
**+** candidate 3 adoption of `KUBE_CONFIG` / `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET`. Adopted
secrets use `value` (plaintext; provider encrypts — `plaintext_value` is deprecated in github
provider v6) re-supplied via `TF_VAR_*` from the existing live GH secrets — value
lands in (encrypted) state; accepted. Plan shows **4 creates, zero destroys/replaces**.

### Scope boundary (read before adding any secret)

- TF **owns**: repo Actions secrets whose *value originates in TF* (a TF resource generated it),
  plus the *existence/metadata* of adopted non-Tier-0 secrets.
- TF **never manages**: the **4 Tier-0 secrets** — `B2_APPLICATION_KEY_ID` / `B2_APPLICATION_KEY`,
  `TF_STATE_PASSPHRASE`, and the Infisical bootstrap `INFISICAL_CLIENT_ID` /
  `INFISICAL_CLIENT_SECRET`. **Chicken-egg:** TF reads state from B2 using exactly these creds, so
  it cannot bootstrap its own access — they stay in the password manager + hand-set GH secrets
  forever. Same DR-root logic as §"Tier-0 seeded roots": the password manager is the true root.

### Provider auth (Tier-0-adjacent, hand-made)

The `integrations/github` provider needs a token with `repo` + Actions-secrets write scope —
a fine-grained PAT (Secrets: read/write on this repo) or a GitHub App installation token. Seed
it into a GH secret `GH_TF_TOKEN` (+ password manager); the provider reads env `GITHUB_TOKEN`
and `GITHUB_OWNER`. **Not** a Tier-0 root (TF doesn't need it to reach state), but hand-made and
never TF-managed (it grants the write access TF uses — self-management is the same chicken-egg).

### Candidate secrets

1. **`TS_TF_CI_AUTH_KEY`** ← `module.tailscale.tailscale_tailnet_key.ci.key`. TF already
   generates this; today it's surfaced via `tofu output -raw ci_auth_key` and copied by hand.
   Wiring it to `github_actions_secret.plaintext_value` removes the manual step. Lowest risk,
   clearest win — the first one to land.
2. **Future TF-generated values** — reserve the pattern for per-service B2 app keys (Phase 1+),
   Authentik tokens (Phase 4), and Infisical machine identities (Phase 3). As each TF resource
   that mints a credential lands, pipe its output into a `github_actions_secret` in the same PR.
3. **Adopted non-Tier-0 secrets** (`KUBE_CONFIG`, `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET`) —
   bring existing manually-set secrets under TF for an inventory-in-code. Caveat: their values
   do **not** originate in TF, so adoption means re-supplying the value through a `TF_VAR_*`
   (it then lands in state) — accept the state exposure or skip. Lower priority than 1–2.

### Import discipline does NOT apply

Unlike B2 buckets and the Tailscale ACL, **`github_actions_secret` cannot be import->no-op**:
the GitHub API never returns a secret's value, so every managed secret is an inherent CREATE
(same shape as `tailscale_tailnet_key.ci`). Plan-only verification is therefore by *count of
creates*, not a clean no-op. There's no destroy risk to a live backup here — deleting a managed
secret only un-sets it in CI — but a wrong value silently breaks a workflow, so apply deliberately.

### State exposure

`plaintext_value` lands in TF state. State is the B2 bucket + native encryption, so it's
encrypted at rest, but anyone with the state file **and** `TF_STATE_PASSPHRASE` can recover the
value. For candidate 1 that's already true (the key lives in state via the tailscale module
output regardless). For candidate 3, prefer `encrypted_value` (sealed client-side with the repo's
public key via `github_actions_public_key`) if the value is sensitive and not already in state.

### Bootstrap order delta

```
… (Phases 0–5 as above)
6. (manual) Create GH_TF_TOKEN PAT/App token -> GH Actions secret + password manager.
7. tofu apply modules/github   # creates TS_TF_CI_AUTH_KEY first; expand per candidate.
```

## HARD STOP rule (import safety)

After import, if `tofu plan` shows ANY `destroy`/replace on a live bucket, **do not apply** —
orphaning a backup bucket loses backups. Fix module HCL (lifecycle/retention/`bucket_info`
to match live) until the plan is a clean no-op / in-place-only update, then merge.
