#!/bin/bash
set -euo pipefail

# =============================================================================
# Palo Alto AI Red Teaming Network Client - Docker Setup (No Kubernetes/Helm)
# =============================================================================
#
# Full documentation: palo-alto-network-client-docker-setup.md
#
# Quick Start:
#   1. Create a .env file with your credentials (see documentation)
#   2. chmod +x setup-panw-network-client.sh
#   3. ./setup-panw-network-client.sh
#
# Required .env variables:
#   REGISTRY_USERNAME, REGISTRY_PASSWORD, CLIENT_ID, CLIENT_SECRET,
#   CHANNEL_ID, TENANT_PATH
#
# Optional:
#   CHART_VERSION (default: latest)
#
# Prerequisites:
#   - Docker and Docker Compose installed
#   - curl, tar, sudo access (for crane installation)
#   - Outbound HTTPS to *.paloaltonetworks.com and github.com
# =============================================================================

REGISTRY="registry.ai-red-teaming.paloaltonetworks.com"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "============================================="
echo " Palo Alto Network Client - Docker Installer"
echo "============================================="
echo ""

# --- Safe .env parser (no arbitrary code execution) ---

load_env() {
  local file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Extract key=value (strip leading whitespace, handle quoted values)
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # Strip surrounding quotes (single or double)
      if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      export "$key=$value"
    fi
  done < "$file"
}

# --- Load .env file ---

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo ""
  echo "Create a .env file with the following content:"
  echo ""
  echo '  REGISTRY_USERNAME="<docker registry username from portal step 2>"'
  echo '  REGISTRY_PASSWORD="<docker registry password from portal step 2>"'
  echo '  CLIENT_ID="<service account client ID from portal step 3>"'
  echo '  CLIENT_SECRET="<service account client secret from portal step 3>"'
  echo '  CHANNEL_ID="<channel ID from portal step 4>"'
  echo '  TENANT_PATH="<e.g. pairs-redteam-prd-fckx/red-teaming-onprem>"'
  echo '  CHART_VERSION="latest"'
  echo ""
  exit 1
fi

load_env "$ENV_FILE"

# --- Validate required variables ---

MISSING=0
for VAR in REGISTRY_USERNAME REGISTRY_PASSWORD CLIENT_ID CLIENT_SECRET CHANNEL_ID TENANT_PATH; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: $VAR is not set in .env"
    MISSING=1
  fi
done
[ "$MISSING" -eq 1 ] && exit 1

# Default chart version to latest if not set
CHART_VERSION="${CHART_VERSION:-latest}"

# Validate TENANT_PATH format
TENANT_PATH="${TENANT_PATH#/}"
TENANT_PATH="${TENANT_PATH%/}"
if [[ ! "$TENANT_PATH" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*$ ]]; then
  echo "ERROR: TENANT_PATH contains invalid characters: $TENANT_PATH"
  echo "  Expected format: org-id/product (e.g., pairs-redteam-prd-fckx/red-teaming-onprem)"
  exit 1
fi

echo "Registry:      $REGISTRY"
echo "Tenant path:   $TENANT_PATH"
echo "Chart version: $CHART_VERSION"
echo ""

# --- Step 1: Install crane ---

echo "--- Step 1: Installing crane ---"

if command -v crane &>/dev/null; then
  echo "crane already installed, skipping."
