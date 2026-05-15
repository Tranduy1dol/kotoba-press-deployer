#!/usr/bin/env bash
set -euo pipefail

REPO="Tranduy1dol/kotoba-press-deployer"
RESOURCE_GROUP="kotoba-press-rg"

# Env var prefixes → Azure Container App name
# APP_*           → kotoba-core
# APP_SEARCH__* → search-grpc

usage() {
  echo "Usage: $0 <environment> <target>"
  echo ""
  echo "  environment:  local | production"
  echo "  target:       github | azure | all"
  echo ""
  echo "Examples:"
  echo "  $0 production github    # Push production secrets to GitHub"
  echo "  $0 production azure     # Push production secrets to Azure (all 3 apps)"
  echo "  $0 production all       # Push to both GitHub and Azure"
  exit 0
}

[ $# -lt 2 ] && usage

ENV_NAME="$1"
TARGET="$2"
ENV_FILE="env/.env.${ENV_NAME}"

if [ ! -f "$ENV_FILE" ]; then
  echo "$ENV_FILE not found."
  echo "Available environments:"
  ls env/.env.* 2>/dev/null | sed 's|env/.env.||; s/^/   - /' || echo "   (none)"
  exit 1
fi

echo "Environment: $ENV_NAME ($ENV_FILE)"
echo ""

# Parse env file: skip comments and blank lines
load_env() {
  grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$'
}

# Determine which Azure Container App a var belongs to
get_app_name() {
  local key="$1"
  case "$key" in
    APP_SEARCH__*)    echo "search-grpc" ;;
    APP_*)            echo "kotoba-core" ;;
    *)                echo "kotoba-core" ;;
  esac
}

# ── GitHub: push all vars as repo secrets ──
sync_github() {
  echo "Syncing to GitHub ($REPO)..."
  while IFS='=' read -r key value; do
    echo "  → $key"
    echo "$value" | gh secret set "$key" --repo "$REPO"
  done < <(load_env)
  echo "GitHub secrets synced"
}

# ── Azure: push vars to the correct container app ──
sync_azure() {
  echo "Syncing to Azure Container Apps..."

  # Group vars by container app
  declare -A ui_secrets core_secrets search_secrets

  while IFS='=' read -r key value; do
    app=$(get_app_name "$key")
    azure_key=$(echo "$key" | tr '[:upper:]_' '[:lower:]-')
    case "$app" in
      kotoba-core)  core_secrets["$azure_key"]="$value" ;;
      search-grpc)  search_secrets["$azure_key"]="$value" ;;
    esac
    echo "  → $key → $app ($azure_key)"
  done < <(load_env)

  # Helper: push secrets to a container app
  push_to_app() {
    local app_name="$1"
    shift
    local -n secrets_map="$1"

    if [ ${#secrets_map[@]} -eq 0 ]; then return; fi

    local args=""
    for k in "${!secrets_map[@]}"; do
      args+="${k}=${secrets_map[$k]} "
    done

    echo ""
    echo "  Pushing ${#secrets_map[@]} secrets to $app_name..."
    az containerapp secret set \
      --name "$app_name" \
      --resource-group "$RESOURCE_GROUP" \
      --secrets $args
  }

  push_to_app "kotoba-core"  core_secrets
  push_to_app "search-grpc"  search_secrets

  echo "Azure secrets synced"
}

sync_azure_docker() {
  echo "Syncing to Azure via Docker..."
  echo "   Mounting env file into the Azure CLI container."
  echo ""

  docker run --rm -it \
    -v "$(pwd)/$ENV_FILE:/tmp/.env:ro" \
    -v "$HOME/.azure:/root/.azure" \
    mcr.microsoft.com/azure-cli \
    bash -c '
      set -euo pipefail
      ENV_FILE="/tmp/.env"
      RESOURCE_GROUP="'"$RESOURCE_GROUP"'"

      load_env() { grep -v "^\s*#" "$ENV_FILE" | grep -v "^\s*$"; }

      get_app() {
        case "$1" in
          APP_SEARCH__*)    echo "search-grpc" ;;
          APP_*)            echo "kotoba-core" ;;
          *)                echo "kotoba-core" ;;
        esac
      }

      declare -A app_secrets
      while IFS="=" read -r key value; do
        app=$(get_app "$key")
        azure_key=$(echo "$key" | tr "[:upper:]_" "[:lower:]-")
        app_secrets["$app"]+="${azure_key}=${value} "
        echo "  → $key → $app ($azure_key)"
      done < <(load_env)

      for app in "${!app_secrets[@]}"; do
        echo ""
        echo "Pushing to $app..."
        az containerapp secret set \
          --name "$app" \
          --resource-group "$RESOURCE_GROUP" \
          --secrets ${app_secrets[$app]}
      done

      echo "Azure secrets synced"
    '
}

case "$TARGET" in
  github)       sync_github ;;
  azure)        sync_azure ;;
  azure-docker) sync_azure_docker ;;
  all)          sync_github; sync_azure ;;
  all-docker)   sync_github; sync_azure_docker ;;
  *)            usage ;;
esac
