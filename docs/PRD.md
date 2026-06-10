# PRD — PANW AI Red Teaming Network Channel Client (Docker)

## 1. Overview

A single-file Bash installer that deploys the Palo Alto Networks AI Red Teaming Network Channel client via Docker Compose — no Kubernetes, no Helm. It turns a multi-step portal + registry + container workflow into one command on any host with Docker.

The Network Channel client is a lightweight daemon that opens an outbound WebSocket to the AI Red Teaming servers and relays scan traffic to internal AI endpoints, so customers expose no inbound ports and change no firewall rules.

## 2. Problem

The upstream client ships as a Helm chart targeting Kubernetes. Customers who run AI endpoints on plain VMs, EC2, or bare metal have no cluster to deploy into, and standing one up just to run one daemon is disproportionate. They also face friction discovering the right image, fetching short-lived registry credentials, and wiring channel configuration by hand.

## 3. Goals

- One command from zero to a connected channel on any Docker host.
- Auto-discover everything derivable: TSG ID, registry credentials, image path, recommended version, channel list.
- Ship a hardened-by-default container (read-only FS, dropped caps, no privilege escalation, resource limits).
- Be safe to re-run: idempotent, exits early when nothing changed.
- Leave a credential-free audit trail for SOC 2 / ISO 27001.
- Provide a clean migration path to Kubernetes when customers outgrow Compose.

## 4. Non-Goals

- Not a Kubernetes deployment tool (Helm chart already exists upstream).
- Does not manage multiple clients or fleets — one client per host.
- Does not proxy or inspect scan traffic; it only deploys the relay daemon.
- Does not create or manage service accounts (done in the portal).
- No telemetry / phone-home. The script reports nothing back to PANW; all timing and adoption metrics are out-of-band (see §10).

### Rejected alternatives

| Alternative | Why not |
|---|---|
| `.deb` / `.rpm` packages | Per-distro build + signing matrix; ties releases to OS package policy; still needs Docker for the container anyway. One portable script covers all Linux + macOS. |
| systemd service running the binary directly | Client is distributed as an OCI image, not a loose binary; would mean unpacking the image by hand and losing the registry-auth + version-discovery flow. |
| Standalone static binary (rewrite installer in Go/Rust) | Heavier toolchain and release pipeline for a thin orchestration layer; Bash + `curl` + `jq` is already present on target hosts. |
| Plain `docker run` instructions in docs | Pushes credential fetch, image discovery, and hardening flags onto the user by hand — exactly the friction this tool removes. |

