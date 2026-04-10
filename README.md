# AI Red Teaming Network Client - Docker Setup

Deploy the Palo Alto Networks AI Red Teaming network client using **Docker Compose** on a standard server (Linux or macOS) — no Kubernetes or Helm required.

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/PaloAltoNetworks/ai-redteam-network-client-docker.git
cd ai-redteam-network-client-docker

# 2. Interactive setup (creates .env from portal values)
chmod +x setup-panw-network-client.sh
./setup-panw-network-client.sh --init

# 3. Deploy
./setup-panw-network-client.sh

# 4. Verify the channel is connected
./setup-panw-network-client.sh --validate
```

The script automatically installs [crane](https://github.com/google/go-containerregistry) (with checksum verification), pulls the container image, generates a hardened `docker-compose.yml`, and starts the client.

Look for **"Connected to the server"** in the logs, or click **Validate Channel** in the portal.

---

## Why This Exists

The Palo Alto AI Red Teaming portal provides Kubernetes/Helm deployment instructions. This repository offers a simpler alternative for teams that run Docker Compose on standard servers (e.g., EC2 instances) without a Kubernetes cluster.

The setup script:

1. **Replaces Helm with crane** — pulls the Helm chart as an OCI artifact and extracts `values.yaml` to discover the container image and default configuration.
2. **Replaces `docker pull` with `crane pull`** — the Palo Alto registry uses token-based auth that can expire mid-download with standard `docker pull`. Crane downloads the image as a tarball in one authenticated request, then `docker load` imports it.
3. **Replaces Kubernetes Secrets/ConfigMaps with `.env` files** — splits credentials into `.env.setup` (registry-only, never passed to the container) and `.env.runtime` (container config), following least-privilege principles.

---

## CLI Modes

| Command | Description |
|---|---|
| `./setup-panw-network-client.sh --init` | Interactive guided setup — creates `.env` from portal values |
| `./setup-panw-network-client.sh` | Full install (pull image, generate config, start container) |
| `./setup-panw-network-client.sh --dry-run` | Show what would happen without making changes |
| `./setup-panw-network-client.sh --status` | Check current deployment state |
| `./setup-panw-network-client.sh --validate` | Verify the channel is connected |
| `./setup-panw-network-client.sh --diagnose` | Analyze container logs for common issues |

### Interactive Setup (`--init`)

The `--init` mode guides you through creating the `.env` file step by step:

1. Prompts for each credential with clear labels matching the portal UI
2. Validates registry credentials in real-time (if crane is available)
3. Auto-extracts `TENANT_PATH` from the full OCI URL — no manual parsing needed
4. Writes a secure `.env` file (mode 600)

### Dry Run (`--dry-run`)

Shows exactly what the script would do without modifying anything. Use this for change management approval or to preview the setup before committing.

### Diagnostics (`--diagnose`)

Pattern-matches container logs against known error signatures:
- Authentication failures (bad CLIENT_ID/CLIENT_SECRET)
- TLS/certificate errors (proxy interception, expired certs)
- Network connectivity issues (firewall, DNS)
- Channel configuration errors (wrong CHANNEL_ID)
- Permission errors (missing Superuser role)

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Docker** | 20.10+ with Docker Compose (v1 or v2) |
| **OS** | Linux (x86_64, aarch64) or macOS (Intel, Apple Silicon) |
| **Tools** | `curl`, `tar` |
| **Disk** | 2 GB free (for temporary image tarballs) |
| **Network** | Outbound HTTPS to `*.paloaltonetworks.com` and `github.com` |

**Note:** `sudo` is no longer required. Crane installs to `~/.local/bin` by default. Override with `CRANE_INSTALL_DIR=/custom/path`.

---

## Credentials

Gather these from the [AI Red Teaming portal](https://ai-red-teaming.paloaltonetworks.com) before running the script, or use `--init` for guided collection:

| Credential | Portal Location | Used For |
|---|---|---|
| Registry Username | Channel Setup > Step 2 | Pulling images |
| Registry Password | Channel Setup > Step 2 | Pulling images |
| Service Account Client ID | Channel Setup > Step 3 | Container authentication |
| Service Account Client Secret | Channel Setup > Step 3 | Container authentication |
| Channel ID | Channel Setup > Step 4 | Container configuration |
| Tenant Path | Channel Setup > Step 4 (in OCI URL) | Registry path |

### Finding Your Tenant Path

With `--init`, paste the full OCI URL and the tenant path is extracted automatically.

Manually, extract it from the OCI URL shown in the portal at Step 4:

```
oci://registry.ai-red-teaming.paloaltonetworks.com/pairs-redteam-prd-fckx/red-teaming-onprem/charts/panw-network-client
                                                   └──────────────────── TENANT_PATH ────────────────────┘
