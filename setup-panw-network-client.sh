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
#   - curl, jq
#   - Outbound HTTPS to *.paloaltonetworks.com
# =============================================================================

# --- Constants ---

REGISTRY_DEFAULT="registry.ai-red-teaming.paloaltonetworks.com"
REGISTRY="$REGISTRY_DEFAULT"
KNOWN_REGISTRIES=(
  "us|registry.ai-red-teaming.paloaltonetworks.com|Americas (US)"
  "nl|registry-nl.ai-red-teaming.paloaltonetworks.com|Europe (Netherlands)"
  "sg|registry-sg.ai-red-teaming.paloaltonetworks.com|Asia Pacific (Singapore)"
)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DEPLOY_LOG="${SCRIPT_DIR}/deploy.log"

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

# =============================================================================
# API Layer — OAuth2 auth + Network Broker REST API
# =============================================================================

API_BASE="https://api.sase.paloaltonetworks.com/ai-red-teaming/data-plane/network-broker"
MGMT_API_BASE="https://api.sase.paloaltonetworks.com/ai-red-teaming/mgmt-plane"
AUTH_ENDPOINT="https://auth.apps.paloaltonetworks.com/oauth2/access_token"
API_TOKEN=""
API_TOKEN_EXPIRY=0
API_AVAILABLE=false

json_extract() {
  jq -re "$1" 2>/dev/null
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

extract_tsg_id() {
  local client_id="$1"
  if [[ "$client_id" =~ @([0-9]+)\.iam\.panserviceaccount\.com$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

api_authenticate() {
  { set +x; } 2>/dev/null

  local client_id="${CLIENT_ID:-}"
  local client_secret="${CLIENT_SECRET:-}"
  local tsg_id="${TSG_ID:-}"

  if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
    return 1
  fi

  local _auth_hdr
  _auth_hdr=$(mktemp) || return 1
  chmod 600 "$_auth_hdr"

  local basic_cred
  basic_cred=$(printf '%s:%s' "$client_id" "$client_secret" | base64 | tr -d '\n')
  printf 'Authorization: Basic %s\n' "$basic_cred" > "$_auth_hdr"

  local scope_data="grant_type=client_credentials"
  if [ -n "$tsg_id" ]; then
    scope_data="${scope_data}&scope=tsg_id:${tsg_id}"
  fi

  local response
  response=$(curl --silent --show-error \
    --proto "=https" \
    --connect-timeout 10 \
    --max-time 30 \
    --header @"$_auth_hdr" \
    --data "$scope_data" \
    "$AUTH_ENDPOINT" 2>/dev/null) || { rm -f "$_auth_hdr"; return 1; }

  rm -f "$_auth_hdr"

  local token
  token=$(printf '%s' "$response" | json_extract '.access_token') || return 1
  [ -z "$token" ] && return 1

  local expires_in
  expires_in=$(printf '%s' "$response" | json_extract '.expires_in') || expires_in=899

  API_TOKEN="$token"
  API_TOKEN_EXPIRY=$(( $(date +%s) + expires_in - 60 ))
  API_AVAILABLE=true
  return 0
}

api_ensure_token() {
  { set +x; } 2>/dev/null
  if [ -z "$API_TOKEN" ] || [ "$(date +%s)" -ge "$API_TOKEN_EXPIRY" ]; then
    api_authenticate || return 1
  fi
  return 0
}

api_call() {
  { set +x; } 2>/dev/null

  local method="$1"
  local endpoint="$2"
  local body="${3:-}"

  case "$endpoint" in
    https://*) ;;
    *) endpoint="${API_BASE}${endpoint}" ;;
  esac

  case "$endpoint" in
    https://*) ;;
    *) error "Refusing non-HTTPS API call"; return 1 ;;
  esac

  api_ensure_token || return 1

  local _call_hdr
  _call_hdr=$(mktemp) || return 1
  chmod 600 "$_call_hdr"

  printf 'Authorization: Bearer %s\n' "$API_TOKEN" > "$_call_hdr"

  local curl_args=(
    --silent --show-error
    --proto "=https"
    --connect-timeout 10
    --max-time 30
    --header @"$_call_hdr"
    --header "Content-Type: application/json"
    --request "$method"
    --write-out '\n%{http_code}'
  )

  if [ -n "$body" ]; then
    curl_args+=(--data "$body")
  fi

  local attempt=0
  local max_attempts=3
  local raw_response http_code response

  while [ $attempt -lt $max_attempts ]; do
    raw_response=$(curl "${curl_args[@]}" "$endpoint" 2>/dev/null) || {
      attempt=$((attempt + 1))
      [ $attempt -lt $max_attempts ] && sleep $((attempt * 2))
      continue
    }

    http_code=$(printf '%s' "$raw_response" | tail -1)
    response=$(printf '%s' "$raw_response" | sed '$d')

    case "$http_code" in
      2[0-9][0-9])
        rm -f "$_call_hdr"
        printf '%s' "$response"
        return 0
        ;;
      401)
        API_TOKEN=""
        api_authenticate || { rm -f "$_call_hdr"; return 1; }
        printf 'Authorization: Bearer %s\n' "$API_TOKEN" > "$_call_hdr"
        attempt=$((attempt + 1))
        ;;
      429)
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep $((attempt * 3))
        ;;
      5[0-9][0-9])
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep $((attempt * 2))
        ;;
      *)
        rm -f "$_call_hdr"
        return 1
        ;;
    esac
  done
  rm -f "$_call_hdr"
  return 1
}

