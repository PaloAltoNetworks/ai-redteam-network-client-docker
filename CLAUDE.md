# CLAUDE.md

Repository instructions for Claude Code.

## Read the shared project documentation

@docs/PRD.md
@docs/ARCHITECTURE.md
@docs/DECISIONS.md
@docs/FEATURES.yaml
@docs/reference.md

These are the source of truth. Do not restate their content here — point to them.

| Doc | Owns |
|---|---|
| `docs/PRD.md` | Product intent, shipped surface (FR1-FR10) |
| `docs/ARCHITECTURE.md` | Stack, single-file layout, security model |
| `docs/DECISIONS.md` | ADR log — trade-offs with rationale |
| `docs/FEATURES.yaml` | Open/planned work (F-1xx) + acceptance criteria |
| `docs/reference.md` | Config / operations / K8s migration |
| `CHANGELOG.md` | Per-release history (Keep a Changelog, SemVer) |

The tool is a single Bash installer, `setup-panw-network-client.sh`. Never commit generated files: `docker-compose.yml`, `.env*`, `deploy.log`.

## How to work here

- Implement one feature at a time (one `F-1xx` from `docs/FEATURES.yaml` for planned work). Do not silently expand scope.
- Use plan mode before any multi-file or architectural change.
- Before editing: identify affected functions, the risks, and the validation commands you will run.
- When implementation reveals a trade-off, record a new ADR in `docs/DECISIONS.md`.
- Update a feature's status in `docs/FEATURES.yaml` only after its acceptance criteria pass; update `CHANGELOG.md` when behavior changes.
- Ask before adding a new runtime dependency.
- Honor the security model in `docs/ARCHITECTURE.md` — no secrets in `deploy.log` / `ps` / committed files. Watch the `set -euo pipefail` grep-abort trap (see CHANGELOG 0.1.9–0.1.11).

## Verification

```bash
shellcheck setup-panw-network-client.sh
shfmt -d -i 2 setup-panw-network-client.sh   # -w to apply
./setup-panw-network-client.sh --dry-run     # preview without changes
```

Then review the diff for regressions and secret leakage; summarize changed functions and remaining risks.

## Conventions not covered in docs

- Commit messages: single line, no `Co-Authored-By` trailer.
- Multi-concern work: split into focused commits, one concern each.
- Release flow: bump `SCRIPT_VERSION` + `CHANGELOG.md` as the **last** PR before merging `develop` into `main`. Tags annotated + SSH-signed, message bare `vX.Y.Z`, never override `gpgsign`. (Release-asset policy: see `docs/DECISIONS.md` ADR-007.)
- All GitHub Actions MUST be SHA-pinned (org rule).
- Do not add backwards-compat shims or speculative abstractions; one focused tool.
