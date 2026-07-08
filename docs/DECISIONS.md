# Architecture Decision Log

Record decisions here when implementation reveals a trade-off.

## ADR-001 — Docker Compose installer, not Kubernetes/Helm

**Status:** accepted

The upstream client ships as a Helm chart. Customers running AI endpoints on plain VMs, EC2, or bare metal have no cluster.

A single Bash + Docker Compose installer reaches those hosts without forcing them to stand up Kubernetes for one daemon. The Helm path stays available upstream for cluster users.

## ADR-002 — One script, CLI modes (not decomposed)

**Status:** accepted

The whole tool is `setup-panw-network-client.sh`. Arg parsing dispatches to `do_*` mode functions; helpers grouped by prefix (`api_*`, `registry_*`, `select_*` / `prompt_*`, `*_env`).

A single downloadable file is the distribution unit — one `curl`, one Sigstore attestation to verify. Splitting into sourced files would break that. Decomposition threshold is ~1800 lines of intent; resist splitting before then.

## ADR-003 — `docker pull` for images, curl/jq for tag discovery (crane removed)

**Status:** accepted (supersedes earlier crane decision)

Image fetch uses `docker pull` against the region registry. Tag discovery uses `registry_list_tags` — curl + jq with basic auth and a bearer-challenge fallback.

Crane was used historically to avoid Docker registry auth friction but added a pinned third-party binary (checksum upkeep, user-local install step). Since the script already requires Docker to run the container, `docker pull` removes the extra dependency. Registry tag listing is a plain registry v2 API call, so curl + jq suffices.

## ADR-004 — Split `.env` files: source of truth vs runtime

**Status:** accepted

`.env` holds the full configuration the operator manages. `.env.runtime` holds only what the container needs and is what gets passed in.

Separating them keeps setup-only material (registry token, region) out of the container's environment and lets the runtime file be regenerated without touching operator input.

## ADR-005 — Healthcheck gated on image base (distroless vs busybox)

**Status:** updated (1.4.0)

Client images before 1.4.0 used a Chainguard `static` (distroless) base — no shell, no coreutils — so no in-container healthcheck was possible. It was removed in PR #35.

Starting with 1.4.0 the image switched to Chainguard `busybox`, which ships `sh`, `kill`, and `grep`. The installer now emits a lightweight procfs healthcheck (`kill -0 1` + zombie check) when `IMAGE_TAG >= 1.4.0`, and omits it for older distroless builds. `restart: unless-stopped` still covers crash recovery for all versions.

## ADR-006 — No telemetry / phone-home

**Status:** accepted

The script reports nothing back to PANW. Metrics like "time to connect" are gauged out-of-band (supported onboardings, release download counts), not auto-captured.

A network client that silently phones home is a trust problem for a security product deployed inside customer infra. If a hard metric is ever required, it needs an explicit opt-in telemetry decision first.

## ADR-008 — Adapter sidecar as an opt-in second Compose service

**Status:** accepted

The client binary (1.4.0+) supports a custom model adapter sidecar via two env vars: `ADAPTER_SIDECAR_ENABLED` and `ADAPTER_SIDECAR_URL` (default `http://localhost:8010`). In the Helm chart this maps to `--set adapterSidecar.enabled=true`.

In the Docker Compose installer the sidecar is an opt-in second service in the generated `docker-compose.yml`. When `ADAPTER_SIDECAR_ENABLED=true` in `.env`, the installer appends a `panw-adapter-sidecar` service with `network_mode: service:panw-network-client` so both containers share the same network namespace — `localhost:8010` routing works without exposing any port. The sidecar image is customer-supplied via `ADAPTER_SIDECAR_IMAGE`.

A `version_ge` guard warns (but does not block) if the client image is older than 1.4.0, since the binary will silently ignore the env vars below that version.

## ADR-007 — Sigstore attestation, no `.sha256`

**Status:** accepted

The release workflow attaches only `setup-panw-network-client.sh` plus a Sigstore build-provenance attestation, verified with `gh attestation verify`.

The attestation covers integrity and proves the file was built by this repo, which a bare `.sha256` cannot. Shipping both would imply the checksum adds a guarantee it does not.
