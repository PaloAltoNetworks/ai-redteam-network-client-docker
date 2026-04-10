#!/bin/bash
set -euo pipefail

# =============================================================================
# Palo Alto AI Red Teaming Network Client - Docker Setup (No Kubernetes/Helm)
# =============================================================================
#
# Usage:
#   ./setup-panw-network-client.sh [OPTIONS]
#
# Options:
#   --init            Interactive guided setup (creates .env from portal values)
#   --dry-run         Show what would happen without making changes
#   --status          Check current deployment state
#   --validate        Verify the channel is connected after setup
#   --diagnose        Analyze container logs for common issues
#   --help            Show this help message
#
# Quick Start:
#   1. ./setup-panw-network-client.sh --init
#   2. ./setup-panw-network-client.sh
#
# Or manually:
#   1. cp .env.example .env && edit .env
#   2. ./setup-panw-network-client.sh
#
# Prerequisites:
#   - Docker (20.10+) with Docker Compose
#   - curl, tar
#   - Outbound HTTPS to *.paloaltonetworks.com and github.com
# =============================================================================

# --- Constants ---

REGISTRY="registry.ai-red-teaming.paloaltonetworks.com"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DEPLOY_LOG="${SCRIPT_DIR}/deploy.log"
CRANE_VERSION="0.21.3"
CRANE_SHA256_DARWIN_ARM64="4c00c3a1ecfac44601abb9a4ef0223f491e3eeb4193c9e644540fb1ea6f2275d"
CRANE_SHA256_DARWIN_X86_64="ee6b02fa1864dca869df0f71838c60048502ab6eed681d795903ecf356471653"
CRANE_SHA256_LINUX_X86_64="46dbf12d943efa5673ab654186c5d7c1503580544de0df9325537083436fe5d0"
CRANE_SHA256_LINUX_ARM64="dabcf2aee76ca72da63b5da5137c910a6852ccff13e35628e8f0a9dd8b73f4f3"

# --- Color output (respects NO_COLOR) ---

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# --- Output helpers ---

info()    { [ "$QUIET" = true ] || printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
success() { [ "$QUIET" = true ] || printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
error()   { printf "${RED}[ERR]${NC}  %s\n" "$1" >&2; }
die()     { error "$1"; exit 1; }
step()    { [ "$QUIET" = true ] || printf "\n${BOLD}--- Step %s: %s ---${NC}\n" "$1" "$2"; }

# --- Deployment audit log ---

log_deploy() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf "[%s] user=%s action=%s %s\n" "$ts" "$(whoami)" "$1" "${2:-}" >> "$DEPLOY_LOG"
  chmod 600 "$DEPLOY_LOG" 2>/dev/null || true
}

# --- Usage ---

usage() {
  cat <<'USAGE'
Usage:
  ./setup-panw-network-client.sh [OPTIONS]

Options:
  --init            Interactive guided setup (creates .env from portal values)
  --dry-run         Show what would happen without making changes
  --status          Check current deployment state
  --validate        Verify the channel is connected after setup
  --diagnose        Analyze container logs for common issues
  --quiet, -q       Suppress info/success output (errors and warnings only)
  --help            Show this help message

Quick Start:
  1. ./setup-panw-network-client.sh --init
  2. ./setup-panw-network-client.sh

Or manually:
  1. cp .env.example .env && edit .env
  2. ./setup-panw-network-client.sh
USAGE
  exit 0
}

# --- Parse CLI arguments ---

MODE="install"
DRY_RUN=false
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --init)      MODE="init"; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --status)    MODE="status"; shift ;;
    --validate)  MODE="validate"; shift ;;
    --diagnose)  MODE="diagnose"; shift ;;
    --quiet|-q)  QUIET=true; shift ;;
    --help|-h)   usage ;;
    *)           error "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Safe .env parser (no arbitrary code execution) ---

load_env() {
  local file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      export "$key=$value"
    fi
  done < "$file"
}

# --- Detect docker compose command ---

detect_compose() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    echo ""
  fi
}

# --- Extract TENANT_PATH from OCI URL ---

parse_tenant_path() {
  local url="$1"
  # Strip oci:// prefix, registry host, and /charts/panw-network-client suffix
  url="${url#oci://}"
  url="${url#https://}"
  url="${url#${REGISTRY}/}"
  url="${url%/charts/panw-network-client*}"
  echo "$url"
}

# =============================================================================
# MODE: --init (Interactive guided setup)
# =============================================================================

