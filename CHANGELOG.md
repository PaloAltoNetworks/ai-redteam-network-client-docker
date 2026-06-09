# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.9] - 2026-06-09

### Fixed
- The installer could exit silently (exit code 1) right after listing available versions, when a client container was already running from an image that had no local tag. Re-running the script now reaches the version menu as expected, and the `--version TAG` workaround is no longer needed. Thanks to Matt Zhang for reporting.

## [0.1.8] - 2026-06-03

### Changed
- Release workflow now pins its GitHub Actions to immutable commit SHAs (`actions/checkout` v6.0.3, `actions/attest` v4.1.0) and uses `actions/attest` directly instead of the deprecated `actions/attest-build-provenance` wrapper. No change to the generated attestation.

## [0.1.7] - 2026-06-03

### Added
- Releases are now built by a CI workflow on tag push, attaching a Sigstore build-provenance attestation to `setup-panw-network-client.sh`. Verify a downloaded copy with `gh attestation verify setup-panw-network-client.sh --repo PaloAltoNetworks/ai-redteam-network-client-docker`.

### Changed
- Install now downloads the script from the latest release (`curl -fLO .../releases/latest/download/setup-panw-network-client.sh`) instead of cloning the repo. Running from source is documented in the reference guide.

## [0.1.6] - 2026-06-03

### Fixed
- Removed the broken container healthcheck from the generated `docker-compose.yml`. The client image is distroless (no `/bin/sh` or coreutils), so the `CMD-SHELL` procfs healthcheck could never execute and marked every container `unhealthy` despite a working connection. `restart: unless-stopped` plus the client's built-in websocket auto-reconnect already cover resilience; the docs now describe host-side log monitoring.

## [0.1.5] - 2026-06-03

### Added
- `--debug` now reports how many registry tags matched the strict `X.Y.Z` semver filter during interactive version selection, plus a short sample of the raw tag list. Helps explain why version selection falls back to the latest tag when the registry uses non-semver tags.

## [0.1.4] - 2026-06-03

### Added
- `--debug` flag surfaces registry tag-listing diagnostics: the GET URL, basic-auth and bearer-auth HTTP codes, the bearer challenge realm/service/scope, and the parsed tag count. Helps diagnose why `registry_list_tags` falls back to "Using latest" without exposing credentials.

### Fixed
- Silent exit when the registry returned no semver-formatted tags. `semver_sort_desc` produced no output and the script exited without explanation; it now warns and falls back to the latest tag from the API.

## [0.1.3] - 2026-06-03

### Fixed
- Network reachability preflight reported `HTTP 000000` and a false `[OK] reachable` when the endpoint was unreachable (e.g. firewall blocking outbound HTTPS). `curl -w "%{http_code}"` already emits `000` on connection failure, so the `|| echo "000"` fallback doubled it to `000000`, which slipped past the `!= "000"` guard. Extracted a single `http_probe` helper used by the `--init`/`--install` preflight and the `--diagnose` API/auth checks.

## [0.1.2] - 2026-05-26

### Added
- `--force-pull` flag: stop the container, remove the cached image with `docker rmi -f`, then re-pull and restart. Use when the registry repushed the same tag with a new digest, or when local layers are suspect. The "Nothing to do" message now mentions the flag so users discover it from the output.

### Changed
- `--force-pull` bypasses the post-pull "already running latest image" early-exit, so the restart actually happens.

## [0.1.1] - 2026-05-20

### Added
- `--check-update` flag for cron and CI. Prints `current=X latest=Y action=upgrade|none|install` and sets exit code (`0` up-to-date, `1` upgrade or install needed, `2` error).
- Version list annotates each tag with `(latest)`, `(running)`, `(pulled)` so the operator sees state at a glance.
- Currently deployed tag shown before the version prompt, sourced from `docker inspect .Image` + `RepoTags` lookup, falling back to `deploy.log` when nothing is running.

### Changed
- Renamed the API recommendation marker from `recommended` to `latest`.
- Renamed the local-store marker from `local` to `pulled`.
- `do_install` skips `docker pull` when the image is already in the local Docker store. Same tag already running exits cleanly with "Nothing to do." Different tag selected but cached skips the pull, writes configs, and restarts.

### Fixed
- `running_image_tag` no longer returns a 64-char hex blob when compose stored `Config.Image` as a digest reference. Reads `.Image` first then looks up `RepoTags`.

## [0.1.0] - 2026-05-20

### Added
- `SCRIPT_VERSION` constant and `--script-version` / `-v` flag.
- `require_basics()` runs at the top of the dispatcher before any operational mode. Checks `jq` and `curl`, exits with `Missing required dependencies: <list>`.
- `do_init` now runs `preflight "init"` so Docker daemon, version, and network reachability are validated before interactive setup.
- Banner and preflight print the script version plus jq, curl, docker, and docker compose versions.

### Fixed
- Reported by Ritesh Tandon (PANW). On a minimal Ubuntu host without `jq`, `--init` reached Step 2, OAuth returned 200, but `json_extract '.access_token'` came back empty because jq was missing. Script blamed credentials. They were fine. Now the script aborts early with a clear dependency error.