```

---

## Configuration

### `.env` (input)

Create this file before running the script (or use `--init`):

```env
REGISTRY_USERNAME="<from portal step 2>"
REGISTRY_PASSWORD="<from portal step 2>"
CLIENT_ID="<from portal step 3>"
CLIENT_SECRET="<from portal step 3>"
CHANNEL_ID="<from portal step 4>"
TENANT_PATH="<e.g. pairs-redteam-prd-fckx/red-teaming-onprem>"
CHART_VERSION="latest"
```

Set `CHART_VERSION` to `latest` for auto-detection or pin a specific version (e.g. `1.0.4`). **Pinning is recommended for production.**

### Generated Files

The script produces three files:

| File | Contents | Passed to Container |
|---|---|---|
| `.env.setup` | Registry credentials | No |
| `.env.runtime` | Client ID, secret, channel ID, tunables | Yes |
| `docker-compose.yml` | Hardened container configuration | — |

Both `.env.*` files are created with `chmod 600` (owner-only access). Existing files are backed up to `.bak` before overwriting.

### Runtime Tunables

Adjust in `.env.runtime` and restart (`docker compose restart`):

| Variable | Default | Description |
|---|---|---|
| `LOG_LEVEL` | `INFO` | Logging verbosity |
| `POOL_SIZE` | `2048` | Max concurrent connections |
| `PROXY_TIMEOUT` | `100s` | Timeout for target responses |
| `CONNECTION_RETRY_INTERVAL` | `5s` | Retry interval for failed connections |
| `RE_AUTH_INTERVAL` | `5m` | Re-authentication frequency |
| `DISABLE_SSL_VERIFICATION` | `false` | **Must be `false` in production** |

---

## Security

The generated `docker-compose.yml` applies these hardening measures:

```yaml
read_only: true                        # Immutable filesystem
security_opt: [no-new-privileges:true] # No privilege escalation
cap_drop: [ALL]                        # Minimal capabilities
mem_limit: 512m                        # Memory limit
cpus: 1.0                              # CPU limit
pids_limit: 256                        # Fork bomb protection
healthcheck: ...                       # Automatic health monitoring
```

Additional protections:
- Registry credentials are **never** passed to the container (split `.env` files)
- Credentials are piped via stdin to `crane auth login` (not visible in `ps`)
- `.env.*` files are created with `600` permissions
- `.gitignore` prevents committing secrets (`.env`, `.env.*`, `.env.setup`, `.env.runtime`)
- Shell tracing detection warns if `set -x` could leak secrets
- Crane binary downloaded with pinned version and SHA256 checksum verification
- Image digest logged to `deploy.log` for supply chain auditability
- Image tarball stored in temp directory (cleaned up on exit, even on failure)
- Existing config files backed up before overwriting

### Deployment Audit Log

Every install and image pull is logged to `deploy.log` with timestamps, image digests, and chart versions. This file never contains secrets and supports compliance requirements (SOC 2, ISO 27001).

---

## Operations

### Managing the Client

```bash
./setup-panw-network-client.sh --status      # Deployment overview
./setup-panw-network-client.sh --validate     # Check channel connectivity
./setup-panw-network-client.sh --diagnose     # Troubleshoot issues

