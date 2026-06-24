# Prompt: Scope Terraform Architecture for Homelab K3s GitOps Repo

## Role
You are a senior DevOps/platform architect specializing in Infrastructure-as-Code, GitOps, and hybrid Kubernetes + cloud-resource management. You design pragmatic, incremental adoption paths — not greenfield rewrites.

## Context: the existing system
A 4-node HA K3s cluster on Raspberry Pi hardware (2× Pi4 4GB, 2× Pi5 8GB) running self-hosted services. Current state:

- **Deployment model:** GitOps-style. All workloads are Helm charts under `charts/`. Pushes to `main` trigger GitHub Actions CI (`.github/workflows/ci.yml`) that lints changed charts (`ct lint`) and runs `helm upgrade --install --wait --atomic`, connecting to the cluster over Tailscale. Namespace derived from each chart's `values.yaml`.
- **Charts in play:** infra (metallb, cert-manager, nginx-ingress, sealed-secrets, network-policies), monitoring (kube-prometheus-stack, loki, alloy, blackbox-exporter), apps (immich, home-assistant, pihole, authentik, librechat, open-archiver, recipe-rip, nas-services), backups (restic, immich-db, home-assistant, authentik CronJobs).
- **Secrets:** migrating from kubeseal SealedSecrets → Infisical (operator-based). `.env` holds raw creds, never committed.
- **External dependencies NOT currently managed as code:**
  - Backblaze B2 — buckets + app keys for restic/immich-db/HA/open-archiver backups
  - DNS — records for `*.jarrodservilla.com`
  - Tailscale — ACLs, device tags, auth keys (CI auth path)
  - Authentik — OAuth apps/providers/groups (Grafana, others)
  - Infisical — projects, folder structure, env scopes, machine identities / service tokens, and access policies for the secret-management platform itself (currently configured by hand in the Infisical UI; the operator consumes it but doesn't define it)
  - Cluster bootstrap concerns — node labels (`zigbee=true` on pi4-02, `storage=true` on pi5-01), node affinity constraints
- **Constraints:** single operator (hobbyist-but-rigorous), ARM64 hardware, limited RAM/compute, must not break the working Helm CI pipeline, prefers simplest solution that works, GitOps reviewability is a core value.

## Your task
Produce an **architecture scoping document** for introducing Terraform (or OpenTofu — recommend and justify a choice) into this repo. The explicit design goal is to manage the **gap** — external/cloud resources and bootstrap concerns currently handled manually — NOT to replace the working Helm deployment pipeline. Challenge that goal if you believe it's wrong, with reasoning.

## Deliverable structure
Address each, concretely:

1. **Scope boundary** — Draw the precise line between what Terraform should own vs. what stays in Helm/CI. Justify. Call out any resources where ownership is genuinely ambiguous (e.g. should TF manage Helm releases via the helm provider, or stay out?).
2. **Provider selection** — Which providers (b2, cloudflare/dns, tailscale, authentik, infisical, kubernetes, helm, etc.), maturity/maintenance risk of each, and ARM64/runner implications.
3. **State management** — Backend choice. Evaluate B2 (S3-compatible, already paid for) as remote state backend incl. locking limitations. Address state encryption given secrets adjacency, and how state interacts with the Infisical migration.
4. **Repo layout** — Directory structure, module boundaries, workspace vs. directory-per-environment (note: single cluster, so weigh whether multi-env abstraction is premature). Show a concrete tree.
5. **Secrets flow** — Distinguish two layers: (a) Terraform *managing the Infisical platform* (folders, identities, policies) via the infisical provider, vs. (b) Terraform *consuming* secrets from Infisical at plan/apply time. Address the bootstrap loop — TF needs an Infisical identity to manage Infisical, and that identity can't itself live in the thing it's bootstrapping. Avoid a second source of truth: secret *values* stay in Infisical; TF owns *structure/access*, not the secret material. No plaintext committed.
6. **CI/CD integration** — How `terraform plan`/`apply` fits alongside the existing Helm CI job. Plan-on-PR, apply-on-merge, drift detection, manual-approval gates. Keep it consistent with current GitHub Actions + Tailscale patterns. Address: what happens when an apply needs cluster access.
7. **Bootstrap & dependency ordering** — Chicken-and-egg problems: TF needs cluster access, state needs B2, B2 keys might be TF-managed, and the Infisical identity that lets TF manage Infisical is itself a manually-seeded root credential — document where it lives. Define the full bootstrap sequence and what's manually seeded.
8. **Migration path** — Phased rollout. Phase 1 should be the lowest-risk, highest-value slice (your pick — justify). For existing manually-created resources, `import` strategy vs. recreate. Risk of orphaning live backups/DNS during import.
9. **Risks & anti-patterns** — Where this could add complexity without payoff. When to NOT use Terraform here. Single-operator maintenance burden.

## Output requirements
- Lead with a 5-sentence executive summary + an explicit **go / partial-go / don't-bother** recommendation.
- Be opinionated and decisive; give one recommended path, note alternatives in one line each — no exhaustive option-surveys.
- Concrete over abstract: real provider names, real resource types, real file paths matching this repo's conventions.
- Flag every assumption you make about unstated details (B2 region, DNS registrar, Tailscale tier, Authentik version, Infisical self-hosted vs. cloud).
- End with a prioritized, numbered first-PR task list small enough to land in one sitting.
