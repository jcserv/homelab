# Implementation Prompt: Bootstrap OpenTofu for homelab-k8s External-Resource Gap

## Role
You are a senior DevOps/platform engineer with deep OpenTofu/Terraform, GitOps, and GitHub Actions experience. You implement incrementally, import live infrastructure without orphaning it, and never break a working pipeline. You write reviewable PRs and stop at risk boundaries to confirm with the operator.

## Source of truth
Read `docs/terraform-architecture-scoping.md` in this repo first — it is the approved architecture. Do not re-litigate its decisions (OpenTofu over Terraform; manage the external "gap" only; no `helm` provider; minimal `kubernetes`; B2 s3 backend with native state encryption; directory-per-domain not multi-env; four Tier-0 seeded roots; Phase 1 = B2 + DNS via import). Implement against it. If you find a decision is wrong in light of live state, raise it as a blocking question — do not silently deviate.

## Context: the existing system (do not change)
4-node HA K3s cluster on Raspberry Pi. All workloads are Helm charts under `charts/`. `.github/workflows/ci.yml` runs: `infisical scan` → `ct lint` (kind) → `deploy` (main-only) which connects via `tailscale/github-action@v4` + base64 `KUBE_CONFIG` secret and runs `helm upgrade --install` on charts changed in `git diff HEAD~1 HEAD`. Secrets are mid-migration from kubeseal SealedSecrets to **self-hosted, in-cluster Infisical** (`charts/infisical`, operator-based). `values/network.yaml` is the single source of truth for IP/network config. **The Helm pipeline must keep working unchanged.**

## Scope of THIS implementation (Phase 0 + Phase 1, plan-only)
Deliver the OpenTofu skeleton and the **B2 backup-bucket import**, ending at a **clean `tofu plan` no-op** — no apply of new resources, no `destroy` on any live resource. DNS (rest of Phase 1) and later phases are out of scope for this PR unless explicitly requested.

In scope:
1. `terraform/` skeleton: `versions.tf` (pin OpenTofu + each provider), `backend.tf` (B2 S3-compatible backend + OpenTofu native PBKDF2/AES-GCM state encryption), `providers.tf`, `main.tf`, `variables.tf`, `outputs.tf`, `README.md` (bootstrap order + DR roots from §7 of the spec).
2. `modules/b2/`: `b2_bucket` + per-bucket scoped `b2_application_key` for the 4 backup buckets (restic, immich-db, home-assistant, open-archiver), with lifecycle/retention attributes matching live reality.
3. `import` blocks (OpenTofu 1.6+ declarative) for the existing B2 buckets.
4. `.github/workflows/terraform.yml`: `paths: ['terraform/**']`, plan-on-PR (post plan as comment), apply-on-merge behind a `terraform-prod` GitHub Environment + `concurrency: { group: terraform, cancel-in-progress: false }`. Reuse the existing Tailscale OAuth + Infisical CLI patterns from `ci.yml` verbatim where possible.
5. `.gitignore` entries: `*.tfstate*`, `.terraform/`, `*.tfplan`, `*.tfvars` (except committed examples). Add a `terraform/` note to `CLAUDE.md` documenting the boundary: **TF = external gap, Helm = workloads.**

Explicitly OUT of scope: any `helm_release`; any `kubernetes` resource beyond what the spec allows (node labels are Phase 5, not now); DNS/Tailscale/Authentik/Infisical-platform modules; any `tofu apply` that creates or destroys real resources.

## Blocking inputs — confirm before writing provider pins
Stop and ask the operator for these; do not guess:
- B2 region + S3 endpoint host (e.g. `us-west-004` / `s3.us-west-004.backblazeb2.com`).
- Exact live B2 bucket names + bucket IDs for the 4 backups (needed for `import` blocks).
- Whether the 4 Tier-0 roots are already seeded (B2 mgmt key, `homelab-tofu-state` bucket, `TF_STATE_PASSPHRASE`, Infisical bootstrap identity). If not, provide the exact manual steps and pause.
- DNS registrar (spec assumes Cloudflare) — only needed if you also touch DNS; otherwise note as deferred.

## Hard constraints
- Providers run on the **amd64 GitHub runner / operator laptop**, never on the Pis. No ARM64 build concern.
- Secret VALUES never enter code or state where avoidable; provider creds come from GitHub Actions secrets / `infisical run -- tofu ...`. No plaintext committed. The state passphrase and Infisical bootstrap identity must NOT live in Infisical (state contains Infisical creds).
- The B2 state bucket is created BY HAND and is NOT TF-managed (it stores the state that would manage it).
- Locking: B2 backend locking is weak — rely on the CI `concurrency` group. Never run a local `apply` that could race CI.

## Definition of done
- `tofu init` succeeds against the hand-created encrypted B2 state bucket.
- `tofu plan` on the B2 module after import shows a **clean no-op or in-place-only** result — zero `destroy`, zero `create` on live buckets. Paste the plan output in the PR.
- `terraform.yml` runs plan on PR and is gated for apply-on-merge; it does NOT trigger on Helm-only changes, and `ci.yml` does NOT trigger on `terraform/**` changes.
- A reviewer can read `terraform/README.md` and reproduce the bootstrap + understand the DR root credentials.

## Working style
Follow the repo conventions (yamllint/yamlfix, selective per-file staging, no `git add -A`). Branch off `main`; do not commit or push unless asked. Start writing files within the first few tool calls — cap exploration; the spec already did the discovery. If a `plan` shows any destroy on a live bucket, STOP and surface it — that is the orphaning risk the spec calls out, and it is never auto-resolved. Produce a single focused PR matching the "First-PR task list" in the spec.