else
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Linux)
      case "$ARCH" in
        x86_64)  CRANE_ARCH="x86_64" ;;
        aarch64) CRANE_ARCH="arm64" ;;
        *)       echo "ERROR: Unsupported Linux architecture: $ARCH (supported: x86_64, aarch64)"; exit 1 ;;
      esac
      OS_NAME="Linux"
      ;;
    Darwin)
      case "$ARCH" in
        x86_64) CRANE_ARCH="x86_64" ;;
        arm64)  CRANE_ARCH="arm64" ;;
        *)      echo "ERROR: Unsupported macOS architecture: $ARCH (supported: x86_64, arm64)"; exit 1 ;;
      esac
      OS_NAME="Darwin"
      ;;
    *)
      echo "ERROR: Unsupported OS: $OS (supported: Linux, Darwin)"
      exit 1
      ;;
  esac

  CRANE_URL="https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_${OS_NAME}_${CRANE_ARCH}.tar.gz"
  CRANE_TMP="$(mktemp -d)/crane.tar.gz"

  echo "Downloading crane for ${OS_NAME}/${CRANE_ARCH}..."
  curl -fsSL "$CRANE_URL" -o "$CRANE_TMP"
  sudo tar -xzf "$CRANE_TMP" --no-same-owner -C /usr/local/bin crane
  rm -f "$CRANE_TMP"
  echo "crane installed."
fi

echo ""
echo "--- Step 2: Logging into registry ---"

echo "$REGISTRY_PASSWORD" | crane auth login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
echo "Registry login successful."

# --- Resolve chart version if "latest" ---

CHART_REF="${REGISTRY}/${TENANT_PATH}/charts/panw-network-client"