do_init() {
  echo ""
  printf "${BOLD}=============================================${NC}\n"
  printf "${BOLD} Palo Alto Network Client - Interactive Setup${NC}\n"
  printf "${BOLD}=============================================${NC}\n"
  echo ""
  info "This will guide you through creating your .env file."
  info "Have the AI Red Teaming portal open to Channel Setup."
  echo ""

  if [ -f "$ENV_FILE" ]; then
    warn ".env file already exists at $ENV_FILE"
    printf "  Overwrite? [y/N] "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      info "Keeping existing .env file."
      exit 0
    fi
  fi

  # Step 2: Registry credentials
  printf "\n${BOLD}Portal Step 2: Docker Registry Credentials${NC}\n"
  info "Find the username and password in the 'kubectl create secret' command."
  echo ""
  printf "  Registry Username: "
  read -r REG_USER
  printf "  Registry Password: "
  read -rs REG_PASS
  echo ""

  # Validate registry credentials immediately
  info "Validating registry credentials..."
  if command -v crane &>/dev/null; then
    if printf '%s\n' "$REG_PASS" | crane auth login "$REGISTRY" -u "$REG_USER" --password-stdin 2>/dev/null; then
      success "Registry credentials valid."
    else
      warn "Could not validate credentials (may still work). Continuing..."
    fi
  else
    info "Skipping validation (crane not yet installed). Will verify during setup."
  fi

  # Step 3: Service account
  printf "\n${BOLD}Portal Step 3: Service Account${NC}\n"
  info "Create a service account in the portal and copy the Client ID and Secret."
  echo ""
  printf "  Client ID: "
  read -r SA_CLIENT_ID
  printf "  Client Secret: "
  read -rs SA_CLIENT_SECRET
  echo ""

  # Step 4: Channel ID and tenant path
  printf "\n${BOLD}Portal Step 4: Channel Configuration${NC}\n"
  echo ""
  printf "  Channel ID: "
  read -r CH_ID

  echo ""
  info "The Tenant Path can be extracted from the helm install command in Step 4."
  info "You can paste the FULL OCI URL or just the tenant path."
  info "Example OCI URL: oci://registry.ai-red-teaming.paloaltonetworks.com/pairs-redteam-prd-fckx/red-teaming-onprem/charts/panw-network-client"
  info "Example tenant path: pairs-redteam-prd-fckx/red-teaming-onprem"
  echo ""
  printf "  OCI URL or Tenant Path: "
  read -r TENANT_INPUT

  # Auto-detect and parse tenant path from full URL
  if [[ "$TENANT_INPUT" == *"$REGISTRY"* ]] || [[ "$TENANT_INPUT" == oci://* ]]; then
    TENANT=$(parse_tenant_path "$TENANT_INPUT")
    info "Auto-extracted tenant path: $TENANT"
  else
    TENANT="$TENANT_INPUT"
  fi

  # Chart version
  echo ""
  printf "  Chart version [latest]: "
  read -r CHART_VER
  CHART_VER="${CHART_VER:-latest}"

  # Write .env
  {
    printf '# Generated by setup-panw-network-client.sh --init\n'
    printf '# Date: %s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'REGISTRY_USERNAME="%s"\n' "$REG_USER"
    printf 'REGISTRY_PASSWORD="%s"\n' "$REG_PASS"
    printf 'CLIENT_ID="%s"\n' "$SA_CLIENT_ID"
    printf 'CLIENT_SECRET="%s"\n' "$SA_CLIENT_SECRET"
    printf 'CHANNEL_ID="%s"\n' "$CH_ID"
    printf 'TENANT_PATH="%s"\n' "$TENANT"
    printf 'CHART_VERSION="%s"\n' "$CHART_VER"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  echo ""
  success ".env file created at $ENV_FILE (mode 600)"
  echo ""
  info "Next: run ./setup-panw-network-client.sh to deploy."
  log_deploy "init" "env_file_created"
}

# =============================================================================
# MODE: --status (Check current deployment state)
# =============================================================================

do_status() {
  printf "${BOLD}=============================================${NC}\n"
  printf "${BOLD} Deployment Status${NC}\n"
  printf "${BOLD}=============================================${NC}\n"
  echo ""

  # Check files
  local files_ok=true
  for f in .env.runtime docker-compose.yml; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
      success "$f exists"
    else
      warn "$f not found"
      files_ok=false
    fi
  done

  # Check compose
  local COMPOSE
  COMPOSE=$(detect_compose)
  if [ -z "$COMPOSE" ]; then
    error "Docker Compose not found"
    return 1
  fi

  # Check container
  echo ""
  cd "$SCRIPT_DIR"
  if $COMPOSE ps --format json 2>/dev/null | grep -q "panw-network-client"; then
    local state
    state=$($COMPOSE ps --format json 2>/dev/null | grep "panw-network-client" || true)
    success "Container is running"
    echo "$state" | head -3
  elif $COMPOSE ps 2>/dev/null | grep -q "panw-network-client"; then
    success "Container found"
    $COMPOSE ps 2>/dev/null | grep "panw-network-client"
  else
    warn "Container not running"
  fi

  # Check image version
  echo ""
  if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    local img
    img=$(grep "image:" "$SCRIPT_DIR/docker-compose.yml" | head -1 | awk '{print $2}' | tr -d '"')
    info "Deployed image: $img"
  fi

  # Check deploy log
  if [ -f "$DEPLOY_LOG" ]; then
    echo ""
    info "Last 5 deploy events:"
    tail -5 "$DEPLOY_LOG" | sed 's/^/  /'
  fi
}

# =============================================================================
# MODE: --validate (Verify channel connectivity)
# =============================================================================

do_validate() {
  printf "${BOLD}=============================================${NC}\n"
  printf "${BOLD} Channel Validation${NC}\n"
  printf "${BOLD}=============================================${NC}\n"
  echo ""

  local COMPOSE
  COMPOSE=$(detect_compose)
  if [ -z "$COMPOSE" ]; then
    error "Docker Compose not found"
    return 1
  fi

  cd "$SCRIPT_DIR"

  # Check container is running
  if ! $COMPOSE ps 2>/dev/null | grep -q "panw-network-client"; then
    error "Container is not running. Start it first: $COMPOSE up -d"
    return 1
  fi

  info "Checking recent logs for connection status..."
  echo ""

  local logs
  logs=$($COMPOSE logs --tail=50 panw-network-client 2>/dev/null || true)

  if echo "$logs" | grep -qi "connected to the server"; then
    success "Channel is CONNECTED"
    echo "$logs" | grep -i "connected" | tail -3 | sed 's/^/  /'
  elif echo "$logs" | grep -qi "error\|fail\|unauthorized\|denied"; then
    error "Channel has ERRORS"
    echo "$logs" | grep -i "error\|fail\|unauthorized\|denied" | tail -5 | sed 's/^/  /'
    echo ""
    info "Run --diagnose for detailed analysis."
  else
    warn "Could not determine channel status from logs."
    info "Check the portal: click 'Validate Channel' to verify."
    echo ""
    info "Recent logs:"
    echo "$logs" | tail -10 | sed 's/^/  /'
  fi
}

# =============================================================================
# MODE: --diagnose (Log analysis)
# =============================================================================

do_diagnose() {
  printf "${BOLD}=============================================${NC}\n"
  printf "${BOLD} Diagnostic Analysis${NC}\n"
  printf "${BOLD}=============================================${NC}\n"
  echo ""

  local COMPOSE
  COMPOSE=$(detect_compose)
  if [ -z "$COMPOSE" ]; then
    error "Docker Compose not found"
    return 1
  fi

  cd "$SCRIPT_DIR"

  # Preflight
  info "Checking prerequisites..."

  # Docker version
  local docker_ver
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
  info "Docker version: $docker_ver"

  # Container state
  if ! $COMPOSE ps 2>/dev/null | grep -q "panw-network-client"; then
    error "Container is not running."
    info "Start it: $COMPOSE up -d"
    info "Then re-run: ./setup-panw-network-client.sh --diagnose"
    return 1
  fi

  # Restart count
  local restarts
  restarts=$(docker inspect --format='{{.RestartCount}}' "$(docker ps -qf name=panw-network-client)" 2>/dev/null || echo "unknown")
  if [ "$restarts" != "0" ] && [ "$restarts" != "unknown" ]; then
    warn "Container has restarted $restarts time(s)"
  else
    success "Container has not restarted"
  fi

  # Memory usage
  info "Resource usage:"
  docker stats --no-stream --format "  CPU: {{.CPUPerc}}  MEM: {{.MemUsage}}" "$(docker ps -qf name=panw-network-client)" 2>/dev/null || true

  echo ""
  info "Analyzing logs for known patterns..."
  echo ""

  local logs
  logs=$($COMPOSE logs --tail=200 panw-network-client 2>/dev/null || true)
  local issues_found=false

  # Pattern: Authentication errors
  if echo "$logs" | grep -qi "unauthorized\|401\|authentication failed\|invalid.*client"; then
    error "AUTHENTICATION FAILURE detected"
    info "  -> Check CLIENT_ID and CLIENT_SECRET in .env.runtime"
    info "  -> Verify the service account has the 'Superuser' role in the portal"
    info "  -> Credentials may have expired — regenerate in the portal"
    issues_found=true
    echo ""
  fi

  # Pattern: TLS/SSL errors
  if echo "$logs" | grep -qi "certificate\|tls\|ssl\|x509"; then
    error "TLS/CERTIFICATE ERROR detected"
    info "  -> For self-signed or internal CA certs: set DISABLE_SSL_VERIFICATION=\"true\" in .env"
    info "  -> Then re-run: ./setup-panw-network-client.sh"
    info "  -> If behind a proxy: set HTTP_PROXY, HTTPS_PROXY, NO_PROXY in .env (v1.0.5+)"
    info "  -> Ensure the host's CA certificates are up to date"
    issues_found=true
    echo ""
  fi

  # Pattern: Connection errors
  if echo "$logs" | grep -qi "connection refused\|timeout\|unreachable\|dns\|resolve"; then
    error "NETWORK CONNECTIVITY ERROR detected"
    info "  -> Test: curl -sI https://api.sase.paloaltonetworks.com"
    info "  -> Test: curl -sI https://auth.apps.paloaltonetworks.com"
    info "  -> Check firewall rules for outbound HTTPS (TCP/443)"
    info "  -> If behind a proxy, set HTTP_PROXY/HTTPS_PROXY in .env.runtime"
    issues_found=true
    echo ""
  fi

  # Pattern: Channel errors
  if echo "$logs" | grep -qi "channel.*not found\|invalid.*channel"; then
    error "CHANNEL CONFIGURATION ERROR detected"
    info "  -> Verify CHANNEL_ID in .env.runtime matches the portal"
    issues_found=true
    echo ""
  fi

  # Pattern: Permission errors
  if echo "$logs" | grep -qi "forbidden\|403\|permission denied\|access denied"; then
    error "PERMISSION ERROR detected"
    info "  -> Verify the service account has the 'Superuser' role"
    info "  -> Check if the service account is active in the portal"
    issues_found=true
    echo ""
  fi

  if echo "$logs" | grep -qi "connected to the server"; then
    success "Channel appears CONNECTED"
    echo ""
  fi

  if [ "$issues_found" = false ]; then
    success "No known error patterns found in logs"
    echo ""
    info "Last 20 log lines:"
    echo "$logs" | tail -20 | sed 's/^/  /'
  fi
}

# =============================================================================
# Preflight checks
# =============================================================================

preflight() {
  local label="$1"
  info "Running preflight checks..."

  local failed=false

  # Docker
  if ! command -v docker &>/dev/null; then
    error "docker is not installed. Install: https://docs.docker.com/get-docker/"
    failed=true
  elif ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running or not accessible."
    failed=true
  else
    # Check Docker version
    local docker_ver
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    local docker_major
    docker_major=$(echo "$docker_ver" | cut -d. -f1)
    if [ "$docker_major" -lt 20 ] 2>/dev/null; then
      warn "Docker $docker_ver detected. Version 20.10+ recommended for security features."
    else
      success "Docker $docker_ver"
    fi
  fi

  # Docker Compose
  local COMPOSE
  COMPOSE=$(detect_compose)
  if [ -z "$COMPOSE" ]; then
    error "Docker Compose not found. Install: https://docs.docker.com/compose/install/"
    failed=true
  else
    success "Docker Compose ($COMPOSE)"
  fi

  # curl
  if ! command -v curl &>/dev/null; then
    error "curl is not installed."
    failed=true
  else
    success "curl"
  fi

  # tar
  if ! command -v tar &>/dev/null; then
    error "tar is not installed."
    failed=true
  else
    success "tar"
  fi

  # Network connectivity (only for install)
  if [ "$label" = "install" ]; then
    if curl -sf --max-time 5 "https://api.sase.paloaltonetworks.com" >/dev/null 2>&1 ||
       curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "https://api.sase.paloaltonetworks.com" 2>/dev/null | grep -q "^[2345]"; then
      success "Network: api.sase.paloaltonetworks.com reachable"
    else
      # Any HTTP response (even 401/403) means network works
      local code
      code=$(curl -so /dev/null --max-time 5 -w "%{http_code}" "https://api.sase.paloaltonetworks.com" 2>/dev/null || echo "000")
      if [ "$code" != "000" ]; then
        success "Network: api.sase.paloaltonetworks.com reachable (HTTP $code)"
      else
        warn "Cannot reach api.sase.paloaltonetworks.com — check network/firewall"
      fi
    fi
  fi

  if [ "$failed" = true ]; then
    if [ "$DRY_RUN" = true ]; then
      warn "Some preflight checks failed. These must be resolved before running."
    else
      error "Preflight checks failed. Fix the above issues and retry."
      exit 1
    fi
  else
    success "All preflight checks passed."
  fi
  echo ""
}

# =============================================================================
# Install crane (with checksum verification, no sudo required)
# =============================================================================

install_crane() {
  if command -v crane &>/dev/null; then
    success "crane already installed ($(crane version 2>/dev/null || echo 'unknown version'))"
    return
  fi

  local OS ARCH CRANE_ARCH OS_NAME
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Linux)
      case "$ARCH" in
        x86_64)  CRANE_ARCH="x86_64"; OS_NAME="Linux" ;;
        aarch64) CRANE_ARCH="arm64";   OS_NAME="Linux" ;;
        *)       error "Unsupported Linux architecture: $ARCH (supported: x86_64, aarch64)"; exit 1 ;;
      esac
      ;;
    Darwin)
      case "$ARCH" in
        x86_64) CRANE_ARCH="x86_64"; OS_NAME="Darwin" ;;
        arm64)  CRANE_ARCH="arm64";   OS_NAME="Darwin" ;;
        *)      error "Unsupported macOS architecture: $ARCH (supported: x86_64, arm64)"; exit 1 ;;
      esac
      ;;
    *)
      error "Unsupported OS: $OS (supported: Linux, Darwin)"
      exit 1
      ;;
  esac

  local CRANE_URL="https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_${OS_NAME}_${CRANE_ARCH}.tar.gz"
  local CRANE_TMP_DIR CRANE_TMP
  CRANE_TMP_DIR="$(mktemp -d)"
  CRANE_TMP="${CRANE_TMP_DIR}/crane.tar.gz"

  info "Downloading crane v${CRANE_VERSION} for ${OS_NAME}/${CRANE_ARCH}..."

  if [ "$DRY_RUN" = true ]; then
    info "[DRY RUN] Would download: $CRANE_URL"
    info "[DRY RUN] Would install crane to user-local or system path"
    return
  fi

  curl -fsSL --proto =https "$CRANE_URL" -o "$CRANE_TMP"

  # Checksum verification
  local expected_sha
  case "${OS_NAME}_${CRANE_ARCH}" in
    Darwin_arm64)  expected_sha="$CRANE_SHA256_DARWIN_ARM64" ;;
    Darwin_x86_64) expected_sha="$CRANE_SHA256_DARWIN_X86_64" ;;
    Linux_x86_64)  expected_sha="$CRANE_SHA256_LINUX_X86_64" ;;
    Linux_arm64)   expected_sha="$CRANE_SHA256_LINUX_ARM64" ;;
  esac

  local actual_sha
  if command -v sha256sum &>/dev/null; then
    actual_sha=$(sha256sum "$CRANE_TMP" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual_sha=$(shasum -a 256 "$CRANE_TMP" | awk '{print $1}')
  else
    rm -f "$CRANE_TMP"
    die "Cannot verify checksum: neither sha256sum nor shasum found. Install coreutils and retry."
  fi

  if [ "$actual_sha" != "$expected_sha" ]; then
    warn "Checksum mismatch for crane binary."
    warn "  Expected: $expected_sha"
    warn "  Got:      $actual_sha"
    warn "The downloaded binary may be corrupted or tampered with."
    warn "Verify manually: https://github.com/google/go-containerregistry/releases/tag/v${CRANE_VERSION}"
    rm -f "$CRANE_TMP"
    die "Aborting installation due to checksum mismatch."
  fi

  # Try user-local install first (no sudo needed)
  local INSTALL_DIR="${CRANE_INSTALL_DIR:-}"
  if [ -z "$INSTALL_DIR" ]; then
    # Try user-local paths first
    for candidate in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
      if [ -d "$candidate" ] && [ -w "$candidate" ]; then
        INSTALL_DIR="$candidate"
        break
      fi
    done
  fi

  if [ -z "$INSTALL_DIR" ]; then
    # Create ~/.local/bin if nothing is writable
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
      warn "Adding $INSTALL_DIR to PATH for this session."
      export PATH="$INSTALL_DIR:$PATH"
      warn "Add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
  fi

  tar -xzf "$CRANE_TMP" --no-same-owner -C "$INSTALL_DIR" crane
  rm -rf "$CRANE_TMP_DIR"
  success "crane v${CRANE_VERSION} installed to $INSTALL_DIR"
}

