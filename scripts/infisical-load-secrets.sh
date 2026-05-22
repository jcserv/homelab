#!/usr/bin/env bash
#
# Load secrets from a .env file into a self-hosted Infisical instance.
#
# Reads KEY=VALUE lines from .env (comments and blanks ignored) and pushes
# them as shared secrets via the Infisical CLI. Uses your existing
# `infisical login` session and the workspaceId from .infisical.json.
#
# Usage:
#   ./scripts/infisical-load-secrets.sh [--prod|--dev|--staging] [--file path] [--path /folder] [--dry-run]
#
# Examples:
#   ./scripts/infisical-load-secrets.sh                 # -> dev, ./.env
#   ./scripts/infisical-load-secrets.sh --prod          # -> prod
#   ./scripts/infisical-load-secrets.sh --file .env.ci  # custom file
#
set -euo pipefail

# --- Config: edit DOMAIN for your self-hosted instance (or export INFISICAL_API_URL) ---
DOMAIN="${INFISICAL_API_URL:-https://infisical.jarrodservilla.com}"

# --- Defaults ---
ENVIRONMENT="dev"
ENV_FILE=".env"
SECRET_PATH="/"
DRY_RUN=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod)    ENVIRONMENT="prod";    shift ;;
    --dev)     ENVIRONMENT="dev";     shift ;;
    --staging) ENVIRONMENT="staging"; shift ;;
    --file)    ENV_FILE="$2";         shift 2 ;;
    --path)    SECRET_PATH="$2";      shift 2 ;;
    --dry-run) DRY_RUN=true;          shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Preflight ---
command -v infisical >/dev/null || { echo "ERROR: infisical CLI not found" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: env file not found: $ENV_FILE" >&2; exit 1; }
if [[ "$DOMAIN" == *example.com* ]]; then
  echo "ERROR: set DOMAIN in this script or export INFISICAL_API_URL" >&2
  exit 1
fi

# --- Warn on lines that are not KEY=value (CLI rejects them) ---
BAD=$(grep -nvE '^\s*(#|$|[A-Za-z_][A-Za-z0-9_]*=)' "$ENV_FILE" || true)
if [[ -n "$BAD" ]]; then
  echo "WARNING: skipping malformed line(s) (not KEY=value):" >&2
  echo "$BAD" | sed -E 's/=.*/=***/' >&2
fi

# --- Build a clean temp file: only valid KEY=value lines ---
CLEAN_FILE=$(mktemp)
trap 'rm -f "$CLEAN_FILE"' EXIT
grep -E '^\s*(#|[A-Za-z_][A-Za-z0-9_]*=)' "$ENV_FILE" > "$CLEAN_FILE" || true

COUNT=$(grep -cvE '^\s*(#|$)' "$CLEAN_FILE" || true)
echo "Loading $COUNT secret(s) from '$ENV_FILE' -> env='$ENVIRONMENT' path='$SECRET_PATH' @ $DOMAIN"

if $DRY_RUN; then
  echo "[dry-run] keys to push:"
  grep -vE '^\s*(#|$)' "$CLEAN_FILE" | sed -E 's/=.*/=***/' | sort
  exit 0
fi

# --- Push (bulk, single API call; --file is mutually exclusive with inline args) ---
infisical secrets set \
  --domain "$DOMAIN" \
  --env "$ENVIRONMENT" \
  --path "$SECRET_PATH" \
  --type shared \
  --file "$CLEAN_FILE" \
  --silent

echo "Done. $COUNT secret(s) set in '$ENVIRONMENT'."