api_list_channels() {
  local status_filter="${1:-}"
  local query=""
  if [ -n "$status_filter" ]; then
    query="?status=${status_filter}"
  fi
  api_call "GET" "/v1/channels${query}"
}

api_create_channel() {
  local name="$1"
  local desc="${2:-}"
  # Escape quotes and backslashes for safe JSON
  name="${name//\\/\\\\}"
  name="${name//\"/\\\"}"
  local body
  if [ -n "$desc" ]; then
    desc="${desc//\\/\\\\}"
    desc="${desc//\"/\\\"}"
    body=$(printf '{"name":"%s","description":"%s"}' "$name" "$desc")
  else
    body=$(printf '{"name":"%s"}' "$name")
  fi
  api_call "POST" "/v1/channels" "$body"
}

api_get_stats() {
  api_call "GET" "/v1/channels/stats"
}

api_get_channel() {
  local channel_id="$1"
  validate_uuid "$channel_id" || return 1
  api_call "GET" "/v1/channels/${channel_id}"
}

api_get_registry_credentials() {
  { set +x; } 2>/dev/null
  api_ensure_token || return 1

  local _reg_header_file
  _reg_header_file=$(mktemp) || return 1
  chmod 600 "$_reg_header_file"

  printf 'Authorization: Bearer %s\n' "$API_TOKEN" > "$_reg_header_file"

  local raw_response http_code response
  raw_response=$(curl --silent --show-error \
    --proto "=https" \
    --connect-timeout 10 \
    --max-time 30 \
    --header @"$_reg_header_file" \
    --header "Content-Type: application/json" \
    --request POST \
    --write-out '\n%{http_code}' \
    "${MGMT_API_BASE}/v1/registry-credentials" 2>/dev/null) || { rm -f "$_reg_header_file"; return 1; }

  rm -f "$_reg_header_file"

  http_code=$(printf '%s' "$raw_response" | tail -1)
  response=$(printf '%s' "$raw_response" | sed '$d')

  case "$http_code" in
    2[0-9][0-9]) printf '%s' "$response"; return 0 ;;
    *) return 1 ;;
  esac
}

