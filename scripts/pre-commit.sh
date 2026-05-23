#!/usr/bin/env bash
# Pre-commit hook for homelab-k8s.
#
# Runs the following on staged changes (fail-fast checks first, then mutations):
#   1. Infisical secret scan   — block commits that leak credentials
#   2. yamllint                — lint staged YAML (mirrors `make lint`)
#   3. helm lint               — lint charts with staged changes
#   4. File hygiene            — block merge markers / whitespace errors / huge files
#   5. Chart version auto-bump — patch-bump Chart.yaml for changed charts (re-stages)
#
# Install with: make setup-hooks
# Skip in an emergency with: git commit --no-verify

set -uo pipefail

CHARTS_DIR="charts"
MAX_FILE_BYTES=$((1024 * 1024)) # 1 MiB
SCAN_CONFIG=".infisical-scan.toml"

fail=0

# Staged files, added/copied/modified only (skip deletions).
mapfile -t staged_files < <(git diff --cached --name-only --diff-filter=ACM)

if [[ ${#staged_files[@]} -eq 0 ]]; then
    exit 0
fi

# Staged YAML files (charts, k8s manifests, top-level config).
staged_yaml=()
for f in "${staged_files[@]}"; do
    [[ "$f" == *.yaml || "$f" == *.yml ]] && staged_yaml+=("$f")
done

# ---------------------------------------------------------------------------
# 1. Infisical secret scan
# ---------------------------------------------------------------------------
if command -v infisical >/dev/null 2>&1; then
    echo "→ infisical: scanning staged changes for secrets"
    # Pipe the staged diff through scan --pipe. (git-changes --staged is
    # unreliable on this CLI version — it scans commits, not the index.)
    if ! git diff --cached | infisical scan --pipe \
        --config "$SCAN_CONFIG" --redact --no-color; then
        echo "✗ infisical: potential secret detected in staged changes (see above)."
        echo "  Inspect with: git diff --cached | infisical scan --pipe --verbose"
        echo "  False positive? Add a rule/path to $SCAN_CONFIG or .infisicalignore"
        fail=1
    fi
else
    echo "⚠ infisical CLI not found — skipping secret scan (https://infisical.com/docs/cli)"
fi

# ---------------------------------------------------------------------------
# 2. yamllint
# ---------------------------------------------------------------------------
if [[ ${#staged_yaml[@]} -gt 0 ]]; then
    if command -v yamllint >/dev/null 2>&1; then
        echo "→ yamllint: ${#staged_yaml[@]} staged YAML file(s)"
        if ! yamllint "${staged_yaml[@]}"; then
            echo "✗ yamllint: fix the issues above (or run 'make fix' to auto-format)."
            fail=1
        fi
    else
        echo "⚠ yamllint not found — skipping (pip install yamllint)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. helm lint (charts with staged changes)
# ---------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
    changed_charts=()
    for f in "${staged_files[@]}"; do
        if [[ "$f" == "$CHARTS_DIR/"* ]]; then
            chart=$(echo "$f" | cut -d/ -f2)
            [[ -f "$CHARTS_DIR/$chart/Chart.yaml" ]] && changed_charts+=("$chart")
        fi
    done
    mapfile -t changed_charts < <(printf '%s\n' "${changed_charts[@]}" | sort -u)

    for chart in "${changed_charts[@]}"; do
        [[ -z "$chart" ]] && continue
        echo "→ helm lint: $chart"
        if ! helm lint "$CHARTS_DIR/$chart"; then
            echo "✗ helm lint failed for $chart."
            fail=1
        fi
    done
else
    echo "⚠ helm not found — skipping chart lint"
fi

# ---------------------------------------------------------------------------
# 4. File hygiene — merge markers, whitespace errors, oversized files
# ---------------------------------------------------------------------------
# `git diff --cached --check` catches conflict markers and whitespace errors.
if ! git diff --cached --check; then
    echo "✗ whitespace errors or conflict markers in staged changes (see above)."
    fail=1
fi

for f in "${staged_files[@]}"; do
    [[ -f "$f" ]] || continue
    size=$(wc -c <"$f" | tr -d ' ')
    if [[ "$size" -gt "$MAX_FILE_BYTES" ]]; then
        echo "✗ $f is $((size / 1024)) KiB (> $((MAX_FILE_BYTES / 1024)) KiB). Use git-lfs or .gitignore it."
        fail=1
    fi
done

# Stop before mutating anything if a check failed.
if [[ "$fail" -ne 0 ]]; then
    echo ""
    echo "Pre-commit checks failed. Fix the above, or bypass with: git commit --no-verify"
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Chart patch-version auto-bump
#    Bump charts whose templates/values changed but whose version still
#    matches main (i.e. the author forgot to bump). Re-stages Chart.yaml.
# ---------------------------------------------------------------------------
bump_charts=()
for f in "${staged_files[@]}"; do
    if [[ "$f" == "$CHARTS_DIR/"* ]]; then
        chart=$(echo "$f" | cut -d/ -f2)
        [[ -f "$CHARTS_DIR/$chart/Chart.yaml" ]] && bump_charts+=("$chart")
    fi
done
mapfile -t bump_charts < <(printf '%s\n' "${bump_charts[@]}" | sort -u)

for chart in "${bump_charts[@]}"; do
    [[ -z "$chart" ]] && continue
    chart_yaml="$CHARTS_DIR/$chart/Chart.yaml"

    # Skip if Chart.yaml was already staged (author bumped manually).
    if printf '%s\n' "${staged_files[@]}" | grep -q "^$chart_yaml$"; then
        continue
    fi

    current_version=$(grep '^version:' "$chart_yaml" | awk '{print $2}' | tr -d '"')
    main_version=$(git show main:"$chart_yaml" 2>/dev/null | grep '^version:' | awk '{print $2}' | tr -d '"' || true)

    # New chart with no version on main — nothing to bump against.
    [[ -z "$main_version" ]] && continue

    if [[ "$current_version" == "$main_version" ]]; then
        IFS='.' read -r major minor patch <<<"$current_version"
        new_version="$major.$minor.$((patch + 1))"
        sed -i '' "s/^version: $current_version/version: $new_version/" "$chart_yaml"
        git add "$chart_yaml"
        echo "↑ auto-bumped $chart: $current_version → $new_version"
    fi
done

exit 0
