# CLAUDE.md

Repository instructions for Claude Code.

## Read the shared project documentation

@docs/PRD.md
@docs/ARCHITECTURE.md
@docs/DECISIONS.md
@docs/FEATURES.yaml
@docs/reference.md

## What this is

A single Bash installer (`setup-panw-network-client.sh`, ~2100 lines) that deploys the Palo Alto Networks AI Red Teaming Network Channel client via Docker Compose — no Kubernetes, no Helm. `docs/PRD.md` is product intent; `docs/ARCHITECTURE.md` is the stack + internal layout; `docs/DECISIONS.md` is the ADR log; `docs/FEATURES.yaml` tracks open/planned work only (shipped surface lives in the PRD); `docs/reference.md` is the full operational + migration guide.

## Layout

| Path | Role |
|---|---|
| `setup-panw-network-client.sh` | The whole tool. Arg parsing dispatches to `do_*` mode functions |
| `.env.example` | Credential template |
| `README.md` | Quick start |
| `docs/reference.md` | Config / operations / K8s migration |
| `docs/PRD.md` | Product requirements (shipped surface, FR1-FR10) |
| `docs/ARCHITECTURE.md` | Stack, single-file layout, security model |
| `docs/DECISIONS.md` | ADR log — trade-offs with rationale |
| `docs/FEATURES.yaml` | Open/planned work only (F-1xx), with acceptance criteria |
| `CHANGELOG.md` | Keep a Changelog, SemVer — per-release history |
| `docker-compose.yml` | **Generated, gitignored — never commit** |
| `.env`, `.env.runtime`, `deploy.log` | Runtime artifacts, gitignored |

## Architecture

- **One script, CLI modes.** Not decomposed. Decomposition threshold ~1800 lines of intent; resist splitting before that.
- **Mode dispatch:** each mode is a `do_*` function (`do_init`, `do_install`, `do_status`, `do_validate`, `do_diagnose`, `do_list_versions`, `do_check_update`). Helpers grouped by prefix: `api_*` (API layer), `registry_*` (tag discovery), `select_*` / `prompt_*` (interactive), `*_env` (config).
- **Image pull is `docker pull`** against the region registry. Tag discovery uses `registry_list_tags` (curl + jq, basic auth with bearer-challenge fallback), not the Docker CLI.
- **Split env files:** `.env` (source of truth) vs `.env.runtime` (container).
- **`die()`** for fatal errors with clean exit. JSON built with `jq`.
- **API endpoints overridable:** `PANW_API_BASE`, `PANW_MGMT_API_BASE`, `PANW_AUTH_ENDPOINT`.

## Working rules

- Implement one feature at a time (one `F-1xx` from `docs/FEATURES.yaml` when working planned items). Do not silently expand scope.
- Use plan mode before any multi-file or architectural change.
- When implementation reveals a trade-off, record it as a new ADR in `docs/DECISIONS.md`.
- Update a feature's status in `docs/FEATURES.yaml` only after its acceptance criteria pass.
- Before editing: identify affected functions, risks, and the validation commands you will run.
- `set -euo pipefail` is on. Guard every command substitution whose command may legitimately exit non-zero — a no-match `grep` will otherwise abort the run. This has caused multiple silent-exit regressions (CHANGELOG 0.1.9–0.1.11).
- Secrets stay out of logs and process listings: never write secrets to `deploy.log`; pass API credentials via `--header @file`, never inline; disable shell tracing (`set +x`) in credential functions.
- Write secret files under a `umask 077` subshell, then `chmod 600`. HTTPS-only on all calls (`--proto =https`).
- Preserve raw API payloads — do not pre-trim responses before they are parsed.
- Ask before adding a new runtime dependency (currently only `curl` + `jq` at startup; crane fetched on demand).
- All GitHub Actions MUST be SHA-pinned, not tag-pinned (org rule).

## Verification

For every completed change:

```bash
shellcheck setup-panw-network-client.sh
shfmt -d -i 2 setup-panw-network-client.sh   # -w to apply
./setup-panw-network-client.sh --dry-run     # preview without changes
```

Then:

- review the diff for regressions and secret leakage;
- update `CHANGELOG.md` if behavior changed;
- summarize changed functions and remaining risks.

## Release workflow

- Bump `SCRIPT_VERSION` + update `CHANGELOG.md` as the **last** PR before merging `develop` into `main`, not the first.
- Tags: annotated + SSH-signed, message is the bare `vX.Y.Z`. Never override `gpgsign`.
- Release workflow builds on tag push: attaches the `.sh` only plus a Sigstore build-provenance attestation (no `.sha256`). Release body is changelog-only.

## Commit / PR conventions

- Commit messages: single line, no `Co-Authored-By` trailer.
- Multi-concern work: split into focused commits, one concern each.

## Do not

- Commit `docker-compose.yml`, `.env*`, or `deploy.log` (gitignored — watch for `.gitignore` regressions, has happened before).
- Skip hooks or signing on commits/tags.
- Add backwards-compat shims or speculative abstractions; this is one focused tool.