# Print channel status from the API. Args: format = "verbose"|"compact"
api_print_channel_status() {
  local format="${1:-verbose}"
  [ -z "${CHANNEL_ID:-}" ] && return 0

  local ch_info ch_status ch_name
  ch_info=$(api_get_channel "$CHANNEL_ID" 2>/dev/null) || ch_info=""
  if [ -z "$ch_info" ]; then
    if [ "$format" = "verbose" ]; then
      warn "Could not retrieve channel info from API."
    else
      warn "Channel $CHANNEL_ID not found via API"
    fi
    return 1
  fi

  ch_status=$(printf '%s' "$ch_info" | json_extract '.status') || ch_status="unknown"
  ch_name=$(printf '%s' "$ch_info" | json_extract '.name') || ch_name=""

  if [ "$format" = "verbose" ]; then
    if [ "$ch_status" = "ONLINE" ]; then
      success "Channel '$ch_name' is ONLINE (confirmed by API)"
    else
      warn "Channel '$ch_name' status: $ch_status (API)"
    fi
  else
    info "Channel: $ch_name | Status: $ch_status | ID: $CHANNEL_ID"
  fi
}

# --- Channel selection ---

select_channel() {
  info "Fetching available channels..."

  local channels_json
  channels_json=$(api_list_channels) || {
    warn "Could not fetch channels from API."
    prompt_channel_id
    return
  }

  local total
  total=$(printf '%s' "$channels_json" | jq -r '.data | length' 2>/dev/null) || total=0

  if [ "$total" -eq 0 ]; then
    info "No channels found. Let's create one."
    printf "\n  Channel name: "
    read -r new_name
    [ -z "$new_name" ] && die "Channel name cannot be empty."
    local created
    created=$(api_create_channel "$new_name") || die "Failed to create channel."
    CHANNEL_ID=$(printf '%s' "$created" | json_extract '.uuid')
    CHANNEL_NAME=$(printf '%s' "$created" | json_extract '.name')
    validate_uuid "$CHANNEL_ID" || die "API returned invalid channel ID."
    success "Created channel: $CHANNEL_NAME ($CHANNEL_ID)"
    return
  fi

  echo ""
  printf "  ${BOLD}Available channels:${NC}\n"
  echo ""

  local idx=1
  local selectable_ids=()
  local selectable_names=()

  while IFS=$'\t' read -r uuid name status last_online; do
    if [ "$status" = "ONLINE" ]; then
      printf "     %s  %-30s ${GREEN}ONLINE${NC}  (in use)\n" "-" "$name"
    else
      printf "  [${BOLD}%d${NC}] %-30s %s\n" "$idx" "$name" "$status"
      selectable_ids+=("$uuid")
      selectable_names+=("$name")
      idx=$((idx + 1))
    fi
  done < <(printf '%s' "$channels_json" | jq -r '.data[] | [.uuid, .name, .status, .last_online_at] | @tsv' 2>/dev/null)

  local create_idx=$idx
  printf "  [${BOLD}%d${NC}] Create a new channel\n" "$create_idx"
  local manual_idx=$((create_idx + 1))
  printf "  [${BOLD}%d${NC}] Enter channel ID manually\n" "$manual_idx"
  echo ""

  local choice
  while true; do
    printf "  Select [1-%d]: " "$manual_idx"
    read -r choice

    if [ "$choice" = "$create_idx" ]; then
      printf "\n  Channel name: "
      read -r new_name
      [ -z "$new_name" ] && { warn "Name cannot be empty."; continue; }
      local created
      created=$(api_create_channel "$new_name") || { warn "Failed to create channel. Try again."; continue; }
      CHANNEL_ID=$(printf '%s' "$created" | json_extract '.uuid')
      CHANNEL_NAME=$(printf '%s' "$created" | json_extract '.name')
      validate_uuid "$CHANNEL_ID" || die "API returned invalid channel ID."
      success "Created channel: $CHANNEL_NAME ($CHANNEL_ID)"
      return
    elif [ "$choice" = "$manual_idx" ]; then
      prompt_channel_id
      return
    elif [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -lt "$create_idx" ] 2>/dev/null; then
      local sel_idx=$((choice - 1))
      CHANNEL_ID="${selectable_ids[$sel_idx]}"
      CHANNEL_NAME="${selectable_names[$sel_idx]}"
      validate_uuid "$CHANNEL_ID" || die "Invalid channel ID from selection."
      success "Selected channel: $CHANNEL_NAME ($CHANNEL_ID)"
      return
    else
      warn "Invalid selection. Enter a number between 1 and $manual_idx."
    fi
  done
}