# =============================================================================
# MODE: install (Main setup flow)
# =============================================================================

do_install() {
  if [ "$QUIET" != true ]; then
    echo ""
    printf "${BOLD}=============================================${NC}\n"
    printf "${BOLD} Palo Alto Network Client - Docker Installer${NC}\n"
    printf "${BOLD}=============================================${NC}\n"
    echo ""
  fi

  # --- Load .env first (proxy settings needed for preflight + crane) ---
  if [ ! -f "$ENV_FILE" ]; then
    error ".env file not found at $ENV_FILE"
    echo ""
    info "Quick start:  ./setup-panw-network-client.sh --init"
    info "Or manually:  cp .env.example .env && edit .env"
    exit 1
  fi

  load_env "$ENV_FILE"

  if [ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]; then
    info "Proxy configured: HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-}"
  fi

  # --- Preflight ---
  step "0" "Preflight checks"
  preflight "install"

  # Validate required variables
  local MISSING=0
  for VAR in REGISTRY_USERNAME REGISTRY_PASSWORD CLIENT_ID CLIENT_SECRET CHANNEL_ID TENANT_PATH; do
    if [ -z "${!VAR:-}" ]; then
      error "$VAR is not set in .env"
      MISSING=1
    fi
  done
  [ "$MISSING" -eq 1 ] && exit 1

  CHART_VERSION="${CHART_VERSION:-latest}"

  # Validate TENANT_PATH format
  TENANT_PATH="${TENANT_PATH#/}"
  TENANT_PATH="${TENANT_PATH%/}"
  if [[ ! "$TENANT_PATH" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*$ ]]; then
    error "TENANT_PATH contains invalid characters: $TENANT_PATH"
    info "Expected format: org-id/product (e.g., pairs-redteam-prd-fckx/red-teaming-onprem)"
    exit 1
  fi

  info "Registry:      $REGISTRY"
  info "Tenant path:   $TENANT_PATH"
  info "Chart version: $CHART_VERSION"

  if [ "$DRY_RUN" = true ]; then
    echo ""
    info "[DRY RUN] Would perform the following actions:"
    info "  1. Install crane v${CRANE_VERSION} (if not present)"
    info "  2. Login to $REGISTRY"
    info "  3. Pull chart: ${REGISTRY}/${TENANT_PATH}/charts/panw-network-client:${CHART_VERSION}"
    info "  4. Extract and pull container image"
    info "  5. Generate: .env.setup, .env.runtime, docker-compose.yml"
    info "  6. Start container with docker compose"
    echo ""
    info "No changes were made."
    exit 0
  fi

  # --- Step 1: Install crane ---
  step "1" "Installing crane"
  install_crane

  # --- Step 2: Registry login ---
  step "2" "Logging into registry"
  if [ "$QUIET" = true ]; then
    printf '%s\n' "${REGISTRY_PASSWORD}" | crane auth login "$REGISTRY" -u "${REGISTRY_USERNAME}" --password-stdin >/dev/null 2>&1
  else
    printf '%s\n' "${REGISTRY_PASSWORD}" | crane auth login "$REGISTRY" -u "${REGISTRY_USERNAME}" --password-stdin
  fi
  success "Registry login successful."

  # --- Resolve chart version ---
  local CHART_REF="${REGISTRY}/${TENANT_PATH}/charts/panw-network-client"

  if [ "$CHART_VERSION" = "latest" ]; then
    step "2b" "Resolving latest chart version"
    local AVAILABLE_TAGS
    AVAILABLE_TAGS=$(crane ls "$CHART_REF" 2>/dev/null || true)
    if [ -z "$AVAILABLE_TAGS" ]; then
      error "Could not list chart versions. Check TENANT_PATH and registry credentials."
      info "Attempted: $CHART_REF"
      info "Try: crane ls $CHART_REF"
      exit 1
    fi
    if echo "1.0.0" | sort -V &>/dev/null 2>&1; then
      CHART_VERSION=$(echo "$AVAILABLE_TAGS" | sort -V | tail -1)
    else
      CHART_VERSION=$(echo "$AVAILABLE_TAGS" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    fi
    success "Latest chart version: $CHART_VERSION"
  fi

  # --- Step 3: Extract chart ---
  step "3" "Extracting chart to discover image and config"

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "${WORK_DIR:-}"' EXIT

  if [ "$QUIET" = true ]; then
    crane pull "${CHART_REF}:${CHART_VERSION}" "$WORK_DIR/chart.tar" >/dev/null 2>&1
  else
    crane pull "${CHART_REF}:${CHART_VERSION}" "$WORK_DIR/chart.tar"
  fi
  mkdir -p "$WORK_DIR/chart-extract"
  tar -xf "$WORK_DIR/chart.tar" --no-same-owner -C "$WORK_DIR/chart-extract"

  cd "$WORK_DIR/chart-extract"
  shopt -s nullglob
  for f in *.tar.gz *.tgz sha256:*; do
    [ -f "$f" ] && tar -xzf "$f" --no-same-owner 2>/dev/null || true
  done
  shopt -u nullglob
  cd "$SCRIPT_DIR"

  # Find values.yaml
  local CHART_DIR VALUES_FILE
  CHART_DIR=$(find "$WORK_DIR/chart-extract" -name "Chart.yaml" -exec dirname {} \; 2>/dev/null | head -1)
  if [ -n "$CHART_DIR" ] && [ -f "$CHART_DIR/values.yaml" ]; then
    VALUES_FILE="$CHART_DIR/values.yaml"
  else
    VALUES_FILE=$(find "$WORK_DIR/chart-extract" -maxdepth 3 -name "values.yaml" 2>/dev/null | head -1)
  fi

  if [ -z "$VALUES_FILE" ] || [ ! -f "$VALUES_FILE" ]; then
    error "Could not find values.yaml in the chart."
    info "Chart ref: ${CHART_REF}:${CHART_VERSION}"
    exit 1
  fi

  success "Found values at: $VALUES_FILE"

  # Parse image
  local IMAGE_REPO IMAGE_TAG
  IMAGE_REPO=$(grep -A5 "^image:" "$VALUES_FILE" | grep "repository:" | head -1 | sed 's/.*repository:[[:space:]]*//' | sed "s/[\"']//g" | xargs)
  IMAGE_TAG=$(grep -A5 "^image:" "$VALUES_FILE" | grep "tag:" | head -1 | sed 's/.*tag:[[:space:]]*//' | sed "s/[\"']//g" | xargs)

  if [ -z "$IMAGE_REPO" ] || [ -z "$IMAGE_TAG" ]; then
    error "Could not parse image from values.yaml"
    cat "$VALUES_FILE"
    exit 1
  fi

  if [[ ! "$IMAGE_REPO" =~ ^[a-zA-Z0-9._:/-]+$ ]]; then
    error "Image repository contains invalid characters: $IMAGE_REPO"
    exit 1
  fi
  if [[ ! "$IMAGE_TAG" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    error "Image tag contains invalid characters: $IMAGE_TAG"
    exit 1
  fi

  local FULL_IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
  success "Discovered image: $FULL_IMAGE"

  # Log image digest for supply chain auditability
  local IMAGE_DIGEST
  IMAGE_DIGEST=$(crane digest "$FULL_IMAGE" 2>/dev/null || echo "unknown")
  info "Image digest: $IMAGE_DIGEST"
  log_deploy "image_resolved" "image=$FULL_IMAGE digest=$IMAGE_DIGEST chart_version=$CHART_VERSION"

  # Parse config defaults from chart, but let .env values take precedence.
  # Save .env overrides before local declarations shadow them.
  local env_LOG_LEVEL="${LOG_LEVEL:-}"
  local env_PRETTY_LOGS="${PRETTY_LOGS:-}"
  local env_HANDSHAKE_TIMEOUT="${HANDSHAKE_TIMEOUT:-}"
  local env_PROXY_TIMEOUT="${PROXY_TIMEOUT:-}"
  local env_CONNECTION_RETRY_INTERVAL="${CONNECTION_RETRY_INTERVAL:-}"
  local env_POOL_SIZE="${POOL_SIZE:-}"
  local env_RE_AUTH_INTERVAL="${RE_AUTH_INTERVAL:-}"
  local env_DISABLE_SSL_VERIFICATION="${DISABLE_SSL_VERIFICATION:-}"

  parse_value() {
    local raw
    raw=$(grep "$1:" "$VALUES_FILE" | head -1 | sed "s/.*$1:[[:space:]]*//" | sed "s/[\"']//g" | xargs)
    echo "$raw"
  }

  local LOG_LEVEL PRETTY_LOGS HANDSHAKE_TIMEOUT PROXY_TIMEOUT CONNECTION_RETRY_INTERVAL POOL_SIZE RE_AUTH_INTERVAL DISABLE_SSL_VERIFICATION
  LOG_LEVEL=$(parse_value "logLevel")
  PRETTY_LOGS=$(parse_value "prettyLogs")
  HANDSHAKE_TIMEOUT=$(parse_value "handshakeTimeout")
  PROXY_TIMEOUT=$(parse_value "proxyTimeout")
  CONNECTION_RETRY_INTERVAL=$(parse_value "connectionRetryInterval")
  POOL_SIZE=$(parse_value "poolSize")
  RE_AUTH_INTERVAL=$(parse_value "reAuthInterval")
  DISABLE_SSL_VERIFICATION=$(parse_value "disableSSLVerification")

  # Precedence: .env override > chart value > hardcoded default
  LOG_LEVEL="${env_LOG_LEVEL:-${LOG_LEVEL:-INFO}}"
  PRETTY_LOGS="${env_PRETTY_LOGS:-${PRETTY_LOGS:-false}}"
  HANDSHAKE_TIMEOUT="${env_HANDSHAKE_TIMEOUT:-${HANDSHAKE_TIMEOUT:-10s}}"
  PROXY_TIMEOUT="${env_PROXY_TIMEOUT:-${PROXY_TIMEOUT:-100s}}"
  CONNECTION_RETRY_INTERVAL="${env_CONNECTION_RETRY_INTERVAL:-${CONNECTION_RETRY_INTERVAL:-5s}}"
  POOL_SIZE="${env_POOL_SIZE:-${POOL_SIZE:-2048}}"
  RE_AUTH_INTERVAL="${env_RE_AUTH_INTERVAL:-${RE_AUTH_INTERVAL:-5m}}"
  DISABLE_SSL_VERIFICATION="${env_DISABLE_SSL_VERIFICATION:-${DISABLE_SSL_VERIFICATION:-false}}"

  if [ "${DISABLE_SSL_VERIFICATION}" = "true" ]; then
    echo ""
    warn "DISABLE_SSL_VERIFICATION is enabled (Custom SSL mode)."
    warn "This is intended for on-premises or private cloud deployments"
    warn "with self-signed or internal CA certificates."
    warn "Not required for production environments with valid SSL certificates."
    echo ""
  fi

  # --- Step 4: Pull image (to temp dir, not SCRIPT_DIR) ---
  step "4" "Pulling container image"

  # Skip if already running the same image
  local DIGEST_FILE="$SCRIPT_DIR/.image-digest"
  if [ "$IMAGE_DIGEST" != "unknown" ] && [ -f "$DIGEST_FILE" ]; then
    local PREV_DIGEST
    PREV_DIGEST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")
    if [ "$PREV_DIGEST" = "$IMAGE_DIGEST" ]; then
      local COMPOSE_CHECK
      COMPOSE_CHECK=$(detect_compose)
      if $COMPOSE_CHECK ps --format json 2>/dev/null | grep -q '"running"'; then
        info "Already running latest image ($IMAGE_DIGEST). Nothing to do."
        exit 0
      fi
    fi
  fi

  local IMAGE_TAR="$WORK_DIR/panw-client.tar"
  if [ "$QUIET" = true ]; then
    crane pull "$FULL_IMAGE" "$IMAGE_TAR" >/dev/null 2>&1
    docker load -i "$IMAGE_TAR" >/dev/null 2>&1
  else
    crane pull "$FULL_IMAGE" "$IMAGE_TAR"
    docker load -i "$IMAGE_TAR"
  fi
  success "Image loaded into Docker."

  # --- Step 5: Write config files (with backup) ---
  step "5" "Writing configuration files"

  # Backup existing files before overwriting
  for f in .env.setup .env.runtime docker-compose.yml; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
      cp "$SCRIPT_DIR/$f" "$SCRIPT_DIR/${f}.bak"
      chmod 600 "$SCRIPT_DIR/${f}.bak"
      info "Backed up existing $f -> ${f}.bak"
    fi
  done

  # .env.setup (registry credentials only — never passed to container)
  {
    printf '# --- Setup credentials (used by setup-panw-network-client.sh) ---\n'
    printf '# This file is NOT passed to the container.\n'
    printf 'REGISTRY_USERNAME="%s"\n' "${REGISTRY_USERNAME//\"/\\\"}"
    printf 'REGISTRY_PASSWORD="%s"\n' "${REGISTRY_PASSWORD//\"/\\\"}"
    printf 'TENANT_PATH="%s"\n' "${TENANT_PATH//\"/\\\"}"
    printf 'CHART_VERSION="%s"\n' "${CHART_VERSION//\"/\\\"}"
  } > "${SCRIPT_DIR}/.env.setup"
  chmod 600 "${SCRIPT_DIR}/.env.setup"

  # .env.runtime (container config)
  {
    printf '# --- Runtime config (used by the container) ---\n'
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
    # Proxy settings (v1.0.5+)
    [ -n "${HTTP_PROXY:-}" ]  && printf 'HTTP_PROXY="%s"\n' "${HTTP_PROXY//\"/\\\"}"
    [ -n "${HTTPS_PROXY:-}" ] && printf 'HTTPS_PROXY="%s"\n' "${HTTPS_PROXY//\"/\\\"}"
    [ -n "${NO_PROXY:-}" ]    && printf 'NO_PROXY="%s"\n' "${NO_PROXY//\"/\\\"}"
  } > "${SCRIPT_DIR}/.env.runtime"
  chmod 600 "${SCRIPT_DIR}/.env.runtime"

  success ".env.setup and .env.runtime created (mode 600)."

  # --- Step 6: Generate docker-compose.yml ---
  step "6" "Creating docker-compose.yml"

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
    cpus: 1.0
    pids_limit: 256
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "kill -0 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF

  success "docker-compose.yml created (with healthcheck, CPU/PID limits)."

  # --- Step 7: Start ---
  step "7" "Starting the client"

  local COMPOSE
  COMPOSE=$(detect_compose)
  if [ -z "$COMPOSE" ]; then
    error "Docker Compose not found."
    exit 1
  fi

  cd "$SCRIPT_DIR"
  if [ "$QUIET" = true ]; then
    $COMPOSE up -d --quiet-pull 2>/dev/null
  else
    $COMPOSE up -d
  fi

  log_deploy "install" "image=$FULL_IMAGE digest=$IMAGE_DIGEST chart=$CHART_VERSION"

  # Save digest for up-to-date check on next run
  printf '%s' "$IMAGE_DIGEST" > "$SCRIPT_DIR/.image-digest"
  chmod 600 "$SCRIPT_DIR/.image-digest"

  # --- Step 8: Verify ---
  step "8" "Verifying startup"

  info "Waiting for container to start..."
  local attempts=0
  local max_attempts=15
  while [ $attempts -lt $max_attempts ]; do
    if $COMPOSE ps --format json 2>/dev/null | grep -q '"running"'; then
      break
    fi
    sleep 2
    attempts=$((attempts + 1))
  done

  if [ $attempts -ge $max_attempts ]; then
    warn "Container may not have started. Check logs:"
    $COMPOSE logs --tail=20 panw-network-client
    exit 1
  else
    success "Container is running."
    echo ""

    # Wait for connection and check logs
    info "Waiting for channel connection (up to 30s)..."
    local wait_attempts=0
    local connected=false
    while [ $wait_attempts -lt 15 ]; do
      if $COMPOSE logs --tail=50 panw-network-client 2>/dev/null | grep -qi "connected to the server"; then
        connected=true
        break
      fi
      sleep 2
      wait_attempts=$((wait_attempts + 1))
    done

    echo ""
    if [ "$connected" = true ]; then
      success "Channel is CONNECTED"
    else
      warn "Could not confirm connection within 30s. Check logs or run --validate later."
    fi

    if [ "$QUIET" != true ]; then
      echo ""
      info "Recent logs:"
      $COMPOSE logs --tail=15 panw-network-client 2>/dev/null | sed 's/^/  /'
    fi
  fi

  # --- Done ---
  if [ "$QUIET" != true ]; then
    echo ""
    printf "${BOLD}=============================================${NC}\n"
    printf "${GREEN}${BOLD} Setup complete!${NC}\n"
    printf "${BOLD}=============================================${NC}\n"
    echo ""
    info "Files in: $SCRIPT_DIR"
    echo ""
    echo "  Config files:"
    echo "    .env.setup   - Registry credentials (script use only)"
    echo "    .env.runtime - Container runtime config"
    echo "    docker-compose.yml"
    echo ""
    echo "  Commands:"
    echo "    Validate:    ./setup-panw-network-client.sh --validate"
    echo "    Diagnose:    ./setup-panw-network-client.sh --diagnose"
    echo "    Status:      ./setup-panw-network-client.sh --status"
    echo "    Follow logs: $COMPOSE logs -f panw-network-client"
    echo "    Stop:        $COMPOSE down"
    echo "    Restart:     $COMPOSE up -d"
    echo "    Update:      change CHART_VERSION in .env and rerun this script"
    echo ""
  fi
}

# =============================================================================
# Guard against shell tracing leaking secrets
# =============================================================================

if [[ "${-}" == *x* ]] || [ -n "${BASH_XTRACEFD:-}" ]; then
  warn "Shell tracing (set -x) detected. Disabling to protect credentials."
  set +x
  unset BASH_XTRACEFD
fi

# =============================================================================
# Main dispatch
# =============================================================================

case "$MODE" in
  init)     do_init ;;
  status)   do_status ;;
  validate) do_validate ;;
  diagnose) do_diagnose ;;
  install)  if [ "$QUIET" = true ]; then do_install >/dev/null; else do_install; fi ;;
esac
