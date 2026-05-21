---
name: build-and-release
description: >-
  Use when working on safeguard-bash Azure Pipelines, Docker packaging, version
  derivation, GitHub releases, or Docker Hub publishing.
---

# safeguard-bash Build and Release

## Files involved

| File | Role |
|---|---|
| `build.yml` | Main Azure DevOps pipeline entry point |
| `pipeline-templates/global-variables.yml` | Shared version and publish variables |
| `pipeline-templates/build-steps.yml` | Common build/package steps reused by both jobs |
| `pipeline-templates/versionnumber.sh` | Computes `VersionString` and `ReleaseTag` |
| `docker/Dockerfile` | Runtime image definition |
| `docker/build.sh` | Local build helper for Docker image + zip artifact |
| `docker/run.sh` | Local helper for running the image |

## 1. Pipeline architecture (files, stages, triggers)

The repo uses **Azure DevOps Pipelines**, not GitHub Actions.

### Entry pipeline: `build.yml`

`build.yml` imports `pipeline-templates/global-variables.yml` and defines both
CI and PR behavior.

#### Triggers

Push builds run for:
- `main`
- `master`
- `release-*`
- tags matching `v*`

PR validation runs for:
- `main`
- `master`
- `release-*`

Both trigger blocks exclude documentation-only changes:
- `**/*.md`
- `LICENSE`
- `docs/`
- `.github/CODEOWNERS`

### Jobs

| Job | Condition | What it does |
|---|---|---|
| `PRValidation` | `Build.Reason == PullRequest` | Runs the shared build/package steps only |
| `BuildAndPublish` | `Build.Reason != PullRequest` | Runs the shared build/package steps, creates a GitHub release, and optionally pushes Docker images |

Both jobs run on `ubuntu-latest`.

### Shared build steps: `pipeline-templates/build-steps.yml`

The shared template performs the packaging work in this order:
1. run `pipeline-templates/versionnumber.sh`
2. dump environment variables for diagnostics
3. run `docker/build.sh $(VersionString) $(Build.SourceVersion)`
4. tag `oneidentity/safeguard-bash:latest`
5. copy the generated zip file to the artifact staging directory
6. publish the Azure Pipeline artifact

### Docker packaging path

`docker/build.sh` is the real build implementation used by the pipeline. It:
- builds `oneidentity/safeguard-bash:<version>-alpine`
- tags `oneidentity/safeguard-bash:latest`
- creates `safeguard-bash-<version>.zip`
- packages `install-local.sh`, `src/`, `samples/`, and `test/`

`docker/Dockerfile` builds the runtime image from `alpine`, installs the shell
and network tooling, copies repository content into `/scripts`, `/samples`, and
`/test`, and defaults the shell to launch with `connect-safeguard.sh` available.

## 2. Version strategy (how version numbers are derived)

### Base version

`pipeline-templates/global-variables.yml` currently defines:

```yaml
version: "8.2.0"
```

That is the base version used by the release helper.

### Tag builds

A tag build is detected when `Build.SourceBranch` starts with `refs/tags/`.

`versionnumber.sh` then enforces this format:

```text
v<major>.<minor>.<patch>
```

If the tag is valid:
- `VersionString` becomes the tag without the leading `v`
- `ReleaseTag` stays the original tag, for example `v8.2.0`

If the tag is not semver-shaped, the script exits non-zero and the release build
fails.

### Non-tag builds

For non-tag builds, `versionnumber.sh`:
- keeps `VersionString` equal to the base version from `global-variables.yml`
- derives a smaller prerelease number with `expr $buildId - 103500`
- emits `ReleaseTag=dev/v<base-version>-pre<buildNumber>`

Example:
- base version: `8.2.0`
- build id: `103900`
- release tag: `dev/v8.2.0-pre400`

### Publish gating

`global-variables.yml` also sets:
- `isTagBuild`
- `isPrerelease`
- `shouldPublishDocker`

`shouldPublishDocker` is only true for tag builds, so Docker Hub publishing is
release-only even though the image is built on every pipeline run.

## 3. Build commands (local reproduction)

### Reproduce the packaging step locally

From the repo root:

```bash
./docker/build.sh <version> <commit-sha>
```

Example:

```bash
./docker/build.sh 8.2.0 abcdef1234567890
```

This produces:
- `oneidentity/safeguard-bash:8.2.0-alpine`
- `oneidentity/safeguard-bash:latest`
- `safeguard-bash-8.2.0.zip`

### Preview version derivation locally

You can run the same helper the pipeline uses:

```bash
./pipeline-templates/versionnumber.sh 8.2.0 103900 main false
./pipeline-templates/versionnumber.sh 8.2.0 103900 v8.2.0 true
```

The script writes Azure DevOps variable commands to stdout, so use it mainly to
verify the derived `VersionString` and `ReleaseTag` behavior.

### Run the built image locally

```bash
./docker/run.sh
./docker/run.sh -c /bin/bash
```

Use `-v <hostdir>` with `docker/run.sh` if you need to mount certs or keys into
`/volume`.

## 4. Publishing targets (Docker Hub, GitHub Releases, etc.)

### Azure Pipeline artifacts

Every pipeline run publishes a build artifact named:

```text
safeguard-bash-$(VersionString)
```

The artifact contains the generated zip file.

### GitHub Releases

The `BuildAndPublish` job always creates a GitHub release in:

```text
OneIdentity/safeguard-bash
```

Pipeline behavior:
- target commit: `$(Build.SourceVersion)`
- tag source: `userSpecifiedTag`
- tag/title: `$(ReleaseTag)`
- changelog: commit-based, compared to the last full release
- asset upload: the generated zip file
- prerelease flag: true for non-tag builds, false for tag builds

So merges to `main`, `master`, or `release-*` produce prerelease-style GitHub
releases even when Docker images are not pushed.

### Docker Hub

The pipeline pushes Docker images only when `shouldPublishDocker == true`, which
means **tag builds only**.

Published tags:
- `oneidentity/safeguard-bash:$(VersionString)-alpine`
- `oneidentity/safeguard-bash:latest`

The login step uses a fixed Docker Hub username:

```text
danpetersonoi
```

and reads the secret token from Azure Key Vault.

## 5. Service connections / secrets required

The release path depends on Azure DevOps resources that are external to the
repo.

### Service connections

| Resource | Where used | Purpose |
|---|---|---|
| `PangaeaBuild-GitHub` | `GitHubRelease@1` | Create GitHub releases in `OneIdentity/safeguard-bash` |
| `SafeguardOpenSource` | `AzureKeyVault@2` | Authorize access to the Azure Key Vault holding publish secrets |

### Key Vault

The pipeline reads secrets from:

```text
SafeguardBuildSecrets
```

Requested secrets:
- `DockerHubAccessToken`
- `DockerHubPassword`

Only `DockerHubAccessToken` is actually consumed by the current Docker login
command. `DockerHubPassword` is still requested, so treat it as part of the
expected release environment unless the pipeline is cleaned up.

### Runtime/tooling assumptions

The pipeline also assumes:
- Docker is available on `ubuntu-latest`
- bash can execute `versionnumber.sh` and `docker/build.sh`
- zip creation works on the hosted agent

If a release change touches versioning, Docker tags, GitHub release behavior, or
publish secrets, inspect **all** of `build.yml`, `pipeline-templates/`, and
`docker/build.sh` together before changing anything.
