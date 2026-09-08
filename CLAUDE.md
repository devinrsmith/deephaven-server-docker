# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repository builds the [Deephaven](https://deephaven.io/) server Docker images published to `ghcr.io/deephaven/*`. There is no application source code here — it is entirely Dockerfiles, `docker buildx bake` (HCL) definitions, and the GitHub Actions workflows that drive them. Images are built from either:

- **released** sources: `deephaven-core` release tar/wheel downloaded from GitHub releases / PyPI, or
- **custom** sources: a locally-provided `server-jetty-*.tar` (and, for Python images, a `deephaven_core-*.whl`) built from a separate `deephaven-core` checkout.

The `DEEPHAVEN_SOURCES` build arg (`released` or `custom`) selects between these via Dockerfile multi-stage `FROM deephaven-${DEEPHAVEN_SOURCES}`-style stage selection.

## Repo layout

- `server.hcl` / `server-base.hcl` — bake definitions for the Python-enabled images (`server`, `server-ui` tag alias, and the `extra` group: `server-all-ai`, `server-nltk`, `server-pytorch`, `server-sklearn`, `server-tensorflow`) and their unversioned "base" counterparts.
- `server-slim.hcl` / `server-slim-base.hcl` — bake definitions for the no-Python `server-slim` image and its base counterpart.
- `contexts/server/` — Dockerfile + `deephaven.prop` + `type/<REQUIREMENTS_TYPE>/requirements.txt` for the full server image (adds a Python venv with `deephaven-core[autocomplete]` on top of the base).
- `contexts/server-base/` — Dockerfile + top-level `requirements.txt` (shared autocomplete deps, see comment in that file) + `type/<REQUIREMENTS_TYPE>/requirements.txt` (per-flavor extras, e.g. AI/ML libs) for the unversioned Python base image. Also installs `curl`, `unixodbc`, `odbc-postgresql` for integration testing.
- `contexts/server-slim/` — Dockerfile + `deephaven.prop` for the no-Python server image.
- `contexts/server-slim-base/` — Dockerfile for the unversioned no-Python base image. Installs `curl` for kafka integration testing.
- `contexts/server-generic/` and `contexts/server-scratch/` — an alternate, not-bake-driven construction path: `server-scratch` unpacks a checksummed `server-jetty-*.tar` onto `scratch`, and `server-generic` layers the grpc-health-probe + config on top of an externally supplied Java base image (`GENERIC_JAVA_BASE` build arg). These are not wired into any `.hcl`/CI target currently — check before assuming they're part of the normal release flow.
- `.github/workflows/release-ci.yml` — runs on PRs/pushes to `main`/`release/v*`; bakes `server,server-slim,server-all-ai,server-nltk,server-pytorch,server-sklearn,server-tensorflow` from released sources. Pushes to `release/v*` set `RELEASE=true` (registry push + multi-arch).
- `.github/workflows/edge-ci.yml` — nightly cron + PR/push to `main`; assembles `deephaven-core` from source (via Gradle) and bakes `server,server-slim,server-base,server-slim-base` with `DEEPHAVEN_SOURCES=custom`, tagged `edge`.
- `.github/workflows/branch-ci.yml` — manual `workflow_dispatch` for building images from an arbitrary `deephaven-core` ref/branch/SHA with a caller-chosen tag and bake target list.
- `RELEASE.md` — the release-manager runbook (branch cut, version bump, verification, fast-forward merge back to `main`).
- `DEVELOPMENT.md` — how to point a local build at a locally-built `deephaven-core` (`DEEPHAVEN_SOURCES=custom`).
- `devenv.nix` / `devenv.yaml` / `.envrc` — optional local dev shell (via devenv.sh) providing a pinned `docker buildx` (bake-capable) and `DOCKER_HOST` auto-detection for rootless Podman. Not required — the only real dependency for building is a `docker` CLI with a working `buildx` plugin. See `devenv-README.md` for details on Podman/rootless setup and multi-arch/QEMU caveats (not covered by the devenv).

## Common commands

Build the default target (`server`) locally, single-arch:

```shell
docker buildx bake -f server.hcl
```

Build a specific target/group:

```shell
docker buildx bake -f server.hcl server-all-ai
docker buildx bake -f server.hcl extra          # all extra/AI flavors
docker buildx bake -f server-slim.hcl
docker buildx bake -f server-base.hcl
docker buildx bake -f server-slim-base.hcl
```

Build against locally-built `deephaven-core` artifacts (see `DEVELOPMENT.md` for the full gradle-assemble + copy steps first):