prompt_channel_id() {
  echo ""
  printf "  Channel ID: "
  read -r CHANNEL_ID
  [ -z "$CHANNEL_ID" ] && die "Channel ID cannot be empty."
  validate_uuid "$CHANNEL_ID" || die "Invalid channel ID format (expected UUID)."
  CHANNEL_NAME=""
}

# --- Region / Registry ---

resolve_registry() {
  if [ -n "${REGISTRY_HOST:-}" ]; then
    REGISTRY="$REGISTRY_HOST"
    return
  fi
  case "${REGION:-us}" in
    us) REGISTRY="registry.ai-red-teaming.paloaltonetworks.com" ;;
    nl) REGISTRY="registry-nl.ai-red-teaming.paloaltonetworks.com" ;;
    sg) REGISTRY="registry-sg.ai-red-teaming.paloaltonetworks.com" ;;
    *)  REGISTRY="$REGISTRY_DEFAULT" ;;
  esac
}

select_region() {
  echo ""
  printf "  ${BOLD}Select your region:${NC}\n"
  echo ""

  local idx=1
  for entry in "${KNOWN_REGISTRIES[@]}"; do
    local rest="${entry#*|}"
    local reg="${rest%%|*}"
    local location="${rest##*|}"
    printf "  [${BOLD}%d${NC}] %-50s %s\n" "$idx" "$location" "$reg"
    idx=$((idx + 1))
  done
  echo ""

  local choice
  while true; do
    printf "  Select region [1-3]: "
    read -r choice
    case "$choice" in
      1) REGION="us"; break ;;
      2) REGION="nl"; break ;;
      3) REGION="sg"; break ;;
      *) warn "Invalid selection. Enter 1, 2, or 3." ;;
    esac
  done

  resolve_registry
  success "Region: ${REGION} ($REGISTRY)"
}

# --- Image discovery ---

discover_image_from_api() {
  if [ -n "${IMAGE_PATH:-}" ]; then
    info "Using IMAGE_PATH override from .env"
    return 0
  fi

  local stats
  stats=$(api_get_stats 2>/dev/null) || {
    warn "Could not fetch image info from API."
    return 1
  }

  local docker_image
  docker_image=$(printf '%s' "$stats" | json_extract '.docker_image') || {
    warn "API did not return docker_image."
    return 1
  }

  if [[ ! "$docker_image" =~ : ]]; then
    warn "API returned image without version tag: $docker_image"
    return 1
  fi

  IMAGE_PATH="$docker_image"
  info "Image discovered from API: $IMAGE_PATH"
  return 0
}

# --- Backwards compatibility ---

