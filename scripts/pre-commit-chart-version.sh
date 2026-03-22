#!/usr/bin/env bash
# Pre-commit hook: auto-bump patch version for modified Helm charts
# that haven't had their Chart.yaml version updated.

set -euo pipefail

CHARTS_DIR="charts"

# Get list of staged files
staged_files=$(git diff --cached --name-only)

# Find charts with staged changes (excluding Chart.yaml itself)
changed_charts=()
for file in $staged_files; do
    if [[ "$file" == "$CHARTS_DIR/"* ]]; then
        # Extract chart name (second path component)
        chart=$(echo "$file" | cut -d/ -f2)
        chart_yaml="$CHARTS_DIR/$chart/Chart.yaml"
        if [[ -f "$chart_yaml" ]]; then
            changed_charts+=("$chart")
        fi
    fi
done

# Deduplicate
changed_charts=($(printf '%s\n' "${changed_charts[@]}" | sort -u))

for chart in "${changed_charts[@]}"; do
    chart_yaml="$CHARTS_DIR/$chart/Chart.yaml"

    # Skip if Chart.yaml itself was already modified (user bumped manually)
    if echo "$staged_files" | grep -q "^$chart_yaml$"; then
        continue
    fi

    # Get current version from the staged/working tree
    current_version=$(grep '^version:' "$chart_yaml" | awk '{print $2}' | tr -d '"')

    # Check if this version exists on main (new charts won't have a prior version)
    main_version=$(git show main:"$chart_yaml" 2>/dev/null | grep '^version:' | awk '{print $2}' | tr -d '"' || true)

    if [[ -z "$main_version" ]]; then
        # New chart, no bump needed
        continue
    fi

    if [[ "$current_version" == "$main_version" ]]; then
        # Auto-bump patch version
        IFS='.' read -r major minor patch <<< "$current_version"
        new_version="$major.$minor.$((patch + 1))"
        sed -i '' "s/^version: $current_version/version: $new_version/" "$chart_yaml"
        git add "$chart_yaml"
        echo "Auto-bumped $chart: $current_version → $new_version"
    fi
done