if [ "$CHART_VERSION" = "latest" ]; then
  echo ""
  echo "--- Resolving latest chart version ---"
  AVAILABLE_TAGS=$(crane ls "$CHART_REF" 2>/dev/null || true)
  if [ -z "$AVAILABLE_TAGS" ]; then
    echo "ERROR: Could not list chart versions. Check TENANT_PATH and registry credentials."
    echo "  Attempted: $CHART_REF"
    echo "  Try running: crane ls $CHART_REF"
    exit 1
  fi
  # Pick the highest semver tag (with portable fallback)
  if echo "1.0.0" | sort -V &>/dev/null 2>&1; then
    CHART_VERSION=$(echo "$AVAILABLE_TAGS" | sort -V | tail -1)
  else
    CHART_VERSION=$(echo "$AVAILABLE_TAGS" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  fi
  echo "Latest chart version: $CHART_VERSION"
fi

echo ""
echo "--- Step 3: Extracting chart to discover image and config ---"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

crane pull "${CHART_REF}:${CHART_VERSION}" "$WORK_DIR/chart.tar"
mkdir -p "$WORK_DIR/chart-extract"
tar -xf "$WORK_DIR/chart.tar" --no-same-owner -C "$WORK_DIR/chart-extract"

# Extract chart layers (tgz inside the OCI artifact)
cd "$WORK_DIR/chart-extract"
shopt -s nullglob
for f in *.tar.gz *.tgz sha256:*; do
  [ -f "$f" ] && tar -xzf "$f" --no-same-owner 2>/dev/null || true
done
shopt -u nullglob
cd "$SCRIPT_DIR"

# Find the chart's values.yaml (prefer the root chart, not subcharts)
CHART_DIR=$(find "$WORK_DIR/chart-extract" -name "Chart.yaml" -exec dirname {} \; 2>/dev/null | head -1)
if [ -n "$CHART_DIR" ] && [ -f "$CHART_DIR/values.yaml" ]; then
  VALUES_FILE="$CHART_DIR/values.yaml"
else
  VALUES_FILE=$(find "$WORK_DIR/chart-extract" -maxdepth 3 -name "values.yaml" 2>/dev/null | head -1)
fi

if [ -z "$VALUES_FILE" ] || [ ! -f "$VALUES_FILE" ]; then
  echo "ERROR: Could not find values.yaml in the chart."
  echo "  Chart ref: ${CHART_REF}:${CHART_VERSION}"
  echo "  Extracted to: $WORK_DIR/chart-extract"
  exit 1
fi

echo "Found values at: $VALUES_FILE"

# Parse image repository and tag from values.yaml
IMAGE_REPO=$(grep -A5 "^image:" "$VALUES_FILE" | grep "repository:" | head -1 | sed 's/.*repository:[[:space:]]*//' | sed "s/[\"']//g" | xargs)
IMAGE_TAG=$(grep -A5 "^image:" "$VALUES_FILE" | grep "tag:" | head -1 | sed 's/.*tag:[[:space:]]*//' | sed "s/[\"']//g" | xargs)

if [ -z "$IMAGE_REPO" ] || [ -z "$IMAGE_TAG" ]; then
  echo "ERROR: Could not parse image from values.yaml"
  echo "Contents of values.yaml:"
  cat "$VALUES_FILE"
  exit 1
fi

# Validate image reference format
if [[ ! "$IMAGE_REPO" =~ ^[a-zA-Z0-9._:/-]+$ ]]; then
  echo "ERROR: Image repository contains invalid characters: $IMAGE_REPO"
  exit 1
fi
if [[ ! "$IMAGE_TAG" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: Image tag contains invalid characters: $IMAGE_TAG"
  exit 1
fi

FULL_IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
echo "Discovered image: $FULL_IMAGE"

# Parse config defaults from values.yaml
parse_value() {
  local raw
  raw=$(grep "$1:" "$VALUES_FILE" | head -1 | sed "s/.*$1:[[:space:]]*//" | sed "s/[\"']//g" | xargs)
  echo "$raw"
}

LOG_LEVEL=$(parse_value "logLevel")
PRETTY_LOGS=$(parse_value "prettyLogs")
HANDSHAKE_TIMEOUT=$(parse_value "handshakeTimeout")
PROXY_TIMEOUT=$(parse_value "proxyTimeout")
CONNECTION_RETRY_INTERVAL=$(parse_value "connectionRetryInterval")
POOL_SIZE=$(parse_value "poolSize")
RE_AUTH_INTERVAL=$(parse_value "reAuthInterval")
DISABLE_SSL_VERIFICATION=$(parse_value "disableSSLVerification")

# Defaults if parsing fails
LOG_LEVEL="${LOG_LEVEL:-INFO}"
PRETTY_LOGS="${PRETTY_LOGS:-false}"
HANDSHAKE_TIMEOUT="${HANDSHAKE_TIMEOUT:-10s}"
PROXY_TIMEOUT="${PROXY_TIMEOUT:-100s}"
CONNECTION_RETRY_INTERVAL="${CONNECTION_RETRY_INTERVAL:-5s}"
POOL_SIZE="${POOL_SIZE:-2048}"
RE_AUTH_INTERVAL="${RE_AUTH_INTERVAL:-5m}"
DISABLE_SSL_VERIFICATION="${DISABLE_SSL_VERIFICATION:-false}"

# Warn about insecure SSL setting
if [ "${DISABLE_SSL_VERIFICATION}" = "true" ]; then
  echo ""
  echo "!!! WARNING: DISABLE_SSL_VERIFICATION is set to 'true' !!!"
  echo "!!! This disables TLS certificate validation and exposes"
  echo "!!! all traffic to man-in-the-middle attacks."
  echo "!!! This should NEVER be used in production."
  echo ""
fi

echo ""
echo "--- Step 4: Pulling container image ---"

crane pull "$FULL_IMAGE" "$SCRIPT_DIR/panw-client.tar"
docker load -i "$SCRIPT_DIR/panw-client.tar"
rm -f "$SCRIPT_DIR/panw-client.tar"
echo "Image loaded into Docker."

echo ""
echo "--- Step 5: Writing configuration files ---"

# Write setup credentials (used only by this script)
cat > "${SCRIPT_DIR}/.env.setup" <<'SETUP_EOF'
# --- Setup credentials (used by setup-panw-network-client.sh) ---
# This file is NOT passed to the container.
SETUP_EOF

# Append actual values with proper quoting (printf prevents command substitution)
{
  printf 'REGISTRY_USERNAME="%s"\n' "${REGISTRY_USERNAME//\"/\\\"}"
  printf 'REGISTRY_PASSWORD="%s"\n' "${REGISTRY_PASSWORD//\"/\\\"}"
  printf 'TENANT_PATH="%s"\n' "${TENANT_PATH//\"/\\\"}"
  printf 'CHART_VERSION="%s"\n' "${CHART_VERSION//\"/\\\"}"
} >> "${SCRIPT_DIR}/.env.setup"
chmod 600 "${SCRIPT_DIR}/.env.setup"

# Write runtime config (passed to the container)
cat > "${SCRIPT_DIR}/.env.runtime" <<'RUNTIME_EOF'
# --- Runtime config (used by the container) ---
RUNTIME_EOF

{
  printf 'CLIENT_ID="%s"\n' "${CLIENT_ID//\"/\\\"}"
  printf 'CLIENT_SECRET="%s"\n' "${CLIENT_SECRET//\"/\\\"}"
  printf 'CHANNEL_ID="%s"\n' "${CHANNEL_ID//\"/\\\"}"
  printf 'LOG_LEVEL="%s"\n' "${LOG_LEVEL//\"/\\\"}"
  printf 'PRETTY_LOGS="%s"\n' "${PRETTY_LOGS//\"/\\\"}"
  printf 'HANDSHAKE_TIMEOUT="%s"\n' "${HANDSHAKE_TIMEOUT//\"/\\\"}"
  printf 'PROXY_TIMEOUT="%s"\n' "${PROXY_TIMEOUT//\"/\\\"}"
  printf 'CONNECTION_RETRY_INTERVAL="%s"\n' "${CONNECTION_RETRY_INTERVAL//\"/\\\"}"
  printf 'POOL_SIZE="%s"\n' "${POOL_SIZE//\"/\\\"}"
  printf 'RE_AUTH_INTERVAL="%s"\n' "${RE_AUTH_INTERVAL//\"/\\\"}"
  printf 'DISABLE_SSL_VERIFICATION="%s"\n' "${DISABLE_SSL_VERIFICATION//\"/\\\"}"
} >> "${SCRIPT_DIR}/.env.runtime"
chmod 600 "${SCRIPT_DIR}/.env.runtime"

echo ".env.setup and .env.runtime created (mode 600)."

echo ""
echo "--- Step 6: Creating docker-compose.yml ---"

cat > "$SCRIPT_DIR/docker-compose.yml" <<EOF
services:
  panw-network-client:
    image: "${FULL_IMAGE}"
    command: ["/app/client"]
    env_file:
      - .env.runtime
    restart: unless-stopped
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /tmp
    mem_limit: 512m
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

echo "docker-compose.yml created."

# --- Detect docker compose command ---

if docker compose version &>/dev/null; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  echo "ERROR: Neither 'docker compose' (v2) nor 'docker-compose' (v1) found."
  echo "  Install Docker Compose: https://docs.docker.com/compose/install/"
  exit 1
fi

echo "Using: $COMPOSE"

echo ""
echo "--- Step 7: Starting the client ---"

cd "$SCRIPT_DIR"
$COMPOSE up -d

echo ""
echo "--- Step 8: Checking logs ---"
echo ""
echo "Waiting 10 seconds for the client to start..."
sleep 10

$COMPOSE logs panw-network-client

echo ""
echo "============================================="
echo " Setup complete!"
echo " Files in: $SCRIPT_DIR"
echo ""
echo " Config files:"
echo "   .env.setup   - Registry credentials (script use only)"
echo "   .env.runtime - Container runtime config"
echo "   docker-compose.yml"
echo ""
echo " Commands:"
echo "   Follow logs:  $COMPOSE logs -f panw-network-client"
echo "   Stop:         $COMPOSE down"
echo "   Restart:      $COMPOSE up -d"
echo "   Update:       change CHART_VERSION in .env and rerun this script"
echo "============================================="