migrate_env_if_needed() {
  if [ -n "${TENANT_PATH:-}" ] && [ -z "${REGION:-}" ]; then
    warn "Detected old .env format. Auto-migrating..."
    cp "$ENV_FILE" "${ENV_FILE}.old"

    case "${REGISTRY_HOST:-}" in
      *-nl.*) REGION="nl" ;;
      *-sg.*) REGION="sg" ;;
      *)      REGION="us" ;;
    esac

    if [ -z "${TSG_ID:-}" ] && [ -n "${REGISTRY_USERNAME:-}" ]; then
      TSG_ID="$REGISTRY_USERNAME"
    fi

    if [ -z "${TSG_ID:-}" ] && [ -n "${CLIENT_ID:-}" ]; then
      TSG_ID=$(extract_tsg_id "$CLIENT_ID" 2>/dev/null) || true
    fi

    success "Migrated: REGION=$REGION, TSG_ID=${TSG_ID:-<unset>}. Old .env saved to .env.old"
  fi
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
  info "You only need your service account credentials from the portal."
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

  # Step 1: Region selection
  printf "\n${BOLD}Step 1: Region${NC}\n"
  info "Select the region closest to your deployment."
  select_region

  # Step 2: Service account credentials
  printf "\n${BOLD}Step 2: Service Account Credentials${NC}\n"
  info "Create a service account in the portal and copy the Client ID and Secret."
  echo ""
  printf "  Client ID: "
  read -r SA_CLIENT_ID
  printf "  Client Secret: "
  read -rs SA_CLIENT_SECRET
  echo ""

  [ -z "$SA_CLIENT_ID" ] && die "Client ID cannot be empty."
  [ -z "$SA_CLIENT_SECRET" ] && die "Client Secret cannot be empty."

  # Extract TSG_ID from CLIENT_ID
  local SA_TSG_ID=""
  SA_TSG_ID=$(extract_tsg_id "$SA_CLIENT_ID") || {
    warn "Could not extract TSG ID from Client ID format."
    info "Expected: name@<tsg_id>.iam.panserviceaccount.com"
    printf "  Enter TSG ID manually (or leave blank): "
    read -r SA_TSG_ID
  }

  # Validate credentials via API
  CHANNEL_ID=""
  CHANNEL_NAME=""
  CLIENT_ID="$SA_CLIENT_ID"
  CLIENT_SECRET="$SA_CLIENT_SECRET"
  TSG_ID="$SA_TSG_ID"

  info "Validating credentials..."
  if ! api_authenticate; then
    die "Authentication failed. Check your Client ID and Client Secret."
  fi
  success "Credentials valid."

  # Fetch registry credentials
  local REG_TOKEN="" REG_EXPIRY=""
  info "Fetching registry credentials..."
  local reg_response
  reg_response=$(api_get_registry_credentials 2>/dev/null) || {
    warn "Could not fetch registry credentials from API."
    printf "  Registry Password (from portal): "
    read -rs REG_TOKEN
    echo ""
  }
  if [ -z "$REG_TOKEN" ] && [ -n "$reg_response" ]; then
    REG_TOKEN=$(printf '%s' "$reg_response" | json_extract '.token') || REG_TOKEN=""
    REG_EXPIRY=$(printf '%s' "$reg_response" | json_extract '.expiry') || REG_EXPIRY=""
  fi
  [ -z "$REG_TOKEN" ] && die "Could not obtain registry credentials."
  success "Registry credentials obtained."

  # Step 3: Channel selection
  printf "\n${BOLD}Step 3: Channel Selection${NC}\n"
  info "Channels are fetched from the AI Red Teaming platform."
  echo ""
  select_channel

  # Write .env
  {
    printf '# Generated by setup-panw-network-client.sh --init\n'
    printf '# Date: %s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'CLIENT_ID="%s"\n' "$SA_CLIENT_ID"
    printf 'CLIENT_SECRET="%s"\n' "$SA_CLIENT_SECRET"
    printf 'TSG_ID="%s"\n' "$SA_TSG_ID"
    printf 'CHANNEL_ID="%s"\n' "$CHANNEL_ID"
    [ -n "$CHANNEL_NAME" ] && printf 'CHANNEL_NAME="%s"\n' "$CHANNEL_NAME"
    printf 'REGION="%s"\n' "$REGION"
    printf 'REGISTRY_TOKEN="%s"\n' "$REG_TOKEN"
    [ -n "$REG_EXPIRY" ] && printf 'REGISTRY_TOKEN_EXPIRY="%s"\n' "$REG_EXPIRY"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  echo ""
  success ".env file created at $ENV_FILE (mode 600)"
  if [ -n "$CHANNEL_NAME" ]; then
    info "Channel: $CHANNEL_NAME ($CHANNEL_ID)"
  fi
  info "Region: $REGION ($REGISTRY)"
  echo ""
  info "Next: run ./setup-panw-network-client.sh to deploy."
  log_deploy "init" "env_file_created channel=$CHANNEL_ID region=$REGION"
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

  # API-based channel validation
  if [ -f "${SCRIPT_DIR}/.env" ]; then
    load_env "${SCRIPT_DIR}/.env"
  fi
  if [ -n "${CLIENT_ID:-}" ] && [ -n "${CLIENT_SECRET:-}" ]; then
    echo ""
    info "Checking channel via API..."
    if api_authenticate 2>/dev/null; then
      success "OAuth2 authentication: OK"
      api_print_channel_status verbose
    else
      info "API authentication failed (non-critical). Log-based validation above still applies."
    fi
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
    info "  -> Check CLIENT_ID and CLIENT_SECRET in .env"
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
    info "  -> If behind a proxy: set HTTP_PROXY, HTTPS_PROXY, NO_PROXY in .env"
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
    info "  -> If behind a proxy, set HTTP_PROXY/HTTPS_PROXY in .env"
    issues_found=true
    echo ""
  fi

  # Pattern: Channel errors
  if echo "$logs" | grep -qi "channel.*not found\|invalid.*channel"; then
    error "CHANNEL CONFIGURATION ERROR detected"
    info "  -> Verify CHANNEL_ID in .env matches the portal"
    info "  -> Run --init to re-select a channel"
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

  # API diagnostics
  if [ -f "${SCRIPT_DIR}/.env" ]; then
    load_env "${SCRIPT_DIR}/.env"
  fi
  if [ -n "${CLIENT_ID:-}" ] && [ -n "${CLIENT_SECRET:-}" ]; then
    echo ""
    printf "${BOLD}--- API Diagnostics ---${NC}\n"
    echo ""

    # API endpoint reachability
    local api_code
    api_code=$(curl -so /dev/null --proto =https --max-time 5 -w "%{http_code}" "$API_BASE/v1/channels/stats" 2>/dev/null || echo "000")
    if [ "$api_code" != "000" ]; then
      success "API endpoint reachable (HTTP $api_code)"
    else
      error "API endpoint unreachable: $API_BASE"
      info "  -> Check network connectivity and firewall rules for HTTPS"
    fi

    # Auth endpoint reachability
    local auth_code
    auth_code=$(curl -so /dev/null --proto =https --max-time 5 -w "%{http_code}" "$AUTH_ENDPOINT" 2>/dev/null || echo "000")
    if [ "$auth_code" != "000" ]; then
      success "Auth endpoint reachable (HTTP $auth_code)"
    else
      error "Auth endpoint unreachable: $AUTH_ENDPOINT"
    fi

    # OAuth2 authentication test
    if api_authenticate 2>/dev/null; then
      success "OAuth2 authentication: OK"
      [ -n "${TSG_ID:-}" ] && info "TSG ID: ${TSG_ID}"

      api_print_channel_status compact

      # Image info from stats
      local stats
      stats=$(api_get_stats 2>/dev/null) || stats=""
      if [ -n "$stats" ]; then
        local api_image api_version
        api_image=$(printf '%s' "$stats" | json_extract '.docker_image') || api_image=""
        api_version=$(printf '%s' "$stats" | json_extract '.client_version') || api_version=""
        [ -n "$api_image" ] && info "Latest image: $api_image"
        [ -n "$api_version" ] && info "Client version: $api_version"
      fi
    else
      error "OAuth2 authentication FAILED"
      info "  -> Check CLIENT_ID and CLIENT_SECRET in .env"
      info "  -> Verify the service account has the 'Superuser' role"
    fi
  else
    info "API diagnostics skipped (CLIENT_ID/CLIENT_SECRET not configured)"
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

  # jq
  if ! command -v jq &>/dev/null; then
    error "jq is not installed. Install: https://jqlang.github.io/jq/download/"
    failed=true
  else
    success "jq"
  fi

  # Network connectivity (only for install)
  if [ "$label" = "install" ]; then
    local code
    code=$(curl -so /dev/null --max-time 5 -w "%{http_code}" "https://api.sase.paloaltonetworks.com" 2>/dev/null || echo "000")
    if [ "$code" != "000" ]; then
      success "Network: api.sase.paloaltonetworks.com reachable (HTTP $code)"
    else
      warn "Cannot reach api.sase.paloaltonetworks.com — check network/firewall"
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

  # --- Load .env (auto-init if missing) ---
  if [ ! -f "$ENV_FILE" ]; then
    info "No .env file found. Starting interactive setup..."
    echo ""
    do_init
    [ ! -f "$ENV_FILE" ] && exit 1
    echo ""
    info "Continuing with installation..."
    echo ""
  fi
  load_env "$ENV_FILE"

  # Backwards compatibility
  migrate_env_if_needed

  if [ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]; then
    info "Proxy configured: HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-}"
  fi

  # --- Preflight ---
  step "0" "Preflight checks"
  preflight "install"

  # Validate required variables
  local MISSING=0
  for VAR in CLIENT_ID CLIENT_SECRET CHANNEL_ID; do
    if [ -z "${!VAR:-}" ]; then
      error "$VAR is not set in .env"
      MISSING=1
    fi
  done
  [ "$MISSING" -eq 1 ] && exit 1

  # Extract TSG_ID if not set
  if [ -z "${TSG_ID:-}" ]; then
    TSG_ID=$(extract_tsg_id "$CLIENT_ID") || die "Cannot extract TSG_ID from CLIENT_ID. Set TSG_ID in .env."
  fi

  # Resolve region/registry
  resolve_registry

  # --- Step 1: API authentication & image discovery ---
  step "1" "API authentication and image discovery"

  if ! api_authenticate; then
    die "Authentication failed. Check CLIENT_ID and CLIENT_SECRET in .env"
  fi
  success "Authenticated."

  # Refresh registry token if expired or missing
  local REGISTRY_PASSWORD="${REGISTRY_TOKEN:-}"
  if [ -z "$REGISTRY_PASSWORD" ]; then
    info "Fetching registry credentials..."
    local reg_response
    reg_response=$(api_get_registry_credentials 2>/dev/null) || die "Could not fetch registry credentials. Set REGISTRY_TOKEN in .env."
    REGISTRY_PASSWORD=$(printf '%s' "$reg_response" | json_extract '.token') || die "Invalid registry credentials response."
    success "Registry credentials obtained."
  fi

  # Discover image
  if ! discover_image_from_api; then
    die "Could not discover image. Set IMAGE_PATH in .env (format: path/image:tag)"
  fi

  local FULL_IMAGE="${REGISTRY}/${IMAGE_PATH}"
  info "Registry: $REGISTRY"
  info "Image:    $FULL_IMAGE"

  if [ "$DRY_RUN" = true ]; then
    echo ""
    info "[DRY RUN] Would perform the following actions:"
    info "  1. docker login to $REGISTRY"
    info "  2. docker pull $FULL_IMAGE"
    info "  3. Generate: .env.runtime, docker-compose.yml"
    info "  4. Start container with docker compose"
    echo ""
    info "No changes were made."
    exit 0
  fi

  # --- Step 2: Docker registry login ---
  step "2" "Docker registry login"
  { set +x; } 2>/dev/null
  printf '%s\n' "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$TSG_ID" --password-stdin >/dev/null 2>&1 || \
    die "Docker login failed. Check registry credentials."
  success "Registry login successful."

  # --- Step 3: Pull image ---
  step "3" "Pulling container image"

  local DIGEST_FILE="$SCRIPT_DIR/.image-digest"

  if [ "$QUIET" = true ]; then
    docker pull "$FULL_IMAGE" >/dev/null 2>&1 || die "Failed to pull image: $FULL_IMAGE"
  else
    docker pull "$FULL_IMAGE" || die "Failed to pull image: $FULL_IMAGE"
  fi

  # Get image digest
  local IMAGE_DIGEST
  IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$FULL_IMAGE" 2>/dev/null | cut -d@ -f2 || echo "unknown")
  info "Image digest: $IMAGE_DIGEST"
  log_deploy "image_pulled" "image=$FULL_IMAGE digest=$IMAGE_DIGEST"

  # Check if digest changed
  if [ "$IMAGE_DIGEST" != "unknown" ] && [ -f "$DIGEST_FILE" ]; then
    local PREV_DIGEST
    PREV_DIGEST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")
    if [ "$PREV_DIGEST" = "$IMAGE_DIGEST" ]; then
      local COMPOSE_CHECK
      COMPOSE_CHECK=$(detect_compose)
      if [ -n "$COMPOSE_CHECK" ] && $COMPOSE_CHECK ps --format json 2>/dev/null | grep -q '"running"'; then
        info "Already running latest image. Nothing to do."
        exit 0
      fi
    fi
  fi

  success "Image pulled."

  # --- Step 4: Write config files ---
  step "4" "Writing configuration files"

  # Config defaults (.env overrides take precedence)
  local LOG_LEVEL="${LOG_LEVEL:-INFO}"
  local PRETTY_LOGS="${PRETTY_LOGS:-false}"
  local HANDSHAKE_TIMEOUT="${HANDSHAKE_TIMEOUT:-10s}"
  local PROXY_TIMEOUT="${PROXY_TIMEOUT:-100s}"
  local CONNECTION_RETRY_INTERVAL="${CONNECTION_RETRY_INTERVAL:-5s}"
  local POOL_SIZE="${POOL_SIZE:-2048}"
  local RE_AUTH_INTERVAL="${RE_AUTH_INTERVAL:-5m}"
  local DISABLE_SSL_VERIFICATION="${DISABLE_SSL_VERIFICATION:-false}"

  if [ "${DISABLE_SSL_VERIFICATION}" = "true" ]; then
    echo ""
    warn "DISABLE_SSL_VERIFICATION is enabled (Custom SSL mode)."
    warn "This is intended for on-premises or private cloud deployments"
    warn "with self-signed or internal CA certificates."
    echo ""
  fi

  # Backup existing files
  for f in .env.runtime docker-compose.yml; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
      cp "$SCRIPT_DIR/$f" "$SCRIPT_DIR/${f}.bak"
      chmod 600 "$SCRIPT_DIR/${f}.bak"
    fi
  done

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
    [ -n "${HTTP_PROXY:-}" ]  && printf 'HTTP_PROXY="%s"\n' "${HTTP_PROXY//\"/\\\"}"
    [ -n "${HTTPS_PROXY:-}" ] && printf 'HTTPS_PROXY="%s"\n' "${HTTPS_PROXY//\"/\\\"}"
    [ -n "${NO_PROXY:-}" ]    && printf 'NO_PROXY="%s"\n' "${NO_PROXY//\"/\\\"}"
  } > "${SCRIPT_DIR}/.env.runtime"
  chmod 600 "${SCRIPT_DIR}/.env.runtime"

  success ".env.runtime created (mode 600)."

  # --- Step 5: Generate docker-compose.yml ---
  step "5" "Creating docker-compose.yml"

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

  success "docker-compose.yml created."

  # --- Step 6: Start ---
  step "6" "Starting the client"

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

  log_deploy "install" "image=$FULL_IMAGE digest=$IMAGE_DIGEST"

  # Save digest for up-to-date check
  printf '%s' "$IMAGE_DIGEST" > "$SCRIPT_DIR/.image-digest"
  chmod 600 "$SCRIPT_DIR/.image-digest"

  # --- Step 7: Verify ---
  step "7" "Verifying startup"

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

    # Wait for connection
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

    # API-based verification
    if [ "$API_AVAILABLE" = true ] && [ -n "${CHANNEL_ID:-}" ]; then
      echo ""
      local ch_info
      ch_info=$(api_get_channel "$CHANNEL_ID" 2>/dev/null) || ch_info=""
      if [ -n "$ch_info" ]; then
        local ch_status ch_name
        ch_status=$(printf '%s' "$ch_info" | json_extract '.status') || ch_status="unknown"
        ch_name=$(printf '%s' "$ch_info" | json_extract '.name') || ch_name=""
        if [ "$ch_status" = "ONLINE" ]; then
          success "API confirms channel is ONLINE: ${ch_name:-$CHANNEL_ID}"
        else
          info "API reports channel status: $ch_status"
        fi
      fi
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
    echo "    Update:      re-run this script (auto-detects new versions)"
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
