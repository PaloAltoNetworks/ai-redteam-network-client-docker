# AI Red Teaming Network Client - Docker Setup

Deploy the Palo Alto Networks AI Red Teaming network client using **Docker Compose** on a standard server (Linux or macOS) — no Kubernetes or Helm required.

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/PaloAltoNetworks/ai-redteam-network-client-docker.git
cd ai-redteam-network-client-docker

# 2. Create your .env file with credentials from the AI Red Teaming portal
cp .env.example .env
# Edit .env with your values

# 3. Run the setup script
chmod +x setup-panw-network-client.sh
./setup-panw-network-client.sh
```

The script automatically installs [crane](https://github.com/google/go-containerregistry), pulls the container image, generates a hardened `docker-compose.yml`, and starts the client.

Look for **"Connected to the server"** in the logs, or click **Validate Channel** in the portal.

---

## Why This Exists

The Palo Alto AI Red Teaming portal provides Kubernetes/Helm deployment instructions. This repository offers a simpler alternative for teams that run Docker Compose on standard servers (e.g., EC2 instances) without a Kubernetes cluster.

The setup script:

1. **Replaces Helm with crane** — pulls the Helm chart as an OCI artifact and extracts `values.yaml` to discover the container image and default configuration.
2. **Replaces `docker pull` with `crane pull`** — the Palo Alto registry uses token-based auth that can expire mid-download with standard `docker pull`. Crane downloads the image as a tarball in one authenticated request, then `docker load` imports it.
3. **Replaces Kubernetes Secrets/ConfigMaps with `.env` files** — splits credentials into `.env.setup` (registry-only, never passed to the container) and `.env.runtime` (container config), following least-privilege principles.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Docker** | 20.10+ with Docker Compose (v1 or v2) |
| **OS** | Linux (x86_64, aarch64) or macOS (Intel, Apple Silicon) |
| **Tools** | `curl`, `tar`, `sudo` access |
| **Disk** | 2 GB free (for temporary image tarballs) |
| **Network** | Outbound HTTPS to `*.paloaltonetworks.com` and `github.com` |

---

## Credentials

Gather these from the [AI Red Teaming portal](https://ai-red-teaming.paloaltonetworks.com) before running the script:

| Credential | Portal Location | Used For |
|---|---|---|
| Registry Username | Channel Setup > Step 2 | Pulling images |
| Registry Password | Channel Setup > Step 2 | Pulling images |
| Service Account Client ID | Channel Setup > Step 3 | Container authentication |
| Service Account Client Secret | Channel Setup > Step 3 | Container authentication |
| Channel ID | Channel Setup > Step 4 | Container configuration |
| Tenant Path | Channel Setup > Step 4 (in OCI URL) | Registry path |

### Finding Your Tenant Path

Extract it from the OCI URL shown in the portal at Step 4:

```
oci://registry.ai-red-teaming.paloaltonetworks.com/pairs-redteam-prd-fckx/red-teaming-onprem/charts/panw-network-client
                                                   └──────────────────── TENANT_PATH ────────────────────┘
```

---

## Configuration

### `.env` (input)

Create this file before running the script:

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

Both `.env.*` files are created with `chmod 600` (owner-only access).

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
mem_limit: 512m                        # Resource limits
```

Additional protections:
- Registry credentials are **never** passed to the container (split `.env` files)
- Credentials are piped via stdin to `crane auth login` (not visible in `ps`)
- `.env.*` files are created with `600` permissions
- `.gitignore` prevents committing secrets
- The script warns if `DISABLE_SSL_VERIFICATION=true`

---

## Operations

### Managing the Client

```bash
docker compose logs -f panw-network-client   # Follow logs
docker compose down                          # Stop
docker compose up -d                         # Start
docker compose restart                       # Restart after config changes
docker stats panw-network-client             # Resource usage
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
4. Revoke old credentials in the portal

### Backup

```bash
tar -czf panw-client-backup-$(date +%Y%m%d).tar.gz .env .env.setup .env.runtime docker-compose.yml
```

### Uninstall

```bash
docker compose down                                    # Stop container
docker rmi $(docker compose config | grep image: | awk '{print $2}')  # Remove image
rm -f .env.setup .env.runtime docker-compose.yml       # Remove config
sudo rm -f /usr/local/bin/crane                        # Remove crane (optional)
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

| Problem | Likely Cause | Fix |
|---|---|---|
| `Unsupported architecture` at Step 1 | Unsupported OS/arch | Check `uname -s` / `uname -m` |
| `Permission denied` at Step 1 | No sudo access | Install crane manually to `~/.local/bin` |
| `unauthorized` at Step 2 | Bad registry credentials | Verify `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` |
| `Could not list chart versions` | Wrong `TENANT_PATH` | Test: `crane ls <registry>/<TENANT_PATH>/charts/panw-network-client` |
| `Could not parse image` | Chart format changed | Check `values.yaml` output, contact PA support |
| Container exits immediately | Bad `CLIENT_ID`/`CLIENT_SECRET` | Check `docker compose logs panw-network-client` |
| Channel stays "Offline" | Network or credential issue | Verify outbound access + `CHANNEL_ID` matches portal |
| `docker compose` not found | Compose not installed | Install: `apt install docker-compose-plugin` |
| Container can't reach targets | Capabilities too restrictive | Add `cap_add: [NET_RAW]` if ICMP is needed |

For manual crane installation without sudo:

```bash
curl -fsSL "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_$(uname -s)_$(uname -m).tar.gz" \
  | tar -xzf - -C ~/.local/bin crane
export PATH="$HOME/.local/bin:$PATH"
```

---

## License

See [LICENSE](LICENSE) for details.