docker compose logs -f panw-network-client    # Follow logs
docker compose down                           # Stop
docker compose up -d                          # Start
docker compose restart                        # Restart after config changes
docker stats panw-network-client              # Resource usage
```

### Health Monitoring

The container includes a Docker healthcheck that verifies the client process is running. Check health status:

```bash
docker inspect --format='{{.State.Health.Status}}' $(docker ps -qf name=panw-network-client)
```

### Updating

Change `CHART_VERSION` in `.env` (or keep `latest`) and re-run the script:

```bash
./setup-panw-network-client.sh
```

List available versions:

```bash
crane ls registry.ai-red-teaming.paloaltonetworks.com/<TENANT_PATH>/charts/panw-network-client
```

### Credential Rotation

1. Generate new credentials in the portal
2. Update `.env.runtime` (or update `.env` and re-run the script)
3. Restart: `docker compose restart`
4. Verify: `./setup-panw-network-client.sh --validate`
5. Revoke old credentials in the portal

### Backup

```bash
tar -czf panw-client-backup-$(date +%Y%m%d).tar.gz .env .env.setup .env.runtime docker-compose.yml deploy.log
```

### Uninstall

```bash
docker compose down                                    # Stop container
docker rmi $(docker compose config | grep image: | awk '{print $2}')  # Remove image
rm -f .env.setup .env.runtime docker-compose.yml       # Remove config
```

---

## Network Requirements

Outbound HTTPS (TCP/443) to:

| Endpoint | Pattern | Purpose |
|---|---|---|
| `api.sase.paloaltonetworks.com` | Long-lived | Control plane |
| `auth.apps.paloaltonetworks.com` | Periodic | Token refresh |
| `registry.ai-red-teaming.paloaltonetworks.com` | Setup only | Image pull |
| `github.com` | Setup only | Crane download |
| Target systems | On-demand | Proxied traffic |

Test connectivity:

```bash
curl -sI https://api.sase.paloaltonetworks.com
curl -sI https://auth.apps.paloaltonetworks.com
```

Any HTTP response (200, 401, 403) confirms the connection works. Timeouts indicate a network block.

### Proxy Support

Add to `.env.runtime`:

```env
HTTP_PROXY="http://proxy.example.com:8080"
HTTPS_PROXY="http://proxy.example.com:8080"
NO_PROXY="localhost,127.0.0.1"
```

---

## Troubleshooting

Run `./setup-panw-network-client.sh --diagnose` for automated analysis, or check manually:

| Problem | Likely Cause | Fix |
|---|---|---|
| `Unsupported architecture` at Step 1 | Unsupported OS/arch | Check `uname -s` / `uname -m` |
| `unauthorized` at Step 2 | Bad registry credentials | Verify `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` |
| `Could not list chart versions` | Wrong `TENANT_PATH` | Test: `crane ls <registry>/<TENANT_PATH>/charts/panw-network-client` |
| `Could not parse image` | Chart format changed | Check `values.yaml` output, contact PA support |
| Container exits immediately | Bad `CLIENT_ID`/`CLIENT_SECRET` | Check `docker compose logs panw-network-client` |
| Channel stays "Offline" | Network or credential issue | Run `--diagnose` to identify the cause |
| `docker compose` not found | Compose not installed | Install: `apt install docker-compose-plugin` |
| Container can't reach targets | Capabilities too restrictive | Add `cap_add: [NET_RAW]` if ICMP is needed |

---

## Migration to Kubernetes

When your team is ready to move to Kubernetes, the mapping is straightforward:

| Docker Compose | Kubernetes |
|---|---|
| `.env.runtime` | Secret + ConfigMap |
| `docker-compose.yml` image | Helm `values.yaml` image override |
| `docker-compose.yml` security | Pod Security Context |
| `docker-compose.yml` limits | Resource requests/limits |
| `healthcheck` | Liveness/readiness probes |

The runtime tunables in `.env.runtime` use the same names as the Helm chart's `values.yaml`, so configuration carries over directly.

---

## License

See [LICENSE](LICENSE) for details.
