# AGENTS.md — AI Agent Instructions for safeguard-bash

safeguard-bash is a Bash + cURL SDK for **One Identity Safeguard for
Privileged Passwords (SPP)**. Public commands live in `src/`; `install-local.sh`
copies them to `$HOME/scripts`, and `docker/Dockerfile` copies them to
`/scripts`.

Reference repo: **[OneIdentity/safeguard-ps](https://github.com/OneIdentity/safeguard-ps)**
for PowerShell equivalents, broader API coverage, and testing ideas.

## Project Structure

```
safeguard-bash/
├── src/                # Public CLI commands
│   └── utils/          # Shared sourced helpers
├── test/               # Integration runner, framework, suites
├── samples/            # Example integrations and demo images
├── pipeline-templates/ # Shared Azure Pipeline steps/version helper
├── docker/             # Main image + local build/run helpers
└── install-local.sh    # Copies src/ into $HOME/scripts
```

## Setup and Build

```bash
./install-local.sh
. ~/.bash_profile
./docker/build.sh <version> <commit-sha>
./docker/run.sh
```

Re-run `./install-local.sh` after editing `src/` so `$HOME/scripts` stays in
sync.

## Linting

N/A — no linter configured.

## Testing

```bash
./test/run-tests.sh -a <appliance> -u <user> -p <password>
./test/run-tests.sh -a <appliance> -u <user> -p <password> -s connect
```

- Tests require a live Safeguard appliance.
- `test/framework.sh` provides the shared `sg_*` helpers.
- `test/suites/suite-*.sh` groups tests by feature area.

## Code Conventions

- Keep `print_usage()` first and implemented with a heredoc.
- Resolve `ScriptDir` from `${BASH_SOURCE[0]}` before sourcing helpers.
- Initialize variables before `getopts`.
- Use `src/utils/loginfile.sh` for shared login-file handling.
- Use `invoke-safeguard-method.sh` for normal REST calls and `src/utils/a2a.sh`
  for A2A mTLS calls.
- Keep long-running reconnect logic in the `listen-for-*` / `handle-*` pattern.

For deeper structure and extension guidance, read the `architecture` and
`new-script-guide` skills.

## CI/CD

See `.agents/skills/build-and-release/SKILL.md` for Azure Pipelines, Docker
packaging, version derivation, publishing targets, and required secrets.

## Security

- Never commit secrets, tokens, certificates, or private keys.
- Treat `$HOME/.safeguard_login` as sensitive because it stores access tokens.
- `-k` / insecure TLS is acceptable for local testing, not for production
  guidance.
- Keep sample-only credentials and demo shortcuts out of product workflows.

## Versioning

- Scripts default to Safeguard API **v4** unless callers override `-v`.
- Release versioning is driven by `pipeline-templates/global-variables.yml` and
  `pipeline-templates/versionnumber.sh`.
- Release tags must be `v<major>.<minor>.<patch>`; non-tag builds use
  `dev/v<base-version>-pre<buildNumber>`.

## On-Demand Skills

| Skill | When to read | File |
|-------|--------------|------|
| Architecture | Repo layout, auth/session flow, utils, events | `.agents/skills/architecture/SKILL.md` |
| Build & Release | Pipelines, Docker packaging, releases, publish secrets | `.agents/skills/build-and-release/SKILL.md` |
| Testing Guide | Running or extending integration tests | `.agents/skills/testing-guide/SKILL.md` |
| API Patterns | REST usage, filters, payload patterns, API gotchas | `.agents/skills/api-patterns/SKILL.md` |
| A2A Workflow | A2A auth, credential retrieval, brokering, A2A events | `.agents/skills/a2a-workflow/SKILL.md` |
| New Script Guide | Adding or extending commands in `src/` | `.agents/skills/new-script-guide/SKILL.md` |

## Dependencies

`bash`, `curl`, `jq` (strongly recommended), `openssl`, `sed`, `grep`, and
`docker` for container workflows.

## Keeping this file current

Update this file when repo layout, setup/test commands, CI/CD entry points, or
skill routing change. Keep only broad always-on guidance here; move detailed
reference/workflow content into `.agents/skills/`.