```shell
DEEPHAVEN_SOURCES=custom docker buildx bake -f server.hcl
```

Override common variables via env or `--set`, e.g. version, tag, multi-arch, registry push:

```shell
DEEPHAVEN_VERSION=42.4 TAG=mytag docker buildx bake -f server.hcl
docker buildx bake -f server.hcl --set '*.platform=linux/amd64,linux/arm64'
```

Run a built image locally:

```shell
docker run --rm --name deephaven -p 10000:10000 deephaven/server:latest
```

There is no separate lint/test suite in this repo — validation is "does the bake build succeed and does the resulting container serve on :10000" (the images also carry a `HEALTHCHECK` hitting `grpc_health_probe` against port 10000).

## Key variables shared across the `.hcl` files

- `DEEPHAVEN_VERSION` — the deephaven-core version to build/download (drives both the release tar URL and, for Python images, the `deephaven-core[autocomplete]==<version>` pip install).
- `DEEPHAVEN_SOURCES` — `released` (download from GitHub/PyPI) or `custom` (use a locally bind-mounted tar/wheel, path controlled by `DEEPHAVEN_CORE_WHEEL`/the `server-jetty-*.tar` filename convention).
- `REQUIREMENTS_TYPE` — selects which `contexts/<image>/type/<REQUIREMENTS_TYPE>/requirements.txt` is layered in on top of the base `requirements.txt`; this is what differentiates `server` vs. `server-all-ai`/`server-nltk`/`server-pytorch`/`server-sklearn`/`server-tensorflow`.
- `RELEASE` — when true, enables multi-arch (`linux/amd64` + `linux/arm64`) output and `type=registry` push, and (in CI) enables GHA layer cache writes.
- `MULTI_ARCH` — independently forces multi-arch platforms without requiring `RELEASE`.
- `TAG` — the primary tag; when `TAG == "latest"`, an additional `:<DEEPHAVEN_VERSION>` tag is also applied.
- `GIT_REVISION` — stamped into `org.opencontainers.image.revision` for custom-source builds (the `deephaven-core` commit that was built).

## Dockerfile structure conventions

Each of the four bake-driven Dockerfiles (`server`, `server-base`, `server-slim`, `server-slim-base`) follows the same layered multi-stage pattern, so understanding one makes the others straightforward:

1. `openjdk` stage — pulls `eclipse-temurin:${OPENJDK_VERSION}` purely as a source to `COPY --link` the JDK out of later (keeps the temurin image itself out of the final layer history).
2. `os-bits` — base `ubuntu:${UBUNTU_VERSION}`, installs common OS packages (`liblzo2-2`, `tzdata`, `ca-certificates`, `locales`, `fontconfig`) and sets `en_US.UTF-8` locale. Carries the shared `org.opencontainers.image.*` LABELs.
3. (Python images only) `libpython-bits` — installs `python${PYTHON_VERSION}` + venv.
4. (`server`/`server-base` only) `venv-bits*` — creates `/opt/deephaven/venv`, installs `deephaven-core[autocomplete]` (released) or the custom wheel (custom) plus `type/${REQUIREMENTS_TYPE}/requirements.txt`.
5. `openjdk-bits` — copies the JDK in, sets `JAVA_HOME`/`PATH`.
6. `deephaven-bits*` (non-`*-base` Dockerfiles only) — copies in `/opt/deephaven` from either the `deephaven-released` (downloads+extracts the release tar via `ADD --link`) or `deephaven-custom` (extracts from a bind-mounted local tar) stage, selected via `FROM deephaven-${DEEPHAVEN_SOURCES}`.
7. `grpc-health-probe-bits` — downloads the `grpc_health_probe` binary for `${TARGETARCH}`.
8. Final stage (`server`/`server-slim`) — copies `deephaven.prop`, sets `EXPOSE`/`VOLUME`/`ENV`/`ENTRYPOINT`/`HEALTHCHECK`, applies final `io.deephaven.*` and `org.opencontainers.image.*` LABELs. The `*-base` images stop one stage earlier and don't include the extracted `/opt/deephaven` server bits at all — they're meant to be extended by copying deephaven bits in downstream.

All `apt-get` layers use locked BuildKit cache mounts keyed by `${TARGETARCH}-${UBUNTU_VERSION}` so cross-arch builds don't share/corrupt each other's apt cache.

When editing a Dockerfile, check whether the same conceptual change (OS package, base image bump, ENV/LABEL) applies to more than one of the four parallel Dockerfiles under `contexts/` — they intentionally duplicate structure rather than share a common base layer.
