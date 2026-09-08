# Reproducible development environment for deephaven-server-docker, via
# devenv.sh (https://devenv.sh).
#
# Same shape as deephaven-base-images/devenv.nix (see that file for the
# fuller rationale) -- this repo has no host-side compile step of its own
# either. Every image (server, server-ui, server-slim, server-all-ai,
# server-nltk, server-pytorch, server-sklearn, server-tensorflow) is produced
# by `docker buildx bake -f <name>.hcl` against a `contexts/<name>/`
# directory (see README.md, DEVELOPMENT.md, *.hcl). So the only thing a
# contributor actually needs on PATH is a `docker` CLI whose `buildx`
# subcommand works.
#
# One thing this repo needs beyond deephaven-base-images: DEVELOPMENT.md's
# "custom sources" workflow copies a `server-jetty-*.tar` and a
# `deephaven_core-*.whl` (built from a *separate* deephaven-core checkout's
# own `./gradlew server-jetty-app:assemble py-server:assemble`) into
# `contexts/server[-slim]/` before running
# `DEEPHAVEN_SOURCES=custom docker buildx bake -f server.hcl`. That's a
# deephaven-core devenv concern, not this one -- this file doesn't try to
# provide a JDK/Python toolchain for that; it only covers what's needed once
# those artifacts already exist (or when using the default
# `DEEPHAVEN_SOURCES=released`, which needs none of this at all).
#
# What this deliberately does NOT do: install or start Docker (or Podman)
# itself, or set up cross-arch (QEMU/binfmt) emulation for the
# `MULTI_ARCH=true`/`RELEASE=true` linux/amd64+linux/arm64 builds -- see
# devenv-README.md for both.
#
# Usage:
#   devenv shell           # docker-buildx plugin wired up, jq/git on PATH,
#                           # DOCKER_HOST auto-detected from a running Podman
#                           # socket if not already set
#   direnv users: `echo "eval \"\$(devenv direnvrc)\"" >> .envrc && echo "use devenv" >> .envrc && direnv allow`
#                           # (an .envrc with exactly this is already
#                           # checked in -- just run `direnv allow`)
{ pkgs, ... }:
let
  # Many Docker installs (especially older dockerd-only ones without Docker
  # Desktop) don't bundle a `buildx` CLI plugin recent enough to support
  # `bake` at all -- pinning our own avoids "unknown command: buildx" or
  # missing-bake-support surprises varying by contributor machine.
  buildx = pkgs.docker-buildx;

  # Auto-detects a rootless Podman API socket so the `docker` CLI itself
  # finds it -- the socket's path is $XDG_RUNTIME_DIR/podman/podman.sock,
  # i.e. it embeds your UID (e.g. /run/user/1001/podman/podman.sock), so a
  # value that works on one contributor's machine won't work on another's.
  #
  # `podman info`'s `.Host.RemoteSocket.Path` is Podman's own reported socket
  # location -- confirmed directly against podman-info(1)'s documented
  # output -- already accounting for XDG_RUNTIME_DIR/whatever the
  # podman.socket systemd unit is actually configured with, so querying it
  # beats guessing the path by hand. This only ever *reads* that value; it
  # never starts or configures the socket/service itself -- it assumes you
  # already have `podman.socket` (or Docker) running normally, and just
  # wires the resulting env var up for you.
  #
  # Only kicks in when DOCKER_HOST isn't already set (never overrides an
  # explicit choice) and the reported path is an actual live socket, not
  # just Podman's unconditionally-computed default (e.g. if podman.socket
  # is installed but not currently running). Identical to
  # deephaven-base-images/devenv.nix's copy of this hook, itself copied from
  # deephaven-core/devenv.nix's podmanDockerHostHook (minus the
  # TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE export, which has no consumer in
  # any of these bake-only repos).
  podmanDockerHostHook = ''
    if [[ -z "''${DOCKER_HOST:-}" ]] && command -v podman >/dev/null 2>&1; then
      _podman_sock="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
      # Depending on podman version/rootless-vs-rootful setup, this value
      # may already carry a "unix://" scheme prefix or may be a bare
      # filesystem path -- normalize to a bare path before testing/using it.
      _podman_sock="''${_podman_sock#unix://}"
      if [[ -n "$_podman_sock" && -S "$_podman_sock" ]]; then
        export DOCKER_HOST="unix://$_podman_sock"
      fi
      unset _podman_sock
    fi
  '';
in
{
  packages = [
    buildx
    pkgs.jq # for inspecting `docker buildx bake -f <name>.hcl --print` (JSON output)
    pkgs.git
  ];

  # Docker's CLI discovers `buildx` as a plugin from a fixed set of
  # directories (not from $PATH) -- `~/.docker/cli-plugins/` is the
  # user-level one, checked before any system-wide plugin dir. Symlinking
  # ours in there is what actually makes `docker buildx bake` (as opposed to
  # just running the `docker-buildx` binary standalone) pick this version up.
  #
  # Only creates the symlink if nothing is there yet -- never overwrites a
  # contributor's own already-installed buildx plugin (e.g. Docker Desktop's
  # bundled one).
  enterShell = ''
    _cli_plugins_dir="$HOME/.docker/cli-plugins"
    mkdir -p "$_cli_plugins_dir"
    if [ ! -e "$_cli_plugins_dir/docker-buildx" ]; then
      ln -s "${buildx}/bin/docker-buildx" "$_cli_plugins_dir/docker-buildx"
    fi
    unset _cli_plugins_dir

    echo "deephaven-server-docker dev shell ($(docker-buildx version 2>&1 | head -1))"
    echo "Run: docker buildx bake -f server.hcl   (or server-base.hcl / server-slim.hcl / server-slim-base.hcl)"
  '' + podmanDockerHostHook;

  # Docker itself (daemon + CLI) is assumed already installed and running on
  # your host -- this file only adds the buildx plugin and DOCKER_HOST
  # detection on top of it, it doesn't install or start anything
  # docker-daemon-shaped itself.
}
