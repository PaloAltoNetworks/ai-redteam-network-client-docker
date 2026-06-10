# Repository instructions for Claude Code

Read the shared project documentation:
- @docs/PRD.md
- @docs/ARCHITECTURE.md
- @docs/DECISIONS.md
- @docs/FEATURES.yaml
- @docs/reference.md

These are the source of truth. Point to them; don't restate their content here.

## Behavior

- **Think before coding.** State assumptions. If multiple interpretations exist, present them — don't pick silently. If a simpler approach exists, say so. If unclear, stop and ask.
- **Simplicity first.** Minimum code that solves the problem. No speculative features, abstractions, configurability, or error handling for impossible cases. No backwards-compat shims. If 200 lines could be 50, rewrite.
- **Surgical changes.** Every changed line traces to the request. Don't improve adjacent code or refactor what isn't broken; match existing style. Remove only the orphans your change created; leave pre-existing dead code (mention it, don't delete).
- **Goal-driven.** Define success criteria before coding. For a bug, write the repro first. For planned features, the `acceptance:` block in `docs/FEATURES.yaml` is the criterion.

## Working rules

- Implement one feature at a time (one `F-1xx` from `docs/FEATURES.yaml` for planned work). Do not silently expand scope.
- Use plan mode before any multi-file or architectural change.
- Before editing, identify affected functions, risks, and the validation commands you will run.
- When implementation reveals a trade-off, record a new ADR in `docs/DECISIONS.md`.
- Honor the security model in `docs/ARCHITECTURE.md`: never write secrets to `deploy.log`, process listings, or committed files. Watch the `set -euo pipefail` grep-abort trap (CHANGELOG 0.1.9–0.1.11).
- Ask before adding a new runtime dependency.
- Never commit generated files: `docker-compose.yml`, `.env*`, `deploy.log`.
- All GitHub Actions MUST be SHA-pinned (org rule).

## Verification

For every completed change:
- run `shellcheck setup-panw-network-client.sh` and `shfmt -d -i 2 setup-panw-network-client.sh`;
- preview with `./setup-panw-network-client.sh --dry-run`;
- review the diff for regressions and secret leakage;
- update `docs/FEATURES.yaml` status (and `CHANGELOG.md` if behavior changed) only after acceptance criteria pass;
- summarize changed functions and remaining risks.

## Conventions

- Commit messages: single line, no `Co-Authored-By` trailer.
- Multi-concern work: split into focused commits, one concern each.
- Release: bump `SCRIPT_VERSION` + `CHANGELOG.md` as the **last** PR before merging `develop` into `main`. Tags annotated + SSH-signed, message bare `vX.Y.Z`, never override `gpgsign`. (Release-asset policy: `docs/DECISIONS.md` ADR-007.)
