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

## ADR-005 — No in-container healthcheck (distroless image)

**Status:** accepted (supersedes earlier procfs healthcheck design)

The client image is distroless — no shell, no coreutils — so an in-container Docker `healthcheck` has nothing to execute. It was removed (PR #35).

`restart: unless-stopped` covers crash recovery and the client auto-reconnects on websocket drops. Health is monitored from the host via logs (see reference.md). An earlier procfs-based composite check was designed but is dead given the distroless base.

## ADR-006 — No telemetry / phone-home

**Status:** accepted

The script reports nothing back to PANW. Metrics like "time to connect" are gauged out-of-band (supported onboardings, release download counts), not auto-captured.

A network client that silently phones home is a trust problem for a security product deployed inside customer infra. If a hard metric is ever required, it needs an explicit opt-in telemetry decision first.

## ADR-007 — Sigstore attestation, no `.sha256`

**Status:** accepted

The release workflow attaches only `setup-panw-network-client.sh` plus a Sigstore build-provenance attestation, verified with `gh attestation verify`.

The attestation covers integrity and proves the file was built by this repo, which a bare `.sha256` cannot. Shipping both would imply the checksum adds a guarantee it does not.