If a customer outgrows Compose but does not want full K8s, the migration table in [reference.md](reference.md#migration-to-kubernetes) maps the same tunable names to a Helm `values.yaml`, so config carries over.

## 5. Users

| Persona | Need |
|---|---|
| Security engineer | Stand up a channel fast on existing infra without a K8s cluster |
| Platform / SRE | Reproducible, auditable, hardened deploy that fits change management |
| CI / automation | Non-interactive, quiet, exit-code-driven runs |

Primary segment is teams running AI endpoints on non-Kubernetes infra (VMs, EC2, bare metal) — spans SMB through enterprise legacy estates. The deployment model does not change the product's security posture versus K8s: same outbound-only WebSocket, same credentials, same image; only the orchestration layer differs.

## 6. Use case — primary journey

End-to-end happy path, P0:

1. In the PANW portal, create a service account → obtain Client ID + Client Secret.
2. Download the script from the latest GitHub release (`curl -fLO …`), `chmod +x`.
3. Run `./setup-panw-network-client.sh`. With no `.env` present it auto-enters `--init`: pick region, paste Client ID + Secret, pick or create a channel.
4. Script auto-discovers TSG ID, fetches registry credentials, resolves the recommended image version, writes `.env` + `.env.runtime` + `docker-compose.yml`, pulls the image, starts the container.
5. Run `--validate` → expect `Connected to the server`. Confirm the channel shows Online in the portal dashboard.

Failure recovery: a failed run leaves prior `.env`/compose backed up to `*.bak`; `--diagnose` pattern-matches logs to the likely cause; re-running `--init` refreshes credentials. No partial state blocks a retry.

## 7. Requirements

### 7.1 Functional

Priority key: **P0** core install path, must ship; **P1** important, fast-follow acceptable; **P2** convenience, cut first under pressure.

- **FR1 — Guided init (P0).** `--init` collects region, Client ID, Client Secret interactively; auto-extracts TSG ID; fetches registry credentials; lists channels (or creates one); writes `.env`.
- **FR2 — Install (P0).** Default run generates `.env.runtime` and a hardened `docker-compose.yml`, pulls the image, and starts the container. Auto-runs `--init` when no `.env` exists.
- **FR3 — Version control (P1).** Discover recommended version from the stats API; `--list-versions` lists registry tags; `--version TAG` pins; `--yes` accepts the recommendation non-interactively. (`--yes` itself is P0 — required for CI.)
- **FR4 — Idempotent re-run (P1).** If the resolved image is unchanged and the container is running, exit early without redeploying.
- **FR5 — Status / validate / diagnose.** `--status` shows deployment state (P1); `--validate` confirms `Connected to the server` (P0 — how a user confirms success); `--diagnose` pattern-matches logs for auth, TLS, network, channel, and permission errors (P2).
- **FR6 — Update (P1).** Re-running detects and applies a newer image. `--force-pull` forces a `docker pull` even when the image is already cached locally.
- **FR7 — Dry run (P2).** `--dry-run` previews actions without making changes.
- **FR8 — Backwards compatibility (P2).** Migrate legacy `.env` (`TENANT_PATH`, `REGISTRY_HOST`, `REGISTRY_USERNAME`) to the current format, saving `.env.old`. Only matters for hosts upgrading from a pre-release format.
- **FR9 — Quiet mode (P1).** `--quiet` suppresses info/success; errors and warnings only — for CI.
- **FR10 — Self-version (P2).** `--script-version` / `-v` prints the script version.

### 7.2 Non-functional

- **Security.** API credentials passed via `--header @file` (never in `ps`); credential functions disable shell tracing; secret files `chmod 600` written under `umask 077`; HTTPS-only (`--proto =https`); SHA256-pinned helper binaries; image digest logged.
- **Performance / resource envelope.** Container is capped by the generated compose file: `mem_limit 512m`, `cpus 1.0`, `pids_limit 256`. These are the hard ceilings the daemon must run within; treat regressions above them as defects. Bandwidth tracks scan volume and is not separately throttled.
- **Portability.** Linux (x86_64, aarch64) and macOS (Intel, Apple Silicon); Docker 20.10+ with Compose v1 or v2; depends only on `curl` + `jq` at startup. `--init` works on hosts without Docker.
- **Robustness.** `set -euo pipefail` throughout; guarded command substitutions so a no-match `grep` cannot abort the run; `die()` for fatal errors with clean exit.
- **Auditability.** Every install and pull appended to `deploy.log` with timestamp and image digest, no secrets.
- **Maintainability.** Single script, ShellCheck-clean, shfmt-formatted (2-space), CI lint on push and PR. Decomposition threshold ~1800 lines.

## 8. Configuration surface

- **Regions:** Americas (US, default), Europe (NL), Asia Pacific (SG) — one registry each.
- **Files:** `.env` (source of truth, generated by `--init`), `.env.runtime` (passed to container), `docker-compose.yml` (generated, hardened, gitignored).
- **Runtime tunables:** `LOG_LEVEL`, `POOL_SIZE`, `PROXY_TIMEOUT`, `CONNECTION_RETRY_INTERVAL`, `RE_AUTH_INTERVAL`, `DISABLE_SSL_VERIFICATION` (must be `false` in prod).
- **Advanced overrides:** `IMAGE_PATH`, `REGISTRY_HOST`, `TSG_ID`; API endpoints overridable via `PANW_API_BASE`, `PANW_MGMT_API_BASE`, `PANW_AUTH_ENDPOINT`.

## 9. Dependencies

- **External:** PANW OAuth2 (`auth.apps.paloaltonetworks.com`); PANW SASE API (`api.sase.paloaltonetworks.com`) — channels, credentials, stats; region registries (`registry[-nl|-sg].ai-red-teaming.paloaltonetworks.com`); Docker (`docker pull`) for image fetch.
- **Internal:** the SASE API contract (channels / credentials / stats endpoints) is owned by another team — a breaking change there breaks `--init`/install; pin to documented endpoints and surface API failures with actionable errors rather than silent exits. Portal documentation linking to the release should land alongside a tagged release.

## 10. Distribution

- Released as the standalone `setup-panw-network-client.sh` with a Sigstore build-provenance attestation generated by the release workflow on tag push.
- Release body is changelog-only; no `.sha256` (attestation covers integrity).
- Semantic Versioning; CHANGELOG follows Keep a Changelog.

## 11. Success metrics

No telemetry ships in the script (see §4), so these are measured out-of-band, not auto-captured:

- **Time from download to connected channel** — target single command, < 2 min on a prepared host. Measured anecdotally / in supported onboardings, not phoned home. If a hard metric is ever required, it needs an explicit opt-in telemetry decision first.
- **Idempotent re-run** — re-run with no change exits early, no container restart. Verifiable locally and in CI.
- **Zero secret leakage** — no secrets in `deploy.log`, `ps`, or committed files. Auditable.
- **CI lint green** on every push and PR.

Adoption volume (active deployments) is not observable from the tool by design; gauge via release download counts and support signal.

## 12. Risks and open items

### Technical / known
- Credential escaping in `.env` writes handles `"` but not backticks / `$()`.
- `load_env` exports secrets into all child process environments.
- Backup files (`.env.old`, `*.bak`) are never auto-pruned — manual rotation required after credential changes.

### Operational / adoption
- **Incompatible Docker Compose versions.** v1 vs v2 syntax / behavior differences raise support load; preflight detects the binary but cannot cover every distro packaging quirk.
- **Stale / vulnerable pinned image.** `--version TAG` and `IMAGE_PATH` let a user pin an old, potentially vulnerable image and never update. Mitigation: default path always resolves the recommended version; document that pinning opts out of security updates.
- **Support surface.** A one-command installer invites hands-off use on hosts the team never sees; `--diagnose` is the first-line self-service mitigation to keep ticket volume down.
