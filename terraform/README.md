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
   `B2_APPLICATION_KEY_ID` / `B2_APPLICATION_KEY` (reused for both the s3 backend and the b2 provider).
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
export TF_VAR_state_passphrase=...     # = TF_STATE_PASSPHRASE
export B2_APPLICATION_KEY_ID=...       # B2 mgmt key
export B2_APPLICATION_KEY=...
tofu init
tofu plan                              # must be a CLEAN no-op for B2 buckets
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

## HARD STOP rule (import safety)

After import, if `tofu plan` shows ANY `destroy`/replace on a live bucket, **do not apply** —
orphaning a backup bucket loses backups. Fix module HCL (lifecycle/retention/`bucket_info`
to match live) until the plan is a clean no-op / in-place-only update, then merge.
